import { assert_equal, assert_match, assert_true } from './testlib.uc';
import * as api from 'miclash.api';
import * as fakes from './fakes.uc';
import * as notify from 'miclash.notify';
import * as telegram from 'miclash.telegram';

let fixture_fs = require('fs');
function fixture_json(name) {
	return json(fixture_fs.readfile('tests/fixtures/telegram/' + name));
};

function clone(value) {
	return value == null ? null : json(sprintf('%J', value));
};

function update(id, text, sender, chat_type) {
	return {
		update_id: id,
		message: {
			message_id: id,
			from: { id: sender ?? 42, is_bot: false, first_name: 'Owner' },
			chat: { id: sender ?? 42, type: chat_type ?? 'private' },
			date: 1710000000,
			text
		}
	};
};

function environment(changes) {
	let options = changes ?? {};
	let filesystem = options.filesystem ?? fakes.fs();
	for (let directory in [ '/var', '/var/run', '/var/run/miclash' ])
		if (filesystem.lstat(directory) == null)
			filesystem.mkdir(directory);
	let clock = options.clock ?? fakes.clock(1710000000000);
	let runtime = {
		fs: filesystem,
		digest: fakes.digest(filesystem),
		clock,
		random: fakes.entropy(),
		paths: { run: '/var/run/miclash', tmp: '/tmp/miclash' }
	};
	let settings = options.settings ?? {
		telegram: { enabled: true, token: '123456:telegram-secret', user_id: '42' }
	};
	let requests = [], poll_replies = options.poll_replies ?? [];
	let http = {
		request: (rt, request) => {
			push(requests, clone(request));
			if (index(request.url, '/getUpdates?') >= 0) {
				let reply = length(poll_replies) ? shift(poll_replies) :
					{ status: 200, headers: {}, body: '{"ok":true,"result":[]}' };
				if (type(reply) == 'string')
					die(reply);
				return clone(reply);
			}
			if (options.send_failure)
				die('DOWNLOAD_FAILED');
			return { status: 200, headers: {}, body: '{"ok":true,"result":{}}' };
		}
	};
	let submitted = [], domain_calls = [], audit = [], logs = [];
	let operations = {
		submit: (kind, source, context, worker) => {
			let record = {
				id: sprintf('0000000001000-%08d-0123456789abcdef', length(submitted) + 1),
				kind, source, state: 'queued'
			};
			push(submitted, { ...record, context: clone(context), worker });
			return record;
		}
	};
	function operation(kind, context) {
		return operations.submit(kind, 'telegram', context ?? {}, () => null);
	};
	let app = {
		runtime,
		http,
		operations,
		settings_get: () => clone(settings),
		status: () => ({ service: { state: 'running' }, token: 'status-secret' }),
		health: () => ({ state: 'ok', detail: 'healthy' }),
		memory_status: () => ({ used_percent: 47, token: 'memory-secret' }),
		diagnostics_summary: () => ({ state: 'ok', url: 'https://example.test/?token=diag-secret' }),
		logs_read: () => 'ready\nAuthorization: Bearer log-secret\n' + sprintf('%05000d', 0),
		service_start: (profile, source) => operation('service.start', { profile }),
		service_stop: (profile, source) => operation('service.stop', { profile }),
		service_restart: (profile, source) => operation('service.restart', { profile }),
		service_reload: (profile, source) => operation('service.reload', { profile }),
		reboot: () => push(domain_calls, { method: 'reboot' }),
		subscription_update: (url, source) => operation('subscription.update', { url }),
		update_miclash: (source) => operation('updates.miclash'),
		update_mihomo: (source) => operation('updates.mihomo'),
		settings_set: (patch, source) => operation('settings.set', { patch }),
		backup_create: (source) => operation('backup.create'),
		audit: (event) => push(audit, clone(event)),
		logger: {
			info: (message) => push(logs, message),
			warn: (message) => push(logs, message),
			error: (message) => push(logs, message)
		}
	};
	return { app, runtime, filesystem, clock, settings, requests, poll_replies,
		submitted, domain_calls, audit, logs };
};

function last_request(env) {
	return env.requests[length(env.requests) - 1];
};

function sent_text(env) {
	let request = last_request(env);
	return request?.url ?? '';
};

assert_equal(type(telegram.create), 'function');

// Disabled or incomplete settings never poll, send, or expose credentials.
for (let settings in [
	{},
	{ telegram: { enabled: false, token: '123456:disabled-secret', user_id: '42' } },
	{ telegram: { enabled: true, token: '', user_id: '42' } },
	{ telegram: { enabled: true, token: '123456:missing-user-secret', user_id: '' } }
]) {
	let env = environment({ settings });
	let controller = telegram.create(env.app);
	assert_equal(controller.start(), false);
	assert_equal(controller.poll_once(), false);
	assert_equal(controller.test(), false);
	assert_equal(length(env.requests), 0);
	let encoded = sprintf('%J', controller.status());
	assert_equal(index(encoded, 'disabled-secret'), -1);
	assert_equal(index(encoded, 'missing-user-secret'), -1);
}

