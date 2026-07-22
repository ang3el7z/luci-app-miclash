import * as errors from 'miclash.errors';
import * as operations from 'miclash.operations';
import * as scheduler from 'miclash.scheduler';
import { assert_equal, assert_throws, assert_true } from './testlib.uc';
import * as fakes from 'fakes';

const MINUTE = 60 * 1000;
const HOUR = 60 * MINUTE;
const STATE_PATH = '/opt/clash/subscription-scheduler.json';

assert_equal(type(scheduler.create), 'function', 'scheduler exports create()');

function environment(options) {
	options ??= {};
	let filesystem = options.filesystem ?? fakes.fs(options.files ?? {
		'/opt/clash/config.yaml': 'active\n'
	});
	filesystem.mkdir('/tmp');
	filesystem.mkdir('/tmp/miclash');
	let clock = fakes.clock(options.now ?? 1700000000000);
	let runtime = {
		fs: filesystem,
		clock,
		digest: fakes.digest(filesystem),
		random: fakes.entropy(),
		paths: { tmp: '/tmp/miclash' }
	};
	let ops = operations.create(runtime);
	let value = options.settings ?? {
		core: {
			subscription_url: 'https://subscriptions.example.test/config.yaml',
			subscription_url_config_yaml: '',
			subscription_url_config2_yaml: '',
			subscription_url_config3_yaml: ''
		},
		updates: { auto_subscription: true, interval_hours: 4 }
	};
	let settings = { get: () => value };
	let scenarios = options.scenarios ?? [ {} ];
	let calls = [];
	let worker_calls = 0;
	let subscription = {};
	function submit_update(request, source, before_run) {
		push(calls, { request, source });
		let scenario = length(scenarios) ? shift(scenarios) : {};
		return ops.submit('subscription.update', source,
			{ profile: request.profile }, (ctx) => {
				worker_calls++;
				ctx.stage('attempt', 10, 'attempt');
				if (scenario.error == 'DOWNLOAD_FAILED') {
					ctx.complete(errors.new('DOWNLOAD_FAILED'));
					return false;
				}
				ctx.result({ interval_hours: scenario.interval_hours ?? null });
				ctx.stage('download', 35, 'download');
				ctx.stage('validation', 55, 'validation');
				if (scenario.error == 'VALIDATION_FAILED') {
					ctx.complete(errors.new('VALIDATION_FAILED'));
					return false;
				}
				ctx.stage('activation', 75, 'activation');
				ctx.stage('reload', 95, 'reload');
				if (scenario.error == 'HEALTH_FAILED') {
					ctx.complete(errors.new('HEALTH_FAILED'));
					return false;
				}
				ctx.stage('complete', 99, 'complete');
				return true;
			}, before_run);
	};
	subscription.update = (request, source) => submit_update(request, source, null);
	subscription.update_scheduled = (request, source, before_run) =>
		submit_update(request, source, before_run);
	let app = { runtime, operations: ops, settings, subscription };
	return { filesystem, clock, runtime, ops, settings, scenarios, calls,
		worker_calls: () => worker_calls,
		app, machine: scheduler.create(app) };
};

function drain(env) {
	env.clock.advance(0);
};

// Disabled and unconfigured schedulers never submit a mutation or retain a due
// timestamp. The public status carries no URL.
let disabled = environment({ settings: {
	core: { subscription_url: 'https://secret.example.test/path?token=secret',
		subscription_url_config_yaml: '' },
	updates: { auto_subscription: false, interval_hours: 4 }
} });
disabled.machine.tick();
assert_equal(length(disabled.calls), 0);
assert_equal(disabled.machine.status().enabled, false);
assert_equal(disabled.machine.status().reason, 'disabled');
assert_true(index(sprintf('%J', disabled.machine.status()), 'secret') < 0);
assert_equal(disabled.machine.start(), true);
assert_equal(disabled.clock.timers[length(disabled.clock.timers) - 1].due,
	disabled.clock.now() + MINUTE);
disabled.machine.stop();
let no_url = environment({ settings: {
	core: { subscription_url: '', subscription_url_config_yaml: '' },
	updates: { auto_subscription: true, interval_hours: 4 }
} });
no_url.machine.tick();
assert_equal(length(no_url.calls), 0);
assert_equal(no_url.machine.status().reason, 'no_url');
assert_equal(no_url.machine.status().next_attempt, null);

