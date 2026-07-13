import { assert_equal, assert_throws, assert_true } from './testlib.uc';
import { desired, observe, diff, apply, cleanup } from 'miclash.routing';
import * as fakes from './fakes.uc';

const MANIFEST_PATH = '/var/run/miclash/routing-ownership.json';
const CAPTURE_PREFIX = '/usr/bin/timeout -s KILL 2 ';

let host_fs = require('fs');
assert_equal(host_fs.readfile('luci-app-miclash/rootfs/etc/iproute2/rt_protos.d/miclash.conf'),
	'242 miclash\n', 'iproute2 protocol 242 has an explicit packaged MiClash reservation');
assert_equal(host_fs.readfile('luci-app-miclash/rootfs/etc/iproute2/rt_tables.d/miclash.conf'),
	'100 miclash_tproxy\n101 miclash_mixed\n',
	'iproute2 tables 100 and 101 have explicit packaged MiClash reservations');
let package_recipe = host_fs.readfile('luci-app-miclash/Makefile');
assert_true(index(package_recipe, '+coreutils-timeout') >= 0,
	'package installs the hard-deadline producer dependency');
assert_true(index(package_recipe, '$(1)/etc/iproute2/rt_protos.d/') >= 0 &&
	index(package_recipe, '$(1)/etc/iproute2/rt_tables.d/') >= 0,
	'reservation fragments are package-owned files replaced on upgrade and removed on uninstall');

function encoded(value) { return sprintf('%J', value); };
function pipe(value, status) {
	let offset = 0;
	return {
		read: (amount) => { let chunk = substr(value, offset, amount); offset += length(chunk); return chunk; },
		close: () => status ?? 0
	};
};
function runtime(outputs) {
	let calls = [], captures = [], filesystem = fakes.fs(), responses = outputs ?? {};
	for (let path in [ '/var', '/var/run', '/var/run/miclash' ]) filesystem.mkdir(path);
	filesystem.popen = (command, mode) => {
		push(captures, command);
		let logical = substr(command, 0, length(CAPTURE_PREFIX)) == CAPTURE_PREFIX
			? substr(command, length(CAPTURE_PREFIX)) : command;
		let reply = responses[logical] ?? responses[command] ?? '[]\n';
		return type(reply) == 'object' ? pipe(reply.output ?? '', reply.status ?? 0) : pipe(reply);
	};
	function argument(args, name) {
		for (let i = 0; i < length(args) - 1; i++) if (args[i] == name) return args[i + 1];
		return null;
	};
	function mutate(request) {
		let args = request.args ?? [], flag = args[0];
		if (flag != '-4' && flag != '-6') return;
		if (args[1] == 'route') {
			let table = argument(args, 'table');
			let key = 'ip -j ' + flag + ' route show table ' + table + ' 2>/dev/null';
			if (args[2] == 'del') { responses[key] = '[]\n'; return; }
			let kind = args[3] == 'local' ? 'local' : args[3] == 'unreachable' ? 'unreachable' : 'unicast';
			let value = { type: kind, dst: 'default', table: int(table), protocol: 242 };
			if (kind == 'local') value.dev = argument(args, 'dev');
			else if (kind == 'unreachable') value.metric = int(argument(args, 'metric'));
			else value.dev = argument(args, 'dev');
			responses[key] = sprintf('[%J]\n', value);
		}
		else if (args[1] == 'rule') {
			let key = 'ip -j ' + flag + ' rule show 2>/dev/null';
			let existing = [];
			try { existing = json(type(responses[key]) == 'string' ? responses[key] : '[]'); }
			catch (error) {}
			if (args[2] == 'del') {
				let retained = [], priority = int(argument(args, 'pref')),
					table = int(argument(args, 'table'));
				for (let rule in existing)
					if (rule.priority != priority || rule.table != table) push(retained, rule);
				responses[key] = sprintf('%J\n', retained);
				return;
			}
			let mark_mask = split(argument(args, 'fwmark'), '/');
			push(existing, { priority: int(argument(args, 'pref')),
				src: 'all', fwmark: mark_mask[0], fwmask: mark_mask[1],
				table: int(argument(args, 'table')), protocol: 242 });
			responses[key] = sprintf('%J\n', existing);
		}
	};
	let value = {
		process: { calls, run: (request) => { push(calls, request); mutate(request); return { code: 0, stdout: 'untrusted' }; } },
		fs: filesystem,
		digest: fakes.digest(filesystem),
		clock: fakes.clock(1000),
		paths: { run: '/var/run/miclash' },
		captures
	};
	value.seed_kernel = (routes, rules) => {
		for (let item in routes ?? []) {
			let flag = item.family == 'ipv4' ? '-4' : '-6';
			let encoded = { type: item.kind, dst: 'default', table: item.table, protocol: 242 };
			if (item.kind == 'unreachable') encoded.metric = item.metric;
			else encoded.dev = item.device;
			responses['ip -j ' + flag + ' route show table ' + item.table + ' 2>/dev/null'] =
				sprintf('[%J]\n', encoded);
		}
		for (let item in rules ?? []) {
			let flag = item.family == 'ipv4' ? '-4' : '-6';
			let key = 'ip -j ' + flag + ' rule show 2>/dev/null', existing = [];
			try { existing = json(type(responses[key]) == 'string' ? responses[key] : '[]'); }
			catch (error) {}
			push(existing, {
				priority: item.priority, src: 'all', fwmark: item.mark, fwmask: item.mask,
				table: item.table, protocol: 242
			});
			responses[key] = sprintf('%J\n', existing);
		}
	};
	return value;
};
function with_monitor(value, present) {
	value.observers = { routing: {
		subscribe: (callback) => ({ remove: () => true }),
		condition: () => present,
		reconcile: (next) => true
	} };
	value.clock.set_timeout = (milliseconds, callback) => ({ cancel: () => true });
	return value;
};
function canonical_route(item) {
	let value = { family: item.family, table: item.table, kind: item.kind,
		destination: item.destination, device: item.device };
	if (item.kind == 'unreachable') { value.unreachable = true; value.metric = item.metric; }
	return value;
};
function canonical_rule(item) {
	return { family: item.family, priority: item.priority, mark: item.mark,
		mask: item.mask, table: item.table };
};
function manifest(routes, rules, transition) {
	return sprintf('%J\n', {
		version: 2, owner: 'miclash', protocol: 242,
		committed: {
			routes: map(routes ?? [], canonical_route), rules: map(rules ?? [], canonical_rule)
		},
		transition: transition ?? null
	});
};
function state(routes, rules) {
	let owned_routes = [], owned_rules = [];
	for (let item in routes ?? []) if (item.owned) push(owned_routes, canonical_route(item));
	for (let item in rules ?? []) if (item.owned) push(owned_rules, canonical_rule(item));
	return {
		routes: routes ?? [], rules: rules ?? [], interfaces: { 'clash-tun': false },
		ownership: {
			trusted: true,
			committed: { routes: owned_routes, rules: owned_rules },
			transition: null
		}
	};
};
function persistent_runtime(outputs, contents) {
	let value = runtime(outputs);
	for (let path, content in contents ?? {}) value.fs.writefile(path, content);
	return value;
};
function seed_manifest(value, routes, rules) {
	value.fs.writefile(MANIFEST_PATH, manifest(routes, rules));
	value.seed_kernel(routes, rules);
	return value;
};

