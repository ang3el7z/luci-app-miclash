import { assert_equal, assert_match, assert_throws, assert_true } from 'testlib';
import * as config from 'miclash.config';
import * as history from 'miclash.history';
import * as operations from 'miclash.operations';
import * as schema from 'miclash.schema';
import * as fakes from 'fakes';

function fixture(name) {
	return require('fs').readfile('tests/fixtures/config/' + name);
};

function validation_key(id) {
	return '/usr/bin/ucode:-- /usr/libexec/miclash/validate-config.uc ' +
		'/tmp/miclash/candidates/' + id + '/config.yaml';
};

function environment(service, setup) {
	let fs = fakes.fs({
		'/opt/clash/config.yaml': 'original-active\n',
		'/opt/clash/config2.yaml': 'second-active\n',
		'/opt/clash/config3.yaml': 'third-active\n',
		'/usr/libexec/miclash/validate-config.uc': 'installed-helper\n'
	});
	for (let path in [ '/tmp', '/tmp/miclash', '/tmp/miclash/operations',
		'/opt', '/opt/clash' ])
		fs.mkdir(path);
	if (type(setup) == 'function')
		setup(fs);
	let clock = fakes.clock(1700000000000);
	let process = fakes.process();
	let rt = {
		fs,
		clock,
		process,
		random: fakes.entropy(),
		digest: fakes.digest(fs),
		service: service ?? {
			reload: () => true,
			health: () => true
		},
		paths: { tmp: '/tmp/miclash', run: '/var/run/miclash' }
	};
	let ops = operations.create(rt);
	ops.recover_interrupted();
	let revisions = history.create(rt);
	let cfg = config.create(rt, ops, revisions);
	return { fs, clock, process, rt, ops, revisions, cfg };
};

function finish(env, record) {
	env.clock.advance(0);
	return env.ops.get(record.id);
};

// Only the three on-disk profile names are accepted.
for (let profile in [ 'config.yaml', 'config2.yaml', 'config3.yaml' ])
	assert_equal(schema.profile_name(profile), profile);
for (let profile in [ 'config0.yaml', 'config1.yaml', 'config4.yaml', '../config.yaml' ])
	assert_throws(() => schema.profile_name(profile), 'INVALID_ARGUMENT');

let env = environment();
assert_equal(join(',', env.cfg.list_profiles()), 'config.yaml,config2.yaml,config3.yaml');
assert_equal(env.cfg.read_active('config.yaml'), 'original-active\n');
assert_equal(env.cfg.detect_external('config.yaml').changed, true);
assert_equal(env.cfg.read_draft('config.yaml'), null);
assert_equal(finish(env, env.cfg.save_draft('config.yaml', 'draft-secret: value\n', 'luci')).state,
	'success');
assert_equal(env.cfg.read_draft('config.yaml'), 'draft-secret: value\n');
assert_equal(env.fs.mode('/opt/clash/history/drafts/config.yaml'), 0o600);

// Validation is queued, uses the operation ID as its unique owned Candidate,
// returns only canonical safe errors, and never changes Active or Draft.
let before = env.fs.readfile('/opt/clash/config.yaml');
let invalid_key;
let invalid = env.cfg.validate('config.yaml', fixture('invalid.yaml'), 'luci');
env.process.replies = {};
invalid_key = validation_key(invalid.id);
env.process.replies[invalid_key] = {
	code: 1
};
let invalid_done = finish(env, invalid);
assert_equal(invalid_done.state, 'failure');
assert_equal(invalid_done.error.code, 'VALIDATION_FAILED');
assert_equal(sprintf('%J', invalid_done.error.detail), '{ "profile": "config.yaml" }');
assert_equal(env.fs.readfile('/opt/clash/config.yaml'), before);
assert_equal(env.cfg.read_draft('config.yaml'), 'draft-secret: value\n');
assert_equal(env.fs.lstat('/tmp/miclash/candidates/' + invalid.id), null);
assert_equal(length(env.revisions.list('config.yaml')), 0);
assert_equal(env.process.calls[0].command, '/usr/bin/ucode');
assert_equal(join(' ', env.process.calls[0].args),
	'-- /usr/libexec/miclash/validate-config.uc /tmp/miclash/candidates/' +
	invalid.id + '/config.yaml');
assert_equal(env.process.calls[0].timeout_ms, 31000);
assert_equal(exists(env.process.calls[0], 'capture_limit'), false);

