import { assert_equal, assert_match, assert_throws, assert_true } from 'testlib';
import * as daemon from 'miclash.daemon';
import * as real_api from 'miclash.api';
import * as real_application from 'miclash.application';
import * as real_reconcile_adapter from 'miclash.reconcile-adapter';
import * as runtime_module from 'miclash.runtime';
import * as startup_guard from 'miclash.startup-guard';
import * as platform from 'miclash.platform';
import * as fakes from './fakes.uc';

assert_equal(daemon.parse_openwrt_version("DISTRIB_RELEASE='24.10.2'\n", ''), '24.10.2');
assert_equal(daemon.parse_openwrt_version("DISTRIB_RELEASE='SNAPSHOT'\n",
	'VERSION_ID="25.12"\n'), '25.12');
assert_equal(daemon.parse_openwrt_version('', 'PRETTY_NAME="OpenWrt 26.01.1 development"\n'),
	'26.01.1');
let manager_probe = fakes.process({
	'/usr/bin/apk:--version': { code: 127 }, '/bin/apk:--version': { code: 1 },
	'/bin/opkg:--version': { code: 0 }
});
assert_equal(platform.detect_package_manager({ process: manager_probe }), 'opkg');
assert_equal(length(manager_probe.calls), 3, 'package manager detection accepted a failed probe');

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
let automatic_update_status = {
	running: true, enabled: true, local_time_valid: true,
	in_maintenance_window: true, last_scheduled_local_date: '2026-07-17',
	last_check: 1, next_check: 1800001, publication_retry_tag: 'v2.0.0',
	publication_retry_count: 1, latest_version: 'v2.0.0', readiness: 'assets_pending',
	pending_target: null, pending_operation_id: null, traffic_samples: 10,
	traffic_quiet: true, traffic_deferral_count: 0, last_error_code: null
};
let application = {
	status: state_model.snapshot, health: state_model.health,
	operation_get: () => null, operation_list: () => [],
	service_start: () => ({ id: 'id' }), service_stop: () => ({ id: 'id' }),
	service_reload: () => ({ id: 'id' }), service_restart: () => ({ id: 'id' }),
	config_list: () => [], config_read: () => '',
	config_read_draft: () => '', config_save_draft: () => ({ id: 'id' }),
	config_validate: () => ({ id: 'id' }), config_apply: () => ({ id: 'id' }),
	operational_settings_apply: () => ({ id: 'id' }),
	config_swap: () => ({ id: 'id' }),
	settings_get: () => ({}), settings_set: () => ({ id: 'id' }),
	guard_transition: () => ({ id: 'id' }),
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
	config: { create: () => { push(order, 'config'); return {
		adopt_external: () => ({ id: 'id' }), read_active: () => ''
	}; } },
	state: { create: () => state_model },
	application: { create: () => application },
	settings: { load: () => ({
		memory: { enabled: false, sample_interval_ms: 60000 },
		notifications: { auto_hide: true, channels: [ 'syslog' ], events: [ 'failure' ] }
	}), validate_patch: (patch) => patch, save: () => ({}) },
	storage: { write_json: () => true },
	memory: { create: () => ({ status: () => ({}), settings: (value) => value ?? {
		sample_interval_ms: 60000 }, reset_baseline: () => true, sample: () => true }) },
	notify: {
		producer: () => { push(failed_trace, 'producer'); return { memory: (event) => event }; },
		create: () => { push(failed_trace, 'notify'); return { emit: () => true, test: () => true }; }
	},
	backup: {
		list: () => [], create: () => ({}), inspect: () => ({}), restore: () => ({}),
		transfer_download: () => ({}), transfer_import: () => ({})
	},
	devices: {
		discover: () => [], timezones: (app) => app.timezones.list(), policy_list: () => [],
		policy_set: () => ({}), policy_delete: () => true,
		effective: () => ({ action: 'inherit' })
	},
	mutation_lock: { with_lock: (runtime, options, worker) => worker({}) },
	subscription: { create: () => ({
		get_redacted: () => ({ configured: false }), set_url: () => ({ id: 'id' }),
		probe: () => ({}), update: () => ({ id: 'id' }), replace: () => ({ id: 'id' })
	}) },
	updates: { create: () => {
		push(order, 'updates.create');
		return { release_info: () => ({}), update_miclash: () => ({ id: 'id' }),
			update_mihomo: () => ({ id: 'id' }), status: () => ({ state: 'idle' }) };
	} },
	app_update_scheduler: { create: (dependencies) => {
		assert_true(dependencies.operations === operation_manager);
		return {
			start: () => { push(order, 'app-update.start'); return true; },
			close: () => { push(order, 'app-update.close'); return true; },
			status: () => automatic_update_status
		};
	} },
	diagnostics: { create: (dependencies) => ({ summary: () => ({ schema_version: 1,
		updates: dependencies.sources.updates() }),
		create_report: () => ({ id: 'rpt_' + sprintf('%032x', 1) }),
		read_report: () => ({ content: '{}' }) }) },
	route_test: { create: () => ({ run: () => ({ decision: 'unknown', steps: [] }) }) },
	routing: { observe: () => ({ rules: [], routes: [] }) },
	api: { create_transfers: () => ({ begin: () => ({}), write: () => ({}), read: () => ({}),
		finish: () => ({}), abort: () => ({}), close: () => true }), register: real_api.register }
};

let process = daemon.compose(rt, factories);
assert_equal(connect_count, 1);
assert_true(index(order, 'recover') < index(order, 'connect'));
assert_true(index(order, 'connect') < index(order, 'config'));
assert_true(index(order, 'config') < index(order, 'publish'));
assert_true(index(order, 'updates.create') < index(order, 'app-update.start'));
let composed_diagnostics = process.app.diagnostics_summary();
assert_equal(composed_diagnostics.updates.state, 'idle');
assert_equal(composed_diagnostics.updates.automatic_miclash.readiness, 'assets_pending');
assert_equal(composed_diagnostics.updates.automatic_miclash.publication_retry_count, 1);
process.drain();
assert_equal(drained, 1);
assert_equal(process.close(), true);
assert_equal(process.close(), false);
assert_equal(disconnect_count, 1);
assert_true(index(order, 'state.close') < index(order, 'state.flush'));
assert_true(index(order, 'app-update.close') < index(order, 'state.close'));
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

