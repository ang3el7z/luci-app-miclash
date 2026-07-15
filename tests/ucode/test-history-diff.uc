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

function revision_directory(record) {
	return '/opt/clash/history/' + record.profile + '/' + record.revision;
};

function read_revision_metadata(env, record) {
	return json(env.fs.readfile(revision_directory(record) + '/metadata.json'));
};

function write_revision_metadata(env, record, metadata) {
	let path = revision_directory(record) + '/metadata.json';
	env.fs.writefile(path, sprintf('%J\n', metadata));
	env.fs.set_mode(path, 0o600);
};

function remove_revision_directory(env, record) {
	let directory = revision_directory(record);
	for (let name in [ 'config.yaml', 'metadata.json' ])
		if (env.fs.lstat(directory + '/' + name) != null)
			env.fs.unlink(directory + '/' + name);
	assert_equal(env.fs.rmdir(directory), true);
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
	    match(call.from, /^\/opt\/clash\/history\/config\.yaml\/\.stage-.+-[0-9a-f]{16}$/))
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

// Metadata-only aliases are public-valid only when their target is a direct,
// authenticated self-content canonical record in the same profile.
let dangling_alias = environment();
let dangling_canonical = dangling_alias.revisions.snapshot_bytes(
	'config.yaml', 'manual', 'same-content\n', {});
let dangling = dangling_alias.revisions.snapshot_bytes(
	'config.yaml', 'manual', 'same-content\n', {});
remove_revision_directory(dangling_alias, dangling_canonical);
assert_equal(dangling_alias.revisions.list('config.yaml')[0].revision, dangling.revision);
assert_equal(dangling_alias.revisions.list('config.yaml')[0].corrupt, true);
assert_throws(() => dangling_alias.revisions.get(
	'config.yaml', dangling.revision), 'CORRUPT_STATE');

let corrupt_target = environment();
let corrupt_canonical = corrupt_target.revisions.snapshot_bytes(
	'config.yaml', 'manual', 'same-content\n', {});
let corrupt_alias = corrupt_target.revisions.snapshot_bytes(
	'config.yaml', 'manual', 'same-content\n', {});
write_revision_metadata(corrupt_target, corrupt_canonical, { broken: true });
let corrupt_target_list = corrupt_target.revisions.list('config.yaml');
assert_equal(corrupt_target_list[0].corrupt, true);
assert_equal(corrupt_target_list[1].corrupt, true);

let chained = environment();
let chain_canonical = chained.revisions.snapshot_bytes(
	'config.yaml', 'manual', 'same-content\n', {});
let chain_alias = chained.revisions.snapshot_bytes(
	'config.yaml', 'manual', 'same-content\n', {});
let chain_leaf = chained.revisions.snapshot_bytes(
	'config.yaml', 'manual', 'same-content\n', {});
let chain_leaf_metadata = read_revision_metadata(chained, chain_leaf);
chain_leaf_metadata.content_revision = chain_alias.revision;
chain_leaf_metadata.duplicate_of = chain_alias.revision;
write_revision_metadata(chained, chain_leaf, chain_leaf_metadata);
let chain_by_id = {};
for (let record in chained.revisions.list('config.yaml'))
	chain_by_id[record.revision] = record;
assert_equal(chain_by_id[chain_canonical.revision].corrupt, false);
assert_equal(chain_by_id[chain_alias.revision].corrupt, false);
assert_equal(chain_by_id[chain_leaf.revision].corrupt, true);

let cyclic = environment();
let cycle_canonical = cyclic.revisions.snapshot_bytes(
	'config.yaml', 'manual', 'same-content\n', {});
let cycle_left = cyclic.revisions.snapshot_bytes(
	'config.yaml', 'manual', 'same-content\n', {});
let cycle_right = cyclic.revisions.snapshot_bytes(
	'config.yaml', 'manual', 'same-content\n', {});
