import { assert_equal, assert_match, assert_throws, assert_true } from './testlib.uc';
import * as fakes from './fakes.uc';
import { acquire, assert_held, release } from 'miclash.mutation_lock';

const BOOT = '12345678-1234-1234-1234-123456789abc';
const LOCK = '/var/run/miclash/mutation.lock';
const TAKEOVER = '/var/run/miclash/mutation.lock.takeover';
const BARRIER = '/var/run/miclash/package-removal';

function proc_stat(pid, started) {
	return pid + ' (miclash test worker) S ' +
		join(' ', [ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, started ]) + '\n';
};

function environment(pid, started, filesystem) {
	let fs = filesystem ?? fakes.fs({
		'/proc/sys/kernel/random/boot_id': BOOT + '\n',
		['/proc/' + pid + '/stat']: proc_stat(pid, started)
	});
	for (let path in [ '/var', '/var/run', '/var/run/miclash' ])
		if (fs.lstat(path) == null) fs.mkdir(path);
	fs.set_mode('/var/run/miclash', 0o700);
	return {
		fs,
		clock: fakes.clock(10000),
		random: fakes.entropy(),
		mutation_lock_self: { boot: BOOT, pid, start: started }
	};
};

let first = environment(101, 500);
let lease = acquire(first, { barrier: 'normal', wait_ms: 0 });
assert_match(lease.token,
	/^12345678-1234-1234-1234-123456789abc:101:500:[0-9a-f]{32}$/,
	'owner token binds boot, PID, start time and a random nonce');
assert_true(first.fs.lstat(LOCK)?.type == 'directory', 'acquire publishes an atomic lock directory');
assert_equal(first.fs.lstat(LOCK)?.mode, 0o700, 'lock directory is root-only');
assert_equal(assert_held(first, lease), true, 'the exact owner lease verifies');
let wrong_release = null;
try { release(first, { ...lease, token: lease.token + '00' }); }
catch (error) { wrong_release = error?.code ?? error?.message; }
assert_equal(wrong_release, 'BUSY', 'wrong-token release must report BUSY, got ' + wrong_release);
assert_true(first.fs.lstat(LOCK) != null, 'wrong-token release cannot remove the owner lock');
assert_equal(release(first, lease), true, 'the exact owner releases its lock');
assert_equal(first.fs.lstat(LOCK), null, 'exact release removes the lock directory');

let blocked = environment(111, 600);
blocked.fs.mkdir(BARRIER);
blocked.fs.set_mode(BARRIER, 0o700);
assert_throws(() => acquire(blocked, { barrier: 'normal', wait_ms: 0 }), 'BUSY');
assert_equal(blocked.fs.lstat(LOCK), null, 'barrier precheck performs no lock mutation');
assert_throws(() => acquire(blocked, { barrier: 'package', wait_ms: 0 }), 'BUSY');
assert_equal(blocked.fs.lstat(LOCK), null,
	'package-mode ucode without an exact inherited owner is participant-only');

let shared = fakes.fs({
	'/proc/sys/kernel/random/boot_id': BOOT + '\n',
	'/proc/201/stat': proc_stat(201, 700),
	'/proc/202/stat': proc_stat(202, 800),
	'/proc/203/stat': proc_stat(203, 900)
});
let owner = environment(201, 700, shared);
let owner_lease = acquire(owner, { barrier: 'normal', wait_ms: 0 });
let child = environment(202, 800, shared);
child.mutation_lock_token = owner_lease.token;
let participant = acquire(child, { barrier: 'normal', wait_ms: 0 });
assert_equal(participant.kind, 'participant', 'an internal synchronous child joins as a participant');
delete shared.files['/proc/201/stat'];
let contender = environment(203, 900, shared);
assert_throws(() => acquire(contender, { barrier: 'normal', wait_ms: 0 }), 'BUSY');
assert_true(shared.lstat(LOCK) != null, 'a live participant prevents stale-owner takeover');
assert_equal(release(child, participant), true, 'participant removes only its own record');
let recovered = acquire(contender, { barrier: 'normal', wait_ms: 0 });
assert_equal(recovered.kind, 'owner', 'a contender recovers after owner and participants are dead');
assert_true(length(filter(shared.calls.rename,
	(item) => item.from == LOCK && item.to == TAKEOVER)) == 1,
	'stale recovery uses the fixed atomic takeover rename');
