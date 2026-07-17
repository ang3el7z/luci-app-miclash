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

// Internal worker primitives reuse the public Candidate and activation paths
// inside one already-running central mutation. They create no nested operation
// records and reject contexts which do not belong to a live operation.
let internal_env = environment();
let internal_result = null;
let issued_ctx = null;
let internal = internal_env.ops.submit('subscription.update', 'auto', {}, (ctx) => {
	issued_ctx = ctx;
	let forged = {
		id: ctx.id, runtime: ctx.runtime,
		stage: ctx.stage, complete: ctx.complete
	};
	assert_throws(() => internal_env.cfg.validate_in_operation(
		forged, 'config.yaml', fixture('valid.yaml')), 'INVALID_ARGUMENT');
	assert_throws(() => internal_env.cfg.apply_in_operation(
		forged, 'config.yaml', fixture('valid.yaml'), 'auto'), 'INVALID_ARGUMENT');
	assert_throws(() => internal_env.cfg.save_draft_in_operation(
		forged, 'config.yaml', 'forged-draft\n'), 'INVALID_ARGUMENT');
	assert_throws(() => internal_env.cfg.apply_in_operation(
		ctx, 'config.yaml', fixture('valid.yaml'), 'restore-before', {},
		{ snapshot_before_validation: false }), 'INVALID_ARGUMENT');
	assert_equal(internal_env.cfg.save_draft_in_operation(
		ctx, 'config.yaml', 'internal-draft\n'), true);
	internal_result = internal_env.cfg.validate_in_operation(
		ctx, 'config.yaml', fixture('valid.yaml'));
	if (internal_result?.ok !== true)
		return ctx.complete(internal_result?.error);
	internal_result = internal_env.cfg.apply_in_operation(
		ctx, 'config.yaml', fixture('valid.yaml'), 'auto', {
		attempt_result: 'success'
	});
	if (internal_result?.ok !== true)
		return ctx.complete(internal_result?.error);
	ctx.result({ interval_hours: null });
	return true;
});
assert_equal(finish(internal_env, internal).state, 'success');
assert_equal(internal_result?.ok, true);
assert_equal(internal_result?.activated, true);
assert_equal(internal_result?.reload_ok, true);
assert_equal(length(internal_env.ops.list()), 1);
assert_equal(internal_env.fs.readfile('/opt/clash/config.yaml'), fixture('valid.yaml'));
assert_throws(() => internal_env.cfg.validate_in_operation(
	{ id: 'fake-operation' }, 'config.yaml', fixture('valid.yaml')), 'INVALID_ARGUMENT');
assert_throws(() => internal_env.cfg.apply_in_operation(
	{ id: internal.id }, 'config.yaml', fixture('valid.yaml'), 'auto'),
	'INVALID_ARGUMENT');
assert_throws(() => internal_env.cfg.validate_in_operation(
	issued_ctx, 'config.yaml', fixture('valid.yaml')), 'INVALID_ARGUMENT');
assert_throws(() => internal_env.cfg.apply_in_operation(
	issued_ctx, 'config.yaml', fixture('valid.yaml'), 'auto'), 'INVALID_ARGUMENT');
assert_throws(() => internal_env.cfg.save_draft_in_operation(
	issued_ctx, 'config.yaml', 'expired-draft\n'), 'INVALID_ARGUMENT');

