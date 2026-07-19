import { assert_equal, assert_true } from 'testlib';
import * as api from 'miclash.api';

let sequence = 0;
function operation(kind) {
	return { id: 'op_' + sprintf('%032x', ++sequence), kind };
};

let last_notification_arguments = null, last_log_arguments = null;
let app = {
	status: () => ({ state: 'ready' }), health: () => ({ ok: true }),
	operation_get: (id) => ({ id, state: 'success', context: { token: 'secret' } }),
	operation_list: () => [],
	service_start: () => operation('service.start'), service_stop: () => operation('service.stop'),
	service_reload: () => operation('service.reload'), service_restart: () => operation('service.restart'),
	config_list: () => [ 'config.yaml', 'config2.yaml', 'config3.yaml' ],
	config_read: () => 'mode: rule\n', config_validate: () => operation('config.validate'),
	config_apply: () => operation('config.apply'),
	operational_settings_apply: () => operation('settings.apply'),
	config_swap: () => operation('config.swap'),
	settings_get: () => ({
		telegram: { enabled: true, token: '123:secret', user_id: '42' },
		notifications: { syslog_events: [ 'guard_outage', 'failure' ] }
	}),
	settings_set: () => operation('settings.set'), guard_transition: () => operation('guard.transition'),
	set_draining: () => true,
	config_external_adopt: () => operation('config.external_adopt'),
	subscription_get: () => ({ profile: 'config.yaml', url: '' }),
	subscription_set: () => operation('subscription.set'), subscription_update: () => operation('subscription.update'),
	update_release: () => ({ version: 'v2.0.3' }), update_miclash: () => operation('updates.miclash'),
	update_mihomo: () => operation('updates.mihomo'), update_rollback_mihomo: () => operation('updates.rollback'),
	memory_status: () => ({ phase: 'monitoring' }), memory_settings: () => ({ enabled: true }),
	memory_reset_baseline: () => operation('memory.reset'), diagnostics_summary: () => ({ ok: true }),
	diagnostics_create_report: () => ({ report_id: 'rpt_' + sprintf('%032x', 1) }),
	diagnostics_route_test: () => ({ decision: 'proxy' }),
	telegram_status: () => ({ running: true }), telegram_settings: () => ({ token: '123:secret' }),
	telegram_token_reveal: () => ({ token: '123:secret' }),
	telegram_test: () => true, devices_list: () => [], devices_timezones: () => [ 'UTC' ],
	devices_policy_list: () => [], devices_policy_set: () => operation('devices.set'),
	devices_policy_delete: () => operation('devices.delete'),
	notifications_settings: () => ({ auto_hide: true }), notifications_test: () => ({ sent: true }),
	notifications_list: (arguments) => {
		last_notification_arguments = arguments;
		return { generation: 'ng_' + sprintf('%032x', 1), cursor: arguments.cursor,
			stale: false, events: [], has_more: false };
	},
	logs_read: (arguments) => {
		last_log_arguments = arguments;
		return { generation: 'log_' + sprintf('%016x', 1), cursor: arguments.cursor,
			stale: false, lines: [ 'ready' ], has_more: false };
	},
	system_info: () => ({ model: 'Router' }), network_interfaces: () => ({ interfaces: [ 'br-lan' ] }),
	ruleset_list: () => [], ruleset_read: () => ({ content: '' }),
	ruleset_write: () => operation('ruleset.write'), ruleset_delete: () => operation('ruleset.delete'),
	ruleset_apply_whitelist: () => operation('ruleset.whitelist')
};

let transfer_calls = [];
let transfers = {
	begin: (arguments) => { push(transfer_calls, [ 'begin', arguments ]); return {
		transfer_id: sprintf('%064x', 1), chunk_size: 49152, size: 0,
		sha256: sprintf('%064x', 2), expires_at: 1000
	}; },
	write: (arguments) => { push(transfer_calls, [ 'write', arguments ]); return { next_seq: 1, received: 1 }; },
	read: (arguments) => { push(transfer_calls, [ 'read', arguments ]); return { seq: 0, next_seq: 1, data: '', eof: true }; },
	finish: (arguments) => { push(transfer_calls, [ 'finish', arguments ]); return { completed: true }; },
	abort: (arguments) => { push(transfer_calls, [ 'abort', arguments ]); return { aborted: true }; }
};

let methods = api.method_table(app, transfers);
let fixture = json(require('fs').readfile('tests/fixtures/api/methods.json'));
assert_equal(join(',', sort(keys(methods))), join(',', sort(map(fixture.methods, (entry) => entry.name))));
for (let removed in [ 'config_read_draft', 'config_save_draft', 'history_list',
	'history_diff', 'history_open_draft', 'history_restore', 'backup_list',
	'backup_create', 'backup_inspect', 'backup_restore' ])
	assert_equal(methods[removed], null);

assert_equal(methods.status.call({ args: {} }).state, 'ready');
assert_equal(methods.config_read.call({ args: { profile: 'config.yaml' } }).content, 'mode: rule\n');
assert_true(type(methods.config_apply.call({ args: {
	profile: 'config.yaml', content: 'mode: rule\n', source: 'luci'
} }).operation_id) == 'string');
assert_equal(methods.config_apply.call({ args: {
	profile: '../config.yaml', content: 'mode: rule\n', source: 'luci'
} }).error.code, 'INVALID_ARGUMENT');
assert_equal(methods.telegram_settings.call({ args: {} }).token, '[REDACTED]');
assert_equal(methods.telegram_token_reveal.call({ args: {} }).token, '123:secret');
let safe_settings = methods.settings_get.call({ args: {} });
assert_equal(safe_settings.telegram.token, '[REDACTED]');
assert_equal(safe_settings.notifications.syslog_events[0], 'guard_outage');
assert_equal(length(methods.notifications_list.call({ args: {
	generation: '', cursor: 0, limit: 200
} }).events), 0);
assert_equal(last_notification_arguments.generation, null);
assert_equal(methods.logs_read.call({ args: {
	generation: '', cursor: 0, limit: 200
} }).lines[0], 'ready');
assert_equal(last_log_arguments.generation, null);

let transfer = methods.transfer_begin.call({ args: {
	direction: 'download', kind: 'report', object_id: 'rpt_' + sprintf('%032x', 1),
	size: 0, sha256: '', metadata: {}
} });
assert_equal(transfer.transfer_id, sprintf('%064x', 1));
assert_equal(transfer_calls[0][0], 'begin');

assert_equal(api.set_draining(app, true), true);
print('api tests passed\n');
