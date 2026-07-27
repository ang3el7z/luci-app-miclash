import * as errors from 'miclash.errors';
import * as local_time_module from 'miclash.local-time';
import * as redact from 'miclash.redact';
import * as schema from 'miclash.schema';
import * as storage from 'miclash.storage';
import * as telegram_i18n from 'miclash.telegram-i18n';
import * as telegram_format from 'miclash.telegram-format';
import * as telegram_menu from 'miclash.telegram-menu';
import * as telegram_outbox from 'miclash.telegram-outbox';
import * as telegram_operations from 'miclash.telegram-operations';
import * as telegram_transport from 'miclash.telegram-transport';

const OFFSET_NAME = 'telegram-offset.json';
// miclashd serves ubus and timers on one event loop. Telegram long polling would
// monopolize that loop and make unrelated LuCI RPC calls time out, so use a
// bounded short poll and leave an explicit gap before the next request.
const MAX_MESSAGE_BYTES = 3500;
const MAX_COMMANDS = 5;
const RATE_WINDOW_MS = 60000;
const MAX_BACKOFF_MS = 60000;
const SUCCESS_DELAY_MS = 3000;
const MAX_DOCUMENT_ATTEMPTS = 3;
const HELP = '/start /menu';

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
	// OpenWrt overlayfs may expose the parent directory and regular files on
	// different st_dev values. Authenticate the fixed path and the file itself;
	// same_file() below still detects replacement during reads and writes.
	if (identity.type != 'file' || identity.mode != 0o600 || identity.nlink != 1 ||
	    (identity.uid != null && identity.uid != 0) ||
	    runtime.fs.realpath(path) != path)
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
	let user_ids = [];
	if (type(value?.user_id) == 'string') for (let item in split(value.user_id, ',')) {
		let user_id = normalized_id(trim(item));
		if (user_id != null && index(user_ids, user_id) < 0) push(user_ids, user_id);
	}
	let user_id = user_ids[0] ?? null;
	return {
		available: true, enabled, configured: token != null && length(user_ids),
		token, user_id, user_ids
	};
};

