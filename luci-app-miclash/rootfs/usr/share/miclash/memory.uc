import { fail } from 'miclash.errors';
import * as storage from 'miclash.storage';

const DEFAULTS = {
	sample_interval_ms: 60000,
	sustained_samples: 5,
	warmup_ms: 900000,
	baseline_samples: 6,
	anomaly_percent: 150,
	anomaly_growth_kb: 16384,
	reserve_percent: 10,
	reserve_min_kb: 16384,
	reserve_max_kb: 65536,
	drop_percent: 10,
	drop_min_kb: 8192,
	success_cooldown_ms: 21600000,
	failure_cooldown_ms: 86400000,
	normal_rearm_ms: 1800000
};

const BOUNDS = {
	sample_interval_ms: [ 10000, 3600000 ], sustained_samples: [ 2, 60 ],
	warmup_ms: [ 60000, 86400000 ], baseline_samples: [ 3, 60 ],
	anomaly_percent: [ 110, 500 ], anomaly_growth_kb: [ 4096, 262144 ],
	reserve_percent: [ 5, 50 ], reserve_min_kb: [ 4096, 262144 ],
	reserve_max_kb: [ 8192, 1048576 ], drop_percent: [ 5, 90 ],
	drop_min_kb: [ 1024, 262144 ], success_cooldown_ms: [ 60000, 604800000 ],
	failure_cooldown_ms: [ 60000, 604800000 ], normal_rearm_ms: [ 60000, 86400000 ]
};

const PHASES = {
	waiting_for_mihomo: true, warming_up: true, learning_baseline: true,
	monitoring: true, recovery_queued: true, recovering: true,
	recovery_deferred: true, cooldown: true, failure_cooldown: true,
	failure_rearm_wait: true
};

const RESULTS = {
	success: true, failed: true, rearmed: true, service_busy: true,
	operation_failed: true, interrupted: true
};

const ACTIONS = { reload: true, restart_core: true, restart_service: true };
const STATE_VERSION = 2;

function invalid() { fail('INVALID_ARGUMENT'); };
function corrupt() { fail('CORRUPT_STATE'); };
function copy(value) { return json(sprintf('%J', value)); };

function exact_fields(value, fields) {
	if (type(value) != 'object') return false;
	for (let name in value)
		if (!exists(fields, name)) return false;
	for (let name in fields)
		if (!exists(value, name)) return false;
	return true;
};

function validate_settings(value) {
	if (!exact_fields(value, DEFAULTS)) invalid();
	for (let name, bound in BOUNDS)
		if (type(value[name]) != 'int' || value[name] < bound[0] || value[name] > bound[1])
			invalid();
	if (value.reserve_min_kb > value.reserve_max_kb ||
	    value.failure_cooldown_ms < value.success_cooldown_ms ||
	    value.warmup_ms < value.sample_interval_ms)
		invalid();
	return value;
};

