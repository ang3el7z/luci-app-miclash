import { assert_equal, assert_throws } from 'testlib';
import * as application from 'miclash.application';

let submitted = [];
let sequence = 0;
let operations = {
	submit: (kind, source, context, worker) => {
		let record = { id: 'application-' + (++sequence), kind, source };
		push(submitted, { record, context, worker });
		return record;
	},
	get: (id) => ({ id }),
	list: (filter) => [ { id: 'listed' } ]
};
let actions = [];
let readiness_deadlines = [];
let service_stages = [];
let service = {
	start: (profile) => push(actions, 'start:' + profile),
	stop: (profile) => push(actions, 'stop:' + profile),
	reload: (profile) => { push(actions, 'reload:' + profile); return { ok: true }; },
	restart_service: (profile) => push(actions, 'restart:' + profile),
	recover_network: () => { push(actions, 'recover-network'); return true; },
	wait_ready: (deadline, profile, options) => {
		push(readiness_deadlines, deadline);
		return { ok: true };
	}
};
function notification_value(auto_hide) {
	return { auto_hide,
		syslog_enabled: true, syslog_events: [ 'failure' ],
		luci_enabled: false, luci_events: [ 'recovery' ],
		telegram_enabled: false, telegram_events: [ 'internet_restored' ] };
};
let settings_value = {
	core: { proxy_mode: 'tproxy' },
	memory: { enabled: false, sample_interval_ms: 60000 },
	notifications: notification_value(true),
	telegram: { enabled: false, token: '', user_id: '' }
};
let validated = 0, saved = 0, fail_save = false;
let desired = json(sprintf('%J', settings_value));
let settings = {
	get: () => settings_value,
	validate: (patch) => { validated++; return patch; },
	set: (patch) => {
		saved++;
		if (fail_save)
			die('INTERNAL');
		for (let section, values in patch) {
			settings_value[section] ??= {};
			for (let name, value in values) settings_value[section][name] = value;
		}
		return json(sprintf('%J', settings_value));
	}
};
let config = {
	list_profiles: () => [ 'config.yaml' ],
	read_active: (profile) => 'exact-active\n',
	validate: (profile, content, source) =>
		operations.submit('config.validate', source, { profile }, () => null),
	apply: (profile, content, source) =>
		operations.submit('config.apply', source, { profile }, () => null),
	apply_operational: (profile, content, source, transaction) =>
		operations.submit('settings.apply', source, { profile }, () => {
			let prepared = transaction.prepare();
			return transaction.commit(prepared);
		}),
	swap: (profile, source) =>
		operations.submit('config.swap', source, { profile }, () => null)
};
let state = {
	snapshot: () => ({ status: 'safe' }),
	current: () => ({ status: 'current' }),
	health: () => ({ health: 'safe' }),
	set_desired: (value) => desired = value
};
let management_calls = [];
let memory = {
	status: () => ({ phase: 'monitoring' }),
	settings: () => ({ sample_interval_ms: 60000 }),
	reset_baseline: () => push(management_calls, [ 'memory.reset' ]),
	prepare: (value) => value,
	configure: (value) => push(management_calls, [ 'memory.configure', value ])
};
let devices = {
	list: () => [ { mac: 'aa:bb:cc:dd:ee:ff' } ],
	policy_list: () => [ { id: 'dp_1_0000000000000001', revision: 1 } ],
	policy_set: (policy) => push(management_calls, [ 'devices.set', policy ]),
	policy_delete: (id, revision) => push(management_calls, [ 'devices.delete', id, revision ]),
	timezones: () => [ 'UTC', 'Europe/Berlin' ]
};
let notifications = {
	settings: () => notification_value(true),
	test: (channel) => channel == 'syslog',
	list: (arguments) => ({ generation: 'ng_00000000000000000000000000000001',
		cursor: arguments.cursor, stale: false, events: [], has_more: false }),
	prepare: (value) => value,
	configure: (value) => push(management_calls, [ 'notifications.configure', value ])
};
let telegram = {
	status: () => ({ running: false, configured: false }),
	settings: () => settings_value.telegram,
	test: () => false,
	prepare: (value) => value,
	configure: (value) => push(management_calls, [ 'telegram.configure', value ])
};
let uninstall_scheduled = 0;
let app = application.create({
	operations, service, settings, config, state, memory, devices,
	notifications, telegram,
	system: { schedule_uninstall: () => { uninstall_scheduled++; return true; } },
	clock: { now: () => 1000 }
});

