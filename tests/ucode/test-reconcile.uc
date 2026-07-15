import { assert_equal, assert_throws, assert_true } from './testlib.uc';
import * as health from 'miclash.health';
import * as reconcile from 'miclash.reconcile';
import * as fakes from './fakes.uc';

const COMPONENTS = [ 'guard', 'firewall', 'routing', 'dns', 'mihomo', 'scheduler', 'telegram' ];
let fixture = json(require('fs').readfile('tests/fixtures/reconcile/scenarios.json'));

function clone(value) { return value == null ? null : json(sprintf('%J', value)); };
function ok(code) {
	return { state: 'ok', code: code ?? 'OK', message: 'healthy', details: {} };
};
function failed(code) {
	return { state: 'failed', code: code ?? 'FAILED', message: 'unhealthy', details: {} };
};

// Mirrors operations.uc completion semantics: any worker return other than
// exactly false auto-completes success, while ctx.complete(error) records a
// durable operation failure.
function production_operations(options) {
	options ??= {};
	let manager = {
		calls: [], deferred: [], fail_submit: options.fail_submit === true,
		complete_throws: options.complete_throws ?? 0, ownership_releases: 0
	};
	manager.start = (record) => {
		record.state = 'running';
		let completed = false;
		let ctx = { id: record.id, complete: (error) => {
			if (completed) return false;
			if (manager.complete_throws > 0) {
				manager.complete_throws--;
				die('HEALTH_FAILED');
			}
			completed = true;
			record.state = error == null ? 'success' : 'failure';
			record.error = error == null ? null : clone(error);
			manager.ownership_releases++;
			return true;
		} };
		let returned;
		try { returned = record.worker(ctx); }
		catch (error) {
			if (!completed) ctx.complete({ code: error?.code ?? error?.message ?? 'INTERNAL' });
		}
		if (returned !== false && !completed)
			ctx.complete(null);
		return record;
	};
	manager.submit = (kind, source, context, worker) => {
		if (manager.fail_submit) {
			manager.fail_submit = false;
			die('INTERNAL');
		}
		let record = {
			id: sprintf('op-%d', length(manager.calls) + 1), kind, source,
			state: 'queued', error: null, worker
		};
		push(manager.calls, record);
		if (options.defer) push(manager.deferred, () => manager.start(record));
		else manager.start(record);
		return record;
	};
	manager.drain = () => shift(manager.deferred)();
	return manager;
};

function make_app(options) {
	options ??= {};
	let states = {};
	let order = [];
	let actions = [];
	let events = [];
	let persisted = clone(options.persisted);
	let clock = options.clock ?? fakes.clock(options.now ?? 1000);
	for (let name in COMPONENTS)
		states[name] = clone(options.states?.[name] ?? ok());
	let observers = {};
	function observer(name) {
		return () => {
			push(order, name);
			let queued = options.sequences?.[name];
			if (type(queued) == 'array' && length(queued))
				states[name] = clone(shift(queued));
			return clone(states[name]);
		};
	};
	for (let name in COMPONENTS)
		observers[name] = observer(name);
	let repairs = {};
	function repair(name) {
		return () => {
			push(actions, 'repair:' + name);
			if (options.repair_success?.[name] === true)
				states[name] = ok();
			if (options.repair_results?.[name] != null)
				return options.repair_results[name];
			return {
				changed: options.changed?.[name] ?? [ name ],
				observe: options.repair_observers?.[name] ?? observer(name)
			};
		};
	};
	for (let name in COMPONENTS)
		repairs[name] = repair(name);
	let app = {
		clock,
		operations: options.operations ?? production_operations(),
		observers,
		repairs,
		mihomo: {
			reload: () => {
				push(actions, 'reload');
				if (options.mihomo_throw?.reload) die('secret reload error');
				return { changed: [ 'mihomo-config' ], observe: observer('mihomo') };
			},
			restart_core: () => {
				push(actions, 'restart_core');
				if (options.mihomo_throw?.restart_core) die('secret core error');
				return { changed: [ 'mihomo-core' ], observe: observer('mihomo') };
			},
			restart_service: () => {
				push(actions, 'restart_service');
				if (options.mihomo_throw?.restart_service) die('secret service error');
				return { changed: [ 'mihomo-service' ], observe: observer('mihomo') };
			}
		},
		guard: { is_on: () => options.guard_on === true },
		fallback: {
			restore_direct: () => { push(actions, 'restore_direct'); return { changed: true }; },
			observe_direct: () => { push(actions, 'observe_direct'); return options.direct_ok === true; }
		},
		store: {
			read: () => clone(persisted),
			write: (value) => { persisted = clone(value); return true; }
		},
		events: { emit: (type, data) => {
			if (options.event_failure) die('secret event sink error');
			push(events, { type, data: clone(data) });
		} }
	};
	return { app, states, order, actions, events, clock, persisted: () => clone(persisted) };
};

