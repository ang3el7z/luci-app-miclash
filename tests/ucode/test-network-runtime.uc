import { assert_equal, assert_throws, assert_true } from './testlib.uc';
import * as fakes from './fakes.uc';
import * as network from 'miclash.network';

const BOOT = '12345678-1234-1234-1234-123456789abc';

function proc_stat(pid, started) {
	return pid + ' (miclash network test) S ' +
		join(' ', [ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, started ]) + '\n';
};

function environment(failure) {
	let filesystem = fakes.fs({
		'/proc/sys/kernel/random/boot_id': BOOT + '\n',
		'/proc/401/stat': proc_stat(401, 900)
	});
	for (let path in [ '/var', '/var/run', '/var/run/miclash' ])
		if (filesystem.lstat(path) == null) filesystem.mkdir(path);
	filesystem.set_mode('/var/run/miclash', 0o700);
	let runtime = {
		fs: filesystem, clock: fakes.clock(10000), random: fakes.entropy(),
		mutation_lock_self: { boot: BOOT, pid: 401, start: 900 }
	};
	let calls = [], leases = [], routes_active = false, dns_active = false;
	let nft_active = false, nft_generation = null;
	let nft_cleanup_failures = failure == 'cleanup-nft-once' ? 1 : 0;
	function seen(name) {
		push(calls, name);
		push(leases, runtime.mutation_lock_lease?.token ?? null);
	};
	let routing = {
		observe: () => {
			seen('routing.observe');
			return { interfaces: [], ownership: { committed: {
				routes: routes_active ? [ 'route' ] : [], rules: []
			} }, active: routes_active };
		},
		desired: () => { seen('routing.desired'); return {}; },
		diff: (wanted, observed) => {
			seen('routing.diff');
			return { conflicts: [], add_routes: observed.active ? [] : [ 'route' ],
				remove_routes: [], add_rules: [], remove_rules: [] };
		},
		apply: () => {
			seen('routing.apply'); routes_active = true;
			if (failure == 'routing') die('HEALTH_FAILED');
			return true;
		},
		cleanup: () => { seen('routing.cleanup'); routes_active = false; return true; }
	};
	let dns = {
		observe: () => {
			seen('dns.observe');
			return { conflicts: [], ownership: dns_active
				? { trusted: true, state: 'active', transition: null }
				: { trusted: false, state: 'clean', transition: null } };
		},
		desired: () => { seen('dns.desired'); return {}; },
		apply: () => {
			seen('dns.apply'); dns_active = true;
			if (failure == 'dns') die('HEALTH_FAILED');
			return true;
		},
		recover: () => { seen('dns.recover'); dns_active = true; return true; },
		cleanup: () => { seen('dns.cleanup'); dns_active = false; return true; }
	};
	let nft = {
		observe: () => {
			seen('nft.observe');
			return { installed: nft_active, generation: nft_generation };
		},
		compile: () => { seen('nft.compile'); return { generation: 'generation-7' }; },
		apply: (ignored_runtime, compiled) => {
			seen('nft.apply'); nft_active = true; nft_generation = compiled.generation;
			if (failure == 'nft') die('HEALTH_FAILED');
			return true;
		},
		cleanup: () => {
			seen('nft.cleanup'); nft_active = false; nft_generation = null;
			if (nft_cleanup_failures > 0) { nft_cleanup_failures--; die('INTERNAL'); }
			return true;
		}
	};
	let api = network.create(runtime, { routing, dns, nft });
	return { api, runtime, filesystem, calls, leases,
		state: () => ({ routes_active, dns_active, nft_active }) };
};

let settings = {
	core: { proxy_mode: 'tproxy', block_quic: false },
	interfaces: { mode: 'explicit', included: [], excluded: [],
		auto_detect_lan: false, auto_detect_wan: false },
	guard: { enabled: false }
};

// One owner lease covers routing, DNS and the final atomic nft generation.
let applied = environment();
assert_equal(applied.api.apply(settings).firewall_generation, 'generation-7');
assert_equal(sprintf('%J', applied.state()), sprintf('%J', {
	routes_active: true, dns_active: true, nft_active: true
}));
let first_lease = applied.leases[0];
assert_true(first_lease != null, 'network mutation did not acquire an owner lease');
for (let lease in applied.leases)
	assert_equal(lease, first_lease, 'network components escaped the encompassing owner lease');
assert_equal(applied.runtime.mutation_lock_lease, null,
	'network mutation leaked the in-process lease');
assert_equal(applied.filesystem.lstat('/var/run/miclash/mutation.lock'), null,
	'network mutation leaked the on-disk owner lease');

// A component may mutate and then fail. Marking it touched must happen before
// invocation so reverse cleanup removes every possibly partial owner.
for (let failed_component in [ 'routing', 'dns', 'nft' ]) {
	let failed = environment(failed_component);
	assert_throws(() => failed.api.apply(settings), 'HEALTH_FAILED');
	assert_equal(sprintf('%J', failed.state()), sprintf('%J', {
		routes_active: false, dns_active: false, nft_active: false
	}), failed_component + ' partial mutation escaped cross-component rollback: ' +
		sprintf('%J', failed.calls));
	let cleanup_order = [];
	for (let call in failed.calls)
		if (match(call, /\.cleanup$/)) push(cleanup_order, call);
	if (failed_component == 'nft')
		assert_equal(sprintf('%J', cleanup_order),
			sprintf('%J', [ 'nft.cleanup', 'dns.cleanup', 'routing.cleanup' ]));
}

// Package removal is a hard barrier: no network observer or mutator may run.
let blocked = environment();
blocked.filesystem.mkdir('/var/run/miclash/package-removal');
blocked.filesystem.set_mode('/var/run/miclash/package-removal', 0o700);
assert_throws(() => blocked.api.apply(settings), 'BUSY');
assert_equal(length(blocked.calls), 0,
	'package-removal barrier admitted a network component');

// Cleanup is failure-atomic at the component boundary. A component that
// mutates and then reports failure cannot prevent the remaining owners from
// being cleaned; a bounded second sweep verifies the final clean state.
let cleanup_fault = environment('cleanup-nft-once');
cleanup_fault.api.apply(settings);
assert_equal(cleanup_fault.api.cleanup(settings).clean, true);
assert_equal(sprintf('%J', cleanup_fault.state()), sprintf('%J', {
	routes_active: false, dns_active: false, nft_active: false
}));
assert_true(index(cleanup_fault.calls, 'routing.cleanup') >= 0 &&
	index(cleanup_fault.calls, 'dns.cleanup') >= 0,
	'one cleanup fault prevented remaining components from being cleaned');

print('network runtime transaction tests passed\n');
