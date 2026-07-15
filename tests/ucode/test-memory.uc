import { assert_equal, assert_throws, assert_true } from './testlib.uc';
import * as memory from 'miclash.memory';
import * as fakes from './fakes.uc';

let fixture = json(require('fs').readfile('tests/fixtures/memory/traces.json'));

let now = 0;
let root_fs = fakes.fs({ '/var/run/miclash/.keep': '' });
let runtime = {
	clock: { now: () => now },
	fs: root_fs,
	digest: fakes.digest(root_fs),
	paths: { run: '/var/run/miclash' }
};
let service = {
	observe: () => ({ running: true, pid: 7 }),
	reload: () => ({ ok: true }),
	restart_core: () => ({ ok: true }),
	restart_service: () => ({ changed: true }),
	wait_ready: () => ({ ok: true })
};
let submitted = [];
let operations = {
	list: () => [],
	submit: (kind, source, context, worker) => {
		push(submitted, { kind, source, context, worker });
		return { id: 'op-1' };
	}
};
let guard = memory.create(runtime, service, operations, () => {});

assert_equal(sprintf('%J', guard.settings()), sprintf('%J', fixture.defaults));
for (let router in fixture.routers)
	assert_equal(guard.observe({ mem_total_kb: router.total_kb }).reserve_kb,
		router.reserve_kb, router.name);
assert_equal(guard.status().phase, 'waiting_for_mihomo');
assert_true(type(guard.sample) == 'function');
assert_true(type(guard.reset_baseline) == 'function');
assert_throws(() => guard.settings({ sustained_samples: 1 }), 'INVALID_ARGUMENT');
assert_equal(sprintf('%J', guard.settings(fixture.safe_settings)),
	sprintf('%J', fixture.safe_settings));
for (let invalid in [
	{ sample_interval_ms: 9999 }, { warmup_ms: 59999 }, { baseline_samples: 2 },
	{ anomaly_percent: 109 }, { anomaly_growth_kb: 4095 }, { reserve_percent: 4 },
	{ reserve_min_kb: 4095 }, { reserve_max_kb: 1048577 }, { drop_percent: 4 },
	{ drop_min_kb: 1023 }, { success_cooldown_ms: 59999 },
	{ failure_cooldown_ms: 59999 }, { normal_rearm_ms: 59999 },
	{ reserve_min_kb: 65536, reserve_max_kb: 16384 }
])
	assert_throws(() => guard.settings(invalid), 'INVALID_ARGUMENT');
guard.settings(fixture.defaults);

// Portable observation reads the actual runtime/service contracts, with PSI optional.
let stat_fields = [ '7', '(clash)', 'S' ];
for (let i = 0; i < 18; i++) push(stat_fields, '0');
push(stat_fields, '12345');
let optional_reads_throw = false;
let proc_runtime = {
	clock: { now: () => 0 }, paths: { run: '/var/run/miclash' },
	fs: { readfile: (path) => {
		if (optional_reads_throw && (path == '/proc/pressure/memory' ||
		    path == '/tmp/miclash-service/manual-operation')) die('NOT_FOUND');
		if (path == '/proc/7/stat') return join(' ', stat_fields);
		if (path == '/proc/7/status') return 'Name:\tclash\nVmRSS:\t62000 kB\n';
		if (path == '/proc/meminfo') return 'MemTotal: 262144 kB\nMemAvailable: 12000 kB\n';
		if (path == '/proc/pressure/memory') return 'some avg10=0.00 avg60=0.00 total=0\nfull avg10=0.25 avg60=0.10 total=3\n';
		return null;
	} }
};
let proc_service = {
	observe: () => ({ state: 'running', running: true, pid: 7 }),
	reload: service.reload, restart_core: service.restart_core,
	restart_service: service.restart_service, wait_ready: service.wait_ready
};
let proc_guard = memory.create(proc_runtime, proc_service, operations, () => {});
let proc_snapshot = proc_guard.observe();
assert_equal(proc_snapshot.start_time, 12345);
assert_equal(proc_snapshot.rss_kb, 62000);
assert_equal(proc_snapshot.mem_total_kb, 262144);
assert_equal(proc_snapshot.mem_available_kb, 12000);
assert_equal(proc_snapshot.psi_full_avg10, 0.25);
optional_reads_throw = true;
let no_psi_snapshot = proc_guard.observe();
assert_equal(no_psi_snapshot.rss_kb, 62000);
assert_equal(no_psi_snapshot.psi_full_avg10, null);

