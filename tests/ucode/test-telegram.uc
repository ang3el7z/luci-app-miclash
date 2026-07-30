import { assert_equal, assert_match, assert_throws, assert_true } from './testlib.uc';
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

function update(id, text, sender, chat_type, language) {
	return {
		update_id: id,
		message: {
			message_id: id,
			from: { id: sender ?? 42, is_bot: false, first_name: 'Owner',
				language_code: language },
			chat: { id: sender ?? 42, type: chat_type ?? 'private' },
			date: 1710000000,
			text
		}
	};
};

function callback(id, data, message_id, sender, language) {
	return {
		update_id: id,
		callback_query: {
			id: 'callback-' + id,
			from: { id: sender ?? 42, is_bot: false, first_name: 'Owner',
				language_code: language },
			message: {
				message_id: message_id ?? 50,
				chat: { id: sender ?? 42, type: 'private' }
			},
			data
		}
	};
};

function request_diagnostic(controller, id, mode) {
	assert_equal(controller.handle_update(update(id, '/menu')), true);
	assert_equal(controller.handle_update(callback(id + 1, 'g1:open:diagnostics')), true);
	if (mode == 'full') {
		assert_equal(controller.handle_update(
			callback(id + 2, 'g2:confirm:diagnostic_full')), true);
		return controller.handle_update(
			callback(id + 3, 'g3:execute:diagnostic_full'));
	}
	return controller.handle_update(
		callback(id + 2, 'g2:execute:diagnostic_' + mode));
};

function request_method(request) {
	return match(request.url, /\/([A-Za-z]+)(\?|$)/)?.[1];
};

function active_timers(clock) {
	let count = 0;
	for (let timer in clock.timers)
		if (timer.active)
			count++;
	return count;
};

function environment(changes) {
	let options = changes ?? {};
	let filesystem = options.filesystem ?? fakes.fs();
	for (let directory in [ '/etc', '/etc/miclash', '/var', '/var/run', '/var/run/miclash' ])
		if (filesystem.lstat(directory) == null)
			filesystem.mkdir(directory);
	filesystem.set_mode('/etc/miclash', 0o700);
	let clock = options.clock ?? fakes.clock(1710000000000);
	let runtime = {
		fs: filesystem,
		digest: fakes.digest(filesystem),
		clock,
		random: fakes.entropy(),
		uci: fakes.uci({ luci: { main: { '.type': 'core', lang: options.locale ?? 'ru' } } }),
		paths: { etc: '/etc/miclash', run: '/var/run/miclash', tmp: '/tmp/miclash' }
	};
	let settings = options.settings ?? {
		telegram: { enabled: true, token: '123456:telegram-secret', user_id: '42' },
		core: { subscription_url: 'https://example.test/current', proxy_mode: 'tproxy' }
	};
	let requests = [], poll_replies = options.poll_replies ?? [],
		document_replies = options.document_replies ?? [];
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
			let method = request_method(request);
			if (method == 'sendDocument') {
				if (options.document_failure)
					die('DOWNLOAD_FAILED');
				let file = request.body_file, received = '';
				while (length(received) < file.size) {
					let chunk = file.read(min(49152, file.size - length(received)));
					if (type(chunk) != 'string' || !length(chunk)) die('INTERNAL');
					received += chunk;
				}
				if (file.read(1) != '') die('INTERNAL');
				if (rt.digest.sha256(received) != file.sha256) die('INTERNAL');
				let reply = length(document_replies) ? shift(document_replies) : null;
				if (reply != null) return clone(reply);
			}
			return { status: 200, headers: {}, body: sprintf('%J', {
				ok: true,
				result: method == 'sendMessage' ? { message_id: 50 } :
					(method == 'editMessageText' ? { message_id: 50 } :
						(method == 'sendDocument' ? { message_id: 51 } : true))
			}) };
		}
	};
	let submitted = [], domain_calls = [], audit = [], logs = [], operation_subscribers = [],
		report_requests = [], report_opens = 0, report_finishes = 0, report_closes = 0;
	let operations = {
		submit: (kind, source, context, worker) => {
			let record = {
				id: sprintf('0000000001000-%08d-0123456789abcdef', length(submitted) + 1),
				kind, source, state: 'queued', stage: 'queued', progress: 0,
				error: null, created_at: clock.now()
			};
			push(submitted, { ...record, context: clone(context), worker });
			return record;
		},
		get: (id) => {
			for (let record in submitted) if (record.id == id) return clone(record);
			return null;
		},
		list: () => clone(submitted),
		subscribe: (callback) => {
			push(operation_subscribers, callback);
			let active = true;
			return () => {
				if (!active) return false;
				active = false;
				let offset = index(operation_subscribers, callback);
				if (offset >= 0) splice(operation_subscribers, offset, 1);
				return true;
			};
		}
	};
	function record_call(method, args) {
		push(domain_calls, { method, args: clone(args) });
	};
	function operation(method, kind, args, source, context) {
		record_call(method, args);
		return operations.submit(kind, source, context ?? {}, () => null);
	};
	let app = {
		runtime,
		http,
		operations,
		boot_id: () => 'boot-test',
		daemon_ready: () => true,
		operation_postcheck: () => true,
		settings_get: () => clone(settings),
		status: () => {
			record_call('status', []);
			return { service: { state: 'running' }, token: 'status-secret' };
		},
		health: () => { record_call('health', []); return { state: 'ok', detail: 'healthy' }; },
		system_info: () => ({
			app_version: options.app_version ?? '2.5.4',
			mihomo: { version: options.mihomo_version ?? '1.19.30' }
		}),
		updates_status: () => ({
			automatic_miclash: { latest_version: 'v2.5.3', readiness: 'ready' }
		}),
		update_release: (kind) => {
			record_call('update_release', [ kind ]);
			return kind == 'miclash'
				? { version: options.miclash_release ?? 'v2.5.4',
					ready: true, readiness: 'ready' }
				: { version: options.mihomo_release ?? 'v1.19.30' };
		},
		memory_status: () => {
			record_call('memory_status', []);
			return { used_percent: 47, token: 'memory-secret' };
		},
		diagnostics_summary: () => {
			record_call('diagnostics_summary', []);
			return { state: 'ok', url: 'https://example.test/?token=diag-secret' };
		},
		diagnostics_create_report: (arguments) => {
			let request = clone(arguments);
			push(report_requests, request);
			let number = length(report_requests);
			let record = {
				id: sprintf('0000000002000-%08d-0123456789abcdef', number),
				kind: 'diagnostics.report', source: request.source,
				state: 'queued', stage: 'queued', progress: 0, error: null,
				created_at: clock.now(), report_id: sprintf('rpt_%032x', number)
			};
			push(submitted, record);
			return { operation_id: record.id, report_id: record.report_id };
		},
		diagnostics_open_report: (id) => {
			report_opens++;
			let content = options.report_content ??
				'{"schema_version":4,"privacy":{"mode":"lite"},"token":"[REDACTED]"}';
			let offset = 0, closed = false, identity = {};
			return {
				identity,
				size: length(content),
				sha256: runtime.digest.sha256(content),
				read: (amount) => {
					if (closed) die('NOT_FOUND');
					let chunk = substr(content, offset, amount);
					offset += length(chunk);
					return chunk;
				},
				finish: () => {
					if (closed || offset != length(content)) die('VALIDATION_FAILED');
					closed = true;
					report_finishes++;
					return true;
				},
				close: () => {
					if (closed) die('NOT_FOUND');
					closed = true;
					report_closes++;
					return true;
				}
			};
		},
		logs_read: () => {
			record_call('logs_read', []);
			return 'ready\nAuthorization: Bearer log-secret\n' + sprintf('%05000d', 0);
		},
		service_start: (profile, source) => operation('service_start', 'service.start',
			[ profile, source ], source, { profile }),
		service_stop: (profile, source) => operation('service_stop', 'service.stop',
			[ profile, source ], source, { profile }),
		service_restart: (profile, source) => operation('service_restart', 'service.restart',
			[ profile, source ], source, { profile }),
		service_reload: (profile, source) => operation('service_reload', 'service.reload',
			[ profile, source ], source, { profile }),
		reboot: () => record_call('reboot', []),
		subscription_update: (url, source) => operation('subscription_update',
			'subscription.update', [ url, source ], source, { url }),
		update_miclash: (action, version, source) => operation(
			'update_miclash', 'updates.miclash', [ action, version, source ], source),
		update_mihomo: (action, version, source) => operation(
			'update_mihomo', 'updates.mihomo', [ action, version, source ], source),
		settings_set: (patch, source) => operation('settings_set', 'settings.set',
			[ patch, source ], source, { patch }),
		guard_transition: (enabled, source) => operation('guard_transition',
			'guard.transition', [ enabled, source ], source, { enabled }),
		audit: (event) => push(audit, clone(event)),
		logger: {
			info: (message) => push(logs, message),
			warn: (message) => push(logs, message),
			error: (message) => push(logs, message)
		}
	};
	function emit_report(state, stage, progress, error) {
		let index = length(submitted) - 1;
		let record = { ...submitted[index], state, stage, progress,
			error: error ?? null };
		submitted[index] = record;
		for (let subscriber in [ ...operation_subscribers ])
			subscriber(clone(record));
		return record;
	};
	return { app, runtime, filesystem, clock, settings, requests, poll_replies,
		submitted, domain_calls, audit, logs, operation_subscribers, report_requests,
		report_opens: () => report_opens, report_finishes: () => report_finishes,
		report_closes: () => report_closes, emit_report };
};