// Authorization accepts one normalized ID and private messages only.
let authorized = environment();
let authorized_controller = telegram.create(authorized.app);
assert_equal(authorized_controller.handle_update(
	fixture_json('private-authorized-status-string-id.json')), true);
assert_equal(length(authorized.requests), 1);
assert_equal(authorized_controller.handle_update(fixture_json('group-authorized.json')), false);
assert_equal(authorized_controller.handle_update(fixture_json('private-wrong-sender.json')), false);
for (let unsupported in fixture_json('unsupported-updates.json'))
	assert_equal(authorized_controller.handle_update(unsupported), false);
assert_equal(length(authorized.submitted), 0);

// A handled update is consumed once, including rejected/unsupported updates.
let duplicate = fixture_json('private-authorized-reboot.json');
assert_equal(authorized_controller.handle_update(duplicate), false,
	'older update IDs are duplicates after a newer update');
let duplicate_env = environment();
let duplicate_controller = telegram.create(duplicate_env.app);
assert_equal(duplicate_controller.handle_update(duplicate), true);
assert_equal(duplicate_controller.handle_update(duplicate), false);
assert_equal(length(duplicate_env.submitted), 1);
assert_equal(duplicate_env.submitted[0].kind, 'system.reboot');
assert_equal(duplicate_env.submitted[0].source, 'telegram');
duplicate_env.submitted[0].worker({ stage: () => null });
assert_equal(duplicate_env.domain_calls[0].method, 'reboot');

// Every approved command routes through a domain method and uses source=telegram.
let commands = fixture_json('approved-commands.json');
let command_id = 1000;
for (let command in commands) {
	let env = environment();
	let controller = telegram.create(env.app);
	assert_equal(controller.handle_update(update(++command_id, command.text)), true, command.text);
	if (command.kind != null) {
		assert_equal(length(env.submitted), 1, command.text);
		assert_equal(env.submitted[0].kind, command.kind, command.text);
		assert_equal(env.submitted[0].source, 'telegram', command.text);
	}
	else
		assert_equal(length(env.submitted), 0, command.text);
	let output = sprintf('%J', env.requests);
	for (let secret in [ 'status-secret', 'memory-secret', 'diag-secret',
		'log-secret', 'url-secret' ])
		assert_equal(index(output, secret), -1, command.text + ' leaked ' + secret);
}

// Commands are exact; /subscription alone, extra args, aliases, and bot suffixes reject.
let exact_env = environment();
let exact_controller = telegram.create(exact_env.app);
for (let text in [ '/status now', '/status@miclash_bot', '/subscription',
	'/subscription https://one.test/a https://two.test/b', '/unknown', ' /status' ])
	assert_equal(exact_controller.handle_update(update(++command_id, text)), false, text);
assert_equal(length(exact_env.submitted), 0);

// Offset advances atomically after every consumed update and survives recreation.
let poll_env = environment({ poll_replies: [ {
	status: 200, headers: {}, body: fixture_fs.readfile('tests/fixtures/telegram/poll-updates.json')
} ] });
let poll_controller = telegram.create(poll_env.app);
assert_equal(poll_controller.poll_once(), true);
assert_match(poll_env.requests[0].url, /\/getUpdates\?offset=0&timeout=20/);
assert_equal(poll_env.requests[0].timeout_ms, 30000);
assert_equal(poll_controller.status().last_update_id, 702);
let persisted = json(poll_env.filesystem.readfile('/var/run/miclash/telegram-offset.json'));
assert_equal(persisted.last_update_id, 702);
let recreated = environment({ filesystem: poll_env.filesystem });
let recreated_controller = telegram.create(recreated.app);
assert_equal(recreated_controller.poll_once(), true);
assert_match(recreated.requests[0].url, /\/getUpdates\?offset=703&timeout=20/);

// Telegram 429 honors retry_after; network failures back off exponentially.
let limited_poll = environment({ poll_replies: [ {
	status: 429,
	headers: { 'retry-after': '7' },
	body: '{"ok":false,"error_code":429,"parameters":{"retry_after":7}}'
} ] });
let limited_controller = telegram.create(limited_poll.app);
assert_equal(limited_controller.poll_once(), false);
assert_equal(limited_controller.status().retry_after_ms, 7000);
let network = environment({ poll_replies: [ 'DOWNLOAD_FAILED', 'DOWNLOAD_FAILED' ] });
let network_controller = telegram.create(network.app);
assert_equal(network_controller.poll_once(), false);
assert_equal(network_controller.status().retry_after_ms, 1000);
assert_equal(network_controller.poll_once(), false);
assert_equal(network_controller.status().retry_after_ms, 2000);