// Health graph: exact order, one timestamp, exact public shape, detached details.
let graph_env = make_app();
graph_env.app.observers.guard = () => {
	push(graph_env.order, 'guard');
	return { state: 'ok', code: 'GUARD_OK', message: 'ready', observed_at: 1,
		details: { installed: true }, ignored: 'never publish' };
};
let graph = health.observe_all(graph_env.app);
assert_equal(join(',', graph_env.order), join(',', fixture.graph_order));
for (let name in COMPONENTS) {
	assert_equal(join(',', sort(keys(graph[name]))),
		'code,details,message,observed_at,state');
	assert_equal(graph[name].observed_at, 1000);
}
assert_equal(graph.guard.code, 'GUARD_OK');
graph.guard.details.installed = false;
assert_equal(health.observe_all(graph_env.app).guard.details.installed, true);

// Malformed and throwing observers fail conservatively without leaking raw errors.
let unsafe = make_app();
unsafe.app.observers.firewall = () => ({ state: 'victory', code: 'bad code',
	message: 'secret-token', details: { password: 'secret' } });
unsafe.app.observers.routing = () => die('secret-token');
let unsafe_graph = health.observe_all(unsafe.app);
assert_equal(unsafe_graph.firewall.state, 'unknown');
assert_equal(unsafe_graph.firewall.code, 'INVALID_OBSERVATION');
assert_equal(index(sprintf('%J', unsafe_graph.firewall), 'secret'), -1);
assert_equal(unsafe_graph.routing.state, 'unknown');
assert_equal(unsafe_graph.routing.code, 'OBSERVER_FAILED');
assert_equal(index(sprintf('%J', unsafe_graph.routing), 'secret'), -1);
assert_throws(() => health.observe_all({}), 'INVALID_ARGUMENT');

// Targeted repair never rebuilds an upstream layer and rechecks only dependents.
let targeted = make_app({ states: { routing: failed() }, repair_success: { routing: true } });
let targeted_reconciler = reconcile.create(targeted.app);
let targeted_result = targeted_reconciler.repair('routing');
assert_equal(targeted_result.state, 'success');
assert_equal(join(',', targeted.actions), 'repair:routing');
assert_equal(join(',', targeted.order), join(',', [ ...COMPONENTS, ...fixture.downstream.routing ]));
assert_equal(index(join(',', targeted.actions), 'repair:firewall'), -1);

// A repair return is never success proof: the fresh observer controls the result.
let false_success = make_app({ states: { dns: failed() } });
let rejected = reconcile.create(false_success.app).repair('dns');
assert_equal(rejected.state, 'failure');
assert_equal(rejected.error.code, 'HEALTH_FAILED');
assert_equal(join(',', false_success.actions), 'repair:dns');
assert_throws(() => reconcile.create(make_app().app).repair('future'), 'INVALID_ARGUMENT');

