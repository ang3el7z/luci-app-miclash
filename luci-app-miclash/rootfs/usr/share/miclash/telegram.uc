import * as errors from 'miclash.errors';
import * as redact from 'miclash.redact';
import * as schema from 'miclash.schema';
import * as storage from 'miclash.storage';

const OFFSET_PATH = '/var/run/miclash/telegram-offset.json';
const POLL_TIMEOUT_SECONDS = 20;
const REQUEST_TIMEOUT_MS = 30000;
const CONNECT_TIMEOUT_MS = 5000;
const RESPONSE_LIMIT = 65536;
const MAX_MESSAGE_BYTES = 480;
const MAX_COMMANDS = 5;
const RATE_WINDOW_MS = 60000;
const MAX_BACKOFF_MS = 60000;
const SUCCESS_DELAY_MS = 10;
const HELP = '/status /health /memory /diagnostics /logs /help /start /stop ' +
	'/restart /reload /reboot /subscription URL /update_subscription ' +
	'/update_miclash /update_mihomo /guard_on /guard_off /backup';

function invalid() { errors.fail('INVALID_ARGUMENT'); };

function clone(value) {
	try { return json(sprintf('%J', value)); }
	catch (error) { invalid(); }
};

function normalized_id(value) {
	let input;
	if (type(value) == 'int') {
		if (value <= 0)
			return null;
		input = sprintf('%d', value);
	}
	else if (type(value) == 'string' && match(value, /^[0-9]+$/))
		input = value;
	else
		return null;
	input = replace(input, /^0+/, '');
	return length(input) ? input : null;
};

function configured(app) {
	let all;
	try { all = app.settings_get(); }
	catch (error) { return { enabled: false, configured: false, token: null, user_id: null }; }
	let value = all?.telegram;
	let enabled = type(value?.enabled) == 'bool' && value.enabled;
	let token = type(value?.token) == 'string' &&
		match(value.token, /^[0-9]{1,20}:[A-Za-z0-9_-]{8,128}$/) ? value.token : null;
	let user_id = normalized_id(value?.user_id);
	return { enabled, configured: token != null && user_id != null, token, user_id };
};

function percent_encode(value) {
	let output = '';
	for (let offset = 0; offset < length(value); offset++) {
		let character = substr(value, offset, 1);
		output += match(character, /^[A-Za-z0-9_.~-]$/) ? character :
			sprintf('%%%02X', ord(value, offset));
	}
	return output;
};

function bounded_text(value) {
	let safe;
	try {
		if (type(value) == 'string')
			safe = redact.sanitize({ output: substr(value, 0, 8192) }).output;
		else
			safe = sprintf('%J', redact.sanitize(value));
	}
	catch (error) { safe = 'Unavailable'; }
	safe = replace(safe, /[[:cntrl:]]+/, ' ');
	if (length(safe) > MAX_MESSAGE_BYTES)
		safe = substr(safe, 0, MAX_MESSAGE_BYTES - 3) + '...';
	return safe;
};

function operation_message(record) {
	if (type(record?.id) != 'string' || type(record?.kind) != 'string')
		return 'Command accepted';
	return bounded_text('Queued ' + record.kind + ' (' + record.id + ')');
};

function retry_seconds(reply, document) {
	let header = reply?.headers?.['retry-after'];
	let value = document?.parameters?.retry_after;
	if (type(value) != 'int' && type(header) == 'string' && match(header, /^[0-9]+$/))
		value = int(header);
	if (type(value) != 'int' || value < 1)
		value = 1;
	return min(value, 3600);
};

function parse_document(reply) {
	if (type(reply?.body) != 'string' || length(reply.body) > RESPONSE_LIMIT)
		errors.fail('INVALID_RESPONSE');
	let document;
	try { document = json(reply.body); }
	catch (error) { errors.fail('INVALID_RESPONSE'); }
	if (type(document) != 'object' || type(document.ok) != 'bool')
		errors.fail('INVALID_RESPONSE');
	return document;
};

function event_text(event) {
	let labels = {
		failure: 'Failure', guard_outage: 'Guard outage', fail_closed: 'Guard blocked',
		direct_fallback: 'Direct fallback', recovery: 'Recovery',
		internet_restored: 'Internet restored', update_outcome: 'Update',
		subscription_outcome: 'Subscription', memory_action: 'Memory',
		memory_outcome: 'Memory'
	};
	let label = labels[event?.type] ?? 'MiClash';
	let details = type(event?.message) == 'string' ? event.message :
		(type(event?.title) == 'string' ? event.title : 'State changed');
	return bounded_text(label + ': ' + details);
};

