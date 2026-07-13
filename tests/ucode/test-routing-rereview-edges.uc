import { assert_equal, assert_throws, assert_true } from './testlib.uc';
import { desired, observe, diff, apply } from 'miclash.routing';
import { empty_outputs, runtime, seed, set_route_json, set_rule_json } from './routing-rereview-testlib.uc';

let wanted = desired({ proxy_mode: 'tproxy', ip_families: [ 'ipv4' ] }, {});
let partial_outputs = empty_outputs();
partial_outputs['ip -j -4 route show table 100 2>/dev/null'] = { output: '[', status: 2 };
partial_outputs['ip -4 route show table 100 2>/dev/null'] =
	'local default dev lo proto 242 scope host\n';
set_rule_json(partial_outputs, wanted.rules[0]);
let partial = observe(seed(runtime(partial_outputs), wanted.routes, wanted.rules));
assert_equal(partial.routes[0].kind, 'local',
	'a status-2 partial JSON document requires authoritative text fallback confirmation');
assert_true(partial.routes[0].owned, 'text-confirmed committed route remains owned');

let cancel_outputs = empty_outputs();
let cancelling = runtime(cancel_outputs), timer_cancelled = 0, drain_cancelled = 0;
cancelling.routing_monitor_epoch = 7;
cancelling.routing_monitor = {
	active: true, epoch: 7,
	callback: () => { cancelling.process.run({ command: 'ip', args: [ '-4', 'route', 'flush', 'table', '100' ] }); },
	subscription: { remove: () => die('remove failed') },
	timer: { cancel: () => timer_cancelled++ },
	drain: { cancel: () => drain_cancelled++ }
};
let conflicting = diff(wanted, observe(cancelling));
push(conflicting.conflicts, { kind: 'forced' });
assert_throws(() => apply(cancelling, conflicting), 'INTERNAL');
assert_equal(timer_cancelled, 1, 'timer cancellation is attempted even when subscription removal throws');
assert_equal(drain_cancelled, 1, 'drain cancellation is attempted even when another cancellation throws');
assert_true(cancelling.routing_monitor == null && cancelling.routing_monitor_epoch > 7,
	'watcher is made stale before exception-safe handle cancellation');
cancelling.routing_monitor?.callback();
assert_equal(length(cancelling.process.calls), 0, 'stale callback remains inert after cancellation errors');

let recipe = require('fs').readfile('luci-app-miclash/Makefile');
assert_true(index(recipe, '/usr/share/miclash/routing-cleanup.uc') >= 0 &&
	index(recipe, 'define Package/$(PKG_NAME)/prerm') < index(recipe, 'routing-cleanup.uc'),
	'package prerm invokes ownership-aware cleanup while module and reservations still exist');
assert_true(index(recipe, 'routing-cleanup.uc') < index(recipe, 'define Package/$(PKG_NAME)/postrm'),
	'ownership cleanup occurs before postrm removes package files');
assert_true(index(recipe, 'full_cleanup >/dev/null') < 0,
	'package lifecycle never invokes legacy whole-table routing teardown');