// Saving the first URL is a configuration change, not permission to run an
// immediate background update. The explicit LuCI action owns the first
// download; automatic work begins only after the configured interval.
let first_url_settings = {
	core: { subscription_url: '', subscription_url_config_yaml: '' },
	updates: { auto_subscription: true, interval_hours: 4 }
};
let first_url = environment({ settings: first_url_settings });
first_url.machine.tick();
first_url_settings.core.subscription_url =
	'https://subscriptions.example.test/config.yaml';
first_url.machine.tick();
assert_equal(length(first_url.calls), 0);
assert_equal(first_url.machine.status().next_attempt,
	first_url.clock.now() + 4 * HOUR);

// A successful explicit update is authoritative for the next automatic due
// time, including a trusted interval supplied by the subscription profile.
let manual_success = environment({ scenarios: [ { interval_hours: 3 } ] });
manual_success.machine.tick();
manual_success.app.subscription.update({ profile: 'config.yaml' }, 'luci');
drain(manual_success);
assert_equal(manual_success.machine.status().last_success,
	manual_success.clock.now());
assert_equal(manual_success.machine.status().next_attempt,
	manual_success.clock.now() + 3 * HOUR);

// A successful scheduled update records every stage, resets backoff, and uses
// the configured interval. Only the scheduler operation id is persisted.
let normal = environment();
normal.machine.run_now();
normal.machine.tick();
drain(normal);
let normal_status = normal.machine.status();
assert_equal(length(normal.calls), 1);
assert_equal(normal.calls[0].source, 'auto');
assert_equal(normal.calls[0].request.profile, 'config.yaml');
assert_equal(normal_status.failure_count, 0);
assert_equal(normal_status.last_failure_code, null);
assert_equal(normal_status.last_attempt, 1700000000000);
assert_equal(normal_status.last_download, 1700000000000);
assert_equal(normal_status.last_validation, 1700000000000);
assert_equal(normal_status.last_activation, 1700000000000);
assert_equal(normal_status.last_reload, 1700000000000);
assert_equal(normal_status.last_success, 1700000000000);
assert_equal(normal_status.next_attempt, 1700000000000 + 4 * HOUR);
assert_equal(normal_status.pending_operation_id, null);
assert_true(normal.filesystem.mode(STATE_PATH) == 0o600);
assert_true(index(normal.filesystem.readfile(STATE_PATH),
	'subscriptions.example.test') < 0);

// Scheduler state is a root-owned, exact-path 0600 authority under a stable,
// non-writable /opt/clash parent. Path substitution and contradictory but
// syntactically valid records fail closed as CORRUPT_STATE.
let trusted_state_bytes = normal.filesystem.readfile(STATE_PATH);
function state_environment(mutator) {
	let filesystem = fakes.fs({
		'/opt/clash/config.yaml': 'active\n',
		[STATE_PATH]: trusted_state_bytes,
		'/opt/clash/foreign-state.json': trusted_state_bytes
	});
	if (type(mutator) == 'function')
		mutator(filesystem);
	return { filesystem, create: () => environment({ filesystem }).machine };
};
let linked_state = state_environment((filesystem) =>
	filesystem.set_symlink(STATE_PATH, '/opt/clash/foreign-state.json'));
assert_throws(linked_state.create, 'CORRUPT_STATE');
let weak_state = state_environment((filesystem) => filesystem.set_mode(STATE_PATH, 0o644));
assert_throws(weak_state.create, 'CORRUPT_STATE');
let foreign_state = state_environment((filesystem) => filesystem.set_uid(STATE_PATH, 1000));
assert_throws(foreign_state.create, 'CORRUPT_STATE');
let weak_parent = state_environment((filesystem) => filesystem.set_mode('/opt/clash', 0o777));
assert_throws(weak_parent.create, 'CORRUPT_STATE');
let foreign_parent = state_environment((filesystem) => filesystem.set_uid('/opt/clash', 1000));
assert_throws(foreign_parent.create, 'CORRUPT_STATE');
let replaced_state = state_environment((filesystem) => {
	filesystem.on_lstat = (path, count) => {
		if (path == STATE_PATH && count == 2)
			filesystem.bump_inode(path);
	};
});
assert_throws(replaced_state.create, 'CORRUPT_STATE');
let replaced_parent = state_environment((filesystem) => {
	filesystem.on_lstat = (path, count) => {
		if (path == '/opt/clash' && count == 2)
			filesystem.bump_inode(path);
	};
});
assert_throws(replaced_parent.create, 'CORRUPT_STATE');

