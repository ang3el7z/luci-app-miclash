import { assert_equal, assert_match, assert_throws, assert_true } from 'testlib';
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

// Exact read-only kinds are compatible with a running mutation; unknown kinds are mutations.
let status = manager.submit('status', 'luci', {}, () => push(order, 'status'));
let unknown = manager.submit('future.unknown', 'luci', {}, () => push(order, 'unknown'));
env.clock.advance(0);
assert_equal(manager.get(status.id).state, 'success');
assert_equal(manager.get(unknown.id).state, 'queued');
assert_equal(join(',', order), 'first,status');
assert_equal(manager.get(first.id).state, 'running');
assert_equal(length(manager.list({ state: 'queued' })), 2);
release_first();
env.clock.advance(0);
assert_equal(join(',', order), 'first,status,second,unknown');
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
let start_record = start_failure_manager.submit('config.apply', 'luci', {}, () => start_ran++);
start_failure.fs.fail_on = 'rename';
start_failure.clock.advance(0);
assert_equal(start_ran, 0);
assert_equal(start_failure_manager.get(start_record.id).state, 'failure');
assert_equal(start_failure_manager.get(start_record.id).error.code, 'INTERNAL');

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
for (let id in [ running.id, queued.id ]) {
	let record = recovered.get(id);
	assert_equal(record.state, 'interrupted');
	assert_equal(record.error.code, 'INTERRUPTED');
	assert_true(record.finished_at != null);
}

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

// Retention is based on completion time, and never removes active work.
let late_env = environment();
let late = operations.create(late_env.rt);
let finish_late;
let old_but_active = late.submit('config.apply', 'system', {}, (ctx) => {
	finish_late = () => ctx.complete();
	return false;
});
late_env.clock.advance(0);
for (let number = 0; number < 101; number++) {
	late.submit('status', 'system', {}, () => null);
	late_env.clock.advance(1);
}
assert_equal(late.get(old_but_active.id).state, 'running');
assert_equal(length(late.list()), 101);
finish_late();
assert_equal(late.get(old_but_active.id).state, 'success');
assert_equal(length(late.list()), 100);
