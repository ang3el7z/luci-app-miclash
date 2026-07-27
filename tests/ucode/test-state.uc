import { assert_equal } from 'testlib';
import * as state from 'miclash.state';

let operation_callback = null;
let model = state.create({
	settings: { get: () => ({ core: { proxy_mode: 'tproxy' } }) },
	service: {
		observe: () => ({ state: 'running', running: true }),
		wait_ready: () => ({ ok: true, state: 'ready', components: [] })
	},
	operations: {
		list: () => [ { id: 'op_1', kind: 'service.start', source: 'luci', state: 'success' } ],
		subscribe: (callback) => { operation_callback = callback; return () => true; }
	},
	clock: { now: () => 1000 },
	store: { write: () => true }
});

let current = model.current();
assert_equal(current.desired.core.proxy_mode, 'tproxy');
assert_equal(current.observed.service.running, false);
assert_equal(current.recent_operations, null);

current.desired.core.proxy_mode = 'redirect';
assert_equal(model.current().desired.core.proxy_mode, 'tproxy');

operation_callback({ id: 'op_2', kind: 'service.stop', source: 'luci', state: 'success' });
assert_equal(model.current().recent_operations, null);
assert_equal(length(model.snapshot().recent_operations), 2);
assert_equal(model.last_repair().state, 'none');
operation_callback({ id: 'op_3', kind: 'memory.recovery', source: 'auto', state: 'success' });
assert_equal(model.last_repair().id, 'op_3');
