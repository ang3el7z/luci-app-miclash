import { assert_equal, assert_throws, assert_true } from 'testlib';
import * as diff from 'miclash.diff';
import * as history from 'miclash.history';
import * as config from 'miclash.config';
import * as operations from 'miclash.operations';
import * as fakes from 'fakes';

const LIMITS = {
	max_input_bytes: 1024,
	max_output_bytes: 2048,
	max_lines: 64,
	max_hunks: 4,
	context_lines: 1,
	max_cells: 4096
};

function repeated(value, count) {
	let output = '';
	for (let index = 0; index < count; index++)
		output += value;
	return output;
};

let changed = diff.unified('alpha\nbeta\ngamma\n', 'alpha\nchanged\ngamma\n', LIMITS);
assert_equal(changed.changed, true);
assert_equal(changed.hunks, 1);
assert_equal(changed.text,
	'--- old\n+++ next\n@@ -1,3 +1,3 @@\n alpha\n-beta\n+changed\n gamma\n');
assert_equal(diff.unified('same\n', 'same\n', LIMITS).text, '');
assert_equal(diff.unified('same', 'same\n', LIMITS).text,
	'--- old\n+++ next\n@@ -1,1 +1,1 @@\n-same\n\\ No newline at end of file\n+same\n');
assert_equal(diff.unified(
	'a\nb\nc\nd\ne\nf\ng\nh\n',
	'a\nB\nc\nd\ne\nf\nG\nh\n', LIMITS).text,
	'--- old\n+++ next\n' +
	'@@ -1,3 +1,3 @@\n a\n-b\n+B\n c\n' +
	'@@ -6,3 +6,3 @@\n f\n-g\n+G\n h\n');
assert_equal(diff.unified('', 'inserted\n', LIMITS).text,
	'--- old\n+++ next\n@@ -0,0 +1,1 @@\n+inserted\n');
assert_equal(diff.unified('removed', '', LIMITS).text,
	'--- old\n+++ next\n@@ -1,1 +0,0 @@\n-removed\n\\ No newline at end of file\n');
assert_throws(() => diff.unified(
	'a\nb\nc\nd\ne\nf\ng\nh\n',
	'a\nB\nc\nd\ne\nf\nG\nh\n', { ...LIMITS, max_hunks: 1 }),
	'RESPONSE_TOO_LARGE');
assert_throws(() => diff.unified('a\nb\n', 'x\ny\n',
	{ ...LIMITS, max_cells: 8 }), 'RESPONSE_TOO_LARGE');
assert_throws(() => diff.unified('nul' + sprintf('%c', 0), 'text', LIMITS),
	'INVALID_ARGUMENT');
assert_throws(() => diff.unified('bad' + sprintf('%c', 255), 'text', LIMITS),
	'INVALID_ARGUMENT');
assert_throws(() => diff.unified('a', 'b', { ...LIMITS, unexpected: 1 }),
	'INVALID_ARGUMENT');
assert_throws(() => diff.unified('a', 'b', { ...LIMITS, max_hunks: 0 }),
	'INVALID_ARGUMENT');
assert_throws(() => diff.unified(repeated('x', 1025), 'text', LIMITS),
	'RESPONSE_TOO_LARGE');
assert_throws(() => diff.unified(repeated('a\n', 65), 'text', LIMITS),
	'RESPONSE_TOO_LARGE');
assert_throws(() => diff.unified('alpha\n', 'changed\n',
	{ ...LIMITS, max_output_bytes: 8 }), 'RESPONSE_TOO_LARGE');

let fs = fakes.fs({ '/opt/clash/config.yaml': 'active\n' });
for (let path in [ '/opt', '/opt/clash' ])
	fs.mkdir(path);
let rt = {
	fs,
	clock: fakes.clock(1700000000000),
	random: fakes.entropy(),
	digest: fakes.digest(fs),
	paths: { tmp: '/tmp/miclash', run: '/var/run/miclash' }
};
let revisions = history.create(rt, { diff });
for (let method in [ 'list', 'get', 'diff', 'open_draft', 'restore', 'prune',
	'snapshot', 'snapshot_bytes', 'mark_activation', 'read' ])
	assert_true(type(revisions[method]) == 'function');