assert_equal(type(telegram.create), 'function');

// Telegram consumes the same production snapshot shapes as the LuCI overview.
// Keep this contract explicit so bot labels cannot silently drift from the UI.
assert_equal(type(telegram.panel_model), 'function');
let production_panel = telegram.panel_model({
	runtime: {
		uci: fakes.uci({ system: { main: { '.type': 'system', zonename: 'Europe/Moscow' } } }),
		timezones: { resolve: (name) => name == 'Europe/Moscow' ? {
			name, from: 0, until: 4102444800, initial_offset: 10800, transitions: []
		} : null }
	},
	settings_get: () => ({
		core: { proxy_mode: 'tproxy',
			subscription_url_config_yaml: 'https://example.test/full/path?token=owner-visible' },
		guard: { enabled: true },
		updates: { auto_subscription: true, auto_major_miclash: true }
	}),
	status: () => ({ observed: {
		service: { state: 'running', running: true },
		readiness: { ok: true, components: [
			{ component: 'process', state: 'ready' },
			{ component: 'api', state: 'ready' },
			{ component: 'dns', state: 'ready' },
			{ component: 'policy', state: 'ready' },
			{ component: 'forward', state: 'ready' }
		] }
	} }),
	health: () => ({ observed: { readiness: { ok: true, components: [
		{ component: 'process', state: 'ready' },
		{ component: 'api', state: 'ready' },
		{ component: 'dns', state: 'ready' },
		{ component: 'policy', state: 'ready' },
		{ component: 'forward', state: 'ready' }
	] } } }),
	system_info: () => ({ app_version: '2.0.4', mihomo: { version: '1.19.29' } }),
	updates_status: () => ({
		automatic_config: { running: true, enabled: false, reason: 'no_url' },
		automatic_miclash: { running: true, enabled: true, local_time_valid: true,
			next_check: 1710003600000, latest_version: 'v2.0.4' }
	}),
	subscription_status: () => ({ configured: false, url: null }),
	subscription_operation: () => ({ state: 'success', updated_at: 1710000100000,
		finished_at: 1710000100000 }),
	memory_status: () => ({ enabled: true, phase: 'warming_up',
		current_rss_kb: 58540, baseline_rss_kb: null, last_action: null }),
	guard_status: () => 'enabled', logs_read: () => '', diagnostics_summary: () => ({})
}, 'memory');
assert_equal(production_panel.miclash_state, 'running');
assert_equal(production_panel.mihomo_state, 'ready');
assert_equal(production_panel.dns_state, 'ready');
assert_equal(production_panel.firewall_state, 'ready');
assert_equal(production_panel.routing_state, 'ready');
assert_equal(production_panel.config_update_state, 'not_configured');
assert_equal(production_panel.miclash_update_state, 'scheduled');
assert_equal(production_panel.subscription_url,
	'https://example.test/full/path?token=owner-visible');
assert_equal(production_panel.last_subscription_update, '2024-03-09 19:01');
assert_equal(production_panel.last_subscription_result, 'success');
assert_equal(production_panel.memory_rss, '57.2 MiB');
assert_equal(production_panel.memory_baseline, 'not_learned');
assert_equal(production_panel.memory_state, 'warming_up');
assert_equal(production_panel.last_memory_action, 'not_required');
assert_equal(production_panel.guard_observed, 'enabled');
assert_equal(production_panel.updates.miclash_available, 'v2.0.4');

let fresh_updates_panel = telegram.panel_model({
	runtime: {},
	settings_get: () => ({ core: {}, guard: {}, updates: {} }),
	status: () => ({}), health: () => ({}),
	system_info: () => ({
		app_version: '2.5.4', mihomo: { version: '1.19.30' }
	}),
	updates_status: () => ({
		automatic_miclash: { latest_version: 'v2.5.3', readiness: 'ready' }
	}),
	update_release: (kind) => kind == 'miclash'
		? { version: 'v2.5.4', ready: true, readiness: 'ready' }
		: { version: 'v1.19.29' }
}, 'updates');
assert_equal(fresh_updates_panel.updates.miclash_available, 'v2.5.4',
	'Telegram used the stale nightly scheduler version instead of a fresh release');
assert_equal(fresh_updates_panel.updates.miclash_action, 'reinstall');
assert_equal(fresh_updates_panel.updates.mihomo_available, 'v1.19.29');
assert_equal(fresh_updates_panel.updates.mihomo_action, 'downgrade');

let offset_path = '/etc/miclash/telegram-offset.json';

let automatic_locale = environment({ locale: 'auto' });
let automatic_locale_controller = telegram.create(automatic_locale.app);
assert_equal(automatic_locale_controller.handle_update(
	update(90, '/menu', 42, 'private', 'ru')), true);
assert_match(automatic_locale.requests[0].body,
	/%D0%9F%D0%B0%D0%BD%D0%B5%D0%BB%D1%8C/);

// The command test double must preserve caller arguments instead of manufacturing telegram.
let source_probe = environment();
source_probe.app.service_start('config2.yaml', 'luci');
assert_equal(source_probe.submitted[0].source, 'luci');

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

// The UI needs to distinguish a saved token from a fully configured bot.
let token_only = environment({ settings: {
	telegram: { enabled: true, token: '123456:missing-user-secret', user_id: '' }
} });
let token_only_status = telegram.create(token_only.app).status();
assert_equal(token_only_status.configured, false);
assert_equal(token_only_status.bot_configured, true);
assert_equal(token_only_status.bot_length, 26);

// Authorization accepts one normalized ID and private messages only.
let authorized = environment();
let authorized_controller = telegram.create(authorized.app);
assert_equal(authorized_controller.handle_update(
	fixture_json('private-authorized-status-string-id.json')), true);
assert_equal(length(authorized.requests), 1);
let authorized_writes = length(authorized.filesystem.calls.open);
assert_equal(json(authorized.filesystem.readfile(offset_path)).last_update_id, 102);
assert_equal(authorized_controller.handle_update(fixture_json('group-authorized.json')), false);
assert_equal(authorized_controller.handle_update(fixture_json('private-wrong-sender.json')), false);
for (let unsupported in fixture_json('unsupported-updates.json'))
	assert_equal(authorized_controller.handle_update(unsupported), false);
