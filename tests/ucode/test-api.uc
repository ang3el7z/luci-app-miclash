import { assert_equal, assert_match, assert_throws, assert_true } from 'testlib';
import * as api from 'miclash.api';
import * as state from 'miclash.state';
import * as fakes from 'fakes';

function json_equal(actual, expected, message) {
	assert_equal(sprintf('%J', actual), sprintf('%J', expected), message);
};
function structural_equal(actual, expected) {
	if (type(actual) != type(expected)) return false;
	if (type(actual) == 'array') {
		if (length(actual) != length(expected)) return false;
		for (let index = 0; index < length(actual); index++)
			if (!structural_equal(actual[index], expected[index])) return false;
		return true;
	}
	if (type(actual) == 'object') {
		let left = sort(keys(actual)), right = sort(keys(expected));
		if (sprintf('%J', left) != sprintf('%J', right)) return false;
		for (let name in left)
			if (!structural_equal(actual[name], expected[name])) return false;
		return true;
	}
	return actual === expected;
};

let submitted = [];
let records = {};
let sequence = 0;
let operation_subscriber = null;
let operations = {
	submit: (kind, source, context, worker) => {
		let id = sprintf('0000000001000-%08d-0123456789abcdef', ++sequence);
		let record = { id, kind, source, state: 'queued' };
		records[id] = record;
		push(submitted, { kind, source, context, worker, id });
		return { ...record };
	},
	get: (id) => records[id] == null ? null : { ...records[id] },
	list: (filter) => map(values(records), (record) => ({ ...record })),
	subscribe: (callback) => {
		operation_subscriber = callback;
		return () => { operation_subscriber = null; return true; };
	}
};

let settings_value = {
	core: {
		proxy_mode: 'tproxy',
		subscription_url: 'https://user:pass@example.test/sub?token=url-secret'
	},
	telegram: { enabled: true, token: 'telegram-secret', user_id: '42' }
};
let settings_validations = 0;
let settings_saves = 0;
let settings_domain = {
	get: () => settings_value,
	validate: (patch) => {
		settings_validations++;
		if (patch?.core?.proxy_mode == 'bad')
			die('INVALID_ARGUMENT');
		return patch;
	},
	set: (patch) => {
		settings_saves++;
		settings_value = { ...settings_value, ...patch };
		return settings_value;
	}
};

let observed_calls = 0;
let readiness_calls = 0;
let service_actions = [];
let service = {
	observe: (profile) => {
		observed_calls++;
		return { state: 'running', running: true, pid: 17, secret: 'controller-secret' };
	},
	wait_ready: (deadline, profile, options) => {
		readiness_calls++;
		return { ok: true, components: [ { component: 'process', state: 'ready', ready: true } ] };
	},
	start: (profile) => push(service_actions, 'start:' + profile),
	stop: (profile) => push(service_actions, 'stop:' + profile),
	reload: (profile) => { push(service_actions, 'reload:' + profile); return { ok: true }; },
	restart_service: (profile) => push(service_actions, 'restart:' + profile)
};

let config_calls = [];
let config = {
	list_profiles: () => [ 'config.yaml', 'config2.yaml', 'config3.yaml' ],
	read_active: (profile) =>
		'external-controller: 127.0.0.1:9090\nsecret: controller-secret\n' +
		'proxy-provider: https://user:pass@example.test/sub?token=config-secret\n',
	read_draft: (profile) => 'draft: true\n',
	save_draft: (profile, content, source) => {
		push(config_calls, { method: 'save_draft', profile, content, source });
		return operations.submit('config.save_draft', source, { profile }, () => null);
	},
	validate: (profile, content, source) => {
		push(config_calls, { method: 'validate', profile, content, source });
		return operations.submit('config.validate', source, { profile }, () => null);
	},
	apply: (profile, content, source) => {
		push(config_calls, { method: 'apply', profile, content, source });
		return operations.submit('config.apply', source, { profile }, () => null);
	}
};

let stored_state = null;
let now = 1000;
let state_model = state.create({
	settings: settings_domain,
	service,
	operations,
	clock: { now: () => now },
	store: { write: (snapshot) => stored_state = snapshot }
});

// Desired state is normalized at startup, observations are explicit, health is cached/read-only.
assert_equal(observed_calls, 0);
state_model.observe('config.yaml');
assert_equal(observed_calls, 1);
assert_equal(readiness_calls, 1);
let before_health_observations = observed_calls;
let health = state_model.health();
assert_equal(observed_calls, before_health_observations);
assert_equal(health.observed.service.secret, '[REDACTED]');
assert_equal(index(sprintf('%J', health), 'controller-secret'), -1);

// State snapshots are defensive, redacted and subscription failures are isolated.
let first_events = [], second_events = [];
state_model.subscribe((event) => { push(first_events, event); event.desired.core.proxy_mode = 'tampered'; });
state_model.subscribe((event) => die('subscriber failed'));
state_model.subscribe((event) => push(second_events, event));
operation_subscriber({
	id: 'safe-operation', kind: 'config.apply', source: 'luci', state: 'failure',
	error: { code: 'INTERNAL', message: 'raw controller-secret', token: 'operation-secret' }
});
assert_true(length(first_events) > 0);
assert_equal(second_events[length(second_events) - 1].desired.core.proxy_mode, 'tproxy');
let snapshot = state_model.snapshot();
assert_equal(snapshot.desired.telegram.token, '[REDACTED]');
assert_equal(snapshot.desired.core.subscription_url,
	'[REDACTED]');
for (let secret in [ 'telegram-secret', 'url-secret', 'controller-secret', 'operation-secret' ])
	assert_equal(index(sprintf('%J', snapshot), secret), -1);
snapshot.desired.core.proxy_mode = 'tampered';
assert_equal(state_model.snapshot().desired.core.proxy_mode, 'tproxy');
assert_equal(state_model.flush(), true);
for (let secret in [ 'telegram-secret', 'url-secret', 'controller-secret', 'operation-secret' ])
	assert_equal(index(sprintf('%J', stored_state), secret), -1);

// A clock tick between a zero-deadline sample and service validation is an
// unavailable readiness observation, not a failed observation timer.
let racing_state = state.create({
	settings: settings_domain,
	service: {
		observe: service.observe,
		wait_ready: (deadline, profile, options) => die('INVALID_ARGUMENT')
	},
	operations,
	clock: { now: () => 1999 },
	store: { write: (value) => true }
});
let racing_observed = racing_state.observe('config.yaml');
assert_equal(racing_observed.readiness.state, 'unknown');
racing_state.close();