export function create(app) {
	if (type(app) != 'object' || type(app.runtime?.fs) != 'object' ||
	    type(app.runtime?.digest) != 'object' || type(app.runtime?.clock?.now) != 'function' ||
	    type(app.runtime?.clock?.set_timeout) != 'function' ||
	    app.runtime?.paths?.run != '/var/run/miclash' ||
	    type(app.http?.request) != 'function' || type(app.settings_get) != 'function' ||
	    type(app.operations?.submit) != 'function')
		invalid();
	for (let method in [ 'status', 'health', 'memory_status', 'diagnostics_summary',
		'logs_read', 'service_start', 'service_stop', 'service_restart', 'service_reload',
		'reboot', 'subscription_update', 'update_miclash', 'update_mihomo',
		'settings_set', 'backup_create' ])
		if (type(app[method]) != 'function')
			invalid();

	let state = {
		running: false,
		last_update_id: -1,
		last_poll_at: null,
		last_success_at: null,
		last_error: null,
		retry_after_ms: 0,
		failures: 0
	};
	let timer = null;
	let command_times = [];

	let stored = app.runtime.fs.readfile(OFFSET_PATH);
	if (stored != null) {
		let offset;
		try { offset = json(stored); }
		catch (error) { errors.fail('CORRUPT_STATE'); }
		if (type(offset) != 'object' || length(keys(offset)) != 1 ||
		    type(offset.last_update_id) != 'int' || offset.last_update_id < 0)
			errors.fail('CORRUPT_STATE');
		state.last_update_id = offset.last_update_id;
	}

	function log_failure(message) {
		try { app.logger?.warn(message); } catch (error) {}
	};

	function audit(action, result, update_id) {
		try {
			app.audit?.({
				source: 'telegram', action, result,
				update_id: type(update_id) == 'int' ? update_id : null,
				user_id: redact.MASK, chat_id: redact.MASK
			});
		}
		catch (error) {}
	};

	function persist_offset(update_id) {
		storage.write_json(app.runtime, OFFSET_PATH, { last_update_id: update_id }, 0o600);
		state.last_update_id = update_id;
	};

	function api_request(path, query, settings) {
		let parts = [];
		for (let name, value in query)
			push(parts, percent_encode(name) + '=' + percent_encode('' + value));
		let url = 'https://api.telegram.org/bot' + settings.token + '/' + path +
			(length(parts) ? '?' + join('&', parts) : '');
		return app.http.request(app.runtime, {
			url,
			connect_timeout_ms: CONNECT_TIMEOUT_MS,
			timeout_ms: REQUEST_TIMEOUT_MS,
			max_redirects: 0,
			max_bytes: RESPONSE_LIMIT,
			managed: true,
			accept_statuses: [ 429 ]
		});
	};

	function send_message(text) {
		let settings = configured(app);
		if (!settings.enabled || !settings.configured)
			return false;
		try {
			let reply = api_request('sendMessage', {
				chat_id: settings.user_id,
				text: bounded_text(text),
				disable_web_page_preview: 'true'
			}, settings);
			if (reply.status == 429)
				return false;
			let document = parse_document(reply);
			return reply.status >= 200 && reply.status < 300 && document.ok === true;
		}
		catch (error) {
			log_failure('Telegram delivery failed');
			return false;
		}
	};

	function rate_allowed(now) {
		let retained = [];
		for (let timestamp in command_times)
			if (timestamp <= now && now - timestamp < RATE_WINDOW_MS)
				push(retained, timestamp);
		command_times = retained;
		if (length(command_times) >= MAX_COMMANDS)
			return false;
		push(command_times, now);
		return true;
	};

	function parse_command(text) {
		if (type(text) != 'string' || !length(text) || length(text) > 4096 ||
		    match(text, /[[:cntrl:]]/))
			return null;
		let simple = {
			'/status': 'status', '/health': 'health', '/memory': 'memory',
			'/diagnostics': 'diagnostics', '/logs': 'logs', '/help': 'help',
			'/start': 'start', '/stop': 'stop', '/restart': 'restart',
			'/reload': 'reload', '/reboot': 'reboot',
			'/update_subscription': 'update_subscription',
			'/update_miclash': 'update_miclash', '/update_mihomo': 'update_mihomo',
			'/guard_on': 'guard_on', '/guard_off': 'guard_off', '/backup': 'backup'
		};
		if (simple[text] != null)
			return { name: simple[text], argument: null };
		let found = match(text, /^\/subscription ([^[:space:]]+)$/);
		if (found == null)
			return null;
		try { schema.url(found[1]); }
		catch (error) { return null; }
		return { name: 'subscription', argument: found[1] };
	};

	function dispatch(command) {
		if (command.name == 'status')
			return bounded_text(app.status());
		if (command.name == 'health')
			return bounded_text(app.health());
		if (command.name == 'memory')
			return bounded_text(app.memory_status());
		if (command.name == 'diagnostics')
			return bounded_text(app.diagnostics_summary());
		if (command.name == 'logs')
			return bounded_text(app.logs_read());
		if (command.name == 'help')
			return HELP;
		if (command.name == 'start')
			return operation_message(app.service_start('config.yaml', 'telegram'));
		if (command.name == 'stop')
			return operation_message(app.service_stop('config.yaml', 'telegram'));
		if (command.name == 'restart')
			return operation_message(app.service_restart('config.yaml', 'telegram'));
		if (command.name == 'reload')
			return operation_message(app.service_reload('config.yaml', 'telegram'));
		if (command.name == 'reboot') {
			let record = app.operations.submit('system.reboot', 'telegram', {}, (ctx) => {
				ctx.stage('reboot', 50, '');
				app.reboot();
			});
			return operation_message(record);
		}
		if (command.name == 'subscription')
			return operation_message(app.subscription_update(command.argument, 'telegram'));
		if (command.name == 'update_subscription')
			return operation_message(app.subscription_update(null, 'telegram'));
		if (command.name == 'update_miclash')
			return operation_message(app.update_miclash('telegram'));
		if (command.name == 'update_mihomo')
			return operation_message(app.update_mihomo('telegram'));
		if (command.name == 'guard_on')
			return operation_message(app.settings_set({ guard: { enabled: true } }, 'telegram'));
		if (command.name == 'guard_off')
			return operation_message(app.settings_set({ guard: { enabled: false } }, 'telegram'));
		if (command.name == 'backup')
			return operation_message(app.backup_create('telegram'));
		invalid();
	};

	let controller = {};
	controller.status = () => {
		let settings = configured(app);
		return {
			running: state.running,
			enabled: settings.enabled,
			configured: settings.configured,
			last_update_id: state.last_update_id,
			last_poll_at: state.last_poll_at,
			last_success_at: state.last_success_at,
			last_error: state.last_error,
			retry_after_ms: state.retry_after_ms,
			failures: state.failures
		};
	};
	controller.handle_update = (update) => {
		let settings = configured(app);
		if (!settings.enabled || !settings.configured || type(update) != 'object' ||
		    type(update.update_id) != 'int' || update.update_id < 0 ||
		    update.update_id <= state.last_update_id)
			return false;
		try { persist_offset(update.update_id); }
		catch (error) {
			log_failure('Telegram offset persistence failed');
			return false;
		}
		let message = update.message;
		let sender = normalized_id(message?.from?.id);
		let chat = normalized_id(message?.chat?.id);
		if (type(message) != 'object' || message.chat?.type != 'private' ||
		    message.from?.is_bot === true || sender != settings.user_id || chat != settings.user_id) {
			audit('message', 'rejected', update.update_id);
			return false;
		}
		let command = parse_command(message.text);
		if (command == null) {
			audit('command', 'rejected', update.update_id);
			return false;
		}
		if (!rate_allowed(app.runtime.clock.now())) {
			audit(command.name, 'rate_limited', update.update_id);
			send_message('Rate limit exceeded');
			return false;
		}
		let response;
		try { response = dispatch(command); }
		catch (error) {
			audit(command.name, 'failed', update.update_id);
			send_message('Command failed');
			return false;
		}
		audit(command.name, 'accepted', update.update_id);
		send_message(response);
		return true;
	};
	controller.poll_once = () => {
		let settings = configured(app);
		if (!settings.enabled || !settings.configured)
			return false;
		state.last_poll_at = app.runtime.clock.now();
		try {
			let reply = api_request('getUpdates', {
				offset: state.last_update_id + 1,
				timeout: POLL_TIMEOUT_SECONDS,
				limit: 20,
				allowed_updates: '["message"]'
			}, settings);
			let document = parse_document(reply);
			if (reply.status == 429 || document.error_code == 429) {
				state.failures++;
				state.last_error = 'RATE_LIMITED';
				state.retry_after_ms = retry_seconds(reply, document) * 1000;
				return false;
			}
			if (reply.status < 200 || reply.status >= 300 || document.ok !== true ||
			    type(document.result) != 'array' || length(document.result) > 100)
				errors.fail('INVALID_RESPONSE');
			for (let update in document.result)
				controller.handle_update(update);
			state.last_success_at = app.runtime.clock.now();
			state.last_error = null;
			state.retry_after_ms = 0;
			state.failures = 0;
			return true;
		}
		catch (error) {
			state.failures++;
			state.last_error = errors.normalize(error).code;
			state.retry_after_ms = min(MAX_BACKOFF_MS,
				1000 * (1 << min(state.failures - 1, 6)));
			log_failure('Telegram poll failed');
			return false;
		}
	};
	function schedule(delay) {
		timer = app.runtime.clock.set_timeout(delay, () => {
			timer = null;
			if (!state.running)
				return;
			controller.poll_once();
			schedule(state.retry_after_ms > 0 ? state.retry_after_ms : SUCCESS_DELAY_MS);
		});
	};
	controller.start = () => {
		let settings = configured(app);
		if (state.running || !settings.enabled || !settings.configured)
			return false;
		state.running = true;
		schedule(0);
		return true;
	};
	controller.stop = () => {
		if (!state.running)
			return false;
		state.running = false;
		if (timer?.cancel != null)
			timer.cancel();
		timer = null;
		return true;
	};
	controller.test = () => send_message('MiClash Telegram test');
	controller.send_event = (event) => {
		try { return send_message(event_text(event)); }
		catch (error) { return false; }
	};
	return controller;
};