function environment(service) {
	let fs = fakes.fs({
		'/opt/clash/config.yaml': 'current-active\n',
		'/opt/clash/config2.yaml': 'second-active\n',
		'/opt/clash/config3.yaml': 'third-active\n',
		'/usr/libexec/miclash/validate-config.uc': 'installed-helper\n'
	});
	for (let path in [ '/tmp', '/tmp/miclash', '/tmp/miclash/operations',
		'/opt', '/opt/clash', '/usr', '/usr/libexec', '/usr/libexec/miclash' ])
		if (fs.lstat(path) == null)
			fs.mkdir(path);
	let clock = fakes.clock(1700000000000);
	let process = fakes.process();
	let runtime = {
		fs, clock, process,
		random: fakes.entropy(),
		digest: fakes.digest(fs),
		service: service ?? { reload: () => true, health: () => true },
		paths: { tmp: '/tmp/miclash', run: '/var/run/miclash' }
	};
	let ops = operations.create(runtime);
	ops.recover_interrupted();
	let revisions = history.create(runtime, { diff });
	let cfg = config.create(runtime, ops, revisions);
	return { fs, clock, process, runtime, ops, revisions, cfg };
};

function finish(env, operation) {
	env.clock.advance(0);
	return env.ops.get(operation.id);
};

function validation_key(operation) {
	return '/usr/bin/ucode:-- /usr/libexec/miclash/validate-config.uc ' +
		'/tmp/miclash/candidates/' + operation.id + '/config.yaml';
};

function yaml_count(env) {
	let count = 0;
	for (let name in env.fs.lsdir('/opt/clash/history/config.yaml'))
		if (env.fs.lstat('/opt/clash/history/config.yaml/' + name)?.type == 'directory' &&
		    env.fs.lstat('/opt/clash/history/config.yaml/' + name + '/config.yaml')?.type == 'file')
			count++;
	return count;
};

function added_records(before, after) {
	let known = {};
	for (let record in before)
		known[record.revision] = true;
	let output = [];
	for (let record in after)
		if (!known[record.revision])
			push(output, record);
	return output;
};

let env = environment();
let source_cases = [
	[ 'manual', 'manual' ], [ 'subscription', 'subscription' ], [ 'auto', 'auto' ],
	[ 'Telegram', 'telegram' ], [ 'external', 'external' ], [ 'restore', 'restore' ]
];
let source_records = [];
for (let item in source_cases) {
	env.clock.advance(1);
	push(source_records, env.revisions.snapshot_bytes('config.yaml', item[0],
		'source-' + item[1] + '\n', {
			validation_result: 'success', activation_result: 'success',
			mihomo_version: '1.19.0', operation_id: 'audit-op',
			ignored_secret: 'must-not-be-persisted'
		}));
	assert_equal(source_records[length(source_records) - 1].source, item[1]);
}
let first = source_records[0];
assert_true(match(first.revision,
	/^[0-9]{13}-[0-9a-f]{12}-[0-9a-f]{16}$/) != null);
assert_equal(first.hash, env.runtime.digest.sha256('source-manual\n'));
assert_equal(first.size, length('source-manual\n'));
assert_equal(first.validation_result, 'success');
assert_equal(first.activation_result, 'success');
assert_equal(first.mihomo_version, '1.19.0');
assert_equal(first.operation_id, 'audit-op');
assert_equal(first.ignored_secret, null);
let first_directory = '/opt/clash/history/config.yaml/' + first.revision;
assert_equal(env.fs.mode(first_directory), 0o700);
assert_equal(env.fs.mode(first_directory + '/config.yaml'), 0o600);
assert_equal(env.fs.mode(first_directory + '/metadata.json'), 0o600);
let published = false;
for (let call in env.fs.calls.rename)
	if (call.to == first_directory &&
	    match(call.from, /^\/opt\/clash\/history\/config\.yaml\/\..+\.tmp-[0-9a-f]{16}$/))
		published = true;
assert_true(published);

// Duplicate content keeps a distinct audit record but reuses authenticated bytes.
let yaml_before_duplicate = yaml_count(env);
env.clock.advance(1);
let duplicate = env.revisions.snapshot_bytes('config.yaml', 'manual',
	'source-manual\n', { operation_id: 'duplicate-op' });
assert_true(duplicate.revision != first.revision);
assert_equal(duplicate.duplicate_of, first.revision);
assert_equal(duplicate.content_revision, first.revision);
assert_equal(yaml_count(env), yaml_before_duplicate);
assert_equal(length(env.revisions.list('config.yaml')), 7);

let readfile_before_list = length(env.fs.calls.readfile);
let metadata = env.revisions.list('config.yaml');
for (let index = readfile_before_list; index < length(env.fs.calls.readfile); index++)
	assert_true(!match(env.fs.calls.readfile[index], /\.yaml$/));
