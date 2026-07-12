import { assert_equal, assert_match, assert_throws, assert_true } from 'testlib';
import * as errors from 'miclash.errors';
import * as operations from 'miclash.operations';
import * as fakes from 'fakes';

function environment(initial, start) {
	let fs = fakes.fs(initial ?? {});
	fs.mkdir('/tmp');
	fs.mkdir('/tmp/miclash');
	fs.mkdir('/tmp/miclash/operations');
	let clock = fakes.clock(start ?? 1000);
	let random = fakes.entropy();
	return {
		fs,
		clock,
		random,
		rt: {
			fs,
			clock,
			random,
			digest: fakes.digest(fs),
			paths: { tmp: '/tmp/miclash', run: '/var/run/miclash' }
		}
	};
};

let env = environment();
let manager = operations.create(env.rt);
assert_equal(env.fs.mode('/tmp/miclash'), 0o700);
assert_equal(env.fs.mode('/tmp/miclash/operations'), 0o700);

// Journal roots are exact root-owned private directories before any access.
let linked_root = environment();
linked_root.fs.set_symlink('/tmp/miclash', '/tmp');
assert_throws(() => operations.create(linked_root.rt), 'INTERNAL');
let linked_journal = environment();
linked_journal.fs.set_symlink('/tmp/miclash/operations', '/tmp');
assert_throws(() => operations.create(linked_journal.rt), 'INTERNAL');
let file_journal = environment({ '/tmp/miclash/operations': 'hostile' });
assert_throws(() => operations.create(file_journal.rt), 'INTERNAL');
let foreign_owner = environment();
foreign_owner.fs.set_uid('/tmp/miclash/operations', 1000);
assert_throws(() => operations.create(foreign_owner.rt), 'INTERNAL');
let chmod_failure = environment();
chmod_failure.fs.fail_on = 'chmod';
assert_throws(() => operations.create(chmod_failure.rt), 'INTERNAL');
let unfixable_mode = environment();
unfixable_mode.fs.ignore_chmod = true;
assert_throws(() => operations.create(unfixable_mode.rt), 'INTERNAL');
let order = [];
let release_first;
let first = manager.submit('config.apply', 'luci', { token: 'never-store-me' }, (ctx) => {
	push(order, 'first');
	release_first = () => ctx.complete();
	return false;
});
let second = manager.submit('service.restart', 'telegram', {}, (ctx) => {
	push(order, 'second');
});
assert_equal(manager.get(first.id).state, 'queued');
assert_equal(manager.get(second.id).state, 'queued');
assert_equal(length(order), 0);
env.clock.advance(0);
assert_equal(manager.get(first.id).state, 'running');
assert_equal(manager.get(second.id).state, 'queued');
assert_equal(join(',', order), 'first');

// Every submitted worker is a mutation. Immediate get/list reads remain available.
let status = manager.submit('status', 'luci', {}, () => push(order, 'status'));
let config_read = manager.submit('config.read', 'luci', {}, () => push(order, 'config.read'));
let unknown = manager.submit('future.unknown', 'luci', {}, () => push(order, 'unknown'));
env.clock.advance(0);
assert_equal(manager.get(status.id).state, 'queued');
assert_equal(manager.get(config_read.id).state, 'queued');
assert_equal(manager.get(unknown.id).state, 'queued');
assert_equal(join(',', order), 'first');
assert_equal(manager.get(first.id).state, 'running');
assert_equal(length(manager.list({ state: 'queued' })), 4);
release_first();
env.clock.advance(0);
assert_equal(join(',', order), 'first,second,status,config.read,unknown');
assert_equal(manager.get(second.id).state, 'success');
assert_equal(manager.get(unknown.id).state, 'success');

// Returned records, lists, and subscriber events are defensive redacted copies.
let events = [];
manager.subscribe((event) => {
	push(events, event);
	event.state = 'tampered';
});
manager.subscribe((event) => die('subscriber failure'));
manager.subscribe((event) => push(events, event));
let staged = manager.submit('config.validate', 'luci', {
	password: 'context-password',
	endpoint: 'https://user:pass@example.test/a?token=context-token'
}, (ctx) => {
	ctx.stage('download', 20, 'fetch https://user:pass@example.test/a?token=stage-token');
	ctx.stage('validate', 100, 'safe');
});
env.clock.advance(0);
let staged_record = manager.get(staged.id);
assert_equal(staged_record.state, 'success');
assert_equal(staged_record.stage, 'validate');
assert_equal(staged_record.progress, 100);
assert_equal(staged_record.message, 'safe');
assert_true(length(events) >= 6);
assert_true(events[length(events) - 2].state == 'tampered');
assert_equal(events[length(events) - 1].state, 'success');
staged_record.state = 'tampered';
let staged_list = manager.list({ kind: 'config.validate', source: 'luci' });
staged_list[0].message = 'tampered';
assert_equal(manager.get(staged.id).state, 'success');
assert_equal(manager.get(staged.id).message, 'safe');
let persisted = '';
for (let path, data in env.fs.files)
	if (index(path, '/tmp/miclash/operations/') == 0)
		persisted += data;
