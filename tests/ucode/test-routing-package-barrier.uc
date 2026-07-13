import { assert_equal, assert_throws, assert_true } from './testlib.uc';
import { desired, observe, diff, apply, cleanup } from 'miclash.routing';
import { empty_outputs, runtime, seed, set_route_json, set_rule_json } from './routing-rereview-testlib.uc';

const BARRIER = '/var/run/miclash/package-removal';

function establish_barrier(value) {
	value.fs.mkdir(BARRIER);
	value.fs.set_mode(BARRIER, 0o700);
};

let wanted = desired({ proxy_mode: 'tproxy', ip_families: [ 'ipv4' ] }, {});
let blocked = runtime(empty_outputs());
let plan = diff(wanted, observe(blocked));
establish_barrier(blocked);
let blocked_error = null;
try { apply(blocked, plan); } catch (error) { blocked_error = error; }
assert_equal(blocked_error?.code ?? blocked_error?.message, 'BUSY');
assert_equal(length(blocked.process.calls), 0,
	'apply performs zero routing mutation once package removal is established');

let cleanup_outputs = empty_outputs();
set_route_json(cleanup_outputs, wanted.routes[0]);
set_rule_json(cleanup_outputs, wanted.rules[0]);
let ordinary = seed(runtime(cleanup_outputs), wanted.routes, wanted.rules);
establish_barrier(ordinary);
assert_throws(() => cleanup(ordinary), 'BUSY');
assert_equal(length(ordinary.process.calls), 0,
	'ordinary cleanup cannot bypass package-removal exclusion');

let dedicated_outputs = empty_outputs();
set_route_json(dedicated_outputs, wanted.routes[0]);
set_rule_json(dedicated_outputs, wanted.rules[0]);
let dedicated = seed(runtime(dedicated_outputs), wanted.routes, wanted.rules);
establish_barrier(dedicated);
dedicated.package_removal_cleanup = true;
dedicated.package_removal_preserve_manifest = true;
dedicated.process.run = (request) => {
	push(dedicated.process.calls, request);
	if (request.args[1] == 'rule') dedicated_outputs['ip -j -4 rule show 2>/dev/null'] = '[]\n';
	if (request.args[1] == 'route') dedicated_outputs['ip -j -4 route show table 100 2>/dev/null'] = '[]\n';
	return { code: 0 };
};
cleanup(dedicated);
assert_equal(length(dedicated.process.calls), 2,
	'the fixed internal package cleanup capability may retire exact committed tuples');
assert_true(dedicated.fs.lstat('/var/run/miclash/routing-ownership.json')?.type == 'file',
	'package cleanup retains an empty trusted manifest until every later prerm step succeeds');

let tun = desired({ proxy_mode: 'tun', ip_families: [ 'ipv4' ] }, { 'clash-tun': true });
let watch_outputs = empty_outputs();
set_route_json(watch_outputs, tun.routes[0]);
set_rule_json(watch_outputs, tun.rules[0]);
watch_outputs['ip -j link show dev clash-tun 2>/dev/null'] = '[{"ifname":"clash-tun"}]\n';
let watched = seed(runtime(watch_outputs), tun.routes, tun.rules), callback = null, reconciled = 0;
watched.observers = { routing: {
	subscribe: (fn) => { callback = fn; return () => true; },
	condition: () => true,
	reconcile: (present) => reconciled++
} };
apply(watched, diff(tun, observe(watched)));
assert_true(type(callback) == 'function', 'successful TUN apply arms a watcher before removal');
establish_barrier(watched);
callback({ interface: 'clash-tun', action: 'remove' });
watched.clock.advance(0);
assert_equal(reconciled, 0, 'watch callbacks perform no reconciliation after barrier establishment');
assert_true(watched.routing_monitor == null, 'barrier observation permanently disarms the stale watcher');