function authorized(settings, user_id) {
	return user_id != null && index(settings?.user_ids ?? [], user_id) >= 0;
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
	let visible = '';
	for (let index = 0; index < length(safe); index++) {
		let character = substr(safe, index, 1), byte = ord(safe, index);
		visible += byte == 9 || byte == 10 || byte == 13 || byte >= 32 ? character : ' ';
	}
	safe = visible;
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

function safe_call(callback, fallback) {
	try { return callback(); }
	catch (error) { return fallback; }
};

function readiness_components(health) {
	let values = health?.observed?.readiness?.components ??
		health?.readiness?.components ?? health?.components;
	let output = {};
	if (type(values) == 'array')
		for (let value in values) {
			let name = value?.component ?? value?.name;
			if (type(name) == 'string' && type(value) == 'object')
				output[name] = value;
		}
	else if (type(values) == 'object')
		output = values;
	return output;
};

function worse_state(left, right) {
	let rank = { failed: 5, error: 5, stopped: 5, degraded: 4, warning: 4,
		unknown: 3, ready: 1, ok: 1, running: 1, success: 1 };
	if (left == null) return right;
	if (right == null) return left;
	return (rank[right] ?? 3) > (rank[left] ?? 3) ? right : left;
};

function component_state(health, name) {
	let direct = health?.[name]?.state;
	if (direct == null && type(health?.components) == 'object' &&
	    type(health.components) != 'array')
		direct = health.components?.[name]?.state;
	if (direct != null)
		return direct == 'healthy' ? 'ready' : direct;
	let readiness = readiness_components(health), value;
	if (name == 'mihomo')
		value = worse_state(readiness.process?.state, readiness.api?.state);
	else if (name == 'routing') value = readiness.policy?.state;
	else if (name == 'firewall') value = readiness.forward?.state;
	else value = readiness?.[name]?.state;
	return value == 'healthy' ? 'ready' : (value ?? 'unknown');
};

function config_scheduler_state(value) {
	if (type(value) != 'object') return 'unknown';
	if (value.enabled !== true) {
		if (value.reason == 'no_url') return 'not_configured';
		if (value.reason == 'invalid_settings') return 'configuration_error';
		return 'disabled';
	}
	if (value.running !== true || value.last_failure_code) return 'failed';
	if (value.pending_operation_id) return 'updating';
	return value.next_attempt != null ? 'scheduled' : 'ready';
};

function miclash_scheduler_state(value) {
	if (type(value) != 'object') return 'unknown';
	if (value.enabled !== true) return 'disabled';
	if (value.running !== true) return 'failed';
	if (value.local_time_valid !== true || value.last_error_code == 'CLOCK_INVALID')
		return 'clock_unavailable';
	if (value.pending_operation_id) return 'updating';
	if (index([ 'ASSETS_PENDING', 'BUSY', 'TRAFFIC_BUSY', 'TRAFFIC_UNAVAILABLE' ],
	    value.last_error_code) >= 0 || value.readiness == 'assets_pending' ||
	    value.pending_target) return 'waiting';
	if (value.last_error_code || value.readiness == 'error') return 'failed';
	return value.next_check != null ? 'scheduled' : 'ready';
};

function kibibytes(value) {
	if (type(value) != 'int' && type(value) != 'double') return '';
	if (value < 1024) return sprintf('%d KiB', value);
	return sprintf('%.1f MiB', value * 1.0 / 1024);
};

function date_time(app, value) {
	if (type(value) != 'int' || value < 0) return '';
	try {
		let observed = local_time_module.create(app.runtime).observe(value);
		if (observed.valid === true && type(observed.local_date) == 'string' &&
		    type(observed.minute) == 'int')
			return sprintf('%s %02d:%02d', observed.local_date,
				int(observed.minute / 60), observed.minute % 60);
	}
	catch (error) {}
	let stamp = gmtime(int(value / 1000));
	if (type(stamp) != 'object') return '';
	return sprintf('%04d-%02d-%02d %02d:%02d', stamp.year, stamp.mon,
		stamp.mday, stamp.hour, stamp.min);
};

export function panel_model(app, screen) {
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
	if (type(configured_url) != 'string') configured_url = '';
	let last_subscription = type(app.subscription_operation) == 'function' ?
		safe_call(() => app.subscription_operation(), null) : null;
	let config_update_state = config_scheduler_state(update_status.automatic_config);
	if (config_update_state == 'unknown')
		config_update_state = wanted?.updates?.auto_subscription === true ?
			(length(configured_url) ? 'enabled' : 'not_configured') : 'disabled';
	let miclash_update_state = miclash_scheduler_state(update_status.automatic_miclash);
	if (miclash_update_state == 'unknown')
		miclash_update_state = wanted?.updates?.auto_major_miclash === true ? 'enabled' : 'disabled';
	let baseline = memory.baseline_rss_kb == null ? '' : kibibytes(memory.baseline_rss_kb);
	return {
		miclash_version: info.app_version ?? status?.versions?.miclash ?? 'unknown',
		miclash_state: running ? 'running' : 'stopped',
		mihomo_version: info.mihomo?.version ?? status?.versions?.mihomo ?? 'unknown',
		mihomo_state: component_state(health, 'mihomo'),
		proxy_mode: wanted?.core?.proxy_mode ?? 'unknown',
		guard_enabled: wanted?.guard?.enabled === true,
		guard_observed: type(app.guard_status) == 'function' ?
			safe_call(() => app.guard_status(), 'unknown') :
			(wanted?.guard?.enabled === true ? 'enabled' : 'disabled'),
		service_running: running,
		dns_state: component_state(health, 'dns'),
		firewall_state: component_state(health, 'firewall'),
		routing_state: component_state(health, 'routing'),
		config_update_state,
		miclash_update_state,
		subscription_url: configured_url,
		last_subscription_update: date_time(app, last_subscription?.finished_at ??
			last_subscription?.updated_at ?? update_status.automatic_config?.last_success),
		last_subscription_result: last_subscription?.state ??
			update_status.automatic_config?.last_failure_code ??
			(update_status.automatic_config?.last_success != null ? 'success' : 'not_required'),
		memory_rss: kibibytes(memory.current_rss_kb) || memory.rss_human ?? '',
		memory_baseline: baseline || (memory.enabled === true ? 'not_learned' : 'disabled'),
		memory_state: memory.enabled === false ? 'disabled' : (memory.phase ?? 'unknown'),
		last_memory_action: memory.last_action ?? 'not_required',
		updates: {
			miclash_installed: info.app_version ?? update_status.miclash?.installed ?? '',
			miclash_available: update_status.automatic_miclash?.latest_version ??
				update_status.miclash?.available ?? update_status.available_miclash ?? '',
			mihomo_installed: info.mihomo?.version ?? update_status.mihomo?.installed ?? '',
			mihomo_available: update_status.mihomo?.available ?? update_status.available_mihomo ?? ''
		}
	};
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
		'diagnostics_create_report', 'diagnostics_open_report',
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
	let diagnostic_jobs = {}, diagnostics_unsubscribe = null;
	let session = {
		generation: 0, screen: 'main', awaiting: null,
		user_locale: null,
		command_locale: null, command_sync_error: null, command_sync_next_at: 0,
		command_sync_requested: false
	};

	state.last_update_id = read_offset(app.runtime);

	function log_failure(message) {
		try { app.logger?.warn('telegram: ' + message); } catch (error) {}
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

	function send_message(text, settings, chat_id, parse_mode) {
		settings = settings ?? configuration(app);
		if (!settings.available || !settings.enabled || !settings.configured)
			return false;
		try {
			return transport.send(settings, chat_id ?? settings.user_id,
				bounded_text(text), null, parse_mode) != null;
		}
		catch (error) {
			log_failure('delivery failed');
			return false;
		}
	};

	function resolved_locale(language) {
		return telegram_i18n.locale(app.runtime, language ?? session.user_locale);
	};

	function show_panel(screen, settings, target) {
		let locale = resolved_locale(target?.locale);
		session.generation++;
		if (session.generation > 999999999) session.generation = 1;
		let model = panel_model(app, screen);
		if (screen == 'settings') model.administrators = join('\n', settings.user_ids ?? []);
		if (screen == 'admin_input') model.admin_action = session.awaiting?.kind;
		if (screen == 'confirm_admin_remove') model.administrator = session.awaiting?.admin_id ?? '';
		let rendered = telegram_menu.render(screen, model, locale,
			session.generation);
		let parse_mode = null;
		// Slash commands pass null and must produce a visible fresh reply. Button
		// callbacks pass an explicit message identity and continue editing in place.
		let identity = target, result = null;
		if (identity != null && type(identity.message_id) == 'int')
			try {
				result = transport.edit(settings, identity.chat_id, identity.message_id,
					rendered.text, rendered.reply_markup, parse_mode);
			}
			catch (error) { result = null; }
		let destination = identity?.chat_id ?? settings.user_id;
		if (result == null)
			result = transport.send(settings, destination, rendered.text,
				rendered.reply_markup, parse_mode);
		if (result == null) return false;
		outbox.panel({ chat_id: destination, message_id: result.message_id,
			generation: session.generation });
		session.screen = screen;
		return true;
	};

	function diagnostic_notice(locale, success) {
		return telegram_i18n.text(locale, 'operation_result', {
			operation: telegram_i18n.text(locale, 'diagnostics'),
			state: telegram_i18n.text(locale,
				success ? 'operation_success' : 'operation_failure')
		});
	};

	function text_document(value) {
		if (type(value) != 'string' || !length(value))
			errors.fail('NOT_FOUND');
		let offset = 0, closed = false;
		return {
			identity: { kind: 'telegram-logs', size: length(value) },
			size: length(value),
			sha256: app.runtime.digest.sha256(value),
			read: (amount) => {
				if (closed || type(amount) != 'int' || amount < 1)
					errors.fail('INVALID_ARGUMENT');
				let chunk = substr(value, offset, amount);
				offset += length(chunk);
				return chunk;
			},
			finish: () => {
				if (closed || offset != length(value)) errors.fail('VALIDATION_FAILED');
				closed = true;
				return true;
			},
			close: () => {
				if (closed) errors.fail('NOT_FOUND');
				closed = true;
				return true;
			}
		};
	};

	function send_logs_document(settings, destination) {
		let logs = app.logs_read();
		if (type(logs) != 'string' || !length(logs)) {
			send_message(telegram_i18n.text(destination.locale, 'no_logs'),
				settings, destination.chat_id);
			return false;
		}
		transport.send_document(settings, destination.chat_id, text_document(logs),
			'miclash-logs-' + app.runtime.clock.now() + '.log',
			telegram_i18n.text(destination.locale, 'logs'), 'text/plain');
		return true;
	};

	function diagnostic_identity(entry) {
		return entry.message_id == null ? null :
			{ chat_id: entry.chat_id, message_id: entry.message_id,
				locale: entry.locale };
	};

	function forget_diagnostic(entry, retire_receipt) {
		if (entry.retry_timer?.cancel != null)
			try { entry.retry_timer.cancel(); } catch (error) {}
		entry.retry_timer = null;
		delete diagnostic_jobs[entry.operation_id];
		if (retire_receipt === true)
			try { outbox.remove('operation.' + entry.operation_id); } catch (error) {}
	};

	function restore_diagnostics(entry, settings, success) {
		let panel_delivered = false, notice_delivered = false;
		try {
			panel_delivered = show_panel('diagnostics', settings,
				diagnostic_identity(entry)) === true;
		}
		catch (error) {}
		try {
			notice_delivered = transport.send(settings, entry.chat_id,
				diagnostic_notice(entry.locale, success), null) != null;
		}
		catch (error) { log_failure('diagnostic result delivery failed'); }
		return panel_delivered || notice_delivered;
	};

	function edit_diagnostic_stage(entry, record, settings) {
		if (entry.message_id == null) return false;
		let rendered = telegram_menu.render('operation_loading', {}, entry.locale,
			session.generation);
		let text = rendered.text + '\n\n' + record.stage + ': ' + record.progress + '%';
		try {
			return transport.edit(settings, entry.chat_id, entry.message_id,
				text, rendered.reply_markup) != null;
		}
		catch (error) {
			log_failure('diagnostic stage delivery failed');
			return false;
		}
	};

	function attempt_diagnostic_document(entry) {
		if (diagnostic_jobs[entry.operation_id] !== entry) return false;
		let settings = configuration(app);
		if (!settings.available || !settings.enabled || !settings.configured ||
		    !authorized(settings, entry.chat_id)) {
			forget_diagnostic(entry, true);
			return false;
		}
		entry.attempts++;
		try {
			let file = app.diagnostics_open_report(entry.report_id);
			let result = transport.send_document(settings, entry.chat_id, file,
				'miclash-diagnostic-' + entry.mode + '-' + app.runtime.clock.now() + '.json',
				telegram_i18n.text(entry.locale, 'diagnostics'));
			if (result?.limited === true) {
				if (entry.attempts >= MAX_DOCUMENT_ATTEMPTS) {
					restore_diagnostics(entry, settings, false);
					forget_diagnostic(entry, true);
					return false;
				}
				edit_diagnostic_stage(entry, {
					stage: 'retry', progress: 100
				}, settings);
				entry.retry_timer = app.runtime.clock.set_timeout(result.retry_after_ms, () => {
					entry.retry_timer = null;
					attempt_diagnostic_document(entry);
				});
				return false;
			}
			restore_diagnostics(entry, settings, true);
			forget_diagnostic(entry, true);
			return true;
		}
		catch (error) {
			log_failure('diagnostic document delivery failed');
			restore_diagnostics(entry, settings, false);
			forget_diagnostic(entry, true);
			return false;
		}
	};

	function diagnostic_event(record) {
		let entry = diagnostic_jobs[record?.id];
		if (entry == null) return false;
		let settings = configuration(app);
		if (record.state == 'success')
			return attempt_diagnostic_document(entry);
		if (record.state == 'failure' || record.state == 'interrupted') {
			if (settings.available && settings.enabled && settings.configured)
				restore_diagnostics(entry, settings, false);
			forget_diagnostic(entry, true);
			return false;
		}
		if (settings.available && settings.enabled && settings.configured)
			edit_diagnostic_stage(entry, record, settings);
		return true;
	};

	function start_diagnostics(settings, destination, mode) {
		if (index([ 'silent', 'lite', 'full' ], mode) < 0)
			errors.fail('INVALID_ARGUMENT');
		if (!show_panel('operation_loading', settings, {
			chat_id: destination.chat_id, message_id: null, locale: destination.locale
		}))
			errors.fail('UNAVAILABLE');
		let panel = outbox.panel();
		let job;
		try {
			job = app.diagnostics_create_report({
				mode, acknowledge_secrets: mode == 'full', source: 'telegram'
			});
		}
		catch (error) {
			try { show_panel('diagnostics', settings, panel); } catch (panel_error) {}
			errors.fail(errors.normalize(error).code);
		}
		if (type(job) != 'object' || type(job.operation_id) != 'string' ||
		    type(job.report_id) != 'string') {
			try { show_panel('diagnostics', settings, panel); } catch (error) {}
			errors.fail('INVALID_RESPONSE');
		}
		let entry = {
			operation_id: job.operation_id, report_id: job.report_id,
			chat_id: destination.chat_id, message_id: panel?.message_id ?? null,
			locale: destination.locale, mode, attempts: 0, retry_timer: null
		};
		let record = app.operations.get(entry.operation_id);
		if (record == null) {
			try { show_panel('diagnostics', settings, panel); } catch (error) {}
			errors.fail('INVALID_RESPONSE');
		}
		try {
			operation_bridge.track({ ...record, report_id: entry.report_id,
				report_mode: entry.mode }, {
				chat_id: entry.chat_id, message_id: entry.message_id, locale: entry.locale
			});
		}
		catch (error) {
			try { show_panel('diagnostics', settings, panel); } catch (panel_error) {}
			errors.fail(errors.normalize(error).code);
		}
		diagnostic_jobs[entry.operation_id] = entry;
		diagnostic_event(record);
		return true;
	};

	function sync_commands(settings) {
		let locale = resolved_locale(), commands = telegram_menu.commands(locale);
		if (transport.set_commands(settings, '', commands) !== true) return false;
		let language = telegram_i18n.telegram_language(locale);
		if (length(language) && transport.set_commands(settings, language, commands) !== true)
			return false;
		session.command_locale = locale;
		session.command_sync_error = null;
		return true;
	};

	function receipt_payload(record, previous) {
		let value = {
			kind: record.kind, stage: record.stage, progress: record.progress,
			error: record.error?.code ?? null
		};
		if (record.kind == 'diagnostics.report')
			value = { ...value,
				report_id: record.report_id ?? previous?.report_id ?? null,
				report_mode: record.report_mode ?? previous?.report_mode ?? 'lite'
			};
		return value;
	};

	function return_screen(kind) {
		if (kind == 'subscription.update') return 'subscription';
		if (kind == 'settings.set') return 'settings';
		if (match(kind, /^updates\./)) return 'updates';
		if (match(kind, /^service\./)) return 'management';
		if (kind == 'guard.transition') return 'guard';
		return 'main';
	};

	function operation_label(locale, kind) {
		let labels = {
			'subscription.update': 'operation_subscription_update',
			'service.start': 'operation_service_start', 'service.stop': 'operation_service_stop',
			'service.reload': 'operation_service_reload', 'service.restart': 'operation_service_restart',
			'updates.miclash': 'operation_updates_miclash', 'updates.mihomo': 'operation_updates_mihomo',
			'guard.transition': 'operation_guard_transition'
		};
		return labels[kind] == null ? kind : telegram_i18n.text(locale, labels[kind]);
	};

	function operation_result_text(entry) {
		let state_key = entry.state == 'success' ? 'operation_success' :
			(entry.state == 'interrupted' ? 'operation_interrupted' : 'operation_failure');
		let text = telegram_i18n.text(entry.locale, 'operation_result', {
			operation: operation_label(entry.locale, entry.kind),
			state: telegram_i18n.text(entry.locale, state_key)
		});
		if (entry.payload?.error != null) text += '\n\n' + entry.payload.error;
		return text;
	};

	function deliver_receipt(entry, saved_panel) {
		let settings = configuration(app);
		if (!settings.available || !settings.enabled || !settings.configured ||
		    !authorized(settings, entry.chat_id)) return false;
		if (entry.kind == 'diagnostics.report') {
			// The live job owns its exact retry deadline and descriptor lifecycle.
			// The durable receipt is only the failover owner after recreation.
			if (diagnostic_jobs[entry.operation_id] != null) return false;
			if (entry.state == 'success' && type(entry.payload?.report_id) == 'string') {
				try {
					let file = app.diagnostics_open_report(entry.payload.report_id);
					let result = transport.send_document(settings, entry.chat_id, file,
						'miclash-diagnostic-' + (entry.payload.report_mode ?? 'lite') + '-' +
							app.runtime.clock.now() + '.json',
						telegram_i18n.text(entry.locale, 'diagnostics'));
					if (result?.limited === true) return false;
					restore_diagnostics(entry, settings, true);
					return { delivered: true };
				}
				catch (error) { log_failure('recovered diagnostic document delivery failed'); }
			}
			if (entry.state != 'failure' && entry.state != 'interrupted' &&
			    entry.state != 'success') return false;
			return restore_diagnostics(entry, settings, false) ?
				{ delivered: true } : false;
		}
		if (entry.audience == 'automatic') {
			let text = event_text(entry.payload);
			if (type(entry.payload?.count) == 'int' && entry.payload.count > 1)
				text += ' (x' + entry.payload.count + ')';
			return transport.send(settings, entry.chat_id, text, null) == null ? false :
				{ delivered: true };
		}
		if (entry.state != 'success' && entry.state != 'failure' && entry.state != 'interrupted')
			return false;
		session.generation++;
		if (session.generation > 999999999) session.generation = 1;
		let target_screen = return_screen(entry.kind);
		let rendered = telegram_menu.render('operation_result', {
			operation_result: operation_result_text(entry),
			operation_failed: entry.state != 'success', return_screen: target_screen
		}, entry.locale, session.generation);
		let identity = entry.message_id != null ?
			{ chat_id: entry.chat_id, message_id: entry.message_id } : saved_panel;
		let result = null;
		if (identity != null)
			try { result = transport.edit(settings, identity.chat_id, identity.message_id,
				rendered.text, rendered.reply_markup); }
			catch (error) { result = null; }
		if (result == null)
			result = transport.send(settings, entry.chat_id, rendered.text, rendered.reply_markup);
		if (result == null) return false;
		session.screen = 'operation_result';
		if (entry.state == 'success') {
			let result_generation = session.generation;
			try { app.runtime.clock.set_timeout(2000, () => {
				if (session.generation != result_generation || session.screen != 'operation_result') return;
				show_panel(target_screen, configuration(app), {
					chat_id: entry.chat_id, message_id: result.message_id });
			}); } catch (error) {}
		}
		return { delivered: true, panel: { chat_id: entry.chat_id,
			message_id: result.message_id, generation: session.generation } };
	};

	function subscribe_diagnostics() {
		if (diagnostics_unsubscribe != null) return false;
		diagnostics_unsubscribe = app.operations.subscribe((record) => {
			try { diagnostic_event(record); } catch (error) {}
		});
		if (type(diagnostics_unsubscribe) != 'function') {
			diagnostics_unsubscribe = null;
			invalid();
		}
		return true;
	};
	function suspend_diagnostics() {
		if (diagnostics_unsubscribe != null) {
			try { diagnostics_unsubscribe(); } catch (error) {}
			diagnostics_unsubscribe = null;
		}
		for (let operation_id in keys(diagnostic_jobs)) {
			let entry = diagnostic_jobs[operation_id];
			// A scheduled document retry already owns a terminal operation. Stop
			// cancels that delivery job completely; its released report remains
			// available only until the report store's normal TTL cleanup.
			forget_diagnostic(entry, entry.retry_timer != null);
		}
		return true;
	};
	function resume_delivery() {
		if (operation_bridge == null)
			operation_bridge = telegram_operations.create(app, outbox, receipt_payload);
		subscribe_diagnostics();
		try { operation_bridge.recover(); } catch (error) {}
		return true;
	};
	function suspend_delivery() {
		suspend_diagnostics();
		if (operation_bridge != null) {
			try { operation_bridge.close(); } catch (error) {}
			operation_bridge = null;
		}
		return true;
	};
	outbox = telegram_outbox.create(app.runtime, deliver_receipt);
	resume_delivery();

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
		function response(value, parse_mode) {
			return { response: value, record: null, parse_mode };
		};
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
		if (command.name == 'logs')
			return response(telegram_format.fenced_code(app.logs_read(), ''), 'MarkdownV2');
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
			message_id: query?.message?.message_id,
			locale: resolved_locale(query?.from?.language_code) };
	};

	function execute_callback(target, destination) {
		if (target == 'remove_admin' && session.awaiting?.kind == 'confirm_remove_admin') {
			let ids = [], removed = session.awaiting.admin_id;
			for (let id in configuration(app).user_ids) if (id != removed) push(ids, id);
			session.awaiting = null;
			let record = app.settings_set({ telegram: { user_id: join(', ', ids) } }, 'telegram');
			operation_bridge.track(record, destination);
			return { response: true, record };
		}
		if (target == 'add_admin' || target == 'remove_admin') {
			session.awaiting = { kind: target, chat_id: destination.chat_id,
				expires_at: app.runtime.clock.now() + 600000 };
			return { response: true, record: null };
		}
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
		if (target == 'check_updates') return { response: true, record: null };
		if (target == 'download_logs') {
			send_logs_document(configuration(app), destination);
			return { response: true, record: null, screen: 'logs' };
		}
		let diagnostic = match(target, /^diagnostic_(silent|lite|full)$/);
		if (diagnostic != null) {
			start_diagnostics(configuration(app), destination, diagnostic[1]);
			return { response: true, record: null, screen: 'diagnostics',
				panel_handled: true };
		}
		invalid();
	};

	function handle_callback(update, settings) {
		let query = update.callback_query, sender = normalized_id(query?.from?.id),
			chat = normalized_id(query?.message?.chat?.id);
		if (type(query) != 'object' || query.message?.chat?.type != 'private' ||
	    query.from?.is_bot === true || !authorized(settings, sender) || chat != sender ||
		    type(query.id) != 'string' || type(query.data) != 'string' ||
		    type(query.message?.message_id) != 'int' || query.message.message_id < 1) {
			state.last_update_id = update.update_id;
			audit('callback', 'rejected', update.update_id);
			return { handled: false, retryable: false };
		}
		try { transport.answer(settings, query.id, ''); }
		catch (error) { log_failure('callback acknowledgement failed'); }
		try { persist_offset(update.update_id); }
		catch (error) {
			log_failure('offset persistence failed');
			return { handled: false, retryable: true, error: 'INTERNAL' };
		}
		let identity = callback_identity(query);
		session.user_locale = identity.locale;
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
				show_panel(action.target, settings, identity);
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
				let admin_prompt = action.target == 'add_admin' ||
					(action.target == 'remove_admin' && session.awaiting?.kind != 'confirm_remove_admin');
				let outcome = execute_callback(action.target, { ...identity,
					locale: identity.locale });
				if (admin_prompt) {
					show_panel('admin_input', settings, identity);
					return { handled: true, retryable: false };
				}
				if (outcome.panel_handled === true)
					return { handled: true, retryable: false };
				show_panel(outcome.record != null ?
					(action.target == 'update_subscription' ? 'subscription_loading' : 'operation_loading') :
					(outcome.screen ?? (action.target == 'check_updates' ? 'updates' :
					(action.target == 'route_check' ? 'diagnostics' : 'main'))),
					settings, identity);
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
		catch (error) { log_failure('accepted message deletion failed'); }
		session.awaiting = null;
		try {
			let record = app.subscription_update(url, 'telegram');
			let panel = outbox.panel();
			operation_bridge.track(record, {
				chat_id: settings.user_id,
				message_id: panel?.message_id ?? message.message_id,
				locale: resolved_locale()
			});
		}
		catch (error) {
			audit('subscription.replace', 'failed', update.update_id);
			show_panel('subscription', settings, outbox.panel());
			return { handled: false, retryable: false };
		}
		audit('subscription.replace', 'accepted', update.update_id);
		show_panel('subscription_loading', settings, outbox.panel());
		return { handled: true, retryable: false };
	};

	function handle_admin_input(update, message, settings) {
		let awaiting = session.awaiting;
		if (awaiting?.kind != 'add_admin' && awaiting?.kind != 'remove_admin') return null;
		if (awaiting.chat_id != normalized_id(message.chat?.id) || app.runtime.clock.now() > awaiting.expires_at) {
			session.awaiting = null; return { handled: false, retryable: false };
		}
		try { persist_offset(update.update_id); }
		catch (error) { return { handled: false, retryable: true, error: 'INTERNAL' }; }
		let admin_id = normalized_id(message.text);
		if (admin_id == null) {
			show_panel('admin_input', settings, outbox.panel());
			return { handled: false, retryable: false };
		}
		if (awaiting.kind == 'remove_admin') {
			session.awaiting = { kind: 'confirm_remove_admin', admin_id, chat_id: awaiting.chat_id,
				expires_at: app.runtime.clock.now() + 600000 };
			show_panel('confirm_admin_remove', settings, outbox.panel());
			return { handled: true, retryable: false };
		}
		let ids = settings.user_ids ?? [];
		if (index(ids, admin_id) < 0) push(ids, admin_id);
		session.awaiting = null;
		let record = app.settings_set({ telegram: { user_id: join(', ', ids) } }, 'telegram');
		operation_bridge.track(record, { chat_id: awaiting.chat_id,
			message_id: outbox.panel()?.message_id ?? message.message_id,
			locale: resolved_locale() });
		show_panel('operation_loading', settings, outbox.panel());
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
	    message.from?.is_bot === true || !authorized(settings, sender) || chat != sender) {
			state.last_update_id = update.update_id;
			audit('message', 'rejected', update.update_id);
			return { handled: false, retryable: false };
		}
		session.user_locale = resolved_locale(message.from?.language_code);
		let input = handle_subscription_input(update, message, settings);
		if (input != null) return input;
		input = handle_admin_input(update, message, settings);
		if (input != null) return input;
		let command = parse_command(message.text);
		if (command == null) {
			state.last_update_id = update.update_id;
			audit('command', 'rejected', update.update_id);
			return { handled: false, retryable: false };
		}
		try { persist_offset(update.update_id); }
		catch (error) {
			log_failure('offset persistence failed');
			return { handled: false, retryable: true, error: 'INTERNAL' };
		}
		if (!rate_allowed(app.runtime.clock.now())) {
			audit(command.name, 'rate_limited', update.update_id);
			send_message('Rate limit exceeded', settings);
			return { handled: false, retryable: false };
		}
		if (command.name == 'menu') {
			audit(command.name, 'accepted', update.update_id);
			show_panel('main', settings, { chat_id: chat, message_id: null,
				locale: session.user_locale });
			return { handled: true, retryable: false };
		}
		let outcome;
		try { outcome = dispatch(command, {
			chat_id: chat, message_id: message.message_id,
			locale: session.user_locale
		}); }
		catch (error) {
			audit(command.name, 'failed', update.update_id);
			send_message('Command failed', settings);
			return { handled: false, retryable: false };
		}
		audit(command.name, 'accepted', update.update_id);
		send_message(outcome.response, settings, chat, outcome.parse_mode);
		return { handled: true, retryable: false };
	};

	let controller = {};
	controller.status = () => {
		let settings = configuration(app);
		return {
			running: state.running,
			enabled: settings.enabled,
			configured: settings.configured,
			bot_configured: settings.token != null,
			bot_length: settings.token != null ? length(settings.token) : 0,
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
		// Bot API I/O must never run inside the settings ubus transaction.
		// The polling timer performs the bounded synchronization in background.
		session.command_locale = null;
		session.command_sync_error = null;
		session.command_sync_next_at = 0;
		session.command_sync_requested = true;
		return true;
	};
	controller.handle_update = (update) =>
		handle_update(update, configuration(app)).handled;
	controller.ingest = (update) => {
		let outcome = handle_update(update, configuration(app));
		return { handled: outcome.handled === true, retryable: outcome.retryable === true,
			last_update_id: state.last_update_id };
	};
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
			suspend_delivery();
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
			let locale = resolved_locale();
			if ((session.command_sync_requested ||
			    (session.command_locale != null && session.command_locale != locale)) &&
			    app.runtime.clock.now() >= session.command_sync_next_at) {
				try {
					if (!sync_commands(settings)) errors.fail('UNAVAILABLE');
					session.command_sync_requested = false;
				}
				catch (error) {
					session.command_sync_error = errors.normalize(error).code;
					session.command_sync_next_at = app.runtime.clock.now() + 60000;
				}
			}
			state.last_success_at = app.runtime.clock.now();
			state.last_error = null;
			state.retry_after_ms = 0;
			state.failures = 0;
			return true;
		}
		catch (error) {
			state.failures++;
			let failure = errors.normalize(error);
			state.last_error = failure.code;
			state.retry_after_ms = min(MAX_BACKOFF_MS,
				1000 * (1 << min(state.failures - 1, 6)));
			log_failure('poll failed: ' + failure.code);
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
		resume_delivery();
		state.running = true;
		return true;
	};
	controller.stop = () => {
		let was_running = state.running;
		state.running = false;
		if (timer?.cancel != null)
			timer.cancel();
		timer = null;
		suspend_delivery();
		return was_running;
	};
	controller.test = () => send_message('MiClash Telegram test');
	controller.send_event = (event) => {
		let settings = configuration(app);
		if (!settings.available || !settings.enabled || !settings.configured ||
		    type(event) != 'object' || type(event.type) != 'string' ||
		    !match(event.type, /^[a-z][a-z0-9_.-]{0,63}$/)) return false;
		let payload = {
			type: event.type,
			title: type(event.title) == 'string' ? event.title : 'MiClash',
			message: type(event.message) == 'string' ? event.message : 'State changed',
			severity: type(event.severity) == 'string' ? event.severity : 'notice'
		};
		try {
			outbox.coalesce({
				id: sprintf('notify.%d.%s', app.runtime.clock.now(),
					app.runtime.random.hex(8)),
				audience: 'automatic', kind: 'notify.' + event.type,
				locale: resolved_locale(), chat_id: settings.user_id,
				message_id: null, operation_id: null, state: 'event',
				created_at: app.runtime.clock.now(), payload
			});
			try { outbox.attempt(); } catch (delivery_error) {}
			return true;
		}
		catch (error) {
			state.last_error = errors.normalize(error).code;
			log_failure('notification enqueue failed');
			return false;
		}
	};
	return controller;
};
