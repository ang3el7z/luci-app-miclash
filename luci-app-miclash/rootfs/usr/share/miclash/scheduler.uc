import * as errors from 'miclash.errors';
import * as schema from 'miclash.schema';
import * as storage from 'miclash.storage';

const STATE_PATH = '/opt/clash/subscription-scheduler.json';
const MINUTE = 60 * 1000;
const HOUR = 60 * MINUTE;
const MAX_INTERVAL_HOURS = 8760;
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
	observed_at: true
};

function invalid() {
	errors.fail('INVALID_ARGUMENT');
};

function clone(value) {
	try { return json(sprintf('%J', value)); }
	catch (error) { errors.fail('INTERNAL'); }
};

function timestamp(value) {
	return value == null || (type(value) == 'int' && value >= 0);
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
	if (value == null)
		return null;
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
		observed_at: now
	};
};

function validate_state(value) {
	if (type(value) != 'object')
		errors.fail('CORRUPT_STATE');
	let fields = 0;
	for (let name in value) {
		if (!exists(STATE_FIELDS, name))
			errors.fail('CORRUPT_STATE');
		fields++;
	}
	if (fields != 13 || value.version != 1 ||
	    !timestamp(value.last_attempt) || !timestamp(value.last_download) ||
	    !timestamp(value.last_validation) || !timestamp(value.last_activation) ||
	    !timestamp(value.last_reload) || !timestamp(value.last_success) ||
	    !timestamp(value.next_attempt) || !timestamp(value.observed_at) ||
	    type(value.failure_count) != 'int' || value.failure_count < 0 ||
	    value.failure_count > 1000000 ||
	    (value.last_failure_code != null &&
	     !known_error_code(value.last_failure_code)) ||
	    (value.interval_hours != null && !interval(value.interval_hours)))
		errors.fail('CORRUPT_STATE');
	try { operation_id(value.pending_operation_id); }
	catch (error) { errors.fail('CORRUPT_STATE'); }
	return value;
};

function retry_minutes(failure_count) {
	if (failure_count <= 1)
		return 5;
	if (failure_count == 2)
		return 15;
	return 60;
};

