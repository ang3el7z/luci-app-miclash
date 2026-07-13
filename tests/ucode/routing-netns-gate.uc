import { assert_equal, assert_throws, assert_true } from './testlib.uc';
import { desired, observe, diff, apply, cleanup } from 'miclash.routing';
import * as production from 'miclash.runtime';

function raw(command) {
	let pipe = require('fs').popen(command, 'r'), output = '';
	while (true) { let chunk = pipe.read(4096); if (!length(chunk ?? '')) break; output += chunk; }
	let status = pipe.close();
	return { status, output };
};

function new_runtime() {
	let runtime = production.create();
	// Ubuntu resolves /var/run through /run; OpenWrt 24.10 resolves the same
	// packaged runtime path through /tmp/run. Preserve real identities while
	// presenting the target's canonical pathname to storage validation.
	let host_realpath = runtime.fs.realpath;
	runtime.fs.realpath = (path) => {
		let resolved = host_realpath(path);
		return resolved == '/run/miclash' ||
			substr(resolved ?? '', 0, length('/run/miclash/')) == '/run/miclash/'
			? '/tmp' + resolved : resolved;
	};
	runtime.clock = {
		now: () => time() * 1000,
		set_timeout: (milliseconds, callback) => ({ cancel: () => true })
	};
	runtime.observers.routing = {
		subscribe: (callback) => ({ remove: () => true }),
		condition: () => observe(runtime).interfaces['clash-tun'],
		reconcile: (present) => true
	};
	return runtime;
};

let runtime = new_runtime();
let initial = observe(runtime);
let wanted = desired({ proxy_mode: 'tproxy', ip_families: [ 'ipv4', 'ipv6' ] }, initial.interfaces);
apply(runtime, diff(wanted, initial));
let installed = observe(runtime);
let installed_diff = diff(wanted, installed);
assert_equal(length(installed_diff.conflicts), 0,
	'real kernel state is unambiguous: ownership=' + sprintf('%J', installed.ownership) +
	' stat=' + sprintf('%J', runtime.fs.lstat('/var/run/miclash/routing-ownership.json')) +
	' realpath=' + sprintf('%J', runtime.fs.realpath('/var/run/miclash/routing-ownership.json')) +
	' manifest=' + sprintf('%J', runtime.fs.readfile('/var/run/miclash/routing-ownership.json')) +
	' ipv6-route=' + sprintf('%J', raw('ip -j -6 route show table 100')) +
	' diff=' + sprintf('%J', installed_diff));
assert_equal(length(installed_diff.add_routes), 0, 'real routes reconcile idempotently');
assert_equal(length(installed_diff.add_rules), 0, 'real rules reconcile idempotently');

let mixed_down = desired({ proxy_mode: 'mixed', ip_families: [ 'ipv4', 'ipv6' ] }, { 'clash-tun': false });
apply(runtime, diff(mixed_down, observe(runtime)));
assert_equal(length(diff(mixed_down, observe(runtime)).add_routes), 0,
	'real MIXED tables install with unreachable UDP fallback');

assert_equal(system([ 'ip', 'link', 'add', 'clash-tun', 'type', 'dummy' ]), 0,
	'isolated namespace can create clash-tun');
assert_equal(system([ 'ip', 'link', 'set', 'clash-tun', 'up' ]), 0,
	'isolated namespace can raise clash-tun');
let mixed_up = desired({ proxy_mode: 'mixed', ip_families: [ 'ipv4', 'ipv6' ] }, { 'clash-tun': true });
let mixed_up_observed = observe(runtime), mixed_up_plan = diff(mixed_up, mixed_up_observed);
assert_equal(length(mixed_up_plan.conflicts), 0,
	'real MIXED transition is unambiguous: v4=' + sprintf('%J', raw('ip -j -4 route show table 101')) +
	' v6=' + sprintf('%J', raw('ip -j -6 route show table 101')) +
	' plan=' + sprintf('%J', mixed_up_plan));