for (let contradiction in [
	(state) => { state.failure_count = 1; state.last_failure_code = null; },
	(state) => { state.last_attempt = null; state.last_download = state.observed_at; },
	(state) => { state.last_success = state.observed_at + 1; },
	(state) => { state.last_reload = null; },
	(state) => { state.pending_operation_id =
		'0000000000001-00000001-0123456789abcdef'; state.next_attempt = null; }
]) {
	let corrupt_relation = state_environment((filesystem) => {
		let value = json(filesystem.readfile(STATE_PATH));
		contradiction(value);
		filesystem.writefile(STATE_PATH, sprintf('%J\n', value));
	});
	assert_throws(corrupt_relation.create, 'CORRUPT_STATE');
}

// A trusted profile interval overrides the configured interval for this next
// schedule and survives daemon reconstruction from durable state.
let provided = environment({ scenarios: [ { interval_hours: 12 } ] });
provided.machine.run_now();
provided.machine.tick();
drain(provided);
assert_equal(provided.machine.status().next_attempt,
	1700000000000 + 12 * HOUR);
provided.machine.stop();
let reconstructed = scheduler.create(provided.app);
assert_equal(reconstructed.status().last_success, 1700000000000);
assert_equal(reconstructed.status().next_attempt, 1700000000000 + 12 * HOUR);
reconstructed.tick();
assert_equal(length(provided.calls), 1);

// A durable pending id is reattached across scheduler reconstruction. If the
// operation completed while no scheduler observer existed, its terminal
// journal record and one-shot outcome are reconciled on construction.
let pending_restart = environment();
pending_restart.machine.run_now();
pending_restart.machine.tick();
let durable_id = pending_restart.machine.status().pending_operation_id;
pending_restart.machine.stop();
drain(pending_restart);
let resumed = scheduler.create(pending_restart.app);
assert_equal(resumed.status().pending_operation_id, null);
assert_equal(resumed.status().last_success, pending_restart.clock.now());
assert_equal(pending_restart.ops.get(durable_id).state, 'success');

// A queued operation has not attempted network work. last_attempt is stamped
// only by the durable `attempt` timeline stage, never by submission itself.
let queued_before_attempt = environment();
queued_before_attempt.machine.run_now();
queued_before_attempt.machine.tick();
assert_equal(queued_before_attempt.machine.status().last_attempt, null);
queued_before_attempt.machine.stop();
let queued_restart_clock = fakes.clock(queued_before_attempt.clock.now());
let queued_restart_runtime = { fs: queued_before_attempt.filesystem,
	clock: queued_restart_clock, digest: fakes.digest(queued_before_attempt.filesystem),
	random: fakes.entropy(), paths: { tmp: '/tmp/miclash' } };
let queued_restart_operations = operations.create(queued_restart_runtime);
assert_equal(queued_restart_operations.recover_interrupted(), 1);
let queued_restart_scheduler = scheduler.create({ runtime: queued_restart_runtime,
	operations: queued_restart_operations, settings: queued_before_attempt.settings,
	subscription: {
		update: () => errors.fail('INTERNAL'),
		update_scheduled: () => errors.fail('INTERNAL')
	} });
assert_equal(queued_restart_scheduler.status().last_attempt, null);
assert_equal(queued_restart_scheduler.status().last_failure_code, 'INTERRUPTED');

// Recreate the operation manager, subscription object, runtime, and scheduler
// from shared disk after the worker completed without a scheduler observer.
// The terminal journal alone restores every current-attempt stage and the
// profile-provided interval.
let process_loss = environment({ scenarios: [ { interval_hours: 12 } ] });
process_loss.machine.run_now();
process_loss.machine.tick();
process_loss.machine.stop();
drain(process_loss);
let restart_clock = fakes.clock(process_loss.clock.now());
let restart_runtime = {
	fs: process_loss.filesystem, clock: restart_clock,
	digest: fakes.digest(process_loss.filesystem), random: fakes.entropy(),
	paths: { tmp: '/tmp/miclash' }
};
let restart_operations = operations.create(restart_runtime);
assert_equal(restart_operations.recover_interrupted(), 0);
let restart_subscription = {
	update: () => errors.fail('INTERNAL'),
	update_scheduled: () => errors.fail('INTERNAL')
};
let restarted = scheduler.create({ runtime: restart_runtime,
	operations: restart_operations, settings: process_loss.settings,
	subscription: restart_subscription });