assert_equal(authorized_controller.handle_update(update(108, '/unknown')), false);
assert_equal(length(authorized.submitted), 0);
assert_equal(length(authorized.filesystem.calls.open), authorized_writes,
	'rejected updates wrote durable state');
assert_equal(json(authorized.filesystem.readfile(offset_path)).last_update_id, 102);
assert_equal(authorized_controller.status().last_update_id, 108);
assert_equal(authorized_controller.poll_once(), true);

assert_match(authorized.requests[length(authorized.requests) - 1].url,
	/\/getUpdates\?offset=109&timeout=25/);

let ingested = authorized_controller.ingest(update(109, '/status'));
assert_equal(ingested.handled, false);
assert_equal(ingested.retryable, false);
assert_equal(ingested.last_update_id, 109);

// Removed slash commands are rejected and never dispatch operations.
let duplicate = fixture_json('private-authorized-reboot.json');
assert_equal(authorized_controller.handle_update(duplicate), false,
	'older update IDs are duplicates after a newer update');
let duplicate_env = environment();
let duplicate_controller = telegram.create(duplicate_env.app);
let original_submit = duplicate_env.app.operations.submit;
let durable_at_submit = null;
duplicate_env.app.operations.submit = (kind, source, context, worker) => {
	durable_at_submit = json(duplicate_env.filesystem.readfile(offset_path));
	return original_submit(kind, source, context, worker);
};
assert_equal(duplicate_controller.handle_update(duplicate), true);
assert_equal(duplicate_controller.handle_update(duplicate), false);
assert_equal(length(duplicate_env.submitted), 0);
assert_equal(durable_at_submit, null);

// Only /start and /menu remain accepted.
let commands = fixture_json('approved-commands.json');
let command_id = 1000;
for (let command in commands) {
	let env = environment();
	let controller = telegram.create(env.app);
	let accepted = command.text == '/start' || command.text == '/menu';
	assert_equal(controller.handle_update(update(++command_id, command.text)), accepted, command.text);
	assert_equal(length(env.submitted), 0, command.text);
}

// Commands are exact; /subscription alone, extra args, aliases, and bot suffixes reject.
let exact_env = environment();
let exact_controller = telegram.create(exact_env.app);
for (let text in [ '/status now', '/subscription',
	'/subscription https://one.test/a https://two.test/b', '/unknown', ' /status' ])
	assert_equal(exact_controller.handle_update(update(++command_id, text)), false, text);
assert_equal(length(exact_env.submitted), 0);
assert_equal(exact_controller.handle_update(update(++command_id, '/menu@miclash_bot')), true,
	'Telegram bot suffix should address the configured bot command');

// Offset advances atomically under the persistent private authority and survives reboot.
let poll_env = environment({ poll_replies: [ {
	status: 200, headers: {}, body: fixture_fs.readfile('tests/fixtures/telegram/poll-updates.json')
} ] });
let poll_controller = telegram.create(poll_env.app);
assert_equal(poll_controller.poll_once(), true);
assert_match(poll_env.requests[0].url, /\/getUpdates\?offset=0&timeout=25/);
assert_equal(poll_env.requests[0].timeout_ms, 30000,
	'Telegram polling must allow the configured long-poll response plus a grace period');
assert_equal(poll_controller.status().last_update_id, 702);
let persisted_bytes = poll_env.filesystem.readfile(offset_path);
assert_true(type(persisted_bytes) == 'string', 'durable Telegram offset was not persisted');
let persisted = json(persisted_bytes);
assert_equal(persisted.last_update_id, 702);
assert_equal(poll_env.filesystem.lstat(offset_path).mode, 0o600);
assert_equal(poll_env.filesystem.lstat(offset_path).uid, 0);
assert_equal(poll_env.filesystem.lstat(offset_path).nlink, 1);
assert_equal(poll_env.filesystem.realpath(offset_path), offset_path);
assert_equal(poll_env.filesystem.readfile('/var/run/miclash/telegram-offset.json'), null);
let recreated = environment({ filesystem: poll_env.filesystem });
let recreated_controller = telegram.create(recreated.app);
assert_equal(recreated_controller.poll_once(), true);
assert_match(recreated.requests[0].url, /\/getUpdates\?offset=703&timeout=25/);

// Diagnostics always submits a Lite report, edits stage progress in the working
// menu, uploads the document, restores Diagnostics, and sends a separate result.
let formatted_env = environment();
formatted_env.app.logs_read = () => 'line one\nline two';
let formatted_controller = telegram.create(formatted_env.app);
assert_equal(request_diagnostic(formatted_controller, 705, 'lite'), true);
assert_equal(formatted_env.report_requests[0].mode, 'lite');
assert_equal(formatted_env.report_requests[0].source, 'telegram');
assert_equal(formatted_env.report_requests[0].acknowledge_secrets, false);
assert_true(index(sprintf('%J', formatted_env.report_requests), 'full') < 0);
assert_equal(request_method(formatted_env.requests[0]), 'sendMessage');
formatted_env.emit_report('running', 'configuration', 30);
assert_equal(request_method(formatted_env.requests[length(formatted_env.requests) - 1]),
	'editMessageText');
assert_match(formatted_env.requests[length(formatted_env.requests) - 1].body, /30%25/);
formatted_env.emit_report('success', 'complete', 100);
let diagnostics_request = null, diagnostics_method_order = [];
for (let request in formatted_env.requests) {
	push(diagnostics_method_order, request_method(request));
	if (request_method(request) == 'sendDocument') diagnostics_request = request;
}
assert_true(diagnostics_request != null, 'completed Lite report was not uploaded');
assert_equal(diagnostics_request.method, 'POST');
assert_equal(diagnostics_request.body, null);
assert_match(diagnostics_request.body_file.filename, /^miclash-diagnostic-lite-[0-9]+\.json$/);
assert_equal(diagnostics_request.body_file.field, 'document');
assert_equal(diagnostics_request.body_file.content_type, 'application/json');
assert_equal(diagnostics_request.body_file.fields.chat_id, '42');
assert_true(!exists(diagnostics_request.body_file, 'path'),
	'Telegram request exposed an arbitrary report pathname');
assert_equal(formatted_env.report_opens(), 1);
assert_equal(formatted_env.report_finishes(), 1);
assert_equal(formatted_env.report_closes(), 0);
assert_match(join(',', diagnostics_method_order),
	/sendMessage,(editMessageText,)+sendDocument,editMessageText,sendMessage/);
assert_equal(formatted_controller.status().panel_screen, 'diagnostics');

let silent_env = environment(), silent_controller = telegram.create(silent_env.app);
assert_equal(request_diagnostic(silent_controller, 7200, 'silent'), true);
assert_equal(silent_env.report_requests[0].mode, 'silent');
assert_equal(silent_env.report_requests[0].acknowledge_secrets, false);

let full_env = environment(), full_controller = telegram.create(full_env.app);
assert_equal(request_diagnostic(full_controller, 7300, 'full'), true);
assert_equal(full_env.report_requests[0].mode, 'full');
assert_equal(full_env.report_requests[0].acknowledge_secrets, true);

// Lite reports above the legacy HTTP cap still use the 16 MiB diagnostic
// transfer contract and reach Telegram as document descriptors.
let large_lite_env = environment({ report_content: sprintf('%1048577s', 'x') });
let large_lite_controller = telegram.create(large_lite_env.app);
assert_equal(request_diagnostic(large_lite_controller, 7051, 'lite'), true);
large_lite_env.emit_report('success', 'complete', 100);
let large_lite_request = null;
for (let request in large_lite_env.requests)
	if (request_method(request) == 'sendDocument') large_lite_request = request;
assert_true(large_lite_request != null,
	'Lite reports above 1 MiB must reach Telegram through sendDocument');
