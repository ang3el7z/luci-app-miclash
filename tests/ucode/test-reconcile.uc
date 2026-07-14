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

function operation_manager(options) {
	options ??= {};
	let manager = { calls: [], active: false, deferred: [] };
	manager.submit = (kind, source, context, worker) => {
		if (manager.active)
			die('operation overlap');
		let record = { id: sprintf('op-%d', length(manager.calls) + 1), kind, source, context };
		push(manager.calls, record);
		if (options.defer) {
			push(manager.deferred, () => {
				manager.active = true;
				record.result = worker({ id: record.id });
				manager.active = false;
				return record.result;
			});
			return record;
		}
		manager.active = true;
		record.result = worker({ id: record.id });
		manager.active = false;
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
			return { changed: true };
		};
	};
	for (let name in COMPONENTS)
		repairs[name] = repair(name);
	let app = {
		clock,
		operations: options.operations ?? operation_manager(),
		observers,
		repairs,
		mihomo: {
			reload: () => {
				push(actions, 'reload');
				if (options.mihomo_throw?.reload) die('secret reload error');
				return { changed: true };
			},
			restart_core: () => {
				push(actions, 'restart_core');
				if (options.mihomo_throw?.restart_core) die('secret core error');
				return { changed: true };
			},
			restart_service: () => {
				push(actions, 'restart_service');
				if (options.mihomo_throw?.restart_service) die('secret service error');
				return { changed: true };
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
let targeted_result = targeted_reconciler.repair('routing').result;
assert_equal(targeted_result.ok, true);
assert_equal(join(',', targeted.actions), 'repair:routing');
assert_equal(join(',', targeted.order), join(',', [ ...COMPONENTS, ...fixture.downstream.routing ]));
assert_equal(index(join(',', targeted.actions), 'repair:firewall'), -1);

// A repair return is never success proof: the fresh observer controls the result.
let false_success = make_app({ states: { dns: failed() } });
let rejected = reconcile.create(false_success.app).repair('dns').result;
assert_equal(rejected.ok, false);
assert_equal(rejected.component, 'dns');
assert_equal(join(',', false_success.actions), 'repair:dns');
assert_throws(() => reconcile.create(make_app().app).repair('future'), 'INVALID_ARGUMENT');

// Mihomo ladder stops only after fresh health proof at each exact stage.
for (let stop = 0; stop < 3; stop++) {
	let sequence = [ failed() ];
	for (let i = 0; i <= stop; i++)
		push(sequence, i == stop ? ok() : failed());
	let ladder = make_app({ states: { mihomo: failed() }, sequences: { mihomo: sequence } });
	let result = reconcile.create(ladder.app).run('automatic').result;
	assert_equal(result.ok, true);
	assert_equal(join(',', ladder.actions), join(',', slice(fixture.mihomo_ladder, 0, stop + 1)));
	assert_equal(ladder.events[length(ladder.events) - 1].type, 'recovery');
}
let total = make_app({ states: { mihomo: failed() }, guard_on: true });
let total_result = reconcile.create(total.app).run('automatic').result;
assert_equal(total_result.ok, false);
assert_equal(join(',', total.actions), join(',', fixture.mihomo_ladder));
assert_equal(index(join(',', total.actions), 'restore_direct'), -1);
assert_equal(total.events[length(total.events) - 1].type, 'fail_closed');

// Guard OFF permits one dependency-safe fallback only after the entire ladder,
// and direct accessibility must itself be freshly observed.
let fallback = make_app({ states: { mihomo: failed() }, direct_ok: true });
let fallback_result = reconcile.create(fallback.app).run('automatic').result;
assert_equal(fallback_result.ok, false);
assert_equal(fallback_result.fallback, true);
assert_equal(join(',', fallback.actions),
	'reload,restart_core,restart_service,restore_direct,observe_direct');
assert_equal(fallback.events[length(fallback.events) - 1].type, 'direct_fallback');
let unproved = make_app({ states: { mihomo: failed() }, direct_ok: false });
assert_equal(reconcile.create(unproved.app).run('automatic').result.fallback, false);

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
let deferred_ops = operation_manager({ defer: true });
let manual = make_app({ states: { dns: failed() }, operations: deferred_ops });
let manual_reconciler = reconcile.create(manual.app);
manual_reconciler.run('automatic');
assert_equal(manual_reconciler.request_manual().code, 'BUSY');
assert_equal(manual_reconciler.circuit_status().pending, true);
deferred_ops.drain();
assert_true(manual_reconciler.circuit_status().next_retry != null);
let requested = manual_reconciler.request_manual();
assert_equal(requested.accepted, true);
assert_equal(manual_reconciler.circuit_status().next_retry, null);
assert_equal(length(deferred_ops.calls), 2);
deferred_ops.drain();

// Restart restores a persisted schedule and converts an in-flight attempt to
// interrupted failure rather than success.
let restart_clock = fakes.clock(2000);
let restarted = make_app({ clock: restart_clock, persisted: {
	version: 1, circuit: 'half_open', failure_count: 2, next_retry: null,
	failure_id: 'failure-1', inflight: true, last_result: null
} });
let restarted_reconciler = reconcile.create(restarted.app);
let restart_status = restarted_reconciler.circuit_status();
assert_equal(restart_status.last_result, 'interrupted');
assert_equal(restart_status.failure_count, 3);
assert_equal(restart_status.next_retry, 2000 + 900000);
assert_equal(restarted.persisted().inflight, false);
restart_clock.advance(900000);
assert_equal(length(restarted.app.operations.calls), 1);
let future_clock = fakes.clock(5000);
let future = make_app({ clock: future_clock, persisted: {
	version: 1, circuit: 'open', failure_count: 1, next_retry: 7000,
	failure_id: 'failure-future', inflight: false, last_result: 'failure'
} });
reconcile.create(future.app);
future_clock.advance(1999);
assert_equal(length(future.app.operations.calls), 0);
future_clock.advance(1);
assert_equal(length(future.app.operations.calls), 1);
let restart_guard_clock = fakes.clock(9000);
let restart_guard = make_app({ clock: restart_guard_clock, guard_on: true,
	states: { mihomo: failed() }, persisted: {
		version: 1, circuit: 'open', failure_count: 1, next_retry: 10000,
		failure_id: 'failure-guard', inflight: false, last_result: 'failure'
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
assert_equal(reconcile.create(isolated.app).run('automatic').result.ok, true);
let recovery = make_app({ states: { scheduler: failed() } });
let recovery_reconciler = reconcile.create(recovery.app);
recovery_reconciler.run('automatic');
let prior_failure = recovery_reconciler.circuit_status().failure_id;
recovery.states.scheduler = ok();
let recovered = recovery_reconciler.request_manual();
assert_equal(recovered.operation.result.ok, true);
let recovery_event = recovery.events[length(recovery.events) - 1];
assert_equal(recovery_event.type, 'recovery');
assert_equal(recovery_event.data.failure_id, prior_failure);
assert_equal(recovery_reconciler.circuit_status().circuit, 'closed');

print('health reconciliation tests passed\n');