let tproxy = desired({ proxy_mode: 'tproxy', ip_families: [ 'ipv4' ] }, { online: true });
assert_equal(encoded(tproxy.routes), encoded([ {
	family: 'ipv4', table: 100, kind: 'local', destination: 'default', device: 'lo', owned: true
} ]), 'TPROXY owns the accepted local table 100 route');
assert_equal(encoded(tproxy.rules), encoded([ {
	family: 'ipv4', priority: 1000, mark: '0x1', mask: '0xffffffff', table: 100, owned: true
} ]), 'TPROXY uses accepted mark/table/preference');

let tun_down = desired({ proxy_mode: 'tun', ip_families: [ 'ipv4' ] }, { 'clash-tun': false, online: false, ap_mode: true });
assert_equal(tun_down.routes[0].kind, 'local', 'offline/AP mode retains a safe prepared table');
let tun_up = desired({ proxy_mode: 'tun', ip_families: [ 'ipv4' ] }, { 'clash-tun': true, wan: [ 'eth0', 'wwan0' ] });
assert_equal(encoded(tun_up.routes[0]), encoded({
	family: 'ipv4', table: 100, kind: 'unicast', destination: 'default', device: 'clash-tun', owned: true
}), 'TUN appearance repairs table 100 independently of multiple WANs');

let mixed = desired({ proxy_mode: 'mixed', ip_families: [ 'ipv4', 'ipv6' ] }, { 'clash-tun': false });
assert_equal(length(mixed.routes), 4, 'MIXED creates v4/v6 TCP and UDP tables');
assert_true(!!mixed.routes[1].unreachable && mixed.routes[1].metric == 42760,
	'MIXED prepares the accepted bounded unreachable UDP route');
assert_equal(mixed.rules[1].mark, '0x3', 'MIXED splits UDP onto mark 0x3');

let already = state(tproxy.routes, tproxy.rules);
assert_equal(encoded(diff(tproxy, already)), encoded({
	remove_rules: [], remove_routes: [], add_routes: [], add_rules: [], conflicts: [],
	monitor: { enabled: false, present: false },
	ownership: {
		before: { routes: map(tproxy.routes, canonical_route), rules: map(tproxy.rules, canonical_rule) },
		after: { routes: map(tproxy.routes, canonical_route), rules: map(tproxy.rules, canonical_rule) }
	}
}), 'reconciliation is idempotent');

let foreign_exact = state([ { ...tproxy.routes[0], owned: false } ], [ { ...tproxy.rules[0], owned: false } ]);
assert_equal(length(diff(tproxy, foreign_exact).conflicts), 2,
	'exact foreign reserved entries are ambiguous and fail closed');

let conflict = state([ { ...tproxy.routes[0], kind: 'unicast', device: 'eth9', owned: false } ],
	[ { ...tproxy.rules[0], mark: '0x9', owned: false } ]);
