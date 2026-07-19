import * as errors from 'miclash.errors';
import * as redact from 'miclash.redact';
import * as schema from 'miclash.schema';
import * as storage from 'miclash.storage';
import * as telegram_transport from 'miclash.telegram-transport';

const OFFSET_NAME = 'telegram-offset.json';
// miclashd serves ubus and timers on one event loop. Telegram long polling would
// monopolize that loop and make unrelated LuCI RPC calls time out, so use a
// bounded short poll and leave an explicit gap before the next request.
const MAX_MESSAGE_BYTES = 480;
const MAX_COMMANDS = 5;
const RATE_WINDOW_MS = 60000;
const MAX_BACKOFF_MS = 60000;
const SUCCESS_DELAY_MS = 3000;
const HELP = '/start /menu /status /health /memory /diagnostics /logs /help ' +
	'/start_service /stop_service /restart_service /reload_service /reboot_router ' +
	'/subscription URL /update_subscription ' +
	'/update_miclash /update_mihomo /guard_on /guard_off';

function invalid() { errors.fail('INVALID_ARGUMENT'); };
function corrupt() { errors.fail('CORRUPT_STATE'); };

function same_directory(left, right) {
	return left?.type == 'directory' && right?.type == 'directory' &&
		left.inode == right.inode && left.dev?.major == right.dev?.major &&
		left.dev?.minor == right.dev?.minor;
};

function same_file(left, right) {
	return left?.type == 'file' && right?.type == 'file' &&
		left.inode == right.inode && left.dev?.major == right.dev?.major &&
		left.dev?.minor == right.dev?.minor && left.nlink == right.nlink &&
		left.size == right.size && left.mode == right.mode && left.uid == right.uid;
};

function persistent_authority(runtime) {
	let authority = runtime.fs.lstat(runtime.paths.etc);
	if (authority?.type != 'directory' || authority.mode != 0o700 ||
	    (authority.uid != null && authority.uid != 0) ||
	    runtime.fs.realpath(runtime.paths.etc) != runtime.paths.etc)
		invalid();
	return authority;
};

function offset_path(runtime) {
	return runtime.paths.etc + '/' + OFFSET_NAME;
};

function offset_identity(runtime, authority) {
	let path = offset_path(runtime);
	let identity = runtime.fs.lstat(path);
	if (identity == null)
		return null;
	if (identity.type != 'file' || identity.mode != 0o600 || identity.nlink != 1 ||
	    (identity.uid != null && identity.uid != 0) ||
	    runtime.fs.realpath(path) != path ||
	    identity.dev?.major != authority.dev?.major ||
	    identity.dev?.minor != authority.dev?.minor)
		corrupt();
	return identity;
};