// Helper/protocol and parent execution failures are infrastructure errors;
// helper timeout 124 remains an ordinary canonical validation failure.
let helper_errors = environment();
let helper_protocol = helper_errors.cfg.validate('config.yaml', fixture('valid.yaml'), 'luci');
helper_errors.process.replies[validation_key(helper_protocol.id)] = { code: 125 };
assert_equal(finish(helper_errors, helper_protocol).error.code, 'INTERNAL');
let helper_parent = helper_errors.cfg.validate('config.yaml', fixture('valid.yaml'), 'luci');
helper_errors.process.replies[validation_key(helper_parent.id)] = { code: -9 };
assert_equal(finish(helper_errors, helper_parent).error.code, 'INTERNAL');
let helper_exec = helper_errors.cfg.validate('config.yaml', fixture('valid.yaml'), 'luci');
helper_errors.process.replies[validation_key(helper_exec.id)] = { code: 255 };
assert_equal(finish(helper_errors, helper_exec).error.code, 'INTERNAL');
let helper_timeout = helper_errors.cfg.validate('config.yaml', fixture('valid.yaml'), 'luci');
helper_errors.process.replies[validation_key(helper_timeout.id)] = { code: 124 };
let helper_timeout_done = finish(helper_errors, helper_timeout);
assert_equal(helper_timeout_done.error.code, 'VALIDATION_FAILED');
assert_equal(sprintf('%J', helper_timeout_done.error.detail),
	'{ "profile": "config.yaml" }');

let missing_helper = environment();
missing_helper.fs.unlink('/usr/libexec/miclash/validate-config.uc');
let missing_validation = missing_helper.cfg.validate(
	'config.yaml', fixture('valid.yaml'), 'luci');
assert_equal(finish(missing_helper, missing_validation).error.code, 'INTERNAL');

// Candidate cleanup failures are visible and can never be reported as a
// successful validation while owned temporary content remains behind.
let cleanup_env = environment();
cleanup_env.fs.fail_unlink_once = true;
let cleanup = cleanup_env.cfg.validate('config.yaml', fixture('valid.yaml'), 'luci');
assert_equal(finish(cleanup_env, cleanup).error.code, 'INTERNAL');
assert_equal(cleanup_env.fs.lstat('/tmp/miclash/candidates/' + cleanup.id)?.type,
	'directory');

let invalid_apply = env.cfg.apply('config.yaml', fixture('invalid.yaml'), 'luci');
env.process.replies[validation_key(invalid_apply.id)] = { code: 1 };
assert_equal(finish(env, invalid_apply).error.code, 'VALIDATION_FAILED');
assert_equal(env.fs.readfile('/opt/clash/config.yaml'), before);
assert_equal(length(env.revisions.list('config.yaml')), 0);

// A Candidate changed by the validator is rejected by identity and digest,
// before either history or Active can change.
let tampered_env = environment();
tampered_env.process.on_run = (request) => {
	let path = request.args[2];
	tampered_env.fs.files[path] += '# tampered\n';
};
let tampered = tampered_env.cfg.apply('config.yaml', fixture('valid.yaml'), 'luci');
assert_equal(finish(tampered_env, tampered).error.code, 'INTERNAL');
assert_equal(tampered_env.fs.readfile('/opt/clash/config.yaml'), 'original-active\n');
assert_equal(length(tampered_env.revisions.list('config.yaml')), 0);

// Candidate directories are operation-unique even when the clock does not move.
let valid_one = env.cfg.validate('config.yaml', fixture('valid.yaml'), 'luci');
let valid_two = env.cfg.validate('config.yaml', fixture('valid.yaml'), 'luci');
finish(env, valid_one);
finish(env, valid_two);
assert_true(valid_one.id != valid_two.id);
let call_count = length(env.process.calls);
assert_true(env.process.calls[call_count - 2].args[2] !=
	env.process.calls[call_count - 1].args[2]);

