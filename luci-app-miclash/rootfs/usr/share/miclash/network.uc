import { fail } from 'miclash.errors';
import * as nft from 'miclash.firewall.nft';
import * as routing from 'miclash.routing';
import * as dns from 'miclash.dns';
import * as interface_scope from 'miclash.interface-scope';
import { with_lock } from 'miclash.mutation_lock';

function unique(values) {
	let result = [];
	for (let value in values ?? [])
		if (type(value) == 'string' && length(value) && index(result, value) < 0)
			push(result, value);
	return result;
};

export function interface_projection(settings, snapshot) {
	let interfaces = settings?.interfaces;
	if (type(interfaces) != 'object' ||
	    (interfaces.mode != 'explicit' && interfaces.mode != 'exclude'))
		fail('INVALID_ARGUMENT');
	if (snapshot != null) {
		let projection = interface_scope.resolve(settings, snapshot);
		return { mode: projection.mode, lan: projection.included, wan: projection.excluded };
	}
	let lan = [ ...(interfaces.included ?? []) ], wan = [ ...(interfaces.excluded ?? []) ];
	if (interfaces.auto_detect_lan === true && length(interfaces.detected_lan ?? ''))
		push(lan, interfaces.detected_lan);
	if (interfaces.auto_detect_wan === true && length(interfaces.detected_wan ?? ''))
		push(wan, interfaces.detected_wan);
	return { mode: interfaces.mode, lan: unique(lan), wan: unique(wan) };
};

export function interface_decision(settings, name, snapshot) {
	let projection = interface_projection(settings, snapshot);
	if (type(name) != 'string' || !length(name)) fail('INVALID_ARGUMENT');
	if (projection.mode == 'explicit')
		return index(projection.lan, name) >= 0 ? 'PROXY' : 'DIRECT';
	return index(projection.wan, name) >= 0 ? 'DIRECT' : 'PROXY';
};

function firewall_desired(settings, observed, additions) {
	let interfaces = settings?.interfaces, core = settings?.core;
	if (type(interfaces) != 'object' || type(core) != 'object' ||
	    type(settings?.guard?.enabled) != 'bool') fail('INVALID_ARGUMENT');
	let projection = interface_projection(settings);
	return {
		proxy_mode: core.proxy_mode,
		interface_mode: projection.mode,
		lan: projection.lan, wan: projection.wan,
		guard: settings.guard.enabled,
		quic: core.block_quic,
		server_ips: additions?.server_ips ?? [],
		fakeip_cidrs: additions?.fakeip_cidrs ?? [],
		device_policies: additions?.device_policies ?? [],
		ip_families: [ 'ipv4', 'ipv6' ],
		previous_generation: observed?.generation ?? null
	};
};

