import { assert_equal, assert_throws, assert_true } from 'testlib';
import * as daemon from 'miclash.daemon';

let order = [];
let connect_count = 0, disconnect_count = 0;
let connection = {
	call: () => null,
	publish: (name, methods) => { push(order, 'publish'); return { name }; },
	disconnect: () => { disconnect_count++; push(order, 'disconnect'); return true; }
};
let rt = {
	ubus: { connect: () => { connect_count++; push(order, 'connect'); return connection; } },
	clock: { now: () => 0 },
	paths: { tmp: '/tmp/miclash' }
};
let operation_manager = {
	recover_interrupted: () => push(order, 'recover'),
	submit: () => ({ id: 'id' }), get: () => null, list: () => [],
	subscribe: () => () => true
};
let state_model = {
	snapshot: () => ({}), health: () => ({}), set_desired: () => null,
	observe: () => null,
	close: () => { push(order, 'state.close'); return true; },
	flush: () => { push(order, 'state.flush'); return true; }
};
let drained = 0;
let application = {
	status: state_model.snapshot, health: state_model.health,
	operation_get: () => null, operation_list: () => [],
	service_start: () => ({ id: 'id' }), service_stop: () => ({ id: 'id' }),
	service_reload: () => ({ id: 'id' }), service_restart: () => ({ id: 'id' }),
	config_list: () => [], config_read: () => '',
	config_read_draft: () => '', config_save_draft: () => ({ id: 'id' }),
	config_validate: () => ({ id: 'id' }), config_apply: () => ({ id: 'id' }),
	settings_get: () => ({}), settings_set: () => ({ id: 'id' }),
	set_draining: (value) => { if (value) drained++; return value; }
};
let factories = {
	operations: { create: () => operation_manager },
	service: { create: (runtime) => {
		assert_true(runtime.ubus.connect() === connection);
		assert_true(runtime.ubus.connect() === connection);
		return {};
	} },
	history: { create: () => ({}) },
	config: { create: () => { push(order, 'config'); return {}; } },
	state: { create: () => state_model },
	application: { create: () => application },
	settings: { load: () => ({}), validate_patch: (patch) => patch, save: () => ({}) },
	storage: { write_json: () => true }
};

let process = daemon.compose(rt, factories);
assert_equal(connect_count, 1);
assert_true(index(order, 'recover') < index(order, 'connect'));
assert_true(index(order, 'connect') < index(order, 'config'));
assert_true(index(order, 'config') < index(order, 'publish'));
process.drain();
assert_equal(drained, 1);
assert_equal(process.close(), true);
assert_equal(process.close(), false);
assert_equal(disconnect_count, 1);
assert_true(index(order, 'state.close') < index(order, 'state.flush'));
assert_true(index(order, 'state.flush') < index(order, 'disconnect'));

function malformed_connection(candidate) {
	let count = 0;
	let original = candidate.disconnect;
	if (type(original) == 'function')
		candidate.disconnect = () => { count++; return original(); };
	let runtime = {
		ubus: { connect: () => candidate }, clock: { now: () => 0 },
		paths: { tmp: '/tmp/miclash' }
	};
	assert_throws(() => daemon.compose(runtime, factories), 'INTERNAL');
	return count;
};

assert_equal(malformed_connection({ call: () => null, disconnect: () => true }), 1);
assert_equal(malformed_connection({ publish: () => ({}), disconnect: () => true }), 1);
assert_equal(malformed_connection({ call: () => null, publish: () => ({}) }), 0);