let cycle_left_metadata = read_revision_metadata(cyclic, cycle_left);
let cycle_right_metadata = read_revision_metadata(cyclic, cycle_right);
cycle_left_metadata.content_revision = cycle_right.revision;
cycle_left_metadata.duplicate_of = cycle_right.revision;
cycle_right_metadata.content_revision = cycle_left.revision;
cycle_right_metadata.duplicate_of = cycle_left.revision;
write_revision_metadata(cyclic, cycle_left, cycle_left_metadata);
write_revision_metadata(cyclic, cycle_right, cycle_right_metadata);
let cycle_by_id = {};
for (let record in cyclic.revisions.list('config.yaml'))
	cycle_by_id[record.revision] = record;
assert_equal(cycle_by_id[cycle_canonical.revision].corrupt, false);
assert_equal(cycle_by_id[cycle_left.revision].corrupt, true);
assert_equal(cycle_by_id[cycle_right.revision].corrupt, true);

// Parent and restore ancestry is part of revision authentication. References
// must resolve directly in the same profile, and the graph must be acyclic.
let missing_ancestry = environment();
let missing_root = missing_ancestry.revisions.snapshot_bytes(
	'config.yaml', 'manual', 'missing-root\n', {});
let missing_dependent = missing_ancestry.revisions.snapshot_bytes(
	'config.yaml', 'restore', 'missing-dependent\n', {});
let missing_metadata = read_revision_metadata(missing_ancestry, missing_dependent);
missing_metadata.parent_revision =
	'1700000000999-0123456789ab-0123456789abcdef';
write_revision_metadata(missing_ancestry, missing_dependent, missing_metadata);
let missing_by_id = {};
for (let record in missing_ancestry.revisions.list('config.yaml'))
	missing_by_id[record.revision] = record;
assert_equal(missing_by_id[missing_root.revision].corrupt, false);
assert_equal(missing_by_id[missing_dependent.revision].corrupt, true);
assert_throws(() => missing_ancestry.revisions.read(
	'config.yaml', missing_dependent.revision), 'CORRUPT_STATE');

let rejected_ancestry = environment();
assert_throws(() => rejected_ancestry.revisions.snapshot_bytes(
	'config.yaml', 'restore', 'must-not-publish\n', {
		parent_revision: '1700000000999-0123456789ab-0123456789abcdef'
	}), 'CORRUPT_STATE');
assert_equal(length(rejected_ancestry.revisions.list('config.yaml')), 0);

let cross_profile_ancestry = environment();
let other_profile = cross_profile_ancestry.revisions.snapshot_bytes(
	'config2.yaml', 'manual', 'other-profile\n', {});
let cross_profile_dependent = cross_profile_ancestry.revisions.snapshot_bytes(
	'config.yaml', 'restore', 'cross-profile-dependent\n', {});
let cross_profile_metadata = read_revision_metadata(
	cross_profile_ancestry, cross_profile_dependent);
cross_profile_metadata.restored_revision = other_profile.revision;
write_revision_metadata(cross_profile_ancestry, cross_profile_dependent,
	cross_profile_metadata);
assert_equal(cross_profile_ancestry.revisions.list(
	'config.yaml')[0].corrupt, true);

let ancestry_cycle = environment();
let ancestry_left = ancestry_cycle.revisions.snapshot_bytes(
	'config.yaml', 'manual', 'ancestry-left\n', {});
let ancestry_right = ancestry_cycle.revisions.snapshot_bytes(
	'config.yaml', 'manual', 'ancestry-right\n', {});
let ancestry_left_metadata = read_revision_metadata(ancestry_cycle, ancestry_left);
let ancestry_right_metadata = read_revision_metadata(ancestry_cycle, ancestry_right);
ancestry_left_metadata.parent_revision = ancestry_right.revision;
ancestry_right_metadata.restored_revision = ancestry_left.revision;
write_revision_metadata(ancestry_cycle, ancestry_left, ancestry_left_metadata);
write_revision_metadata(ancestry_cycle, ancestry_right, ancestry_right_metadata);
let ancestry_cycle_by_id = {};
for (let record in ancestry_cycle.revisions.list('config.yaml'))
	ancestry_cycle_by_id[record.revision] = record;
assert_equal(ancestry_cycle_by_id[ancestry_left.revision].corrupt, true);
assert_equal(ancestry_cycle_by_id[ancestry_right.revision].corrupt, true);