assert_equal(large_lite_request.body_file.size, 1048577);
assert_equal(large_lite_env.report_finishes(), 1);

assert_equal(formatted_controller.handle_update(callback(708, 'g4:open:logs')), true);
assert_equal(formatted_controller.handle_update(
	callback(709, 'g5:execute:download_logs')), true);
let logs_request = null;
for (let request in formatted_env.requests)
	if (request_method(request) == 'sendDocument' &&
	    request.body_file?.content_type == 'text/plain') logs_request = request;
assert_true(logs_request != null);
assert_equal(request_method(logs_request), 'sendDocument');
assert_equal(logs_request.body_file.content_type, 'text/plain');
assert_match(logs_request.body_file.filename, /^miclash-logs-[0-9]+\.log$/);

// Telegram 429 releases the one-shot descriptor, honors retry_after, and opens
// a fresh daemon capability for the successful retry.
let document_retry = environment({ document_replies: [
	{ status: 429, headers: { 'retry-after': '7' },
		body: '{"ok":false,"parameters":{"retry_after":7}}' },
	{ status: 200, headers: {}, body: '{"ok":true,"result":{"message_id":52}}' }
] });
let document_retry_controller = telegram.create(document_retry.app);
assert_equal(request_diagnostic(document_retry_controller, 707, 'lite'), true);
document_retry.emit_report('success', 'complete', 100);
assert_equal(document_retry.report_opens(), 1);
assert_equal(document_retry.report_closes(), 1);
assert_equal(document_retry.report_finishes(), 0);
document_retry.clock.advance(6999);
assert_equal(document_retry.report_opens(), 1);
document_retry.clock.advance(1);
assert_equal(document_retry.report_opens(), 2);
assert_equal(document_retry.report_closes(), 1);
assert_equal(document_retry.report_finishes(), 1);

// An upload failure releases rather than consumes the report, restores the
// Diagnostics menu, and emits a separate localized failure message.
let document_failure = environment({ document_failure: true });
let document_failure_controller = telegram.create(document_failure.app);
assert_equal(request_diagnostic(document_failure_controller, 708, 'lite'), true);
document_failure.emit_report('success', 'complete', 100);
assert_equal(document_failure.report_opens(), 1);
assert_equal(document_failure.report_finishes(), 0);
assert_equal(document_failure.report_closes(), 1);
assert_equal(document_failure_controller.status().panel_screen, 'diagnostics');
assert_equal(request_method(document_failure.requests[length(document_failure.requests) - 1]),
	'sendMessage');

// Restart recovery marks an in-flight observation interrupted. A recreated
// controller recovers the durable Telegram destination without receiving the
// old controller's live event, reports failure, and never opens a partial file.
let interrupted_report = environment();
let interrupted_controller = telegram.create(interrupted_report.app);
assert_equal(interrupted_controller.start(), true);
assert_equal(request_diagnostic(interrupted_controller, 709, 'lite'), true);
assert_equal(interrupted_controller.stop(), true);
let interrupted_index = length(interrupted_report.submitted) - 1;
interrupted_report.submitted[interrupted_index] = {
	...interrupted_report.submitted[interrupted_index],
	state: 'interrupted', stage: 'interrupted', progress: 30,
	error: { code: 'INTERRUPTED', message: 'INTERRUPTED' }
};
let interrupted_requests = length(interrupted_report.requests);
let recovered_controller = telegram.create(interrupted_report.app);
assert_equal(recovered_controller.start(), true);
assert_equal(recovered_controller.poll_once(), true);
assert_equal(interrupted_report.report_opens(), 0);
assert_true(length(interrupted_report.requests) > interrupted_requests);
assert_equal(request_method(interrupted_report.requests[
	length(interrupted_report.requests) - 1]), 'sendMessage');

// A recovered interrupted receipt stays durable when Telegram accepts neither
// the restored panel nor the explicit result notice, then retries successfully.
let interrupted_delivery_options = {};
let interrupted_delivery = environment(interrupted_delivery_options);
let interrupted_delivery_controller = telegram.create(interrupted_delivery.app);
assert_equal(interrupted_delivery_controller.start(), true);
assert_equal(request_diagnostic(interrupted_delivery_controller, 713, 'lite'), true);
assert_equal(interrupted_delivery_controller.stop(), true);
let interrupted_delivery_index = length(interrupted_delivery.submitted) - 1;
interrupted_delivery.submitted[interrupted_delivery_index] = {
	...interrupted_delivery.submitted[interrupted_delivery_index],
	state: 'interrupted', stage: 'interrupted', progress: 30,
	error: { code: 'INTERRUPTED', message: 'INTERRUPTED' }
};
let interrupted_delivery_recovered = telegram.create(interrupted_delivery.app);
assert_equal(interrupted_delivery_recovered.start(), true);
interrupted_delivery_options.send_failure = true;
assert_equal(interrupted_delivery_recovered.poll_once(), true);
assert_equal(interrupted_delivery_recovered.status().pending_deliveries, 1,
	'recovered diagnostic receipt was lost when Telegram rejected its failure UX');
interrupted_delivery_options.send_failure = false;
interrupted_delivery.clock.advance(15000);
assert_equal(interrupted_delivery_recovered.poll_once(), true);
assert_equal(interrupted_delivery_recovered.status().pending_deliveries, 0);

// Recovery uses the same complete administrator authorization set as the live
// command path, not only the primary configured ID.
let secondary_restart = environment({ settings: {
	telegram: { enabled: true, token: '123456:telegram-secret', user_id: '42, 84' },
	core: { subscription_url: 'https://example.test/current', proxy_mode: 'tproxy' }
} });
let secondary_restart_controller = telegram.create(secondary_restart.app);
assert_equal(secondary_restart_controller.start(), true);
assert_equal(secondary_restart_controller.handle_update(update(714, '/menu', 84)), true);
assert_equal(secondary_restart_controller.handle_update(
	callback(715, 'g1:open:diagnostics', 50, 84)), true);
assert_equal(secondary_restart_controller.handle_update(
	callback(716, 'g2:execute:diagnostic_lite', 50, 84)), true);
assert_equal(secondary_restart_controller.stop(), true);
let secondary_restart_index = length(secondary_restart.submitted) - 1;
secondary_restart.submitted[secondary_restart_index] = {
	...secondary_restart.submitted[secondary_restart_index],
	state: 'interrupted', stage: 'interrupted', progress: 30,
	error: { code: 'INTERRUPTED', message: 'INTERRUPTED' }
};
let secondary_restart_recovered = telegram.create(secondary_restart.app);
assert_equal(secondary_restart_recovered.start(), true);
assert_equal(secondary_restart_recovered.poll_once(), true);
assert_equal(secondary_restart_recovered.status().pending_deliveries, 0,
	'recovered diagnostic receipt excluded an authorized secondary administrator');
assert_match(secondary_restart.requests[length(secondary_restart.requests) - 1].body,
	/(^|&)chat_id=84(&|$)/);

// If Telegram becomes unavailable before generation completes, no upload is
// attempted; the report remains in the TTL-managed store.
let unavailable_report = environment();
let unavailable_controller = telegram.create(unavailable_report.app);
assert_equal(request_diagnostic(unavailable_controller, 710, 'lite'), true);
unavailable_report.settings.telegram.enabled = false;
unavailable_report.emit_report('success', 'complete', 100);
assert_equal(unavailable_report.report_opens(), 0);

// OpenWrt overlayfs may report the private directory and a regular file inside it
// on different st_dev values. The fixed path and file identity remain authoritative.
let overlay = environment();
overlay.filesystem.set_device('/etc/miclash', 20);
overlay.filesystem.on_rename = (from, to) => {
	if (to == offset_path) overlay.filesystem.set_device(to, 21);
};
let overlay_controller = telegram.create(overlay.app);
assert_equal(overlay_controller.handle_update(update(703, '/menu')), true);
assert_equal(overlay_controller.status().last_update_id, 703);
assert_equal(json(overlay.filesystem.readfile(offset_path)).last_update_id, 703);