let published = null;
let connection = {
	publish: (name, methods) => {
		published = { name, methods };
		return { registered: true };
	}
};
let application_draining = false;
function application_writable() {
	if (application_draining)
		die('BUSY');
};
function application_service(action, profile, source) {
	application_writable();
	return operations.submit('service.' + action, source, { profile }, (ctx) => {
		ctx.stage('service_' + action, 20, '');
		service[action == 'restart' ? 'restart_service' : action](profile);
		service.wait_ready(6000, profile, action == 'stop' ? { stopped: true } : {});
	});
};
let app = {
	status: () => state_model.snapshot(),
	health: () => state_model.health(),
	operation_get: (id) => operations.get(id),
	operation_list: (filter) => operations.list(filter),
	service_start: (profile, source) => application_service('start', profile, source),
	service_stop: (profile, source) => application_service('stop', profile, source),
	service_reload: (profile, source) => application_service('reload', profile, source),
	service_restart: (profile, source) => application_service('restart', profile, source),
	config_list: () => config.list_profiles(),
	config_read: (profile) => config.read_active(profile),
	config_read_draft: (profile) => config.read_draft(profile),
	config_save_draft: (profile, content, source) => {
		application_writable(); return config.save_draft(profile, content, source);
	},
	config_validate: (profile, content, source) => {
		application_writable(); return config.validate(profile, content, source);
	},
	config_apply: (profile, content, source) => {
		application_writable(); return config.apply(profile, content, source);
	},
	settings_get: () => settings_domain.get(),
	settings_set: (patch, source) => {
		application_writable();
		patch = settings_domain.validate(patch);
		return operations.submit('settings.set', source, {}, (ctx) => {
			ctx.stage('settings', 20, '');
			state_model.set_desired(settings_domain.set(patch));
		});
	},
	telegram_status: () => ({
		running: true, configured: true, token: 'telegram-secret', user_id: '42'
	}),
	telegram_settings: () => settings_domain.get().telegram,
	telegram_test: () => true,
	notifications_list: (arguments) => ({
		generation: arguments.generation ?? 'ng_00000000000000000000000000000001',
		cursor: arguments.cursor, stale: false, events: [], has_more: false
	}),
	devices_timezones: () => [ 'UTC', 'Europe/Berlin' ],
	set_draining: (value) => application_draining = value
};
let methods = api.method_table(app);
let names = sort(keys(methods));
json_equal(names, sort([
	'status', 'health', 'operation_get', 'operation_list', 'operation_start',
	'service_start', 'service_stop', 'service_reload', 'service_restart',
	'config_list', 'config_read', 'config_read_draft', 'config_save_draft',
	'config_validate', 'config_apply',
	'config_external_adopt', 'settings_get', 'settings_set',
	'history_list', 'history_diff', 'history_open_draft', 'history_restore',
	'subscription_get', 'subscription_set', 'subscription_update', 'subscription_probe',
	'update_release', 'update_miclash', 'update_mihomo', 'update_rollback_mihomo',
	'memory_status', 'memory_reset_baseline', 'memory_settings',
	'diagnostics_summary', 'diagnostics_create_report', 'diagnostics_route_test',
	'backup_list', 'backup_create', 'backup_inspect', 'backup_restore',
	'telegram_status', 'telegram_settings', 'telegram_test',
	'devices_list', 'devices_timezones', 'devices_policy_list', 'devices_policy_set', 'devices_policy_delete',
	'notifications_settings', 'notifications_test', 'notifications_list',
	'transfer_begin', 'transfer_write', 'transfer_read', 'transfer_finish', 'transfer_abort'
]));
assert_equal(api.register(connection, app).registered, true);
assert_equal(published.name, 'miclash');
json_equal(sort(keys(published.methods)), names);

// Before the Task 7 one-jump cutover, the transport publishes safe Telegram
// reads/test=false without requiring daemon/application composition.
let unwired_app = { ...app };
delete unwired_app.telegram_status;
delete unwired_app.telegram_settings;
delete unwired_app.telegram_test;
let unwired_methods = api.method_table(unwired_app);
assert_equal(unwired_methods.telegram_status.call({ args: {} }).running, false);
assert_equal(unwired_methods.telegram_status.call({ args: {} }).configured, true);
assert_equal(unwired_methods.telegram_settings.call({ args: {} }).token, '[REDACTED]');
assert_equal(unwired_methods.telegram_settings.call({ args: {} }).user_id, '42');
json_equal(unwired_methods.telegram_test.call({ args: {} }), { sent: false });

function invoke(name, args) {
	return methods[name].call({ args: args ?? {} });
};

// Published policies are exact and compatible with ucode ubus type hints.
json_equal(methods.status.args, {});
json_equal(methods.operation_get.args, { operation_id: '' });
json_equal(methods.service_start.args, { profile: '', source: '' });
json_equal(methods.config_validate.args, { profile: '', content: '', source: '' });
json_equal(methods.config_read_draft.args, { profile: '' });
json_equal(methods.config_save_draft.args, { profile: '', content: '', source: '' });
json_equal(methods.history_open_draft.args, { profile: '', revision: '', source: '' });
json_equal(methods.settings_set.args, { settings: {}, source: '' });
json_equal(methods.telegram_status.args, {});
json_equal(methods.telegram_settings.args, {});
	json_equal(methods.telegram_test.args, {});
	json_equal(methods.notifications_list.args, { generation: '', cursor: 0, limit: 0 });
for (let name in names) {
	assert_equal(type(methods[name].call), 'function');
	assert_equal(type(methods[name].args), 'object');
	for (let forbidden in [ 'command', 'path', 'controller', 'secret', 'token' ])
		assert_equal(exists(methods[name].args, forbidden), false, name + ' exposes ' + forbidden);
}

// Reads are immediate, defensive and never expose configured credentials.
let status_reply = invoke('status');
assert_equal(status_reply.desired.telegram.token, '[REDACTED]');
let settings_reply = invoke('settings_get');
assert_equal(settings_reply.telegram.token, '[REDACTED]');
assert_equal(settings_reply.core.subscription_url, '[REDACTED]');
let config_reply = invoke('config_read', { profile: 'config.yaml' });
assert_equal(config_reply.profile, 'config.yaml');
assert_equal(config_reply.content,
	'external-controller: 127.0.0.1:9090\nsecret: controller-secret\n' +
	'proxy-provider: https://user:pass@example.test/sub?token=config-secret\n');
for (let secret in [ 'telegram-secret', 'controller-secret', 'config-secret' ])
	assert_equal(index(sprintf('%J', [ status_reply, settings_reply ]), secret), -1);