assert_equal(metadata[0].corrupt, false);
let fetched = env.revisions.get('config.yaml', first.revision);
assert_equal(fetched.content, 'source-manual\n');
assert_equal(fetched.metadata.revision, first.revision);
assert_equal(env.revisions.read('config.yaml', duplicate.revision), 'source-manual\n');
assert_equal(env.revisions.diff('config.yaml', first.revision,
	source_records[1].revision, LIMITS).changed, true);

// Opening a historical revision affects Draft only and uses one outer operation.
let operations_before = length(env.ops.list());
let opened = env.revisions.open_draft('config.yaml', first.revision, 'luci');
assert_equal(finish(env, opened).state, 'success');
assert_equal(length(env.ops.list()), operations_before + 1);
assert_equal(env.cfg.read_draft('config.yaml'), 'source-manual\n');
assert_equal(env.fs.readfile('/opt/clash/config.yaml'), 'current-active\n');

// Restore is one outer operation. It snapshots current Active before validation;
// failed validation leaves Active unchanged and retains that audit snapshot.
let invalid_revision = env.revisions.snapshot_bytes('config.yaml', 'manual',
	'invalid-selected\n', { validation_result: 'failure' });
let history_before_invalid = env.revisions.list('config.yaml');
operations_before = length(env.ops.list());
let restore_worker_calls = 0;
let restore_worker = env.revisions.restore_in_operation;
assert_true(type(restore_worker) == 'function');
env.revisions.restore_in_operation = (ctx, configuration, profile, revision) => {
	restore_worker_calls++;
	return restore_worker(ctx, configuration, profile, revision);
};
assert_throws(() => env.revisions.restore_in_operation(
	{ id: 'forged' }, env.cfg, 'config.yaml', invalid_revision.revision),
	'INVALID_ARGUMENT');
let invalid_restore = env.revisions.restore(
	'config.yaml', invalid_revision.revision, 'luci');
env.process.replies[validation_key(invalid_restore)] = { code: 1 };
let invalid_done = finish(env, invalid_restore);
assert_equal(invalid_done.state, 'failure');
assert_equal(invalid_done.error.code, 'VALIDATION_FAILED');
assert_equal(length(env.ops.list()), operations_before + 1);
assert_equal(restore_worker_calls, 2);
assert_equal(env.fs.readfile('/opt/clash/config.yaml'), 'current-active\n');
let after_invalid = env.revisions.list('config.yaml');
let invalid_added = added_records(history_before_invalid, after_invalid);
assert_equal(length(invalid_added), 1);
assert_equal(invalid_added[0].source, 'restore-before');
assert_equal(invalid_added[0].restored_revision, invalid_revision.revision);
assert_equal(invalid_added[0].activation_result, 'validation_failed');

operations_before = length(env.ops.list());
let history_before_success = env.revisions.list('config.yaml');
let restored = env.revisions.restore('config.yaml', first.revision, 'luci');
assert_equal(finish(env, restored).state, 'success');
assert_equal(length(env.ops.list()), operations_before + 1);
assert_equal(env.fs.readfile('/opt/clash/config.yaml'), 'source-manual\n');
let success_added = added_records(history_before_success,
	env.revisions.list('config.yaml'));
assert_equal(length(success_added), 2);
assert_equal(success_added[0].source, 'restore-before');
assert_equal(success_added[0].activation_result, 'success');
assert_equal(success_added[1].source, 'restore');
assert_equal(success_added[1].activation_result, 'success');
assert_equal(success_added[1].restored_revision, first.revision);
assert_equal(success_added[1].parent_revision, success_added[0].revision);

// The compatibility config entrypoint has its own one-operation wrapper but
// invokes the same authenticated history worker and produces the same audit.
let compatibility = environment();
let compatibility_selected = compatibility.revisions.snapshot_bytes(
	'config.yaml', 'manual', 'compatibility-selected\n', {});
let compatibility_calls = 0;
let compatibility_worker = compatibility.revisions.restore_in_operation;
compatibility.revisions.restore_in_operation = (ctx, configuration, profile, revision) => {
	compatibility_calls++;
	return compatibility_worker(ctx, configuration, profile, revision);
};
let compatibility_before = compatibility.revisions.list('config.yaml');
let compatibility_operations = length(compatibility.ops.list());
let compatibility_restore = compatibility.cfg.restore(
	'config.yaml', compatibility_selected.revision, 'luci');
