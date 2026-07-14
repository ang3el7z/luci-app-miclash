import { fail } from 'miclash.errors';
import * as errors from 'miclash.errors';
import * as health from 'miclash.health';

const COMPONENTS = [ 'guard', 'firewall', 'routing', 'dns', 'mihomo', 'scheduler', 'telegram' ];
const BACKOFF = [ 60000, 300000, 900000, 1800000, 3600000 ];
const CIRCUITS = { closed: true, open: true, half_open: true };
const RESULTS = { success: true, failure: true, fallback: true, interrupted: true };

function clone(value) {
	try { return json(sprintf('%J', value)); }
	catch (error) { fail('INTERNAL'); }
};

function component_index(component) {
	let position = index(COMPONENTS, component);
	if (position < 0)
		fail('INVALID_ARGUMENT');
	return position;
};

function validate(app) {
	if (type(app?.clock?.now) != 'function' || type(app?.clock?.set_timeout) != 'function' ||
	    type(app?.operations?.submit) != 'function' || type(app?.store?.read) != 'function' ||
	    type(app?.store?.write) != 'function' || type(app?.events?.emit) != 'function' ||
	    type(app?.guard?.is_on) != 'function' ||
	    type(app?.fallback?.restore_direct) != 'function' ||
	    type(app?.fallback?.observe_direct) != 'function' ||
	    type(app?.mihomo?.reload) != 'function' ||
	    type(app?.mihomo?.restart_core) != 'function' ||
	    type(app?.mihomo?.restart_service) != 'function' ||
	    type(app?.repairs) != 'object' || type(app?.observers) != 'object')
		fail('INVALID_ARGUMENT');
	for (let component in COMPONENTS) {
		if (type(app.observers[component]) != 'function')
			fail('INVALID_ARGUMENT');
		if (component != 'mihomo' && type(app.repairs[component]) != 'function')
			fail('INVALID_ARGUMENT');
	}
};

function default_state() {
	return {
		version: 1,
		circuit: 'closed',
		failure_count: 0,
		next_retry: null,
		failure_id: null,
		inflight: false,
		last_result: null
	};
};

function valid_state(value) {
	return type(value) == 'object' && value.version === 1 && CIRCUITS[value.circuit] &&
		type(value.failure_count) == 'int' && value.failure_count >= 0 &&
		(value.next_retry == null || (type(value.next_retry) == 'int' && value.next_retry >= 0)) &&
		(value.failure_id == null || (type(value.failure_id) == 'string' &&
		 length(value.failure_id) > 0 && length(value.failure_id) <= 128 &&
		 match(value.failure_id, /^[A-Za-z0-9._-]+$/))) &&
		type(value.inflight) == 'bool' &&
		(value.last_result == null || RESULTS[value.last_result]);
};

function delay_for(failure_count) {
	let position = failure_count - 1;
	if (position < 0) position = 0;
	if (position >= length(BACKOFF)) position = length(BACKOFF) - 1;
	return BACKOFF[position];
};

function all_ok(graph) {
	if (type(graph) != 'object' || !length(keys(graph)))
		return false;
	for (let name, record in graph)
		if (record?.state != 'ok')
			return false;
	return true;
};

function first_unhealthy(graph) {
	for (let component in COMPONENTS)
		if (graph?.[component]?.state != 'ok')
			return component;
	return null;
};