assert_true(index(persisted, 'context-password') < 0);
assert_true(index(persisted, 'context-token') < 0);
assert_true(index(persisted, 'stage-token') < 0);

// Invalid/non-monotonic progress and worker exceptions are normalized failures.
let decreasing = manager.submit('service.reload', 'system', {}, (ctx) => {
	ctx.stage('prepare', 50, 'half');
	ctx.stage('backwards', 49, 'bad');
});
env.clock.advance(0);
assert_equal(manager.get(decreasing.id).state, 'failure');
assert_equal(manager.get(decreasing.id).error.code, 'INVALID_ARGUMENT');
let unsafe = manager.submit('service.stop', 'system', {}, (ctx) =>
	ctx.stage('bad stage', 1, 'bad'));
env.clock.advance(0);
assert_equal(manager.get(unsafe.id).error.code, 'INVALID_ARGUMENT');
let exploded = manager.submit('service.start', 'system', {}, () => die('raw secret failure'));
env.clock.advance(0);
assert_equal(manager.get(exploded.id).error.code, 'INTERNAL');
assert_equal(manager.get(exploded.id).error.message, 'Internal error');

// A journal failure fails closed before the mutation can run.
let broken = environment();
let broken_manager = operations.create(broken.rt);
let ran = 0;
broken.fs.fail_on = 'rename';
assert_throws(() => broken_manager.submit('config.apply', 'luci', {}, () => ran++), 'INTERNAL');
broken.clock.advance(0);
assert_equal(ran, 0);
assert_equal(length(broken_manager.list()), 0);

let start_failure = environment();
let start_failure_manager = operations.create(start_failure.rt);
let start_ran = 0;
let next_ran = 0;
let start_events = [];
start_failure_manager.subscribe((event) => push(start_events, event));
let start_record = start_failure_manager.submit('config.apply', 'luci', {}, () => start_ran++);
let next_record = start_failure_manager.submit('service.restart', 'luci', {}, () => next_ran++);
let durable_events = length(start_events);
start_failure.fs.fail_on = 'rename';
start_failure.clock.advance(0);
assert_equal(start_ran, 0);
assert_equal(next_ran, 0);
assert_equal(start_failure_manager.get(start_record.id).state, 'queued');
assert_equal(start_failure_manager.get(next_record.id).state, 'queued');
assert_equal(length(start_events), durable_events);

let finish_failure = environment();
let finish_failure_manager = operations.create(finish_failure.rt);
let followup_ran = 0;
let finish_record = finish_failure_manager.submit('config.apply', 'luci', {}, () => {
	finish_failure.fs.fail_on = 'rename';
});
finish_failure_manager.submit('service.restart', 'luci', {}, () => followup_ran++);
assert_throws(() => finish_failure.clock.advance(0), 'INTERNAL');
assert_equal(finish_failure_manager.get(finish_record.id).state, 'running');
assert_equal(followup_ran, 0);

// Restart never resumes queued/running work; both become interrupted durably.
let restart = environment();
let old_manager = operations.create(restart.rt);
let running = old_manager.submit('config.apply', 'luci', {}, (ctx) => false);
let queued = old_manager.submit('service.restart', 'luci', {}, () => die('must not resume'));
restart.clock.advance(0);
let recovered_env = {
	fs: restart.fs,
	clock: fakes.clock(2000),
	random: fakes.entropy(),
	digest: fakes.digest(restart.fs),
	paths: { tmp: '/tmp/miclash', run: '/var/run/miclash' }
};
let recovered = operations.create(recovered_env);
assert_equal(recovered.recover_interrupted(), 2);
assert_equal(recovered.recover_interrupted(), 0);
for (let id in [ running.id, queued.id ]) {
	let record = recovered.get(id);
	assert_equal(record.state, 'interrupted');
	assert_equal(record.error.code, 'INTERRUPTED');
	assert_true(record.finished_at != null);
}
recovered.submit('status', 'system', {}, () => null);
assert_throws(() => recovered.recover_interrupted(), 'BUSY');