assert_equal(finish(compatibility, compatibility_restore).state, 'success');
assert_equal(compatibility_calls, 1);
assert_equal(length(compatibility.ops.list()), compatibility_operations + 1);
let compatibility_added = added_records(compatibility_before,
	compatibility.revisions.list('config.yaml'));
assert_equal(length(compatibility_added), 2);
assert_equal(compatibility_added[0].source, 'restore-before');
assert_equal(compatibility_added[0].activation_result, 'success');
assert_equal(compatibility_added[1].source, 'restore');
assert_equal(compatibility_added[1].activation_result, 'success');
assert_equal(compatibility.fs.readfile('/opt/clash/config.yaml'),
	'compatibility-selected\n');

let compatibility_invalid = environment();
let compatibility_invalid_selected = compatibility_invalid.revisions.snapshot_bytes(
	'config.yaml', 'manual', 'compatibility-invalid\n', {});
let compatibility_invalid_before = compatibility_invalid.revisions.list('config.yaml');
let compatibility_invalid_restore = compatibility_invalid.cfg.restore(
	'config.yaml', compatibility_invalid_selected.revision, 'luci');
compatibility_invalid.process.replies[validation_key(compatibility_invalid_restore)] =
	{ code: 1 };
assert_equal(finish(compatibility_invalid, compatibility_invalid_restore).error.code,
	'VALIDATION_FAILED');
let compatibility_invalid_added = added_records(compatibility_invalid_before,
	compatibility_invalid.revisions.list('config.yaml'));
assert_equal(length(compatibility_invalid_added), 1);
assert_equal(compatibility_invalid_added[0].source, 'restore-before');
assert_equal(compatibility_invalid_added[0].activation_result, 'validation_failed');
assert_equal(compatibility_invalid.fs.readfile('/opt/clash/config.yaml'),
	'current-active\n');

// Health failure follows the project-wide no-automatic-config-rollback rule.
let unhealthy = environment({ reload: () => true, health: () => false });
let unhealthy_selected = unhealthy.revisions.snapshot_bytes('config.yaml', 'manual',
	'new-active\n', {});
let unhealthy_restore = unhealthy.revisions.restore(
	'config.yaml', unhealthy_selected.revision, 'luci');
let unhealthy_before = unhealthy.revisions.list('config.yaml');
let unhealthy_done = finish(unhealthy, unhealthy_restore);
assert_equal(unhealthy_done.state, 'failure');
assert_equal(unhealthy_done.error.code, 'HEALTH_FAILED');
assert_equal(unhealthy.fs.readfile('/opt/clash/config.yaml'), 'new-active\n');
let unhealthy_added = added_records(unhealthy_before,
	unhealthy.revisions.list('config.yaml'));
assert_equal(length(unhealthy_added), 2);
assert_equal(unhealthy_added[0].source, 'restore-before');
assert_equal(unhealthy_added[0].activation_result, 'health_failed');
assert_equal(unhealthy_added[1].source, 'restore');
assert_equal(unhealthy_added[1].activation_result, 'health_failed');

function retention_environment() {
	let current = environment();
	let records = [];
	for (let index = 0; index < 12; index++) {
		current.clock.advance(1);
		push(records, current.revisions.snapshot_bytes('config.yaml', 'auto',
			'revision-' + index + '\n', {}));
	}
	return { ...current, records };
};

let retained = retention_environment();
assert_equal(retained.revisions.prune('config.yaml'), 2);
assert_equal(length(retained.revisions.list('config.yaml')), 10);

let protected_current = retention_environment();
protected_current.fs.writefile('/opt/clash/history/active-config.yaml.json',
	sprintf('%J', { profile: 'config.yaml', hash: protected_current.records[0].hash,
		operation_id: 'protected', updated_at: protected_current.clock.now() }));
protected_current.fs.set_mode('/opt/clash/history/active-config.yaml.json', 0o600);
assert_equal(protected_current.revisions.prune('config.yaml'), 1);
assert_equal(length(protected_current.revisions.list('config.yaml')), 11);

let protected_restore = retention_environment();
protected_restore.clock.advance(1);
protected_restore.revisions.snapshot_bytes('config.yaml', 'restore', 'latest\n', {
		restored_revision: protected_restore.records[0].revision
});
protected_restore.revisions.prune('config.yaml');
let restore_ids = {};
for (let record in protected_restore.revisions.list('config.yaml'))
	restore_ids[record.revision] = true;
assert_true(restore_ids[protected_restore.records[0].revision]);