export function create(runtime, service, operations, notify) {
	if (type(runtime?.clock?.now) != 'function' || type(service?.observe) != 'function' ||
	    type(service?.reload) != 'function' || type(service?.restart_core) != 'function' ||
	    type(service?.restart_service) != 'function' || type(service?.wait_ready) != 'function' ||
	    type(operations?.list) != 'function' || type(operations?.submit) != 'function' ||
	    type(notify) != 'function')
		invalid();

	let options = copy(DEFAULTS);
	let current = {
		phase: 'waiting_for_mihomo', pid: null, start_time: null,
		manual_generation: null, baseline_started_at: null,
		baseline_rss_kb: null, current_rss_kb: null,
		pressure_samples: 0, cooldown_until: 0, normal_since: null,
		last_action: null, last_result: null, last_sample_at: null,
		mem_total_kb: null, recovery_sequence: 0, recovery_id: null,
		active_stage: null
	};
	let baseline_samples = [];
	let recovery_pending = false;
	let state_path = (runtime.paths?.run ?? '/var/run/miclash') + '/memory.json';

	function disk_state() {
		return { version: STATE_VERSION, settings: options, state: current, baseline_samples };
	};

	function persist_state() {
		storage.write_json(runtime, state_path, disk_state(), 0o600);
		return true;
	};

	function transaction(change) {
		let before = {
			options: copy(options), current: copy(current),
			baseline_samples: copy(baseline_samples), recovery_pending
		};
		try {
			change();
			persist_state();
		}
		catch (error) {
			options = before.options;
			current = before.current;
			baseline_samples = before.baseline_samples;
			recovery_pending = before.recovery_pending;
			fail(error?.code ?? error?.message ?? 'INTERNAL');
		}
	};

	function valid_nullable(value, allowed_types) {
		if (value == null) return true;
		for (let expected in allowed_types)
			if (type(value) == expected) return true;
		return false;
	};

	function valid_start_time(value) {
		return (type(value) == 'int' && value > 0) ||
			(type(value) == 'string' && length(value) >= 1 && length(value) <= 32 &&
			 match(value, /^[0-9]+$/));
	};

	function valid_manual_generation(value) {
		return value == null || (type(value) == 'string' && length(value) >= 1 &&
			length(value) <= 128 && match(value, /^[A-Za-z0-9][A-Za-z0-9._:-]*$/));
	};

	function restore_state() {
		let saved;
		try { saved = storage.read_json(runtime, state_path); }
		catch (error) {
			let code = error?.code ?? error?.message;
			if (code == 'NOT_FOUND') return;
			fail(error?.code ?? error?.message ?? 'INTERNAL');
		}
		let top_fields = { version: true, settings: true, state: true, baseline_samples: true };
		let state_fields = {};
		for (let name in current) state_fields[name] = true;
		if (!exact_fields(saved, top_fields) || saved.version != STATE_VERSION ||
		    !exact_fields(saved.state, state_fields) || type(saved.baseline_samples) != 'array')
			corrupt();
		try { validate_settings(saved.settings); } catch (error) { corrupt(); }
		let state = saved.state;
		if (!exists(PHASES, state.phase) ||
		    !valid_nullable(state.pid, [ 'int' ]) || (state.pid != null && state.pid < 1) ||
		    (state.start_time != null && !valid_start_time(state.start_time)) ||
		    !valid_manual_generation(state.manual_generation) ||
		    !valid_nullable(state.baseline_started_at, [ 'int' ]) ||
		    (state.baseline_started_at != null && state.baseline_started_at < 0) ||
		    !valid_nullable(state.baseline_rss_kb, [ 'int' ]) ||
		    (state.baseline_rss_kb != null && state.baseline_rss_kb < 1) ||
		    !valid_nullable(state.current_rss_kb, [ 'int' ]) ||
		    (state.current_rss_kb != null && state.current_rss_kb < 1) ||
		    type(state.pressure_samples) != 'int' || state.pressure_samples < 0 ||
		    type(state.cooldown_until) != 'int' || state.cooldown_until < 0 ||
		    !valid_nullable(state.normal_since, [ 'int' ]) ||
		    (state.normal_since != null && state.normal_since < 0) ||
		    !valid_nullable(state.last_sample_at, [ 'int' ]) ||
		    (state.last_sample_at != null && state.last_sample_at < 0) ||
		    !valid_nullable(state.mem_total_kb, [ 'int' ]) ||
		    (state.mem_total_kb != null && state.mem_total_kb < 1) ||
		    type(state.recovery_sequence) != 'int' || state.recovery_sequence < 0 ||
		    !valid_nullable(state.recovery_id, [ 'string' ]) ||
		    (state.recovery_id != null && !match(state.recovery_id, /^memory-[0-9]+-[0-9]+$/)) ||
		    (state.active_stage != null && !exists(ACTIONS, state.active_stage)) ||
		    (state.last_action != null && !exists(ACTIONS, state.last_action)) ||
		    (state.last_result != null && !exists(RESULTS, state.last_result)))
			corrupt();
		for (let value in saved.baseline_samples)
			if (type(value) != 'int' || value < 1) corrupt();
		if (length(saved.baseline_samples) > saved.settings.baseline_samples ||
		    state.pressure_samples > saved.settings.sustained_samples)
			corrupt();
		if ((state.phase == 'recovery_queued' || state.phase == 'recovering') &&
		    state.recovery_id == null)
			corrupt();
		if (state.phase == 'recovering' && state.active_stage == null)
			corrupt();
		if (state.phase == 'recovery_queued' && state.active_stage != null)
			corrupt();
		if (state.phase == 'cooldown' &&
		    (state.last_result != 'success' || state.recovery_id == null ||
		     state.active_stage != null || state.baseline_rss_kb != null))
			corrupt();
		if ((state.phase == 'failure_cooldown' || state.phase == 'failure_rearm_wait') &&
		    (state.last_result != 'failed' || state.recovery_id == null ||
		     state.active_stage != null))
			corrupt();
		if (state.phase == 'recovery_deferred' &&
		    (state.last_result != 'service_busy' || state.active_stage != null))
			corrupt();
		if ((state.phase == 'warming_up' || state.phase == 'learning_baseline') &&
		    state.baseline_rss_kb != null)
			corrupt();
		if (state.phase == 'monitoring' && state.baseline_rss_kb == null)
			corrupt();
		if (state.phase == 'waiting_for_mihomo' &&
		    (state.pid != null || state.start_time != null || state.current_rss_kb != null ||
		     state.mem_total_kb != null || state.baseline_started_at != null ||
		     state.last_sample_at != null || state.baseline_rss_kb != null ||
		     state.pressure_samples != 0 || length(saved.baseline_samples) != 0))
			corrupt();
		if (state.phase != 'waiting_for_mihomo' &&
		    (state.pid == null || !valid_start_time(state.start_time) ||
		     state.current_rss_kb == null || state.mem_total_kb == null ||
		     state.baseline_started_at == null || state.last_sample_at == null))
			corrupt();
		options = copy(saved.settings);
		current = copy(state);
		baseline_samples = copy(saved.baseline_samples);
		if (current.phase == 'recovering' || current.phase == 'recovery_queued') {
			transaction(() => {
				current.phase = 'failure_cooldown';
				current.last_result = 'failed';
				current.active_stage = null;
				current.pressure_samples = 0;
				current.cooldown_until = runtime.clock.now() + options.failure_cooldown_ms;
			});
		}
	};

	restore_state();

	function reserve(total) {
		if (type(total) != 'int' || total < 1) invalid();
		let configured = max(options.reserve_min_kb,
			min(options.reserve_max_kb, int(total * options.reserve_percent / 100)));
		return min(configured, max(1, int(total / 2)));
	};

	function settings(next) {
		if (next == null) return copy(options);
		if (type(next) != 'object') invalid();
		let merged = copy(options);
		for (let name, value in next) {
			if (!exists(DEFAULTS, name) || type(value) != 'int') invalid();
			merged[name] = value;
		}
		validate_settings(merged);
		if (recovery_pending || current.phase == 'recovery_queued' || current.phase == 'recovering')
			fail('BUSY');
		transaction(() => {
			options = merged;
			baseline_samples = [];
			current.baseline_rss_kb = null;
			current.pressure_samples = 0;
			let learning_started_at = current.pid == null ? null : runtime.clock.now();
			current.last_sample_at = learning_started_at;
			current.baseline_started_at = learning_started_at;
			if (current.pid != null && current.phase == 'monitoring')
				current.phase = 'warming_up';
		});
		return copy(options);
	};

	function observe(snapshot) {
		if (snapshot == null) {
			try { snapshot = service.observe('config.yaml'); }
			catch (error) { return { running: false, state: 'unknown' }; }
			if (snapshot?.running === true && type(snapshot.pid) == 'int' &&
			    type(snapshot.rss_kb) != 'int') {
				try {
					let stat_text = runtime.fs.readfile('/proc/' + snapshot.pid + '/stat');
					let close = rindex(stat_text, ')');
					let fields = close >= 0 ? split(substr(stat_text, close + 2), ' ') : [];
					let status = match(runtime.fs.readfile('/proc/' + snapshot.pid + '/status') ?? '',
						/(^|\n)VmRSS:[ \t]*([0-9]+)[ \t]*kB/);
					let meminfo = runtime.fs.readfile('/proc/meminfo') ?? '';
					let total = match(meminfo, /(^|\n)MemTotal:[ \t]*([0-9]+)[ \t]*kB/);
					let available = match(meminfo, /(^|\n)MemAvailable:[ \t]*([0-9]+)[ \t]*kB/);
					if (length(fields) < 20 || status == null || total == null || available == null)
						return { running: false, state: 'metrics_unavailable' };
					snapshot.start_time = int(fields[19]);
					snapshot.rss_kb = int(status[2]);
					snapshot.mem_total_kb = int(total[2]);
					snapshot.mem_available_kb = int(available[2]);
					let psi = null;
					try {
						psi = match(runtime.fs.readfile('/proc/pressure/memory') ?? '',
							/(^|\n)full [^\n]*avg10=([0-9]+(\.[0-9]+)?)/);
					}
					catch (error) {}
					snapshot.psi_full_avg10 = psi == null ? null : +psi[2];
					let generation = null;
					try { generation = runtime.fs.readfile('/tmp/miclash-service/manual-operation'); }
					catch (error) {}
					generation = type(generation) == 'string' ? trim(generation) : null;
					snapshot.manual_generation = length(generation ?? '') ? generation : null;
				}
				catch (error) { return { running: false, state: 'metrics_unavailable' }; }
			}
		}
		if (type(snapshot) != 'object') invalid();
		let result = copy(snapshot);
		if (snapshot.mem_total_kb != null) result.reserve_kb = reserve(snapshot.mem_total_kb);
		return result;
	};

	function reset_learning(snapshot) {
		baseline_samples = [];
		current.baseline_rss_kb = null;
		current.pressure_samples = 0;
		current.last_sample_at = type(snapshot) == 'object' ? runtime.clock.now() : null;
		current.baseline_started_at = type(snapshot) == 'object' ? runtime.clock.now() : null;
		if (type(snapshot) == 'object') {
			current.pid = snapshot.pid ?? null;
			current.start_time = snapshot.start_time ?? null;
			current.manual_generation = snapshot.manual_generation ?? null;
			current.current_rss_kb = snapshot.rss_kb ?? null;
			current.mem_total_kb = snapshot.mem_total_kb ?? null;
			current.phase = 'warming_up';
		}
		else {
			current.pid = null;
			current.start_time = null;
			current.manual_generation = null;
			current.current_rss_kb = null;
			current.mem_total_kb = null;
			current.phase = 'waiting_for_mihomo';
		}
	};

	let validate_snapshot;

	function reset_baseline(snapshot) {
		if (recovery_pending || current.phase == 'recovery_queued' || current.phase == 'recovering')
			fail('BUSY');
		if (snapshot != null) {
			snapshot = observe(snapshot);
			validate_snapshot(snapshot);
		}
		transaction(() => reset_learning(snapshot));
		return copy(current);
	};

	function median(values) {
		let ordered = [ ...values ];
		sort(ordered, (a, b) => a - b);
		let middle = int(length(ordered) / 2);
		return length(ordered) % 2 ? ordered[middle] :
			int((ordered[middle - 1] + ordered[middle]) / 2);
	};

	function anomaly(snapshot) {
		return snapshot.rss_kb >= current.baseline_rss_kb + options.anomaly_growth_kb &&
			snapshot.rss_kb * 100 >= current.baseline_rss_kb * options.anomaly_percent;
	};

	function under_pressure(snapshot) {
		return snapshot.mem_available_kb < snapshot.reserve_kb;
	};

	validate_snapshot = (snapshot) => {
		if (snapshot.running !== true || type(snapshot.pid) != 'int' || snapshot.pid < 1 ||
		    !valid_start_time(snapshot.start_time) ||
		    !valid_manual_generation(snapshot.manual_generation) ||
		    type(snapshot.rss_kb) != 'int' || snapshot.rss_kb < 1 ||
		    type(snapshot.mem_total_kb) != 'int' || snapshot.mem_total_kb < 1 ||
		    snapshot.rss_kb > snapshot.mem_total_kb ||
		    type(snapshot.mem_available_kb) != 'int' || snapshot.mem_available_kb < 0 ||
		    snapshot.mem_available_kb > snapshot.mem_total_kb ||
		    snapshot.reserve_kb >= snapshot.mem_total_kb ||
		    (snapshot.psi_full_avg10 != null && type(snapshot.psi_full_avg10) != 'int' &&
		     type(snapshot.psi_full_avg10) != 'double') || snapshot.psi_full_avg10 < 0)
			invalid();
		return snapshot;
	};

	function material_drop(before, after) {
		if (type(before) != 'int' || type(after) != 'int' || after >= before) return false;
		let drop = before - after;
		return drop >= options.drop_min_kb && drop * 100 >= before * options.drop_percent;
	};

	function safe_notify(event) {
		try { notify(copy(event)); } catch (error) {}
	};

	function busy() {
		try {
			return length(operations.list({ state: 'running' })) > 0 ||
				length(operations.list({ state: 'queued' })) > 0;
		}
		catch (error) { return true; }
	};

	let transition_failure = () => {
		transaction(() => {
			current.phase = 'failure_cooldown';
			current.active_stage = null;
			current.last_result = 'failed';
			current.pressure_samples = 0;
			current.cooldown_until = runtime.clock.now() + options.failure_cooldown_ms;
		});
		recovery_pending = false;
	};

	function recover(ctx, initial) {
		let latest = initial;
		let stages = [
			{ name: 'reload', progress: 20, run: () => service.reload('config.yaml') },
			{ name: 'restart_core', progress: 50, run: () => service.restart_core('config.yaml') },
			{ name: 'restart_service', progress: 80, run: () => service.restart_service('config.yaml') }
		];
		for (let stage in stages) {
			transaction(() => {
				current.phase = 'recovering';
				current.active_stage = stage.name;
				current.last_action = stage.name;
			});
			if (type(ctx.stage) == 'function')
				ctx.stage(stage.name, stage.progress, 'Adaptive memory recovery');
			let action_result = null;
			try { action_result = stage.run(); } catch (error) {}
			let action_ok = stage.name == 'restart_service' ?
				action_result?.changed === true && action_result?.state == 'restarting' :
				action_result?.ok === true;
			let ready = false;
			if (action_ok) {
				try {
					ready = service.wait_ready(runtime.clock.now() + options.sample_interval_ms,
						'config.yaml', { tun_required: false })?.ok === true;
				}
				catch (error) {}
			}
			let after = null;
			try { after = observe(); } catch (error) {}
			let dropped = after != null && material_drop(latest.rss_kb, after.rss_kb);
			safe_notify({
				type: 'memory_recovery_stage', severity: 'info',
				recovery_id: current.recovery_id, action: stage.name,
				before_rss_kb: latest.rss_kb, after_rss_kb: after?.rss_kb ?? null,
				mem_available_kb: after?.mem_available_kb ?? latest.mem_available_kb,
				reserve_kb: after?.reserve_kb ?? latest.reserve_kb,
				ready, material_drop: dropped, preserve_guard: true
			});
			if (ready && dropped) {
				transaction(() => {
					reset_learning(after);
					current.current_rss_kb = after.rss_kb;
					current.phase = 'cooldown';
					current.active_stage = null;
					current.last_action = stage.name;
					current.last_result = 'success';
					current.cooldown_until = runtime.clock.now() + options.success_cooldown_ms;
				});
				recovery_pending = false;
				safe_notify({ type: 'memory_recovery', severity: 'notice',
					recovery_id: current.recovery_id, result: 'success',
					action: stage.name, before_rss_kb: initial.rss_kb,
					after_rss_kb: after.rss_kb, preserve_guard: true });
				ctx.complete(null);
				return false;
			}
			if (after?.rss_kb != null) latest = after;
		}
		transition_failure();
		safe_notify({ type: 'memory_recovery', severity: 'warning',
			recovery_id: current.recovery_id, result: 'failed',
			before_rss_kb: initial.rss_kb, after_rss_kb: latest.rss_kb,
			preserve_guard: true });
		ctx.complete({ code: 'HEALTH_FAILED', message: 'HEALTH_FAILED' });
		return false;
	};

	function submit_recovery(snapshot) {
		if (recovery_pending) return;
		if (busy()) {
			transaction(() => {
				current.phase = 'recovery_deferred';
				current.last_result = 'service_busy';
				current.pressure_samples = 0;
			});
			return;
		}
		transaction(() => {
			current.recovery_sequence++;
			current.recovery_id = sprintf('memory-%d-%d', current.recovery_sequence,
				runtime.clock.now());
			current.phase = 'recovery_queued';
			current.active_stage = null;
			current.pressure_samples = 0;
		});
		recovery_pending = true;
		try {
			operations.submit('memory-recovery', 'auto', {
				before_rss_kb: snapshot.rss_kb,
				mem_available_kb: snapshot.mem_available_kb,
				reserve_kb: snapshot.reserve_kb,
				preserve_guard: true,
				recovery_id: current.recovery_id
			}, (ctx) => {
				try { return recover(ctx, snapshot); }
				catch (error) {
					if (current.phase != 'failure_cooldown') transition_failure();
					fail(error?.code ?? error?.message ?? 'INTERNAL');
				}
			});
		}
		catch (error) {
			let accepted = null;
			try {
				accepted = false;
				for (let record in operations.list({ kind: 'memory-recovery', source: 'auto' }))
					if (record.state == 'queued' || record.state == 'running') accepted = true;
			}
			catch (list_error) { accepted = null; }
			if (accepted === false) {
				transaction(() => {
					current.phase = 'monitoring';
					current.recovery_id = null;
					current.active_stage = null;
					current.last_result = 'operation_failed';
				});
				recovery_pending = false;
			}
		}
	};

	function sample(snapshot) {
		if (recovery_pending || current.phase == 'recovery_queued' ||
		    current.phase == 'recovering')
			return copy(current);
		snapshot = observe(snapshot);
		if (snapshot.running !== true) {
			transaction(() => reset_learning(null));
			return copy(current);
		}
		validate_snapshot(snapshot);
		let now = runtime.clock.now();
		if (current.last_sample_at != null) {
			let elapsed = now - current.last_sample_at;
			if (elapsed < 0) {
				transaction(() => {
					reset_learning(snapshot);
					current.last_sample_at = now;
				});
				return copy(current);
			}
			if (elapsed < options.sample_interval_ms)
				return copy(current);
			if (elapsed > options.sample_interval_ms * 2)
				transaction(() => { current.pressure_samples = 0; });
		}
		if (current.pid != snapshot.pid || current.start_time != snapshot.start_time ||
		    current.manual_generation != snapshot.manual_generation) {
			transaction(() => {
				reset_learning(snapshot);
				current.last_sample_at = now;
			});
			return copy(current);
		}
		transaction(() => {
			current.current_rss_kb = snapshot.rss_kb;
			current.mem_total_kb = snapshot.mem_total_kb;
			current.last_sample_at = now;
		});
		if (recovery_pending) return copy(current);
		if (current.last_result == 'success' && current.cooldown_until > now) {
			transaction(() => { current.phase = 'cooldown'; });
			return copy(current);
		}
		if (current.last_result == 'failed') {
			if (current.cooldown_until > now) {
				transaction(() => { current.phase = 'failure_cooldown'; });
				return copy(current);
			}
			if (snapshot.mem_available_kb < snapshot.reserve_kb) {
				transaction(() => {
					current.normal_since = null;
					current.phase = 'failure_rearm_wait';
				});
				return copy(current);
			}
			if (current.normal_since == null)
				transaction(() => { current.normal_since = now; });
			if (now - current.normal_since < options.normal_rearm_ms) {
				transaction(() => { current.phase = 'failure_rearm_wait'; });
				return copy(current);
			}
			transaction(() => {
				current.last_result = 'rearmed';
				current.normal_since = null;
			});
		}
		if (now - current.baseline_started_at < options.warmup_ms) {
			transaction(() => { current.phase = 'warming_up'; });
			return copy(current);
		}
		if (current.baseline_rss_kb == null) {
			transaction(() => {
				current.phase = 'learning_baseline';
				push(baseline_samples, snapshot.rss_kb);
				if (length(baseline_samples) >= options.baseline_samples) {
					current.baseline_rss_kb = median(baseline_samples);
					current.phase = 'monitoring';
				}
			});
			return copy(current);
		}
		transaction(() => {
			current.phase = 'monitoring';
			current.pressure_samples = anomaly(snapshot) && under_pressure(snapshot) ?
				current.pressure_samples + 1 : 0;
		});
		if (current.pressure_samples >= options.sustained_samples) submit_recovery(snapshot);
		return copy(current);
	};

	return {
		observe, sample, reset_baseline, settings,
		status: () => copy(current)
	};
};
