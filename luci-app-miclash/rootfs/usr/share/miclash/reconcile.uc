import { fail } from 'miclash.errors';
import * as errors from 'miclash.errors';
import * as health from 'miclash.health';

const COMPONENTS = [ 'guard', 'firewall', 'routing', 'dns', 'mihomo', 'scheduler', 'telegram' ];
const BACKOFF = [ 60000, 300000, 900000, 1800000, 3600000 ];
const STATE_FIELDS = {
	version: true, circuit: true, phase: true, failure_count: true,
	next_retry: true, failure_id: true, failure_sequence: true, last_result: true
};
const LAST_RESULTS = { success: true, failure: true, fallback: true, interrupted: true };

function clone(value) {
	try { return json(sprintf('%J', value)); }
	catch (error) { fail('INTERNAL'); }
};

function index_of(component) {
	let position = index(COMPONENTS, component);
	if (position < 0)
		fail('INVALID_ARGUMENT');
	return position;
};

function exact_fields(value, allowed, count) {
	if (type(value) != 'object' || length(keys(value)) != count)
		return false;
	for (let name in value)
		if (!allowed[name])
			return false;
	return true;
};

function safe_failure_id(value) {
	return type(value) == 'string' && length(value) > 0 && length(value) <= 128 &&
		match(value, /^failure-[0-9]+-[0-9]+$/);
};

function failure_id_sequence(value) {
	if (!safe_failure_id(value))
		return null;
	return int(split(value, '-')[1]);
};

function valid_state(value) {
	if (!exact_fields(value, STATE_FIELDS, 8) || value.version !== 1 ||
	    type(value.failure_count) != 'int' || value.failure_count < 0 ||
	    type(value.failure_sequence) != 'int' || value.failure_sequence < 0 ||
	    (value.failure_id != null && !safe_failure_id(value.failure_id)) ||
	    (value.failure_id != null && failure_id_sequence(value.failure_id) != value.failure_sequence) ||
	    (value.next_retry != null && (type(value.next_retry) != 'int' || value.next_retry < 0)) ||
	    (value.last_result != null && !LAST_RESULTS[value.last_result]))
		return false;

	if (value.phase == 'idle' && value.circuit == 'closed')
		return value.failure_count == 0 && value.next_retry == null &&
			value.failure_id == null && (value.last_result == 'success' ||
			 (value.last_result == null && value.failure_sequence == 0));
	if ((value.phase == 'idle' || value.phase == 'queued') && value.circuit == 'open')
		return value.failure_count > 0 && type(value.next_retry) == 'int' &&
			safe_failure_id(value.failure_id) &&
			(value.last_result == 'failure' || value.last_result == 'fallback' ||
			 value.last_result == 'interrupted');
	if (value.phase == 'queued' && value.circuit == 'half_open')
		return value.failure_count == 0 && value.next_retry == null && value.failure_id == null &&
			(value.last_result == 'success' ||
			 (value.last_result == null && value.failure_sequence == 0));
	if (value.phase == 'inflight' && value.circuit == 'half_open')
		return value.next_retry == null &&
			((value.failure_count == 0 &&
			  (value.last_result == 'success' ||
			   (value.last_result == null && value.failure_sequence == 0) ||
			   (safe_failure_id(value.failure_id) && value.last_result == null))) ||
			 (value.failure_count > 0 && safe_failure_id(value.failure_id) &&
			  (value.last_result == 'failure' || value.last_result == 'fallback' ||
			   value.last_result == 'interrupted')));
	return false;
};

function initial_state() {
	return {
		version: 1, circuit: 'closed', phase: 'idle', failure_count: 0,
		next_retry: null, failure_id: null, failure_sequence: 0, last_result: null
	};
};

function retry_delay(count) {
	let position = min(max(count - 1, 0), length(BACKOFF) - 1);
	return BACKOFF[position];
};

function validate_app(app) {
	if (type(app?.clock?.now) != 'function' || type(app?.clock?.set_timeout) != 'function' ||
	    type(app?.operations?.submit) != 'function' || type(app?.store?.read) != 'function' ||
	    type(app?.store?.write) != 'function' || type(app?.events?.emit) != 'function' ||
	    type(app?.guard?.is_on) != 'function' ||
	    type(app?.fallback?.restore_direct) != 'function' ||
	    type(app?.fallback?.observe_direct) != 'function' ||
	    type(app?.mihomo) != 'object' || type(app?.repairs) != 'object' ||
	    type(app?.observers) != 'object')
		fail('INVALID_ARGUMENT');
	for (let component in COMPONENTS) {
		if (type(app.observers[component]) != 'function')
			fail('INVALID_ARGUMENT');
		if (component != 'mihomo' && type(app.repairs[component]) != 'function')
			fail('INVALID_ARGUMENT');
	}
	for (let stage in [ 'reload', 'restart_core', 'restart_service' ])
		if (type(app.mihomo[stage]) != 'function')
			fail('INVALID_ARGUMENT');
};