let live_recovery = environment();
let live_manager = operations.create(live_recovery.rt);
live_manager.submit('status', 'system', {}, () => null);
assert_throws(() => live_manager.recover_interrupted(), 'BUSY');

function disk_record(id, state) {
	let terminal = state == 'success' || state == 'failure' || state == 'interrupted';
	return {
		id,
		kind: 'config.apply',
		source: 'system',
		state,
		stage: state == 'interrupted' ? 'interrupted' : 'queued',
		progress: state == 'success' ? 100 : 0,
		message: '',
		error: state == 'failure' || state == 'interrupted' ?
			{ code: state == 'interrupted' ? 'INTERRUPTED' : 'INTERNAL', message: 'safe' } : null,
		created_at: 100,
		updated_at: terminal ? 200 : 100,
		finished_at: terminal ? 200 : null
	};
};

function assert_corrupt(mutator) {
	let id = '0000000000100-00000001-0123456789abcdef';
	let record = disk_record(id, 'success');
	mutator(record);
	let filename = record.id + '.json';
	let path = '/tmp/miclash/operations/' + filename;
	let corrupt_env = environment({ [path]: sprintf('%J\n', record) });
	let corrupt_manager = operations.create(corrupt_env.rt);
	assert_throws(() => corrupt_manager.recover_interrupted(), 'CORRUPT_STATE');
	assert_equal(length(corrupt_manager.list()), 0);
};

// Recovery validates the exact complete schema and state invariants as CORRUPT_STATE.
for (let index, mutator in [
	(record) => record.extra = true,
	(record) => record.id = 'bad-id',
	(record) => record.kind = 'bad kind',
	(record) => record.kind = 'safe' + sprintf('%c', 0),
	(record) => record.source = 'remote',
	(record) => record.state = 'unknown',
	(record) => record.stage = 'bad stage',
	(record) => record.stage = 'safe' + sprintf('%c', 0),
	(record) => record.progress = 101,
	(record) => record.message = 'bad' + sprintf('%c', 0),
	(record) => record.created_at = '100',
	(record) => record.updated_at = 99,
	(record) => record.finished_at = null,
	(record) => record.error = { code: 'INTERNAL', message: 'unexpected' }
]) assert_corrupt(mutator);

assert_corrupt((record) => {
	record.state = 'failure';
	record.progress = 1;
	record.error = null;
});
assert_corrupt((record) => {
	record.state = 'running';
	record.progress = 1;
	record.error = null;
});
assert_corrupt((record) => {
	record.state = 'queued';
	record.progress = 1;
	record.finished_at = null;
	record.error = null;
});
assert_corrupt((record) => record.error = {
	code: 'NOT_A_CODE', message: 'bad', extra: true
});
assert_corrupt((record) => record.error = {
	code: 'INTERNAL', message: 'safe' + sprintf('%c', 0)
});
assert_corrupt((record) => record.error = {
	code: 'INTERNAL', message: 'safe', detail: { token: 'raw-secret' }
});
assert_corrupt((record) => {
	record.state = 'failure';
	record.progress = 20;
	record.error = { code: 'INTERNAL', message: 'raw secret failure' };
});
assert_corrupt((record) => {
	record.state = 'failure';
	record.progress = 20;
	record.error = { code: 'DOWNLOAD_FAILED', message: 'custom download message' };
});

let canonical_internal = '0000000000110-00000001-0123456789abcdef';
let canonical_download = '0000000000110-00000002-0123456789abcdef';
let canonical_internal_record = disk_record(canonical_internal, 'failure');
canonical_internal_record.error = { code: 'INTERNAL', message: 'Internal error' };
let canonical_download_record = disk_record(canonical_download, 'failure');
canonical_download_record.error = { code: 'DOWNLOAD_FAILED', message: 'DOWNLOAD_FAILED' };
let canonical_env = environment({
	['/tmp/miclash/operations/' + canonical_internal + '.json']:
		sprintf('%J\n', canonical_internal_record),
	['/tmp/miclash/operations/' + canonical_download + '.json']:
		sprintf('%J\n', canonical_download_record)
});
let canonical_manager = operations.create(canonical_env.rt);
assert_equal(canonical_manager.recover_interrupted(), 0);
assert_equal(length(canonical_manager.list({ state: 'failure' })), 2);