release(contender, recovered);

let sentinel_fs = fakes.fs({
	'/proc/sys/kernel/random/boot_id': BOOT + '\n',
	'/proc/301/stat': proc_stat(301, 1000)
});
let sentinel = environment(301, 1000, sentinel_fs);
sentinel_fs.on_mkdir = (path) => {
	if (path != LOCK) return;
	sentinel_fs.on_mkdir = null;
	sentinel_fs.mkdir(TAKEOVER);
	sentinel_fs.set_mode(TAKEOVER, 0o700);
	sentinel_fs.mkdir(TAKEOVER + '/participants');
	sentinel_fs.set_mode(TAKEOVER + '/participants', 0o700);
};
let sentinel_lease = acquire(sentinel, { barrier: 'normal', wait_ms: 0 });
assert_equal(sentinel_fs.lstat(TAKEOVER), null,
	'an owner rechecks the takeover sentinel after mkdir before publishing');
assert_equal(assert_held(sentinel, sentinel_lease), true,
	'sentinel recovery leaves exactly one published owner');
release(sentinel, sentinel_lease);

let initializing = environment(401, 1100);
initializing.fs.mkdir(LOCK);
initializing.fs.set_mode(LOCK, 0o700);
initializing.fs.mkdir(LOCK + '/participants');
initializing.fs.set_mode(LOCK + '/participants', 0o700);
initializing.fs.set_mtime(LOCK, 7);
assert_throws(() => acquire(initializing, { barrier: 'normal', wait_ms: 0 }), 'BUSY');
assert_true(initializing.fs.lstat(LOCK) != null,
	'an incomplete owner directory is protected during its five-second initialization grace');
initializing.clock.advance(2000);
let initialized_recovery = acquire(initializing, { barrier: 'normal', wait_ms: 0 });
assert_equal(initialized_recovery.kind, 'owner',
	'an incomplete owner directory becomes recoverable after the initialization grace');
release(initializing, initialized_recovery);

let reuse_fs = fakes.fs({
	'/proc/sys/kernel/random/boot_id': BOOT + '\n',
	'/proc/501/stat': proc_stat(501, 1200),
	'/proc/502/stat': proc_stat(502, 1300)
});
let reused_owner = environment(501, 1200, reuse_fs);
acquire(reused_owner, { barrier: 'normal', wait_ms: 0 });
reuse_fs.files['/proc/501/stat'] = proc_stat(501, 1201);
let reuse_contender = environment(502, 1300, reuse_fs);
let reuse_recovery = acquire(reuse_contender, { barrier: 'normal', wait_ms: 0 });
assert_equal(reuse_recovery.kind, 'owner',
	'a reused PID with a different process start time cannot keep a stale lock alive');
release(reuse_contender, reuse_recovery);

let revalidated_fs = fakes.fs({
	'/proc/sys/kernel/random/boot_id': BOOT + '\n',
	'/proc/601/stat': proc_stat(601, 1400),
	'/proc/602/stat': proc_stat(602, 1500)
});
let revalidated_owner = environment(601, 1400, revalidated_fs);
let revalidated_lease = acquire(revalidated_owner, { barrier: 'normal', wait_ms: 0 });
delete revalidated_fs.files['/proc/601/stat'];
revalidated_fs.on_rename = (from, to) => {
	if (from != LOCK || to != TAKEOVER) return;
	revalidated_fs.on_rename = null;
	revalidated_fs.files['/proc/601/stat'] = proc_stat(601, 1400);
};
let revalidation_contender = environment(602, 1500, revalidated_fs);
assert_throws(() => acquire(revalidation_contender, { barrier: 'normal', wait_ms: 0 }), 'BUSY');
assert_equal(revalidated_fs.lstat(TAKEOVER), null,
	'post-rename revalidation restores a lock whose exact owner identity is live again');
assert_equal(assert_held(revalidated_owner, revalidated_lease), true,
	'post-rename revalidation preserves the original exact owner lease');
release(revalidated_owner, revalidated_lease);