// Mihomo ladder stops only after fresh health proof at each exact stage.
for (let stop = 0; stop < 3; stop++) {
	let sequence = [ failed() ];
	for (let i = 0; i <= stop; i++)
		push(sequence, i == stop ? ok() : failed());
	let ladder = make_app({ states: { mihomo: failed() }, sequences: { mihomo: sequence } });
	let result = reconcile.create(ladder.app).run('automatic');
	assert_equal(result.state, 'success');
	assert_equal(join(',', ladder.actions), join(',', slice(fixture.mihomo_ladder, 0, stop + 1)));
	assert_equal(ladder.events[length(ladder.events) - 1].type, 'recovery');
}
let total = make_app({ states: { mihomo: failed() }, guard_on: true });
let total_result = reconcile.create(total.app).run('automatic');
assert_equal(total_result.state, 'failure');
assert_equal(join(',', total.actions), join(',', fixture.mihomo_ladder));
assert_equal(index(join(',', total.actions), 'restore_direct'), -1);
assert_equal(total.events[length(total.events) - 1].type, 'fail_closed');

// Guard OFF permits one dependency-safe fallback only after the entire ladder,
// and direct accessibility must itself be freshly observed.
let fallback = make_app({ states: { mihomo: failed() }, direct_ok: true });
let fallback_reconciler = reconcile.create(fallback.app);
let fallback_result = fallback_reconciler.run('automatic');
assert_equal(fallback_result.state, 'failure');
assert_equal(fallback_reconciler.circuit_status().last_result, 'fallback');
assert_equal(join(',', fallback.actions),
	'reload,restart_core,restart_service,restore_direct,observe_direct');
assert_equal(fallback.events[length(fallback.events) - 1].type, 'direct_fallback');
let unproved = make_app({ states: { mihomo: failed() }, direct_ok: false });
let unproved_reconciler = reconcile.create(unproved.app);
assert_equal(unproved_reconciler.run('automatic').state, 'failure');
assert_equal(unproved_reconciler.circuit_status().last_result, 'failure');

// Guard ON remains fail closed across every retry and never invokes cleanup.
let guarded = make_app({ states: { mihomo: failed() }, guard_on: true });
let guarded_reconciler = reconcile.create(guarded.app);
guarded_reconciler.run('automatic');
for (let delay in [ 60000, 300000, 900000 ])
	guarded.clock.advance(delay);
guarded_reconciler.request_manual();
assert_equal(index(join(',', guarded.actions), 'restore_direct'), -1);
assert_true(length(filter(guarded.events, (item) => item.type == 'fail_closed')) >= 4);
let exceptional_guard = make_app({ states: { mihomo: failed() }, guard_on: true,
	mihomo_throw: { reload: true, restart_core: true, restart_service: true } });
reconcile.create(exceptional_guard.app).run('automatic');
assert_equal(index(join(',', exceptional_guard.actions), 'restore_direct'), -1);

// Exact retry backoff, saturation, and public circuit state.
let backed = make_app({ states: { telegram: failed() } });
let backed_reconciler = reconcile.create(backed.app);
for (let i = 0; i < length(fixture.backoff_minutes); i++) {
	if (i == 0) backed_reconciler.run('automatic');
	else backed.clock.advance(fixture.backoff_minutes[i - 1] * 60000);
	let before = backed.clock.now();
	let status = backed_reconciler.circuit_status();
	assert_equal(status.circuit, 'open');
	assert_equal(status.failure_count, i + 1);
	assert_equal(status.next_retry - before, fixture.backoff_minutes[i] * 60000);
}

// Manual requests return BUSY while queued, reset a scheduled delay when idle,
// and all mutations remain serialized through the operation adapter.
let deferred_ops = production_operations({ defer: true });
let manual = make_app({ states: { dns: failed() }, operations: deferred_ops });
let manual_reconciler = reconcile.create(manual.app);
manual_reconciler.run('automatic');
assert_equal(manual_reconciler.request_manual().code, 'BUSY');
assert_equal(manual_reconciler.circuit_status().pending, true);
deferred_ops.drain();
assert_true(manual_reconciler.circuit_status().next_retry != null);
let requested = manual_reconciler.request_manual();
assert_equal(requested.accepted, true);
assert_true(manual_reconciler.circuit_status().next_retry != null);
assert_equal(manual_reconciler.circuit_status().phase, 'queued');
assert_equal(length(deferred_ops.calls), 2);
deferred_ops.drain();

