import { assert_equal, assert_match, assert_true } from 'testlib';
import * as api from 'miclash.api';

let sequence = 0;
function operation(kind) {
	return { id: 'op_' + sprintf('%032x', ++sequence), kind };
};

let last_notification_arguments = null, last_log_arguments = null;
let last_miclash_update_arguments = null, last_mihomo_update_arguments = null;
let app = {
	status: () => ({ state: 'ready' }), overview: () => ({ state: 'current' }),
	health: () => ({ ok: true }),
	operation_get: (id) => ({ id, state: 'success', context: { token: 'secret' } }),
	operation_list: () => [],
	service_start: () => operation('service.start'), service_stop: () => operation('service.stop'),
	service_reload: () => operation('service.reload'), service_restart: () => operation('service.restart'),
	network_recover: () => operation('network.recover'),
	developer_uninstall: () => ({ accepted: true }),
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
	update_release: () => ({ version: 'v2.0.3' }),
	update_miclash: (arguments) => {
		last_miclash_update_arguments = arguments;
		return operation('updates.miclash');
	},
	update_mihomo: (arguments) => {
		last_mihomo_update_arguments = arguments;
		return operation('updates.mihomo');
	},
	update_rollback_mihomo: () => operation('updates.rollback'),
	memory_status: () => ({ phase: 'monitoring' }), memory_settings: () => ({ enabled: true }),
	runtime_metrics: () => ({ running: true, available: true, connections: 3 }),
	memory_reset_baseline: () => operation('memory.reset'), diagnostics_summary: () => ({ ok: true }),
	diagnostics_create_report: () => ({
		operation_id: '0000000001000-00000001-0123456789abcdef',
		report_id: 'rpt_' + sprintf('%032x', 1)
	}),
	diagnostics_route_test: () => ({ decision: 'proxy' }),
	telegram_status: () => ({ running: true }), telegram_settings: () => ({ token: '123:secret' }),
	telegram_test: () => true, devices_list: () => [], devices_timezones: () => [ 'UTC' ],
	telegram_ingest: () => ({ handled: true, retryable: false, last_update_id: 1 }),
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
			stale: false, lines: [ 'Authorization: Bearer raw-secret' ], has_more: false };
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
	'backup_create', 'backup_inspect', 'backup_restore', 'telegram_token_reveal' ])
	assert_equal(methods[removed], null);

assert_equal(methods.status.call({ args: {} }).state, 'ready');
assert_equal(methods.overview.call({ args: {} }).state, 'current');
assert_equal(methods.runtime_metrics.call({ args: {} }).connections, 3);
assert_equal(methods.config_read.call({ args: { profile: 'config.yaml' } }).content, 'mode: rule\n');
assert_true(type(methods.config_apply.call({ args: {
	profile: 'config.yaml', content: 'mode: rule\n', source: 'luci'
} }).operation_id) == 'string');
assert_true(type(methods.network_recover.call({ args: { source: 'luci' } }).operation_id) == 'string');
assert_equal(methods.developer_uninstall.call({ args: { source: 'luci' } }).accepted, true);
assert_equal(methods.config_apply.call({ args: {
	profile: '../config.yaml', content: 'mode: rule\n', source: 'luci'
} }).error.code, 'INVALID_ARGUMENT');
assert_true(type(methods.update_miclash.call({ args: {
	channel: 'release', source: 'luci', action: 'reinstall', version: 'v2.5.4'
} }).operation_id) == 'string');
assert_equal(last_miclash_update_arguments.action, 'reinstall');
assert_equal(last_miclash_update_arguments.version, 'v2.5.4');
assert_true(type(methods.update_mihomo.call({ args: {
	channel: 'release', source: 'luci', action: 'downgrade', version: 'v1.19.10'
} }).operation_id) == 'string');
assert_equal(last_mihomo_update_arguments.action, 'downgrade');
assert_equal(last_mihomo_update_arguments.version, 'v1.19.10');
assert_equal(methods.update_miclash.call({ args: {
	channel: 'release', source: 'luci', action: 'replace', version: 'v2.5.4'
} }).error.code, 'INVALID_ARGUMENT');
assert_equal(methods.telegram_settings.call({ args: {} }).token, '[REDACTED]');
let safe_settings = methods.settings_get.call({ args: {} });
assert_equal(safe_settings.telegram.token, '[REDACTED]');
assert_equal(safe_settings.notifications.syslog_events[0], 'guard_outage');
assert_equal(length(methods.notifications_list.call({ args: {
	generation: '', cursor: 0, limit: 200
} }).events), 0);
assert_equal(last_notification_arguments.generation, null);
assert_equal(methods.logs_read.call({ args: {
	generation: '', cursor: 0, limit: 200
} }).lines[0], 'Authorization: Bearer raw-secret');
assert_equal(last_log_arguments.generation, null);

let created_report = methods.diagnostics_create_report.call({ args: {
	mode: 'lite', acknowledge_secrets: false, source: 'luci'
} });
assert_match(created_report.operation_id, /^[0-9]{13}-/);
assert_match(created_report.report_id, /^rpt_[0-9a-f]{32}$/);
assert_equal(methods.diagnostics_create_report.call({ args: {
	mode: 'full', acknowledge_secrets: false, source: 'luci'
} }).error.code, 'PERMISSION_DENIED');
assert_equal(methods.diagnostics_create_report.call({ args: {
	mode: 'full', acknowledge_secrets: true, source: 'telegram'
} }).error.code, 'PERMISSION_DENIED');

let transfer = methods.transfer_begin.call({ args: {
	direction: 'download', kind: 'report', object_id: 'rpt_' + sprintf('%032x', 1),
	size: 0, sha256: '', metadata: {}
} });
assert_equal(transfer.transfer_id, sprintf('%064x', 1));
assert_equal(transfer_calls[0][0], 'begin');

assert_equal(api.set_draining(app, true), true);
print('api tests passed\n');
