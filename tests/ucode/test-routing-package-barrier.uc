import { assert_equal, assert_throws, assert_true } from './testlib.uc';
import { desired, observe, diff, apply, cleanup } from 'miclash.routing';
import { acquire, release } from 'miclash.mutation_lock';
import * as fakes from './fakes.uc';
import { empty_outputs, runtime, seed, set_route_json, set_rule_json } from './routing-rereview-testlib.uc';

const BARRIER = '/var/run/miclash/package-removal';
let package_pid = 9100;

function establish_barrier(value) {
	value.fs.mkdir(BARRIER);
	value.fs.set_mode(BARRIER, 0o700);
};

function authorize_package(value) {
	package_pid++;
	let started = 1700 + package_pid;
	value.fs.files['/proc/' + package_pid + '/stat'] = package_pid + ' (package owner) S ' +
		join(' ', [ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, started ]) + '\n';
	let owner = {
		fs: value.fs,
		clock: value.clock,
		random: fakes.entropy(),
		mutation_lock_self: {
			boot: '12345678-1234-1234-1234-123456789abc', pid: package_pid, start: started
		}
	};
	let lease = acquire(owner, { barrier: 'normal', wait_ms: 0 });
	value.mutation_lock_token = lease.token;
	establish_barrier(value);
	return () => release(owner, lease);
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

let never_started = runtime(empty_outputs());
let release_never_started = authorize_package(never_started);
never_started.package_removal_cleanup = true;
never_started.package_removal_preserve_manifest = true;
assert_equal(cleanup(never_started).clean, true,
	'package cleanup accepts a freshly proved empty never-started installation');
release_never_started();
let adopted_raw = never_started.fs.readfile('/var/run/miclash/routing-ownership.json');
assert_true(adopted_raw != null,
	'package cleanup must persist proof of the freshly observed empty kernel state');
let adopted = json(adopted_raw);
assert_equal(adopted?.version, 2,
	'package cleanup creates a trusted manifest when the kernel is freshly proved empty');
assert_equal(length(adopted?.committed?.routes), 0,
	'the adopted package cleanup manifest owns no route');
assert_equal(length(adopted?.committed?.rules), 0,
	'the adopted package cleanup manifest owns no rule');
assert_equal(adopted?.transition, null,
	'the adopted package cleanup manifest contains no pending transition');

let collision_outputs = empty_outputs();
collision_outputs['ip -j -4 route show table 100 2>/dev/null'] =
	'[{"type":"local","dst":"default","dev":"lo","table":100}]\n';
let unmanifested_collision = runtime(collision_outputs);
let release_collision = authorize_package(unmanifested_collision);
unmanifested_collision.package_removal_cleanup = true;
unmanifested_collision.package_removal_preserve_manifest = true;
assert_throws(() => cleanup(unmanifested_collision), 'INTERNAL');
release_collision();
assert_equal(unmanifested_collision.fs.readfile('/var/run/miclash/routing-ownership.json'), null,
	'package cleanup does not bless a canonical reserved-table collision');
assert_equal(length(unmanifested_collision.process.calls), 0,
	'absent-manifest collision refusal performs zero kernel mutation');

let protocol_outputs = empty_outputs();
set_route_json(protocol_outputs, wanted.routes[0]);
let unmanifested_protocol = runtime(protocol_outputs);
let release_protocol = authorize_package(unmanifested_protocol);
unmanifested_protocol.package_removal_cleanup = true;
unmanifested_protocol.package_removal_preserve_manifest = true;
assert_throws(() => cleanup(unmanifested_protocol), 'INTERNAL');
release_protocol();
assert_equal(unmanifested_protocol.fs.readfile('/var/run/miclash/routing-ownership.json'), null,
	'package cleanup does not bless unmanifested protocol-242 state');
assert_equal(length(unmanifested_protocol.process.calls), 0,
	'unmanifested protocol collision refusal performs zero kernel mutation');

let dedicated_outputs = empty_outputs();
set_route_json(dedicated_outputs, wanted.routes[0]);
set_rule_json(dedicated_outputs, wanted.rules[0]);
let dedicated = seed(runtime(dedicated_outputs), wanted.routes, wanted.rules);
let release_dedicated = authorize_package(dedicated);
dedicated.package_removal_cleanup = true;
dedicated.package_removal_preserve_manifest = true;
dedicated.process.run = (request) => {
	push(dedicated.process.calls, request);
	if (request.args[1] == 'rule') dedicated_outputs['ip -j -4 rule show 2>/dev/null'] = '[]\n';
	if (request.args[1] == 'route') dedicated_outputs['ip -j -4 route show table 100 2>/dev/null'] = '[]\n';
	return { code: 0 };
};
cleanup(dedicated);
release_dedicated();
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
watched.fs.files['/proc/9003/stat'] = '9003 (package contender) S ' +
	join(' ', [ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 703 ]) + '\n';
let package_contender = {
	fs: watched.fs,
	clock: watched.clock,
	random: fakes.entropy(),
	mutation_lock_self: {
		boot: '12345678-1234-1234-1234-123456789abc', pid: 9003, start: 703
	}
};
watched.observers = { routing: {
	subscribe: (fn) => { callback = fn; return () => true; },
	condition: () => true,
	reconcile: (present) => {
		reconciled++;
		assert_true(watched.fs.lstat('/var/run/miclash/mutation.lock')?.type == 'directory',
			'a watcher drain owns the shared lease before calling its mutation reconciler');
		establish_barrier(watched);
		assert_throws(() => acquire(package_contender, { barrier: 'package', wait_ms: 0 }), 'BUSY');
	}
} };
apply(watched, diff(tun, observe(watched)));
assert_true(type(callback) == 'function', 'successful TUN apply arms a watcher before removal');
callback({ interface: 'clash-tun', action: 'remove' });
watched.clock.advance(0);
assert_equal(reconciled, 1, 'the pre-barrier watcher drain completes under its original lease');
watched.fs.rmdir(BARRIER);
let release_package_owner = authorize_package(package_contender);
let package_lease = acquire(package_contender, { barrier: 'package', wait_ms: 0 });
release(package_contender, package_lease);
release_package_owner();
watched.fs.rmdir(BARRIER);
establish_barrier(watched);
callback({ interface: 'clash-tun', action: 'remove' });
watched.clock.advance(0);
assert_equal(reconciled, 1, 'watch callbacks perform no reconciliation after barrier establishment');
assert_true(watched.routing_monitor == null, 'barrier observation permanently disarms the stale watcher');