// Every canonical producible error survives journal recovery; a forged code
// with an otherwise exact schema is corrupt state.
let all_code_files = {};
let code_ids = [];
for (let number, code in errors.CODES) {
	let id = sprintf('0000000000120-%08d-0123456789abcdef', number + 1);
	let record = disk_record(id, 'failure');
	record.error = { code, message: code == 'INTERNAL' ? 'Internal error' : code };
	all_code_files['/tmp/miclash/operations/' + id + '.json'] = sprintf('%J\n', record);
	push(code_ids, id);
}
let all_codes_env = environment(all_code_files);
let all_codes = operations.create(all_codes_env.rt);
assert_equal(all_codes.recover_interrupted(), 0);
for (let number, code in errors.CODES) {
	let recovered_code = all_codes.get(code_ids[number]);
	assert_equal(recovered_code.state, 'failure');
	assert_equal(recovered_code.error.code, code);
}
assert_corrupt((record) => {
	record.state = 'failure';
	record.error = { code: 'FORGED_FAILURE', message: 'FORGED_FAILURE' };
});

let hidden_bad_env = environment({
	'/tmp/miclash/operations/.bad.json': sprintf('%J\n', disk_record(
		'0000000000100-00000001-0123456789abcdef', 'success'))
});
assert_throws(() => operations.create(hidden_bad_env.rt).recover_interrupted(), 'CORRUPT_STATE');

// One malformed file prevents loading, ID observation, or interrupting any valid file.
let preflight_valid = '0000000000200-00000001-0123456789abcdef';
let preflight_bad = '0000000000200-00000002-0123456789abcdef';
let preflight_env = environment({
	['/tmp/miclash/operations/' + preflight_valid + '.json']:
		sprintf('%J\n', disk_record(preflight_valid, 'running')),
	['/tmp/miclash/operations/' + preflight_bad + '.json']:
		sprintf('%J\n', { ...disk_record(preflight_bad, 'success'), extra: true })
});
let preflight = operations.create(preflight_env.rt);
assert_throws(() => preflight.recover_interrupted(), 'CORRUPT_STATE');
assert_equal(length(preflight.list()), 0);
assert_equal(json(preflight_env.fs.files[
	'/tmp/miclash/operations/' + preflight_valid + '.json']).state, 'running');

// Inaccessible journal enumeration fails closed and remains retryable.
let retry_id = '0000000000300-00000001-0123456789abcdef';
let retry_env = environment({
	['/tmp/miclash/operations/' + retry_id + '.json']:
		sprintf('%J\n', disk_record(retry_id, 'running'))
});
let retry_manager = operations.create(retry_env.rt);
let retry_lsdir = retry_env.fs.lsdir;
retry_env.fs.lsdir = (path) => null;
assert_throws(() => retry_manager.recover_interrupted(), 'INTERNAL');
assert_equal(length(retry_manager.list()), 0);
retry_env.fs.lsdir = retry_lsdir;
assert_equal(retry_manager.recover_interrupted(), 1);
assert_equal(retry_manager.get(retry_id).state, 'interrupted');

// Recovery removes only identity-stable storage atomic temps, and only after
// every journal record has passed preflight validation.
let temp_id = '0000000000310-00000001-0123456789abcdef';
let temp_name = '.' + temp_id + '.json.miclash.1-1.01234567';
let temp_path = '/tmp/miclash/operations/' + temp_name;
let stale_temp = environment({ [temp_path]: 'partial journal' });
let stale_manager = operations.create(stale_temp.rt);
assert_equal(stale_manager.recover_interrupted(), 0);
assert_equal(stale_temp.fs.lstat(temp_path), null);

let malformed_with_temp = environment({
	[temp_path]: 'partial journal',
	'/tmp/miclash/operations/bad.json': '{}'
});
assert_throws(() => operations.create(malformed_with_temp.rt).recover_interrupted(),
	'CORRUPT_STATE');
assert_equal(malformed_with_temp.fs.readfile(temp_path), 'partial journal');

let replaced_temp = environment({ [temp_path]: 'partial journal' });
let replacement_manager = operations.create(replaced_temp.rt);
let original_lstat = replaced_temp.fs.lstat;
let temp_lstats = 0;
replaced_temp.fs.lstat = (path) => {
	if (path == temp_path && ++temp_lstats == 2)
		replaced_temp.fs.bump_inode(path);
	return original_lstat(path);
};
assert_throws(() => replacement_manager.recover_interrupted(), 'INTERNAL');
assert_equal(replaced_temp.fs.readfile(temp_path), 'partial journal');

let unlink_temp = environment({ [temp_path]: 'partial journal' });
let unlink_manager = operations.create(unlink_temp.rt);
unlink_temp.fs.fail_unlink_once = true;
assert_throws(() => unlink_manager.recover_interrupted(), 'INTERNAL');
assert_equal(unlink_temp.fs.readfile(temp_path), 'partial journal');
assert_equal(unlink_manager.recover_interrupted(), 0);
assert_equal(unlink_temp.fs.lstat(temp_path), null);