let restart_status = restarted.status();
assert_equal(restart_status.last_attempt, restart_clock.now());
assert_equal(restart_status.last_download, restart_clock.now());
assert_equal(restart_status.last_validation, restart_clock.now());
assert_equal(restart_status.last_activation, restart_clock.now());
assert_equal(restart_status.last_reload, restart_clock.now());
assert_equal(restart_status.last_success, restart_clock.now());
assert_equal(restart_status.interval_hours, 12);
assert_equal(restart_status.next_attempt, restart_clock.now() + 12 * HOUR);

// A failed newer attempt reconstructed from disk overwrites stale stage values
// from the prior success and clears stages the new attempt never reached.
let stale = environment({ scenarios: [ {}, { error: 'VALIDATION_FAILED' } ] });
stale.machine.run_now();
stale.machine.tick();
drain(stale);
let old_success = stale.machine.status().last_success;
stale.clock.advance(4 * HOUR);
stale.machine.stop();
stale.machine.tick();
drain(stale);
let stale_clock = fakes.clock(stale.clock.now());
let stale_runtime = { fs: stale.filesystem, clock: stale_clock,
	digest: fakes.digest(stale.filesystem), random: fakes.entropy(),
	paths: { tmp: '/tmp/miclash' } };
let stale_operations = operations.create(stale_runtime);
assert_equal(stale_operations.recover_interrupted(), 0);
let stale_scheduler = scheduler.create({ runtime: stale_runtime,
	operations: stale_operations, settings: stale.settings,
	subscription: restart_subscription });
let stale_status = stale_scheduler.status();
assert_equal(stale_status.last_attempt, stale_clock.now());
assert_equal(stale_status.last_download, stale_clock.now());
assert_equal(stale_status.last_validation, stale_clock.now());
assert_equal(stale_status.last_activation, null);
assert_equal(stale_status.last_reload, null);
assert_equal(stale_status.last_success, old_success);

let stopped_pending = environment();
stopped_pending.machine.run_now();
stopped_pending.machine.tick();
stopped_pending.machine.stop();
drain(stopped_pending);
assert_true(stopped_pending.machine.status().pending_operation_id != null);
stopped_pending.machine.start();
assert_equal(stopped_pending.machine.status().pending_operation_id, null);
assert_equal(stopped_pending.machine.status().last_success, stopped_pending.clock.now());

// Download failures retry at exactly 5, 15, and then 60 minutes. A later
// success clears the failure state and returns to the normal interval.
let retry = environment({ scenarios: [
	{ error: 'DOWNLOAD_FAILED' }, { error: 'DOWNLOAD_FAILED' },
	{ error: 'DOWNLOAD_FAILED' }, {}
] });
retry.machine.run_now();
for (let expected in [ 5, 15, 60 ]) {
	let attempt = retry.clock.now();
	retry.machine.tick();
	drain(retry);
	assert_equal(retry.machine.status().next_attempt, attempt + expected * MINUTE);
	assert_equal(retry.machine.status().last_failure_code, 'DOWNLOAD_FAILED');
	retry.clock.advance(expected * MINUTE);
}
assert_equal(retry.machine.status().failure_count, 3);
retry.machine.tick();
drain(retry);
assert_equal(retry.machine.status().failure_count, 0);
assert_equal(retry.machine.status().last_failure_code, null);
assert_equal(retry.machine.status().last_success, retry.clock.now());

// Validation and reload failures are classified independently. Validation
// cannot stamp activation; a health failure has activated content but no
// successful reload and never advances last_success.
let stages = environment({ scenarios: [
	{ error: 'VALIDATION_FAILED' }, { error: 'HEALTH_FAILED' }
] });
stages.machine.run_now();
stages.machine.tick();
drain(stages);
let validation = stages.machine.status();
assert_equal(validation.last_failure_code, 'VALIDATION_FAILED');
assert_equal(validation.last_validation, stages.clock.now());
assert_equal(validation.last_activation, null);
assert_equal(validation.last_reload, null);
assert_equal(validation.last_success, null);
stages.clock.advance(5 * MINUTE);
stages.machine.tick();
drain(stages);
let reload = stages.machine.status();
assert_equal(reload.last_failure_code, 'HEALTH_FAILED');
assert_equal(reload.last_activation, stages.clock.now());
assert_equal(reload.last_reload, stages.clock.now());
assert_equal(reload.last_success, null);