assert_equal(app.status().status, 'safe');
assert_equal(app.overview().status, 'current');
assert_equal(app.health().health, 'safe');
assert_equal(app.operation_get('id').id, 'id');
assert_equal(app.operation_list({})[0].id, 'listed');
assert_equal(app.config_list()[0], 'config.yaml');
assert_equal(app.config_read('config.yaml'), 'exact-active\n');
assert_equal(app.settings_get().core.proxy_mode, 'tproxy');
assert_equal(app.memory_status().phase, 'monitoring');
assert_equal(app.memory_settings().sample_interval_ms, 60000);
assert_equal(app.notifications_list({ generation: null, cursor: 0, limit: 10 }).cursor, 0);
assert_equal(app.devices_list()[0].mac, 'aa:bb:cc:dd:ee:ff');
assert_equal(app.devices_policy_list()[0].revision, 1);
assert_equal(app.devices_timezones()[1], 'Europe/Berlin');
assert_equal(app.notifications_settings().syslog_enabled, true);
assert_equal(app.notifications_test({ channel: 'syslog' }).sent, true);
assert_equal(app.notifications_test({ channel: 'telegram' }).sent, false);

let memory_reset = app.memory_reset_baseline({ source: 'luci' });
submitted[length(submitted) - 1].worker({ stage: () => null });
assert_equal(memory_reset.id, submitted[length(submitted) - 1].record.id);
let policy_set = app.devices_policy_set({ policy: { scope: 'device', action: 'block' }, source: 'luci' });
submitted[length(submitted) - 1].worker({ stage: () => null });
assert_equal(policy_set.id, submitted[length(submitted) - 1].record.id);
let policy_delete = app.devices_policy_delete({ policy_id: 'dp_1_0000000000000001',
	expected_revision: 1, source: 'luci' });
submitted[length(submitted) - 1].worker({ stage: () => null });
assert_equal(policy_delete.id, submitted[length(submitted) - 1].record.id);

for (let action in [ 'start', 'stop', 'reload', 'restart' ]) {
	let before = length(submitted);
	let record = app['service_' + action]('config.yaml', 'luci');
	assert_equal(length(submitted), before + 1);
	assert_equal(record.id, submitted[length(submitted) - 1].record.id);
	submitted[length(submitted) - 1].worker({ stage: (name) => push(service_stages, name) });
}
assert_equal(join(',', actions),
	'start:config.yaml,stop:config.yaml,reload:config.yaml,restart:config.yaml');
assert_equal(join(',', readiness_deadlines), '31000,6000,31000,31000');
assert_equal(join(',', service_stages),
	'service_start,service_start_dispatched,service_start_readiness,ready,' +
	'service_stop,service_stop_dispatched,service_stop_readiness,ready,' +
	'service_reload,service_reload_dispatched,service_reload_readiness,ready,' +
	'service_restart,service_restart_dispatched,service_restart_readiness,ready');
let network_recovery = app.network_recover('luci');
submitted[length(submitted) - 1].worker({ stage: () => null });
assert_equal(network_recovery.id, submitted[length(submitted) - 1].record.id);
assert_equal(actions[length(actions) - 1], 'recover-network');
assert_equal(app.developer_uninstall('luci').accepted, true);
assert_equal(uninstall_scheduled, 1);
assert_throws(() => app.settings_set({ core: { proxy_mode: 'tun' } }, 'luci'), 'BUSY');

// Continue exercising ordinary mutations with a fresh non-draining instance.
app = application.create({
	operations, service, settings, config, state, memory, devices,
	notifications, telegram,
	system: { schedule_uninstall: () => true },
	clock: { now: () => 1000 }
});

let before_config = length(submitted);
app.config_validate('config.yaml', 'valid\n', 'luci');
assert_equal(length(submitted), before_config + 1);
app.config_apply('config.yaml', 'valid\n', 'luci');
assert_equal(length(submitted), before_config + 2);
app.config_swap('config2.yaml', 'luci');
assert_equal(length(submitted), before_config + 3);

