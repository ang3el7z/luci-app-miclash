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
	let filesystem = fakes.fs(options.files ?? {
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
	let outcomes = {};
	let subscription = {};
	subscription.update = (request, source) => {
		push(calls, { request, source });
		let scenario = length(scenarios) ? shift(scenarios) : {};
		return ops.submit('subscription.update', source,
			{ profile: request.profile }, (ctx) => {
				let outcome = {
					downloaded: false, validated: false, activated: false,
					reload_ok: false, interval_hours: null
				};
				outcomes[ctx.id] = outcome;
				ctx.stage('attempt', 10, 'attempt');
				if (scenario.error == 'DOWNLOAD_FAILED') {
					ctx.complete(errors.new('DOWNLOAD_FAILED'));
					return false;
				}
				outcome.downloaded = true;
				outcome.interval_hours = scenario.interval_hours ?? null;
				ctx.stage('download', 35, 'download');
				ctx.stage('validation', 55, 'validation');
				if (scenario.error == 'VALIDATION_FAILED') {
					ctx.complete(errors.new('VALIDATION_FAILED'));
					return false;
				}
				outcome.validated = true;
				ctx.stage('activation', 75, 'activation');
				outcome.activated = true;
				ctx.stage('reload', 95, 'reload');
				if (scenario.error == 'HEALTH_FAILED') {
					ctx.complete(errors.new('HEALTH_FAILED'));
					return false;
				}
				outcome.reload_ok = true;
				return true;
			});
	};
	subscription.consume_scheduler_outcome = (id) => {
		let value = outcomes[id];
		delete outcomes[id];
		return value;
	};
	let app = { runtime, operations: ops, settings, subscription };
	return { filesystem, clock, runtime, ops, settings, scenarios, calls,
		outcomes, app, machine: scheduler.create(app) };
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

// A successful scheduled update records every stage, resets backoff, and uses
// the configured interval. Only the scheduler operation id is persisted.
let normal = environment();
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

// A trusted profile interval overrides the configured interval for this next
// schedule and survives daemon reconstruction from durable state.
let provided = environment({ scenarios: [ { interval_hours: 12 } ] });
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
pending_restart.machine.tick();
let durable_id = pending_restart.machine.status().pending_operation_id;
pending_restart.machine.stop();
drain(pending_restart);
let resumed = scheduler.create(pending_restart.app);
assert_equal(resumed.status().pending_operation_id, null);
assert_equal(resumed.status().last_success, pending_restart.clock.now());
assert_equal(pending_restart.ops.get(durable_id).state, 'success');

let stopped_pending = environment();
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
busy.machine.tick();
assert_equal(length(busy.calls), 0);
assert_equal(busy.machine.status().failure_count, 0);
assert_equal(busy.machine.status().next_attempt, busy.clock.now() + MINUTE);

// Manual run resets only waiting: existing audit and failure counters remain,
// but the operation becomes immediately due.
let manual = environment({ scenarios: [ { error: 'DOWNLOAD_FAILED' } ] });
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
let rollback = environment();
rollback.machine.tick();
drain(rollback);
rollback.clock.advance(-HOUR);
rollback.machine.tick();
assert_equal(length(rollback.calls), 1);
assert_equal(rollback.machine.status().next_attempt,
	rollback.clock.now() + 4 * HOUR);

// A daemon restart with an unresolved durable operation id cannot leave the
// scheduler waiting forever: a missing/interrupted record becomes a bounded
// retry with a redacted code.
let interrupted = environment();
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
assert_equal(lifecycle.machine.start(), true);
assert_equal(lifecycle.machine.start(), false);
assert_true(lifecycle.clock.timers[0].due <= lifecycle.clock.now() + MINUTE);
assert_equal(lifecycle.machine.stop(), true);
assert_equal(lifecycle.machine.stop(), false);

print('ok - resilient subscription scheduler contracts\n');
