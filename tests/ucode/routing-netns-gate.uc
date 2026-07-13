import { assert_equal, assert_true } from './testlib.uc';
import { desired, observe, diff, apply, cleanup } from 'miclash.routing';

let fs = require('fs');
let runtime = {
	fs: { popen: (command, mode) => fs.popen(command, mode) },
	process: { run: (request) => ({ code: system([ request.command, ...request.args ]) }) },
	observers: { routing: {
		subscribe: (callback) => ({ remove: () => true }),
		condition: () => true,
		reconcile: (present) => true
	} },
	clock: { set_timeout: (milliseconds, callback) => ({ cancel: () => true }) }
};

let initial = observe(runtime);
let wanted = desired({ proxy_mode: 'tproxy', ip_families: [ 'ipv4', 'ipv6' ] }, initial.interfaces);
apply(runtime, diff(wanted, initial));
let installed = observe(runtime);
assert_equal(length(diff(wanted, installed).conflicts), 0, 'real kernel state is unambiguous');
assert_equal(length(diff(wanted, installed).add_routes), 0, 'real routes reconcile idempotently');
assert_equal(length(diff(wanted, installed).add_rules), 0, 'real rules reconcile idempotently');

assert_equal(system([ 'ip', 'link', 'add', 'clash-tun', 'type', 'dummy' ]), 0,
	'isolated namespace can create clash-tun');
assert_equal(system([ 'ip', 'link', 'set', 'clash-tun', 'up' ]), 0,
	'isolated namespace can raise clash-tun');
let tun_wanted = desired({ proxy_mode: 'tun', ip_families: [ 'ipv4', 'ipv6' ] }, { 'clash-tun': true });
apply(runtime, diff(tun_wanted, observe(runtime)));
assert_equal(length(diff(tun_wanted, observe(runtime)).add_routes), 0,
	'existing clash-tun route repair survives a real lifecycle');

cleanup(runtime);
let final_state = observe(runtime);
for (let item in [ ...final_state.routes, ...final_state.rules ])
	assert_true(!item.owned, 'real cleanup leaves no MiClash-owned entry');
