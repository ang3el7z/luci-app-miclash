import * as errors from 'miclash.errors';
import * as schema from 'miclash.schema';
import * as storage from 'miclash.storage';

const STATE_PATH = '/opt/clash/subscription-scheduler.json';
const STATE_PARENT = '/opt/clash';
const MINUTE = 60 * 1000;
const HOUR = 60 * MINUTE;
const MAX_INTERVAL_HOURS = 8760;
const MAX_TIMESTAMP = 253402300799999;
const STATE_FIELDS = {
	version: true,
	last_attempt: true,
	last_download: true,
	last_validation: true,
	last_activation: true,
	last_reload: true,
	last_success: true,
	next_attempt: true,
	failure_count: true,
	last_failure_code: true,
	interval_hours: true,
	pending_operation_id: true,
	observed_at: true,
	clock_ceiling: true
};
const STAGE_INDEX = {
	queued: 0, attempt: 1, download: 2, validation: 3,
	activation: 4, reload: 5, complete: 6, interrupted: 7
};

function invalid() {
	errors.fail('INVALID_ARGUMENT');
};

function corrupt() {
	errors.fail('CORRUPT_STATE');
};

function clone(value) {
	try { return json(sprintf('%J', value)); }
	catch (error) { errors.fail('INTERNAL'); }
};

function timestamp(value) {
	return value == null || (type(value) == 'int' && value >= 0 &&
		value <= MAX_TIMESTAMP);
};

function interval(value) {
	return type(value) == 'int' && value >= 1 && value <= MAX_INTERVAL_HOURS;
};

function operation_id(value) {
	if (value == null)
		return null;
	return schema.operation_id(value);
};

function safe_error_code(value) {
	if (type(value) == 'string')
		for (let candidate in errors.CODES)
			if (candidate == value)
				return value;
	return 'INTERNAL';
};

function known_error_code(value) {
	if (type(value) != 'string')
		return false;
	for (let candidate in errors.CODES)
		if (candidate == value)
			return true;
	return false;
};

function same_node(left, right) {
	return left?.type != null && left.type == right?.type && left.inode == right?.inode &&
		left.dev?.major == right.dev?.major && left.dev?.minor == right.dev?.minor;
};

function same_identity(left, right) {
	return same_node(left, right) && left.nlink == right.nlink &&
		left.size == right.size && left.mode == right.mode && left.uid == right.uid;
};

function secure_parent(runtime) {
	let value = runtime.fs.lstat(STATE_PARENT);
	if (value?.type != 'directory' || runtime.fs.realpath(STATE_PARENT) != STATE_PARENT ||
	    type(value.mode) != 'int' || (value.mode & 0o022) != 0 ||
	    (value.uid != null && value.uid != 0))
		corrupt();
	return value;
};

function secure_read(runtime) {
	let parent_before = secure_parent(runtime);
	let before = runtime.fs.lstat(STATE_PATH);
	if (before == null) {
		let parent_after = secure_parent(runtime);
		if (!same_identity(parent_before, parent_after))
			corrupt();
		return null;
	}
	if (before.type != 'file' || before.nlink != 1 || before.mode != 0o600 ||
	    (before.uid != null && before.uid != 0) ||
	    runtime.fs.realpath(STATE_PATH) != STATE_PATH)
		corrupt();
	let content = runtime.fs.readfile(STATE_PATH);
	let after = runtime.fs.lstat(STATE_PATH);
	let content_hash = type(content) == 'string' ? runtime.digest.sha256(content) : null;
	let file_hash = runtime.digest.sha256_file(STATE_PATH);
	let final = runtime.fs.lstat(STATE_PATH);
	let parent_after = secure_parent(runtime);
	if (type(content) != 'string' || length(content) != before.size ||
	    content_hash == null || content_hash != file_hash ||
	    !same_identity(before, after) || !same_identity(after, final) ||
	    !same_identity(parent_before, parent_after) ||
	    runtime.fs.realpath(STATE_PATH) != STATE_PATH)
		corrupt();
	try { return json(content); }
	catch (error) { corrupt(); }
};

function initial_state(now) {
	return {
		version: 1,
		last_attempt: null,
		last_download: null,
		last_validation: null,
		last_activation: null,
		last_reload: null,
		last_success: null,
		next_attempt: null,
		failure_count: 0,
		last_failure_code: null,
		interval_hours: null,
		pending_operation_id: null,
		observed_at: now,
		clock_ceiling: now
	};
};