// Subscription replacement prepares its durable URL before touching Active,
// then treats Active bytes, health, and URL finalization as one rollback unit.
let transaction_url = 'old-url', transaction_calls = [];
let transaction_env = environment();
let transaction_record = transaction_env.ops.submit('subscription.update', 'telegram', {}, (ctx) => {
	let result = transaction_env.cfg.apply_transaction_in_operation(ctx, 'config.yaml',
		fixture('valid.yaml'), 'telegram', {}, {
			prepare: () => { push(transaction_calls, 'prepare'); transaction_url = 'new-url'; return 'old-url'; },
			commit: () => { push(transaction_calls, 'commit'); return transaction_url == 'new-url'; },
			rollback: (old) => { push(transaction_calls, 'rollback'); transaction_url = old; return true; }
		});
	if (!result.ok) { ctx.complete(result.error); return false; }
	ctx.result({ interval_hours: null });
	return true;
});
let transaction_done = finish(transaction_env, transaction_record);
assert_equal(transaction_done.state, 'success', sprintf('transaction failed: %J', transaction_done));
assert_equal(transaction_url, 'new-url');
assert_equal(transaction_env.fs.readfile('/opt/clash/config.yaml'), fixture('valid.yaml'));
assert_equal(sprintf('%J', transaction_calls), sprintf('%J', [ 'prepare', 'commit' ]));

transaction_url = 'old-url'; transaction_calls = [];
let transaction_unhealthy = environment({ reload: () => false, health: () => false });
let unhealthy_transaction = transaction_unhealthy.ops.submit('subscription.update', 'telegram', {}, (ctx) => {
	let result = transaction_unhealthy.cfg.apply_transaction_in_operation(ctx, 'config.yaml',
		fixture('valid.yaml'), 'telegram', {}, {
			prepare: () => { push(transaction_calls, 'prepare'); transaction_url = 'new-url'; return 'old-url'; },
			commit: () => { push(transaction_calls, 'commit'); return true; },
			rollback: (old) => { push(transaction_calls, 'rollback'); transaction_url = old; return true; }
		});
	ctx.complete(result.error); return false;
});
assert_equal(finish(transaction_unhealthy, unhealthy_transaction).error.code, 'INTERNAL',
	'failed health verification after restoring Active must not claim a completed rollback');
assert_equal(transaction_url, 'old-url');
assert_equal(transaction_unhealthy.fs.readfile('/opt/clash/config.yaml'), 'original-active\n');
assert_equal(sprintf('%J', transaction_calls), sprintf('%J', [ 'prepare', 'rollback' ]));

// Only the three on-disk profile names are accepted.
for (let profile in [ 'config.yaml', 'config2.yaml', 'config3.yaml' ])
	assert_equal(schema.profile_name(profile), profile);
for (let profile in [ 'config0.yaml', 'config1.yaml', 'config4.yaml', '../config.yaml' ])
	assert_throws(() => schema.profile_name(profile), 'INVALID_ARGUMENT');

let env = environment();
assert_equal(join(',', env.cfg.list_profiles()), 'config.yaml,config2.yaml,config3.yaml');
assert_equal(env.cfg.read_active('config.yaml'), 'original-active\n');

// Promoting a secondary profile is one serialized domain operation: both
// profiles are validated and swapped, while a running Mihomo receives only
// the new Main profile (never the temporary backup profile).
let swap_calls = [];
let swap_env = environment({
	observe: () => ({ state: 'running', running: true }),
	reload: (profile, controller_config) => {
		push(swap_calls, { profile, controller_config });
		return true;
	},
	health: () => true
});
let swapped = swap_env.cfg.swap('config2.yaml', 'luci');
assert_equal(finish(swap_env, swapped).state, 'success');
assert_equal(swap_env.fs.readfile('/opt/clash/config.yaml'), 'second-active\n');
assert_equal(swap_env.fs.readfile('/opt/clash/config2.yaml'), 'original-active\n');
assert_equal(length(swap_calls), 1);
assert_equal(swap_calls[0].profile, 'config.yaml');
assert_equal(swap_calls[0].controller_config, 'original-active\n');

