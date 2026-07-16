import { assert_equal } from 'testlib';
import * as adapter from 'miclash.reconcile-adapter';

let records = [], events = [], ready = false, guard_enabled = true, now = 1700000000000;
let sequence = 0;
let reconciler = adapter.create({
	operations: { submit: (kind, source, context, worker) => {
		let record = { id: 'operation-' + (++sequence), kind, source, context };
		try { record.result = worker({ stage: () => true }); record.state = 'success'; }
		catch (error) { record.state = 'failure'; record.error = error?.code ?? error?.message; }
		push(records, record); return record;
	} },
	service: { restart_service: () => true,
		wait_ready: () => ({ ok: ready, components: ready ? [
			{ component: 'process', ready: true }, { component: 'api', ready: true },
			{ component: 'dns', ready: true, observed_at: now },
			{ component: 'forward', ready: true, observed_at: now },
			{ component: 'guard', ready: true, observed_at: now,
				enabled: guard_enabled, generation: 7 }
		] : [] }) },
	settings: { get: () => ({ core: { proxy_mode: 'tproxy' },
		guard: { enabled: guard_enabled } }) },
	clock: { now: () => now },
	events: { emit: (type_name, data) => { push(events, { type: type_name, data }); return true; } }
});

assert_equal(reconciler.run('automatic').state, 'failure');
assert_equal(events[0].type, 'failure');
assert_equal(events[0].data.component, 'mihomo');
assert_equal(events[1].type, 'fail_closed');
assert_equal(events[1].data.failure_id, events[0].data.failure_id);

ready = true; now++;
assert_equal(reconciler.run('scheduled').state, 'success');
assert_equal(events[2].type, 'internet_restored');
assert_equal(events[2].data.failure_id, events[0].data.failure_id);
assert_equal(events[2].data.recovery_of, 'fail-closed/' + events[0].data.failure_id);
assert_equal(events[2].data.guard.enabled, true);
assert_equal(events[2].data.network.path, 'proxy');
assert_equal(events[3].type, 'recovery');
assert_equal(events[3].data.failure_id, events[0].data.failure_id);

// A healthy run without an active outage is not an Internet-restored event.
assert_equal(reconciler.run('scheduled').state, 'success');
assert_equal(length(events), 4);

// Without Guard, the restoration closes the failure itself and is emitted once.
ready = false; guard_enabled = false; now++;
assert_equal(reconciler.run('automatic').state, 'failure');
let direct_failure = events[length(events) - 1].data.failure_id;
ready = true; now++;
assert_equal(reconciler.run('scheduled').state, 'success');
assert_equal(events[length(events) - 1].type, 'internet_restored');
assert_equal(events[length(events) - 1].data.recovery_of, 'failure/' + direct_failure);
assert_equal(events[length(events) - 1].data.network.path, 'proxy');
