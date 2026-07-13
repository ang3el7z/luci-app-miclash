import { assert_equal, assert_throws, assert_true } from './testlib.uc';
import { desired, observe, diff, apply, cleanup } from 'miclash.routing';

function encoded(value) { return sprintf('%J', value); };
function pipe(value) {
	let offset = 0;
	return {
		read: (amount) => { let chunk = substr(value, offset, amount); offset += length(chunk); return chunk; },
		close: () => 0
	};
};
function runtime(outputs) {
	let calls = [], captures = [];
	return {
		process: { calls, run: (request) => { push(calls, request); return { code: 0, stdout: 'untrusted' }; } },
		fs: { popen: (command, mode) => { push(captures, command); return pipe(outputs?.[command] ?? '[]\n'); } },
		captures
	};
};
function with_monitor(value, present) {
	value.observers = { routing: {
		subscribe: (callback) => ({ remove: () => true }),
		condition: () => present,
		reconcile: (next) => true
	} };
	value.clock = { set_timeout: (milliseconds, callback) => ({ cancel: () => true }) };
	return value;
};
function state(routes, rules) { return { routes: routes ?? [], rules: rules ?? [], interfaces: { 'clash-tun': false } }; };

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
	monitor: { enabled: false, present: false }
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
let repaired = with_monitor(runtime(), true);
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
apply(replacement_runtime, diff(tproxy, state(tproxy.routes,
	[ { ...tproxy.rules[0], mark: '0x9', owned: true } ])));
assert_equal(replacement_runtime.process.calls[0].args[2], 'add',
	'replacement policy is installed before the stale owned rule is retired');

let event_callback = null, reconciled = [], timer_callbacks = [], sleeps = 0;
let monitored = runtime();
let removed_subscriptions = 0, cancelled_timers = 0;
monitored.observers = { routing: {
	subscribe: (callback) => { event_callback = callback; return () => removed_subscriptions++; },
	condition: () => true,
	reconcile: (present) => push(reconciled, present)
} };
monitored.clock = {
	set_timeout: (milliseconds, callback) => { push(timer_callbacks, callback); return { cancel: () => cancelled_timers++ }; },
	sleep: () => sleeps++
};
apply(monitored, diff(tun_down, state(tun_down.routes, tun_down.rules)));
apply(monitored, diff(tun_down, state(tun_down.routes, tun_down.rules)));
assert_equal(removed_subscriptions, 1, 'idempotent apply replaces rather than leaks its event subscription');
assert_equal(cancelled_timers, 1, 'idempotent apply cancels its prior polling chain');
event_callback({ interface: 'clash-tun', action: 'add' });
assert_equal(encoded(reconciled), encoded([ true ]), 'uloop network event triggers TUN route reconciliation');
assert_true(length(timer_callbacks) == 2, 'event subscription also arms bounded condition polling fallback');
timer_callbacks[1]();
assert_equal(encoded(reconciled), encoded([ true, true ]), 'condition fallback repairs a missed TUN event');
assert_equal(sleeps, 0, 'TUN waiting never uses blocking sleep');
cleanup(monitored, state([], []));
assert_equal(removed_subscriptions, 2, 'cleanup disarms the active TUN event subscription');
assert_equal(cancelled_timers, 2, 'cleanup cancels the active TUN polling timer');
let missing_monitor = runtime();
assert_throws(() => apply(missing_monitor, diff(tun_down, state(tun_down.routes, tun_down.rules))),
	'INVALID_ARGUMENT');
assert_equal(length(missing_monitor.process.calls), 0,
	'missing TUN event adapter fails before mutation instead of silently disabling repair');
let uncancellable_monitor = with_monitor(runtime(), true);
uncancellable_monitor.observers.routing.subscribe = (callback) => true;
assert_throws(() => apply(uncancellable_monitor, repair), 'INVALID_ARGUMENT');
assert_equal(length(uncancellable_monitor.process.calls), 0,
	'uncancellable TUN subscription fails before the first route mutation');

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
assert_true(observed.routes[0].owned && observed.rules[0].owned,
	'structured observation recognizes protocol-tagged ownership');
assert_true(index(encoded(observed_runtime.process.calls), 'untrusted') < 0,
	'observation never relies on runtime.process.run stdout');
assert_equal(encoded(observed_runtime.captures), encoded(keys(json_outputs)),
	'observation capture surface is fixed and bounded');

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
assert_equal(length(diff(tproxy, observe(runtime(masked_outputs))).add_rules), 1,
	'a broader masked owned rule never appears exact to the full-width desired mark');

let failed_capture = runtime(json_outputs);
failed_capture.fs.popen = (command) => ({ read: () => '', close: () => 127 });
assert_throws(() => observe(failed_capture), 'INTERNAL');

let owned_state = state(tproxy.routes, tproxy.rules);
let clean_runtime = runtime();
cleanup(clean_runtime, owned_state);
assert_equal(clean_runtime.process.calls[0].args[1], 'rule', 'cleanup removes owned rules first');
assert_equal(clean_runtime.process.calls[1].args[1], 'route', 'cleanup then removes owned routes');
let foreign_state = state([ { ...tproxy.routes[0], owned: false } ], [ { ...tproxy.rules[0], owned: false } ]);
let foreign_runtime = runtime();
cleanup(foreign_runtime, foreign_state);
assert_equal(length(foreign_runtime.process.calls), 0, 'cleanup never removes foreign lookalikes');

let oversized = runtime();
let too_large = '';
for (let i = 0; i < 70; i++) too_large += sprintf('%01000d', i);
oversized.fs.popen = () => pipe(too_large);
assert_throws(() => observe(oversized), 'INTERNAL');