settings_reply.core.proxy_mode = 'tampered';
assert_equal(invoke('settings_get').core.proxy_mode, 'tproxy');
assert_equal(index(sprintf('%J', invoke('telegram_status')), 'telegram-secret'), -1);
assert_equal(invoke('telegram_status').user_id, '42');
assert_equal(invoke('telegram_settings').token, '[REDACTED]');
json_equal(invoke('telegram_test'), { sent: true });

// Domain config mutations already submit; the transport returns only their durable ID.
let before_submits = length(submitted);
let validate_reply = invoke('config_validate', {
	profile: 'config2.yaml', content: 'mode: rule\n', source: 'luci'
});
assert_match(validate_reply.operation_id, /^[A-Za-z0-9._-]+$/);
assert_equal(length(submitted), before_submits + 1);
assert_equal(config_calls[length(config_calls) - 1].method, 'validate');
json_equal(keys(validate_reply), [ 'operation_id' ]);
let apply_reply = invoke('config_apply', { profile: 'config.yaml', content: 'mode: direct\n' });
json_equal(keys(apply_reply), [ 'operation_id' ]);
assert_equal(config_calls[length(config_calls) - 1].source, 'luci');
assert_equal(invoke('config_read_draft', { profile: 'config.yaml' }).content, 'draft: true\n');
let save_draft_reply = invoke('config_save_draft', {
	profile: 'config.yaml', content: 'draft: changed\n', source: 'luci'
});
json_equal(keys(save_draft_reply), [ 'operation_id' ]);
assert_equal(config_calls[length(config_calls) - 1].method, 'save_draft');

// Service/settings mutations are wrapped exactly once in the same FIFO.
for (let name in [ 'service_start', 'service_stop', 'service_reload', 'service_restart' ]) {
	let count = length(submitted);
	let reply = invoke(name, {});
	json_equal(keys(reply), [ 'operation_id' ]);
	assert_equal(length(submitted), count + 1);
}
let settings_count = length(submitted);
let settings_reply_id = invoke('settings_set', {
	settings: { core: { proxy_mode: 'tun' } }, source: 'luci'
});
json_equal(keys(settings_reply_id), [ 'operation_id' ]);
assert_equal(length(submitted), settings_count + 1);
assert_equal(settings_validations, 1);
submitted[length(submitted) - 1].worker({
	id: settings_reply_id.operation_id,
	stage: () => null,
	complete: () => null
});
assert_equal(settings_saves, 1);

// Strict callbacks reject unknown/wrong/oversized inputs before any submission.
function assert_invalid(name, args) {
	let count = length(submitted);
	let reply = invoke(name, args);
	assert_equal(reply.error.code, 'INVALID_ARGUMENT', name);
	assert_equal(reply.error.message, 'INVALID_ARGUMENT');
	assert_equal(length(submitted), count);
	assert_equal(index(sprintf('%J', reply), 'raw'), -1);
};
assert_invalid('status', { command: '/bin/sh' });
assert_invalid('service_start', { path: '/etc/init.d/clash' });
assert_invalid('service_start', { profile: 'config4.yaml' });
assert_invalid('service_start', { source: 'auto' });
assert_invalid('config_validate', { profile: 'config.yaml', content: '', source: 'luci' });
assert_invalid('config_apply', { profile: 'config.yaml', content: sprintf('%01048577d', 0) });
assert_invalid('operation_get', {});
assert_invalid('operation_get', { operation_id: '../bad' });
assert_invalid('operation_list', { state: 'raw-state' });
assert_invalid('settings_set', { settings: { core: { proxy_mode: 'bad' } } });

// Draining rejects every new mutation with BUSY while reads remain available.
api.set_draining(app, true);
for (let name in [ 'service_start', 'service_stop', 'service_reload', 'service_restart',
	'config_save_draft', 'config_validate', 'config_apply', 'settings_set' ]) {
	let args = name == 'settings_set' ? { settings: {} } :
		(index(name, 'config_') == 0 ? { profile: 'config.yaml', content: 'mode: rule\n' } : {});
	assert_equal(invoke(name, args).error.code, 'BUSY', name);
}
assert_true(invoke('status').desired != null);
assert_true(invoke('operation_list').operations != null);
state_model.close();
assert_equal(operation_subscriber, null);

// The canonical fixture is the single parity contract shared with the Node UI check.
let canonical = json(require('fs').readfile('tests/fixtures/api/methods.json')).methods;
let transfer_fixture = json(require('fs').readfile('tests/fixtures/api/transfers.json'));
json_equal(sort(map(canonical, (entry) => entry.name)), names);
for (let entry in canonical)
	json_equal(sort(keys(methods[entry.name].args)), sort(entry.params),
		entry.name + ' backend policy differs from canonical params');
assert_equal(invoke('transfer_abort', { transfer_id: sprintf('%064x', 1) }).error.code,
	'HEALTH_FAILED');

// Every canonical method executes through exactly one typed delegate. The same
// table proves unknown fields are rejected before any delegate is reached and
// operation/read reply shapes follow the fixture operation flag.
function valid_contract_arguments(entry) {
	let values = {
		operation_id: 'op-valid', state: 'queued', kind: 'service.start', source: 'luci',
		arguments: { profile: 'config.yaml' }, profile: 'config.yaml', content: 'mode: rule\n',
		settings: {}, limit: 10, from_revision: 'rev-from', to_revision: 'rev-to',
		revision: 'rev-one', url: 'https://example.test/subscription', channel: 'stable',
		generation: 'ng_00000000000000000000000000000001', cursor: 0,
		target: 'example.test', device: 'AA:BB:CC:DD:EE:FF', interface: 'lan', options: {},
		backup_id: 'b-0000000005000-' + sprintf('%032x', 4),
		inspection_id: 'x-0000000005000-' + sprintf('%032x', 5),
		policy: { mac: 'AA:BB:CC:DD:EE:FF', mode: 'proxy' },
		policy_id: 'dp_1_0000000000000001', expected_revision: 1,
		direction: 'upload', object_id: '', size: 1,
		sha256: sprintf('%064x', 7), metadata: {}, transfer_id: sprintf('%064x', 8),
		seq: 0, data: b64enc('x')
	};
	if (entry.name == 'update_release') values.kind = 'miclash';
	let arguments = {};
	for (let name in entry.params) arguments[name] = values[name];
	return arguments;
};
function expected_delegate_arguments(name, arguments) {
	if (name == 'status' || name == 'health' || name == 'config_list' ||
		name == 'settings_get' || name == 'telegram_status' ||
		name == 'telegram_settings' || name == 'telegram_test') return [];
	if (name == 'operation_get') return [ arguments.operation_id ];
	if (name == 'operation_list') return [ arguments ];
	if (index(name, 'service_') == 0) return [ arguments.profile, arguments.source ];
	if (name == 'config_read' || name == 'config_read_draft') return [ arguments.profile ];
	if (name == 'config_save_draft' || name == 'config_validate' || name == 'config_apply')
		return [ arguments.profile, arguments.content, arguments.source ];
	if (name == 'settings_set') return [ arguments.settings, arguments.source ];
	return [ arguments ];
};
let delegation = [], contract_sequence = 100;
let contract_app = { ...app };
function contract_delegate(name, operation) {
	return (...args) => {
		push(delegation, { name, args });
		if (name == 'telegram_test') return true;
		if (operation)
			return { id: sprintf('0000000005000-%08d-0123456789abcdef', ++contract_sequence) };
		if (name == 'config_list') return [ { marker: 'read:' + name } ];
		if (name == 'config_read' || name == 'config_read_draft') return 'read:' + name;
		if (name == 'operation_list') return [ { marker: 'read:' + name } ];
		return { marker: 'read:' + name };
	};
};
for (let entry in canonical) {
	if (index(entry.name, 'transfer_') == 0) continue;
	contract_app[entry.name] = contract_delegate(entry.name, entry.operation);
}
let contract_transfers = {};
function transfer_delegate(method_name) {
	return (arguments) => {
		push(delegation, { name: 'transfer_' + method_name, args: [ arguments ] });
		return { marker: 'read:transfer_' + method_name };
	};
};
for (let method_name in [ 'begin', 'write', 'read', 'finish', 'abort' ])
	contract_transfers[method_name] = transfer_delegate(method_name);
