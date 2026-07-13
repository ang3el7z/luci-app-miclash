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
	// The production target resolves /var/run/miclash to /tmp/run/miclash.
	// Ubuntu resolves it to /run/miclash, so present the target canonical name
	// while retaining the real handle/stat identities for this host gate.
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

assert_equal(system([ 'ip', 'link', 'add', 'clash-tun', 'type', 'dummy' ]), 0,
	'isolated namespace can create clash-tun for real table100 transition');
assert_equal(system([ 'ip', 'link', 'set', 'clash-tun', 'up' ]), 0,
	'isolated namespace can raise clash-tun for real table100 transition');
let tun_up = desired({ proxy_mode: 'tun', ip_families: [ 'ipv4', 'ipv6' ] }, { 'clash-tun': true });
apply(runtime, diff(tun_up, observe(runtime)));
assert_true(index(raw('ip -j -4 route show table 100').output, 'clash-tun') >= 0,
	'real table100 local-to-TUN replace leaves only the clash-tun route');
assert_equal(system([ 'ip', 'link', 'delete', 'clash-tun' ]), 0,
	'isolated namespace can remove clash-tun after real table100 up transition');
let tun_down = desired({ proxy_mode: 'tun', ip_families: [ 'ipv4', 'ipv6' ] }, { 'clash-tun': false });
apply(runtime, diff(tun_down, observe(runtime)));
assert_true(index(raw('ip -j -4 route show table 100').output, '"type":"local"') >= 0,
	'real table100 TUN-to-local replace succeeds without a stale old-route delete');

let mixed_down = desired({ proxy_mode: 'mixed', ip_families: [ 'ipv4', 'ipv6' ] }, { 'clash-tun': false });
let mixed_down_plan = diff(mixed_down, observe(runtime));
apply(runtime, mixed_down_plan);
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

// Fail after the first completed operation. Committed advances only for that
// proved route; the second exact rule operation remains retryable at pre-state.
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
	'only the proved first operation is committed after failure and restart');
assert_equal(partial.ownership.transition_state, 'pre',
	'the failed second operation restarts only at its exact retryable pre-state');
apply(retry_runtime, diff(retry_wanted, partial));
assert_equal(length(diff(retry_wanted, observe(retry_runtime)).add_rules), 0,
	'failure/restart retry completes the missing policy rule');
cleanup(retry_runtime);

// A producer may report success without changing the kernel. The persisted
// operation remains at pre; if an external actor later creates the pending
// target, that uncommitted post-state is a collision and authorizes nothing.
let zero = new_runtime();
zero.process.run = (request) => ({ code: 0, stdout: null, stderr: null });
assert_throws(() => apply(zero, diff(retry_wanted, observe(zero))), 'INTERNAL');
let zero_restart = new_runtime(), zero_pre = observe(zero_restart);
assert_equal(zero_pre.ownership.transition_state, 'pre',
	'reported success with zero kernel effect remains a retryable pre-state');
assert_equal(system([ 'ip', '-4', 'route', 'replace', 'local', 'default', 'dev', 'lo',
	'table', '100', 'proto', '242' ]), 0, 'test can create the pending target externally');
let zero_collision_runtime = new_runtime(), zero_collision = observe(zero_collision_runtime);
assert_equal(zero_collision.ownership.transition_state, 'post',
	'external creation of a pending target is recognized as uncommitted post-state');
assert_true(zero_collision.routes[0].ambiguous && !zero_collision.routes[0].owned,
	'uncommitted post-state never authorizes the pending target');
let zero_calls = length(zero_collision_runtime.process.calls);
assert_throws(() => apply(zero_collision_runtime, diff(retry_wanted, zero_collision)), 'INTERNAL');
assert_throws(() => cleanup(zero_collision_runtime), 'INTERNAL');
assert_equal(length(zero_collision_runtime.process.calls), zero_calls,
	'uncommitted post collision causes zero network mutation');
assert_equal(system([ 'ip', '-4', 'route', 'del', 'local', 'default', 'dev', 'lo',
	'table', '100', 'proto', '242' ]), 0, 'gate removes the external pending-target collision');
let zero_retry = new_runtime();
apply(zero_retry, diff(retry_wanted, observe(zero_retry)));
cleanup(zero_retry);

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

// Leave one exact live state for the shell gate to remove through the same
// routing-cleanup.uc entrypoint that package prerm invokes.
let package_runtime = new_runtime();
apply(package_runtime, diff(retry_wanted, observe(package_runtime)));
assert_true(package_runtime.fs.lstat('/var/run/miclash/routing-ownership.json')?.type == 'file',
	'package lifecycle gate starts with a live ownership manifest');
assert_true(package_runtime.fs.mkdir('/var/run/miclash/package-removal') == true,
	'real package lifecycle establishes its atomic removal barrier');
assert_true(package_runtime.fs.chmod('/var/run/miclash/package-removal', 0o700) == true,
	'real package removal barrier is root-only');
let calls_before_barrier = length(package_runtime.process.calls);
assert_throws(() => apply(package_runtime, diff(retry_wanted, observe(package_runtime))), 'BUSY');
assert_throws(() => cleanup(package_runtime), 'BUSY');
assert_equal(length(package_runtime.process.calls), calls_before_barrier,
	'real apply and ordinary cleanup perform zero mutation behind the removal barrier');
