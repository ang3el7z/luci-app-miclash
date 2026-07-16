import { assert_equal, assert_throws, assert_true } from 'testlib';
import * as daemon from 'miclash.daemon';
import * as real_api from 'miclash.api';
import * as real_application from 'miclash.application';
import * as runtime_module from 'miclash.runtime';
import * as fakes from './fakes.uc';

let order = [];
let connect_count = 0, disconnect_count = 0;
let published_methods = null;
let connection = {
	call: () => null,
	publish: (name, methods) => { published_methods = methods; push(order, 'publish'); return { name }; },
	disconnect: () => { disconnect_count++; push(order, 'disconnect'); return true; }
};
let rt = {
	ubus: { connect: () => { connect_count++; push(order, 'connect'); return connection; } },
	clock: { now: () => 0 },
	paths: { tmp: '/tmp/miclash' },
	reconcile: { run: () => ({ id: 'reconcile' }) }
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
	settings: { load: () => ({
		memory: { enabled: false, sample_interval_ms: 60000 },
		notifications: { auto_hide: true, channels: [ 'syslog' ], events: [ 'failure' ] }
	}), validate_patch: (patch) => patch, save: () => ({}) },
	storage: { write_json: () => true },
	memory: { create: () => ({ status: () => ({}), settings: (value) => value ?? {
		sample_interval_ms: 60000 }, reset_baseline: () => true, sample: () => true }) },
	notify: { producer: () => ({ memory: (event) => event }), create: () => ({
		emit: () => true, test: () => true }) },
	backup: {
		list: () => [], create: () => ({}), inspect: () => ({}), restore: () => ({}),
		transfer_download: () => ({}), transfer_import: () => ({})
	},
	devices: {
		discover: () => [], timezones: (app) => app.timezones.list(), policy_list: () => [],
		policy_set: () => ({}), policy_delete: () => true
	},
	mutation_lock: { with_lock: (runtime, options, worker) => worker({}) },
	api: { create_transfers: () => ({ begin: () => ({}), write: () => ({}), read: () => ({}),
		finish: () => ({}), abort: () => ({}), close: () => true }), register: real_api.register }
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

// The management cutover uses the real application facade and real API
// registration. Domain implementations remain injected so this test observes
// daemon composition rather than duplicating each domain's focused tests.
let integration_methods = null, integrated_disconnects = 0, integrated_closes = [];
let integrated_connection = {
	call: () => null,
	send: () => true,
	publish: (name, methods) => { integration_methods = methods; return { name }; },
	disconnect: () => { integrated_disconnects++; return true; }
};
let operation_sequence = 0, operation_records = {};
let integrated_operations = {
	recover_interrupted: () => true,
	submit: (kind, source, context, worker) => {
		let id = 'operation-' + (++operation_sequence);
		let record = { id, kind, source, context, state: 'running' };
		operation_records[id] = record;
		let result = worker({ id, stage: () => true });
		record.state = 'success'; record.result = result;
		return { id };
	},
	get: (id) => operation_records[id] ?? null,
	list: () => values(operation_records), subscribe: () => () => true
};
let desired = {
	memory: { enabled: true, sample_interval_ms: 60000 },
	notifications: { auto_hide: true, channels: [ 'syslog', 'luci' ], events: [ 'failure' ] },
	backup: { enabled: false, retention: 5, include_secrets: false },
	telegram: { enabled: false, token: '', user_id: '' }
};
let integrated_state = {
	snapshot: () => ({ desired }), health: () => ({ ready: true }),
	set_desired: (value) => desired = value, observe: () => null,
	close: () => { push(integrated_closes, 'state'); return true; }, flush: () => true
};
let guard = {
	status: () => ({ phase: 'monitoring', current_rss_kb: 64000 }),
	settings: (value) => value ?? { sample_interval_ms: 60000 },
	reset_baseline: () => true, sample: () => true
};
let notifier = {
	emit: () => true, test: (channel) => channel == 'syslog' || channel == 'luci'
};
let imported_staged = null, backup_app_seen = null, devices_app_seen = null;
let fake_transfers = null;
let integrated_factories = {
	operations: { create: () => integrated_operations },
	service: { create: () => ({
		start: () => true, stop: () => true, reload: () => true,
		restart_service: () => true, wait_ready: () => ({ ok: true })
	}) },
	history: { create: () => ({
		list: () => [], diff: () => ({ text: '' }), open_draft: () => ({ id: 'operation-history' }),
		restore: () => ({ id: 'operation-restore' })
	}) },
	config: { create: () => ({
		list_profiles: () => [ 'config.yaml' ], read_active: () => 'mode: rule\n',
		read_draft: () => 'mode: rule\n', save_draft: () => ({ id: 'operation-draft' }),
		validate: () => ({ id: 'operation-validate' }), apply: () => ({ id: 'operation-apply' }),
		validate_in_operation: () => ({ ok: true })
	}) },
	state: { create: () => integrated_state },
	application: real_application,
	settings: {
		load: () => desired, validate_patch: (patch) => patch,
		save: (runtime, patch) => { desired = { ...desired, ...patch }; return desired; }
	},
	storage: { write_json: () => true },
	memory: { create: () => guard },
	notify: { producer: () => ({ memory: (event) => event }), create: () => notifier },
	backup: {
		list: (app) => { backup_app_seen = app; return [ { id: 'b-1700000000000-00000000000000000000000000000000' } ]; },
		create: () => ({ id: 'b-1700000000000-00000000000000000000000000000000' }),
		inspect: (app, id) => ({ id: 'x-1700000000000-00000000000000000000000000000000', source_id: id }),
		restore: () => ({ id: 'operation-backup-restore' }),
		transfer_download: () => ({ size: 1, sha256: sprintf('%064d', 0), read: () => 'x', finish: () => ({}), close: () => true }),
		transfer_import: (app, staged) => { imported_staged = staged; return { import_id: 'i-1700000000000-00000000000000000000000000000000' }; }
	},
	devices: {
		discover: (app) => { devices_app_seen = app; return [ { mac: '02:00:00:00:00:01' } ]; },
		timezones: (app) => app.timezones.list(), policy_list: () => [],
		policy_set: () => ({ id: 'dp_1_0000000000000000', revision: 1 }),
		policy_delete: () => true
	},
	mutation_lock: { with_lock: (runtime, options, worker) => worker({}) },
	api: {
		create_transfers: (dependencies) => {
			fake_transfers = {
				begin: () => ({ transfer_id: 'transfer' }), write: () => ({ next_seq: 1 }),
				read: () => ({ completed: true }), abort: () => ({ aborted: true }),
				finish: () => ({ completed: true, result: dependencies.uploads.backup({
					kind: 'backup', metadata: { purpose: 'inspect' }, size: 1,
					sha256: sprintf('%064d', 0), read: () => 'x'
				}) }),
				close: () => { push(integrated_closes, 'transfers'); return true; }
			};
			return fake_transfers;
		},
		register: real_api.register
	}
};
let integrated_runtime = {
	ubus: { connect: () => integrated_connection },
	clock: { now: () => 1700000000000, set_timeout: () => ({ cancel: () => true }) },
	paths: { tmp: '/tmp/miclash', etc: '/etc/miclash', run: '/var/run/miclash' },
	secure_fs: {}, fs: {}, digest: {}, random: {}, uci: {}, process: { run: () => ({ code: 0 }) }
};
let integrated = daemon.compose(integrated_runtime, integrated_factories);
assert_equal(integration_methods.memory_status.call({ args: {} }).phase, 'monitoring');
assert_equal(length(integration_methods.backup_list.call({ args: {} })), 1);
assert_equal(integration_methods.devices_timezones.call({ args: {} })[0], 'UTC');
assert_equal(integration_methods.devices_list.call({ args: {} })[0].mac, '02:00:00:00:00:01');
assert_equal(integration_methods.notifications_test.call({ args: { channel: 'syslog' } }).sent, true);
assert_equal(fake_transfers.finish({}).result.import_id,
	'i-1700000000000-00000000000000000000000000000000');
assert_true(imported_staged != null);
assert_true(backup_app_seen.runtime === integrated_runtime);
assert_true(devices_app_seen.timezones.list()[0] == 'UTC');
assert_equal(integrated.close(), true);
assert_equal(integrated_disconnects, 1);
assert_true(index(integrated_closes, 'transfers') >= 0);

// The production composition must construct every management domain and the
// real transfer manager. Only host capabilities are substituted here.
let production_methods = null, production_disconnects = 0;
let production_running = false;
let production_connection = {
	call: (object, method, args) => {
		if (object == 'service' && method == 'list')
			return { clash: { instances: production_running
				? { core: { running: true, pid: 321 } } : {} } };
		if (object == 'service' && method == 'state') {
			production_running = args.spawn === true;
			return {};
		}
		return {};
	},
	send: () => true,
	publish: (name, methods) => { production_methods = methods; return { name }; },
	disconnect: () => { production_disconnects++; return true; }
};
let production_clock = fakes.clock(1700000000000);
let production_fs = fakes.fs({
	'/proc/sys/kernel/random/boot_id': '11111111-1111-1111-1111-111111111111\n',
	'/proc/self/stat': '123 (ucode) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 200 21 22\n',
	'/proc/123/stat': '123 (ucode) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 200 21 22\n',
	'/var/run/miclash/.keep': '', '/tmp/miclash/.keep': '',
	'/etc/miclash/.keep': '', '/opt/clash/.keep': '',
	'/opt/clash/config.yaml': 'external-controller: 127.0.0.1:9090\n',
	'/opt/clash/bin/clash': 'binary',
	'/usr/libexec/miclash/validate-config.uc': 'helper'
});
production_fs.set_mode('/opt/clash', 0o700);
production_fs.set_mode('/opt/clash/config.yaml', 0o600);
production_fs.set_mode('/opt/clash/bin/clash', 0o755);
let production_runtime = runtime_module.create({
	fs: production_fs,
	digest: fakes.digest(production_fs),
	random: fakes.entropy(),
	clock: production_clock,
	process: fakes.process(),
	uci: fakes.uci({ miclash: {
		core: { '.type': 'core' }, interfaces: { '.type': 'interfaces' },
		guard: { '.type': 'guard' }, memory: { '.type': 'memory' },
		updates: { '.type': 'updates' }, telegram: { '.type': 'telegram' },
		notifications: { '.type': 'notifications' }, backup: { '.type': 'backup' },
		meta: { '.type': 'meta' }
	} }),
	ubus: { connect: () => production_connection },
	http: { request: () => ({ status: 200, body: '{}' }) },
	observers: {
		dhcp_leases: () => ({ observed_at: 1700000000, data: '' }),
		neighbors: () => ({ observed_at: 1700000000, data: '[]' }),
		dns: () => ({ ready: true }), tun: () => ({ ready: true }),
		policy: () => ({ ready: true }), forward: () => ({ ready: true })
	}
});
let production_daemon = daemon.compose(production_runtime);
assert_true(type(production_runtime.rulesets?.validate) == 'function');
assert_true(type(production_runtime.reconcile?.run) == 'function');
assert_true(type(production_methods?.settings_get?.call) == 'function');
assert_true(type(production_methods?.transfer_begin?.call) == 'function');
assert_equal(production_methods.devices_timezones.call({ args: {} })[0], 'UTC');
assert_equal(length(production_methods.backup_list.call({ args: {} })), 0);
let create_record = production_methods.backup_create.call({ args: {
	options: { include_secrets: true }, source: 'luci'
} });
production_clock.advance(0);
create_record = production_daemon.app.operation_get(create_record.operation_id);
assert_equal(create_record.state, 'success');
let created_backups = production_methods.backup_list.call({ args: {} });
assert_equal(length(created_backups), 1);
let inspection = production_methods.backup_inspect.call({ args: {
	backup_id: created_backups[0].id, options: {}
} });
let restore_record = production_methods.backup_restore.call({ args: {
	inspection_id: inspection.id, source: 'luci'
} });
production_clock.advance(0);
restore_record = production_daemon.app.operation_get(restore_record.operation_id);
assert_equal(restore_record.stage, 'complete');
assert_equal(restore_record.error?.code, null);
assert_equal(restore_record.state, 'success');
production_clock.advance(0);
let reconciliations = production_daemon.app.operation_list({ kind: 'system.reconcile' });
assert_equal(length(reconciliations), 1);
assert_equal(reconciliations[0].state, 'success');
let upload = production_methods.transfer_begin.call({ args: {
	direction: 'upload', kind: 'backup', metadata: { purpose: 'inspect' },
	size: 1, sha256: sprintf('%064d', 0)
} });
assert_true(type(upload.transfer_id) == 'string');
assert_equal(production_daemon.close(), true);
assert_equal(production_disconnects, 1);