function snapshot(rss, available, identity) {
	identity ??= {};
	return {
		running: true,
		pid: identity.pid ?? 7,
		start_time: identity.start_time ?? 100,
		manual_generation: identity.manual_generation ?? 'manual-1',
		rss_kb: rss,
		mem_total_kb: 262144,
		mem_available_kb: available,
		psi_full_avg10: identity.psi_full_avg10
	};
};

// Warmup precedes the six-sample median baseline.
guard.sample(snapshot(60000, 100000));
assert_equal(guard.status().phase, 'warming_up');
now = fixture.defaults.warmup_ms;
for (let rss in fixture.baseline.samples_kb) {
	guard.sample(snapshot(rss, 100000));
	now += fixture.defaults.sample_interval_ms;
}
assert_equal(guard.status().phase, 'monitoring');
assert_equal(guard.status().baseline_rss_kb, fixture.baseline.median_kb);

// Either process identity dimension or a manual operation generation resets learning.
guard.sample(snapshot(62000, 100000, { pid: 8, start_time: 100 }));
assert_equal(guard.status().phase, 'warming_up');
assert_equal(guard.status().baseline_rss_kb, null);
guard.reset_baseline(snapshot(62000, 100000));
guard.sample(snapshot(62000, 100000, { start_time: 101 }));
assert_equal(guard.status().phase, 'warming_up');
guard.reset_baseline(snapshot(62000, 100000));
now += fixture.defaults.warmup_ms;
for (let rss in fixture.baseline.samples_kb) {
	guard.sample(snapshot(rss, 100000));
	now += fixture.defaults.sample_interval_ms;
}
guard.sample(snapshot(62000, 100000, { manual_generation: 'manual-2' }));
assert_equal(guard.status().phase, 'warming_up');

// Five consecutive Mihomo anomalies under low available-memory pressure submit once.
guard.reset_baseline(snapshot(61500, 100000));
now += fixture.defaults.warmup_ms;
for (let rss in fixture.baseline.samples_kb) {
	guard.sample(snapshot(rss, 100000));
	now += fixture.defaults.sample_interval_ms;
}
for (let i = 0; i < fixture.defaults.sustained_samples; i++) {
	guard.sample(snapshot(93000, 10000));
	if (i + 1 < fixture.defaults.sustained_samples)
		now += fixture.defaults.sample_interval_ms;
}
assert_equal(length(submitted), 1);
assert_equal(submitted[0].kind, 'memory-recovery');
assert_equal(submitted[0].source, 'auto');
for (let i = 0; i < fixture.defaults.sustained_samples * 2; i++)
	guard.sample(snapshot(93000, 10000));
assert_equal(length(submitted), 1);