let unauthenticated_coalesce = environment();
let unauthenticated_original = unauthenticated_coalesce.revisions.snapshot_bytes(
	'config.yaml', 'manual', 'same-content\n', {});
write_revision_metadata(unauthenticated_coalesce, unauthenticated_original,
	{ broken: true });
let replacement_canonical = unauthenticated_coalesce.revisions.snapshot_bytes(
	'config.yaml', 'manual', 'same-content\n', {});
assert_equal(replacement_canonical.duplicate_of, null);
assert_true(unauthenticated_coalesce.fs.lstat(
	revision_directory(replacement_canonical) + '/config.yaml')?.type == 'file');

// New IDs bind the persisted timestamp and hash prefix. Corrupt metadata never
// influences the next logical timestamp or turns a safe snapshot into a DoS.
let inconsistent_id = environment();
let inconsistent = inconsistent_id.revisions.snapshot_bytes(
	'config.yaml', 'manual', 'first\n', {});
let inconsistent_metadata = read_revision_metadata(inconsistent_id, inconsistent);
inconsistent_metadata.timestamp = 9999999999999;
write_revision_metadata(inconsistent_id, inconsistent, inconsistent_metadata);
assert_equal(inconsistent_id.revisions.list('config.yaml')[0].corrupt, true);
let after_inconsistent = inconsistent_id.revisions.snapshot_bytes(
	'config.yaml', 'manual', 'second\n', {});
assert_equal(after_inconsistent.timestamp, inconsistent_id.clock.now());

let hash_prefix = environment();
let hash_mismatch = hash_prefix.revisions.snapshot_bytes(
	'config.yaml', 'manual', 'first\n', {});
let replacement_bytes = 'replacement\n';
let hash_metadata = read_revision_metadata(hash_prefix, hash_mismatch);
hash_metadata.hash = hash_prefix.runtime.digest.sha256(replacement_bytes);
hash_metadata.size = length(replacement_bytes);
hash_prefix.fs.writefile(revision_directory(hash_mismatch) + '/config.yaml', replacement_bytes);
hash_prefix.fs.set_mode(revision_directory(hash_mismatch) + '/config.yaml', 0o600);
write_revision_metadata(hash_prefix, hash_mismatch, hash_metadata);
assert_equal(hash_prefix.revisions.list('config.yaml')[0].corrupt, true);

let collision = environment();
let collision_hash = collision.runtime.digest.sha256('collision\n');
let collision_revision = sprintf('%013d-%s-%s', collision.clock.now(),
	substr(collision_hash, 0, 12), '0000000000000001');
let collision_path = '/opt/clash/history/config.yaml/' + collision_revision;
collision.fs.mkdir(collision_path);
collision.fs.chmod(collision_path, 0o700);
collision.fs.writefile(collision_path + '/foreign', 'foreign');
let after_collision_record = collision.revisions.snapshot_bytes(
	'config.yaml', 'manual', 'collision\n', {});
assert_true(after_collision_record.revision != collision_revision);
assert_equal(collision.fs.readfile(collision_path + '/foreign'), 'foreign');

// A metadata-valid maximum timestamp cannot influence generation until its
// canonical bytes have also authenticated against the recorded size and hash.
let corrupt_maximum = environment();
let corrupt_maximum_record = corrupt_maximum.revisions.snapshot_bytes(
	'config.yaml', 'manual', 'maximum-original\n', {});
let corrupt_maximum_metadata = read_revision_metadata(
	corrupt_maximum, corrupt_maximum_record);
let corrupt_maximum_revision = '9999999999999-' +
	substr(corrupt_maximum_record.hash, 0, 12) + '-' +
	split(corrupt_maximum_record.revision, '-')[2];
corrupt_maximum_metadata.revision = corrupt_maximum_revision;
corrupt_maximum_metadata.timestamp = 9999999999999;
corrupt_maximum_metadata.content_revision = corrupt_maximum_revision;
corrupt_maximum.fs.rename(revision_directory(corrupt_maximum_record),
	'/opt/clash/history/config.yaml/' + corrupt_maximum_revision);