// Restart restores a persisted schedule and converts an in-flight attempt to
// interrupted failure rather than success.
let restart_clock = fakes.clock(2000);
let restarted = make_app({ clock: restart_clock, persisted: {
	version: 1, circuit: 'half_open', phase: 'inflight', failure_count: 2,
	next_retry: null, failure_id: 'failure-2-1000', failure_sequence: 2,
	last_result: 'failure'
} });
let restarted_reconciler = reconcile.create(restarted.app);
let restart_status = restarted_reconciler.circuit_status();
assert_equal(restart_status.last_result, 'interrupted');
assert_equal(restart_status.failure_count, 3);
assert_equal(restart_status.next_retry, 2000 + 900000);
assert_equal(restarted.persisted().phase, 'idle');
restart_clock.advance(900000);
assert_equal(length(restarted.app.operations.calls), 1);
let future_clock = fakes.clock(5000);
let future = make_app({ clock: future_clock, persisted: {
	version: 1, circuit: 'open', phase: 'idle', failure_count: 1, next_retry: 7000,
	failure_id: 'failure-1-1000', failure_sequence: 1, last_result: 'failure'
} });
reconcile.create(future.app);
future_clock.advance(1999);
assert_equal(length(future.app.operations.calls), 0);
future_clock.advance(1);
assert_equal(length(future.app.operations.calls), 1);
let restart_guard_clock = fakes.clock(9000);
let restart_guard = make_app({ clock: restart_guard_clock, guard_on: true,
	states: { mihomo: failed() }, persisted: {
		version: 1, circuit: 'open', phase: 'idle', failure_count: 1, next_retry: 10000,
		failure_id: 'failure-1-1000', failure_sequence: 1, last_result: 'failure'
	} });
reconcile.create(restart_guard.app);
restart_guard_clock.advance(1000);
assert_equal(index(join(',', restart_guard.actions), 'restore_direct'), -1);
assert_throws(() => reconcile.create({}), 'INVALID_ARGUMENT');
let corrupt_state = make_app({ persisted: { version: 99 } });
assert_throws(() => reconcile.create(corrupt_state.app), 'CORRUPT_STATE');

// Event sink failures are isolated. Recovery is observer-confirmed and links
// to the prior failure identity.
let isolated = make_app({ states: { routing: failed() }, repair_success: { routing: true }, event_failure: true });
assert_equal(reconcile.create(isolated.app).run('automatic').state, 'success');
let recovery = make_app({ states: { scheduler: failed() } });
let recovery_reconciler = reconcile.create(recovery.app);
recovery_reconciler.run('automatic');
let prior_failure = recovery_reconciler.circuit_status().failure_id;
recovery.states.scheduler = ok();
let recovered = recovery_reconciler.request_manual();
assert_equal(recovered.operation.state, 'success');
let recovery_event = recovery.events[length(recovery.events) - 1];
assert_equal(recovery_event.type, 'recovery');
assert_equal(recovery_event.data.failure_id, prior_failure);
assert_equal(recovery_reconciler.circuit_status().circuit, 'closed');

print('health reconciliation tests passed\n');

// Blocking review regressions. Keep these aggregated so the RED records all
// independently reproduced root causes in one focused invocation.
let review_failures = [];
function review_check(value, label) {
	if (!value) push(review_failures, label);
};
function threw_code(fn, code) {
	let caught = null;
	try { fn(); } catch (error) { caught = error?.code ?? error?.message; }
	return caught == code;
};

let operation_failure_ops = production_operations();
let operation_failure = make_app({ states: { telegram: failed() },
	operations: operation_failure_ops });
reconcile.create(operation_failure.app).run('automatic');
review_check(operation_failure_ops.calls[0].state == 'failure' &&
	operation_failure_ops.calls[0].error?.code == 'HEALTH_FAILED',
	'failed reconciliation operation status');