let conflict_diff = diff(tproxy, conflict);
assert_true(length(conflict_diff.conflicts) == 2, 'foreign reserved rule and table conflicts fail closed');
let no_mutation = runtime();
assert_throws(() => apply(no_mutation, conflict_diff), 'INTERNAL');
assert_equal(length(no_mutation.process.calls), 0, 'conflicts are rejected before mutation');
let invalid_plan_runtime = runtime();
assert_throws(() => apply(invalid_plan_runtime, {
	remove_rules: [], remove_routes: [], add_rules: [], conflicts: [], monitor: { enabled: false, present: false },
	add_routes: [ tproxy.routes[0], { ...tproxy.routes[0], family: 'bad' } ]
}), 'INVALID_ARGUMENT');
assert_equal(length(invalid_plan_runtime.process.calls), 0,
	'the entire immutable plan is validated before its first route mutation');
let base_external_plan = diff(tproxy, state([], []));
let duplicate_plan_runtime = runtime();
assert_throws(() => apply(duplicate_plan_runtime, {
	...base_external_plan,
	add_routes: [ tproxy.routes[0], tproxy.routes[0] ]
}), 'INVALID_ARGUMENT');
assert_equal(length(duplicate_plan_runtime.process.calls), 0,
	'duplicate apply entries are rejected before mutation');
let invalid_remove_runtime = runtime();
assert_throws(() => apply(invalid_remove_runtime, {
	...base_external_plan,
	add_routes: [],
	remove_routes: [ { ...tproxy.routes[0], table: 101 } ]
}), 'INVALID_ARGUMENT');
assert_equal(length(invalid_remove_runtime.process.calls), 0,
	'the exact table/kind/device matrix applies to removals too');
let invalid_remove_rule_runtime = runtime();
assert_throws(() => apply(invalid_remove_rule_runtime, {
	...base_external_plan,
	add_routes: [], add_rules: [],
	remove_rules: [ { ...tproxy.rules[0], priority: 1001 } ]
}), 'INVALID_ARGUMENT');
assert_equal(length(invalid_remove_rule_runtime.process.calls), 0,
	'the exact table/priority/mark matrix applies to rule removals too');
let extra_field_runtime = runtime();
assert_throws(() => apply(extra_field_runtime, { ...base_external_plan, unexpected: true }),
	'INVALID_ARGUMENT');
assert_equal(length(extra_field_runtime.process.calls), 0,
	'unknown externally supplied plan fields are rejected');
let oversized_plan_runtime = runtime(), excessive_conflicts = [];
for (let i = 0; i < 17; i++) push(excessive_conflicts, { kind: 'ambiguous' });
assert_throws(() => apply(oversized_plan_runtime, {
	...base_external_plan, conflicts: excessive_conflicts
}), 'INVALID_ARGUMENT');
assert_equal(length(oversized_plan_runtime.process.calls), 0,
	'externally supplied apply arrays have fixed size bounds');
let orphan_action_runtime = runtime();
assert_throws(() => apply(orphan_action_runtime, {
	...base_external_plan,
	add_rules: [],
	ownership: {
		before: { routes: [], rules: [] },
		after: { routes: [], rules: [] }
	}
}), 'INVALID_ARGUMENT');
assert_equal(length(orphan_action_runtime.process.calls), 0,
	'an action outside the declared final ownership set is rejected');
let missing_action_runtime = runtime();
assert_throws(() => apply(missing_action_runtime, {
	...base_external_plan, add_routes: [], add_rules: []
}), 'INVALID_ARGUMENT');
assert_equal(length(missing_action_runtime.process.calls), 0,
	'a newly declared ownership tuple requires its exact add action');
let mismatched_before_runtime = persistent_runtime(null, {
	[MANIFEST_PATH]: manifest(tun_down.routes, tun_down.rules)
});
let prior_manifest = mismatched_before_runtime.fs.readfile(MANIFEST_PATH);
assert_throws(() => apply(mismatched_before_runtime, base_external_plan), 'INTERNAL');
assert_equal(length(mismatched_before_runtime.process.calls), 0,
	'an external plan cannot mutate when its before-set mismatches durable ownership');
assert_equal(mismatched_before_runtime.fs.readfile(MANIFEST_PATH), prior_manifest,
	'a mismatched external plan cannot rewrite the verified manifest');
let shadowed_conflict = state([
	{ ...tproxy.routes[0], owned: false },
	{ ...tproxy.routes[0], kind: 'unicast', device: 'eth9', owned: false }
], [
	{ ...tproxy.rules[0], owned: false },
	{ ...tproxy.rules[0], mark: '0x9', owned: false }
]);
assert_true(length(diff(tproxy, shadowed_conflict).conflicts) == 2,
	'an exact foreign satisfier cannot hide another reserved conflict');

let repair = diff(tun_up, state([ { ...tun_down.routes[0], owned: true } ], tun_down.rules));
assert_equal(length(repair.remove_routes), 0,
	'a same-table route type transition is one verified replace without a stale old-route delete');