corrupt_maximum_record.revision = corrupt_maximum_revision;
write_revision_metadata(corrupt_maximum, corrupt_maximum_record,
	corrupt_maximum_metadata);
corrupt_maximum.fs.writefile(
	revision_directory(corrupt_maximum_record) + '/config.yaml', 'tampered\n');
corrupt_maximum.fs.set_mode(
	revision_directory(corrupt_maximum_record) + '/config.yaml', 0o600);
let after_corrupt_maximum = corrupt_maximum.revisions.snapshot_bytes(
	'config.yaml', 'manual', 'safe-after-corrupt\n', {});
assert_equal(after_corrupt_maximum.timestamp, corrupt_maximum.clock.now());

let maximum = environment();
let maximum_record = maximum.revisions.snapshot_bytes(
	'config.yaml', 'manual', 'maximum\n', {});
let maximum_metadata = read_revision_metadata(maximum, maximum_record);
let maximum_revision = '9999999999999-' + substr(maximum_record.hash, 0, 12) + '-' +
	split(maximum_record.revision, '-')[2];
maximum_metadata.revision = maximum_revision;
maximum_metadata.timestamp = 9999999999999;
maximum_metadata.content_revision = maximum_revision;
maximum.fs.rename(revision_directory(maximum_record),
	'/opt/clash/history/config.yaml/' + maximum_revision);
maximum_record.revision = maximum_revision;
write_revision_metadata(maximum, maximum_record, maximum_metadata);
assert_equal(maximum.revisions.list('config.yaml')[0].corrupt, false);
assert_throws(() => maximum.revisions.snapshot_bytes(
	'config.yaml', 'manual', 'beyond-maximum\n', {}), 'INTERNAL');

function assert_cross_layout_rejected(current, revision) {
	let found = null;
	for (let record in current.revisions.list('config.yaml'))
		if (record.revision == revision)
			found = record;
	assert_equal(found?.corrupt, true);
	assert_throws(() => current.revisions.read(
		'config.yaml', revision), 'CORRUPT_STATE');
	assert_throws(() => current.revisions.get(
		'config.yaml', revision), 'CORRUPT_STATE');
	let opened = current.revisions.open_draft('config.yaml', revision, 'luci');
	assert_equal(finish(current, opened).error.code, 'CORRUPT_STATE');
	let restored = current.revisions.restore('config.yaml', revision, 'luci');
	assert_equal(finish(current, restored).error.code, 'CORRUPT_STATE');
};

// Three-part IDs are directory-only. A paired-file lookalike is visible as
// corrupt and is rejected by every content-consuming entrypoint.
let new_as_legacy = environment();
let new_as_legacy_record = new_as_legacy.revisions.snapshot_bytes(
	'config.yaml', 'manual', 'new-as-legacy\n', {});
let new_as_legacy_revision = new_as_legacy_record.revision;
remove_revision_directory(new_as_legacy, new_as_legacy_record);
let new_as_legacy_base = '/opt/clash/history/config.yaml/' +
	new_as_legacy_revision;
new_as_legacy.fs.writefile(new_as_legacy_base + '.yaml', 'new-as-legacy\n');
new_as_legacy.fs.set_mode(new_as_legacy_base + '.yaml', 0o600);
new_as_legacy.fs.writefile(new_as_legacy_base + '.json', sprintf('%J\n', {
	revision: new_as_legacy_revision,
	filename: new_as_legacy_revision + '.yaml', profile: 'config.yaml',
	source: 'manual', timestamp: new_as_legacy_record.timestamp,
	hash: new_as_legacy_record.hash, validation_result: null,
	activation_result: null, mihomo_version: null, operation_id: null,
	parent_revision: null, restored_revision: null
}));
new_as_legacy.fs.set_mode(new_as_legacy_base + '.json', 0o600);
assert_cross_layout_rejected(new_as_legacy, new_as_legacy_revision);

// Two-part legacy IDs are paired-file-only. A directory lookalike is likewise
// visible but never read, opened, or restored.
let legacy_as_new = environment();
let legacy_as_new_content = 'legacy-as-new\n';
let legacy_as_new_hash = legacy_as_new.runtime.digest.sha256(legacy_as_new_content);
let legacy_as_new_revision = '1699999999999-abcdefabcdefabcd';
let legacy_as_new_base = '/opt/clash/history/config.yaml/' +
	legacy_as_new_revision;