function validate_state(value) {
	if (type(value) != 'object')
		corrupt();
	let fields = 0;
	for (let name in value) {
		if (!exists(STATE_FIELDS, name))
			corrupt();
		fields++;
	}
	if (fields != 14 || value.version != 1 ||
	    !timestamp(value.last_attempt) || !timestamp(value.last_download) ||
	    !timestamp(value.last_validation) || !timestamp(value.last_activation) ||
	    !timestamp(value.last_reload) || !timestamp(value.last_success) ||
	    !timestamp(value.next_attempt) || !timestamp(value.observed_at) ||
	    !timestamp(value.clock_ceiling) || value.observed_at == null ||
	    value.clock_ceiling == null || value.observed_at > value.clock_ceiling ||
	    type(value.failure_count) != 'int' || value.failure_count < 0 ||
	    value.failure_count > 1000000 ||
	    (value.failure_count == 0) != (value.last_failure_code == null) ||
	    (value.last_failure_code != null && !known_error_code(value.last_failure_code)) ||
	    (value.interval_hours != null && !interval(value.interval_hours)) ||
	    (value.last_success == null) != (value.interval_hours == null))
		corrupt();
	try { operation_id(value.pending_operation_id); }
	catch (error) { corrupt(); }
	if (value.pending_operation_id != null && value.next_attempt == null)
		corrupt();

	let previous = null, missing = false;
	for (let stamp in [ value.last_attempt, value.last_download,
		value.last_validation, value.last_activation, value.last_reload ]) {
		if (stamp == null)
			missing = true;
		else if (missing || (previous != null && stamp < previous) ||
		         stamp > value.clock_ceiling)
			corrupt();
		else
			previous = stamp;
	}
	if (value.last_success != null) {
		if (value.last_attempt == null || value.last_success > value.clock_ceiling)
			corrupt();
		if (value.failure_count == 0 && value.pending_operation_id == null &&
		    (value.last_reload == null || value.last_success < value.last_reload))
			corrupt();
	}
	return value;
};

function retry_minutes(failure_count) {
	if (failure_count <= 1)
		return 5;
	if (failure_count == 2)
		return 15;
	return 60;
};

function timeline(record) {
	if (type(record?.timeline) != 'array' || length(record.timeline) < 1 ||
	    length(record.timeline) > 32)
		corrupt();
	let previous_index = -1, previous_at = null, values = {};
	for (let position, item in record.timeline) {
		let index = STAGE_INDEX[item?.stage];
		if (index == null || type(item.at) != 'int' || !timestamp(item.at) ||
		    (position == 0 && item.stage != 'queued') ||
		    (previous_at != null && item.at < previous_at) ||
		    index <= previous_index || (item.stage == 'interrupted' &&
		    position != length(record.timeline) - 1))
			corrupt();
		previous_index = index;
		previous_at = item.at;
		values[item.stage] = item.at;
	}
	return values;
};