let healthy_target = make_app({ states: { scheduler: failed() },
	repair_success: { scheduler: true }, operations: production_operations() });
reconcile.create(healthy_target.app).repair('routing');
review_check(join(',', healthy_target.actions) == 'repair:scheduler',
	'target healthy but downstream failed');
let unhealthy_upstream = make_app({ states: { firewall: failed() },
	repair_success: { routing: true }, operations: production_operations() });
reconcile.create(unhealthy_upstream.app).repair('routing');
review_check(length(unhealthy_upstream.actions) == 0 &&
	unhealthy_upstream.events[0]?.data?.component == 'firewall',
	'unhealthy upstream prerequisite');

let dependent_failure = make_app({ states: { mihomo: failed(), scheduler: failed() },
	sequences: { mihomo: [ failed(), ok() ] }, repair_success: { scheduler: true },
	operations: production_operations(), direct_ok: true });
reconcile.create(dependent_failure.app).run('automatic');
review_check(join(',', dependent_failure.actions) == 'reload,repair:scheduler',
	'Mihomo recovery decisions ignore downstream state');

let open_state = make_app({ persisted: {
	version: 1, circuit: 'open', phase: 'idle', failure_count: 1, next_retry: 61000,
	failure_id: 'failure-1-1000', failure_sequence: 1, last_result: 'failure'
}, operations: production_operations() });
let open_reconciler = reconcile.create(open_state.app);
review_check(threw_code(() => open_reconciler.run('automatic'), 'BUSY') &&
	length(open_state.app.operations.calls) == 0,
	'automatic run respects open delay');

let stale_ops = production_operations();
let stale = make_app({ states: { telegram: failed() }, operations: stale_ops });
let stale_reconciler = reconcile.create(stale.app);
stale_reconciler.run('automatic');
for (let timer in stale.clock.timers)
	timer.cancel = () => die('cancel failed');
stale_reconciler.request_manual();
stale.clock.advance(60000);
review_check(length(stale_ops.calls) == 2, 'stale timer ignored after cancel exception');

let submit_ops = production_operations();
let submit_failure = make_app({ states: { telegram: failed() }, operations: submit_ops });
let submit_reconciler = reconcile.create(submit_failure.app);
submit_reconciler.run('automatic');
submit_ops.fail_submit = true;
review_check(threw_code(() => submit_reconciler.request_manual(), 'INTERNAL') &&
	submit_reconciler.circuit_status().next_retry != null,
	'manual submit failure restores durable retry');

let loose = make_app({ persisted: {
	version: 1, circuit: 'closed', phase: 'idle', failure_count: 0, next_retry: null,
	failure_id: null, failure_sequence: 0, last_result: null, extra: true
} });
review_check(threw_code(() => reconcile.create(loose.app), 'CORRUPT_STATE'),
	'exact persistent state allowlist');

let queued_clock = fakes.clock(1000);
let queued_restart = make_app({ clock: queued_clock, persisted: {
	version: 1, circuit: 'open', phase: 'queued', failure_count: 1,
	next_retry: 61000, failure_id: 'failure-7-1000', failure_sequence: 7,
	last_result: 'failure'
} });
let queued_ok = true, queued_status = null;
try { queued_status = reconcile.create(queued_restart.app).circuit_status(); }
catch (error) { queued_ok = false; }
review_check(queued_ok && queued_status.last_result == 'interrupted' &&
	queued_restart.persisted().phase == 'idle', 'queued crash recovery');

let inflight_restart = make_app({ clock: fakes.clock(1000), persisted: {
	version: 1, circuit: 'half_open', phase: 'inflight', failure_count: 1,
	next_retry: null, failure_id: 'failure-8-1000', failure_sequence: 8,
	last_result: 'failure'
} });
let inflight_ok = true, inflight_status = null;
try { inflight_status = reconcile.create(inflight_restart.app).circuit_status(); }
catch (error) { inflight_ok = false; }
review_check(inflight_ok && inflight_status.failure_count == 2 &&
	inflight_status.last_result == 'interrupted', 'inflight crash recovery');