legacy_as_new.fs.mkdir(legacy_as_new_base);
legacy_as_new.fs.chmod(legacy_as_new_base, 0o700);
legacy_as_new.fs.writefile(legacy_as_new_base + '/config.yaml',
	legacy_as_new_content);
legacy_as_new.fs.set_mode(legacy_as_new_base + '/config.yaml', 0o600);
legacy_as_new.fs.writefile(legacy_as_new_base + '/metadata.json', sprintf('%J\n', {
	revision: legacy_as_new_revision, filename: 'config.yaml',
	profile: 'config.yaml', source: 'manual', timestamp: 1699999999999,
	hash: legacy_as_new_hash, size: length(legacy_as_new_content),
	validation_result: null, activation_result: null, mihomo_version: null,
	operation_id: null, parent_revision: null, restored_revision: null,
	content_revision: legacy_as_new_revision, duplicate_of: null
}));
legacy_as_new.fs.set_mode(legacy_as_new_base + '/metadata.json', 0o600);
assert_cross_layout_rejected(legacy_as_new, legacy_as_new_revision);

// Opening a historical revision affects Draft only and uses one outer operation.
let operations_before = length(env.ops.list());
let opened = env.revisions.open_draft('config.yaml', first.revision, 'luci');
assert_equal(finish(env, opened).state, 'success');
assert_equal(length(env.ops.list()), operations_before + 1);
assert_equal(env.cfg.read_draft('config.yaml'), 'source-manual\n');
assert_equal(env.fs.readfile('/opt/clash/config.yaml'), 'current-active\n');

// Restore is one outer operation. It snapshots current Active before validation;
// failed validation leaves Active unchanged and retains that audit snapshot.
let release = environment();
let release_selected = release.revisions.snapshot_bytes(
	'config.yaml', 'manual', 'release-selected\n', {});
assert_true(type(release.cfg.release_restore_capture_in_operation) == 'function');
assert_throws(() => release.cfg.release_restore_capture_in_operation(
	{ id: 'forged' }, {}), 'INVALID_ARGUMENT');
let release_snapshot = release.revisions.snapshot_bytes;
release.revisions.snapshot_bytes = (profile, source, content, metadata) => {
	if (source == 'restore-before')
		die('INTERNAL');
	return release_snapshot(profile, source, content, metadata);
};
let release_probes = 0;
let release_operation = release.ops.submit('history.restore', 'luci',
	{ profile: 'config.yaml' }, (ctx) => {
		for (let attempt = 0; attempt < 3; attempt++) {
			assert_throws(() => release.revisions.restore_in_operation(
				ctx, release.cfg, 'config.yaml', release_selected.revision), 'INTERNAL');
			let probe = release.cfg.capture_active_in_operation(ctx, 'config.yaml');
			assert_throws(() => release.cfg.release_restore_capture_in_operation(
				ctx, {}), 'INVALID_ARGUMENT');
			assert_equal(release.cfg.release_restore_capture_in_operation(
				ctx, probe), true);
			assert_throws(() => release.cfg.release_restore_capture_in_operation(
				ctx, probe), 'INVALID_ARGUMENT');
			release_probes++;
		}
	});
assert_equal(finish(release, release_operation).state, 'success');
assert_equal(release_probes, 3);

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

function auxiliary_entries(env) {
	let output = [];
	for (let name in env.fs.lsdir('/opt/clash/history/config.yaml'))
		if (match(name, /^\.(stage|prune)-/))
			push(output, name);
	return output;
};