// Construction failures after state ownership begins must release and flush the
// state model without replacing the earliest construction error.
let failed_state_lifecycle = [];
let failed_state = {
	snapshot: () => ({}), health: () => ({}), set_desired: () => null,
	observe: () => null,
	close: () => { push(failed_state_lifecycle, 'close'); return true; },
	flush: () => { push(failed_state_lifecycle, 'flush'); return true; }
};
let failed_disconnects = 0;
let failed_transfer_attempts = 0;
let failed_app_update_closes = 0;
let failed_connection = {
	call: () => null, publish: () => ({}),
	disconnect: () => { failed_disconnects++; return true; }
};
let failed_runtime = {
	ubus: { connect: () => failed_connection }, clock: { now: () => 0 },
	paths: { tmp: '/tmp/miclash-construction-failure' },
	reconcile: { run: () => ({}) }
};
let failed_operations = {
	recover_interrupted: () => true, submit: () => ({}), get: () => null,
	list: () => [], subscribe: () => () => true
};
let failed_application = {
	status: failed_state.snapshot, health: failed_state.health,
	operation_get: () => null, operation_list: () => [],
	service_start: () => ({}), service_stop: () => ({}), service_reload: () => ({}),
	service_restart: () => ({}), config_list: () => [], config_read: () => '',
	config_read_draft: () => '', config_save_draft: () => ({}),
	config_validate: () => ({}), config_apply: () => ({}),
	operational_settings_apply: () => ({}), config_swap: () => ({}),
	settings_get: () => ({}),
	settings_set: () => ({}), guard_transition: () => ({}), set_draining: () => true
};
let failed_desired = {
	memory: { enabled: false, sample_interval_ms: 60000 },
	notifications: { auto_hide: true, channels: [ 'syslog' ], events: [ 'failure' ] }
};
let failed_factories = {
	operations: { create: () => failed_operations }, service: { create: () => ({}) },
	history: { create: () => ({}) }, config: { create: () => ({
		adopt_external: () => ({}), read_active: () => ''
	}) },
	state: { create: () => failed_state }, application: { create: () => failed_application },
	settings: { load: () => failed_desired,
		validate_patch: (patch) => patch, save: () => ({}) },
	storage: { write_json: () => true },
	memory: { create: () => ({
		status: () => ({}), settings: (value) => value ?? { sample_interval_ms: 60000 },
		reset_baseline: () => true, sample: () => true
	}) },
	notify: { producer: () => ({ memory: (event) => event }), create: () => ({
		emit: () => true, test: () => true }) },
	backup: { list: () => [], create: () => ({}), inspect: () => ({}),
		restore: () => ({}), transfer_download: () => ({}), transfer_import: () => ({}) },
	devices: { discover: () => [], timezones: () => [ 'UTC' ], policy_list: () => [],
		policy_set: () => ({}), policy_delete: () => true,
		effective: () => ({ action: 'inherit' }) },
	mutation_lock: { with_lock: (runtime, options, worker) => worker({}) },
	subscription: { create: () => ({
		get_redacted: () => ({ configured: false }), set_url: () => ({}),
		probe: () => ({}), update: () => ({}), replace: () => ({})
	}) },
	updates: { create: () => ({
		release_info: () => ({}), update_miclash: () => ({}), update_mihomo: () => ({}),
		status: () => ({ state: 'idle' })
	}) },
	app_update_scheduler: { create: () => ({ start: () => true,
		close: () => { failed_app_update_closes++; return true; }, status: () => ({}) }) },
	diagnostics: factories.diagnostics, route_test: factories.route_test,
	routing: factories.routing,
	api: { create_transfers: () => { failed_transfer_attempts++; die('HEALTH_FAILED'); },
		register: real_api.register }
};
let failed_error = null;
try { daemon.compose(failed_runtime, failed_factories); }
catch (error) { failed_error = error; }
assert_equal(failed_error?.code ?? failed_error?.message, 'HEALTH_FAILED');
assert_equal(length(failed_state_lifecycle), 2);
assert_equal(failed_state_lifecycle[0], 'close');
assert_equal(failed_state_lifecycle[1], 'flush');
assert_equal(failed_disconnects, 1);
assert_equal(failed_transfer_attempts, 1);
assert_equal(failed_app_update_closes, 1);

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
let operation_sequence = 0, operation_records = {}, integrated_operation_listener = null;
let integrated_operation_unsubscribes = 0;
let reconcile_queue = [];
let integrated_operations = {
	recover_interrupted: () => true,
	submit: (kind, source, context, worker) => {
		let id = 'operation-' + (++operation_sequence);
		let record = { id, kind, source, context, state: 'running' };
		operation_records[id] = record;
		if (kind == 'system.reconcile') {
			record.state = 'queued'; record.worker = worker;
			push(reconcile_queue, id); return { id };
		}
		try {
			let result = worker({ id, stage: () => true });
			record.state = 'success'; record.result = result;
		}
		catch (error) {
			if (kind != 'guard.transition') die(error);
			record.state = 'failure'; record.error = { code: error?.code ?? error?.message ?? 'INTERNAL' };
		}
		return { id };
	},
	get: (id) => operation_records[id] ?? null,
	list: () => values(operation_records),
	subscribe: (listener) => {
		integrated_operation_listener = listener;
		return () => { integrated_operation_unsubscribes++; return true; };
	}
};
let desired = {
	core: { subscription_url: 'https://main.example/sub',
		subscription_url_config_yaml: 'https://main.example/sub',
		subscription_url_config2_yaml: 'https://backup.example/sub',
		subscription_url_config3_yaml: '' },
	memory: { enabled: false, sample_interval_ms: 60000 },
	notifications: { auto_hide: true, channels: [ 'syslog', 'luci', 'telegram' ],
		events: [ 'failure', 'subscription_outcome' ] },
	backup: { enabled: false, retention: 5, include_secrets: false,
		interval_hours: 24, schedule_time: '03:00' },
	telegram: { enabled: true, token: '123456:telegram-secret', user_id: '42' }
};
let guard_persist_failures = 0, guard_on_persist_failures = 0;
let integrated_state_updates = 0, integrated_state_failures = 0;
let integrated_state = {
	snapshot: () => ({ desired }), health: () => ({ ready: true }),
	set_desired: (value) => {
		integrated_state_updates++;
		if (integrated_state_failures > 0) { integrated_state_failures--; die('INTERNAL'); }
		desired = value;
	}, observe: () => null,
	close: () => { push(integrated_closes, 'state'); return true; }, flush: () => true
};
let guard_settings_calls = 0;
let guard_settings_value = { sample_interval_ms: 60000 };
let guard_samples = 0;
let guard = {
	status: () => ({ phase: 'monitoring', current_rss_kb: 64000 }),
	settings: (value) => {
		if (value != null) { guard_settings_calls++; guard_settings_value = { ...value }; }
		return { ...guard_settings_value };
	},
	reset_baseline: () => true, sample: () => { guard_samples++; return true; }
};
let emitted_notifications = [], notification_channel_unsubscribes = 0;
let notifier = {
	emit: (event) => { push(emitted_notifications, event); return true; },
	list: (arguments) => ({ generation: 'ng_00000000000000000000000000000001',
		cursor: arguments.cursor, stale: false,
		events: [ { cursor: 1, event: { type: 'subscription_outcome', title: 'Updated',
			message: 'Subscription updated', severity: 'notice' } } ], has_more: false }),
	test: (channel) => channel == 'syslog' || channel == 'luci',
	subscribe: (channel) => {
		assert_equal(channel.name, 'telegram');
		return () => { notification_channel_unsubscribes++; return true; };
	}
};
let telegram_starts = 0, telegram_stops = 0, telegram_tests = 0, telegram_running = false;
let telegram_start_failure = null;
let telegram_facade = null;
let imported_staged = null, backup_app_seen = null, devices_app_seen = null;
let telegram_backend_calls = [];
let auto_backup_attempts = 0, auto_backup_prunes = 0, auto_backup_options = [];
let fail_next_auto_backup = true;
let failed_auto_prune = false, backup_list_calls = 0;
let integrated_swap_transaction = null, integrated_swap_before = null;
let fake_transfers = null;
let guard_actual = false, guard_latched = false, guard_failure_mode = null, guard_backend_calls = [];
let guard_protect_failures = 0;
let integrated_factories = {
	operations: { create: () => integrated_operations },
	service: { create: () => ({
		observe: () => ({ state: 'running' }), start: () => true, stop: () => true, reload: () => true,
		restart_service: () => true, wait_ready: () => ({ ok: guard_actual == desired.guard.enabled,
			components: [
				{ component: 'guard', ready: guard_actual == desired.guard.enabled,
					enabled: guard_actual, observed_at: 1700000000000, generation: 1 },
				{ component: 'dns', ready: true, observed_at: 1700000000000 },
				{ component: 'forward', ready: true, observed_at: 1700000000000 }
			] }),
		recover: () => ({ ok: guard_actual == desired.guard.enabled, stage: 'reload',
			ready: { ok: guard_actual == desired.guard.enabled, components: [
				{ component: 'guard', ready: guard_actual == desired.guard.enabled,
					enabled: guard_actual, observed_at: 1700000000000, generation: 1 },
				{ component: 'dns', ready: true, observed_at: 1700000000000 },
				{ component: 'forward', ready: true, observed_at: 1700000000000 }
			] } })
	}) },
	history: { create: () => ({
		list: () => [], diff: () => ({ text: '' }), open_draft: () => ({ id: 'operation-history' }),
		restore: () => ({ id: 'operation-restore' })
	}) },
	config: { create: () => ({
		list_profiles: () => [ 'config.yaml' ], read_active: () => 'mode: rule\n',
		read_draft: () => 'mode: rule\n', save_draft: () => ({ id: 'operation-draft' }),
		validate: () => ({ id: 'operation-validate' }), apply: () => ({ id: 'operation-apply' }),
		apply_operational: () => ({ id: 'operation-settings-apply' }),
		adopt_external: () => ({ id: 'operation-external-adopt' }),
		swap: (profile, source, transaction) => {
			integrated_swap_transaction = transaction;
			integrated_swap_before = transaction.prepare();
			try { transaction.commit(integrated_swap_before); }
			catch (error) { transaction.rollback(integrated_swap_before); die(error); }
			return { id: 'operation-swap' };
		},
		validate_in_operation: () => ({ ok: true })
	}) },
	state: { create: () => integrated_state },
	application: real_application,
	settings: {
		load: () => desired, validate_patch: (patch) => patch,
		save: (runtime, patch) => {
			if (patch?.guard?.enabled === true && guard_on_persist_failures > 0) {
				guard_on_persist_failures--; die('INTERNAL');
			}
			if (patch?.guard != null && guard_persist_failures > 0) {
				guard_persist_failures--; die('INTERNAL');
			}
			desired = { ...desired, ...patch }; return desired;
		}
	},
	storage: { write_json: () => true },
	memory: { create: () => guard },
	notify: {
		producer: () => ({
			memory: (event) => event,
			backup: (success) => ({ notification: 'backup', success }),
			operation: (record) => ({ notification: 'operation', id: record.id,
				kind: record.kind, state: record.state })
		}),
		telegram_channel: (controller) => ({
			name: 'telegram', minimum_severity: 'info', types: [], components: [],
			send: controller.send_event
		}),
		create: () => notifier
	},
	telegram: { create: (facade) => {
		telegram_facade = facade;
		return {
			start: () => {
				telegram_starts++;
				if (telegram_start_failure == 'throw') die('INTERNAL');
				if (telegram_start_failure == 'false') return false;
				telegram_running = true; return true;
			},
			stop: () => { telegram_stops++; telegram_running = false; return true; },
			status: () => ({ running: telegram_running, configured: true }),
			test: () => { telegram_tests++; return true; },
			send_event: () => true
		};
	} },
	subscription: { create: () => ({
		update: (options, source) => {
			push(telegram_backend_calls, { method: 'subscription', options, source });
			return { id: 'subscription-operation', kind: 'subscription.update' };
		},
		replace: (options, source) => {
			push(telegram_backend_calls, { method: 'subscription', options, source });
			return { id: 'subscription-operation', kind: 'subscription.update' };
		}
	}) },
	updates: { create: () => ({
		status: () => ({ state: 'idle' }), release_info: () => ({}),
		update_miclash: (options, source) => {
			push(telegram_backend_calls, { method: 'miclash', options, source });
			return { id: 'miclash-operation', kind: 'updates.miclash' };
		},
		update_mihomo: (options, source) => {
			push(telegram_backend_calls, { method: 'mihomo', options, source });
			return { id: 'mihomo-operation', kind: 'updates.mihomo' };
		}
	}) },
	app_update_scheduler: { create: () => ({ start: () => true,
		close: () => { push(integrated_closes, 'app-update'); return true; },
		status: () => automatic_update_status }) },
	backup: {
		list: (app) => { backup_list_calls++; backup_app_seen = app; return [ { id: 'b-1700000000000-00000000000000000000000000000000' } ]; },
		create: (app, options, source) => {
			if (source == 'auto') {
				auto_backup_attempts++; push(auto_backup_options, options);
				if (fail_next_auto_backup) { fail_next_auto_backup = false; die('HEALTH_FAILED'); }
			}
			return { id: 'b-1700000000000-00000000000000000000000000000000' };
		},
		prune: () => {
			auto_backup_prunes++;
			if (auto_backup_attempts == 2 && !failed_auto_prune) {
				failed_auto_prune = true; die('INTERNAL');
			}
			return { removed: [], retained: [] };
		},
		inspect: (app, id) => ({ id: 'x-1700000000000-00000000000000000000000000000000', source_id: id }),
		restore: () => ({ id: 'operation-backup-restore' }),
		transfer_download: () => ({ size: 1, sha256: sprintf('%064d', 0), read: () => 'x', finish: () => ({}), close: () => true }),
		transfer_import: (app, staged) => { imported_staged = staged; return { import_id: 'i-1700000000000-00000000000000000000000000000000' }; }
	},
	devices: {
		discover: (app) => { devices_app_seen = app; return [ { mac: '02:00:00:00:00:01' } ]; },
		timezones: (app) => app.timezones.list(), policy_list: () => [],
		policy_set: () => ({ id: 'dp_1_0000000000000000', revision: 1 }),
		policy_delete: () => true, effective: () => ({ action: 'inherit' })
	},
	mutation_lock: { with_lock: (runtime, options, worker) => worker({}) },
	reconcile_adapter: real_reconcile_adapter,
	network: { create: () => ({ apply: () => true, cleanup: () => true }) },
	diagnostics: factories.diagnostics, route_test: factories.route_test,
	routing: factories.routing,
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
let integrated_clock = fakes.clock(1700000000000);
let integrated_runtime = {
	ubus: { connect: () => integrated_connection },
	clock: integrated_clock,
	paths: { tmp: '/tmp/miclash', etc: '/etc/miclash', run: '/var/run/miclash' },
	secure_fs: {}, fs: {}, digest: {}, random: {}, uci: {}, process: { run: () => ({ code: 0 }) },
	observers: { guard: (enabled) => ({ ready: true, state: 'ready', enabled,
		observed_at: integrated_clock.now(), generation: 1 }) },
	guard_control: {
		protect: () => {
			push(guard_backend_calls, 'protect');
			// A refined/capture failure occurs only after the minimal emergency
			// barrier has already been installed and structurally verified.
			guard_actual = true;
			if (guard_protect_failures > 0) { guard_protect_failures--; return false; }
			if (guard_failure_mode == 'protect') return false;
			return true;
		},
		verify_protected: () => guard_actual,
		disable: () => {
			push(guard_backend_calls, 'disable'); guard_latched = false; guard_actual = false;
			return guard_failure_mode != 'disable_after_remove';
		},
		verify: (enabled) => {
			push(guard_backend_calls, 'verify_' + enabled);
			if (guard_failure_mode == 'verify_' + enabled) return false;
			return guard_actual == enabled && desired.guard?.enabled == enabled;
		},
		latch_set: () => { push(guard_backend_calls, 'latch_set'); guard_latched = true; return true; },
		latch_clear: () => { push(guard_backend_calls, 'latch_clear'); guard_latched = false; return true; },
		is_latched: () => guard_latched
	},
	events: fakes.events()
};
let integrated = daemon.compose(integrated_runtime, integrated_factories);
function drain_reconcile() {
	let id = shift(reconcile_queue), record = operation_records[id];
	assert_true(record != null, 'no queued real reconcile operation');
	record.state = 'running';
	try { record.result = record.worker({ stage: () => true }); record.state = 'success'; }
	catch (error) { record.state = 'failure'; record.error = error?.code ?? error?.message; }
	delete record.worker;
	return record;
};
assert_equal(length(filter(integrated_clock.timers, (timer) => timer.active)), 1,
	'backup cleanup owns more than one lifecycle timer');
assert_equal(guard_settings_calls, 0);
assert_true(telegram_facade != null);
assert_equal(telegram_starts, 1);
assert_equal(telegram_facade.subscription_update('https://example.test/sub', 'telegram').id,
	'subscription-operation');
assert_equal(telegram_facade.update_miclash('telegram').id, 'miclash-operation');
assert_equal(telegram_facade.update_mihomo('telegram').id, 'mihomo-operation');
assert_equal(length(telegram_backend_calls), 3);
assert_true(type(telegram_facade.logs_read()) == 'string');
assert_equal(integrated.app.config_swap('config2.yaml', 'luci').id, 'operation-swap');
assert_equal(desired.core.subscription_url_config_yaml, 'https://backup.example/sub');
assert_equal(desired.core.subscription_url_config2_yaml, 'https://main.example/sub');
assert_true(integrated_swap_transaction.rollback(integrated_swap_before));
assert_equal(desired.core.subscription_url_config_yaml, 'https://main.example/sub');
assert_equal(desired.core.subscription_url_config2_yaml, 'https://backup.example/sub');
integrated_state_failures = 1;
assert_throws(() => integrated.app.config_swap('config2.yaml', 'luci'), 'INTERNAL');
assert_equal(desired.core.subscription_url_config_yaml, 'https://main.example/sub');
assert_equal(desired.core.subscription_url_config2_yaml, 'https://backup.example/sub');
// Fresh-install canonical OFF -> LuCI ON uses the typed method and proves real
// backend state, then Telegram traverses the exact same transition function.
let clean_ui_guard_on = integration_methods.guard_transition.call({ args: { enabled: true, source: 'luci' } });
assert_equal(operation_records[clean_ui_guard_on.operation_id].state, 'success');
assert_equal(desired.guard.enabled, true);
assert_equal(guard_actual, true);
assert_equal(guard_latched, false);
assert_true(index(guard_backend_calls, 'latch_set') >= 0 && index(guard_backend_calls, 'latch_clear') >= 0,
	'Guard ON did not bracket risky work with the durable safety latch');
let telegram_guard_record = telegram_facade.guard_transition(false, 'telegram');
assert_equal(operation_records[telegram_guard_record.id].kind, 'guard.transition');
assert_equal(operation_records[telegram_guard_record.id].state, 'success');
assert_equal(desired.guard.enabled, false);
assert_equal(guard_actual, false);
assert_equal(guard_latched, false);
assert_true(index(guard_backend_calls, 'protect') >= 0 && index(guard_backend_calls, 'verify_true') >= 0);
let ui_guard_on = integration_methods.guard_transition.call({ args: { enabled: true, source: 'luci' } });
assert_equal(operation_records[ui_guard_on.operation_id].state, 'success');
assert_equal(desired.guard.enabled, true);
assert_equal(guard_actual, true);

// A failure after Guard removal must roll canonical state back ON and prove
// freshly reinstalled protection before returning the failed operation.
guard_failure_mode = 'disable_after_remove';
let failed_guard_off = integration_methods.guard_transition.call({ args: { enabled: false, source: 'luci' } });
assert_equal(operation_records[failed_guard_off.operation_id].state, 'failure');
assert_equal(desired.guard.enabled, true);
assert_equal(guard_actual, true);
assert_true(length(reconcile_queue) >= 1);
guard_failure_mode = null;
let first_guard_reconcile = drain_reconcile();
assert_equal(first_guard_reconcile.state, 'success', sprintf('reconcile error: %J desired=%J actual=%J latch=%J calls=%J',
	first_guard_reconcile.error, desired.guard, guard_actual, guard_latched, guard_backend_calls));

// A pre-enable backend failure still persists fail-closed repair intent,
// emits a critical Guard incident and never reports success.
let reset_guard_off = integration_methods.guard_transition.call({ args: { enabled: false, source: 'luci' } });
assert_equal(operation_records[reset_guard_off.operation_id].state, 'success');
let transient_calls_before = length(guard_backend_calls);
guard_protect_failures = 1;
let recovered_guard_on = integration_methods.guard_transition.call({ args: { enabled: true, source: 'luci' } });
assert_equal(operation_records[recovered_guard_on.operation_id].state, 'success',
	'transient emergency Guard install failure was not retried synchronously');
assert_true(length(guard_backend_calls) >= transient_calls_before + 3);
let reset_after_transient = integration_methods.guard_transition.call({ args: { enabled: false, source: 'luci' } });
assert_equal(operation_records[reset_after_transient.operation_id].state, 'success');
guard_failure_mode = 'protect';
let failed_guard_on = integration_methods.guard_transition.call({ args: { enabled: true, source: 'luci' } });
assert_equal(operation_records[failed_guard_on.operation_id].state, 'failure');
assert_equal(desired.guard.enabled, true);
assert_equal(guard_actual, true);
assert_equal(guard_latched, true);
assert_true(length(filter(integrated_runtime.events.items, (event) => event.type == 'failure')) >= 1);
guard_failure_mode = null;
guard_actual = true;
assert_equal(drain_reconcile().state, 'success');

// Canonical persistence failures are retried boundedly; the operation fails,
// but real protection and ON repair intent survive.
let prepare_guard_off = integration_methods.guard_transition.call({ args: { enabled: false, source: 'luci' } });
assert_equal(operation_records[prepare_guard_off.operation_id].state, 'success');
guard_persist_failures = 100;
let failed_guard_persist = integration_methods.guard_transition.call({ args: { enabled: true, source: 'luci' } });
assert_equal(operation_records[failed_guard_persist.operation_id].state, 'failure');
assert_equal(desired.guard.enabled, false);
assert_equal(guard_actual, true);
assert_equal(guard_latched, true);
let disables_before_failed_reconcile = length(filter(guard_backend_calls, (name) => name == 'disable'));
assert_equal(drain_reconcile().state, 'failure');
assert_equal(guard_latched, true);
assert_equal(guard_actual, true);
assert_equal(desired.guard.enabled, false);
assert_equal(length(filter(guard_backend_calls, (name) => name == 'disable')),
	disables_before_failed_reconcile, 'ordinary reconcile invoked Guard finalization while latched');
assert_equal(length(reconcile_queue), 0, 'failed real reconcile created a busy retry loop');
guard_persist_failures = 0;
let state_updates_before_repair = integrated_state_updates;
assert_equal(integrated_runtime.reconcile.run('storage-recovered').id != null, true);
assert_equal(drain_reconcile().state, 'success');
assert_equal(desired.guard.enabled, true);
assert_equal(guard_actual, true);
assert_equal(guard_latched, false);
assert_true(integrated_state_updates > state_updates_before_repair,
	'reconcile repaired UCI without refreshing daemon desired state');

// Failure of the final ON proof cannot become false success.
guard_failure_mode = 'verify_true';
let failed_guard_verify_on = integration_methods.guard_transition.call({ args: { enabled: true, source: 'luci' } });
assert_equal(operation_records[failed_guard_verify_on.operation_id].state, 'failure');
assert_equal(desired.guard.enabled, true);
assert_equal(guard_actual, true);
guard_failure_mode = null;
assert_equal(drain_reconcile().state, 'success');

// Failure after successful OFF mutation but before final OFF proof rolls back
// canonical UCI ON and reinstalls exact protection.
guard_failure_mode = 'verify_false';
let failed_guard_verify_off = integration_methods.guard_transition.call({ args: { enabled: false, source: 'luci' } });
assert_equal(operation_records[failed_guard_verify_off.operation_id].state, 'failure');
assert_equal(desired.guard.enabled, true);
assert_equal(guard_actual, true);
guard_failure_mode = null;
assert_equal(drain_reconcile().state, 'success');

// Even if canonical ON cannot be restored after OFF already removed Guard,
// the physical protection must be reinstalled before the failure is returned.
guard_failure_mode = 'disable_after_remove';
guard_on_persist_failures = 100;
let failed_guard_uci_rollback = integration_methods.guard_transition.call({ args: { enabled: false, source: 'luci' } });
assert_equal(operation_records[failed_guard_uci_rollback.operation_id].state, 'failure');
assert_equal(guard_actual, true,
	'rollback UCI failure skipped physical fail-closed Guard restoration');
assert_equal(guard_latched, true);
guard_failure_mode = null;
let disables_before_off_reconcile = length(filter(guard_backend_calls, (name) => name == 'disable'));
assert_equal(drain_reconcile().state, 'failure');
assert_equal(guard_latched, true);
assert_equal(guard_actual, true);
assert_equal(desired.guard.enabled, false);
assert_equal(length(filter(guard_backend_calls, (name) => name == 'disable')),
	disables_before_off_reconcile, 'OFF rollback reconcile removed Guard while latch was active');
guard_on_persist_failures = 0;
assert_true(integrated_runtime.reconcile.run('off-storage-recovered').id != null);
assert_equal(drain_reconcile().state, 'success');
assert_equal(desired.guard.enabled, true);
assert_equal(guard_latched, false);
let successful_guard_off = integration_methods.guard_transition.call({ args: { enabled: false, source: 'luci' } });
assert_equal(operation_records[successful_guard_off.operation_id].state, 'success');
assert_equal(guard_latched, false, 'explicit successful OFF retained the safety latch');
assert_equal(guard_actual, false);

// Exercise the actual post-compose startup path with canonical OFF, no
// physical protection and an armed latch. Guard-only reconciliation repairs
// both persisted desired state and the live state model without Clash health.
guard_latched = true; guard_actual = false;
let integrated_ready = 0;
let integrated_startup = startup_guard.create({
	clock: integrated_runtime.clock,
	guard: integrated_runtime.guard_control,
	reconcile: integrated_runtime.reconcile,
	on_ready: () => { integrated_ready++; return true; }
});
assert_true(integrated_startup.start());
assert_equal(integrated_ready, 1);
assert_true(integrated_startup.start());
assert_equal(integrated_ready, 1, 'repeated startup armed observation twice');
assert_equal(desired.guard.enabled, true);
assert_equal(integrated.state.snapshot().desired.guard.enabled, true);
assert_equal(guard_actual, true);
assert_equal(guard_latched, false);
assert_true(integrated_startup.close());
let reset_after_startup = integration_methods.guard_transition.call({ args: { enabled: false, source: 'luci' } });
assert_equal(operation_records[reset_after_startup.operation_id].state, 'success');
let healthy_memory_set_timeout = integrated_clock.set_timeout;
let timers_before_failed_memory = length(filter(integrated_clock.timers, (timer) => timer.active));
integrated_clock.set_timeout = () => die('timer failed');
assert_throws(() => integrated.app.settings_set({ memory: {
	enabled: true, sample_interval_ms: 120000
} }, 'luci'), 'INTERNAL');
assert_equal(desired.memory.enabled, false);
assert_equal(desired.memory.sample_interval_ms, 60000);
assert_equal(integrated.domains.memory.settings().enabled, false);
assert_equal(integrated.domains.memory.settings().sample_interval_ms, 60000);
assert_equal(length(filter(integrated_clock.timers, (timer) => timer.active)),
	timers_before_failed_memory, 'throwing memory timer changed the live timer set');
integrated_clock.set_timeout = () => null;
assert_throws(() => integrated.app.settings_set({ memory: {
	enabled: true, sample_interval_ms: 180000
} }, 'luci'), 'INTERNAL');
assert_equal(desired.memory.enabled, false);
assert_equal(desired.memory.sample_interval_ms, 60000);
assert_equal(integrated.domains.memory.settings().enabled, false);
assert_equal(integrated.domains.memory.settings().sample_interval_ms, 60000);
assert_equal(length(filter(integrated_clock.timers, (timer) => timer.active)),
	timers_before_failed_memory, 'invalid memory timer changed the live timer set');
integrated_clock.set_timeout = healthy_memory_set_timeout;
// Once enabled, a transient primary timer failure during callback rearm must
// move to the independent fallback and later return to the primary scheduler.
integrated.app.settings_set({ memory: { enabled: true, sample_interval_ms: 60000 } }, 'luci');
let memory_primary = integrated_clock.set_timeout;
assert_equal(type(integrated_clock.set_fallback_timeout), 'function');
let memory_rearm_calls = 0;
integrated_clock.set_timeout = (delay, callback) => {
	memory_rearm_calls++;
	if (memory_rearm_calls == 1) die('transient timer failure');
	return memory_primary(delay, callback);
};
integrated_clock.advance(60000);
assert_equal(guard_samples, 1, 'first Memory Guard timer did not sample');
assert_equal(memory_rearm_calls, 1, 'Memory Guard did not attempt primary rearm');
assert_equal(length(filter(integrated_clock.timers, (timer) => timer.active)), 2,
	sprintf('timers after memory fallback: %J', map(integrated_clock.timers,
		(timer) => ({ due: timer.due, active: timer.active }))));
integrated_clock.advance(60000);
assert_equal(guard_samples, 2, 'Memory Guard fallback did not recover primary rearming');
integrated.app.settings_set({ memory: { enabled: false } }, 'luci');
assert_equal(length(filter(integrated_clock.timers, (timer) => timer.active)), 1,
	'disabling Memory Guard retained its recovered timer');
integrated_clock.set_timeout = memory_primary;
assert_equal(integration_methods.telegram_test.call({ args: {} }).sent, true);
assert_equal(telegram_tests, 1);
assert_true(type(integrated_operation_listener) == 'function');
integrated_operation_listener({ id: 'subscription-finished', kind: 'subscription.update',
	state: 'success', source: 'scheduler', context: {} });
assert_equal(emitted_notifications[length(emitted_notifications) - 1].id,
	'subscription-finished');
let integration_notification_page = integration_methods.notifications_list.call({ args: {
	generation: null, cursor: 0, limit: 10
} });
assert_equal(integration_notification_page.events[0].cursor, 1);
let emitted_before_running = length(emitted_notifications);
integrated_operation_listener({ id: 'subscription-running', kind: 'subscription.update',
	state: 'running', source: 'scheduler', context: {} });
assert_equal(length(emitted_notifications), emitted_before_running);
integrated.app.settings_set({ telegram: { enabled: false } }, 'luci');
assert_equal(telegram_stops, 1);
assert_equal(telegram_running, false);
telegram_start_failure = 'false';
assert_throws(() => integrated.app.settings_set({ telegram: { enabled: true } }, 'luci'),
	'HEALTH_FAILED');
assert_equal(desired.telegram.enabled, false);
assert_equal(integrated.app.telegram_settings().enabled, false);
assert_equal(telegram_running, false);
telegram_start_failure = 'throw';
assert_throws(() => integrated.app.settings_set({ telegram: { enabled: true } }, 'luci'),
	'INTERNAL');
assert_equal(desired.telegram.enabled, false);
assert_equal(integrated.app.telegram_settings().enabled, false);
assert_equal(telegram_running, false);
telegram_start_failure = null;
integrated.app.settings_set({ telegram: { enabled: true } }, 'luci');
assert_equal(telegram_starts, 4);
assert_equal(telegram_running, true);
integrated.app.settings_set({ core: { proxy_mode: 'tun' } }, 'luci');
assert_equal(guard_settings_calls, 0);
integrated.app.settings_set({ backup: { enabled: true, retention: 3,
	include_secrets: false, interval_hours: 1, schedule_time: '03:00' } }, 'luci');
assert_equal(length(filter(integrated_clock.timers, (timer) => timer.active)), 1,
	'backup settings update left duplicate timers');
let schedule_anchor = 3 * 3600000, schedule_interval = 3600000;
let schedule_now = integrated_clock.now();
let schedule_due = schedule_anchor +
	(int((schedule_now - schedule_anchor) / schedule_interval) + 1) * schedule_interval;
integrated_clock.advance(schedule_due - schedule_now - 1);
assert_equal(auto_backup_attempts, 0, 'scheduled backup ignored its UTC anchor');
assert_true(backup_list_calls >= 1, 'proactive import cleanup did not run before the backup interval');
assert_equal(auto_backup_prunes, 1, 'startup maintenance did not enforce persisted retention');
integrated_clock.advance(1);
assert_equal(auto_backup_attempts, 1, 'scheduled backup did not run at its anchored interval');
assert_equal(auto_backup_prunes, 1, 'failed scheduled create unexpectedly changed retention state');
integrated_clock.advance(300000);
assert_equal(auto_backup_attempts, 2, 'failed scheduled backup did not retry with backoff');
assert_equal(auto_backup_prunes, 2, 'successful create did not attempt retention pruning');
integrated_clock.advance(300000);
assert_equal(auto_backup_attempts, 2, 'retention retry created a duplicate backup');
assert_equal(auto_backup_prunes, 3, 'failed retention pruning was not retried');
assert_equal(auto_backup_options[1].include_secrets, false,
	'automatic backup included secrets without the explicit setting');
integrated.app.settings_set({ backup: { enabled: false } }, 'luci');
integrated_clock.advance(7200000);
assert_equal(auto_backup_attempts, 2, 'disabled scheduler created another backup');
let backup_primary = integrated_clock.set_timeout;
integrated_clock.set_timeout = () => null;
let maintenance = filter(integrated_clock.timers, (timer) => timer.active)[0];
integrated_clock.advance(maintenance.due - integrated_clock.now());
assert_equal(length(filter(integrated_clock.timers, (timer) => timer.active)), 1,
	'backup scheduler did not retain exactly one fallback timer after null rearm');
integrated_clock.set_timeout = backup_primary;
integrated_clock.advance(900000);
assert_equal(length(filter(integrated_clock.timers, (timer) => timer.active)), 1,
	'backup scheduler did not recover the primary timer after fallback');
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
assert_equal(length(filter(integrated_clock.timers, (timer) => timer.active)), 0,
	'daemon close retained the backup lifecycle timer');
assert_equal(integrated_disconnects, 1);
assert_true(index(integrated_closes, 'transfers') >= 0);
assert_equal(integrated_operation_unsubscribes, 1);
assert_equal(notification_channel_unsubscribes, 1);
assert_equal(telegram_stops, 4);

// The production composition must construct every management domain and the
// real transfer manager. Only host capabilities are substituted here.
let production_methods = null, production_disconnects = 0;
let production_running = false;
let production_http_healthy = true;
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
let persisted_memory = sprintf('%J\n', {
	version: 2,
	settings: {
		sample_interval_ms: 60000, sustained_samples: 5, warmup_ms: 900000,
		baseline_samples: 6, anomaly_percent: 150, anomaly_growth_kb: 16384,
		reserve_percent: 10, reserve_min_kb: 16384, reserve_max_kb: 65536,
		drop_percent: 10, drop_min_kb: 8192, success_cooldown_ms: 21600000,
		failure_cooldown_ms: 86400000, normal_rearm_ms: 1800000
	},
	state: {
		phase: 'monitoring', pid: 321, start_time: 200, manual_generation: null,
		baseline_started_at: 1699999000000, baseline_rss_kb: 64000,
		current_rss_kb: 65000, pressure_samples: 0, cooldown_until: 0,
		normal_since: null, last_action: null, last_result: null,
		last_sample_at: 1699999999000, mem_total_kb: 262144,
		recovery_sequence: 0, recovery_id: null, active_stage: null
	},
	baseline_samples: []
});
let production_fs = fakes.fs({
	'/proc/sys/kernel/random/boot_id': '11111111-1111-1111-1111-111111111111\n',
	'/proc/self/stat': '123 (ucode) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 200 21 22\n',
	'/proc/net/tcp': '  sl  local_address rem_address   st\n' +
		'   0: 00000000:1EC2 00000000:0000 0A\n' +
		'   1: 00000000:1ED6 00000000:0000 0A\n',
	'/proc/net/tcp6': '  sl  local_address rem_address   st\n' +
		'   0: 00000000000000000000000001000000:1ED6 00000000000000000000000000000000:0000 0A\n',
	'/proc/net/udp': '  sl  local_address rem_address   st\n' +
		'   0: 00000000:1EC2 00000000:0000 07\n' +
		'   1: 00000000:1ED6 00000000:0000 07\n',
	'/proc/net/udp6': '  sl  local_address rem_address   st\n' +
		'   0: 00000000000000000000000001000000:1ED6 00000000000000000000000000000000:0000 07\n',
	'/proc/123/stat': '123 (ucode) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 200 21 22\n',
	'/var/run/miclash/memory.json': persisted_memory,
	'/var/run/miclash/routing-ownership.json': sprintf('%J\n', {
		version: 2, owner: 'miclash', protocol: 242,
		committed: {
			routes: [ { family: 'ipv4', table: 100, kind: 'local',
				destination: 'default', device: 'lo' } ],
			rules: [ { family: 'ipv4', priority: 1000, mark: '0x1',
				mask: '0xffffffff', table: 100 } ]
		}, transition: null
	}),
	'/etc/miclash/dns-ownership.json': sprintf('%J\n', {
		version: 1, owner: 'miclash', section: 'dnsmasq',
		original: {
			server: { present: true, value: [ '127.0.0.1#7874' ] },
			cachesize: { present: true, value: '0' },
			noresolv: { present: true, value: '1' }
		},
		target_preexisting: true, state: 'active', transition: null, clean: null
	}),
	'/var/run/miclash/.keep': '', '/tmp/miclash/.keep': '',
	'/etc/miclash/.keep': '', '/opt/clash/.keep': '',
	'/opt/clash/config.yaml': 'external-controller: 127.0.0.1:9090\n' +
		'proxies:\n' +
		'  - name: upstream\n' +
		'    type: socks5\n' +
		'    server: proxy.example.test\n' +
		'    port: 443\n',
	'/opt/clash/bin/clash': 'binary',
	'/usr/libexec/miclash/validate-config.uc': 'helper',
	'/etc/openwrt_release': "DISTRIB_RELEASE='24.10.2'\nDISTRIB_ARCH='aarch64_cortex-a53'\n",
	'/tmp/sysinfo/model': 'Router Without eth0\n',
	'/sys/class/net/br-lan/address': '02:00:00:00:00:01\n',
	'/sys/class/net/pppoe-wan/address': '02:00:00:00:00:02\n',
	'/proc/net/route': 'Iface\tDestination\tGateway\tFlags\tRefCnt\tUse\tMetric\tMask\n' +
		'pppoe-wan\t00000000\t0101A8C0\t0003\t0\t0\t0\t00000000\n'
});
production_fs.set_mode('/opt/clash', 0o700);
production_fs.set_mode('/opt/clash/config.yaml', 0o600);
production_fs.set_mode('/opt/clash/bin/clash', 0o755);
let production_nft_generation = 'aaaaaaaaaaaa';
let production_routes = { v4_100: true, v6_100: false, v4_rule: true, v6_rule: false };
production_fs.popen = (command, mode) => {
	let output = '[]\n';
	if (index(command, 'ip -j -4 rule show') >= 0)
		output = production_routes.v4_rule ? '[{"priority":1000,"src":"all","fwmark":"0x1","fwmask":"0xffffffff","table":100,"protocol":242}]\n' : '[]\n';
	else if (index(command, 'ip -j -6 rule show') >= 0)
		output = production_routes.v6_rule ? '[{"priority":1000,"src":"all","fwmark":"0x1","fwmask":"0xffffffff","table":100,"protocol":242}]\n' : '[]\n';
	else if (index(command, 'ip -j -4 route show table 100') >= 0)
		output = production_routes.v4_100 ? '[{"type":"local","dst":"default","dev":"lo","table":100,"protocol":242,"scope":"host"}]\n' : '[]\n';
	else if (index(command, 'ip -j -6 route show table 100') >= 0)
		output = production_routes.v6_100 ? '[{"type":"local","dst":"default","dev":"lo","table":100,"protocol":242,"scope":"host"}]\n' : '[]\n';
	else if (index(command, 'nft -j list table inet miclash') >= 0)
		output = '{"nftables":[{"chain":{"family":"inet","table":"miclash","name":"prerouting","type":"filter","hook":"prerouting","prio":-150,"policy":"accept"}},{"rule":{"family":"inet","table":"miclash","chain":"prerouting","expr":[{"jump":{"target":"prerouting_g_' + production_nft_generation + '"}}]}}]}';
	else if (index(command, '/opt/clash/bin/clash -v') >= 0)
		die('system_info must not execute Mihomo through a shell');
	let offset = 0;
	return { read: (amount) => { let chunk = substr(output, offset, amount);
		offset += length(chunk); return chunk; }, close: () => 0 };
};
let production_process = fakes.process({
	'/usr/bin/apk:--version': { code: 127 }, '/bin/apk:--version': { code: 127 },
	'/bin/opkg:--version': { code: 0 }
});
production_process.on_run = (request) => {
	if (request.command == 'nft' && request.args?.[0] == '-f') {
		let batch = production_fs.readfile(request.args[1]) ?? '';
		let found = match(batch, /prerouting_g_([0-9a-f]{12})/);
		if (found != null) production_nft_generation = found[1];
	}
	if (request.command == 'ip' && request.args?.[1] == 'route' && request.args?.[2] == 'replace') {
		if (request.args[0] == '-4') production_routes.v4_100 = true;
		if (request.args[0] == '-6') production_routes.v6_100 = true;
	}
	if (request.command == 'ip' && request.args?.[1] == 'rule' && request.args?.[2] == 'add') {
		if (request.args[0] == '-4') production_routes.v4_rule = true;
		if (request.args[0] == '-6') production_routes.v6_rule = true;
	}
};
let production_runtime = runtime_module.create({
	fs: production_fs,
	digest: fakes.digest(production_fs),
	random: fakes.entropy(),
	clock: production_clock,
	process: production_process,
	uci: fakes.uci({ miclash: {
		core: { '.type': 'core' }, interfaces: { '.type': 'interfaces',
			mode: 'explicit', auto_detect_lan: '1', auto_detect_wan: '1',
			detected_lan: 'br-lan', detected_wan: 'pppoe-wan',
			included: [ 'wlan0' ], excluded: [ 'wwan0' ] },
		guard: { '.type': 'guard' }, memory: { '.type': 'memory' },
		updates: { '.type': 'updates' }, telegram: { '.type': 'telegram' },
		notifications: { '.type': 'notifications' }, backup: { '.type': 'backup' },
		meta: { '.type': 'meta' }
	}, dhcp: { dnsmasq: { '.type': 'dnsmasq', server: [ '127.0.0.1#7874' ],
		cachesize: '0', noresolv: '1' } } }),
	ubus: { connect: () => production_connection },
	http: { request: (request) => ({ status: production_http_healthy ? 200 : 503,
		body: request.path == '/version' ? '{"version":"v1.20.0"}' :
			request.path == '/dns/query?name=domain.example.test&type=A' ?
				'{"Status":0,"Answer":[{"name":"domain.example.test.","type":1,"TTL":60,"data":"198.51.100.10"}]}' :
			request.path == '/dns/query?name=domain.example.test&type=AAAA' ?
				'{"Status":0,"Answer":[]}' : '{}' }) }
});
let production_daemon = daemon.compose(production_runtime);
assert_true(type(production_runtime.rulesets?.validate) == 'function');
assert_true(type(production_runtime.reconcile?.run) == 'function');
assert_true(type(production_methods?.settings_get?.call) == 'function');
assert_true(type(production_methods?.transfer_begin?.call) == 'function');
let production_system = production_methods.system_info.call({ args: {} });
assert_equal(production_system.app_version, '0.9.3');
assert_equal(production_system.openwrt_version, '24.10.2');
assert_equal(production_system.package_manager, 'opkg');
assert_equal(production_system.mihomo.version, '1.20.0');
assert_equal(production_system.hwid,
	substr(production_runtime.digest.sha256('02:00:00:00:00:01|Router Without eth0'), 0, 14));
let production_interfaces = production_methods.network_interfaces.call({ args: {} });
assert_equal(production_interfaces.detected_lan, 'br-lan');
assert_equal(production_interfaces.detected_wan, 'pppoe-wan');
assert_equal(production_methods.memory_status.call({ args: {} }).baseline_rss_kb, 64000);
assert_equal(type(production_methods.devices_list.call({ args: {} })?.devices), 'array',
	'first device discovery must start with an empty daemon cache');
assert_equal(production_methods.devices_timezones.call({ args: {} })[0], 'UTC');
assert_equal(length(production_methods.backup_list.call({ args: {} })), 0);
let production_diagnostics = production_methods.diagnostics_summary.call({ args: {} });
assert_equal(production_diagnostics.schema_version, 1,
	'production daemon did not compose the diagnostics domain: ' + sprintf('%J', production_diagnostics));
let external_adoption = production_methods.config_external_adopt.call({ args: {
	profile: 'config.yaml', source: 'luci'
} });
production_clock.advance(0);
assert_equal(production_daemon.app.operation_get(external_adoption.operation_id).state, 'success',
	'production daemon did not compose external config adoption');
let production_report = production_methods.diagnostics_create_report.call({ args: {} });
assert_match(production_report.id, /^rpt_[0-9a-f]{32}$/,
	'production daemon did not compose diagnostic report creation');
let report_download = production_methods.transfer_begin.call({ args: {
	direction: 'download', kind: 'report', object_id: production_report.id,
	size: 0, sha256: '', metadata: { format: 'json' }
} });
let report_chunk = production_methods.transfer_read.call({ args: {
	transfer_id: report_download.transfer_id, seq: 0
} });
assert_equal(json(b64dec(report_chunk.data)).schema_version, 1,
	'production diagnostic report was not available through the transfer API');
assert_equal(production_methods.transfer_finish.call({ args: {
	transfer_id: report_download.transfer_id
} }).completed, true);
let production_route_test = production_methods.diagnostics_route_test.call({ args: {
	target: '198.51.100.10', device: '', interface: 'br-lan'
} });
assert_equal(production_route_test.steps[0].source, 'input',
	'production daemon did not compose the routing diagnostics domain');
assert_equal(production_route_test.steps[3].source, 'interface_policy');
assert_equal(production_route_test.steps[3].decision, 'PROXY',
	'auto-detected LAN did not use the explicit-mode firewall projection');
let production_route_included = production_methods.diagnostics_route_test.call({ args: {
	target: '198.51.100.10', device: '', interface: 'wlan0'
} });
assert_equal(production_route_included.steps[3].decision, 'PROXY',
	'explicitly included interface did not match the firewall projection');
let production_route_unmatched = production_methods.diagnostics_route_test.call({ args: {
	target: '198.51.100.10', device: '', interface: 'eth9'
} });
assert_equal(production_route_unmatched.steps[3].decision, 'DIRECT',
	'unmatched explicit-mode interface was not diagnosed as direct');
assert_equal(production_route_test.steps[length(production_route_test.steps) - 1].source, 'guard');
let exclude_settings = production_methods.settings_set.call({ args: { settings: { interfaces: {
	mode: 'exclude', auto_detect_lan: true, auto_detect_wan: true,
	detected_lan: 'br-lan', detected_wan: 'pppoe-wan',
	included: [ 'wlan0' ], excluded: [ 'wwan0' ]
} }, source: 'luci' } });
production_clock.advance(0);
assert_equal(production_daemon.app.operation_get(exclude_settings.operation_id).state, 'success');
let production_route_excluded = production_methods.diagnostics_route_test.call({ args: {
	target: '198.51.100.10', device: '', interface: 'pppoe-wan'
} });
assert_equal(production_route_excluded.steps[3].decision, 'DIRECT',
	'auto-detected WAN did not use the exclude-mode firewall projection');
let production_route_proxy_default = production_methods.diagnostics_route_test.call({ args: {
	target: '198.51.100.10', device: '', interface: 'eth9'
} });
assert_equal(production_route_proxy_default.steps[3].decision, 'PROXY',
	'unmatched exclude-mode interface was not diagnosed as proxied');
let production_route_domain = production_methods.diagnostics_route_test.call({ args: {
	target: 'domain.example.test', device: '', interface: 'eth9'
} });
assert_equal(production_route_domain.steps[1].source, 'dns');
assert_equal(production_route_domain.steps[1].evidence.available, true,
	'production route diagnostics did not query Mihomo DNS');
assert_equal(length(production_route_domain.steps[1].evidence.answers), 1,
	'production route diagnostics did not retain bounded DNS evidence');
let production_route_bypass = production_methods.diagnostics_route_test.call({ args: {
	target: 'proxy.example.test', device: '', interface: 'eth9'
} });
assert_equal(production_route_bypass.steps[4].source, 'proxy_server_bypass');
assert_equal(production_route_bypass.steps[4].evidence.matched, true,
	'production route diagnostics did not derive proxy server bypasses from active config');
assert_equal(production_route_bypass.decision, 'DIRECT',
	sprintf('proxy bypass was not final: %J', production_route_bypass));
// The production lifecycle itself must create exactly one restoration event:
// a failed Mihomo/API observation followed by fresh API, DNS, routing and
// applied Guard verification. No test-only event injection is accepted here.
production_http_healthy = false;
let lifecycle_failed = production_runtime.reconcile.run('automatic');
production_clock.advance(0);
assert_equal(production_daemon.app.operation_get(lifecycle_failed.id).state, 'failure');
production_http_healthy = true;
let lifecycle_recovered = production_runtime.reconcile.run('scheduled');
production_clock.advance(0);
assert_equal(production_daemon.app.operation_get(lifecycle_recovered.id).state, 'success',
	sprintf('production reconcile recovery failed: %J', production_daemon.app.operation_get(lifecycle_recovered.id)));
let lifecycle_head = production_methods.notifications_list.call({ args: {
	generation: null, cursor: 0, limit: 20
} });
let lifecycle_page = production_methods.notifications_list.call({ args: {
	generation: lifecycle_head.generation, cursor: 0, limit: 20
} });
let lifecycle_types = map(lifecycle_page.events, (item) => item.event.type);
assert_equal(length(filter(lifecycle_types, (type_name) => type_name == 'internet_restored')), 1,
	'production failure-to-health lifecycle did not dedupe Internet restoration');
assert_true(index(lifecycle_types, 'failure') >= 0 || index(lifecycle_types, 'guard_outage') >= 0,
	'production lifecycle did not record the real failed observation');
let schedule_settings = production_methods.settings_set.call({ args: { settings: { backup: {
	enabled: true, retention: 5, include_secrets: false,
	interval_hours: 1, schedule_time: '03:00'
} }, source: 'luci' } });
production_clock.advance(0);
assert_equal(production_daemon.app.operation_get(schedule_settings.operation_id).state, 'success');
let production_schedule_now = production_clock.now();
let production_schedule_due = schedule_anchor +
	(int((production_schedule_now - schedule_anchor) / schedule_interval) + 1) * schedule_interval;
production_clock.advance(production_schedule_due - production_schedule_now);
assert_equal(length(production_methods.backup_list.call({ args: {} })), 1,
	'real scheduled backup path did not publish an archive');
production_methods.settings_set.call({ args: { settings: { backup: { enabled: false } }, source: 'luci' } });
production_clock.advance(0);
let create_record = production_methods.backup_create.call({ args: {
	options: { include_secrets: true }, source: 'luci'
} });
production_clock.advance(0);
create_record = production_daemon.app.operation_get(create_record.operation_id);
assert_equal(create_record.state, 'success');
let created_backups = production_methods.backup_list.call({ args: {} });
assert_equal(length(created_backups), 2);
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
assert_equal(length(reconciliations), 3);
assert_equal(length(filter(reconciliations, (record) => record.state == 'success')), 2);
assert_equal(length(filter(reconciliations, (record) => record.state == 'failure')), 1);
let upload = production_methods.transfer_begin.call({ args: {
	direction: 'upload', kind: 'backup', metadata: { purpose: 'inspect' },
	size: 1, sha256: sprintf('%064d', 0)
} });
assert_true(type(upload.transfer_id) == 'string');
assert_equal(production_daemon.close(), true);
assert_equal(production_disconnects, 1);