let operational_record = app.operational_settings_apply('config.yaml', 'generated\n',
	{ core: { proxy_mode: 'mixed' } }, 'luci');
submitted[length(submitted) - 1].worker({ stage: () => null });
assert_equal(operational_record.id, submitted[length(submitted) - 1].record.id);
assert_equal(settings_value.core.proxy_mode, 'mixed');
assert_throws(() => app.operational_settings_apply('config.yaml', 'generated\n',
	{ guard: { enabled: false } }, 'luci'), 'INVALID_ARGUMENT');

let setting_record = app.settings_set({ core: { proxy_mode: 'tun' } }, 'luci');
assert_equal(validated, 3);
assert_equal(saved, 1);
submitted[length(submitted) - 1].worker({ stage: () => null });
assert_equal(saved, 2);
assert_equal(desired.core.proxy_mode, 'tun');
assert_equal(length(management_calls), 3);
assert_equal(setting_record.id, submitted[length(submitted) - 1].record.id);

let memory_setting = app.settings_set({ memory: {
	enabled: true, sample_interval_ms: 60000
} }, 'luci');
submitted[length(submitted) - 1].worker({ stage: () => null });
assert_equal(memory_setting.id, submitted[length(submitted) - 1].record.id);
assert_equal(management_calls[length(management_calls) - 1][0], 'memory.configure');

let notification_setting = app.settings_set({ notifications: {
	syslog_enabled: true, syslog_events: [ 'failure' ],
	luci_enabled: false, luci_events: [ 'recovery' ],
	telegram_enabled: false, telegram_events: [ 'internet_restored' ], auto_hide: false
} }, 'luci');
submitted[length(submitted) - 1].worker({ stage: () => null });
assert_equal(notification_setting.id, submitted[length(submitted) - 1].record.id);
assert_equal(management_calls[length(management_calls) - 1][0], 'notifications.configure');

fail_save = true;
let failed_setting = app.settings_set({ core: { proxy_mode: 'mixed' } }, 'luci');
assert_throws(() => submitted[length(submitted) - 1].worker({ stage: () => null }), 'INTERNAL');
assert_equal(failed_setting.id, submitted[length(submitted) - 1].record.id);
assert_equal(desired.core.proxy_mode, 'tun');
fail_save = false;

let atomic_value = {
	core: { proxy_mode: 'tproxy' },
	memory: { enabled: false, sample_interval_ms: 60000 },
	notifications: notification_value(true),
	telegram: { enabled: false, token: '', user_id: '' }
};
let atomic_set_calls = 0, fail_memory_prepare = false, fail_notify_prepare = false;
let fail_memory_configure = false, fail_notify_configure = false, fail_state_commit = false;
let atomic_memory = json(sprintf('%J', atomic_value.memory));
let atomic_notifications = json(sprintf('%J', atomic_value.notifications));
let atomic_desired = json(sprintf('%J', atomic_value));
let atomic_memory_configures = 0, atomic_notify_configures = 0;
let atomic_settings = {
	get: () => json(sprintf('%J', atomic_value)),
	validate: (patch) => json(sprintf('%J', patch)),
	set: (patch) => {
		atomic_set_calls++;
		for (let section, values in patch) {
			atomic_value[section] ??= {};
			for (let name, value in values) atomic_value[section][name] = value;
		}
		return json(sprintf('%J', atomic_value));
	}
};
let atomic_memory_domain = {
	status: memory.status, settings: () => atomic_memory, reset_baseline: memory.reset_baseline,
	prepare: (value) => { if (fail_memory_prepare) die('INVALID_ARGUMENT'); return json(sprintf('%J', value)); },
	configure: (value) => {
		atomic_memory_configures++;
		if (fail_memory_configure) die('INTERNAL');
		atomic_memory = json(sprintf('%J', value)); return atomic_memory;
	}
};
let atomic_notification_domain = {
	settings: () => atomic_notifications, test: notifications.test, list: notifications.list,
	prepare: (value) => { if (fail_notify_prepare) die('INVALID_ARGUMENT'); return json(sprintf('%J', value)); },
	configure: (value) => {
		atomic_notify_configures++;
		if (fail_notify_configure) die('INTERNAL');
		atomic_notifications = json(sprintf('%J', value)); return atomic_notifications;
	}
};
let atomic_telegram = json(sprintf('%J', atomic_value.telegram));
let atomic_telegram_domain = {
	status: telegram.status, settings: () => atomic_telegram, test: telegram.test,
	prepare: (value) => json(sprintf('%J', value)),
	configure: (value) => { atomic_telegram = json(sprintf('%J', value)); return atomic_telegram; }
};
let atomic_state = {
	snapshot: state.snapshot, health: state.health,
	set_desired: (value) => {
		if (fail_state_commit) die('INTERNAL');
		atomic_desired = json(sprintf('%J', value)); return true;
	}
};
let atomic_app = application.create({
	operations, service, settings: atomic_settings, config, state: atomic_state,
	memory: atomic_memory_domain, devices, notifications: atomic_notification_domain,
	telegram: atomic_telegram_domain,
	system: { schedule_uninstall: () => true },
	clock: { now: () => 1000 }
});
function run_last() { return submitted[length(submitted) - 1].worker({ stage: () => null }); };