// An incompatible queued/running operation delays observation by one minute
// without incrementing failure state or submitting a nested operation.
let busy = environment();
busy.ops.submit('config.apply', 'luci', {}, () => false);
drain(busy);
busy.machine.run_now();
busy.machine.tick();
assert_equal(length(busy.calls), 0);
assert_equal(busy.machine.status().failure_count, 0);
assert_equal(busy.machine.status().next_attempt, busy.clock.now() + MINUTE);

// If scheduler durability fails after the queued operation journal exists, the
// pre-enqueue barrier terminally fails that operation before its worker can
// touch Active. A later tick retries once without an uncorrelated duplicate.
let persist_crash = environment({ scenarios: [ {}, {} ] });
persist_crash.machine.run_now();
persist_crash.filesystem.fail_open_once_matching = 'subscription-scheduler.json.miclash';
persist_crash.filesystem.fail_open_matching_count = 16;
persist_crash.machine.tick();
drain(persist_crash);
assert_equal(persist_crash.worker_calls(), 0);
assert_equal(length(persist_crash.ops.list({ state: 'failure' })), 1);
assert_equal(persist_crash.machine.status().pending_operation_id, null);
persist_crash.machine.run_now();
persist_crash.machine.tick();
drain(persist_crash);
assert_equal(persist_crash.worker_calls(), 1);
assert_equal(persist_crash.machine.status().last_success, persist_crash.clock.now());

// Manual run resets only waiting: existing audit and failure counters remain,
// but the operation becomes immediately due.
let manual = environment({ scenarios: [ { error: 'DOWNLOAD_FAILED' } ] });
manual.machine.run_now();
manual.machine.tick();
drain(manual);
let previous_attempt = manual.machine.status().last_attempt;
assert_equal(manual.machine.status().failure_count, 1);
manual.machine.run_now();
assert_equal(manual.machine.status().last_attempt, previous_attempt);
assert_equal(manual.machine.status().failure_count, 1);
assert_equal(manual.machine.status().next_attempt, manual.clock.now());

// If the wall clock moves backwards, the remaining delay is shifted with it
// and is never converted into an immediate retry storm.
let rollback = environment({ scenarios: [ {}, { error: 'VALIDATION_FAILED' } ] });
rollback.machine.run_now();
rollback.machine.tick();
drain(rollback);
let rollback_success = rollback.machine.status().last_success;
rollback.clock.advance(-HOUR);
rollback.machine.tick();
assert_equal(length(rollback.calls), 1);
assert_equal(rollback.machine.status().next_attempt,
	rollback.clock.now() + 4 * HOUR);
rollback.machine.run_now();
rollback.machine.tick();
drain(rollback);
assert_equal(rollback.machine.status().last_failure_code, 'VALIDATION_FAILED');
assert_equal(rollback.machine.status().last_success, rollback_success);

// A daemon restart with an unresolved durable operation id cannot leave the
// scheduler waiting forever: a missing/interrupted record becomes a bounded
// retry with a redacted code.
let interrupted = environment();
interrupted.machine.run_now();
interrupted.machine.tick();
let pending = interrupted.machine.status().pending_operation_id;
assert_true(pending != null);
interrupted.machine.stop();
let state = json(interrupted.filesystem.readfile(STATE_PATH));
state.pending_operation_id = '0000000000001-00000001-0123456789abcdef';
interrupted.filesystem.writefile(STATE_PATH, sprintf('%J\n', state));
let recovered = scheduler.create(interrupted.app);
assert_equal(recovered.status().pending_operation_id, null);
assert_equal(recovered.status().last_failure_code, 'INTERRUPTED');
assert_equal(recovered.status().next_attempt, interrupted.clock.now() + 5 * MINUTE);

let corrupt = environment();
corrupt.machine.stop();
corrupt.filesystem.writefile(STATE_PATH, '{"version":1,"secret":"bad"}\n');
assert_throws(() => scheduler.create(corrupt.app), 'CORRUPT_STATE');

// start/stop are idempotent and the wake-up timer is capped at one minute even
// for a distant due time.
let lifecycle = environment();
for (let method in [ 'start', 'stop', 'tick', 'status', 'run_now' ])
	assert_throws(() => lifecycle.machine[method]('unexpected'), 'INVALID_ARGUMENT');
assert_equal(lifecycle.machine.start(), true);
assert_equal(lifecycle.machine.start(), false);
assert_true(lifecycle.clock.timers[0].due <= lifecycle.clock.now() + MINUTE);
assert_equal(lifecycle.machine.stop(), true);
assert_equal(lifecycle.machine.stop(), false);

print('ok - resilient subscription scheduler contracts\n');
