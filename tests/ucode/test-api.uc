import { assert_equal, assert_match, assert_true } from 'testlib';
import * as api from 'miclash.api';
import * as state from 'miclash.state';

function json_equal(actual, expected, message) {
	assert_equal(sprintf('%J', actual), sprintf('%J', expected), message);
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
	set_draining: (value) => application_draining = value
};
let methods = api.method_table(app);
let names = sort(keys(methods));
json_equal(names, sort([
	'status', 'health', 'operation_get', 'operation_list',
	'service_start', 'service_stop', 'service_reload', 'service_restart',
	'config_list', 'config_read', 'config_validate', 'config_apply',
	'settings_get', 'settings_set',
	'telegram_status', 'telegram_settings', 'telegram_test'
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
assert_equal(unwired_methods.telegram_settings.call({ args: {} }).user_id, '[REDACTED]');
json_equal(unwired_methods.telegram_test.call({ args: {} }), { sent: false });

function invoke(name, args) {
	return methods[name].call({ args: args ?? {} });
};

// Published policies are exact and compatible with ucode ubus type hints.
json_equal(methods.status.args, {});
json_equal(methods.operation_get.args, { operation_id: '' });
json_equal(methods.service_start.args, { profile: '', source: '' });
json_equal(methods.config_validate.args, { profile: '', content: '', source: '' });
json_equal(methods.settings_set.args, { settings: {}, source: '' });
json_equal(methods.telegram_status.args, {});
json_equal(methods.telegram_settings.args, {});
json_equal(methods.telegram_test.args, {});
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
assert_equal(invoke('telegram_status').user_id, '[REDACTED]');
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
	'config_validate', 'config_apply', 'settings_set' ]) {
	let args = name == 'settings_set' ? { settings: {} } :
		(index(name, 'config_') == 0 ? { profile: 'config.yaml', content: 'mode: rule\n' } : {});
	assert_equal(invoke(name, args).error.code, 'BUSY', name);
}
assert_true(invoke('status').desired != null);
assert_true(invoke('operation_list').operations != null);
state_model.close();
assert_equal(operation_subscriber, null);