let contract_methods = api.method_table(contract_app, contract_transfers);
function expected_read_reply(entry, arguments) {
	let marker = { marker: 'read:' + entry.name };
	if (entry.name == 'operation_get') return { operation: marker };
	if (entry.name == 'operation_list') return { operations: [ marker ] };
	if (entry.name == 'config_list') return { profiles: [ marker ] };
	if (entry.name == 'config_read' || entry.name == 'config_read_draft')
		return { profile: arguments.profile, content: 'read:' + entry.name };
	if (entry.name == 'telegram_test') return { sent: true };
	return marker;
};
for (let entry in canonical) {
	let arguments = valid_contract_arguments(entry), before = length(delegation);
	let reply = contract_methods[entry.name].call({ args: arguments });
	assert_equal(length(delegation), before + 1, entry.name + ' delegate count');
	assert_equal(delegation[before].name, entry.name, entry.name + ' delegate name');
	assert_true(structural_equal(delegation[before].args,
		expected_delegate_arguments(entry.name, arguments)),
		entry.name + ' normalized delegate arguments');
	if (entry.operation) json_equal(keys(reply), [ 'operation_id' ], entry.name + ' operation reply');
	else {
		assert_equal(reply?.error, null, entry.name + ' read returned an error');
		assert_true(structural_equal(reply, expected_read_reply(entry, arguments)),
			entry.name + ' read success shape/marker');
	}
	let invalid = { ...arguments, unexpected: true };
	let rejected = contract_methods[entry.name].call({ args: invalid });
	assert_equal(rejected.error.code, 'INVALID_ARGUMENT', entry.name + ' accepted unknown field');
	assert_equal(length(delegation), before + 1, entry.name + ' delegated unknown field');
}
assert_equal(contract_methods.operation_start.call({ args: {
	kind: 'arbitrary.shell', arguments: {}, source: 'luci'
} }).error.code, 'INVALID_ARGUMENT');
assert_equal(contract_methods.subscription_set.call({ args: {
	profile: 'config.yaml', url: 'http://', source: 'luci'
} }).error.code, 'INVALID_ARGUMENT');
assert_equal(contract_methods.subscription_probe.call({ args: {
	profile: 'config.yaml', url: 'https://user@example.test/path'
} }).error.code, 'INVALID_ARGUMENT');
assert_equal(contract_methods.devices_policy_delete.call({ args: {
	policy_id: 'not-an-id', expected_revision: 1, source: 'luci'
} }).error.code, 'INVALID_ARGUMENT');
assert_equal(contract_methods.history_list.call({ args: {
	profile: 'config.yaml', limit: 101
} }).error.code, 'INVALID_ARGUMENT');
assert_equal(contract_methods.diagnostics_route_test.call({ args: {
	target: sprintf('%0513d', 0), device: '', interface: ''
} }).error.code, 'INVALID_ARGUMENT');
assert_equal(contract_methods.backup_create.call({ args: {
	options: { note: sprintf('%05000d', 0) }, source: 'luci'
} }).error.code, 'RESPONSE_TOO_LARGE');

// Chunk transfers are a bounded, pathless adapter: the caller receives only a
// 256-bit opaque ID and the upload domain receives only a reader capability.
let transfer_fs = fakes.fs({}), transfer_clock = fakes.clock(5000);
let transfer_runtime = {
	fs: transfer_fs, clock: transfer_clock, random: fakes.entropy(),
	digest: fakes.digest(transfer_fs), paths: { tmp: '/tmp/miclash' }
};
let imported = null;
let download_verified = false;
let transfer = api.create_transfers({
	runtime: transfer_runtime,
	uploads: {
		backup: (staged) => {
			let content = '', chunk;
			while (length(chunk = staged.read(4))) content += chunk;
			imported = { content, kind: staged.kind, metadata: staged.metadata,
				size: staged.size, sha256: staged.sha256 };
			return { import_id: 'i-0000000005000-' + sprintf('%032x', 1) };
		}
	},
	downloads: {
		report: (id, metadata) => {
			if (id != transfer_fixture.report_id) die('NOT_FOUND');
			let content = 'diagnostic', served = '';
			return {
				size: length(content), sha256: transfer_runtime.digest.sha256(content),
				read: (offset, amount) => {
					let chunk = substr(content, offset, amount); served += chunk; return chunk;
				},
				finish: () => {
					download_verified = served == content;
					return { size: length(served), sha256: transfer_runtime.digest.sha256(served) };
				},
				close: () => true
			};
		},
		backup: (id) => {
			if (id != transfer_fixture.backup_id) die('NOT_FOUND');
			let content = 'backup', served = '';
			return { size: length(content), sha256: transfer_runtime.digest.sha256(content),
				read: (offset, amount) => {
					let chunk = substr(content, offset, amount); served += chunk; return chunk;
				},
				finish: () => ({ size: length(served),
					sha256: transfer_runtime.digest.sha256(served) }), close: () => true };
		}
	}
});
let payload = 'hello world', payload_hash = transfer_runtime.digest.sha256(payload);
let begun = transfer.begin({ direction: 'upload', kind: 'backup', object_id: '',
	size: length(payload), sha256: payload_hash, metadata: { secrets: false } });