// Simulated reboot clears /var/run but preserves flash state; an accepted menu update
// is still at-most-once after boot.
let before_reboot = environment();
let before_reboot_controller = telegram.create(before_reboot.app);
assert_equal(before_reboot_controller.handle_update(duplicate), true);
let durable_bytes = before_reboot.filesystem.readfile(offset_path);
let after_reboot_fs = fakes.fs({ [offset_path]: durable_bytes });
let after_reboot = environment({ filesystem: after_reboot_fs });
let after_reboot_controller = telegram.create(after_reboot.app);
assert_equal(after_reboot_controller.handle_update(duplicate), false);
assert_equal(length(after_reboot.submitted), 0);
assert_equal(after_reboot_controller.status().last_update_id, duplicate.update_id);

// Existing durable state and its authority are authenticated before trust.
let corrupt_offset = environment({ filesystem: fakes.fs({ [offset_path]: '{broken' }) });
assert_throws(() => telegram.create(corrupt_offset.app), 'CORRUPT_STATE');
let wide_offset = environment({ filesystem: fakes.fs({
	[offset_path]: '{"last_update_id":702}\n'
}) });
wide_offset.filesystem.set_mode(offset_path, 0o640);
assert_throws(() => telegram.create(wide_offset.app), 'CORRUPT_STATE');
let foreign_offset = environment({ filesystem: fakes.fs({
	[offset_path]: '{"last_update_id":702}\n'
}) });
foreign_offset.filesystem.set_uid(offset_path, 1000);
assert_throws(() => telegram.create(foreign_offset.app), 'CORRUPT_STATE');
let linked_offset = environment({ filesystem: fakes.fs({
	'/tmp/foreign-offset': '{"last_update_id":702}\n'
}) });
linked_offset.filesystem.set_symlink(offset_path, '/tmp/foreign-offset');
assert_throws(() => telegram.create(linked_offset.app), 'CORRUPT_STATE');
let unsafe_authority = environment();
unsafe_authority.filesystem.set_mode('/etc/miclash', 0o755);
assert_throws(() => telegram.create(unsafe_authority.app), 'INVALID_ARGUMENT');
let swapped_offset = environment({ filesystem: fakes.fs({
	[offset_path]: '{"last_update_id":702}\n'
}) });
swapped_offset.filesystem.on_lstat = (path, count) => {
	if (path == offset_path && count == 2)
		swapped_offset.filesystem.bump_inode(path);
};
assert_throws(() => telegram.create(swapped_offset.app), 'CORRUPT_STATE');
let write_authority_swap = environment();
let write_authority_swap_controller = telegram.create(write_authority_swap.app);
write_authority_swap.filesystem.on_lstat = (path, count) => {
	if (path == offset_path && count == 4)
		write_authority_swap.filesystem.bump_inode('/etc/miclash');
};
assert_equal(write_authority_swap_controller.handle_update(update(703, '/menu')), false);
assert_equal(length(write_authority_swap.submitted), 0);

// Directory size is mutable metadata and must not invalidate a stable authority identity.
let resized_authority = environment();
let resized_authority_controller = telegram.create(resized_authority.app);
let authority_lstat = resized_authority.filesystem.lstat;
let authority_reads = 0;
resized_authority.filesystem.lstat = (path) => {
	let identity = authority_lstat(path);
	if (path == '/etc/miclash' && identity != null) {
		authority_reads++;
		identity = { ...identity, size: authority_reads == 1 ? 0 : 4096 };
	}
	return identity;
};
assert_equal(resized_authority_controller.handle_update(update(704, '/menu')), true);
assert_equal(length(resized_authority.submitted), 0);
assert_equal(json(resized_authority.filesystem.readfile(offset_path)).last_update_id, 704);

// A durable write failure is a batch barrier: later updates wait while N retries.
let barrier_document = sprintf('%J', {
	ok: true,
	result: [ update(800, '/menu'), update(801, '/menu', 43) ]
});
let barrier_fs = fakes.fs({ [offset_path]: '{"last_update_id":799}\n' });
let barrier = environment({
	filesystem: barrier_fs,
	poll_replies: [
		{ status: 200, headers: {}, body: barrier_document },
		{ status: 200, headers: {}, body: barrier_document }
	]
});
let barrier_controller = telegram.create(barrier.app);
assert_equal(barrier_controller.start(), true);
barrier.filesystem.fail_on = 'rename';
assert_equal(barrier_controller.poll_once(), false);
assert_equal(barrier_controller.status().last_update_id, 799);
assert_equal(json(barrier.filesystem.readfile(offset_path)).last_update_id, 799);
assert_equal(length(barrier.submitted), 0);
assert_equal(length(barrier.audit), 0, 'later update crossed persistence barrier');
assert_equal(barrier_controller.status().last_error, 'INTERNAL');
assert_equal(barrier_controller.status().retry_after_ms, 1000);
assert_equal(active_timers(barrier.clock), 0,
	'external polling does not arm a miclashd timer');
assert_match(barrier.requests[0].url, /\/getUpdates\?offset=800&timeout=25/);
barrier.filesystem.fail_on = null;
assert_equal(barrier_controller.poll_once(), true);
assert_match(barrier.requests[1].url, /\/getUpdates\?offset=800&timeout=25/);
assert_equal(json(barrier.filesystem.readfile(offset_path)).last_update_id, 800);
assert_equal(barrier_controller.status().last_update_id, 801);
assert_equal(length(barrier.submitted), 0);
assert_equal(barrier_controller.status().retry_after_ms, 0);
assert_equal(active_timers(barrier.clock), 0,
	'manual poll coverage must not create a production polling timer');

// Telegram 429 honors retry_after; network failures back off exponentially.
let limited_poll = environment({ poll_replies: [ {
	status: 429,
	headers: { 'retry-after': '7' },
	body: '{"ok":false,"error_code":429,"parameters":{"retry_after":7}}'
} ] });
let limited_controller = telegram.create(limited_poll.app);
assert_equal(limited_controller.poll_once(), false);
assert_equal(limited_controller.status().retry_after_ms, 7000);
let network = environment({ poll_replies: [ 'DOWNLOAD_FAILED', 'DOWNLOAD_FAILED',
	{ status: 200, headers: {}, body: '{"ok":true,"result":[]}' } ] });
let network_controller = telegram.create(network.app);
assert_equal(network_controller.poll_once(), false);
assert_equal(network_controller.status().retry_after_ms, 1000);
assert_equal(network.logs[length(network.logs) - 1],
	'telegram: poll failed: DOWNLOAD_FAILED');
assert_equal(network_controller.poll_once(), false);
assert_equal(network_controller.status().retry_after_ms, 2000);
assert_equal(length(network.logs), 1,
	'a retry must not repeat the same Telegram transport warning in the log');
assert_equal(network_controller.poll_once(), true);
assert_equal(network.logs[length(network.logs) - 1],
	'telegram: polling recovered after 2 failures');

// The separate miclash-telegram-poller owns network long polling. miclashd
// must stay responsive to unrelated ubus reads while receiving worker telemetry.
let lifecycle = environment();
let lifecycle_controller = telegram.create(lifecycle.app);
assert_equal(lifecycle_controller.start(), true);
assert_equal(lifecycle_controller.start(), false);
assert_equal(lifecycle_controller.status().running, true);
assert_equal(active_timers(lifecycle.clock), 0,
	'the controller must not create a second synchronous Telegram poller');