function recovery_env(trace, options) {
	options ??= {};
	let time = 1000;
	let actions = [];
	let notices = [];
	let completed = [];
	let worker_returns = [];
	let ownership_releases = 0;
	let after = [ ...trace.rss_after_kb ];
	let readiness = [ ...trace.ready ];
	let observed = snapshot(93000, 10000);
	let state_path = '/var/run/miclash/memory.json';
	let initial_files = { '/var/run/miclash/.keep': '' };
	if (options.persisted != null) initial_files[state_path] = options.persisted;
	let disk = fakes.fs(initial_files);
	let ops = { calls: [] };
	ops.list = (query) => {
		if (options.list_throws || (options.list_throws_after_submit && length(ops.calls)))
			die('INTERNAL');
		if (options.busy) return [ { state: query.state, kind: 'other' } ];
		return query?.kind == 'memory-recovery' ?
			filter(ops.calls, (record) => record.accepted === true &&
				(record.state == 'queued' || record.state == 'running')) : [];
	};
	ops.submit = (kind, source, context, worker) => {
			if (options.submit_throws) die('INTERNAL');
			let record = { kind, source, context, state: options.defer_submit ? 'queued' : 'running',
				worker, accepted: true };
			push(ops.calls, record);
			if (options.order != null) push(options.order, 'submit');
			if (options.accept_then_throw) die('INTERNAL');
			if (options.defer_submit) return record;
			let done = false;
			let ctx = { id: 'op-1', complete: (error) => {
				if (options.complete_throws && !done) {
					options.complete_throws = false;
					die('INTERNAL');
				}
				if (done) return false;
				done = true;
				record.state = error == null ? 'success' : 'failure';
				push(completed, error == null ? 'success' : 'failure');
				ownership_releases++;
				return true;
			} };
			try {
				let returned = worker(ctx);
				push(worker_returns, returned);
				if (returned !== false && !done) ctx.complete(null);
			}
			catch (error) {
				if (!done) ctx.complete({ code: error?.code ?? error?.message ?? 'INTERNAL' });
			}
			return record;
		};
	let svc = {
		observe: () => {
			if (options.observer_throws && options.observer_throws-- > 0)
				die('HEALTH_FAILED');
			return observed;
		},
		reload: (profile) => {
			assert_equal(profile, 'config.yaml'); push(actions, 'reload');
			observed = snapshot(shift(after), 20000);
			return options.action_results?.reload ?? { ok: true };
		},
		restart_core: (profile) => {
			assert_equal(profile, 'config.yaml'); push(actions, 'restart_core');
			observed = snapshot(shift(after), 20000);
			return options.action_results?.restart_core ?? { ok: true };
		},
		restart_service: (profile) => {
			assert_equal(profile, 'config.yaml'); push(actions, 'restart_service');
			observed = snapshot(shift(after), 20000);
			return options.action_results?.restart_service ?? { changed: true, state: 'restarting' };
		},
		wait_ready: () => ({ ok: shift(readiness) === true })
	};
	if (options.order != null)
		disk.on_rename = () => push(options.order, 'persist');
	let rt = {
		clock: { now: () => time },
		fs: disk,
		digest: fakes.digest(disk),
		paths: { run: '/var/run/miclash' }
	};
	let controller = memory.create(rt, svc, ops, (event) => {
		if (options.notify_throws) die('INTERNAL');
		push(notices, event);
	});
	function learn() {
		controller.sample(snapshot(60000, 100000));
		time += fixture.defaults.warmup_ms;
		for (let rss in fixture.baseline.samples_kb) {
			controller.sample(snapshot(rss, 100000));
			time += fixture.defaults.sample_interval_ms;
		}
	};
	function trigger(trigger_snapshot) {
		trigger_snapshot ??= snapshot(93000, 10000);
		learn();
		for (let i = 0; i < fixture.defaults.sustained_samples; i++) {
			controller.sample(trigger_snapshot);
			if (i + 1 < fixture.defaults.sustained_samples)
				time += fixture.defaults.sample_interval_ms;
		}
	};
	return {
		controller, ops, actions, notices, completed, worker_returns, learn, trigger, now: () => time,
		ownership_releases: () => ownership_releases,
		advance: (milliseconds) => time += milliseconds,
		set_time: (value) => time = value,
		filesystem: disk,
		persisted: () => disk.files[state_path],
		recreate: () => memory.create(rt, svc, ops, () => {})
	};
};

// Rapid duplicate calls are not effective samples and cannot manufacture a
// learned baseline or a sustained anomaly at one clock instant.
let cadence_now = 0;
let cadence_calls = [];
let cadence_fs = fakes.fs({ '/var/run/miclash/.keep': '' });
let cadence_runtime = {
	clock: { now: () => cadence_now }, fs: cadence_fs, digest: fakes.digest(cadence_fs),
	paths: { run: '/var/run/miclash' }
};
let cadence_ops = {
	list: () => [],
	submit: (kind, source, context, worker) => { push(cadence_calls, { kind, worker }); return { id: 'cadence-1' }; }
};
let cadence_guard = memory.create(cadence_runtime, service, cadence_ops, () => {});
cadence_guard.sample(snapshot(60000, 100000));
cadence_now += fixture.defaults.warmup_ms;
for (let rss in fixture.baseline.samples_kb) {
	cadence_guard.sample(snapshot(rss, 100000));
	cadence_now += fixture.defaults.sample_interval_ms;
}
assert_equal(cadence_guard.status().baseline_rss_kb, fixture.baseline.median_kb);
for (let i = 0; i < fixture.defaults.sustained_samples; i++)
	cadence_guard.sample(snapshot(93000, 10000));