assert_match(begun.transfer_id, /^[0-9a-f]{64}$/);
assert_true(begun.chunk_size > 0 && begun.chunk_size <= 49152);
assert_equal(transfer_runtime.random.calls[0], 32);
json_equal(transfer.write({ transfer_id: begun.transfer_id, seq: 0,
	data: b64enc('hello ') }), { next_seq: 1, received: 6 });
assert_equal(transfer.write({ transfer_id: begun.transfer_id, seq: 2,
	data: b64enc('world') }).error.code, 'INVALID_ARGUMENT');
json_equal(transfer.write({ transfer_id: begun.transfer_id, seq: 1,
	data: b64enc('world') }), { next_seq: 2, received: 11 });
let finalized = transfer.finish({ transfer_id: begun.transfer_id });
assert_equal(finalized.completed, true);
assert_equal(finalized.result.import_id, 'i-0000000005000-' + sprintf('%032x', 1));
assert_equal(imported.content, payload);
assert_equal(imported.kind, 'backup');
assert_equal(imported.metadata.secrets, false);
assert_equal(imported.sha256, payload_hash);
assert_equal(index(sprintf('%J', finalized), '/tmp/'), -1);

// Replay, wrong sequence, real same-size hash mismatch, overflow and expiry all fail closed.
assert_equal(transfer.finish({ transfer_id: begun.transfer_id }).error.code, 'NOT_FOUND');
let mismatch = transfer.begin({ direction: 'upload', kind: 'backup', object_id: '',
	size: 3, sha256: transfer_runtime.digest.sha256('bad'), metadata: {} });
assert_equal(transfer.write({ transfer_id: mismatch.transfer_id, seq: 0,
	data: b64enc('good') }).error.code, 'RESPONSE_TOO_LARGE');
assert_equal(transfer.abort({ transfer_id: mismatch.transfer_id }).aborted, true);
let bad_hash = transfer.begin({ direction: 'upload', kind: 'backup', object_id: '',
	size: 3, sha256: transfer_runtime.digest.sha256('bad'), metadata: {} });
assert_equal(transfer.write({ transfer_id: bad_hash.transfer_id, seq: 0,
	data: b64enc('bag') }).received, 3);
assert_equal(transfer.finish({ transfer_id: bad_hash.transfer_id }).error.code,
	'VALIDATION_FAILED');
let expired = transfer.begin({ direction: 'upload', kind: 'backup', object_id: '',
	size: 1, sha256: transfer_runtime.digest.sha256('x'), metadata: {} });
let expired_path = transfer_fs.calls.open[length(transfer_fs.calls.open) - 1].path;
transfer_clock.advance(300001);
assert_true(transfer_fs.lstat(expired_path) == null,
	'expiry timer did not proactively remove staging without another RPC');
assert_equal(transfer.write({ transfer_id: expired.transfer_id, seq: 0,
	data: b64enc('x') }).error.code, 'NOT_FOUND');

// Download authority is a daemon-created report ID, never a path supplied by LuCI.
let report_id = transfer_fixture.report_id;
let download = transfer.begin({ direction: 'download', kind: 'report', object_id: report_id,
	size: 0, sha256: '', metadata: { format: 'text' } });
assert_match(download.transfer_id, /^[0-9a-f]{64}$/);
assert_equal(download.size, 10);
let downloaded = transfer.read({ transfer_id: download.transfer_id, seq: 0 });
assert_equal(b64dec(downloaded.data), 'diagnostic');
assert_equal(downloaded.eof, true);
assert_equal(transfer.read({ transfer_id: download.transfer_id, seq: 0 }).error.code,
	'INVALID_ARGUMENT');
assert_equal(transfer.finish({ transfer_id: download.transfer_id }).completed, true);
assert_equal(download_verified, true, 'download source did not verify finalized size/hash');
let backup_download = transfer.begin({ direction: 'download', kind: 'backup',
	object_id: transfer_fixture.backup_id, size: 0, sha256: '', metadata: {} });
assert_match(backup_download.transfer_id, /^[0-9a-f]{64}$/);
assert_equal(transfer.abort({ transfer_id: backup_download.transfer_id }).aborted, true);
for (let invalid_id in transfer_fixture.invalid_backup_ids)
	assert_equal(transfer.begin({ direction: 'download', kind: 'backup',
		object_id: invalid_id, size: 0, sha256: '', metadata: {} }).error.code,
		'INVALID_ARGUMENT', 'accepted invalid backup ID: ' + invalid_id);
assert_equal(transfer.begin({ direction: 'download', kind: 'config', object_id: report_id,
	size: 0, sha256: '', metadata: {} }).error.code, 'INVALID_ARGUMENT');

// Replacing the owned staging leaf with a symlink is detected and the foreign
// target is not removed by abort cleanup.
let raced = transfer.begin({ direction: 'upload', kind: 'backup', object_id: '',
	size: 1, sha256: transfer_runtime.digest.sha256('z'), metadata: {} });
let stage_path = transfer_fs.calls.open[length(transfer_fs.calls.open) - 1].path;
transfer_fs.writefile('/tmp/miclash/foreign', 'foreign');
transfer_fs.set_symlink(stage_path, '/tmp/miclash/foreign');
assert_equal(transfer.write({ transfer_id: raced.transfer_id, seq: 0,
	data: b64enc('z') }).error.code, 'INTERNAL');
assert_equal(transfer_fs.readfile('/tmp/miclash/foreign'), 'foreign');
assert_equal(transfer.abort({ transfer_id: raced.transfer_id }).aborted, true);

// Only one upload reservation (and at most 16 MiB aggregate staging) exists.
let reserved = transfer.begin({ direction: 'upload', kind: 'backup', object_id: '',
	size: 16777216, sha256: transfer_runtime.digest.sha256('reserved'), metadata: {} });
assert_equal(transfer.begin({ direction: 'upload', kind: 'backup', object_id: '',
	size: 1, sha256: transfer_runtime.digest.sha256('q'), metadata: {} }).error.code, 'BUSY');
assert_equal(transfer.write({ transfer_id: reserved.transfer_id, seq: 0, data: '%%%%' }).error.code,
	'INVALID_ARGUMENT');
assert_equal(transfer.abort({ transfer_id: reserved.transfer_id }).aborted, true);

