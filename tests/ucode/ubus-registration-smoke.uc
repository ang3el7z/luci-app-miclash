import * as uloop from 'uloop';
import * as ubus from 'ubus';
import * as daemon from 'miclash.daemon';

if (uloop.init() !== true)
	die('uloop init failed');

let connection_count = 0;
let rt = {
	ubus: { connect: () => { connection_count++; return ubus.connect(ARGV[0]); } },
	clock: { now: () => 0 },
	paths: { tmp: '/tmp/miclash' }
};
let operations = {
	recover_interrupted: () => 0,
	submit: (kind, source, context, worker) => ({ id: 'native-smoke-operation' }),
	get: (id) => null,
	list: (filter) => [],
	subscribe: (callback) => () => true
};
let state = {
	snapshot: () => ({ ready: true }),
	health: () => ({ observed: {} }),
	set_desired: (value) => value,
	observe: () => null,
	close: () => true,
	flush: () => true
};
let application = {
	status: state.snapshot,
	health: state.health,
	operation_get: () => null,
	operation_list: () => [],
	service_start: () => ({ id: 'native-smoke-operation' }),
	service_stop: () => ({ id: 'native-smoke-operation' }),
	service_reload: () => ({ id: 'native-smoke-operation' }),
	service_restart: () => ({ id: 'native-smoke-operation' }),
	config_list: () => [ 'config.yaml' ],
	config_read: () => 'mode: rule\n',
	config_validate: () => ({ id: 'native-smoke-operation' }),
	config_apply: () => ({ id: 'native-smoke-operation' }),
	settings_get: () => ({ telegram: { token: 'native-smoke-secret' } }),
	settings_set: () => ({ id: 'native-smoke-operation' }),
	set_draining: (value) => value
};
let factories = {
	operations: { create: () => operations },
	service: { create: (runtime) => {
		if (runtime.ubus.connect() == null || runtime.ubus.connect() == null)
			die('shared ubus unavailable');
		return {};
	} },
	history: { create: () => ({}) },
	config: { create: () => ({}) },
	state: { create: () => state },
	application: { create: () => application },
	settings: { load: () => ({}), validate_patch: (patch) => patch, save: (runtime, patch) => patch },
	storage: { write_json: () => true }
};

let process = daemon.compose(rt, factories);
if (connection_count != 1)
	die('daemon opened more than one ubus connection');
let timeout = uloop.timer(5000, () => uloop.end());
uloop.run();
timeout.cancel();
process.close();
uloop.done();