apply(runtime, mixed_up_plan);
assert_true(runtime.routing_monitor != null, 'successful TUN-capable apply owns one live watcher epoch');
assert_equal(length(diff(mixed_up, observe(runtime)).add_routes), 0,
	'real MIXED UDP table follows clash-tun');

assert_equal(system([ 'ip', 'link', 'delete', 'clash-tun' ]), 0,
	'isolated namespace can remove clash-tun');
let disappeared = observe(runtime);
assert_true(!disappeared.interfaces['clash-tun'], 'real observer sees TUN disappearance');
let disappearance_plan = diff(mixed_down, disappeared);
assert_equal(length(disappearance_plan.conflicts), 0,
	'real TUN disappearance is unambiguous: v4=' + sprintf('%J', raw('ip -j -4 route show table 101')) +
	' v6=' + sprintf('%J', raw('ip -j -6 route show table 101')) +
	' plan=' + sprintf('%J', disappearance_plan));
apply(runtime, disappearance_plan);
assert_equal(length(diff(mixed_down, observe(runtime)).add_routes), 0,
	'real TUN disappearance repairs MIXED to unreachable fallback');

// A new runtime simulates daemon restart. Exact manifest tuples, not protocol
// 242 alone, are the only ownership proof across the restart.
let restarted = new_runtime();
let after_restart = observe(restarted);
assert_true(after_restart.ownership.trusted, 'restart reloads the durable routing manifest');
for (let item in [ ...after_restart.routes, ...after_restart.rules ])
	assert_true(!item.ambiguous, 'manifest-covered restart state remains canonical');

cleanup(restarted);
assert_true(restarted.routing_monitor == null, 'cleanup invalidates the live watcher epoch');

// Fail after the first successful kernel mutation. The transition journal
// authorizes exactly that partial state so a fresh runtime can retry safely.
let failing = new_runtime(), real_run = failing.process.run, run_count = 0;
failing.process.run = (request) => {
	run_count++;
	if (run_count == 2) return { code: 1, stdout: null, stderr: null };
	return real_run(request);
};
let retry_wanted = desired({ proxy_mode: 'tproxy', ip_families: [ 'ipv4' ] }, {});
assert_throws(() => apply(failing, diff(retry_wanted, observe(failing))), 'INTERNAL');
let retry_runtime = new_runtime(), partial = observe(retry_runtime);
assert_true(partial.ownership.trusted && partial.routes[0].owned,
	'partial success remains exactly owned after failure and restart');
apply(retry_runtime, diff(retry_wanted, partial));
assert_equal(length(diff(retry_wanted, observe(retry_runtime)).add_rules), 0,
	'failure/restart retry completes the missing policy rule');
cleanup(retry_runtime);

// Collision semantics: a canonical proto-242 tuple created without manifest
// intent is ambiguous, and both apply and cleanup perform zero mutation.
assert_equal(system([ 'ip', '-4', 'route', 'replace', 'local', 'default', 'dev', 'lo',
	'table', '100', 'proto', '242' ]), 0, 'test can create a foreign protocol collision');
let collision_runtime = new_runtime(), collision = observe(collision_runtime);
assert_true(collision.routes[0].ambiguous && !collision.routes[0].owned,
	'unmanifested real proto-242 collision is ambiguous');
let collision_plan = diff(retry_wanted, collision);
assert_throws(() => apply(collision_runtime, collision_plan), 'INTERNAL');
assert_throws(() => cleanup(collision_runtime, collision), 'INTERNAL');
assert_true(length(trim(raw('ip -4 route show table 100 proto 242').output)) > 0,
	'foreign collision survives zero-mutation reconciliation and cleanup');
assert_equal(system([ 'ip', '-4', 'route', 'del', 'local', 'default', 'dev', 'lo',
	'table', '100', 'proto', '242' ]), 0, 'gate removes its foreign collision explicitly');

let final_state = observe(new_runtime());
for (let item in [ ...final_state.routes, ...final_state.rules ])
	assert_true(!item.owned, 'real cleanup leaves no MiClash-owned entry');