export function create(app) {
	validate(app);
	let loaded;
	try { loaded = app.store.read(); }
	catch (error) { fail('INTERNAL'); }
	let state = loaded == null ? default_state() : clone(loaded);
	if (!valid_state(state))
		fail('CORRUPT_STATE');
	let pending = false;
	let active = false;
	let timer = null;
	let failure_sequence = 0;
	let run;

	function persist() {
		if (app.store.write(clone(state)) !== true)
			fail('INTERNAL');
	};

	function emit(type, data) {
		try { app.events.emit(type, clone(data)); }
		catch (error) {}
	};

	function cancel_timer() {
		if (timer != null) {
			try { timer.cancel(); } catch (error) {}
			timer = null;
		}
	};

	function schedule_at(when) {
		cancel_timer();
		state.next_retry = when;
		state.circuit = 'open';
		persist();
		let delay = max(0, when - app.clock.now());
		timer = app.clock.set_timeout(delay, () => {
			timer = null;
			state.next_retry = null;
			persist();
			try { run('scheduled'); }
			catch (error) {
				state.failure_count++;
				state.last_result = 'failure';
				schedule_at(app.clock.now() + delay_for(state.failure_count));
			}
		});
	};

	function failure_identity() {
		failure_sequence++;
		return sprintf('failure-%d-%d', app.clock.now(), failure_sequence);
	};

	function record_failure(component, reason) {
		if (state.failure_id == null) {
			state.failure_id = failure_identity();
			emit('failure', { failure_id: state.failure_id, component, reason });
		}
	};

	function finish_success(component, reason, observations, changed) {
		let prior = state.failure_id;
		cancel_timer();
		state.circuit = 'closed';
		state.failure_count = 0;
		state.next_retry = null;
		state.inflight = false;
		state.last_result = 'success';
		state.failure_id = null;
		persist();
		if (changed)
			emit('self_heal', { component, reason });
		if (prior != null)
			emit('recovery', { failure_id: prior, component, reason });
		return { ok: true, component, observations };
	};

	function finish_failure(component, reason, observations, fallback) {
		state.inflight = false;
		state.last_result = fallback ? 'fallback' : 'failure';
		state.failure_count++;
		let retry_at = app.clock.now() + delay_for(state.failure_count);
		schedule_at(retry_at);
		return {
			ok: false,
			component,
			observations,
			fallback: fallback === true,
			failure_id: state.failure_id,
			next_retry: retry_at
		};
	};

	function generic_repair(component) {
		try { app.repairs[component](); }
		catch (error) {}
		return health.observe_from(app, component);
	};

	function mihomo_repair() {
		let observations = null;
		for (let stage in [ 'reload', 'restart_core', 'restart_service' ]) {
			try { app.mihomo[stage](); }
			catch (error) {}
			observations = health.observe_from(app, 'mihomo');
			if (all_ok(observations))
				return { ok: true, observations };
		}
		return { ok: false, observations };
	};

	function attempt(reason, requested_component) {
		state.circuit = 'half_open';
		state.next_retry = null;
		state.inflight = true;
		persist();
		let graph = health.observe_all(app);
		let component = requested_component ?? first_unhealthy(graph);
		if (component == null)
			return finish_success(null, reason, graph, false);
		component_index(component);
		if (graph[component]?.state == 'ok')
			return finish_success(component, reason, graph, false);

		record_failure(component, reason);
		if (component != 'mihomo') {
			let observations = generic_repair(component);
			if (all_ok(observations))
				return finish_success(component, reason, observations, true);
			return finish_failure(component, reason, observations, false);
		}

		let recovery = mihomo_repair();
		if (recovery.ok)
			return finish_success(component, reason, recovery.observations, true);

		let guard_on = true;
		try { guard_on = app.guard.is_on() !== false; }
		catch (error) { guard_on = true; }
		if (guard_on) {
			emit('fail_closed', { failure_id: state.failure_id, component, reason });
			return finish_failure(component, reason, recovery.observations, false);
		}

		let fallback = false;
		try {
			app.fallback.restore_direct();
			fallback = app.fallback.observe_direct() === true;
		}
		catch (error) { fallback = false; }
		if (fallback)
			emit('direct_fallback', { failure_id: state.failure_id, component, reason });
		return finish_failure(component, reason, recovery.observations, fallback);
	};

	function submit(kind, reason, component) {
		if (pending || active)
			fail('BUSY');
		pending = true;
		let operation;
		try {
			operation = app.operations.submit(kind, 'auto', {
				reason,
				component: component ?? null
			}, (ctx) => {
				active = true;
				let result;
				try { result = attempt(reason, component); }
				catch (error) {
					active = false;
					pending = false;
					fail(errors.normalize(error).code);
				}
				active = false;
				pending = false;
				return result;
			});
		}
		catch (error) {
			pending = false;
			fail(errors.normalize(error).code);
		}
		return operation;
	};

	run = (reason) => {
		if (type(reason) != 'string' || !length(reason) || length(reason) > 64 ||
		    !match(reason, /^[A-Za-z0-9._-]+$/))
			fail('INVALID_ARGUMENT');
		return submit('reconcile.run', reason, null);
	};

	let reconciler = {};
	reconciler.run = run;
	reconciler.repair = (component) => {
		component_index(component);
		return submit('reconcile.repair.' + component, 'targeted', component);
	};
	reconciler.circuit_status = () => clone({
		circuit: state.circuit,
		failure_count: state.failure_count,
		next_retry: state.next_retry,
		failure_id: state.failure_id,
		last_result: state.last_result,
		active,
		pending
	});
	reconciler.request_manual = () => {
		if (pending || active)
			return { accepted: false, code: 'BUSY' };
		cancel_timer();
		state.next_retry = null;
		persist();
		return { accepted: true, operation: run('manual') };
	};

	if (state.inflight) {
		state.inflight = false;
		state.last_result = 'interrupted';
		state.circuit = 'open';
		state.failure_count++;
		state.next_retry = app.clock.now() + delay_for(state.failure_count);
		persist();
	}
	if (state.next_retry != null)
		schedule_at(state.next_retry);

	return reconciler;
};
