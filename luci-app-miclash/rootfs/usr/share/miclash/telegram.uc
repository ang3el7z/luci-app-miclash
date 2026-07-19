import * as errors from 'miclash.errors';
import * as redact from 'miclash.redact';
import * as schema from 'miclash.schema';
import * as storage from 'miclash.storage';
import * as telegram_i18n from 'miclash.telegram-i18n';
import * as telegram_menu from 'miclash.telegram-menu';
import * as telegram_outbox from 'miclash.telegram-outbox';
import * as telegram_operations from 'miclash.telegram-operations';
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
	let outbox = null, operation_bridge = null;
	let session = {
		generation: 0, screen: 'main', awaiting: null,
		command_locale: null, command_sync_error: null
	};

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

	function safe_call(callback, fallback) {
		try { return callback(); }
		catch (error) { return fallback; }
	};

	function component_state(health, name) {
		let value = health?.[name]?.state ?? health?.components?.[name]?.state;
		if (value == 'ok' || value == 'healthy') return 'ready';
		return value ?? 'unknown';
	};

	function panel_model(screen) {
		let wanted = safe_call(() => app.settings_get(), {});
		let status = safe_call(() => app.status(), {});
		let health = safe_call(() => app.health(), {});
		let info = type(app.system_info) == 'function' ? safe_call(() => app.system_info(), {}) : {};
		let observed_service = status?.observed?.service ?? status?.service ?? {};
		let running = observed_service.running === true || observed_service.state == 'running' ||
			status?.service_running === true;
		let memory = screen == 'memory' || screen == 'main' ?
			safe_call(() => app.memory_status(), {}) : {};
		let update_status = type(app.updates_status) == 'function' ?
			safe_call(() => app.updates_status(), {}) : {};
		let configured_url = wanted?.core?.subscription_url_config_yaml;
		if (type(configured_url) != 'string' || !length(configured_url))
			configured_url = wanted?.core?.subscription_url;
		return {
			miclash_version: info.app_version ?? status?.versions?.miclash ?? 'unknown',
			miclash_state: running ? 'running' : 'stopped',
			mihomo_version: info.mihomo?.version ?? status?.versions?.mihomo ?? 'unknown',
			mihomo_state: component_state(health, 'mihomo'),
			proxy_mode: wanted?.core?.proxy_mode ?? 'unknown',
			guard_enabled: wanted?.guard?.enabled === true,
			guard_observed: status?.observed?.guard?.state ??
				(wanted?.guard?.enabled === true ? 'enabled' : 'disabled'),
			internet_state: status?.observed?.internet?.state ?? 'unknown',
			service_running: running,
			dns_state: component_state(health, 'dns'),
			firewall_state: component_state(health, 'firewall'),
			routing_state: component_state(health, 'routing'),
			config_update_state: update_status.automatic_config?.state ??
				(wanted?.updates?.auto_subscription === true ? 'running' : 'disabled'),
			miclash_update_state: update_status.automatic_miclash?.state ??
				(wanted?.updates?.auto_major === true ? 'running' : 'disabled'),
			subscription_url: configured_url ?? '',
			last_subscription_update: update_status.automatic_config?.last_success_at ?? '',
			last_subscription_result: update_status.automatic_config?.last_result ?? '',
			memory_rss: memory.rss_human ?? memory.rss ?? memory.used ?? '',
			memory_baseline: memory.baseline_human ?? memory.baseline ?? '',
			memory_state: memory.state ?? memory.phase ?? '',
			last_memory_action: memory.last_action ?? memory.last_recovery ?? '',
			logs: screen == 'logs' ? safe_call(() => app.logs_read(), '') : '',
			diagnostics: screen == 'diagnostics' ?
				sprintf('%J', safe_call(() => app.diagnostics_summary(), {})) : '',
			updates: {
				miclash_installed: info.app_version ?? update_status.miclash?.installed ?? '',
				miclash_available: update_status.miclash?.available ?? update_status.available_miclash ?? '',
				mihomo_installed: info.mihomo?.version ?? update_status.mihomo?.installed ?? '',
				mihomo_available: update_status.mihomo?.available ?? update_status.available_mihomo ?? ''
			}
		};
	};

	function show_panel(screen, settings, target) {
		let locale = telegram_i18n.locale(app.runtime);
		session.generation++;
		if (session.generation > 999999999) session.generation = 1;
		let rendered = telegram_menu.render(screen, panel_model(screen), locale,
			session.generation);
		let identity = target ?? outbox.panel(), result = null;
		if (identity != null)
			try {
				result = transport.edit(settings, identity.chat_id, identity.message_id,
					rendered.text, rendered.reply_markup);
			}
			catch (error) { result = null; }
		if (result == null)
			result = transport.send(settings, settings.user_id, rendered.text,
				rendered.reply_markup);
		if (result == null) return false;
		outbox.panel({ chat_id: settings.user_id, message_id: result.message_id,
			generation: session.generation });
		session.screen = screen;
		return true;
	};

	function sync_commands(settings) {
		let locale = telegram_i18n.locale(app.runtime), commands = telegram_menu.commands(locale);
		if (transport.set_commands(settings, '', commands) !== true) return false;
		let language = telegram_i18n.telegram_language(locale);
		if (length(language) && transport.set_commands(settings, language, commands) !== true)
			return false;
		session.command_locale = locale;
		session.command_sync_error = null;
		return true;
	};

	function receipt_payload(record) {
		return {
			kind: record.kind, stage: record.stage, progress: record.progress,
			error: record.error?.code ?? null
		};
	};

	function deliver_receipt(entry, saved_panel) {
		if (entry.state != 'success' && entry.state != 'failure' && entry.state != 'interrupted')
			return false;
		let settings = configuration(app);
		if (!settings.available || !settings.enabled || !settings.configured ||
		    settings.user_id != entry.chat_id) return false;
		let state_key = entry.state == 'success' ? 'operation_success' :
			(entry.state == 'interrupted' ? 'operation_interrupted' : 'operation_failure');
		let prefix = telegram_i18n.text(entry.locale, 'operation_result', {
			operation: entry.kind, state: telegram_i18n.text(entry.locale, state_key)
		});
		if (entry.payload?.error != null) prefix += ' (' + entry.payload.error + ')';
		session.generation++;
		if (session.generation > 999999999) session.generation = 1;
		let rendered = telegram_menu.render('main', panel_model('main'), entry.locale,
			session.generation);
		let text = prefix + '\n\n' + rendered.text;
		let identity = entry.message_id != null ?
			{ chat_id: entry.chat_id, message_id: entry.message_id } : saved_panel;
		let result = null;
		if (identity != null)
			try { result = transport.edit(settings, identity.chat_id, identity.message_id,
				text, rendered.reply_markup); }
			catch (error) { result = null; }
		if (result == null)
			result = transport.send(settings, entry.chat_id, text, rendered.reply_markup);
		if (result == null) return false;
		session.screen = 'main';
		return { delivered: true, panel: { chat_id: entry.chat_id,
			message_id: result.message_id, generation: session.generation } };
	};

	outbox = telegram_outbox.create(app.runtime, deliver_receipt);
	operation_bridge = telegram_operations.create(app, outbox, receipt_payload);
	try { operation_bridge.recover(); } catch (error) {}

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
		let command = telegram_menu.parse_command(text);
		if (command?.name == 'subscription')
			try { schema.url(command.argument); }
			catch (error) { return null; }
		return command;
	};

	function dispatch(command, destination) {
		function response(value) { return { response: value, record: null }; };
		function mutation(record) {
			if (destination != null) operation_bridge.track(record, destination);
			return { response: operation_message(record), record };
		};
		if (command.name == 'status')
			return response(app.status());
		if (command.name == 'health')
			return response(app.health());
		if (command.name == 'memory')
			return response(app.memory_status());
		if (command.name == 'diagnostics')
			return response(app.diagnostics_summary());
		if (command.name == 'logs')
			return response(app.logs_read());
		if (command.name == 'help')
			return response(HELP);
		if (command.name == 'menu')
			return response(HELP);
		if (command.name == 'start_service')
			return mutation(app.service_start('config.yaml', 'telegram'));
		if (command.name == 'stop_service')
			return mutation(app.service_stop('config.yaml', 'telegram'));
		if (command.name == 'restart_service')
			return mutation(app.service_restart('config.yaml', 'telegram'));
		if (command.name == 'reload_service')
			return mutation(app.service_reload('config.yaml', 'telegram'));
		if (command.name == 'reboot_router') {
			if (destination == null) invalid();
			operation_bridge.prepare_reboot(destination);
			let record = app.operations.submit('system.reboot', 'telegram', {}, (ctx) => {
				ctx.stage('reboot', 50, '');
				app.reboot();
			});
			return { response: operation_message(record), record: null };
		}
		if (command.name == 'subscription')
			return mutation(app.subscription_update(command.argument, 'telegram'));
		if (command.name == 'update_subscription')
			return mutation(app.subscription_update(null, 'telegram'));
		if (command.name == 'update_miclash')
			return mutation(app.update_miclash('telegram'));
		if (command.name == 'update_mihomo')
			return mutation(app.update_mihomo('telegram'));
		if (command.name == 'guard_on')
			return mutation(app.guard_transition(true, 'telegram'));
		if (command.name == 'guard_off')
			return mutation(app.guard_transition(false, 'telegram'));
		invalid();
	};

	function callback_identity(query) {
		return { chat_id: normalized_id(query?.message?.chat?.id),
			message_id: query?.message?.message_id };
	};

	function execute_callback(target, destination) {
		if (target == 'start') return dispatch({ name: 'start_service', argument: null }, destination);
		if (target == 'stop') return dispatch({ name: 'stop_service', argument: null }, destination);
		if (target == 'reload') return dispatch({ name: 'reload_service', argument: null }, destination);
		if (target == 'restart') return dispatch({ name: 'restart_service', argument: null }, destination);
		if (target == 'reboot') return dispatch({ name: 'reboot_router', argument: null }, destination);
		if (target == 'update_subscription')
			return dispatch({ name: 'update_subscription', argument: null }, destination);
		if (target == 'update_miclash') return dispatch({ name: 'update_miclash', argument: null }, destination);
		if (target == 'update_mihomo') return dispatch({ name: 'update_mihomo', argument: null }, destination);
		if (target == 'guard_on') return dispatch({ name: 'guard_on', argument: null }, destination);
		if (target == 'guard_off') return dispatch({ name: 'guard_off', argument: null }, destination);
		if (target == 'route_check') {
			if (type(app.diagnostics_route_test) != 'function') errors.fail('NOT_FOUND');
			return { response: app.diagnostics_route_test({ target: 'one.one.one.one',
				interface: null, device: null }), record: null };
		}
		if (target == 'check_updates') return { response: true, record: null };
		invalid();
	};

	function handle_callback(update, settings) {
		let query = update.callback_query, sender = normalized_id(query?.from?.id),
			chat = normalized_id(query?.message?.chat?.id);
		if (type(query) != 'object' || query.message?.chat?.type != 'private' ||
		    query.from?.is_bot === true || sender != settings.user_id || chat != settings.user_id ||
		    type(query.id) != 'string' || type(query.data) != 'string' ||
		    type(query.message?.message_id) != 'int' || query.message.message_id < 1) {
			state.last_update_id = update.update_id;
			audit('callback', 'rejected', update.update_id);
			return { handled: false, retryable: false };
		}
		try { transport.answer(settings, query.id, ''); }
		catch (error) { log_failure('Telegram callback acknowledgement failed'); }
		try { persist_offset(update.update_id); }
		catch (error) {
			log_failure('Telegram offset persistence failed');
			return { handled: false, retryable: true, error: 'INTERNAL' };
		}
		let identity = callback_identity(query);
		let action = telegram_menu.parse_callback(query.data, session.generation);
		if (action == null) {
			audit('callback', 'stale', update.update_id);
			show_panel('main', settings, identity);
			return { handled: true, retryable: false };
		}
		try {
			if (action.name == 'open' || action.name == 'refresh')
				show_panel(action.target, settings, identity);
			else if (action.name == 'back') {
				session.awaiting = null;
				show_panel('main', settings, identity);
			}
			else if (action.name == 'cancel') {
				session.awaiting = null;
				show_panel('subscription', settings, identity);
			}
			else if (action.name == 'confirm')
				show_panel('confirm_' + action.target, settings, identity);
			else if (action.name == 'execute' && action.target == 'replace_subscription') {
				session.awaiting = { kind: 'subscription_url', chat_id: chat,
					expires_at: app.runtime.clock.now() + 600000 };
				show_panel('subscription_input', settings, identity);
			}
			else if (action.name == 'execute') {
				execute_callback(action.target, { ...identity,
					locale: telegram_i18n.locale(app.runtime) });
				show_panel(action.target == 'check_updates' ? 'updates' : 'main', settings, identity);
			}
			else invalid();
		}
		catch (error) {
			audit(action.name + '.' + action.target, 'failed', update.update_id);
			show_panel('main', settings, identity);
			return { handled: false, retryable: false };
		}
		audit(action.name + '.' + action.target, 'accepted', update.update_id);
		return { handled: true, retryable: false };
	};

	function handle_subscription_input(update, message, settings) {
		if (session.awaiting?.kind != 'subscription_url') return null;
		if (session.awaiting.chat_id != normalized_id(message.chat?.id) ||
		    app.runtime.clock.now() > session.awaiting.expires_at) {
			session.awaiting = null;
			return { handled: false, retryable: false };
		}
		let url;
		try { url = schema.url(message.text); }
		catch (error) {
			state.last_update_id = update.update_id;
			show_panel('subscription_input', settings, outbox.panel());
			return { handled: false, retryable: false };
		}
		try { persist_offset(update.update_id); }
		catch (error) {
			return { handled: false, retryable: true, error: 'INTERNAL' };
		}
		try { transport.delete(settings, settings.user_id, message.message_id); }
		catch (error) { log_failure('Telegram accepted message deletion failed'); }
		session.awaiting = null;
		try {
			let record = app.subscription_update(url, 'telegram');
			let panel = outbox.panel();
			operation_bridge.track(record, {
				chat_id: settings.user_id,
				message_id: panel?.message_id ?? message.message_id,
				locale: telegram_i18n.locale(app.runtime)
			});
		}
		catch (error) {
			audit('subscription.replace', 'failed', update.update_id);
			show_panel('subscription', settings, outbox.panel());
			return { handled: false, retryable: false };
		}
		audit('subscription.replace', 'accepted', update.update_id);
		show_panel('subscription', settings, outbox.panel());
		return { handled: true, retryable: false };
	};

	function handle_update(update, settings) {
		if (!settings.available || !settings.enabled || !settings.configured ||
		    type(update) != 'object' ||
		    type(update.update_id) != 'int' || update.update_id < 0 ||
		    update.update_id <= state.last_update_id)
			return { handled: false, retryable: false };
		if (update.callback_query != null)
			return handle_callback(update, settings);
		let message = update.message;
		let sender = normalized_id(message?.from?.id);
		let chat = normalized_id(message?.chat?.id);
		if (type(message) != 'object' || message.chat?.type != 'private' ||
		    message.from?.is_bot === true || sender != settings.user_id || chat != settings.user_id) {
			state.last_update_id = update.update_id;
			audit('message', 'rejected', update.update_id);
			return { handled: false, retryable: false };
		}
		let input = handle_subscription_input(update, message, settings);
		if (input != null) return input;
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
		if (command.name == 'menu') {
			audit(command.name, 'accepted', update.update_id);
			show_panel('main', settings, null);
			return { handled: true, retryable: false };
		}
		let outcome;
		try { outcome = dispatch(command, {
			chat_id: settings.user_id, message_id: message.message_id,
			locale: telegram_i18n.locale(app.runtime)
		}); }
		catch (error) {
			audit(command.name, 'failed', update.update_id);
			send_message('Command failed', settings);
			return { handled: false, retryable: false };
		}
		audit(command.name, 'accepted', update.update_id);
		send_message(outcome.response, settings);
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
			failures: state.failures,
			panel_generation: session.generation,
			panel_screen: session.screen,
			awaiting: session.awaiting?.kind ?? null,
			command_locale: session.command_locale,
			command_sync_error: session.command_sync_error,
			pending_deliveries: safe_call(() => length(outbox.pending()), 0)
		};
	};
	controller.configure = () => {
		let settings = configuration(app);
		if (!settings.available || !settings.enabled || !settings.configured) return false;
		try { return sync_commands(settings); }
		catch (error) {
			session.command_sync_error = errors.normalize(error).code;
			return false;
		}
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
			try { operation_bridge.recover(); } catch (error) {}
			try { outbox.attempt(); } catch (error) {}
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