assert_equal(cadence_guard.status().pressure_samples, 1);
assert_equal(length(cadence_calls), 0);

// Every ladder stage succeeds only when readiness and an observer-proven
// 10%/+8 MiB drop both hold; otherwise the next Guard-preserving stage runs.
for (let trace in fixture.recovery_cases) {
	let env = recovery_env(trace);
	env.trigger();
	assert_equal(join(',', env.actions), join(',', trace.actions), trace.name);
	assert_equal(env.controller.status().last_result, trace.result, trace.name);
	assert_equal(join(',', env.completed), trace.result == 'success' ? 'success' : 'failure', trace.name);
	assert_equal(length(env.worker_returns), 1, trace.name);
	assert_equal(env.worker_returns[0], false, trace.name);
	assert_equal(env.ownership_releases(), 1, trace.name);
	assert_equal(env.ops.calls[0].context.preserve_guard, true, trace.name);
	assert_equal(env.controller.status().cooldown_until - env.now(),
		trace.result == 'success' ? fixture.defaults.success_cooldown_ms :
		fixture.defaults.failure_cooldown_ms, trace.name);
}

// Central-operation contention defers without consuming either cooldown.
let busy = recovery_env(fixture.recovery_cases[0], { busy: true });
busy.trigger();
assert_equal(length(busy.ops.calls), 0);
assert_equal(busy.controller.status().last_result, 'service_busy');
assert_equal(busy.controller.status().cooldown_until, 0);
let submit_failure = recovery_env(fixture.recovery_cases[0], { submit_throws: true });
submit_failure.trigger();
assert_equal(submit_failure.controller.status().last_result, 'operation_failed');
assert_equal(submit_failure.controller.status().cooldown_until, 0);

// A rejected stage result is not successful even if readiness and an
// incidental RSS drop follow it.
let rejected_action = recovery_env({
	ready: [ true, true ], rss_after_kb: [ 80000, 70000 ]
}, { action_results: { reload: { ok: false } } });
rejected_action.trigger();
assert_equal(join(',', rejected_action.actions), 'reload,restart_core');
assert_equal(rejected_action.controller.status().last_action, 'restart_core');
let rejected_core = recovery_env({
	ready: [ true, true, true ], rss_after_kb: [ 92000, 80000, 69000 ]
}, { action_results: { restart_core: { ok: false } } });
rejected_core.trigger();
assert_equal(join(',', rejected_core.actions), 'reload,restart_core,restart_service');
let rejected_service = recovery_env({
	ready: [ true, true, true ], rss_after_kb: [ 92000, 91000, 70000 ]
}, { action_results: { restart_service: { changed: false, state: 'restarting' } } });
rejected_service.trigger();
assert_equal(rejected_service.controller.status().last_result, 'failed');

// Long gaps and clock rollback break sustained anomaly continuity.
let long_gap = recovery_env(fixture.recovery_cases[0], { defer_submit: true });
long_gap.learn();
for (let i = 0; i < fixture.defaults.sustained_samples - 1; i++) {
	long_gap.controller.sample(snapshot(93000, 10000));
	long_gap.advance(fixture.defaults.sample_interval_ms);
}
long_gap.advance(fixture.defaults.sample_interval_ms * 3);
long_gap.controller.sample(snapshot(93000, 10000));
assert_equal(length(long_gap.ops.calls), 0);
assert_equal(long_gap.controller.status().pressure_samples, 1);
let rollback = recovery_env(fixture.recovery_cases[0], { defer_submit: true });
rollback.learn();
rollback.controller.sample(snapshot(93000, 10000));
rollback.advance(fixture.defaults.sample_interval_ms);
rollback.controller.sample(snapshot(93000, 10000));
rollback.set_time(rollback.now() - fixture.defaults.sample_interval_ms * 2);
rollback.controller.sample(snapshot(93000, 10000));
assert_equal(length(rollback.ops.calls), 0);
assert_equal(rollback.controller.status().pressure_samples, 0);