// Apply validates the immutable Candidate, snapshots exact previous Active,
// atomically replaces Active, retains Draft, and records native runtime hashes.
let applied = env.cfg.apply('config.yaml', fixture('valid.yaml'), 'luci');
let applied_done = finish(env, applied);
assert_equal(applied_done.state, 'success');
assert_equal(env.fs.readfile('/opt/clash/config.yaml'), fixture('valid.yaml'));
assert_equal(env.cfg.read_draft('config.yaml'), 'draft-secret: value\n');
let applied_history = env.revisions.list('config.yaml');
assert_equal(length(applied_history), 1);
assert_equal(applied_history[0].source, 'luci');
assert_equal(applied_history[0].operation_id, applied.id);
assert_equal(env.revisions.read('config.yaml', applied_history[0].revision), before);
assert_equal(applied_history[0].hash, env.rt.digest.sha256(before));
assert_true(match(applied_history[0].filename, /^[A-Za-z0-9][A-Za-z0-9._-]*$/) != null);
let history_rename = -1;
let active_rename = -1;
for (let index, call in env.fs.calls.rename) {
	if (history_rename < 0 && match(call.to, /^\/opt\/clash\/history\/config\.yaml\/.+\.yaml$/))
		history_rename = index;
	if (call.to == '/opt/clash/config.yaml')
		active_rename = index;
}
assert_true(history_rename >= 0 && active_rename > history_rename);

// Runtime health failure is visible but does not roll Active or erase Draft.
let unhealthy_env = environment({ reload: () => false, health: () => false });
finish(unhealthy_env, unhealthy_env.cfg.save_draft(
	'config.yaml', 'still-draft\n', 'luci'));
let unhealthy = unhealthy_env.cfg.apply(
	'config.yaml', fixture('runtime-unhealthy.yaml'), 'luci');
let unhealthy_done = finish(unhealthy_env, unhealthy);
assert_equal(unhealthy_done.state, 'failure');
assert_equal(unhealthy_done.error.code, 'HEALTH_FAILED');
assert_equal(unhealthy_env.fs.readfile('/opt/clash/config.yaml'),
	fixture('runtime-unhealthy.yaml'));
assert_equal(unhealthy_env.cfg.read_draft('config.yaml'), 'still-draft\n');
assert_equal(length(unhealthy_env.revisions.list('config.yaml')), 1);
assert_equal(unhealthy_env.revisions.list('config.yaml')[0].activation_result, 'health_failed');

// Manual restore takes a snapshot of the current Active before replacement.
let restored = env.cfg.restore('config.yaml', applied_history[0].revision, 'luci');
assert_equal(finish(env, restored).state, 'success');
assert_equal(env.fs.readfile('/opt/clash/config.yaml'), before);
let restored_history = env.revisions.list('config.yaml');
assert_equal(length(restored_history), 2);
assert_equal(restored_history[1].source, 'restore');
assert_equal(env.revisions.read('config.yaml', restored_history[1].revision), fixture('valid.yaml'));

// External edits are detected by persisted hash, validated, and snapshotted as
// the external source; invalid external data is never overwritten.
env.fs.writefile('/opt/clash/config.yaml', fixture('valid.yaml') + '# external\n');
let detected = env.cfg.detect_external('config.yaml');
assert_equal(detected.changed, true);
assert_equal(detected.hash, env.rt.digest.sha256(fixture('valid.yaml') + '# external\n'));
let adopted = env.cfg.adopt_external('config.yaml', 'system');
assert_equal(finish(env, adopted).state, 'success');
let external_history = env.revisions.list('config.yaml');
assert_equal(external_history[length(external_history) - 1].source, 'external');
assert_equal(env.cfg.detect_external('config.yaml').changed, false);

// External adoption snapshots the exact validated bytes. A mutation after the
// snapshot but before tracking fails closed and never marks the race as adopted.
let external_race = environment();
let external_bytes = fixture('valid.yaml') + '# validated external\n';
external_race.fs.writefile('/opt/clash/config.yaml', external_bytes);
assert_true(type(external_race.revisions.snapshot_bytes) == 'function');
let snapshot_bytes = external_race.revisions.snapshot_bytes;
external_race.revisions.snapshot_bytes = (profile, source, content, metadata) => {
	let record = snapshot_bytes(profile, source, content, metadata);
	external_race.fs.writefile('/opt/clash/config.yaml', 'changed during adoption\n');
	return record;
};
let raced_adoption = external_race.cfg.adopt_external('config.yaml', 'system');
assert_equal(finish(external_race, raced_adoption).error.code, 'INTERNAL');
let raced_history = external_race.revisions.list('config.yaml');
assert_equal(length(raced_history), 1);
assert_equal(external_race.revisions.read('config.yaml', raced_history[0].revision),
	external_bytes);