fail_memory_prepare = true;
atomic_app.settings_set({ memory: { enabled: true } }, 'luci');
assert_throws(run_last, 'INVALID_ARGUMENT');
assert_equal(atomic_set_calls, 0);
fail_memory_prepare = false;
fail_notify_prepare = true;
atomic_app.settings_set({ notifications: { auto_hide: false } }, 'luci');
assert_throws(run_last, 'INVALID_ARGUMENT');
assert_equal(atomic_set_calls, 0);
fail_notify_prepare = false;

fail_notify_configure = true;
atomic_app.settings_set({
	memory: { enabled: true }, notifications: { auto_hide: false }
}, 'luci');
assert_throws(run_last, 'INTERNAL');
assert_equal(atomic_set_calls, 2);
assert_equal(atomic_value.memory.enabled, false);
assert_equal(atomic_value.notifications.auto_hide, true);
assert_equal(atomic_memory.enabled, false);
assert_equal(atomic_notifications.auto_hide, true);
assert_equal(atomic_desired.memory.enabled, false);
fail_notify_configure = false;

let memory_before_unrelated = atomic_memory_configures;
let notify_before_unrelated = atomic_notify_configures;
atomic_app.settings_set({ telegram: { enabled: false } }, 'luci');
run_last();
assert_equal(atomic_memory_configures, memory_before_unrelated);
assert_equal(atomic_notify_configures, notify_before_unrelated);

fail_memory_configure = true;
atomic_app.settings_set({ memory: { enabled: true } }, 'luci');
assert_throws(run_last, 'INTERNAL');
assert_equal(atomic_value.memory.enabled, false);
assert_equal(atomic_memory.enabled, false);
assert_equal(atomic_desired.memory.enabled, false);
fail_memory_configure = false;

fail_state_commit = true;
atomic_app.settings_set({
	memory: { enabled: true }, notifications: { auto_hide: false }
}, 'luci');
assert_throws(run_last, 'INTERNAL');
assert_equal(atomic_value.memory.enabled, false);
assert_equal(atomic_value.notifications.auto_hide, true);
assert_equal(atomic_memory.enabled, false);
assert_equal(atomic_notifications.auto_hide, true);
fail_state_commit = false;

app.set_draining(true);
for (let mutation in [
	() => app.service_start('config.yaml', 'luci'),
	() => app.config_validate('config.yaml', 'valid\n', 'luci'),
	() => app.config_swap('config2.yaml', 'luci'),
	() => app.settings_set({}, 'luci'),
	() => app.memory_reset_baseline({ source: 'luci' }),
	() => app.devices_policy_set({ policy: {}, source: 'luci' }),
	() => app.devices_policy_delete({ policy_id: 'dp_1_0000000000000001', expected_revision: 1,
		source: 'luci' })
]) assert_throws(mutation, 'BUSY');
assert_equal(app.status().status, 'safe');