assert_equal(lifecycle_controller.poll_report({
	success: false, error: 'DOWNLOAD_FAILED', retry_after_ms: 1000
}), true);
assert_equal(lifecycle_controller.status().last_error, 'DOWNLOAD_FAILED');
assert_equal(lifecycle_controller.poll_report({
	success: true, error: '', retry_after_ms: 0
}), true);
assert_equal(lifecycle_controller.status().last_success_at, lifecycle.clock.now());
assert_equal(lifecycle_controller.stop(), true);
assert_equal(lifecycle_controller.stop(), false);
assert_equal(lifecycle_controller.status().running, false);

let dormant_lifecycle = environment();
let dormant_controller = telegram.create(dormant_lifecycle.app);
assert_equal(length(dormant_lifecycle.operation_subscribers), 2);
assert_equal(dormant_controller.stop(), false);
assert_equal(length(dormant_lifecycle.operation_subscribers), 0,
	'stop left Telegram operation subscriptions on a controller that was not running');

// A live 429 retry remains the sole owner of document delivery. The durable
// receipt must not race poll_once and then let the timer upload a duplicate.
let diagnostic_retry_race = environment({ document_replies: [
	{ status: 429, headers: { 'retry-after': '7' },
		body: '{"ok":false,"parameters":{"retry_after":7}}' },
	{ status: 200, headers: {}, body: '{"ok":true,"result":{"message_id":52}}' }
] });
let diagnostic_retry_race_controller = telegram.create(diagnostic_retry_race.app);
assert_equal(diagnostic_retry_race_controller.start(), true);
assert_equal(request_diagnostic(diagnostic_retry_race_controller, 712, 'lite'), true);
diagnostic_retry_race.emit_report('success', 'complete', 100);
assert_equal(diagnostic_retry_race.report_opens(), 1);
assert_equal(diagnostic_retry_race_controller.poll_once(), true);
assert_equal(diagnostic_retry_race.report_opens(), 1,
	'durable outbox raced the live diagnostic retry');
diagnostic_retry_race.clock.advance(7000);
assert_equal(diagnostic_retry_race.report_opens(), 2);
assert_equal(diagnostic_retry_race.report_finishes(), 1);
assert_equal(diagnostic_retry_race_controller.status().pending_deliveries, 0);

// Stop detaches the diagnostic listener and cancels/releases a pending document
// retry. Restarting the same controller re-arms one listener without replaying it.
let diagnostic_stop = environment({ document_replies: [ {
	status: 429, headers: { 'retry-after': '7' },
	body: '{"ok":false,"parameters":{"retry_after":7}}'
} ] });
let diagnostic_stop_controller = telegram.create(diagnostic_stop.app);
assert_equal(diagnostic_stop_controller.start(), true);
assert_equal(request_diagnostic(diagnostic_stop_controller, 711, 'lite'), true);
diagnostic_stop.emit_report('success', 'complete', 100);
assert_equal(diagnostic_stop.report_opens(), 1);
assert_equal(diagnostic_stop.report_closes(), 1);
assert_equal(active_timers(diagnostic_stop.clock), 1,
	'only the pending document retry owns a controller timer');
assert_equal(length(diagnostic_stop.operation_subscribers), 2);
assert_equal(diagnostic_stop_controller.status().pending_deliveries, 1);
assert_equal(diagnostic_stop_controller.stop(), true);
assert_equal(active_timers(diagnostic_stop.clock), 0);
assert_equal(length(diagnostic_stop.operation_subscribers), 0);
assert_equal(diagnostic_stop_controller.status().pending_deliveries, 0,
	'stop retained a canceled diagnostic retry as a pending delivery job');
diagnostic_stop.clock.advance(7000);
assert_equal(diagnostic_stop.report_opens(), 1);
assert_equal(diagnostic_stop_controller.start(), true);
assert_equal(length(diagnostic_stop.operation_subscribers), 2);

// Poll dispatch uses its validated settings snapshot; no handler-level reread can fail.
let snapshot = environment({ poll_replies: [ {
	status: 200,
	headers: {},
	body: sprintf('%J', { ok: true, result: [ update(900, '/menu') ] })
} ] });
let snapshot_reads = 0;
snapshot.app.settings_get = () => {
	snapshot_reads++;
	if (snapshot_reads <= 3)
		return clone(snapshot.settings);
	die('INTERNAL');
};
let snapshot_controller = telegram.create(snapshot.app);
assert_equal(snapshot_controller.start(), true);
assert_equal(snapshot_controller.poll_once(), true);
assert_equal(snapshot_reads, 3, 'menu panel reread settings more than once');
assert_equal(length(snapshot.submitted), 0);
assert_equal(active_timers(snapshot.clock), 0,
	'the controller does not schedule network polling after a settings snapshot');

// A controller records disabled/incomplete settings without creating a timer.
for (let change in [ 'disabled', 'incomplete' ]) {
	let inactive = environment();
	let inactive_controller = telegram.create(inactive.app);
	assert_equal(inactive_controller.start(), true);
	if (change == 'disabled')
		inactive.settings.telegram.enabled = false;
	else
		inactive.settings.telegram.token = '';
	assert_equal(inactive_controller.poll_once(), false, change);
	assert_equal(active_timers(inactive.clock), 0, change);
	assert_equal(length(inactive.requests), 0, change);
}

// A settings read error remains distinguishable without adding a controller timer.
let settings_error = environment();
let settings_error_controller = telegram.create(settings_error.app);
assert_equal(settings_error_controller.start(), true);
settings_error.app.settings_get = () => die('INTERNAL');
assert_equal(settings_error_controller.poll_once(), false);
assert_equal(settings_error_controller.status().running, true);
assert_equal(settings_error_controller.status().last_error, 'SETTINGS_UNAVAILABLE');
assert_equal(settings_error_controller.status().retry_after_ms, 1000);
assert_equal(active_timers(settings_error.clock), 0);
assert_equal(length(settings_error.requests), 0);

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

// Settings, notification payloads, and internal failure logs remain redacted;
// sending failures are isolated from the controller.
let masking = environment({ send_failure: true });
let masking_controller = telegram.create(masking.app);
assert_equal(masking_controller.test(), false);
let masking_event_accepted = masking_controller.send_event({
	type: 'failure', severity: 'error', component: 'routing',
	title: 'Routing failed', message: 'https://user:pass@example.test/?token=event-secret',
	dedupe_key: 'failure/failure-1-1710000000000', occurred_at: 1710000000000,
	recovery_of: null, context: { authorization: 'Bearer context-secret' }
});
assert_equal(masking_event_accepted, true,
	'notification enqueue failed: ' + masking_controller.status().last_error);
assert_equal(masking_controller.status().pending_deliveries, 1);
assert_equal(masking_controller.send_event({
	type: 'failure', severity: 'error', component: 'routing',
	title: 'Routing failed', message: 'Repeated routing failure',
	dedupe_key: 'failure/failure-1-1710000000000', occurred_at: 1710000001000,
	recovery_of: null, context: {}
}), true);
assert_equal(masking_controller.status().pending_deliveries, 1,
	'repeated automatic outcomes are coalesced while Telegram is unavailable');
let public_state = sprintf('%J', masking_controller.status());
for (let secret in [ 'telegram-secret', 'event-secret', 'context-secret', 'user:pass', '42' ])
	assert_equal(index(public_state, secret), -1, 'public state leaked ' + secret);
assert_true(length(masking.logs) == 0 || index(sprintf('%J', masking.logs), 'telegram-secret') < 0);