function first_unhealthy(graph, first, last) {
	for (let i = first; i <= (last ?? length(COMPONENTS) - 1); i++)
		if (graph?.[COMPONENTS[i]]?.state != 'ok')
			return COMPONENTS[i];
	return null;
};

function safe_resource(value) {
	return type(value) == 'string' && length(value) > 0 && length(value) <= 128 &&
		match(value, /^[A-Za-z0-9][A-Za-z0-9._:/-]*$/);
};

function action_result(value) {
	if (!exact_fields(value, { changed: true, observe: true }, 2) ||
	    type(value.changed) != 'array' || length(value.changed) > 64 ||
	    type(value.observe) != 'function')
		return null;
	let changed = [];
	for (let resource in value.changed) {
		if (!safe_resource(resource))
			return null;
		push(changed, resource);
	}
	return { changed: clone(changed), observe: value.observe };
};

export function create(app) {
	validate_app(app);
	let loaded;
	try { loaded = app.store.read(); }
	catch (error) { fail('INTERNAL'); }
	let state = loaded == null ? initial_state() : clone(loaded);
	if (!valid_state(state))
		fail('CORRUPT_STATE');

	let pending = false, active = false;
	let timer = null, stale_timers = [], timer_generation = 0;
	let run_internal;

	function persist() {
		if (!valid_state(state) || app.store.write(clone(state)) !== true)
			fail('INTERNAL');
	};

	function emit(type, data) {
		try { app.events.emit(type, clone(data)); }
		catch (error) {}
	};

	function invalidate_timer() {
		timer_generation++;
		if (timer == null)
			return;
		let previous = timer;
		try {
			if (previous.cancel() !== true)
				push(stale_timers, previous);
		}
		catch (error) { push(stale_timers, previous); }
		timer = null;
	};

	function arm_retry(deadline) {
		invalidate_timer();
		let token = timer_generation;
		let delay = max(0, deadline - app.clock.now());
		timer = app.clock.set_timeout(delay, () => {
			if (token != timer_generation || state.phase != 'idle' ||
			    state.circuit != 'open' || state.next_retry != deadline ||
			    app.clock.now() < deadline)
				return;
			timer = null;
			run_internal('scheduled', null, 'scheduled', deadline, token);
		});
	};

	function assign_failure() {
		if (state.failure_id != null)
			return false;
		state.failure_sequence++;
		state.failure_id = sprintf('failure-%d-%d', state.failure_sequence, app.clock.now());
		return true;
	};

	function ensure_failure(component, reason) {
		let assigned = assign_failure();
		if (!assigned)
			return state.failure_id;
		persist();
		emit('failure', { failure_id: state.failure_id, component, reason });
		return state.failure_id;
	};

	function transition_failure(component, reason, result) {
		let assigned = assign_failure();
		state.phase = 'idle';
		state.circuit = 'open';
		state.failure_count++;
		state.last_result = result ?? 'failure';
		state.next_retry = app.clock.now() + retry_delay(state.failure_count);
		persist();
		if (assigned)
			emit('failure', { failure_id: state.failure_id, component: component ?? 'unknown', reason });
		arm_retry(state.next_retry);
		return false;
	};

	function transition_success(component, reason, observations, changed) {
		let prior = state.failure_id;
		invalidate_timer();
		state.phase = 'idle';
		state.circuit = 'closed';
		state.failure_count = 0;
		state.next_retry = null;
		state.failure_id = null;
		state.last_result = 'success';
		persist();
		if (changed)
			emit('self_heal', { component, reason });
		if (prior != null)
			emit('recovery', { failure_id: prior, component, reason });
		return true;
	};

	function perform_action(component, name, adapter) {
		let event = { failure_id: state.failure_id, component, action: name };
		if (component == 'mihomo')
			event.stage = name;
		emit('action_attempt', { ...event, changed: [] });
		let result = null, observations;
		try { result = action_result(adapter()); }
		catch (error) { result = null; }
		if (result != null)
			observations = health.observe_from(app, component, result.observe);
		else
			observations = health.observe_from(app, component);
		let outcome = result != null && observations[component]?.state == 'ok' ? 'ok' : 'failed';
		emit('action_outcome', {
			...event, outcome,
			changed: result?.changed ?? []
		});
		return { valid: result != null, changed: result?.changed ?? [], observations };
	};

	function repair_generic(component, reason) {
		let repaired = perform_action(component, 'repair', app.repairs[component]);
		let failed_component = first_unhealthy(repaired.observations, index_of(component));
		if (repaired.valid && failed_component == null)
			return transition_success(component, reason, repaired.observations, true);
		return transition_failure(failed_component ?? component, reason, 'failure');
	};

	function repair_mihomo(reason) {
		let observations = null;
		for (let stage in [ 'reload', 'restart_core', 'restart_service' ]) {
			let repaired = perform_action('mihomo', stage, app.mihomo[stage]);
			observations = repaired.observations;
			if (observations.mihomo?.state == 'ok') {
				let dependent = first_unhealthy(observations, index_of('mihomo') + 1);
				if (dependent != null)
					return repair_generic(dependent, reason);
				return transition_success('mihomo', reason, observations, true);
			}
		}

		let guard_on = true;
		try { guard_on = app.guard.is_on() !== false; }
		catch (error) { guard_on = true; }
		if (guard_on) {
			emit('fail_closed', { failure_id: state.failure_id, component: 'mihomo', reason });
			return transition_failure('mihomo', reason, 'failure');
		}

		let fallback = false;
		try {
			app.fallback.restore_direct();
			fallback = app.fallback.observe_direct() === true;
		}
		catch (error) { fallback = false; }
		if (fallback)
			emit('direct_fallback', { failure_id: state.failure_id, component: 'mihomo', reason });
		return transition_failure('mihomo', reason, fallback ? 'fallback' : 'failure');
	};

	function attempt(reason, requested) {
		let graph = health.observe_all(app);
		let component;
		if (requested != null) {
			let requested_index = index_of(requested);
			let prerequisite = requested_index > 0 ? first_unhealthy(graph, 0, requested_index - 1) : null;
			if (prerequisite != null) {
				ensure_failure(prerequisite, reason);
				return transition_failure(prerequisite, reason, 'failure');
			}
			component = first_unhealthy(graph, requested_index);
		}
		else
			component = first_unhealthy(graph, 0);
		if (component == null)
			return transition_success(requested, reason, graph, false);

		ensure_failure(component, reason);
		return component == 'mihomo' ? repair_mihomo(reason) : repair_generic(component, reason);
	};

	function complete_failure(ctx) {
		try { ctx.complete(errors.new('HEALTH_FAILED', 'HEALTH_FAILED', null)); }
		catch (error) {}
		return false;
	};

	function submit_attempt(reason, component, mode, expected_deadline, expected_token) {
		if (pending || active || state.phase != 'idle')
			fail('BUSY');
		if (mode == 'automatic' && state.circuit == 'open')
			fail('BUSY');
		if (mode == 'scheduled' &&
		    (state.circuit != 'open' || state.next_retry != expected_deadline ||
		     expected_token != timer_generation || app.clock.now() < expected_deadline))
			fail('BUSY');

		let before = clone(state);
		state.phase = 'queued';
		if (state.circuit == 'closed')
			state.circuit = 'half_open';
		try { persist(); }
		catch (error) {
			state = before;
			fail('INTERNAL');
		}
		invalidate_timer();
		pending = true;
		let operation;
		try {
			operation = app.operations.submit(
				component == null ? 'reconcile.run' : 'reconcile.repair.' + component,
				'auto', { reason, component: component ?? null }, (ctx) => {
					pending = false;
					active = true;
					state.phase = 'inflight';
					state.circuit = 'half_open';
					state.next_retry = null;
					try { persist(); }
					catch (error) {
						active = false;
						transition_failure(component, reason, 'failure');
						return complete_failure(ctx);
					}
					let success = false;
					try { success = attempt(reason, component); }
					catch (error) {
						if (state.phase != 'idle')
							transition_failure(component, reason, 'failure');
						success = false;
					}
					active = false;
					return success ? true : complete_failure(ctx);
				});
		}
		catch (error) {
			pending = false;
			if (state.phase == 'queued')
				transition_failure(component, reason, 'failure');
			fail(errors.normalize(error).code);
		}
		return operation;
	};

	run_internal = (reason, component, mode, deadline, token) =>
		submit_attempt(reason, component, mode, deadline, token);

	let reconciler = {};
	reconciler.run = (reason) => {
		if (type(reason) != 'string' || !length(reason) || length(reason) > 64 ||
		    !match(reason, /^[A-Za-z0-9._-]+$/))
			fail('INVALID_ARGUMENT');
		return run_internal(reason, null, 'automatic', null, null);
	};
	reconciler.repair = (component) => {
		index_of(component);
		return run_internal('targeted', component, 'automatic', null, null);
	};
	reconciler.request_manual = () => {
		if (pending || active || state.phase != 'idle')
			return { accepted: false, code: 'BUSY' };
		return { accepted: true, operation: run_internal('manual', null, 'manual', null, null) };
	};
	reconciler.circuit_status = () => clone({
		circuit: state.circuit, phase: state.phase, failure_count: state.failure_count,
		next_retry: state.next_retry, failure_id: state.failure_id,
		failure_sequence: state.failure_sequence, last_result: state.last_result,
		active, pending
	});

	if (state.phase == 'queued' || state.phase == 'inflight')
		transition_failure(null, 'restart', 'interrupted');
	else if (state.circuit == 'open')
		arm_retry(state.next_retry);

	return reconciler;
};