// Available-memory pressure is sufficient without PSI; PSI can also provide
// pressure when available memory is above reserve. Neither signal alone may
// recover a non-anomalous Mihomo process.
let psi = recovery_env(fixture.recovery_cases[0]);
psi.trigger(snapshot(93000, 100000, { psi_full_avg10: 0.01 }));
assert_equal(length(psi.ops.calls), 0);
let high_psi = recovery_env(fixture.recovery_cases[0]);
high_psi.trigger(snapshot(93000, 100000, { psi_full_avg10: 99.0 }));
assert_equal(length(high_psi.ops.calls), 0);
let normal = recovery_env(fixture.recovery_cases[0]);
normal.trigger(snapshot(93000, 100000));
assert_equal(length(normal.ops.calls), 0);
let system_only = recovery_env(fixture.recovery_cases[0]);
system_only.trigger(snapshot(70000, 10000));
assert_equal(length(system_only.ops.calls), 0);

// A completed outcome and cooldown survive construction of a new controller.
let durable = recovery_env(fixture.recovery_cases[0]);
durable.trigger();
assert_true(durable.persisted() != null);
let restarted = durable.recreate();
assert_equal(restarted.status().last_result, 'success');
assert_equal(restarted.status().cooldown_until, durable.controller.status().cooldown_until);

// A full failure cannot loop during its 24-hour cooldown and requires thirty
// continuous normal minutes after expiry before rearming.
let rearm = recovery_env(fixture.recovery_cases[4]);
rearm.trigger();
for (let i = 0; i < fixture.defaults.sustained_samples; i++)
	rearm.controller.sample(snapshot(93000, 10000));
assert_equal(length(rearm.ops.calls), 1);
rearm.advance(fixture.defaults.failure_cooldown_ms);
rearm.controller.sample(snapshot(70000, 100000));
assert_equal(rearm.controller.status().phase, 'failure_rearm_wait');
rearm.advance(fixture.defaults.normal_rearm_ms);
rearm.controller.sample(snapshot(70000, 100000));
assert_equal(rearm.controller.status().last_result, 'rearmed');

// Observer and notification failures are detached; completion failures follow
// operations.uc ownership semantics without rerunning an effective recovery.
let observer_failure = recovery_env(fixture.recovery_cases[1], { observer_throws: 1 });
observer_failure.trigger();
assert_equal(join(',', observer_failure.actions), 'reload,restart_core');
assert_equal(observer_failure.controller.status().last_result, 'success');
let notify_failure = recovery_env(fixture.recovery_cases[0], { notify_throws: true });
notify_failure.trigger();
assert_equal(notify_failure.controller.status().last_result, 'success');
let completion_failure = recovery_env(fixture.recovery_cases[0], { complete_throws: true });
completion_failure.trigger();
assert_equal(join(',', completion_failure.actions), 'reload');
assert_equal(join(',', completion_failure.completed), 'failure');
assert_equal(length(completion_failure.ops.calls), 1);
assert_equal(completion_failure.ownership_releases(), 1);

// State changes use the shared atomic storage contract. A failed durable write
// rolls both settings and runtime state back before any external side effect.
let atomic_order = [];
let atomic = recovery_env(fixture.recovery_cases[0], { defer_submit: true, order: atomic_order });
atomic.trigger();
assert_true(length(atomic.filesystem.calls.rename) > 0);
assert_true(index(atomic_order, 'persist') < index(atomic_order, 'submit'));
let queued_status = atomic.controller.status();
assert_equal(queued_status.phase, 'recovery_queued');
assert_true(type(queued_status.recovery_id) == 'string');
assert_throws(() => atomic.controller.reset_baseline(), 'BUSY');
let queued_restart = atomic.recreate();
assert_equal(queued_restart.status().phase, 'failure_cooldown');
assert_equal(queued_restart.status().cooldown_until - atomic.now(),
	fixture.defaults.failure_cooldown_ms);

for (let failure in [ 'open', 'write', 'rename' ]) {
	let failed_write = recovery_env(fixture.recovery_cases[0]);
	let before_settings = sprintf('%J', failed_write.controller.settings());
	failed_write.filesystem.fail_on = failure;
	assert_throws(() => failed_write.controller.settings({ sustained_samples: 6 }), 'INTERNAL');
	assert_equal(sprintf('%J', failed_write.controller.settings()), before_settings);
}

