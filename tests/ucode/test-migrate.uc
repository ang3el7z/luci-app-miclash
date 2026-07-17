import * as migrate from 'miclash.migrate';
import { assert_equal, assert_true, assert_throws } from 'testlib';
import { fail } from 'miclash.errors';

assert_equal(type(migrate.daemon_ready), 'function',
	'migration must verify daemon startup reconciliation readiness');

function readiness(marker, running, health) {
	let disconnects = 0;
	let runtime = {
		fs: {
			readfile: (path) => path == '/tmp/miclash/daemon-ready.json' ? marker : null,
			lstat: (path) => path == '/tmp/miclash/daemon-ready.json' && marker != null
				? { type: 'file', mode: 0o600, uid: 0 } : null
		},
		ubus: { connect: () => ({
			call: (object, method) => object == 'service' && method == 'list'
				? { miclashd: { instances: { instance1: { running } } } }
				: (object == 'miclash' && method == 'health' ? health : null),
			disconnect: () => { disconnects++; return true; }
		}) }
	};
	return { runtime, disconnects: () => disconnects };
};

let ready_marker = sprintf('%J\n', {
	schema_version: 1, startup_reconciled: true, ready_at_ms: 1700000000000
});
assert_equal(migrate.daemon_ready(readiness(null, true, { state: 'healthy' }).runtime), false,
	'procd running without a startup reconcile marker was accepted');
assert_equal(migrate.daemon_ready(readiness(ready_marker, true,
	{ error: { code: 'HEALTH_FAILED' } }).runtime), false,
	'daemon marker without a successful typed health call was accepted');
assert_equal(migrate.daemon_ready(readiness(ready_marker, false, { state: 'healthy' }).runtime), false,
	'a stopped daemon with a stale readiness marker was accepted');
let ready = readiness(ready_marker, true, { state: 'healthy' });
assert_equal(migrate.daemon_ready(ready.runtime), true,
	'daemon with startup reconcile marker and typed health call was rejected');
assert_equal(ready.disconnects(), 1, 'migration readiness leaked its ubus connection');

function harness(files, canonical) {
	let state = canonical ?? { guard: { enabled: false }, core: { proxy_mode: 'tproxy' } };
	let fs = { files: files ?? {}, fail_write: false };
	fs.readfile = (path) => fs.files[path];
	fs.lstat = (path) => fs.files[path] == null ? null :
		{ type: 'file', uid: 0, gid: 0, mode: 0o600 };
	fs.writefile = (path, value) => {
		if (fs.fail_write) return false;
		fs.files[path] = value;
		return true;
	};
	fs.unlink = (path) => {
		if (fs.files[path] == null) return null;
		delete fs.files[path];
		return true;
	};
	let calls = [], latched = false;
	let runtime = { fs, clock: { now: () => 1700000000000 } };
	let adapters = {
		legacy_patch: (text) => {
			if (text == 'corrupt') fail('INVALID_ARGUMENT');
			return { guard: { enabled: index(text, 'GUARD=true') >= 0 }, core: { proxy_mode: 'tun' } };
		},
		load: () => state,
		save: (patch) => { push(calls, patch); state = patch; return state; },
		latch_is_set: () => latched,
		latch_set: () => { latched = true; return true; },
		guard_verify: (enabled) => !enabled || latched
	};
	return { runtime, adapters, calls, state: () => state, latched: () => latched };
};

let fresh = harness({});
assert_equal(migrate.run(fresh.runtime, fresh.adapters, 'prepare').phase, 'prepared', 'fresh prepared');
assert_equal(migrate.run(fresh.runtime, fresh.adapters, 'apply').phase, 'applied', 'fresh applied');
assert_equal(length(fresh.calls), 0, 'fresh install has no legacy settings write');
assert_equal(migrate.run(fresh.runtime, fresh.adapters, 'verify').phase, 'verified', 'fresh verified');
assert_equal(migrate.run(fresh.runtime, fresh.adapters, 'cleanup').phase, 'complete', 'fresh complete');

let legacy = harness({ '/opt/clash/settings': 'PROXY=tun\nGUARD=true\n' });
migrate.run(legacy.runtime, legacy.adapters, 'prepare');
migrate.run(legacy.runtime, legacy.adapters, 'apply');
assert_equal(length(legacy.calls), 1, 'legacy settings applied exactly once');
assert_true(legacy.latched(), 'Guard latched before migration write');
migrate.run(legacy.runtime, legacy.adapters, 'verify');
migrate.run(legacy.runtime, legacy.adapters, 'cleanup');
assert_equal(legacy.runtime.fs.files['/opt/clash/settings'], null, 'legacy settings removed after verification');