let repaired = with_monitor(seed_manifest(runtime(), [ tun_down.routes[0] ], tun_down.rules), true);
apply(repaired, repair);
assert_equal(repaired.process.calls[0].args[1], 'route', 'route table is prepared before policy rules');
let route_add = -1, rule_add = -1, rule_del = -1, route_del = -1;
for (let i = 0; i < length(repaired.process.calls); i++) {
	let args = repaired.process.calls[i].args;
	if (args[1] == 'route' && args[2] == 'replace') route_add = i;
	if (args[1] == 'rule' && args[2] == 'add') rule_add = i;
	if (args[1] == 'rule' && args[2] == 'del') rule_del = i;
	if (args[1] == 'route' && args[2] == 'del') route_del = i;
}
assert_true(rule_add < 0 || route_add < rule_add, 'adding policy follows route preparation');
assert_true(rule_del < 0 || route_del < 0 || rule_del < route_del, 'removing rules precedes routes');
let replacement_runtime = runtime();
seed_manifest(replacement_runtime, tproxy.routes, [ mixed.rules[1] ]);
apply(replacement_runtime, diff(tproxy, state(tproxy.routes,
	[ mixed.rules[1] ])));
assert_equal(replacement_runtime.process.calls[0].args[2], 'add',
	'replacement policy is installed before the stale owned rule is retired');

let event_callback = null, subscriptions = [], reconciled = [], scheduled = [], sleeps = 0;
let monitored = runtime(), applying = false;
seed_manifest(monitored, tun_down.routes, tun_down.rules);
let removed_subscriptions = 0, cancelled_timers = 0;
monitored.observers = { routing: {
	subscribe: (callback) => {
		event_callback = callback; push(subscriptions, callback);
		callback({ interface: 'clash-tun', action: 'add' });
		return () => removed_subscriptions++;
	},
	condition: () => true,
	reconcile: (present) => {
		assert_true(!applying, 'monitor reconciliation never runs inline over outer apply');
		push(reconciled, present);
	}
} };
monitored.clock.set_timeout = (milliseconds, callback) => {
	let handle = { milliseconds, callback, active: true };
	handle.cancel = () => { if (handle.active) { handle.active = false; cancelled_timers++; } };
	push(scheduled, handle); return handle;
};
monitored.clock.sleep = () => sleeps++;
function fire_timer(handle) {
	if (!handle.active) return;
	handle.active = false;
	handle.callback();
};
applying = true;
apply(monitored, diff(tun_down, state(tun_down.routes, tun_down.rules)));
applying = false;
assert_equal(length(reconciled), 0, 'synchronous subscribe delivery is queued until apply returns');
let first_queue = null;
for (let handle in scheduled) if (handle.milliseconds == 0 && handle.active) first_queue = handle;
assert_true(first_queue != null, 'synchronous delivery schedules one zero-delay reconcile drain');
fire_timer(first_queue);
assert_equal(encoded(reconciled), encoded([ true ]), 'queued delivery reconciles after successful apply');

let first_callback = subscriptions[0];
first_callback({ interface: 'clash-tun', action: 'add' });
first_callback({ interface: 'clash-tun', action: 'remove' });
let cancelled_transition = null;
for (let handle in scheduled) if (handle.milliseconds == 0 && handle.active) cancelled_transition = handle;
fire_timer(cancelled_transition);
assert_equal(encoded(reconciled), encoded([ true ]),
	'coalesced add then remove returns to baseline without stale reconciliation');
first_callback({ interface: 'clash-tun', action: 'add' });
first_callback({ interface: 'clash-tun', action: 'ifup' });
let coalesced = 0, pending = null;
for (let handle in scheduled) if (handle.milliseconds == 0 && handle.active) { coalesced++; pending = handle; }
assert_equal(coalesced, 1, 'overlapping equivalent events coalesce into one in-flight drain');
let stale_queue = pending;
apply(monitored, diff(tun_down, state(tun_down.routes, tun_down.rules)));
assert_equal(removed_subscriptions, 1, 'idempotent apply replaces rather than leaks its event subscription');
fire_timer(stale_queue);
assert_equal(encoded(reconciled), encoded([ true ]), 'reapply invalidates a queued callback from the old epoch');

let active_callback = event_callback;
assert_throws(() => apply(monitored, conflict_diff), 'INTERNAL');
let scheduled_before_conflict_event = length(scheduled);
active_callback({ interface: 'clash-tun', action: 'add' });
assert_equal(length(scheduled), scheduled_before_conflict_event,
	'a conflicting reapply disarms the old epoch before failing closed');
assert_equal(sleeps, 0, 'TUN waiting never uses blocking sleep');
cleanup(monitored, state([], []));
assert_equal(removed_subscriptions, 2, 'cleanup disarms the active TUN event subscription');

let failed_monitor = with_monitor(runtime(), true), subscriptions_on_failure = 0;
seed_manifest(failed_monitor, [ tun_down.routes[0] ], tun_down.rules);
failed_monitor.observers.routing.subscribe = (callback) => {
	subscriptions_on_failure++; return () => true;
};
failed_monitor.process.run = (request) => { push(failed_monitor.process.calls, request); return { code: 1 }; };
assert_throws(() => apply(failed_monitor, repair), 'INTERNAL');
assert_equal(subscriptions_on_failure, 0, 'TUN monitoring arms only after every mutation succeeds');