export function create(app) {
	if (type(app?.runtime?.fs) != 'object' ||
	    type(app?.runtime?.clock?.now) != 'function' ||
	    type(app?.runtime?.clock?.set_timeout) != 'function' ||
	    type(app?.runtime?.digest?.sha256) != 'function' ||
	    type(app?.runtime?.digest?.sha256_file) != 'function' ||
	    type(app?.operations?.get) != 'function' ||
	    type(app?.operations?.list) != 'function' ||
	    type(app?.operations?.subscribe) != 'function' ||
	    type(app?.settings?.get) != 'function' ||
	    type(app?.subscription?.update_scheduled) != 'function')
		invalid();

	let runtime = app.runtime;
	let now = runtime.clock.now();
	if (!timestamp(now) || now == null)
		errors.fail('INTERNAL');
	let stored = secure_read(runtime);
	let state = stored == null ? initial_state(now) : validate_state(stored);
	let started = false;
	let timer = null;
	let unsubscribe = null;
	let api = {};

	function persist() {
		validate_state(state);
		// Refuse to overwrite a path whose authority changed after construction.
		let existing = secure_read(runtime);
		if (existing != null)
			validate_state(existing);
		storage.write_json(runtime, STATE_PATH, state, 0o600);
		let verified = validate_state(secure_read(runtime));
		if (sprintf('%J', verified) != sprintf('%J', state))
			errors.fail('INTERNAL');
	};

	function settings_state() {
		let value;
		try { value = app.settings.get(); }
		catch (error) { return { enabled: false, reason: 'invalid_settings' }; }
		let enabled = value?.updates?.auto_subscription;
		let hours = value?.updates?.interval_hours;
		let url = value?.core?.subscription_url_config_yaml;
		if (type(url) != 'string' || !length(url))
			url = value?.core?.subscription_url;
		if (type(enabled) != 'bool' || !interval(hours) || type(url) != 'string')
			return { enabled: false, reason: 'invalid_settings' };
		if (!enabled)
			return { enabled: false, reason: 'disabled', hours };
		if (!length(url))
			return { enabled: false, reason: 'no_url', hours };
		return { enabled: true, reason: null, hours };
	};

	function observe_clock() {
		let current = runtime.clock.now();
		if (!timestamp(current) || current == null)
			errors.fail('INTERNAL');
		if (current < state.observed_at && state.next_attempt != null) {
			let remaining = state.next_attempt - state.observed_at;
			if (remaining < MINUTE)
				remaining = MINUTE;
			state.next_attempt = current + remaining;
		}
		state.observed_at = current;
		if (current > state.clock_ceiling)
			state.clock_ceiling = current;
		return current;
	};

	function schedule_timer() {
		if (!started)
			return;
		if (timer != null)
			timer.cancel();
		let current = runtime.clock.now();
		let delay = MINUTE;
		if (state.next_attempt != null && state.next_attempt <= current)
			delay = 0;
		else if (state.next_attempt != null && state.next_attempt - current < delay)
			delay = state.next_attempt - current;
		timer = runtime.clock.set_timeout(delay, () => {
			timer = null;
			api.tick();
		});
	};

	function mark_failure(code, finished_at) {
		state.failure_count++;
		if (state.failure_count > 1000000)
			state.failure_count = 1000000;
		state.last_failure_code = safe_error_code(code);
		state.pending_operation_id = null;
		state.next_attempt = finished_at + retry_minutes(state.failure_count) * MINUTE;
		state.observed_at = finished_at;
		if (finished_at > state.clock_ceiling)
			state.clock_ceiling = finished_at;
	};

	function apply_timeline(record) {
		let stages = timeline(record);
		if (stages.attempt == null)
			return stages;
		state.last_attempt = stages.attempt;
		state.last_download = stages.download ?? null;
		state.last_validation = stages.validation ?? null;
		state.last_activation = stages.activation ?? null;
		// Current subscription operations finish with `complete` after the
		// service reload and readiness postcheck. Older journals used `reload`
		// as their terminal success stage, so accept both representations.
		state.last_reload = stages.complete ?? stages.reload ?? null;
		for (let name in [ 'attempt', 'download', 'validation', 'activation', 'reload' ])
			if (stages[name] != null && stages[name] > state.clock_ceiling)
				state.clock_ceiling = stages[name];
		return stages;
	};

	function finish(record) {
		let stages = apply_timeline(record);
		let finished = record?.finished_at;
		if (!timestamp(finished) || finished == null)
			corrupt();
		state.pending_operation_id = null;
		if (finished > state.clock_ceiling)
			state.clock_ceiling = finished;
		if (record.state == 'success') {
			if (stages.attempt == null || stages.download == null ||
			    stages.validation == null || stages.activation == null ||
			    (stages.reload == null && stages.complete == null) ||
			    (record.stage != 'reload' && record.stage != 'complete') ||
			    type(record.result) != 'object' ||
			    (record.result.interval_hours != null &&
			     !interval(record.result.interval_hours)))
				corrupt();
			let configured = settings_state();
			let hours = record.result.interval_hours ?? configured.hours;
			if (!interval(hours)) {
				mark_failure('INTERNAL', finished);
				return;
			}
			state.interval_hours = hours;
			state.last_success = finished;
			state.failure_count = 0;
			state.last_failure_code = null;
			state.next_attempt = finished + hours * HOUR;
			state.observed_at = finished;
			return;
		}
		let code = record?.error?.code ??
			(record.state == 'interrupted' ? 'INTERRUPTED' : 'INTERNAL');
		mark_failure(code, finished);
	};

	function operation_event(record) {
		if (record?.kind != 'subscription.update')
			return;
		if (record.source != 'auto') {
			if (record.state != 'success' || state.pending_operation_id != null)
				return;
			finish(record);
			persist();
			schedule_timer();
			return;
		}
		if (state.pending_operation_id == null ||
		    record.id != state.pending_operation_id)
			return;
		apply_timeline(record);
		let at = record.updated_at;
		if (!timestamp(at) || at == null)
			corrupt();
		if (record.state == 'success' || record.state == 'failure' ||
		    record.state == 'interrupted')
			finish(record);
		state.observed_at = at;
		if (at > state.clock_ceiling)
			state.clock_ceiling = at;
		persist();
		schedule_timer();
	};

	function attach() {
		if (unsubscribe == null)
			unsubscribe = app.operations.subscribe(operation_event);
	};

	function recover_pending(recovered_at) {
		if (state.pending_operation_id == null)
			return;
		if (!timestamp(recovered_at) || recovered_at == null)
			recovered_at = runtime.clock.now();
		let record = null;
		try { record = app.operations.get(state.pending_operation_id); }
		catch (error) {}
		if (record != null && (!timestamp(record.created_at) || record.created_at == null ||
		    record.created_at > state.clock_ceiling ||
		    state.next_attempt < record.created_at))
			corrupt();
		if (record?.kind == 'subscription.update' && record.source == 'auto' &&
		    (record.state == 'queued' || record.state == 'running')) {
			apply_timeline(record);
			persist();
			return;
		}
		if (record?.kind == 'subscription.update' && record.source == 'auto' &&
		    (record.state == 'success' || record.state == 'failure' ||
		     record.state == 'interrupted'))
			finish(record);
		else
			mark_failure('INTERRUPTED', recovered_at);
		persist();
	};

	attach();
	recover_pending(now);

	api.start = (...args) => {
		if (length(args)) invalid();
		if (started)
			return false;
		started = true;
		attach();
		recover_pending(runtime.clock.now());
		schedule_timer();
		return true;
	};
	api.stop = (...args) => {
		if (length(args)) invalid();
		if (!started && timer == null && unsubscribe == null)
			return false;
		started = false;
		if (timer != null) {
			timer.cancel();
			timer = null;
		}
		if (unsubscribe != null) {
			unsubscribe();
			unsubscribe = null;
		}
		return true;
	};
	api.tick = (...args) => {
		if (length(args)) invalid();
		let current = observe_clock();
		recover_pending(current);
		let configured = settings_state();
		if (state.pending_operation_id != null) {
			persist();
			schedule_timer();
			return api.status();
		}
		if (!configured.enabled) {
			state.next_attempt = null;
			persist();
			schedule_timer();
			return api.status();
		}
		if (state.next_attempt == null) {
			state.next_attempt = current + configured.hours * HOUR;
			persist();
			schedule_timer();
			return api.status();
		}
		if (state.next_attempt > current) {
			persist();
			schedule_timer();
			return api.status();
		}
		if (length(app.operations.list({ state: 'running' })) > 0 ||
		    length(app.operations.list({ state: 'queued' })) > 0) {
			state.next_attempt = current + MINUTE;
			persist();
			schedule_timer();
			return api.status();
		}
		let before = clone(state), hooked = false;
		try {
			let record = app.subscription.update_scheduled(
				{ profile: 'config.yaml', url: null }, 'auto', (queued) => {
					let id = operation_id(queued?.id);
					if (id == null || queued.state != 'queued' ||
					    queued.kind != 'subscription.update' || queued.source != 'auto')
						corrupt();
					state.pending_operation_id = id;
					state.next_attempt = current + MINUTE;
					state.observed_at = current;
					try { persist(); }
					catch (error) {
						state = before;
						errors.fail(errors.normalize(error).code);
					}
					hooked = true;
				});
			if (!hooked) {
				state = before;
				mark_failure(record?.error?.code ?? 'INTERNAL', current);
				persist();
			}
		}
		catch (error) {
			state = before;
			mark_failure(errors.normalize(error).code, current);
			persist();
		}
		schedule_timer();
		return api.status();
	};
	api.status = (...args) => {
		if (length(args)) invalid();
		let configured = settings_state();
		return {
			running: started,
			enabled: configured.enabled,
			reason: configured.reason,
			last_attempt: state.last_attempt,
			last_download: state.last_download,
			last_validation: state.last_validation,
			last_activation: state.last_activation,
			last_reload: state.last_reload,
			last_success: state.last_success,
			next_attempt: state.next_attempt,
			failure_count: state.failure_count,
			last_failure_code: state.last_failure_code,
			interval_hours: state.interval_hours,
			pending_operation_id: state.pending_operation_id
		};
	};
	api.run_now = (...args) => {
		if (length(args)) invalid();
		let current = observe_clock();
		state.next_attempt = current;
		persist();
		schedule_timer();
		return api.status();
	};

	return api;
};