assert_equal(external_race.cfg.detect_external('config.yaml').changed, true);

let invalid_external = fixture('invalid.yaml');
env.fs.writefile('/opt/clash/config.yaml', invalid_external);
let reject_external = env.cfg.adopt_external('config.yaml', 'system');
env.process.replies[validation_key(reject_external.id)] = { code: 1 };
assert_equal(finish(env, reject_external).error.code, 'VALIDATION_FAILED');
assert_equal(env.fs.readfile('/opt/clash/config.yaml'), invalid_external);
assert_equal(length(env.revisions.list('config.yaml')), length(external_history));

// Arbitrary caller metadata is redacted before it reaches the sidecar journal.
let metadata_env = environment();
let metadata_revision = metadata_env.revisions.snapshot('config.yaml', 'system', {
	operation_id: 'metadata-op',
	token: 'history-secret',
	endpoint: 'https://user:pass@example.test/?token=url-secret'
});
let metadata_json = metadata_env.fs.readfile(
	'/opt/clash/history/config.yaml/' + metadata_revision.revision + '.json');
assert_true(index(metadata_json, 'history-secret') < 0);
assert_true(index(metadata_json, 'url-secret') < 0);
assert_match(metadata_revision.filename, /^[A-Za-z0-9][A-Za-z0-9._-]*$/);

// A pre-existing revision is never overwritten; O_EXCL reservation advances
// to another safe random revision.
let collision_env = environment();
let colliding_revision = '1700000000000-0000000000000001';
let colliding_path = '/opt/clash/history/config.yaml/' + colliding_revision + '.yaml';
collision_env.fs.writefile(colliding_path, 'foreign-history\n');
let after_collision = collision_env.revisions.snapshot('config.yaml', 'system', {});
assert_true(after_collision.revision != colliding_revision);
assert_equal(collision_env.fs.readfile(colliding_path), 'foreign-history\n');

// Candidate roots and operation directories must not follow symlinks.
let linked = environment();
linked.fs.set_symlink('/tmp/miclash/candidates', '/opt/clash');
let linked_validation = linked.cfg.validate('config.yaml', fixture('valid.yaml'), 'luci');
assert_equal(finish(linked, linked_validation).error.code, 'INTERNAL');
assert_equal(linked.fs.readfile('/opt/clash/config.yaml'), 'original-active\n');

// Initialization removes only exact owned stale Candidate trees. Foreign
// layouts and symlinks are untouched, while cleanup I/O failure is visible.
let stale_id = '1700000000000-0000000000000001';
let stale = environment(null, (fs) => {
	fs.mkdir('/tmp/miclash/candidates');
	fs.mkdir('/tmp/miclash/candidates/' + stale_id);
	fs.writefile('/tmp/miclash/candidates/' + stale_id + '/config.yaml', 'stale\n');
});
assert_equal(stale.fs.lstat('/tmp/miclash/candidates/' + stale_id), null);
assert_equal(stale.fs.lstat('/tmp/miclash/candidates')?.type, 'directory');

let foreign_id = 'foreign-operation';
let preserved = environment(null, (fs) => {
	fs.mkdir('/tmp/miclash/candidates');
	fs.mkdir('/tmp/miclash/candidates/' + foreign_id);
	fs.writefile('/tmp/miclash/candidates/' + foreign_id + '/config.yaml', 'foreign\n');
	fs.writefile('/tmp/miclash/candidates/' + foreign_id + '/notes', 'keep\n');
	fs.set_symlink('/tmp/miclash/candidates/symlink-operation', '/opt/clash');
});
assert_equal(preserved.fs.readfile(
	'/tmp/miclash/candidates/' + foreign_id + '/config.yaml'), 'foreign\n');
assert_equal(preserved.fs.lstat('/tmp/miclash/candidates/symlink-operation')?.type, 'link');

assert_throws(() => environment(null, (fs) => {
	fs.set_symlink('/tmp/miclash/candidates', '/opt/clash');
}), 'INTERNAL');

assert_throws(() => environment(null, (fs) => {
	fs.mkdir('/tmp/miclash/candidates');
	fs.mkdir('/tmp/miclash/candidates/' + stale_id);
	fs.writefile('/tmp/miclash/candidates/' + stale_id + '/config.yaml', 'stale\n');
	fs.fail_unlink_once = true;
}), 'INTERNAL');