let cleanup_callback = null, cleanup_reconciled = 0, cleanup_runtime = runtime();
seed_manifest(cleanup_runtime, tun_down.routes, tun_down.rules);
cleanup_runtime.observers = { routing: {
	subscribe: (callback) => { cleanup_callback = callback; return () => true; },
	condition: () => false,
	reconcile: (present) => { cleanup_reconciled++; cleanup(cleanup_runtime, state([], [])); }
} };
apply(cleanup_runtime, diff(tun_down, state(tun_down.routes, tun_down.rules)));
cleanup_callback({ interface: 'clash-tun', action: 'add' });
cleanup_runtime.clock.advance(0);
cleanup_callback({ interface: 'clash-tun', action: 'add' });
cleanup_runtime.clock.advance(0);
assert_equal(cleanup_reconciled, 1, 'cleanup during a callback invalidates the epoch before callback return');
let missing_monitor = runtime();
assert_throws(() => apply(missing_monitor, diff(tun_down, state(tun_down.routes, tun_down.rules))),
	'INVALID_ARGUMENT');
assert_equal(length(missing_monitor.process.calls), 0,
	'missing TUN event adapter fails before mutation instead of silently disabling repair');
let uncancellable_monitor = with_monitor(runtime(), true);
seed_manifest(uncancellable_monitor, tun_down.routes, tun_down.rules);
uncancellable_monitor.observers.routing.subscribe = (callback) => true;
assert_throws(() => apply(uncancellable_monitor,
	diff(tun_down, state(tun_down.routes, tun_down.rules))), 'INVALID_ARGUMENT');
assert_equal(length(uncancellable_monitor.process.calls), 0,
	'uncancellable TUN subscription cannot cause a kernel mutation');

let json_outputs = {
	'ip -j -4 rule show 2>/dev/null': '[{"priority":1000,"fwmark":"0x1","table":100,"protocol":242}]\n',
	'ip -j -4 route show table 100 2>/dev/null': '[{"type":"local","dst":"default","dev":"lo","table":100,"protocol":242}]\n',
	'ip -j -4 route show table 101 2>/dev/null': '[]\n',
	'ip -j -6 rule show 2>/dev/null': '[]\n',
	'ip -j -6 route show table 100 2>/dev/null': '[]\n',
	'ip -j -6 route show table 101 2>/dev/null': '[]\n',
	'ip -j link show dev clash-tun 2>/dev/null': '[]\n'
};
let observed_runtime = runtime(json_outputs);
let observed = observe(observed_runtime);
assert_true(!observed.routes[0].owned && observed.routes[0].ambiguous &&
	!observed.rules[0].owned && observed.rules[0].ambiguous,
	'protocol 242 without a trustworthy exact ownership manifest is ambiguous');
assert_true(length(diff(tproxy, observed).conflicts) > 0,
	'unmanifested protocol-242 state causes fail-closed zero-mutation reconciliation');
let manifested_runtime = persistent_runtime(json_outputs, {
	[MANIFEST_PATH]: manifest(tproxy.routes, tproxy.rules)
});
let manifested = observe(manifested_runtime);
assert_true(manifested.ownership.trusted && manifested.routes[0].owned && manifested.rules[0].owned,
	'exact canonical protocol-242 tuples are owned only when the verified manifest covers them');
let openwrt_manifest_runtime = persistent_runtime(json_outputs, {
	[MANIFEST_PATH]: manifest(tproxy.routes, tproxy.rules)
});
for (let path in [ '/tmp', '/tmp/run', '/tmp/run/miclash' ]) openwrt_manifest_runtime.fs.mkdir(path);
openwrt_manifest_runtime.fs.set_mode('/tmp', 0o1777);
let fake_realpath = openwrt_manifest_runtime.fs.realpath;
openwrt_manifest_runtime.fs.realpath = (path) => {
	let resolved = fake_realpath(path);
	if (resolved == '/var/run/miclash') return '/tmp/run/miclash';
	return resolved == MANIFEST_PATH ? '/tmp/run/miclash/routing-ownership.json' : resolved;
};
assert_true(observe(openwrt_manifest_runtime).ownership.trusted,
	'OpenWrt /var/run to /tmp/run canonicalization preserves manifest trust');
let mismatched_runtime = persistent_runtime(json_outputs, {
	[MANIFEST_PATH]: manifest([ { ...tproxy.routes[0], family: 'ipv6' } ], tproxy.rules)
});
assert_true(observe(mismatched_runtime).routes[0].ambiguous,
	'a canonical protocol-242 tuple outside the verified manifest remains ambiguous');
let corrupt_manifest_runtime = persistent_runtime(json_outputs, { [MANIFEST_PATH]: '{broken\n' });
assert_true(!observe(corrupt_manifest_runtime).ownership.trusted,
	'a corrupt persistent manifest fails closed instead of authorizing ownership');