// A failed promoted profile is one atomic rollback boundary: profile bytes,
// active revision markers, and coupled subscription settings all return to
// their pre-swap values before the operation reports failure.
let swap_settings = { main: 'https://main.example/sub', selected: 'https://backup.example/sub' };
let rollback_calls = 0;
let unhealthy_swap = environment({
	observe: () => ({ state: 'running', running: true }),
	reload: () => true,
	health: () => false
});
let failed_swap = unhealthy_swap.cfg.swap('config2.yaml', 'luci', {
	prepare: () => json(sprintf('%J', swap_settings)),
	commit: (before) => {
		let value = swap_settings.main;
		swap_settings.main = swap_settings.selected;
		swap_settings.selected = value;
		return true;
	},
	rollback: (before) => { rollback_calls++; swap_settings = before; return true; }
});
let failed_swap_done = finish(unhealthy_swap, failed_swap);
assert_equal(failed_swap_done.error.code, 'HEALTH_FAILED');
assert_equal(unhealthy_swap.fs.readfile('/opt/clash/config.yaml'), 'original-active\n');
assert_equal(unhealthy_swap.fs.readfile('/opt/clash/config2.yaml'), 'second-active\n');
assert_equal(unhealthy_swap.cfg.detect_external('config.yaml').changed, false);
assert_equal(unhealthy_swap.cfg.detect_external('config2.yaml').changed, false);
assert_equal(swap_settings.main, 'https://main.example/sub');
assert_equal(swap_settings.selected, 'https://backup.example/sub');
assert_equal(rollback_calls, 1);

// A transaction which persisted settings and then failed its runtime-state
// commit is still partial work and must be rolled back.
let partial_settings = { main: 'main-before', selected: 'selected-before' };
let partial_rollbacks = 0;
let partial_env = environment({ reload: () => true, health: () => true });
let partial_swap = partial_env.cfg.swap('config2.yaml', 'luci', {
	prepare: () => json(sprintf('%J', partial_settings)),
	commit: (before) => {
		partial_settings.main = 'selected-before';
		partial_settings.selected = 'main-before';
		die('INTERNAL');
		return before;
	},
	rollback: (before) => {
		partial_rollbacks++; partial_settings = before; return true;
	}
});
finish(partial_env, partial_swap);
assert_equal(partial_env.fs.readfile('/opt/clash/config.yaml'), 'original-active\n');
assert_equal(partial_env.fs.readfile('/opt/clash/config2.yaml'), 'second-active\n');
assert_equal(partial_settings.main, 'main-before');
assert_equal(partial_settings.selected, 'selected-before');
assert_equal(partial_rollbacks, 1);

// Operational UI settings and their generated Main configuration commit in
// one operation. A health failure retains the user's Draft but restores both
// active configuration and settings/revision state.
let operational_settings = { proxy_mode: 'tproxy' }, operational_rollbacks = 0;
let operational_env = environment({ reload: () => true, health: () => false });
let operational_content = fixture('valid.yaml');
let operational = operational_env.cfg.apply_operational('config.yaml',
	operational_content, 'luci', {
		prepare: () => json(sprintf('%J', operational_settings)),
		commit: () => { operational_settings.proxy_mode = 'tun'; return true; },
		rollback: (before) => {
			operational_rollbacks++; operational_settings = before; return true;
		}
	});
let operational_done = finish(operational_env, operational);
assert_equal(operational_done.error.code, 'HEALTH_FAILED');
assert_equal(operational_env.fs.readfile('/opt/clash/config.yaml'), 'original-active\n');
assert_equal(operational_env.cfg.read_draft('config.yaml'), operational_content);
assert_equal(operational_env.cfg.detect_external('config.yaml').changed, false);
assert_equal(operational_settings.proxy_mode, 'tproxy');
assert_equal(operational_rollbacks, 1);