// Ambiguous submission retains conservative queued ownership; definite
// non-acceptance may roll back without consuming a recovery cooldown.
let ambiguous = recovery_env(fixture.recovery_cases[0], { accept_then_throw: true });
ambiguous.trigger();
assert_equal(ambiguous.controller.status().phase, 'recovery_queued');
assert_equal(length(ambiguous.ops.calls), 1);
let unknown_submit = recovery_env(fixture.recovery_cases[0], {
	accept_then_throw: true, list_throws_after_submit: true
});
unknown_submit.trigger();
assert_equal(unknown_submit.controller.status().phase, 'recovery_queued');

// Worker ownership failures become a durable failure cooldown before the real
// operations manager catches the propagated exception and releases once.
for (let target, expected_actions in {
	reload: '', restart_core: 'reload', restart_service: 'reload,restart_core'
}) {
	let stage_failure = recovery_env(fixture.recovery_cases[4], { defer_submit: true });
	stage_failure.trigger();
	assert_throws(() => stage_failure.ops.calls[0].worker({
		id: 'op-stage',
		stage: (name) => { if (name == target) die('INTERNAL'); },
		complete: () => true
	}), 'INTERNAL');
	assert_equal(stage_failure.controller.status().phase, 'failure_cooldown');
	assert_equal(join(',', stage_failure.actions), expected_actions);
}
assert_equal(completion_failure.controller.status().phase, 'failure_cooldown');

// A failed running-state commit prevents the next destructive action.
let no_durable_action = recovery_env(fixture.recovery_cases[0], { defer_submit: true });
no_durable_action.trigger();
no_durable_action.filesystem.fail_on = 'rename';
assert_throws(() => no_durable_action.ops.calls[0].worker({
	id: 'op-durable', stage: () => {}, complete: () => true
}), 'INTERNAL');
assert_equal(length(no_durable_action.actions), 0);
assert_equal(no_durable_action.controller.status().phase, 'recovery_queued');

// Expert changes that alter learning semantics reset dependent state, and
// reserve settings may never reserve all observed RAM.
let settings_reset = recovery_env(fixture.recovery_cases[0]);
settings_reset.learn();
assert_true(settings_reset.controller.status().baseline_rss_kb != null);
settings_reset.controller.settings({ baseline_samples: 7, sustained_samples: 6 });
assert_equal(settings_reset.controller.status().baseline_rss_kb, null);
assert_equal(settings_reset.controller.status().pressure_samples, 0);
assert_throws(() => settings_reset.controller.settings({
	reserve_min_kb: 262144, reserve_max_kb: 262144
}), 'INVALID_ARGUMENT');
let settings_restart = settings_reset.recreate();
assert_equal(settings_restart.settings().baseline_samples, 7);

// Snapshot values and identities are positive, coherent, and bounded.
for (let invalid_snapshot in [
	snapshot(0, 10000), snapshot(60000, -1), snapshot(60000, 300000),
	snapshot(60000, 10000, { pid: 0 }),
	snapshot(60000, 10000, { start_time: -1 }),
	snapshot(60000, 10000, { manual_generation: sprintf('%0300s', 'x') })
])
	assert_throws(() => settings_reset.controller.sample(invalid_snapshot), 'INVALID_ARGUMENT');

// Persisted state is an exact versioned contract; corruption is never treated
// as permission to forget a failure cooldown.
for (let corrupt in [
	'{"version":99,"state":{},"baseline_samples":[]}',
	'{"version":1,"state":{"phase":"monitoring","cooldown_until":0},"baseline_samples":[],"extra":true}',
	'{"version":1,"state":{"phase":"monitoring","cooldown_until":-1},"baseline_samples":[]}'
]) {
	let corrupt_runtime = {
		clock: { now: () => 0 }, paths: { run: '/var/run/miclash' },
		fs: { readfile: () => corrupt }
	};
	assert_throws(() => memory.create(corrupt_runtime, service, operations, () => {}),
		'CORRUPT_STATE');
}