let empty_outputs = { ...json_outputs,
	'ip -j -4 rule show 2>/dev/null': '[]\n',
	'ip -j -4 route show table 100 2>/dev/null': '[]\n'
};
let persistence_runtime = persistent_runtime({ ...empty_outputs });
let persistence_run = persistence_runtime.process.run;
persistence_runtime.process.run = (request) => {
	assert_true(type(persistence_runtime.fs.readfile(MANIFEST_PATH)) == 'string',
		'atomic ownership intent exists before the first kernel mutation');
	return persistence_run(request);
};
apply(persistence_runtime, diff(tproxy, observe(persistence_runtime)));
assert_equal(persistence_runtime.fs.readfile(MANIFEST_PATH), manifest(tproxy.routes, tproxy.rules),
	'success collapses the persistent transition journal to the exact final ownership tuples');

let partial_runtime = persistent_runtime({ ...empty_outputs });
partial_runtime.process.run = (request) => {
	push(partial_runtime.process.calls, request);
	return { code: 1 };
};
assert_throws(() => apply(partial_runtime, diff(tproxy, observe(partial_runtime))), 'INTERNAL');
let partial_doc = json(partial_runtime.fs.readfile(MANIFEST_PATH));
assert_equal(encoded(partial_doc.committed), encoded({ routes: [], rules: [] }),
	'a failed pre-state command never advances committed ownership');
assert_true(partial_doc.transition.action == 'replace' && !length(partial_doc.transition.pre),
	'a failed first mutation retains one exact retryable pre-state operation');
let restart_runtime = persistent_runtime({ ...empty_outputs }, {
	[MANIFEST_PATH]: partial_runtime.fs.readfile(MANIFEST_PATH)
});
let restarted = observe(restart_runtime);
assert_equal(restarted.ownership.transition_state, 'pre',
	'a daemon restart may retry only the exact persisted pre-state operation');
apply(restart_runtime, diff(tproxy, restarted));
assert_true(observe(restart_runtime).routes[0].owned,
	'a verified pre-state retry advances committed only after post-state proof');
assert_true(index(encoded(observed_runtime.process.calls), 'untrusted') < 0,
	'observation never relies on runtime.process.run stdout');
assert_equal(encoded(observed_runtime.captures),
	encoded(map(keys(json_outputs), (command) => CAPTURE_PREFIX + command)),
	'observation capture surface is fixed and bounded by an external kill deadline');

let text_absent_outputs = { ...json_outputs,
	'ip -j link show dev clash-tun 2>/dev/null': { output: '', status: 127 },
	'ip link show dev clash-tun 2>/dev/null': { output: '', status: 1 }
};
assert_true(!observe(runtime(text_absent_outputs)).interfaces['clash-tun'],
	'text link exit 1 with empty output is normal clash-tun absence when JSON is unavailable');
let text_present_outputs = { ...text_absent_outputs,
	'ip link show dev clash-tun 2>/dev/null': {
		output: '17: clash-tun: <POINTOPOINT,UP> mtu 9000 state UNKNOWN\n', status: 0
	}
};
assert_true(observe(runtime(text_present_outputs)).interfaces['clash-tun'],
	'text link fallback observes clash-tun presence');
text_present_outputs['ip link show dev clash-tun 2>/dev/null'] = { output: '', status: 1 };
assert_true(!observe(runtime(text_present_outputs)).interfaces['clash-tun'],
	'text link fallback observes later clash-tun disappearance without error');
let missing_table_outputs = { ...json_outputs,
	'ip -j -4 route show table 100 2>/dev/null': { output: '[', status: 2 },
	'ip -4 route show table 100 2>/dev/null': { output: '', status: 2 }
};
assert_equal(length(observe(runtime(missing_table_outputs)).routes), 0,
	'fixed route-table status 2 partial JSON and empty text mean table absence');

let text_outputs = { ...json_outputs,
	'ip -j -4 rule show 2>/dev/null': 'not-json\n',
	'ip -4 rule show 2>/dev/null': '1000:\tfrom all fwmark 0x1 lookup 100 proto 242\n'
};
let fallback_runtime = runtime(text_outputs);
assert_equal(observe(fallback_runtime).rules[0].priority, 1000,
	'strict text fallback parses reserved rules');
let masked_outputs = { ...json_outputs,
	'ip -j -4 rule show 2>/dev/null': '[{"priority":1000,"fwmark":"0x1","fwmask":"0xff","table":100,"protocol":242}]\n'
};
assert_true(length(diff(tproxy, observe(runtime(masked_outputs))).conflicts) > 0,
	'a broader masked protocol-242 rule is ambiguous and never adopted as owned');

let source_rule_outputs = { ...json_outputs,
	'ip -j -4 rule show 2>/dev/null':
		'[{"priority":1000,"src":"10.0.0.0/8","fwmark":"0x1","table":100,"protocol":242}]\n'
};
let source_rule = observe(persistent_runtime(source_rule_outputs, {
	[MANIFEST_PATH]: manifest(tproxy.routes, tproxy.rules)
}));
assert_true(source_rule.rules[0].ambiguous && !source_rule.rules[0].owned,
	'a source-specific reserved rule is relevant but never canonical ownership');
