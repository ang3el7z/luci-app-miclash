import { assert_equal, assert_throws, assert_true } from './testlib.uc';
import { desired, observe, diff, apply, cleanup } from 'miclash.routing';
import { empty_outputs, manifest, runtime, seed, set_route_json, set_rule_json, MANIFEST_PATH } from './routing-rereview-testlib.uc';

let wanted = desired({ proxy_mode: 'tproxy', ip_families: [ 'ipv4' ] }, {});

let changing_outputs = empty_outputs();
let changing = runtime(changing_outputs);
let stale_plan = diff(wanted, observe(changing));
set_route_json(changing_outputs, wanted.routes[0]);
assert_throws(() => apply(changing, stale_plan), 'INTERNAL');
assert_equal(length(changing.process.calls), 0,
	'apply fresh-observes and performs zero mutation when the supplied complete diff became stale');

let cleanup_outputs = empty_outputs();
set_route_json(cleanup_outputs, wanted.routes[0]);
set_rule_json(cleanup_outputs, wanted.rules[0]);
let cleanup_runtime = seed(runtime(cleanup_outputs), wanted.routes, wanted.rules);
cleanup_runtime.process.run = (request) => {
	push(cleanup_runtime.process.calls, request);
	if (request.args[1] == 'rule' && request.args[2] == 'del')
		cleanup_outputs['ip -j -4 rule show 2>/dev/null'] = '[]\n';
	if (request.args[1] == 'route' && request.args[2] == 'del')
		cleanup_outputs['ip -j -4 route show table 100 2>/dev/null'] = '[]\n';
	return { code: 0 };
};
cleanup(cleanup_runtime, { routes: [], rules: [] });
assert_equal(length(cleanup_runtime.process.calls), 2,
	'cleanup ignores an incomplete caller snapshot and fresh-deletes every committed tuple');
assert_true(!cleanup_runtime.fs.exists(MANIFEST_PATH),
	'cleanup deletes the manifest only after every committed tuple is proven absent');

let missing = seed(runtime(empty_outputs()), wanted.routes, wanted.rules);
let saved = missing.fs.files[MANIFEST_PATH];
assert_throws(() => cleanup(missing, { routes: [], rules: [] }), 'INTERNAL');
assert_equal(missing.fs.files[MANIFEST_PATH], saved,
	'cleanup preserves committed ownership when a tuple vanished without a verified transition');
assert_equal(length(missing.process.calls), 0,
	'a missing committed tuple is ambiguous and cleanup performs zero mutation');

let tun = desired({ proxy_mode: 'tun', ip_families: [ 'ipv4' ] }, { 'clash-tun': true });
let disappeared_outputs = empty_outputs();
set_rule_json(disappeared_outputs, tun.rules[0]);
let disappeared = seed(runtime(disappeared_outputs), tun.routes, tun.rules);
disappeared.process.run = (request) => {
	push(disappeared.process.calls, request);
	if (request.args[1] == 'rule') disappeared_outputs['ip -j -4 rule show 2>/dev/null'] = '[]\n';
	return { code: 0 };
};
cleanup(disappeared);
assert_equal(length(disappeared.process.calls), 1,
	'cleanup retires a fresh-verified absent clash-tun route without a meaningless kernel delete');
assert_equal(disappeared.process.calls[0].args[1], 'rule',
	'verified-absence cleanup still removes the committed policy rule first');