let foreign_path = '/opt/clash/history/config.yaml/foreign-entry';
protected_restore.fs.writefile(foreign_path, 'foreign');
protected_restore.revisions.prune('config.yaml');
assert_equal(protected_restore.fs.readfile(foreign_path), 'foreign');

// Recognized corrupt revisions stay visible, are never executed, and pruning
// neither follows nor silently deletes them.
let corrupt = environment();
let corrupt_record = corrupt.revisions.snapshot_bytes('config.yaml', 'manual',
	'corrupt-me\n', {});
let corrupt_json = '/opt/clash/history/config.yaml/' + corrupt_record.revision + '/metadata.json';
corrupt.fs.writefile(corrupt_json, '{broken');
let corrupt_list = corrupt.revisions.list('config.yaml');
assert_equal(length(corrupt_list), 1);
assert_equal(corrupt_list[0].revision, corrupt_record.revision);
assert_equal(corrupt_list[0].corrupt, true);
assert_equal(corrupt_list[0].error, 'CORRUPT_STATE');
assert_throws(() => corrupt.revisions.get(
	'config.yaml', corrupt_record.revision), 'CORRUPT_STATE');
assert_equal(corrupt.revisions.prune('config.yaml'), 0);
assert_true(corrupt.fs.lstat(corrupt_json) != null);

let linked = environment();
let linked_record = linked.revisions.snapshot_bytes('config.yaml', 'manual', 'owned\n', {});
let linked_yaml = '/opt/clash/history/config.yaml/' + linked_record.revision + '/config.yaml';
linked.fs.set_symlink(linked_yaml, '/opt/clash/config.yaml');
assert_throws(() => linked.revisions.get(
	'config.yaml', linked_record.revision), 'CORRUPT_STATE');
assert_equal(linked.revisions.list('config.yaml')[0].corrupt, true);
let linked_process_calls = length(linked.process.calls);
let linked_restore = linked.revisions.restore(
	'config.yaml', linked_record.revision, 'luci');
assert_equal(finish(linked, linked_restore).error.code, 'CORRUPT_STATE');
assert_equal(length(linked.process.calls), linked_process_calls);
assert_equal(linked.fs.readfile('/opt/clash/config.yaml'), 'current-active\n');

let linked_count = environment();
let linked_count_record = linked_count.revisions.snapshot_bytes(
	'config.yaml', 'manual', 'owned\n', {});
let linked_count_yaml = '/opt/clash/history/config.yaml/' +
	linked_count_record.revision + '/config.yaml';
linked_count.fs.set_nlink(linked_count_yaml, 2);
assert_throws(() => linked_count.revisions.get(
	'config.yaml', linked_count_record.revision), 'CORRUPT_STATE');

let wrong_owner = environment();
let wrong_owner_record = wrong_owner.revisions.snapshot_bytes(
	'config.yaml', 'manual', 'owned\n', {});
wrong_owner.fs.set_uid('/opt/clash/history/config.yaml/' +
	wrong_owner_record.revision + '/metadata.json', 1000);
assert_equal(wrong_owner.revisions.list('config.yaml')[0].corrupt, true);

// Previous paired revisions remain readable but are never selected for pruning
// or used as a destination for new snapshots.
let legacy = environment();
let legacy_revision = '1699999999999-abcdefabcdefabcd';
let legacy_content = 'legacy-active\n';
let legacy_base = '/opt/clash/history/config.yaml/' + legacy_revision;
legacy.fs.writefile(legacy_base + '.yaml', legacy_content);
legacy.fs.set_mode(legacy_base + '.yaml', 0o600);
legacy.fs.writefile(legacy_base + '.json', sprintf('%J\n', {
	revision: legacy_revision,
	filename: legacy_revision + '.yaml',
	profile: 'config.yaml', source: 'luci', timestamp: 1699999999999,
	hash: legacy.runtime.digest.sha256(legacy_content),
	validation_result: 'success', activation_result: 'success',
	mihomo_version: null, operation_id: 'legacy-op'
}));
legacy.fs.set_mode(legacy_base + '.json', 0o600);
assert_equal(legacy.revisions.read('config.yaml', legacy_revision), legacy_content);
assert_equal(legacy.revisions.list('config.yaml')[0].corrupt, false);
assert_equal(legacy.revisions.prune('config.yaml'), 0);
assert_true(legacy.fs.lstat(legacy_base + '.yaml') != null);
assert_true(legacy.fs.lstat(legacy_base + '.json') != null);