let invalid_relation = make_app({ persisted: {
	version: 1, circuit: 'closed', phase: 'idle', failure_count: 2,
	next_retry: null, failure_id: null, failure_sequence: 2, last_result: 'success'
} });
review_check(threw_code(() => reconcile.create(invalid_relation.app), 'CORRUPT_STATE'),
	'persistent relational invariants');
let mismatched_sequence = make_app({ persisted: {
	version: 1, circuit: 'open', phase: 'idle', failure_count: 1,
	next_retry: 61000, failure_id: 'failure-9-1000', failure_sequence: 8,
	last_result: 'failure'
} });
review_check(threw_code(() => reconcile.create(mismatched_sequence.app), 'CORRUPT_STATE'),
	'failure identity matches persisted monotonic sequence');
let inconsistent_inflight = make_app({ persisted: {
	version: 1, circuit: 'half_open', phase: 'inflight', failure_count: 3,
	next_retry: null, failure_id: null, failure_sequence: 3, last_result: 'success'
} });
review_check(threw_code(() => reconcile.create(inconsistent_inflight.app), 'CORRUPT_STATE'),
	'inflight relation requires active failure identity for prior failures');
let inconsistent_closed = make_app({ persisted: {
	version: 1, circuit: 'closed', phase: 'idle', failure_count: 0,
	next_retry: null, failure_id: null, failure_sequence: 3, last_result: null
} });
review_check(threw_code(() => reconcile.create(inconsistent_closed.app), 'CORRUPT_STATE'),
	'closed historical state requires successful last result');

let followup_calls = 0;
let followup = make_app({ states: { dns: failed() }, operations: production_operations(),
	repair_observers: { dns: () => { followup_calls++; return ok('FOLLOWUP_OK'); } } });
reconcile.create(followup.app).repair('dns');
review_check(followup_calls == 1 && followup.app.operations.calls[0].state == 'success',
	'repair follow-up observer establishes success');

let invalid_action = make_app({ states: { dns: failed() }, operations: production_operations(),
	repair_results: { dns: { changed: [ 'dns' ], observe: () => ok(), extra: true } } });
reconcile.create(invalid_action.app).repair('dns');
review_check(invalid_action.app.operations.calls[0].state == 'failure' &&
	invalid_action.app.operations.calls[0].error?.code == 'HEALTH_FAILED',
	'exact repair action result validation');

let changed = [ 'dns-resource' ];
let action_events = make_app({ states: { dns: failed() }, operations: production_operations(),
	changed: { dns: changed }, repair_success: { dns: true } });
reconcile.create(action_events.app).repair('dns');
changed[0] = 'mutated-after-return';
let attempts = filter(action_events.events, (item) => item.type == 'action_attempt');
let outcomes = filter(action_events.events, (item) => item.type == 'action_outcome');
review_check(length(attempts) == 1 && length(outcomes) == 1 &&
	outcomes[0].data.changed[0] == 'dns-resource' &&
	type(outcomes[0].data.failure_id) == 'string',
	'action attempt/outcome events and detached resources');

let sequence_state = make_app({ now: 500, persisted: {
	version: 1, circuit: 'closed', phase: 'idle', failure_count: 0,
	next_retry: null, failure_id: null, failure_sequence: 41, last_result: 'success'
}, states: { telegram: failed() }, operations: production_operations() });
let sequence_ok = true;
try { reconcile.create(sequence_state.app).run('automatic'); }
catch (error) { sequence_ok = false; }
review_check(sequence_ok && sequence_state.events[0]?.data?.failure_id == 'failure-42-500',
	'monotonic failure identity across restart and clock rollback');

let initial_submit_ops = production_operations({ fail_submit: true });
let initial_submit = make_app({ operations: initial_submit_ops });
let initial_submit_reconciler = reconcile.create(initial_submit.app);
review_check(threw_code(() => initial_submit_reconciler.run('automatic'), 'INTERNAL') &&
	initial_submit_reconciler.circuit_status().phase == 'idle' &&
	initial_submit_reconciler.circuit_status().next_retry != null,
	'initial synchronous submit failure becomes durable retry');

