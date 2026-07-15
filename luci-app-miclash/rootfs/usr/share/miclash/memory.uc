import { fail } from 'miclash.errors';

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
		last_action: null, last_result: null
	};
	let baseline_samples = [];
	let recovery_pending = false;
	let state_path = (runtime.paths?.run ?? '/var/run/miclash') + '/memory.json';

	function persist_state() {
		if (type(runtime.fs?.writefile) != 'function') return false;
		try {
			return runtime.fs.writefile(state_path, sprintf('%J', {
				version: 1, settings: options, state: current, baseline_samples
			})) !== false;
		}
		catch (error) { return false; }
	};

	function valid_nullable(value, allowed_types) {
		if (value == null) return true;
		for (let expected in allowed_types)
			if (type(value) == expected) return true;
		return false;
	};

	function restore_state() {
		if (type(runtime.fs?.readfile) != 'function') return;
		let raw;
		try { raw = runtime.fs.readfile(state_path); }
		catch (error) { fail('INTERNAL'); }
		if (raw == null) return;
		if (type(raw) != 'string') corrupt();
		let saved;
		try { saved = json(raw); } catch (error) { corrupt(); }
		let top_fields = { version: true, settings: true, state: true, baseline_samples: true };
		let state_fields = {};
		for (let name in current) state_fields[name] = true;
		if (!exact_fields(saved, top_fields) || saved.version != 1 ||
		    !exact_fields(saved.state, state_fields) || type(saved.baseline_samples) != 'array')
			corrupt();
		try { validate_settings(saved.settings); } catch (error) { corrupt(); }
		let state = saved.state;
		if (!exists(PHASES, state.phase) ||
		    !valid_nullable(state.pid, [ 'int' ]) || (state.pid != null && state.pid < 1) ||
		    !valid_nullable(state.start_time, [ 'int', 'string' ]) ||
		    !valid_nullable(state.manual_generation, [ 'string' ]) ||
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
		    (state.last_action != null && !exists(ACTIONS, state.last_action)) ||
		    (state.last_result != null && !exists(RESULTS, state.last_result)))
			corrupt();
		for (let value in saved.baseline_samples)
			if (type(value) != 'int' || value < 1) corrupt();
		if (length(saved.baseline_samples) > saved.settings.baseline_samples ||
		    state.pressure_samples > saved.settings.sustained_samples)
			corrupt();
		options = copy(saved.settings);
		current = copy(state);
		baseline_samples = copy(saved.baseline_samples);
		if (current.phase == 'recovering' || current.phase == 'recovery_queued') {
			current.phase = 'monitoring';
			current.last_result = 'interrupted';
			current.pressure_samples = 0;
			persist_state();
		}
	};

	restore_state();

	function reserve(total) {
		if (type(total) != 'int' || total < 1) invalid();
		return max(options.reserve_min_kb,
			min(options.reserve_max_kb, int(total * options.reserve_percent / 100)));
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
		options = merged;
		persist_state();
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
					snapshot.manual_generation = type(generation) == 'string' ? trim(generation) : null;
				}
				catch (error) { return { running: false, state: 'metrics_unavailable' }; }
			}
		}
		if (type(snapshot) != 'object') invalid();
		let result = copy(snapshot);
		if (snapshot.mem_total_kb != null) result.reserve_kb = reserve(snapshot.mem_total_kb);
		return result;
	};

	function reset_baseline(snapshot) {
		baseline_samples = [];
		recovery_pending = false;
		current.baseline_rss_kb = null;
		current.pressure_samples = 0;
		current.baseline_started_at = runtime.clock.now();
		if (type(snapshot) == 'object') {
			current.pid = snapshot.pid ?? null;
			current.start_time = snapshot.start_time ?? null;
			current.manual_generation = snapshot.manual_generation ?? null;
			current.current_rss_kb = snapshot.rss_kb ?? null;
			current.phase = 'warming_up';
		}
		else {
			current.pid = null;
			current.start_time = null;
			current.manual_generation = null;
			current.current_rss_kb = null;
			current.phase = 'waiting_for_mihomo';
		}
		persist_state();
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
		return snapshot.mem_available_kb < snapshot.reserve_kb ||
			((type(snapshot.psi_full_avg10) == 'int' ||
			  type(snapshot.psi_full_avg10) == 'double') && snapshot.psi_full_avg10 > 0);
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

	function recover(ctx, initial) {
		let latest = initial;
		let stages = [
			{ name: 'reload', progress: 20, run: () => service.reload('config.yaml') },
			{ name: 'restart_core', progress: 50, run: () => service.restart_core('config.yaml') },
			{ name: 'restart_service', progress: 80, run: () => service.restart_service('config.yaml') }
		];
		for (let stage in stages) {
			current.phase = 'recovering';
			current.last_action = stage.name;
			if (type(ctx.stage) == 'function')
				ctx.stage(stage.name, stage.progress, 'Adaptive memory recovery');
			let action_ok = true;
			try { stage.run(); } catch (error) { action_ok = false; }
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
				type: 'memory_recovery_stage', severity: 'info', action: stage.name,
				before_rss_kb: latest.rss_kb, after_rss_kb: after?.rss_kb ?? null,
				mem_available_kb: after?.mem_available_kb ?? latest.mem_available_kb,
				reserve_kb: after?.reserve_kb ?? latest.reserve_kb,
				ready, material_drop: dropped, preserve_guard: true
			});
			if (ready && dropped) {
				reset_baseline(after);
				current.current_rss_kb = after.rss_kb;
				current.phase = 'cooldown';
				current.last_action = stage.name;
				current.last_result = 'success';
				current.cooldown_until = runtime.clock.now() + options.success_cooldown_ms;
				persist_state();
				safe_notify({ type: 'memory_recovery', severity: 'notice', result: 'success',
					action: stage.name, before_rss_kb: initial.rss_kb,
					after_rss_kb: after.rss_kb, preserve_guard: true });
				ctx.complete(null);
				return false;
			}
			if (after?.rss_kb != null) latest = after;
		}
		recovery_pending = false;
		current.phase = 'failure_cooldown';
		current.last_result = 'failed';
		current.cooldown_until = runtime.clock.now() + options.failure_cooldown_ms;
		persist_state();
		safe_notify({ type: 'memory_recovery', severity: 'warning', result: 'failed',
			before_rss_kb: initial.rss_kb, after_rss_kb: latest.rss_kb,
			preserve_guard: true });
		ctx.complete({ code: 'HEALTH_FAILED', message: 'HEALTH_FAILED' });
		return false;
	};

	function submit_recovery(snapshot) {
		if (recovery_pending) return;
		if (busy()) {
			current.phase = 'recovery_deferred';
			current.last_result = 'service_busy';
			current.pressure_samples = 0;
			persist_state();
			return;
		}
		recovery_pending = true;
		current.phase = 'recovery_queued';
		current.pressure_samples = 0;
		persist_state();
		try {
			operations.submit('memory-recovery', 'auto', {
				before_rss_kb: snapshot.rss_kb,
				mem_available_kb: snapshot.mem_available_kb,
				reserve_kb: snapshot.reserve_kb,
				preserve_guard: true
			}, (ctx) => recover(ctx, snapshot));
		}
		catch (error) {
			recovery_pending = false;
			current.phase = 'monitoring';
			current.last_result = 'operation_failed';
			persist_state();
		}
	};

	function sampled() {
		persist_state();
		return copy(current);
	};

	function sample(snapshot) {
		snapshot = observe(snapshot);
		if (snapshot.running !== true || type(snapshot.pid) != 'int' ||
		    (type(snapshot.start_time) != 'int' && type(snapshot.start_time) != 'string') ||
		    type(snapshot.rss_kb) != 'int' || type(snapshot.mem_available_kb) != 'int') {
			current.phase = 'waiting_for_mihomo';
			return sampled();
		}
		if (current.pid != snapshot.pid || current.start_time != snapshot.start_time ||
		    current.manual_generation != snapshot.manual_generation) {
			reset_baseline(snapshot);
			return sampled();
		}
		current.current_rss_kb = snapshot.rss_kb;
		if (recovery_pending) return sampled();
		let now = runtime.clock.now();
		if (current.last_result == 'success' && current.cooldown_until > now) {
			current.phase = 'cooldown';
			return sampled();
		}
		if (current.last_result == 'failed') {
			if (current.cooldown_until > now) {
				current.phase = 'failure_cooldown';
				return sampled();
			}
			let psi_normal = snapshot.psi_full_avg10 == null || snapshot.psi_full_avg10 <= 0;
			if (snapshot.mem_available_kb < snapshot.reserve_kb || !psi_normal) {
				current.normal_since = null;
				current.phase = 'failure_rearm_wait';
				return sampled();
			}
			if (current.normal_since == null) current.normal_since = now;
			if (now - current.normal_since < options.normal_rearm_ms) {
				current.phase = 'failure_rearm_wait';
				return sampled();
			}
			current.last_result = 'rearmed';
			current.normal_since = null;
		}
		if (now - current.baseline_started_at < options.warmup_ms) {
			current.phase = 'warming_up';
			return sampled();
		}
		if (current.baseline_rss_kb == null) {
			current.phase = 'learning_baseline';
			push(baseline_samples, snapshot.rss_kb);
			if (length(baseline_samples) >= options.baseline_samples) {
				current.baseline_rss_kb = median(baseline_samples);
				current.phase = 'monitoring';
			}
			return sampled();
		}
		current.phase = 'monitoring';
		current.pressure_samples = anomaly(snapshot) && under_pressure(snapshot) ?
			current.pressure_samples + 1 : 0;
		if (current.pressure_samples >= options.sustained_samples) submit_recovery(snapshot);
		return sampled();
	};

	return {
		observe, sample, reset_baseline, settings,
		status: () => copy(current)
	};
};