// Domain completion replies are an exact opaque-ID shape, never a generic
// object that can leak a path or an unclassified secret.
let unsafe_fs = fakes.fs({}), unsafe_runtime = { fs: unsafe_fs, clock: fakes.clock(0),
	random: fakes.entropy(), digest: fakes.digest(unsafe_fs), paths: { tmp: '/tmp/miclash' } };
let unsafe_transfer = api.create_transfers({ runtime: unsafe_runtime,
	uploads: { backup: (staged) => {
		while (length(staged.read(16))) {}
		return { import_id: 'i-0000000000000-' + sprintf('%032x', 9),
			path: '/tmp/private', secret: 'domain-secret' };
	} }, downloads: {} });
let unsafe = unsafe_transfer.begin({ direction: 'upload', kind: 'backup', object_id: '',
	size: 1, sha256: unsafe_runtime.digest.sha256('u'), metadata: {} });
unsafe_transfer.write({ transfer_id: unsafe.transfer_id, seq: 0, data: b64enc('u') });
let unsafe_reply = unsafe_transfer.finish({ transfer_id: unsafe.transfer_id });
assert_equal(unsafe_reply.error.code, 'INVALID_RESPONSE');
assert_equal(index(sprintf('%J', unsafe_reply), 'domain-secret'), -1);
assert_equal(index(sprintf('%J', unsafe_reply), '/tmp/private'), -1);

// Random collisions retry without aliasing authority and exhaust after the
// fixed attempt bound. Exactly one expiry timer remains active for all records.
function empty_download(runtime) {
	let served = '';
	return { size: 0, sha256: runtime.digest.sha256(''),
		read: (offset, amount) => '',
		finish: () => ({ size: length(served), sha256: runtime.digest.sha256(served) }),
		close: () => true };
};
let collision_fs = fakes.fs({}), collision_clock = fakes.clock(0);
let token_a = sprintf('%064x', 41), token_b = sprintf('%064x', 42);
let collision_values = [ token_a, token_a, token_b ], collision_calls = 0;
let collision_runtime = { fs: collision_fs, clock: collision_clock,
	random: { hex: (bytes) => { collision_calls++; return shift(collision_values); } },
	digest: fakes.digest(collision_fs), paths: { tmp: '/tmp/miclash' } };
let collision_transfer = api.create_transfers({ runtime: collision_runtime, uploads: {},
	downloads: { report: (id) => empty_download(collision_runtime) } });
let collision_first = collision_transfer.begin({ direction: 'download', kind: 'report',
	object_id: 'rpt_' + sprintf('%032x', 21), size: 0, sha256: '', metadata: {} });
let collision_second = collision_transfer.begin({ direction: 'download', kind: 'report',
	object_id: 'rpt_' + sprintf('%032x', 22), size: 0, sha256: '', metadata: {} });
assert_equal(collision_first.transfer_id, token_a);
assert_equal(collision_second.transfer_id, token_b);
assert_equal(collision_calls, 3);
assert_equal(length(filter(collision_clock.timers, (timer) => timer.active)), 1,
	'exactly one transfer expiry timer must be active');
assert_equal(collision_transfer.close(), true);
assert_equal(length(filter(collision_clock.timers, (timer) => timer.active)), 0);
assert_equal(collision_transfer.begin({ direction: 'download', kind: 'report',
	object_id: 'rpt_' + sprintf('%032x', 25), size: 0, sha256: '', metadata: {} }).error.code,
	'HEALTH_FAILED');

// Timer setup is part of begin's transaction. A null, invalid, or throwing
// timer cannot leave an unreachable record, upload leaf, or download source.
let failed_timer_modes = [ 'null', 'invalid', 'throw' ];
for (let timer_mode in failed_timer_modes) {
	let timer_fs = fakes.fs({}), timer_clock = fakes.clock(0), source_closes = 0;
	timer_clock.set_timeout = (milliseconds, callback) => {
		if (timer_mode == 'null') return null;
		if (timer_mode == 'invalid') return {};
		die('set_timeout failed');
	};
	let failed_timer = api.create_transfers({ runtime: { fs: timer_fs, clock: timer_clock,
		random: fakes.entropy(), digest: fakes.digest(timer_fs), paths: { tmp: '/tmp/miclash' } },
		uploads: {}, downloads: { report: (id) => ({ size: 0,
			sha256: fakes.digest(timer_fs).sha256(''), read: () => '',
			finish: () => ({ size: 0, sha256: fakes.digest(timer_fs).sha256('') }),
			close: () => source_closes++ }) } });
	assert_equal(failed_timer.begin({ direction: 'download', kind: 'report',
		object_id: 'rpt_' + sprintf('%032x', 31), size: 0, sha256: '', metadata: {} })
		.error.code, 'INTERNAL', timer_mode + ' timer failure was accepted');
	assert_equal(source_closes, 1, timer_mode + ' timer failure leaked its source');
}
let failed_upload_fs = fakes.fs({}), failed_upload_clock = fakes.clock(0);
let healthy_set_timeout = failed_upload_clock.set_timeout;
failed_upload_clock.set_timeout = () => null;
let failed_upload_runtime = { fs: failed_upload_fs, clock: failed_upload_clock,
	random: fakes.entropy(), digest: fakes.digest(failed_upload_fs), paths: { tmp: '/tmp/miclash' } };
let failed_upload = api.create_transfers({ runtime: failed_upload_runtime,
	uploads: { backup: (staged) => ({ import_id: 'i-0000000000000-' + sprintf('%032x', 7) }) },
	downloads: {} });
assert_equal(failed_upload.begin({ direction: 'upload', kind: 'backup', object_id: '',
	size: 1, sha256: failed_upload_runtime.digest.sha256('x'), metadata: {} }).error.code,
	'INTERNAL');
let failed_upload_path = failed_upload_fs.calls.open[length(failed_upload_fs.calls.open) - 1].path;
assert_true(failed_upload_fs.lstat(failed_upload_path) == null,
	'failed initial timer left an inaccessible staging leaf');
failed_upload_clock.set_timeout = healthy_set_timeout;
let recovered_upload = failed_upload.begin({ direction: 'upload', kind: 'backup', object_id: '',
	size: 1, sha256: failed_upload_runtime.digest.sha256('x'), metadata: {} });
assert_match(recovered_upload.transfer_id, /^[0-9a-f]{64}$/,
	'failed initial timer retained an upload reservation');
failed_upload.abort({ transfer_id: recovered_upload.transfer_id });

// A replacement timer is validated before the live timer is touched.
let replacement_fs = fakes.fs({}), replacement_clock = fakes.clock(0);
let replacement_set_timeout = replacement_clock.set_timeout, reject_replacement = false;
replacement_clock.set_timeout = (milliseconds, callback) => reject_replacement ? null :
	replacement_set_timeout(milliseconds, callback);