let queued_window_ops = production_operations({ defer: true });
let queued_window = make_app({ operations: queued_window_ops });
reconcile.create(queued_window.app).run('automatic');
let queued_snapshot = queued_window.persisted();
let queued_window_restart = make_app({ persisted: queued_snapshot });
let queued_window_status = reconcile.create(queued_window_restart.app).circuit_status();
review_check(queued_snapshot.phase == 'queued' && queued_window_status.phase == 'idle' &&
	queued_window_status.last_result == 'interrupted' &&
	queued_window_status.next_retry != null, 'actual queued-window crash recovery');

let worker_exception_ops = production_operations();
let worker_exception = make_app({ operations: worker_exception_ops });
let original_write = worker_exception.app.store.write;
let worker_writes = 0;
worker_exception.app.store.write = (value) => {
	worker_writes++;
	if (worker_writes == 2) die('transient store failure');
	return original_write(value);
};
let worker_exception_reconciler = reconcile.create(worker_exception.app);
worker_exception_reconciler.run('automatic');
let worker_exception_status = worker_exception_reconciler.circuit_status();
review_check(worker_exception_ops.calls[0].state == 'failure' &&
	worker_exception_status.phase == 'idle' && worker_exception_status.next_retry != null &&
	worker_exception_status.failure_count == 1,
	'worker exception clears phase and schedules one retry');

let success_persist_ops = production_operations();
let success_persist = make_app({ operations: success_persist_ops });
let success_persist_write = success_persist.app.store.write;
let success_persist_writes = 0;
success_persist.app.store.write = (value) => {
	success_persist_writes++;
	if (success_persist_writes == 3) die('transient success persistence failure');
	return success_persist_write(value);
};
let success_persist_reconciler = reconcile.create(success_persist.app);
success_persist_reconciler.run('automatic');
let success_persist_status = success_persist_reconciler.circuit_status();
let success_persist_durable = success_persist.persisted();
review_check(success_persist_ops.calls[0].state == 'failure' &&
	success_persist_ops.calls[0].error?.code == 'HEALTH_FAILED' &&
	success_persist_ops.ownership_releases == 1 && success_persist_writes == 4 &&
	success_persist_status.phase == 'idle' && success_persist_status.circuit == 'open' &&
	success_persist_status.failure_count == 1 &&
	success_persist_status.failure_id != null &&
	success_persist_status.failure_id == success_persist_durable.failure_id &&
	success_persist_status.failure_sequence == 1 &&
	success_persist_status.failure_sequence == success_persist_durable.failure_sequence &&
	success_persist_status.last_result == 'failure' &&
	success_persist_status.last_result == success_persist_durable.last_result &&
	success_persist_status.next_retry == success_persist_durable.next_retry &&
	success_persist_durable.phase == 'idle' && success_persist_durable.circuit == 'open' &&
	success_persist_durable.failure_count == 1 &&
	length(filter(success_persist.events, (item) => item.type == 'failure')) == 1 &&
	filter(success_persist.events, (item) => item.type == 'failure')[0].data.failure_id ==
		success_persist_durable.failure_id &&
	length(filter(success_persist.clock.timers, (item) => item.active)) == 1,
	'success persistence failure rolls back into one durable retry');

let mihomo_events = make_app({ states: { mihomo: failed() }, guard_on: true,
	operations: production_operations() });
reconcile.create(mihomo_events.app).run('automatic');
let mihomo_attempts = filter(mihomo_events.events, (item) => item.type == 'action_attempt');
let mihomo_outcomes = filter(mihomo_events.events, (item) => item.type == 'action_outcome');
review_check(length(mihomo_attempts) == 3 && length(mihomo_outcomes) == 3 &&
	join(',', map(mihomo_attempts, (item) => item.data.stage)) == join(',', fixture.mihomo_ladder) &&
	join(',', fixture.action_events) == 'action_attempt,action_outcome',
	'every Mihomo stage emits attempt and outcome');