let linked_temp = environment();
linked_temp.fs.set_symlink(temp_path, '/tmp/foreign-journal');
assert_throws(() => operations.create(linked_temp.rt).recover_interrupted(), 'CORRUPT_STATE');
assert_equal(linked_temp.fs.lstat(temp_path)?.type, 'link');
let hardlinked_temp = environment({ [temp_path]: 'foreign hardlink' });
hardlinked_temp.fs.set_nlink(temp_path, 2);
assert_throws(() => operations.create(hardlinked_temp.rt).recover_interrupted(),
	'CORRUPT_STATE');
assert_equal(hardlinked_temp.fs.readfile(temp_path), 'foreign hardlink');

// IDs stay schema/safe-name compatible, strictly ordered, and have random suffixes.
let ids_env = environment({}, 5000);
let ids = operations.create(ids_env.rt);
let id1 = ids.submit('status', 'system', {}, () => null).id;
let id2 = ids.submit('status', 'system', {}, () => null).id;
assert_match(id1, /^[0-9]+-[0-9]+-[0-9a-f]+$/);
assert_match(id2, /^[0-9]+-[0-9]+-[0-9a-f]+$/);
assert_true(id1 < id2);
assert_true(id1 != id2);
assert_equal(join(',', ids_env.random.calls), '8,8');

// Recovery advances the generator past persisted IDs even after clock rollback.
let high_id = '0000000999999-00000042-0123456789abcdef';
let seeded_record = {
	id: high_id, kind: 'status', source: 'system', state: 'success',
	stage: 'queued', progress: 100, message: '', error: null,
	created_at: 999999, updated_at: 999999, finished_at: 999999
};
let seeded_path = '/tmp/miclash/operations/' + high_id + '.json';
let seeded_env = environment({ [seeded_path]: sprintf('%J\n', seeded_record) }, 1);
let seeded = operations.create(seeded_env.rt);
assert_equal(seeded.recover_interrupted(), 0);
let after_seed = seeded.submit('status', 'system', {}, () => null);
assert_true(after_seed.id > high_id);

// Retention keeps exactly the latest 100 completed records with deterministic ordering.
let retention_env = environment();
let retention = operations.create(retention_env.rt);
for (let number = 0; number < 105; number++) {
	retention.submit('status', 'system', {}, () => null);
	retention_env.clock.advance(0);
}
let retained = retention.list({ state: 'success' });
assert_equal(length(retained), 100);
for (let index = 1; index < length(retained); index++)
	assert_true(retained[index - 1].id < retained[index].id);
assert_throws(() => retention.list({ unknown: true }), 'INVALID_ARGUMENT');
assert_throws(() => retention.list({ state: 'bogus' }), 'INVALID_ARGUMENT');
assert_throws(() => retention.get('../bad'), 'INVALID_ARGUMENT');
assert_throws(() => retention.subscribe('not a callback'), 'INVALID_ARGUMENT');

// Retention unlink failure is housekeeping: terminal state and FIFO continue.
let prune_env = environment();
let prune_manager = operations.create(prune_env.rt);
for (let number = 0; number < 100; number++) {
	prune_manager.submit('status', 'system', {}, () => null);
	prune_env.clock.advance(0);
}
prune_env.fs.fail_unlink_once = true;
let prune_101 = prune_manager.submit('status', 'system', {}, () => null);
let prune_102 = prune_manager.submit('status', 'system', {}, () => null);
prune_env.clock.advance(0);
assert_equal(prune_manager.get(prune_101.id).state, 'success');
assert_equal(prune_manager.get(prune_102.id).state, 'success');
assert_equal(length(prune_manager.list()), 100);

// Each subscription has its own identity even when callbacks are identical.
let subscription_env = environment();
let subscription_manager = operations.create(subscription_env.rt);
let subscription_calls = 0;
let same_callback = (event) => subscription_calls++;
let unsubscribe_first = subscription_manager.subscribe(same_callback);
let unsubscribe_second = subscription_manager.subscribe(same_callback);
assert_equal(unsubscribe_first(), true);
subscription_manager.submit('status', 'system', {}, () => null);
subscription_env.clock.advance(0);
assert_equal(subscription_calls, 3);
assert_equal(unsubscribe_second(), true);
subscription_manager.submit('status', 'system', {}, () => null);
subscription_env.clock.advance(0);
assert_equal(subscription_calls, 3);