// Every notification family has a concise, redacted and URL-adapter-bounded format.
let notification_cases = [
	[ 'failure', 'Failure' ],
	[ 'recovery', 'Recovery' ],
	[ 'update_outcome', 'Update' ],
	[ 'subscription_outcome', 'Subscription' ],
	[ 'memory_outcome', 'Memory' ],
	[ 'guard_outage', 'Guard%20outage' ]
];
for (let item in notification_cases) {
	let family = environment({ locale: 'en' });
	let family_controller = telegram.create(family.app);
	assert_equal(family_controller.send_event({
		type: item[0], severity: 'warning', component: 'test',
		title: 'Family title',
		message: 'Family message https://user:pass@example.test/?token=family-secret ' +
			sprintf('%01000d', 0),
		dedupe_key: 'family/test', occurred_at: 1710000000000,
		recovery_of: null, context: { authorization: 'Bearer context-secret' }
	}), true, item[0]);
	let request_url = family.requests[0].url, request_body = family.requests[0].body ?? '';
	assert_true(index(request_body, 'text=' + item[1] + '%3A%20') >= 0,
		item[0] + ': ' + request_body);
	assert_true(length(request_url) <= 2048, item[0] + ' URL was not bounded');
	assert_true(length(request_body) <= 8192, item[0] + ' body was not bounded');
	for (let secret in [ 'family-secret', 'context-secret', 'user:pass' ])
		assert_equal(index(request_url + request_body, secret), -1, item[0] + ' leaked ' + secret);
}

// Automatic notifications follow the configured Telegram locale too.
let localized_notice = environment({ locale: 'ru' });
let localized_notice_controller = telegram.create(localized_notice.app);
assert_equal(localized_notice_controller.send_event({
	type: 'failure', severity: 'error', component: 'routing',
	title: 'Routing failed', message: 'Маршрут недоступен',
	dedupe_key: 'failure/routing', occurred_at: 1710000000000,
	recovery_of: null, context: {}
}), true);
assert_match(localized_notice.requests[0].body,
	/text=%D0%9E%D1%88%D0%B8%D0%B1%D0%BA%D0%B0%3A%20/,
	'automatic notification label ignored the Russian bot locale');