review_check(join(',', sort(keys(queued_snapshot))) ==
	join(',', sort(fixture.persistent_fields)) &&
	join(',', fixture.phases) == 'idle,queued,inflight',
	'fixture-backed exact persistent schema');

let complete_throw_ops = production_operations({ complete_throws: 1 });
let complete_throw = make_app({ states: { telegram: failed() },
	operations: complete_throw_ops });
let complete_throw_reconciler = reconcile.create(complete_throw.app);
complete_throw_reconciler.run('automatic');
let complete_throw_status = complete_throw_reconciler.circuit_status();
review_check(complete_throw_ops.calls[0].state == 'failure' &&
	complete_throw_ops.calls[0].error?.code == 'HEALTH_FAILED' &&
	complete_throw_ops.ownership_releases == 1 && complete_throw_status.phase == 'idle' &&
	complete_throw_status.failure_count == 1 &&
	length(filter(complete_throw.clock.timers, (item) => item.active)) == 1,
	'ctx.complete error propagates to manager catch and releases ownership once');

let transient_timer = fakes.clock(1000);
let real_set_timeout = transient_timer.set_timeout;
let timer_installs = 0;
transient_timer.set_timeout = (milliseconds, callback) => {
	timer_installs++;
	if (timer_installs == 1) die('transient timer creation failure');
	return real_set_timeout(milliseconds, callback);
};
let timer_throw_ops = production_operations();
let timer_throw = make_app({ clock: transient_timer, states: { telegram: failed() },
	operations: timer_throw_ops });
let timer_throw_reconciler = reconcile.create(timer_throw.app);
timer_throw_reconciler.run('automatic');
let timer_throw_status = timer_throw_reconciler.circuit_status();
let active_before_retry = length(filter(transient_timer.timers, (item) => item.active));
transient_timer.advance(60000);
review_check(timer_throw_ops.calls[0].state == 'failure' &&
	timer_throw_status.phase == 'idle' && timer_throw_status.circuit == 'open' &&
	timer_throw_status.failure_count == 1 && active_before_retry == 1 &&
	length(timer_throw_ops.calls) == 2 &&
	length(filter(timer_throw.actions, (item) => item == 'repair:telegram')) == 2,
	'transient timer install rolls back then creates one effective retry');

let startup_timer = fakes.clock(1000);
startup_timer.set_timeout = (milliseconds, callback) => die('startup timer failure');
let startup_open = make_app({ clock: startup_timer, persisted: {
	version: 1, circuit: 'open', phase: 'idle', failure_count: 1,
	next_retry: 61000, failure_id: 'failure-1-1000', failure_sequence: 1,
	last_result: 'failure'
} });
let startup_failed = false;
try { reconcile.create(startup_open.app); }
catch (error) { startup_failed = true; }
review_check(startup_failed && length(startup_open.app.operations.calls) == 0,
	'startup open state fails creation when timer cannot be installed');

let persist_timer_clock = fakes.clock(1000);
let persist_timer_ops = production_operations();
let persist_timer = make_app({ clock: persist_timer_clock, states: { telegram: failed() },
	operations: persist_timer_ops });
let persist_timer_write = persist_timer.app.store.write;
let persist_timer_writes = 0;
persist_timer.app.store.write = (value) => {
	persist_timer_writes++;
	if (persist_timer_writes == 4) die('transient final persistence failure');
	return persist_timer_write(value);
};
let persist_timer_reconciler = reconcile.create(persist_timer.app);
persist_timer_reconciler.run('automatic');
let persist_timer_status = persist_timer_reconciler.circuit_status();
review_check(persist_timer_ops.calls[0].state == 'failure' &&
	persist_timer_status.failure_count == 1 && persist_timer_status.phase == 'idle' &&
	length(filter(persist_timer_clock.timers, (item) => item.active)) == 1,
	'candidate timer invalidates and retries after final persistence failure');

if (length(review_failures))
	die('review regressions: ' + join('; ', review_failures));
