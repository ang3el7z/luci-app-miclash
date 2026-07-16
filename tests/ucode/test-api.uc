import { assert_equal, assert_match, assert_throws, assert_true } from 'testlib';
import * as api from 'miclash.api';
import * as state from 'miclash.state';
import * as fakes from 'fakes';

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
	'status', 'health', 'operation_get', 'operation_list', 'operation_start',
	'service_start', 'service_stop', 'service_reload', 'service_restart',
	'config_list', 'config_read', 'config_validate', 'config_apply',
	'config_external_adopt', 'settings_get', 'settings_set',
	'history_list', 'history_diff', 'history_open_draft', 'history_restore',
	'subscription_get', 'subscription_set', 'subscription_update', 'subscription_probe',
	'update_release', 'update_miclash', 'update_mihomo', 'update_rollback_mihomo',
	'memory_status', 'memory_reset_baseline', 'memory_settings',
	'diagnostics_summary', 'diagnostics_create_report', 'diagnostics_route_test',
	'backup_list', 'backup_create', 'backup_inspect', 'backup_restore',
	'telegram_status', 'telegram_settings', 'telegram_test',
	'devices_list', 'devices_policy_list', 'devices_policy_set', 'devices_policy_delete',
	'notifications_settings', 'notifications_test',
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

// The canonical fixture is the single parity contract shared with the Node UI check.
let canonical = json(require('fs').readfile('tests/fixtures/api/methods.json')).methods;
json_equal(sort(map(canonical, (entry) => entry.name)), names);
for (let entry in canonical)
	json_equal(sort(keys(methods[entry.name].args)), sort(entry.params),
		entry.name + ' backend policy differs from canonical params');
assert_equal(invoke('transfer_abort', { transfer_id: sprintf('%064x', 1) }).error.code,
	'HEALTH_FAILED');

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
			return { inspection_id: 'i_' + sprintf('%032x', 1) };
		}
	},
	downloads: {
		report: (id, metadata) => {
			if (id != 'rpt_' + sprintf('%032x', 2)) die('NOT_FOUND');
			let content = 'diagnostic';
			return {
				size: length(content), sha256: transfer_runtime.digest.sha256(content),
				read: (offset, amount) => substr(content, offset, amount),
				finish: (size, sha256) => {
					download_verified = size == length(content) &&
						sha256 == transfer_runtime.digest.sha256(content);
					return download_verified;
				},
				close: () => true
			};
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
assert_equal(finalized.result.inspection_id, 'i_' + sprintf('%032x', 1));
assert_equal(imported.content, payload);
assert_equal(imported.kind, 'backup');
assert_equal(imported.metadata.secrets, false);
assert_equal(imported.sha256, payload_hash);
assert_equal(index(sprintf('%J', finalized), '/tmp/'), -1);

// Replay, wrong sequence, size/hash mismatch, overflow and expiry all fail closed.
assert_equal(transfer.finish({ transfer_id: begun.transfer_id }).error.code, 'NOT_FOUND');
let mismatch = transfer.begin({ direction: 'upload', kind: 'backup', object_id: '',
	size: 3, sha256: transfer_runtime.digest.sha256('bad'), metadata: {} });
assert_equal(transfer.write({ transfer_id: mismatch.transfer_id, seq: 0,
	data: b64enc('good') }).error.code, 'RESPONSE_TOO_LARGE');
assert_equal(transfer.abort({ transfer_id: mismatch.transfer_id }).aborted, true);
let expired = transfer.begin({ direction: 'upload', kind: 'backup', object_id: '',
	size: 1, sha256: transfer_runtime.digest.sha256('x'), metadata: {} });
transfer_clock.advance(300001);
assert_equal(transfer.write({ transfer_id: expired.transfer_id, seq: 0,
	data: b64enc('x') }).error.code, 'NOT_FOUND');

// Download authority is a daemon-created report ID, never a path supplied by LuCI.
let report_id = 'rpt_' + sprintf('%032x', 2);
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

// Active transfer state is fixed-size; malformed chunks cannot consume a slot
// silently and a ninth concurrent transfer is rejected.
let slots = [];
for (let index = 0; index < 7; index++) {
	let slot = transfer.begin({ direction: 'upload', kind: 'backup', object_id: '',
		size: 1, sha256: transfer_runtime.digest.sha256('q'), metadata: {} });
	push(slots, slot.transfer_id);
}
assert_equal(transfer.begin({ direction: 'upload', kind: 'backup', object_id: '',
	size: 1, sha256: transfer_runtime.digest.sha256('q'), metadata: {} }).error.code, 'BUSY');
assert_equal(transfer.write({ transfer_id: slots[0], seq: 0, data: '%%%%' }).error.code,
	'INVALID_ARGUMENT');
for (let id in slots) assert_equal(transfer.abort({ transfer_id: id }).aborted, true);

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