let replacement_runtime = { fs: replacement_fs, clock: replacement_clock,
	random: fakes.entropy(), digest: fakes.digest(replacement_fs), paths: { tmp: '/tmp/miclash' } };
let replacement = api.create_transfers({ runtime: replacement_runtime, uploads: {},
	downloads: { report: (id) => ({ size: 1, sha256: replacement_runtime.digest.sha256('z'),
		read: () => 'z', finish: () => ({ size: 1,
			sha256: replacement_runtime.digest.sha256('z') }), close: () => true }) } });
let replacement_first = replacement.begin({ direction: 'download', kind: 'report',
	object_id: 'rpt_' + sprintf('%032x', 32), size: 0, sha256: '', metadata: {} });
replacement_clock.advance(1);
let replacement_second = replacement.begin({ direction: 'download', kind: 'report',
	object_id: 'rpt_' + sprintf('%032x', 33), size: 0, sha256: '', metadata: {} });
reject_replacement = true;
assert_equal(replacement.abort({ transfer_id: replacement_first.transfer_id }).error.code,
	'INTERNAL');
assert_equal(length(filter(replacement_clock.timers, (timer) => timer.active)), 1,
	'failed replacement canceled the existing live timer');
assert_equal(b64dec(replacement.read({ transfer_id: replacement_second.transfer_id, seq: 0 }).data),
	'z', 'failed replacement made an existing record inaccessible');
reject_replacement = false;
replacement.abort({ transfer_id: replacement_second.transfer_id });

// If the old timer's cancel capability throws, the validated replacement still
// becomes authoritative and keeps the remaining record expirable/accessible.
let cancel_replace_fs = fakes.fs({}), cancel_replace_clock = fakes.clock(0);
let cancel_replace_set_timeout = cancel_replace_clock.set_timeout, cancel_replace_closes = 0;
cancel_replace_clock.set_timeout = (milliseconds, callback) => {
	let timer = cancel_replace_set_timeout(milliseconds, callback);
	timer.cancel = () => die('replacement cancel failed');
	return timer;
};
let cancel_replace_runtime = { fs: cancel_replace_fs, clock: cancel_replace_clock,
	random: fakes.entropy(), digest: fakes.digest(cancel_replace_fs),
	paths: { tmp: '/tmp/miclash' } };
let cancel_replace = api.create_transfers({ runtime: cancel_replace_runtime, uploads: {},
	downloads: { report: (id) => ({ size: 1,
		sha256: cancel_replace_runtime.digest.sha256('k'), read: () => 'k',
		finish: () => ({ size: 1, sha256: cancel_replace_runtime.digest.sha256('k') }),
		close: () => cancel_replace_closes++ }) } });
let cancel_replace_first = cancel_replace.begin({ direction: 'download', kind: 'report',
	object_id: 'rpt_' + sprintf('%032x', 35), size: 0, sha256: '', metadata: {} });
cancel_replace_clock.advance(1);
let cancel_replace_second = cancel_replace.begin({ direction: 'download', kind: 'report',
	object_id: 'rpt_' + sprintf('%032x', 36), size: 0, sha256: '', metadata: {} });
assert_equal(cancel_replace.abort({ transfer_id: cancel_replace_first.transfer_id }).aborted, true);
assert_true(length(filter(cancel_replace_clock.timers, (timer) => timer.active)) >= 1,
	'throwing old cancel left the existing record without a live timer');
assert_equal(b64dec(cancel_replace.read({ transfer_id: cancel_replace_second.transfer_id,
	seq: 0 }).data), 'k');
assert_equal(cancel_replace.close(), true);
assert_equal(cancel_replace_closes, 2);

// If callback rearming fails after the earliest deadline, expiry fails closed:
// the expired source is pruned and every later source/staging leaf is disposed
// synchronously without leaking an exception into the event loop.
for (let rearm_mode in [ 'throw', 'null', 'invalid' ]) {
	let rearm_fs = fakes.fs({}), rearm_clock = fakes.clock(0), rearm_closes = 0;
	let healthy_rearm = rearm_clock.set_timeout, fail_rearm = false;
	rearm_clock.set_timeout = (milliseconds, callback) => {
		if (!fail_rearm) return healthy_rearm(milliseconds, callback);
		if (rearm_mode == 'throw') die('rearm failed');
		if (rearm_mode == 'invalid') return {};
		return null;
	};
	let rearm_runtime = { fs: rearm_fs, clock: rearm_clock, random: fakes.entropy(),
		digest: fakes.digest(rearm_fs), paths: { tmp: '/tmp/miclash' } };
	let rearm = api.create_transfers({ runtime: rearm_runtime,
		uploads: { backup: (staged) => ({ import_id: 'i-0000000000000-' + sprintf('%032x', 9) }) },
		downloads: { report: (id) => ({ size: 1,
			sha256: rearm_runtime.digest.sha256('r'), read: () => 'r',
			finish: () => ({ size: 1, sha256: rearm_runtime.digest.sha256('r') }),
			close: () => rearm_closes++ }) } });
	let rearm_first = rearm.begin({ direction: 'download', kind: 'report',
		object_id: 'rpt_' + sprintf('%032x', 41), size: 0, sha256: '', metadata: {} });
	rearm_clock.advance(1);
	let rearm_second = rearm.begin({ direction: 'download', kind: 'report',
		object_id: 'rpt_' + sprintf('%032x', 42), size: 0, sha256: '', metadata: {} });
	let rearm_upload = rearm.begin({ direction: 'upload', kind: 'backup', object_id: '',
		size: 1, sha256: rearm_runtime.digest.sha256('u'), metadata: {} });
	let rearm_path = rearm_fs.calls.open[length(rearm_fs.calls.open) - 1].path;
	fail_rearm = true;
	let callback_failure = null;
	try { rearm_clock.advance(299999); } catch (error) { callback_failure = error; }
	assert_equal(callback_failure, null, rearm_mode + ' rearm exception escaped timer callback');
	assert_equal(rearm_closes, 2, rearm_mode + ' rearm did not close both download sources');
	assert_true(rearm_fs.lstat(rearm_path) == null,
		rearm_mode + ' rearm leaked the later upload staging leaf');
	assert_equal(rearm.read({ transfer_id: rearm_second.transfer_id, seq: 0 }).error.code,
		'NOT_FOUND', rearm_mode + ' rearm left an inaccessible download record');
	assert_equal(rearm.write({ transfer_id: rearm_upload.transfer_id, seq: 0,
		data: b64enc('u') }).error.code, 'NOT_FOUND',
		rearm_mode + ' rearm left an inaccessible upload record');
	assert_equal(length(filter(rearm_clock.timers, (timer) => timer.active)), 0,
		rearm_mode + ' rearm left an active timer');
}