export function create(app) {
	if (type(app?.runtime?.fs) != 'object' ||
	    type(app?.runtime?.clock?.now) != 'function' ||
	    type(app?.runtime?.clock?.set_timeout) != 'function' ||
	    type(app?.runtime?.digest?.sha256) != 'function' ||
	    type(app?.runtime?.digest?.sha256_file) != 'function' ||
	    type(app?.operations?.submit) != 'function' ||
	    type(app?.operations?.get) != 'function' ||
	    type(app?.operations?.list) != 'function' ||
	    type(app?.operations?.subscribe) != 'function' ||
	    type(app?.settings?.get) != 'function' ||
	    type(app?.subscription?.update) != 'function' ||
	    type(app?.subscription?.consume_scheduler_outcome) != 'function')
		invalid();

	let runtime = app.runtime;
	let now = runtime.clock.now();
	if (type(now) != 'int' || now < 0)
		errors.fail('INTERNAL');
	let state;
	try { state = validate_state(storage.read_json(runtime, STATE_PATH)); }
	catch (error) {
		if (errors.normalize(error).code != 'NOT_FOUND')
			errors.fail(errors.normalize(error).code);
		state = initial_state(now);
	}

	let started = false;
	let timer = null;
	let unsubscribe = null;

	function persist() {
		validate_state(state);
		storage.write_json(runtime, STATE_PATH, state, 0o600);
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
		if (type(current) != 'int' || current < 0)
			errors.fail('INTERNAL');
		if (state.observed_at != null && current < state.observed_at) {
			if (state.next_attempt != null) {
				let remaining = state.next_attempt - state.observed_at;
				if (remaining < MINUTE)
					remaining = MINUTE;
				state.next_attempt = current + remaining;
			}
		}
		state.observed_at = current;
		return current;
	};

	function schedule_timer() {
		if (!started)
			return;
		if (timer != null)
			timer.cancel();
		let current = runtime.clock.now();
		let delay = MINUTE;
		if (state.next_attempt == null) {
			let configured = settings_state();
			if (configured.enabled && state.pending_operation_id == null)
				delay = 0;
		}
		else if (state.next_attempt <= current)
			delay = 0;
		else if (state.next_attempt - current < delay)
			delay = state.next_attempt - current;
		timer = runtime.clock.set_timeout(delay, () => {
			timer = null;
			api.tick();
		});
	};

	function mark_failure(code, finished_at) {
		code = safe_error_code(code);
		state.failure_count++;
		if (state.failure_count > 1000000)
			state.failure_count = 1000000;
		state.last_failure_code = code;
		state.pending_operation_id = null;
		state.next_attempt = finished_at + retry_minutes(state.failure_count) * MINUTE;
		state.observed_at = finished_at;
	};

	function outcome_for(id) {
		try { return app.subscription.consume_scheduler_outcome(id); }
		catch (error) { return null; }
	};

	function finish(record) {
		let finished = record?.finished_at;
		if (!timestamp(finished) || finished == null)
			finished = observe_clock();
		let outcome = outcome_for(record.id);
		state.pending_operation_id = null;
		if (record.state == 'success') {
			let trusted = outcome == null ? record.stage == 'reload' :
				outcome.downloaded === true && outcome.validated === true &&
				outcome.activated === true && outcome.reload_ok === true;
			if (!trusted) {
				mark_failure('INTERNAL', finished);
				return;
			}
			let configured = settings_state();
			let hours = interval(outcome?.interval_hours) ? outcome.interval_hours :
				(configured.hours ?? state.interval_hours);
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
		if (code == 'VALIDATION_FAILED' && state.last_validation == null)
			state.last_validation = finished;
		if (code == 'HEALTH_FAILED') {
			if (state.last_activation == null)
				state.last_activation = finished;
			state.last_reload = finished;
		}
		mark_failure(code, finished);
	};

	function operation_event(record) {
		if (state.pending_operation_id == null ||
		    record?.id != state.pending_operation_id ||
		    record.kind != 'subscription.update' || record.source != 'auto')
			return;
		let at = record.updated_at;
		if (!timestamp(at) || at == null)
			return;
		if (record.stage == 'attempt') state.last_attempt = at;
		else if (record.stage == 'download') state.last_download = at;
		else if (record.stage == 'validation') state.last_validation = at;
		else if (record.stage == 'activation') state.last_activation = at;
		else if (record.stage == 'reload') state.last_reload = at;
		if (record.state == 'success' || record.state == 'failure' ||
		    record.state == 'interrupted')
			finish(record);
		state.observed_at = at;
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
		if (record?.kind == 'subscription.update' && record.source == 'auto' &&
		    (record.state == 'queued' || record.state == 'running'))
			return;
		if (record?.kind == 'subscription.update' && record.source == 'auto' &&
		    (record.state == 'success' || record.state == 'failure' ||
		     record.state == 'interrupted'))
			finish(record);
		else {
			outcome_for(state.pending_operation_id);
			mark_failure('INTERRUPTED', recovered_at);
		}
		persist();
	};

	attach();
	recover_pending(now);

	let api = {};
	api.start = () => {
		if (started)
			return false;
		started = true;
		attach();
		recover_pending(runtime.clock.now());
		schedule_timer();
		return true;
	};
	api.stop = () => {
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
	api.tick = () => {
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
		if (state.next_attempt == null)
			state.next_attempt = current;
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
		let record;
		try {
			record = app.subscription.update({ profile: 'config.yaml', url: null }, 'auto');
			state.pending_operation_id = operation_id(record?.id);
			if (state.pending_operation_id == null)
				errors.fail('INTERNAL');
			state.last_attempt = current;
			state.next_attempt = current + MINUTE;
		}
		catch (error) {
			mark_failure(errors.normalize(error).code, current);
		}
		persist();
		schedule_timer();
		return api.status();
	};
	api.status = () => {
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
	api.run_now = () => {
		let current = observe_clock();
		state.next_attempt = current;
		persist();
		schedule_timer();
		return api.status();
	};

	return api;
};