function read_offset(runtime) {
	let authority = persistent_authority(runtime);
	let before = offset_identity(runtime, authority);
	let source = runtime.fs.readfile(offset_path(runtime));
	let after = offset_identity(runtime, authority);
	let current_authority = persistent_authority(runtime);
	if (!same_directory(authority, current_authority) ||
	    (before == null ? source != null || after != null :
		(type(source) != 'string' || !same_file(before, after))))
		corrupt();
	if (source == null)
		return -1;
	let offset;
	try { offset = json(source); }
	catch (error) { corrupt(); }
	if (type(offset) != 'object' || length(keys(offset)) != 1 ||
	    type(offset.last_update_id) != 'int' || offset.last_update_id < 0)
		corrupt();
	return offset.last_update_id;
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

function configuration(app) {
	let all;
	try { all = app.settings_get(); }
	catch (error) {
		return {
			available: false, enabled: false, configured: false,
			token: null, user_id: null
		};
	}
	let value = all?.telegram;
	let enabled = type(value?.enabled) == 'bool' && value.enabled;
	let token = type(value?.token) == 'string' &&
		match(value.token, /^[1-9][0-9]{0,19}:[A-Za-z0-9_-]{8,128}$/) ? value.token : null;
	let user_id = normalized_id(value?.user_id);
	return {
		available: true, enabled, configured: token != null && user_id != null,
		token, user_id
	};
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
	return 'Queued ' + record.kind + ' (' + record.id + ')';
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
	return label + ': ' + details;
};

export function create(app) {
	if (type(app) != 'object' || type(app.runtime?.fs) != 'object' ||
	    type(app.runtime?.digest) != 'object' || type(app.runtime?.clock?.now) != 'function' ||
	    type(app.runtime?.clock?.set_timeout) != 'function' ||
	    app.runtime?.paths?.etc != '/etc/miclash' ||
	    app.runtime?.paths?.run != '/var/run/miclash' ||
	    type(app.http?.request) != 'function' || type(app.settings_get) != 'function' ||
	    type(app.operations?.submit) != 'function')
		invalid();
	for (let method in [ 'status', 'health', 'memory_status', 'diagnostics_summary',
		'logs_read', 'service_start', 'service_stop', 'service_restart', 'service_reload',
		'reboot', 'subscription_update', 'update_miclash', 'update_mihomo',
		'settings_set', 'guard_transition' ])
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
	let transport = telegram_transport.create(app);

	state.last_update_id = read_offset(app.runtime);

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
		let authority = persistent_authority(app.runtime);
		let path = offset_path(app.runtime);
		storage.write_json(app.runtime, path, { last_update_id: update_id }, 0o600);
		let identity = offset_identity(app.runtime, authority);
		if (identity == null)
			errors.fail('INTERNAL');
		let persisted;
		try { persisted = json(app.runtime.fs.readfile(path)); }
		catch (error) { errors.fail('INTERNAL'); }
		let verified = offset_identity(app.runtime, authority);
		let current_authority = persistent_authority(app.runtime);
		if (!same_directory(authority, current_authority) || !same_file(identity, verified) ||
		    type(persisted) != 'object' ||
		    length(keys(persisted)) != 1 || persisted.last_update_id != update_id)
			errors.fail('INTERNAL');
		state.last_update_id = update_id;
	};

	function send_message(text, settings) {
		settings = settings ?? configuration(app);
		if (!settings.available || !settings.enabled || !settings.configured)
			return false;
		try {
			return transport.send(settings, settings.user_id, bounded_text(text), null) != null;
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
			'/start': 'menu', '/menu': 'menu',
			'/start_service': 'start_service', '/stop_service': 'stop_service',
			'/restart_service': 'restart_service', '/reload_service': 'reload_service',
			'/reboot_router': 'reboot_router',
			'/update_subscription': 'update_subscription',
			'/update_miclash': 'update_miclash', '/update_mihomo': 'update_mihomo',
			'/guard_on': 'guard_on', '/guard_off': 'guard_off'
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
			return app.status();
		if (command.name == 'health')
			return app.health();
		if (command.name == 'memory')
			return app.memory_status();
		if (command.name == 'diagnostics')
			return app.diagnostics_summary();
		if (command.name == 'logs')
			return app.logs_read();
		if (command.name == 'help')
			return HELP;
		if (command.name == 'menu')
			return HELP;
		if (command.name == 'start_service')
			return operation_message(app.service_start('config.yaml', 'telegram'));
		if (command.name == 'stop_service')
			return operation_message(app.service_stop('config.yaml', 'telegram'));
		if (command.name == 'restart_service')
			return operation_message(app.service_restart('config.yaml', 'telegram'));
		if (command.name == 'reload_service')
			return operation_message(app.service_reload('config.yaml', 'telegram'));
		if (command.name == 'reboot_router') {
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
			return operation_message(app.guard_transition(true, 'telegram'));
		if (command.name == 'guard_off')
			return operation_message(app.guard_transition(false, 'telegram'));
		invalid();
	};

	function handle_update(update, settings) {
		if (!settings.available || !settings.enabled || !settings.configured ||
		    type(update) != 'object' ||
		    type(update.update_id) != 'int' || update.update_id < 0 ||
		    update.update_id <= state.last_update_id)
			return { handled: false, retryable: false };
		let message = update.message;
		let sender = normalized_id(message?.from?.id);
		let chat = normalized_id(message?.chat?.id);
		if (type(message) != 'object' || message.chat?.type != 'private' ||
		    message.from?.is_bot === true || sender != settings.user_id || chat != settings.user_id) {
			state.last_update_id = update.update_id;
			audit('message', 'rejected', update.update_id);
			return { handled: false, retryable: false };
		}
		let command = parse_command(message.text);
		if (command == null) {
			state.last_update_id = update.update_id;
			audit('command', 'rejected', update.update_id);
			return { handled: false, retryable: false };
		}
		try { persist_offset(update.update_id); }
		catch (error) {
			log_failure('Telegram offset persistence failed');
			return { handled: false, retryable: true, error: 'INTERNAL' };
		}
		if (!rate_allowed(app.runtime.clock.now())) {
			audit(command.name, 'rate_limited', update.update_id);
			send_message('Rate limit exceeded', settings);
			return { handled: false, retryable: false };
		}
		let response;
		try { response = dispatch(command); }
		catch (error) {
			audit(command.name, 'failed', update.update_id);
			send_message('Command failed', settings);
			return { handled: false, retryable: false };
		}
		audit(command.name, 'accepted', update.update_id);
		send_message(response, settings);
		return { handled: true, retryable: false };
	};

	let controller = {};
	controller.status = () => {
		let settings = configuration(app);
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
	controller.handle_update = (update) =>
		handle_update(update, configuration(app)).handled;
	controller.poll_once = () => {
		let settings = configuration(app);
		if (!settings.available) {
			state.failures++;
			state.last_error = 'SETTINGS_UNAVAILABLE';
			state.retry_after_ms = min(MAX_BACKOFF_MS,
				1000 * (1 << min(state.failures - 1, 6)));
			return false;
		}
		if (!settings.enabled || !settings.configured) {
			state.running = false;
			if (timer?.cancel != null)
				timer.cancel();
			timer = null;
			state.last_error = null;
			state.retry_after_ms = 0;
			state.failures = 0;
			return false;
		}
		state.last_poll_at = app.runtime.clock.now();
		try {
			let reply = transport.poll(settings, state.last_update_id);
			if (reply.retry_after_ms > 0) {
				state.failures++;
				state.last_error = 'RATE_LIMITED';
				state.retry_after_ms = reply.retry_after_ms;
				return false;
			}
			if (type(reply.updates) != 'array' || length(reply.updates) > 100)
				errors.fail('INVALID_RESPONSE');
			for (let update in reply.updates) {
				let outcome = handle_update(update, settings);
				if (outcome.retryable)
					errors.fail(outcome.error);
			}
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
		let candidate = null;
		try { candidate = app.runtime.clock.set_timeout(delay, () => {
			timer = null;
			if (!state.running)
				return;
			controller.poll_once();
			if (!state.running)
				return;
			try { schedule(state.retry_after_ms > 0 ? state.retry_after_ms : SUCCESS_DELAY_MS); }
			catch (error) {
				state.running = false;
				state.last_error = 'INTERNAL';
				state.retry_after_ms = 0;
			}
		}); }
		catch (error) { errors.fail('INTERNAL'); }
		if (candidate == null || type(candidate.cancel) != 'function') {
			try { candidate?.cancel?.(); } catch (error) {}
			errors.fail('INTERNAL');
		}
		timer = candidate;
		return true;
	};
	controller.start = () => {
		let settings = configuration(app);
		if (state.running || !settings.available || !settings.enabled || !settings.configured)
			return false;
		state.running = true;
		try { schedule(0); }
		catch (error) {
			state.running = false;
			if (timer?.cancel != null) try { timer.cancel(); } catch (cancel_error) {}
			timer = null;
			errors.fail('INTERNAL');
		}
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