let rejected_swap = environment();
let rejected = rejected_swap.cfg.swap('config2.yaml', 'luci');
rejected_swap.process.replies[validation_key(rejected.id)] = { code: 1 };
assert_equal(finish(rejected_swap, rejected).error.code, 'VALIDATION_FAILED');
assert_equal(rejected_swap.fs.readfile('/opt/clash/config.yaml'), 'original-active\n');
assert_equal(rejected_swap.fs.readfile('/opt/clash/config2.yaml'), 'second-active\n');
assert_throws(() => rejected_swap.cfg.swap('config.yaml', 'luci'), 'INVALID_ARGUMENT');

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
assert_equal(env.process.calls[0].timeout_ms, 0);
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
	if (history_rename < 0 && match(call.to,
	    /^\/opt\/clash\/history\/config\.yaml\/\.stage-.+\/config\.yaml$/))
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
let unhealthy_internal_result = null;
let unhealthy_internal = unhealthy_env.ops.submit('subscription.update', 'auto', {}, (ctx) => {
	unhealthy_internal_result = unhealthy_env.cfg.apply_in_operation(
		ctx, 'config.yaml', fixture('valid.yaml'), 'auto');
	ctx.complete(unhealthy_internal_result.error);
	return false;
});
assert_equal(finish(unhealthy_env, unhealthy_internal).error.code, 'HEALTH_FAILED');
assert_equal(unhealthy_internal_result.activated, true);
assert_equal(unhealthy_internal_result.reload_ok, false);

// Activation passes byte-exact pre-Active controller configuration to reload,
// then health observes the already replaced Active. Reload failure never rolls back.
let transition_calls = [];
let transition_env;
let transition_service = {
	reload: (profile, controller_config) => {
		push(transition_calls, { method: 'reload', profile, controller_config,
			active: transition_env.fs.readfile('/opt/clash/config.yaml') });
		return false;
	},
	health: (profile) => {
		push(transition_calls, { method: 'health', profile,
			active: transition_env.fs.readfile('/opt/clash/config.yaml') });
		return false;
	}
};
transition_env = environment(transition_service);
let transition_candidate = fixture('runtime-unhealthy.yaml') + '# new controller\n';
let transition_apply = transition_env.cfg.apply('config.yaml', transition_candidate, 'luci');
assert_equal(finish(transition_env, transition_apply).error.code, 'HEALTH_FAILED');
assert_equal(transition_calls[0].method, 'reload');
assert_equal(transition_calls[0].controller_config, 'original-active\n');
assert_equal(transition_calls[0].active, transition_candidate);
assert_equal(transition_env.fs.readfile('/opt/clash/config.yaml'), transition_candidate);

// A live Active mutation during byte snapshotting fails before replacement;
// the snapshot still contains only the captured original bytes.
let activation_race = environment();
let activation_snapshot = activation_race.revisions.snapshot_bytes;
activation_race.revisions.snapshot_bytes = (profile, source, content, metadata) => {
	assert_equal(content, 'original-active\n');
	let record = activation_snapshot(profile, source, content, metadata);
	activation_race.fs.writefile('/opt/clash/config.yaml', 'external-race\n');
	return record;
};
let raced_apply = activation_race.cfg.apply('config.yaml', fixture('valid.yaml'), 'luci');
assert_equal(finish(activation_race, raced_apply).error.code, 'INTERNAL');
assert_equal(activation_race.fs.readfile('/opt/clash/config.yaml'), 'external-race\n');
let activation_history = activation_race.revisions.list('config.yaml');
assert_equal(length(activation_history), 1);
assert_equal(activation_race.revisions.read(
	'config.yaml', activation_history[0].revision), 'original-active\n');

// Manual restore takes a snapshot of the current Active before replacement.
let restored = env.cfg.restore('config.yaml', applied_history[0].revision, 'luci');
assert_equal(finish(env, restored).state, 'success');
assert_equal(env.fs.readfile('/opt/clash/config.yaml'), before);
let restored_history = env.revisions.list('config.yaml');
assert_equal(length(restored_history), 3);
assert_equal(restored_history[1].source, 'restore-before');
assert_equal(restored_history[1].activation_result, 'success');
assert_equal(env.revisions.read('config.yaml', restored_history[1].revision), fixture('valid.yaml'));
assert_equal(restored_history[2].source, 'restore');
assert_equal(restored_history[2].activation_result, 'success');
assert_equal(restored_history[2].parent_revision, restored_history[1].revision);
assert_equal(restored_history[2].restored_revision, applied_history[0].revision);
assert_equal(env.revisions.read('config.yaml', restored_history[2].revision), before);

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
	'/opt/clash/history/config.yaml/' + metadata_revision.revision + '/metadata.json');
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