export function create(runtime, injected) {
	if (type(runtime) != 'object') fail('INVALID_ARGUMENT');
	let modules = { nft, routing, dns, ...(injected ?? {}) };
	for (let name in [ 'nft', 'routing', 'dns' ])
		if (type(modules[name]) != 'object') fail('INVALID_ARGUMENT');
	if (type(modules.nft.observe) != 'function' || type(modules.nft.compile) != 'function' ||
	    type(modules.nft.apply) != 'function' ||
	    type(modules.nft.cleanup) != 'function' ||
	    type(modules.routing.observe) != 'function' || type(modules.routing.desired) != 'function' ||
	    type(modules.routing.diff) != 'function' || type(modules.routing.apply) != 'function' ||
	    type(modules.routing.cleanup) != 'function' ||
	    type(modules.dns.observe) != 'function' || type(modules.dns.desired) != 'function' ||
	    type(modules.dns.apply) != 'function' || type(modules.dns.recover) != 'function' ||
	    type(modules.dns.cleanup) != 'function')
		fail('INVALID_ARGUMENT');

	function apply(settings, additions) {
		return with_lock(runtime, { barrier: 'normal', wait_ms: 0 }, () => {
			let touched_routing = false, touched_dns = false, touched_firewall = false;
			let firewall = null, failure = null;
			try {
				let routes_before = modules.routing.observe(runtime);
				let wanted = modules.routing.desired({
					proxy_mode: settings.core.proxy_mode,
					ip_families: [ 'ipv4', 'ipv6' ]
				}, routes_before.interfaces);
				let route_plan = modules.routing.diff(wanted, routes_before);
				if (length(route_plan.conflicts ?? [])) fail('HEALTH_FAILED');
				// A component may partially mutate before reporting failure. Mark it
				// touched before entry so reverse cleanup always covers that boundary.
				touched_routing = true;
				modules.routing.apply(runtime, route_plan);
				let route_check = modules.routing.diff(wanted, modules.routing.observe(runtime));
				if (length(route_check.conflicts ?? []) || length(route_check.add_routes ?? []) ||
				    length(route_check.remove_routes ?? []) || length(route_check.add_rules ?? []) ||
				    length(route_check.remove_rules ?? [])) fail('HEALTH_FAILED');

				let dns_before = modules.dns.observe(runtime);
				touched_dns = true;
				if (dns_before?.ownership?.trusted === true && dns_before.ownership.transition != null)
					modules.dns.recover(runtime, 'active');
				else if (!(dns_before?.ownership?.trusted === true &&
				           dns_before.ownership.state == 'active'))
					modules.dns.apply(runtime, modules.dns.desired(dns_before));
				let dns_after = modules.dns.observe(runtime);
				if (length(dns_after?.conflicts ?? []) || dns_after?.ownership?.trusted !== true ||
				    dns_after.ownership.state != 'active' || dns_after.ownership.transition != null)
					fail('HEALTH_FAILED');

				let nft_before = modules.nft.observe(runtime);
				firewall = modules.nft.compile(firewall_desired(settings, nft_before, additions));
				touched_firewall = true;
				modules.nft.apply(runtime, firewall);
				let nft_after = modules.nft.observe(runtime);
				if (nft_after?.installed !== true || nft_after.generation != firewall.generation)
					fail('HEALTH_FAILED');
			}
			catch (error) { failure = error?.code ?? error?.message ?? 'INTERNAL'; }
			if (failure != null) {
				let rollback_failed = false;
				if (touched_firewall) try { modules.nft.cleanup(runtime, { preserve_guard: true }); }
				catch (error) { rollback_failed = true; }
				if (touched_dns) try { modules.dns.cleanup(runtime); }
				catch (error) { rollback_failed = true; }
				if (touched_routing) try {
					modules.routing.cleanup(runtime, modules.routing.observe(runtime));
				} catch (error) { rollback_failed = true; }
				fail(rollback_failed ? 'INTERNAL' : failure);
			}
			return { changed: true, firewall_generation: firewall.generation };
		});
	};

	function is_clean() {
		let nft_state = modules.nft.observe(runtime);
		let route_state = modules.routing.observe(runtime);
		let dns_state = modules.dns.observe(runtime);
		return nft_state?.installed !== true &&
			!length(route_state?.ownership?.committed?.routes ?? []) &&
			!length(route_state?.ownership?.committed?.rules ?? []) &&
			dns_state?.ownership?.trusted !== true;
	};

	function cleanup(settings) {
		if (type(settings?.guard?.enabled) != 'bool') fail('INVALID_ARGUMENT');
		return with_lock(runtime, { barrier: 'normal', wait_ms: 0 }, () => {
			function sweep() {
				let reported_failure = false;
				try { modules.nft.cleanup(runtime, { preserve_guard: true }); }
				catch (error) { reported_failure = true; }
				try { modules.routing.cleanup(runtime, modules.routing.observe(runtime)); }
				catch (error) { reported_failure = true; }
				try { modules.dns.cleanup(runtime); }
				catch (error) { reported_failure = true; }
				let nft_after = null, routes_after = null, dns_after = null;
				try { nft_after = modules.nft.observe(runtime); }
				catch (error) { reported_failure = true; }
				try { routes_after = modules.routing.observe(runtime); }
				catch (error) { reported_failure = true; }
				try { dns_after = modules.dns.observe(runtime); }
				catch (error) { reported_failure = true; }
				let clean = nft_after != null && routes_after != null && dns_after != null &&
					nft_after?.installed !== true &&
					!length(routes_after?.ownership?.committed?.routes ?? []) &&
					!length(routes_after?.ownership?.committed?.rules ?? []) &&
					!length(dns_after?.conflicts ?? []) && dns_after?.ownership?.trusted !== true;
				return { clean, reported_failure };
			};
			// All component cleanup boundaries are attempted even after one reports
			// failure. A bounded second full sweep handles mutate-then-error adapters
			// and proves one coherent clean terminal state under the same lease.
			let result = sweep();
			if (!result.clean || result.reported_failure) result = sweep();
			if (!result.clean || result.reported_failure)
				fail(result.reported_failure ? 'INTERNAL' : 'HEALTH_FAILED');
			return { clean: true, guard_preserved: settings.guard.enabled };
		});
	};

	return { apply, cleanup, is_clean };
};
