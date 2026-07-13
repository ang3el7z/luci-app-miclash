import { assert_equal, assert_true } from './testlib.uc';
import { desired, observe, diff } from 'miclash.routing';
import { committed, empty_outputs, runtime, seed, set_route_json, set_rule_json, transition } from './routing-rereview-testlib.uc';

let local = desired({ proxy_mode: 'tproxy', ip_families: [ 'ipv4' ] }, {});
let tun = desired({ proxy_mode: 'tun', ip_families: [ 'ipv4' ] }, { 'clash-tun': true });
let next = committed(tun.routes, local.rules);
let retired = [ committed(local.routes, []).routes[0] ];
let op = transition('route', 'replace', next.routes[0], retired, retired, [ next.routes[0] ], next);

let pre_outputs = empty_outputs();
set_route_json(pre_outputs, local.routes[0]);
set_rule_json(pre_outputs, local.rules[0]);
let pre_runtime = seed(runtime(pre_outputs), local.routes, local.rules, op);
let pre = observe(pre_runtime);
assert_true(pre.ownership.trusted && pre.ownership.transition_state == 'pre',
	'a verified transition pre-state is retryable: ' + sprintf('%J', pre.ownership) +
	' manifest=' + pre_runtime.fs.files['/var/run/miclash/routing-ownership.json']);
assert_true(pre.routes[0].owned, 'only the committed pre-state authorizes ownership');

let post_outputs = empty_outputs();
set_route_json(post_outputs, tun.routes[0]);
set_rule_json(post_outputs, local.rules[0]);
let post = observe(seed(runtime(post_outputs), local.routes, local.rules, op));
assert_equal(post.ownership.transition_state, 'post',
	'a crash after kernel success is recognized as uncommitted post-state');
assert_true(post.routes[0].ambiguous && !post.routes[0].owned,
	'a pending transition target never authorizes ownership after restart');

let disappeared_outputs = empty_outputs();
set_rule_json(disappeared_outputs, local.rules[0]);
let disappeared = observe(seed(runtime(disappeared_outputs), tun.routes, local.rules));
assert_true(!disappeared.routes[0]?.ambiguous &&
	disappeared.ownership.verified_absent.routes[0].device == 'clash-tun',
	'an exact committed clash-tun route is verified absent only when fresh link observation is absent');
assert_equal(length(diff(local, disappeared).conflicts), 0,
	'exact interface-driven TUN disappearance is repairable before watcher intent exists');

let foreign_deleted_outputs = empty_outputs();
set_rule_json(foreign_deleted_outputs, local.rules[0]);
let foreign_deleted = observe(seed(runtime(foreign_deleted_outputs), local.routes, local.rules));
assert_true(foreign_deleted.routes[0].ambiguous,
	'foreign deletion of a non-TUN committed route remains ambiguous even when clash-tun is absent');

let mixed_down = desired({ proxy_mode: 'mixed', ip_families: [ 'ipv4' ] }, { 'clash-tun': false });
let mixed_up = desired({ proxy_mode: 'mixed', ip_families: [ 'ipv4' ] }, { 'clash-tun': true });
let mixed_observed = {
	routes: map(mixed_down.routes, (item) => ({ ...item, protocol: 242 })),
	rules: map(mixed_down.rules, (item) => ({ ...item, protocol: 242 })),
	interfaces: { 'clash-tun': true },
	ownership: { trusted: true, committed: committed(mixed_down.routes, mixed_down.rules), transition: null }
};
let mixed_plan = diff(mixed_up, mixed_observed);
assert_equal(length(mixed_plan.add_routes), 1,
	'table101 type transition first adds the new route');
assert_equal(length(mixed_plan.remove_routes), 1,
	'table101 type transition retains an explicit verified deletion after additive replace');