// Notification subscription formats supported events and isolates Telegram failure.
let notify_env = environment({ send_failure: true });
let notify_controller = telegram.create(notify_env.app);
let runtime = {
	clock: notify_env.clock,
	random: notify_env.app.runtime.random,
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

// The interactive panel edits one message, acknowledges callbacks first, and
// confirms dangerous button actions without slowing down direct slash commands.
let panel_env = environment(), panel_controller = telegram.create(panel_env.app);
assert_equal(panel_controller.handle_update(update(2000, '/start')), true);
assert_equal(request_method(panel_env.requests[0]), 'sendMessage');
assert_equal(panel_env.requests[0].method, 'POST');
assert_true(index(panel_env.requests[0].body, 'reply_markup=') >= 0);
assert_equal(panel_controller.handle_update(update(2001, '/start')), true);
assert_equal(request_method(panel_env.requests[1]), 'sendMessage');
assert_equal(panel_controller.handle_update(callback(2002, 'g2:open:management')), true);
assert_equal(request_method(panel_env.requests[2]), 'answerCallbackQuery');
assert_equal(request_method(panel_env.requests[3]), 'editMessageText');
assert_equal(panel_controller.handle_update(callback(2003, 'g3:confirm:stop')), true);
	assert_equal(length(panel_env.submitted), 0, 'confirmation screen executed stop');
assert_equal(panel_controller.handle_update(callback(2004, 'g4:execute:stop')), true);
	assert_equal(panel_env.submitted[0].kind, 'service.stop');
assert_equal(panel_controller.handle_update(callback(2004, 'g4:execute:stop')), false,
	'duplicate callback executed twice');

// The confirmed release action and exact target survive the callback round trip.
// A lower release must never be silently converted into an ordinary update.
let downgrade_env = environment({
	locale: 'en',
	app_version: '2.5.4',
	miclash_release: 'v2.5.3'
});
let downgrade_controller = telegram.create(downgrade_env.app);
assert_equal(downgrade_controller.handle_update(update(2050, '/start')), true);
assert_equal(downgrade_controller.handle_update(
	callback(2051, 'g1:open:updates')), true);
assert_equal(downgrade_controller.handle_update(
	callback(2052, 'g2:confirm:update_miclash')), true);
assert_equal(downgrade_controller.handle_update(
	callback(2053, 'g3:execute:update_miclash')), true);
let downgrade_call = null;
for (let index = length(downgrade_env.domain_calls) - 1; index >= 0; index--)
	if (downgrade_env.domain_calls[index].method == 'update_miclash') {
		downgrade_call = downgrade_env.domain_calls[index];
		break;
	}
assert_equal(downgrade_call.method, 'update_miclash');
assert_equal(downgrade_call.args[0], 'downgrade');
assert_equal(downgrade_call.args[1], 'v2.5.3');
assert_equal(downgrade_call.args[2], 'telegram');
let downgrade_completed = { ...downgrade_env.submitted[0], state: 'success',
	stage: 'complete', progress: 100, error: null };
downgrade_env.submitted[0] = downgrade_completed;
downgrade_env.operation_subscribers[0](downgrade_completed);
assert_equal(downgrade_controller.poll_once(), true);
let downgrade_result = null;
for (let request in downgrade_env.requests)
	if (request_method(request) == 'editMessageText') downgrade_result = request;
assert_match(downgrade_result.body, /Downgrade%20MiClash/,
	'completed downgrade was mislabeled as an update');

let direct_env = environment(), direct_controller = telegram.create(direct_env.app);
assert_equal(direct_controller.handle_update(update(2100, '/stop_service')), false);
assert_equal(length(direct_env.submitted), 0);
assert_equal(direct_controller.handle_update(update(2101, '/stop')), false);

// Every configured administrator receives replies in their own private chat.
let multi_admin_env = environment({ settings: {
	telegram: { enabled: true, token: '123456:telegram-secret', user_id: '42, 84' },
	core: { subscription_url: 'https://example.test/current', proxy_mode: 'tproxy' }
} }), multi_admin_controller = telegram.create(multi_admin_env.app);
assert_equal(multi_admin_controller.handle_update(update(2200, '/start', 84)), true);
assert_match(multi_admin_env.requests[0].body, /(^|&)chat_id=84(&|$)/);

// Administrator add/remove conversations stay inside the editable panel and
// submit the complete canonical ID list through the typed settings operation.
let admin_env = environment({ settings: {
	telegram: { enabled: true, token: '123456:telegram-secret', user_id: '42, 84' },
	core: { subscription_url: 'https://example.test/current', proxy_mode: 'tproxy' }
} }), admin_controller = telegram.create(admin_env.app);
assert_equal(admin_controller.handle_update(update(2300, '/start')), true);
assert_equal(admin_controller.handle_update(callback(2301, 'g1:open:settings')), true);
assert_equal(admin_controller.handle_update(callback(2302, 'g2:execute:add_admin')), true);
assert_equal(admin_controller.status().awaiting, 'add_admin');
assert_equal(admin_controller.status().panel_screen, 'admin_input');
assert_equal(admin_controller.handle_update(update(2303, '126')), true);
assert_equal(admin_env.submitted[0].kind, 'settings.set');
assert_equal(admin_env.submitted[0].context.patch.telegram.user_id, '42, 84, 126');

let remove_env = environment({ settings: {
	telegram: { enabled: true, token: '123456:telegram-secret', user_id: '42, 84' },
	core: { subscription_url: 'https://example.test/current', proxy_mode: 'tproxy' }
} }), remove_controller = telegram.create(remove_env.app);
remove_controller.handle_update(update(2400, '/start'));
remove_controller.handle_update(callback(2401, 'g1:open:settings'));
remove_controller.handle_update(callback(2402, 'g2:execute:remove_admin'));
assert_equal(remove_controller.handle_update(update(2403, '84')), true);
assert_equal(remove_controller.status().panel_screen, 'confirm_admin_remove');
assert_equal(remove_controller.handle_update(callback(2404, 'g4:execute:remove_admin')), true);
assert_equal(remove_env.submitted[0].context.patch.telegram.user_id, '42');
assert_equal(remove_controller.status().panel_screen, 'operation_loading');

// Subscription replacement is a bounded conversation. Accepted URL messages
// are deleted, while invalid input remains available for correction.
let subscription_env = environment(), subscription_controller = telegram.create(subscription_env.app);
assert_equal(subscription_controller.handle_update(update(3000, '/start')), true);
assert_equal(subscription_controller.handle_update(
	callback(3001, 'g1:open:subscription')), true);
assert_equal(subscription_controller.handle_update(
	callback(3002, 'g2:execute:replace_subscription')), true);
let before_invalid = length(subscription_env.requests);
assert_equal(subscription_controller.handle_update(update(3003, 'not-a-url')), false);
assert_equal(length(subscription_env.submitted), 0);
for (let index = before_invalid; index < length(subscription_env.requests); index++)
	assert_true(request_method(subscription_env.requests[index]) != 'deleteMessage');
assert_equal(subscription_controller.handle_update(
	update(3004, 'https://subscriptions.example.test/new.yaml?token=user-secret')), true);
assert_equal(subscription_env.submitted[0].kind, 'subscription.update');
let subscription_call = null;
for (let call in subscription_env.domain_calls)
	if (call.method == 'subscription_update') subscription_call = call;
assert_equal(subscription_call.args[0], 'https://subscriptions.example.test/new.yaml?token=user-secret');
assert_true(index(join(',', map(subscription_env.requests, request_method)), 'deleteMessage') >= 0);
assert_equal(subscription_controller.status().panel_screen, 'subscription_loading',
	'subscription replacement did not remain on its loading screen');

// A completed Telegram operation has a dedicated result state before the user
// returns to the refreshed source section. The result must never be glued into
// the navigable menu text.
let completion_env = environment(), completion_controller = telegram.create(completion_env.app);
assert_equal(completion_controller.handle_update(update(3050, '/start')), true);
assert_equal(completion_controller.handle_update(callback(3051, 'g1:open:subscription')), true);
assert_equal(completion_controller.handle_update(callback(3052, 'g2:execute:update_subscription')), true);
let completed = { ...completion_env.submitted[0], state: 'success', stage: 'complete',
	progress: 100, error: null };
completion_env.submitted[0] = completed;
completion_env.operation_subscribers[0](completed);
assert_equal(completion_controller.poll_once(), true);
let completion_edit = null;
for (let request in completion_env.requests)
	if (request_method(request) == 'editMessageText') completion_edit = request;
assert_true(completion_edit != null, 'completed operation did not edit the panel');
assert_equal(request_method(completion_edit), 'editMessageText');
assert_match(completion_edit.body, /(^|&)chat_id=42(&|$)/);
assert_match(completion_edit.body, /(^|&)message_id=50(&|$)/);
assert_match(completion_edit.body, /(^|&)text=[^&]+/);
assert_equal(completion_controller.status().panel_screen, 'operation_result');

// Production uses the external long-poll process and telegram_ingest(); it never
// calls controller.poll_once(). A terminal operation must therefore wake its
// own durable receipt delivery loop.
let ingest_completion_env = environment();
let ingest_completion_controller = telegram.create(ingest_completion_env.app);
assert_equal(ingest_completion_controller.start(), true);
assert_equal(ingest_completion_controller.ingest(update(3060, '/start')).handled, true);
assert_equal(ingest_completion_controller.ingest(
	callback(3061, 'g1:open:subscription')).handled, true);
assert_equal(ingest_completion_controller.ingest(
	callback(3062, 'g2:execute:update_subscription')).handled, true);
let ingest_completed = { ...ingest_completion_env.submitted[0], state: 'success',
	stage: 'complete', progress: 100, error: null };
ingest_completion_env.submitted[0] = ingest_completed;
ingest_completion_env.operation_subscribers[0](ingest_completed);
ingest_completion_env.clock.advance(0);
let ingest_completion_edit = null;
for (let request in ingest_completion_env.requests)
	if (request_method(request) == 'editMessageText')
		ingest_completion_edit = request;
assert_true(ingest_completion_edit != null,
	'external telegram_ingest flow did not deliver the terminal operation receipt');
assert_equal(ingest_completion_controller.status().pending_deliveries, 0);

let expired_env = environment(), expired_controller = telegram.create(expired_env.app);
expired_controller.handle_update(update(3100, '/start'));
expired_controller.handle_update(callback(3101, 'g1:open:subscription'));
expired_controller.handle_update(callback(3102, 'g2:execute:replace_subscription'));
expired_env.clock.advance(600001);
assert_equal(expired_controller.handle_update(update(3103,
	'https://subscriptions.example.test/expired')), false);
assert_equal(length(expired_env.submitted), 0);

// BotFather commands follow the active MiClash locale; synchronization failure
// is reported but does not disable polling.
let command_env = environment(), command_controller = telegram.create(command_env.app);
assert_equal(command_controller.configure(), true);
assert_equal(length(command_env.requests), 0,
	'BotFather synchronization must not block settings RPC');
assert_equal(command_controller.start(), true);
assert_equal(command_controller.poll_once(), true);
assert_equal(request_method(command_env.requests[0]), 'getUpdates');
assert_equal(request_method(command_env.requests[1]), 'setMyCommands');
assert_equal(request_method(command_env.requests[2]), 'setMyCommands');
assert_equal(command_env.requests[2].method, 'POST');
assert_true(index(command_env.requests[2].body, 'language_code=ru') >= 0);

// API exposes only redacted Telegram reads and an isolated channel test.
let api_env = environment();
let controller = telegram.create(api_env.app);
assert_equal(sprintf('%J', sort(keys(controller))), sprintf('%J', sort([
	'configure', 'start', 'stop', 'status', 'test', 'poll_once', 'poll_report', 'handle_update', 'ingest', 'send_event'
])));
let minimal_app = {
	status: () => ({}), overview: () => ({}), health: () => ({}), operation_get: () => null,
	operation_list: () => [], service_start: () => ({ id: 'op-1' }),
	service_stop: () => ({ id: 'op-1' }), service_reload: () => ({ id: 'op-1' }),
	service_restart: () => ({ id: 'op-1' }), network_recover: () => ({ id: 'op-1' }),
	developer_uninstall: () => ({ accepted: true }),
	config_list: () => [],
	config_read: () => '', config_validate: () => ({ id: 'op-1' }),
	config_apply: () => ({ id: 'op-1' }),
	operational_settings_apply: () => ({ id: 'op-1' }),
	config_swap: () => ({ id: 'op-1' }), settings_get: () => ({}),
	settings_set: () => ({ id: 'op-1' }), set_draining: () => null,
	guard_transition: () => ({ id: 'op-1' }),
	telegram_status: () => controller.status(),
	telegram_settings: () => api_env.settings.telegram,
	telegram_test: () => controller.test(),
	telegram_ingest: (update) => controller.ingest(update),
	telegram_poll_report: (report) => controller.poll_report(report)
};
let methods = api.method_table(minimal_app);
assert_true(methods.telegram_status != null);
assert_true(methods.telegram_settings != null);
assert_true(methods.telegram_test != null);
assert_true(methods.telegram_poll_report != null);
assert_equal(length(keys(methods.telegram_status.args)), 1);
assert_equal(methods.telegram_status.args.ubus_rpc_session, '');
assert_equal(length(keys(methods.telegram_settings.args)), 1);
assert_equal(methods.telegram_settings.args.ubus_rpc_session, '');
assert_equal(length(keys(methods.telegram_test.args)), 1);
assert_equal(methods.telegram_test.args.ubus_rpc_session, '');
assert_equal(methods.telegram_poll_report.args.ubus_rpc_session, '');
let telegram_settings = methods.telegram_settings.call({ args: {} });
assert_equal(telegram_settings.token, api_env.settings.telegram.token,
	'Telegram Settings may hydrate its password field without a reveal-time request');
assert_equal(telegram_settings.user_id, api_env.settings.telegram.user_id);
assert_equal(methods.telegram_test.call({ args: {} }).sent, true);