function retry_prune_after_failure(kind) {
	let current = retention_environment();
	if (kind == 'rename')
		current.fs.throw_after_rename_once_matching = '/.prune-';
	else if (kind == 'content-unlink')
		current.fs.fail_unlink_once_matching = '/config.yaml';
	else if (kind == 'metadata-unlink')
		current.fs.fail_unlink_once_matching = '/metadata.json';
	else if (kind == 'rmdir')
		current.fs.fail_rmdir_once = true;
	assert_throws(() => current.revisions.prune('config.yaml'), 'INTERNAL');
	assert_true(length(auxiliary_entries(current)) >= 1);
	// Both create-time and prune-time recovery are idempotent. A fresh store may
	// clean the exact tombstone, and the original store can safely finish prune.
	history.create(current.runtime, { diff });
	current.revisions.prune('config.yaml');
	assert_equal(length(current.revisions.list('config.yaml')), 10);
	assert_equal(length(auxiliary_entries(current)), 0);
};

for (let boundary in [ 'rename', 'content-unlink', 'metadata-unlink', 'rmdir' ])
	retry_prune_after_failure(boundary);

// Aliases leave the visible namespace before their canonical content. A crash
// after the first tombstone rename cannot expose a dangling visible alias.
let dependency = environment();
let dependency_canonical = dependency.revisions.snapshot_bytes(
	'config.yaml', 'manual', 'dependency\n', {});
dependency.revisions.snapshot_bytes('config.yaml', 'manual', 'dependency\n', {});
for (let index = 0; index < 11; index++) {
	dependency.clock.advance(1);
	dependency.revisions.snapshot_bytes('config.yaml', 'auto',
		'dependency-new-' + index + '\n', {});
}
dependency.fs.throw_after_rename_once_matching = '/.prune-';
assert_throws(() => dependency.revisions.prune('config.yaml'), 'INTERNAL');
let dependency_visible = dependency.revisions.list('config.yaml');
for (let record in dependency_visible)
	assert_equal(record.corrupt, false);
let canonical_still_visible = false;
for (let record in dependency_visible)
	if (record.revision == dependency_canonical.revision)
		canonical_still_visible = true;
assert_true(canonical_still_visible);
dependency.revisions.prune('config.yaml');
assert_equal(length(auxiliary_entries(dependency)), 0);

// Restore from an alias creates both an aliased restore audit and an aliased
// restore-before audit. Repeated crashes after every tombstone rename must leave
// a healthy visible graph, and retry must converge to the retention limit.
let graph_prune = environment();
graph_prune.clock.advance(1);
let graph_current = graph_prune.revisions.snapshot_bytes(
	'config.yaml', 'manual', 'current-active\n', {});
graph_prune.clock.advance(1);
let graph_selected = graph_prune.revisions.snapshot_bytes(
	'config.yaml', 'manual', 'graph-selected\n', {});
graph_prune.clock.advance(1);
let graph_selected_alias = graph_prune.revisions.snapshot_bytes(
	'config.yaml', 'manual', 'graph-selected\n', {});
assert_equal(graph_selected_alias.duplicate_of, graph_selected.revision);
let graph_restore = graph_prune.revisions.restore(
	'config.yaml', graph_selected_alias.revision, 'luci');
assert_equal(finish(graph_prune, graph_restore).state, 'success');
let graph_restore_before = null;
let graph_restore_audit = null;
for (let record in graph_prune.revisions.list('config.yaml')) {
	if (record.source == 'restore-before')
		graph_restore_before = record;
	else if (record.source == 'restore')
		graph_restore_audit = record;
}
assert_equal(graph_restore_before.duplicate_of, graph_current.revision);
assert_equal(graph_restore_audit.duplicate_of, graph_selected.revision);
assert_equal(graph_restore_audit.parent_revision, graph_restore_before.revision);
assert_equal(graph_restore_audit.restored_revision, graph_selected_alias.revision);
let newest_graph_content = null;
for (let index = 0; index < 12; index++) {
	graph_prune.clock.advance(1);
	newest_graph_content = 'graph-new-' + index + '\n';
	graph_prune.revisions.snapshot_bytes(
		'config.yaml', 'auto', newest_graph_content, {});
}
graph_prune.fs.writefile('/opt/clash/config.yaml', newest_graph_content);
graph_prune.fs.set_mode('/opt/clash/config.yaml', 0o600);
graph_prune.fs.writefile('/opt/clash/history/active-config.yaml.json', sprintf('%J\n', {
	profile: 'config.yaml', hash: graph_prune.runtime.digest.sha256(newest_graph_content),
	operation_id: 'graph-active', updated_at: graph_prune.clock.now()
}));
graph_prune.fs.set_mode('/opt/clash/history/active-config.yaml.json', 0o600);
let graph_initial_count = length(graph_prune.revisions.list('config.yaml'));
let graph_remove_count = graph_initial_count - 10;
assert_true(graph_remove_count > 3);
for (let removed = 0; removed < graph_remove_count; removed++) {
	graph_prune.fs.throw_after_rename_once_matching = '/.prune-';
	let prune_failure = null;
	let prune_result = null;
	try { prune_result = graph_prune.revisions.prune('config.yaml'); }
	catch (error) { prune_failure = error; }
	assert_true(prune_failure != null,
		sprintf('expected prune crash after rename %d/%d, result=%J',
			removed + 1, graph_remove_count, prune_result));
	assert_equal(prune_failure.code ?? prune_failure.message, 'INTERNAL');
	let visible = graph_prune.revisions.list('config.yaml');
	assert_equal(length(visible), graph_initial_count - removed - 1);
	for (let record in visible)
		assert_equal(record.corrupt, false);
}
assert_equal(graph_prune.revisions.prune('config.yaml'), 0);
assert_equal(length(graph_prune.revisions.list('config.yaml')), 10);
assert_equal(length(auxiliary_entries(graph_prune)), 0);