// A throwing timer cancel is isolated so close still disposes every record.
let close_fs = fakes.fs({}), close_clock = fakes.clock(0), download_closes = 0;
let close_set_timeout = close_clock.set_timeout;
close_clock.set_timeout = (milliseconds, callback) => {
	let timer = close_set_timeout(milliseconds, callback);
	timer.cancel = () => die('cancel failed');
	return timer;
};
let close_runtime = { fs: close_fs, clock: close_clock, random: fakes.entropy(),
	digest: fakes.digest(close_fs), paths: { tmp: '/tmp/miclash' } };
let close_transfer = api.create_transfers({ runtime: close_runtime,
	uploads: { backup: (staged) => ({ import_id: 'i-0000000000000-' + sprintf('%032x', 8) }) },
	downloads: { report: (id) => ({ size: 0, sha256: close_runtime.digest.sha256(''),
		read: () => '', finish: () => ({ size: 0, sha256: close_runtime.digest.sha256('') }),
		close: () => download_closes++ }) } });
let close_upload = close_transfer.begin({ direction: 'upload', kind: 'backup', object_id: '',
	size: 1, sha256: close_runtime.digest.sha256('c'), metadata: {} });
let close_path = close_fs.calls.open[length(close_fs.calls.open) - 1].path;
close_transfer.begin({ direction: 'download', kind: 'report',
	object_id: 'rpt_' + sprintf('%032x', 34), size: 0, sha256: '', metadata: {} });
let close_failure = null;
try { close_transfer.close(); } catch (error) { close_failure = error; }
assert_equal(close_failure, null, 'throwing timer cancel escaped close');
assert_true(close_fs.lstat(close_path) == null, 'throwing timer cancel leaked upload staging');
assert_equal(download_closes, 1, 'throwing timer cancel leaked download source');
let exhaust_fs = fakes.fs({}), exhaust_runtime = { fs: exhaust_fs, clock: fakes.clock(0),
	random: { hex: (bytes) => token_a }, digest: fakes.digest(exhaust_fs),
	paths: { tmp: '/tmp/miclash' } };
let exhaust = api.create_transfers({ runtime: exhaust_runtime, uploads: {},
	downloads: { report: (id) => empty_download(exhaust_runtime) } });
let held = exhaust.begin({ direction: 'download', kind: 'report',
	object_id: 'rpt_' + sprintf('%032x', 23), size: 0, sha256: '', metadata: {} });
assert_equal(exhaust.begin({ direction: 'download', kind: 'report',
	object_id: 'rpt_' + sprintf('%032x', 24), size: 0, sha256: '', metadata: {} }).error.code,
	'BUSY');
exhaust.abort({ transfer_id: held.transfer_id });

// Link, owner and mode drift invalidate the open staging capability before any
// additional caller bytes are written.
for (let mutation in [ 'hardlink', 'owner', 'mode' ]) {
	let drift_fs = fakes.fs({}), drift_runtime = { fs: drift_fs, clock: fakes.clock(0),
		random: fakes.entropy(), digest: fakes.digest(drift_fs), paths: { tmp: '/tmp/miclash' } };
	let drift = api.create_transfers({ runtime: drift_runtime,
		uploads: { backup: (staged) => ({ import_id: 'i-0000000000000-' + sprintf('%032x', 6) }) },
		downloads: {} });
	let drift_begin = drift.begin({ direction: 'upload', kind: 'backup', object_id: '',
		size: 1, sha256: drift_runtime.digest.sha256('d'), metadata: {} });
	let drift_path = drift_fs.calls.open[length(drift_fs.calls.open) - 1].path;
	if (mutation == 'hardlink') drift_fs.set_nlink(drift_path, 2);
	else if (mutation == 'owner') drift_fs.set_uid(drift_path, 1000);
	else drift_fs.set_mode(drift_path, 0o644);
	assert_equal(drift.write({ transfer_id: drift_begin.transfer_id, seq: 0,
		data: b64enc('d') })?.error?.code, 'INTERNAL', mutation + ' drift was accepted');
	drift.abort({ transfer_id: drift_begin.transfer_id });
}

// A daemon restart removes only authenticated stale transfer leaves. Unknown
// entries in the private staging authority stop startup and are never deleted.
let stale_name = sprintf('%064x', 99), stale_path = '/tmp/miclash/transfers/' + stale_name;
let stale_fs = fakes.fs({ [stale_path]: 'old' });
api.create_transfers({
	runtime: { fs: stale_fs, clock: fakes.clock(0), random: fakes.entropy(),
		digest: fakes.digest(stale_fs), paths: { tmp: '/tmp/miclash' } },
	uploads: {}, downloads: {}
});
assert_true(stale_fs.lstat(stale_path) == null, 'stale owned transfer survived restart');
let foreign_transfer = fakes.fs({ '/tmp/miclash/transfers/foreign': 'keep' });
assert_throws(() => api.create_transfers({
	runtime: { fs: foreign_transfer, clock: fakes.clock(0), random: fakes.entropy(),
		digest: fakes.digest(foreign_transfer), paths: { tmp: '/tmp/miclash' } },
	uploads: {}, downloads: {}
}), 'INTERNAL');
assert_equal(foreign_transfer.readfile('/tmp/miclash/transfers/foreign'), 'keep');

// The parent authority is re-authenticated after exclusive leaf creation, so
// swapping the staging directory at that boundary cannot capture an upload.
let parent_race_fs = fakes.fs({});
let parent_race = api.create_transfers({
	runtime: { fs: parent_race_fs, clock: fakes.clock(0), random: fakes.entropy(),
		digest: fakes.digest(parent_race_fs), paths: { tmp: '/tmp/miclash' } },
	uploads: { backup: () => ({}) }, downloads: {}
});
parent_race_fs.on_lstat = (path, count) => {
	if (path == '/tmp/miclash/transfers' && count == 5)
		parent_race_fs.bump_inode(path);
};
let parent_reply = parent_race.begin({ direction: 'upload', kind: 'backup', object_id: '',
	size: 1, sha256: fakes.digest(parent_race_fs).sha256('x'), metadata: {} });
assert_equal(parent_reply?.error?.code, 'INTERNAL');
let parent_stage = parent_race_fs.calls.open[length(parent_race_fs.calls.open) - 1].path;
assert_true(parent_race_fs.lstat(parent_stage) == null, 'raced staging leaf was not cleaned');