// Start/stop controls one timer; the process timeout stays above long-poll timeout.
let lifecycle = environment();
let lifecycle_controller = telegram.create(lifecycle.app);
assert_equal(lifecycle_controller.start(), true);
assert_equal(lifecycle_controller.start(), false);
assert_equal(lifecycle_controller.status().running, true);
lifecycle.clock.advance(0);
assert_true(length(lifecycle.requests) >= 1);
assert_equal(lifecycle_controller.stop(), true);
assert_equal(lifecycle_controller.stop(), false);
assert_equal(lifecycle_controller.status().running, false);

// The authorized command limiter is bounded and audited without IDs, token, URL, or text.
let rate = environment();
let rate_controller = telegram.create(rate.app);
let rate_update = fixture_json('rate-limit.json');
for (let index = 0; index < 5; index++) {
	let candidate = clone(rate_update);
	candidate.update_id += index;
	assert_equal(rate_controller.handle_update(candidate), true);
}
let rejected = clone(rate_update);
rejected.update_id += 5;
assert_equal(rate_controller.handle_update(rejected), false);
assert_equal(rate.audit[length(rate.audit) - 1].result, 'rate_limited');
let audit_text = sprintf('%J', rate.audit);
for (let secret in [ '42', 'telegram-secret', '/status', 'url-secret' ])
	assert_equal(index(audit_text, secret), -1, 'audit leaked ' + secret);

// Status, settings and logs are redacted at source; sending failures are isolated.
let masking = environment({ send_failure: true });
let masking_controller = telegram.create(masking.app);
assert_equal(masking_controller.test(), false);
assert_equal(masking_controller.send_event({
	type: 'failure', severity: 'error', component: 'routing',
	title: 'Routing failed', message: 'https://user:pass@example.test/?token=event-secret',
	dedupe_key: 'failure/failure-1-1710000000000', occurred_at: 1710000000000,
	recovery_of: null, context: { authorization: 'Bearer context-secret' }
}), false);
let public_state = sprintf('%J', masking_controller.status());
for (let secret in [ 'telegram-secret', 'event-secret', 'context-secret', 'user:pass', '42' ])
	assert_equal(index(public_state, secret), -1, 'public state leaked ' + secret);
assert_true(length(masking.logs) == 0 || index(sprintf('%J', masking.logs), 'telegram-secret') < 0);

// Notification subscription formats supported events and isolates Telegram failure.
let notify_env = environment({ send_failure: true });
let notify_controller = telegram.create(notify_env.app);
let runtime = {
	clock: notify_env.clock,
	process: fakes.process(),
	ubus: { connect: () => ({ send: () => true }) }
};
let center = notify.create(runtime, {
	dedupe_window_ms: 1000,
	syslog: { enabled: false, minimum_severity: 'debug', types: [], components: [] },
	luci: { enabled: false, channel: 'miclash.notify', minimum_severity: 'debug',
		types: [], components: [] }
});
center.subscribe(notify.telegram_channel(notify_controller));
let healthy_deliveries = 0;
center.subscribe({
	name: 'healthy', minimum_severity: 'debug', types: [], components: [],
	send: () => { healthy_deliveries++; return true; }
});
assert_equal(center.emit({
	type: 'guard_outage', severity: 'critical', component: 'guard',
	title: 'Guard outage', message: 'Protected routing unavailable',
	dedupe_key: 'guard/failure-9-1710000000000', occurred_at: 1710000000000,
	recovery_of: null, context: { failure_id: 'failure-9-1710000000000' }
}), true);
assert_equal(healthy_deliveries, 1);

// API exposes only redacted Telegram reads and an isolated channel test.
let api_env = environment();
let controller = telegram.create(api_env.app);
assert_equal(sprintf('%J', sort(keys(controller))), sprintf('%J', sort([
	'start', 'stop', 'status', 'test', 'poll_once', 'handle_update', 'send_event'
])));
let minimal_app = {
	status: () => ({}), health: () => ({}), operation_get: () => null,
	operation_list: () => [], service_start: () => ({ id: 'op-1' }),
	service_stop: () => ({ id: 'op-1' }), service_reload: () => ({ id: 'op-1' }),
	service_restart: () => ({ id: 'op-1' }), config_list: () => [],
	config_read: () => '', config_validate: () => ({ id: 'op-1' }),
	config_apply: () => ({ id: 'op-1' }), settings_get: () => ({}),
	settings_set: () => ({ id: 'op-1' }), set_draining: () => null,
	telegram_status: () => controller.status(),
	telegram_settings: () => api_env.settings.telegram,
	telegram_test: () => controller.test()
};
let methods = api.method_table(minimal_app);
assert_true(methods.telegram_status != null);
assert_true(methods.telegram_settings != null);
assert_true(methods.telegram_test != null);
assert_equal(length(keys(methods.telegram_status.args)), 0);
assert_equal(length(keys(methods.telegram_settings.args)), 0);
assert_equal(length(keys(methods.telegram_test.args)), 0);
let telegram_settings = methods.telegram_settings.call({ args: {} });
assert_equal(telegram_settings.token, '[REDACTED]');
assert_equal(telegram_settings.user_id, '[REDACTED]');
assert_equal(methods.telegram_test.call({ args: {} }).sent, true);