// Exact owned staging/tombstone directories are recovered; foreign names and
// unsafe lookalikes are never followed or deleted.
let recovery = environment();
let recovery_revision = '1700000000999-0123456789ab-0123456789abcdef';
let stage_name = '.stage-' + recovery_revision + '-aaaaaaaaaaaaaaaa';
let prune_name = '.prune-' + recovery_revision + '-bbbbbbbbbbbbbbbb';
let profile_directory = '/opt/clash/history/config.yaml';
if (recovery.fs.lstat(profile_directory) == null) {
	recovery.fs.mkdir(profile_directory);
	recovery.fs.chmod(profile_directory, 0o700);
}
for (let name in [ stage_name, prune_name ]) {
	recovery.fs.mkdir(profile_directory + '/' + name);
	recovery.fs.chmod(profile_directory + '/' + name, 0o700);
	recovery.fs.writefile(profile_directory + '/' + name + '/metadata.json', '{}\n');
	recovery.fs.set_mode(profile_directory + '/' + name + '/metadata.json', 0o600);
}
recovery.fs.writefile(profile_directory + '/foreign-entry', 'foreign');
history.create(recovery.runtime, { diff });
assert_equal(recovery.fs.lstat(profile_directory + '/' + stage_name), null);
assert_equal(recovery.fs.lstat(profile_directory + '/' + prune_name), null);
assert_equal(recovery.fs.readfile(profile_directory + '/foreign-entry'), 'foreign');

let unsafe_recovery = environment();
let unsafe_name = '.stage-' + recovery_revision + '-cccccccccccccccc';
unsafe_recovery.fs.set_symlink(
	'/opt/clash/history/config.yaml/' + unsafe_name, '/opt/clash');
assert_throws(() => history.create(unsafe_recovery.runtime, { diff }),
	'CORRUPT_STATE');
assert_equal(unsafe_recovery.fs.lstat(
	'/opt/clash/history/config.yaml/' + unsafe_name)?.type, 'link');

let recovery_bound = environment();
recovery_bound.fs.mkdir('/opt/clash/history/config.yaml');
recovery_bound.fs.chmod('/opt/clash/history/config.yaml', 0o700);
for (let index = 0; index < 257; index++)
	recovery_bound.fs.writefile('/opt/clash/history/config.yaml/foreign-' + index, 'x');
assert_throws(() => history.create(recovery_bound.runtime, { diff }),
	'RESPONSE_TOO_LARGE');

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
let legacy_mismatch = json(legacy.fs.readfile(legacy_base + '.json'));
legacy_mismatch.timestamp++;
legacy.fs.writefile(legacy_base + '.json', sprintf('%J\n', legacy_mismatch));
legacy.fs.set_mode(legacy_base + '.json', 0o600);
assert_equal(legacy.revisions.list('config.yaml')[0].corrupt, true);