for (let selector in [ 'not', 'iif', 'oif', 'uidrange', 'action' ]) {
	let item = { priority: 1000, src: 'all', fwmark: '0x1', table: 100, protocol: 242 };
	item[selector] = selector == 'not' ? true : selector == 'action' ? 'goto' : 'foreign';
	let outputs = { ...json_outputs,
		'ip -j -4 rule show 2>/dev/null': sprintf('[%J]\n', item)
	};
	let parsed = observe(persistent_runtime(outputs, {
		[MANIFEST_PATH]: manifest(tproxy.routes, tproxy.rules)
	}));
	assert_true(parsed.rules[0].ambiguous && !parsed.rules[0].owned,
		'unknown relevant rule selector ' + selector + ' is ambiguous');
}

for (let attribute, value in {
	gateway: '192.0.2.1', metric: 7,
	multipath: [ { dev: 'eth9', weight: 1 } ], scope: 'link'
}) {
	let item = { type: 'local', dst: 'default', dev: 'lo', table: 100, protocol: 242 };
	item[attribute] = value;
	let outputs = { ...json_outputs,
		'ip -j -4 route show table 100 2>/dev/null': sprintf('[%J]\n', item)
	};
	let parsed = observe(persistent_runtime(outputs, {
		[MANIFEST_PATH]: manifest(tproxy.routes, tproxy.rules)
	}));
	assert_true(parsed.routes[0].ambiguous && !parsed.routes[0].owned,
		'noncanonical relevant route attribute ' + attribute + ' is ambiguous');
}
let type_outputs = { ...json_outputs,
	'ip -j -4 route show table 100 2>/dev/null':
		'[{"type":"throw","dst":"default","dev":"clash-tun","table":100,"protocol":242}]\n'
};
assert_true(observe(persistent_runtime(type_outputs, {
	[MANIFEST_PATH]: manifest(tun_up.routes, tun_up.rules)
})).routes[0].ambiguous, 'unknown route type is never inferred as unicast');

let ipv6_tproxy = desired({ proxy_mode: 'tproxy', ip_families: [ 'ipv6' ] }, {});
let ipv6_kernel_outputs = { ...json_outputs,
	'ip -j -4 rule show 2>/dev/null': '[]\n',
	'ip -j -4 route show table 100 2>/dev/null': '[]\n',
	'ip -j -6 rule show 2>/dev/null':
		'[{"priority":1000,"src":"all","fwmark":"0x1","table":100,"protocol":"242"}]\n',
	'ip -j -6 route show table 100 2>/dev/null':
		'[{"type":"local","dst":"default","dev":"lo","protocol":"242","metric":1024,"flags":[],"pref":"medium"}]\n'
};
assert_true(observe(persistent_runtime(ipv6_kernel_outputs, {
	[MANIFEST_PATH]: manifest(ipv6_tproxy.routes, ipv6_tproxy.rules)
})).routes[0].owned, 'exact kernel IPv6 metric 1024/pref medium normalizes to canonical local route');
let ipv6_text_outputs = { ...ipv6_kernel_outputs,
	'ip -j -6 route show table 100 2>/dev/null': 'not-json\n',
	'ip -6 route show table 100 2>/dev/null':
		'local default dev lo proto 242 metric 1024 pref medium\n'
};
assert_true(observe(persistent_runtime(ipv6_text_outputs, {
	[MANIFEST_PATH]: manifest(ipv6_tproxy.routes, ipv6_tproxy.rules)
})).routes[0].owned, 'text fallback accepts only the exact kernel IPv6 metric/preference defaults');
let ipv6_mixed = desired({ proxy_mode: 'mixed', ip_families: [ 'ipv6' ] }, { 'clash-tun': false });
let ipv6_unreachable_outputs = { ...ipv6_kernel_outputs,
	'ip -j -6 route show table 101 2>/dev/null':
		'[{"type":"unreachable","dst":"default","dev":"lo","protocol":"242","metric":42760,"flags":[],"pref":"medium"}]\n',
	'ip -j -6 rule show 2>/dev/null':
		'[{"priority":1000,"src":"all","fwmark":"0x1","table":100,"protocol":"242"},' +
		'{"priority":1001,"src":"all","fwmark":"0x3","table":101,"protocol":"242"}]\n'
};
assert_true(observe(persistent_runtime(ipv6_unreachable_outputs, {
	[MANIFEST_PATH]: manifest(ipv6_mixed.routes, ipv6_mixed.rules)
})).routes[1].owned, 'exact kernel IPv6 unreachable dev lo normalizes to canonical device-free tuple');
let ipv6_unreachable_text = { ...ipv6_unreachable_outputs,
	'ip -j -6 route show table 101 2>/dev/null': 'not-json\n',
	'ip -6 route show table 101 2>/dev/null':
		'unreachable default dev lo proto 242 metric 42760 pref medium\n'
};
assert_true(observe(persistent_runtime(ipv6_unreachable_text, {
	[MANIFEST_PATH]: manifest(ipv6_mixed.routes, ipv6_mixed.rules)
})).routes[1].owned, 'text fallback normalizes exact kernel IPv6 unreachable dev lo shape');