let canonical = harness({
	'/opt/clash/settings': 'PROXY=tun\n',
	'/etc/miclash/canonical-preexisting': '1\n'
}, { guard: { enabled: false }, core: { proxy_mode: 'mixed' } });
migrate.run(canonical.runtime, canonical.adapters, 'prepare');
migrate.run(canonical.runtime, canonical.adapters, 'apply');
assert_equal(length(canonical.calls), 0, 'newer canonical edits win');
assert_equal(canonical.state().core.proxy_mode, 'mixed', 'canonical value retained');

let marker_after_prepare = harness({ '/opt/clash/settings': 'PROXY=tun\n' });
migrate.run(marker_after_prepare.runtime, marker_after_prepare.adapters, 'prepare');
marker_after_prepare.runtime.fs.files['/etc/miclash/canonical-preexisting'] = '1\n';
let marker_result = migrate.run(marker_after_prepare.runtime, marker_after_prepare.adapters, 'apply');
assert_equal(length(marker_after_prepare.calls), 0, 'marker created after prepare was ignored');
assert_equal(marker_result.user_edit_preserved, true);

let edit_after_prepare = harness({ '/opt/clash/settings': 'PROXY=tun\n' });
migrate.run(edit_after_prepare.runtime, edit_after_prepare.adapters, 'prepare');
edit_after_prepare.state().core.proxy_mode = 'mixed';
let edit_result = migrate.run(edit_after_prepare.runtime, edit_after_prepare.adapters, 'apply');
assert_equal(length(edit_after_prepare.calls), 0, 'canonical edit after prepare was overwritten');
assert_equal(edit_after_prepare.state().core.proxy_mode, 'mixed');
assert_equal(edit_result.user_edit_preserved, true);

let commit_race = harness({ '/opt/clash/settings': 'PROXY=tun\n' });
migrate.run(commit_race.runtime, commit_race.adapters, 'prepare');
commit_race.adapters.commit_patch = (expected, patch) => {
	commit_race.state().core.proxy_mode = 'mixed';
	return null;
};
let race_result = migrate.run(commit_race.runtime, commit_race.adapters, 'apply');
assert_equal(commit_race.state().core.proxy_mode, 'mixed', 'commit-time user edit lost');
assert_equal(race_result.patch_applied, false);
assert_equal(race_result.user_edit_preserved, true);

let interrupted = harness({ '/opt/clash/settings': 'PROXY=tun\n' });
migrate.run(interrupted.runtime, interrupted.adapters, 'prepare');
let interrupted_journal = json(interrupted.runtime.fs.files['/etc/miclash/migration-v1.json']);
interrupted_journal.phase = 'applying';
interrupted_journal.canonical_before = interrupted.state();
interrupted.runtime.fs.files['/etc/miclash/migration-v1.json'] = sprintf('%J\n', interrupted_journal);
migrate.run(interrupted.runtime, interrupted.adapters, 'apply');
assert_equal(length(interrupted.calls), 1, 'interrupted/repeated apply is idempotent');

let edited = harness({ '/opt/clash/settings': 'PROXY=tun\n' });
migrate.run(edited.runtime, edited.adapters, 'prepare');
let edited_journal = json(edited.runtime.fs.files['/etc/miclash/migration-v1.json']);
edited_journal.phase = 'applying';
edited_journal.canonical_before = edited.state();
edited.runtime.fs.files['/etc/miclash/migration-v1.json'] = sprintf('%J\n', edited_journal);
edited.state().core.proxy_mode = 'mixed';
migrate.run(edited.runtime, edited.adapters, 'apply');
assert_equal(length(edited.calls), 0, 'new canonical edit wins after interrupted apply');
assert_equal(edited.state().core.proxy_mode, 'mixed');

let corrupt = harness({ '/opt/clash/settings': 'corrupt' });
assert_throws(() => migrate.run(corrupt.runtime, corrupt.adapters, 'prepare'), 'INVALID_ARGUMENT');
let corrupt_journal = harness({ '/etc/miclash/migration-v1.json': '{broken' });
assert_throws(() => migrate.run(corrupt_journal.runtime, corrupt_journal.adapters, 'status'), 'INTERNAL');

let low_disk = harness({ '/opt/clash/settings': 'PROXY=tun\n' });
low_disk.runtime.fs.fail_write = true;
assert_throws(() => migrate.run(low_disk.runtime, low_disk.adapters, 'prepare'), 'INTERNAL');