let alias_outputs = { ...json_outputs,
	'ip -j -4 rule show 2>/dev/null':
		'[{"priority":1000,"src":"all","fwmark":"0x1","table":"miclash_tproxy","protocol":"miclash"}]\n',
	'ip -j -4 route show table 100 2>/dev/null':
		'[{"type":"local","dst":"default","dev":"lo","table":"miclash_tproxy","protocol":"miclash"}]\n'
};
let aliased = observe(persistent_runtime(alias_outputs, {
	[MANIFEST_PATH]: manifest(tproxy.routes, tproxy.rules)
}));
assert_true(aliased.rules[0].owned && aliased.routes[0].owned,
	'exact reserved table/protocol aliases normalize to numeric 100 and 242');
let mixed_v4 = desired({ proxy_mode: 'mixed', ip_families: [ 'ipv4' ] }, { 'clash-tun': false });
let alias_101_outputs = { ...json_outputs,
	'ip -j -4 rule show 2>/dev/null':
		'[{"priority":1000,"src":"all","fwmark":"0x1","table":"miclash_tproxy","protocol":"miclash"},' +
		'{"priority":1001,"src":"all","fwmark":"0x3","table":"miclash_mixed","protocol":"miclash"}]\n',
	'ip -j -4 route show table 100 2>/dev/null':
		'[{"type":"local","dst":"default","dev":"lo","table":"miclash_tproxy","protocol":"miclash"}]\n',
	'ip -j -4 route show table 101 2>/dev/null':
		'[{"type":"unreachable","dst":"default","metric":42760,"table":"miclash_mixed","protocol":"miclash"}]\n'
};
let aliased_101 = observe(persistent_runtime(alias_101_outputs, {
	[MANIFEST_PATH]: manifest(mixed_v4.routes, mixed_v4.rules)
}));
assert_true(aliased_101.routes[1].owned && aliased_101.rules[1].owned,
	'exact reserved table alias miclash_mixed normalizes to numeric 101');

let strict_text_outputs = { ...json_outputs,
	'ip -j -4 route show table 100 2>/dev/null': 'not-json\n',
	'ip -4 route show table 100 2>/dev/null':
		'local default dev lo proto 242 gateway 192.0.2.1\n'
};
assert_true(observe(persistent_runtime(strict_text_outputs, {
	[MANIFEST_PATH]: manifest(tproxy.routes, tproxy.rules)
})).routes[0].ambiguous, 'text route parser rejects unexpected gateway/metric/multipath suffixes');

let alias_text_outputs = { ...json_outputs,
	'ip -j -4 rule show 2>/dev/null': 'not-json\n',
	'ip -4 rule show 2>/dev/null':
		'1000:\tfrom all fwmark 0x1 lookup miclash_tproxy proto miclash\n',
	'ip -j -4 route show table 100 2>/dev/null': 'not-json\n',
	'ip -4 route show table 100 2>/dev/null':
		'local default dev lo proto miclash\n'
};
let text_aliased = observe(persistent_runtime(alias_text_outputs, {
	[MANIFEST_PATH]: manifest(tproxy.routes, tproxy.rules)
}));
assert_true(text_aliased.rules[0].owned && text_aliased.routes[0].owned,
	'text aliases normalize only through the exact packaged reservations');

let failed_capture = runtime(json_outputs);
failed_capture.fs.popen = (command) => ({ read: () => '', close: () => 127 });
assert_throws(() => observe(failed_capture), 'INTERNAL');

let owned_state = state(tproxy.routes, tproxy.rules);
let clean_runtime = runtime();
seed_manifest(clean_runtime, tproxy.routes, tproxy.rules);
cleanup(clean_runtime, owned_state);
assert_equal(clean_runtime.process.calls[0].args[1], 'rule', 'cleanup removes owned rules first');
assert_equal(clean_runtime.process.calls[1].args[1], 'route', 'cleanup then removes owned routes');
let foreign_state = state([ { ...tproxy.routes[0], owned: false } ], [ { ...tproxy.rules[0], owned: false } ]);
let foreign_runtime = runtime();
cleanup(foreign_runtime, foreign_state);
assert_equal(length(foreign_runtime.process.calls), 0, 'cleanup never removes foreign lookalikes');
let forged_cleanup_runtime = runtime();
cleanup(forged_cleanup_runtime, owned_state);
assert_equal(length(forged_cleanup_runtime.process.calls), 0,
	'caller-supplied owned flags are ignored and cannot authorize cleanup without the verified manifest');

let oversized = runtime();
let too_large = '';
for (let i = 0; i < 70; i++) too_large += sprintf('%01000d', i);
let oversized_closed = 0, oversized_reads = 0, oversized_command = null;
oversized.fs.popen = (command) => {
	oversized_command = command;
	let source = pipe(too_large);
	return {
		read: (amount) => { oversized_reads++; return source.read(amount); },
		close: () => { oversized_closed++; return source.close(); }
	};
};
assert_throws(() => observe(oversized), 'INTERNAL');
assert_true(substr(oversized_command, 0, length(CAPTURE_PREFIX)) == CAPTURE_PREFIX,
	'every fixed producer runs under the hard two-second kill deadline');
assert_equal(oversized_closed, 1, 'oversize capture always closes and reaps its producer');
assert_true(oversized_reads > 16, 'oversize capture drains the producer while retaining fixed memory');
