import * as errors from 'miclash.errors';
import * as i18n from 'miclash.telegram-i18n';

const COMMAND_NAMES = [
	'start', 'menu', 'status', 'health', 'memory', 'diagnostics', 'logs', 'help',
	'start_service', 'stop_service', 'reload_service', 'restart_service',
	'reboot_router', 'subscription', 'update_subscription', 'update_miclash',
	'update_mihomo', 'guard_on', 'guard_off'
];

const SIMPLE_COMMANDS = {
	start: 'menu', menu: 'menu', status: 'status', health: 'health', memory: 'memory',
	diagnostics: 'diagnostics', logs: 'logs', help: 'help',
	start_service: 'start_service', stop_service: 'stop_service',
	reload_service: 'reload_service', restart_service: 'restart_service',
	reboot_router: 'reboot_router', update_subscription: 'update_subscription',
	update_miclash: 'update_miclash', update_mihomo: 'update_mihomo',
	guard_on: 'guard_on', guard_off: 'guard_off'
};

const CALLBACKS = {
	open: [ 'status', 'management', 'subscription', 'updates', 'guard', 'memory',
		'logs', 'diagnostics' ],
	back: [ 'main' ], refresh: [ 'main', 'status', 'memory', 'logs', 'diagnostics' ],
	confirm: [ 'stop', 'guard_off', 'reboot', 'update_miclash', 'update_mihomo' ],
	execute: [ 'start', 'stop', 'reload', 'restart', 'guard_on', 'guard_off', 'reboot',
		'update_subscription', 'replace_subscription', 'check_updates', 'update_miclash',
		'update_mihomo', 'route_check' ],
	cancel: [ 'subscription_input' ]
};

function unavailable(locale) { return i18n.text(locale, 'unavailable'); };
function value(model, name, locale) {
	let found = model?.[name];
	return found == null || (type(found) == 'string' && !length(found)) ?
		unavailable(locale) : sprintf('%s', found);
};
function nested(model, group, name, locale) {
	let found = model?.[group]?.[name];
	return found == null || (type(found) == 'string' && !length(found)) ?
		unavailable(locale) : sprintf('%s', found);
};
function state(value, locale) {
	let keys = {
		enabled: 'enabled', disabled: 'disabled', ready: 'ready', ok: 'ready',
		running: 'running', stopped: 'stopped', unknown: 'unknown',
		not_configured: 'not_configured'
	};
	return keys[value] == null ? (value == null ? unavailable(locale) : sprintf('%s', value)) :
		i18n.text(locale, keys[value]);
};
function generation(value) {
	if (type(value) != 'int' || value < 0 || value > 999999999)
		errors.fail('INVALID_ARGUMENT');
	return value;
};
function callback(value, action, target) {
	let output = 'g' + generation(value) + ':' + action + ':' + target;
	if (length(output) > 64) errors.fail('INVALID_ARGUMENT');
	return output;
};
function button(locale, key, generation_value, action, target) {
	return { text: i18n.text(locale, key),
		callback_data: callback(generation_value, action, target) };
};
function markup(rows) { return { inline_keyboard: rows }; };
function back(locale, generation_value) {
	return [ button(locale, 'back', generation_value, 'back', 'main') ];
};

export function commands(locale) {
	let output = [];
	for (let name in COMMAND_NAMES)
		push(output, { command: name, description: i18n.text(locale, 'command_' + name) });
	return output;
};

export function parse_command(text) {
	if (type(text) != 'string' || !length(text) || length(text) > 4096 ||
	    match(text, /[[:cntrl:]]/)) return null;
	let found = match(text, /^\/([a-z0-9_]{1,32})(@[A-Za-z0-9_]{1,64})?( ([^[:space:]]+))?$/);
	if (found == null) return null;
	let name = found[1], argument = found[4];
	if (name == 'subscription')
		return argument == null ? null : { name: 'subscription', argument };
	if (argument != null || SIMPLE_COMMANDS[name] == null) return null;
	return { name: SIMPLE_COMMANDS[name], argument: null };
};

export function parse_callback(data, active_generation) {
	if (type(data) != 'string' || !length(data) || length(data) > 64 ||
	    type(active_generation) != 'int') return null;
	let found = match(data, /^g([0-9]{1,9}):([a-z_]{1,24}):([a-z_]{1,32})$/);
	if (found == null || int(found[1]) != active_generation) return null;
	let action = found[2], target = found[3], allowed = CALLBACKS[action];
	if (allowed == null || index(allowed, target) < 0) return null;
	return { name: action, target };
};

export function render(screen, model, locale, generation_value) {
	generation(generation_value);
	model ??= {};
	let text, rows;
	if (screen == 'main') {
		text = i18n.text(locale, 'main_body', {
			miclash_version: value(model, 'miclash_version', locale),
			miclash_state: state(model.miclash_state, locale),
			mihomo_version: value(model, 'mihomo_version', locale),
			mihomo_state: state(model.mihomo_state, locale),
			proxy_mode: value(model, 'proxy_mode', locale),
			guard_state: model.guard_enabled === true ? i18n.text(locale, 'enabled') :
				i18n.text(locale, 'disabled'),
			internet_state: state(model.internet_state, locale)
		});
		rows = [
			[ button(locale, 'status', generation_value, 'open', 'status'),
				button(locale, 'management', generation_value, 'open', 'management') ],
			[ button(locale, 'subscription', generation_value, 'open', 'subscription'),
				button(locale, 'updates', generation_value, 'open', 'updates') ],
			[ button(locale, 'guard', generation_value, 'open', 'guard'),
				button(locale, 'memory', generation_value, 'open', 'memory') ],
			[ button(locale, 'logs', generation_value, 'open', 'logs'),
				button(locale, 'diagnostics', generation_value, 'open', 'diagnostics') ],
			[ button(locale, 'reboot_router', generation_value, 'confirm', 'reboot') ]
		];
	}
	else if (screen == 'status') {
		text = i18n.text(locale, 'status_body', {
			miclash_state: state(model.miclash_state, locale),
			mihomo_state: state(model.mihomo_state, locale), dns_state: state(model.dns_state, locale),
			firewall_state: state(model.firewall_state, locale),
			routing_state: state(model.routing_state, locale),
			config_update_state: state(model.config_update_state, locale),
			miclash_update_state: state(model.miclash_update_state, locale)
		});
		rows = [ [ button(locale, 'refresh', generation_value, 'refresh', 'status') ], back(locale, generation_value) ];
	}
	else if (screen == 'management') {
		text = i18n.text(locale, 'management_body', {
			service_state: model.service_running === true ? i18n.text(locale, 'running') : i18n.text(locale, 'stopped')
		});
		rows = [
			[ button(locale, 'start_service', generation_value, 'execute', 'start'),
				button(locale, 'stop_service', generation_value, 'confirm', 'stop') ],
			[ button(locale, 'reload_service', generation_value, 'execute', 'reload'),
				button(locale, 'restart_service', generation_value, 'execute', 'restart') ],
			back(locale, generation_value)
		];
	}
	else if (screen == 'subscription') {
		text = i18n.text(locale, 'subscription_body', {
			subscription_url: value(model, 'subscription_url', locale),
			last_update: value(model, 'last_subscription_update', locale),
			last_result: value(model, 'last_subscription_result', locale)
		});
		rows = [
			[ button(locale, 'update_configuration', generation_value, 'execute', 'update_subscription') ],
			[ button(locale, 'replace_url', generation_value, 'execute', 'replace_subscription') ],
			back(locale, generation_value)
		];
	}
	else if (screen == 'subscription_input') {
		text = i18n.text(locale, 'subscription_input_body');
		rows = [ [ button(locale, 'cancel', generation_value, 'cancel', 'subscription_input') ],
			back(locale, generation_value) ];
	}
	else if (screen == 'updates') {
		text = i18n.text(locale, 'updates_body', {
			miclash_installed: nested(model, 'updates', 'miclash_installed', locale),
			miclash_available: nested(model, 'updates', 'miclash_available', locale),
			mihomo_installed: nested(model, 'updates', 'mihomo_installed', locale),
			mihomo_available: nested(model, 'updates', 'mihomo_available', locale)
		});
		rows = [ [ button(locale, 'check_updates', generation_value, 'execute', 'check_updates') ],
			[ button(locale, 'update_miclash', generation_value, 'confirm', 'update_miclash') ],
			[ button(locale, 'update_mihomo', generation_value, 'confirm', 'update_mihomo') ],
			back(locale, generation_value) ];
	}
	else if (screen == 'guard') {
		text = i18n.text(locale, 'guard_body', {
			guard_state: model.guard_enabled === true ? i18n.text(locale, 'enabled') : i18n.text(locale, 'disabled'),
			guard_observed: state(model.guard_observed, locale)
		});
		rows = [ [ button(locale, 'enable_guard', generation_value, 'execute', 'guard_on'),
			button(locale, 'disable_guard', generation_value, 'confirm', 'guard_off') ], back(locale, generation_value) ];
	}
	else if (screen == 'memory') {
		text = i18n.text(locale, 'memory_body', {
			memory_rss: value(model, 'memory_rss', locale), memory_baseline: value(model, 'memory_baseline', locale),
			memory_state: value(model, 'memory_state', locale), last_memory_action: value(model, 'last_memory_action', locale)
		});
		rows = [ [ button(locale, 'refresh', generation_value, 'refresh', 'memory') ], back(locale, generation_value) ];
	}
	else if (screen == 'logs') {
		text = i18n.text(locale, 'logs_body', { logs: value(model, 'logs', locale) });
		rows = [ [ button(locale, 'refresh', generation_value, 'refresh', 'logs') ], back(locale, generation_value) ];
	}
	else if (screen == 'diagnostics') {
		text = i18n.text(locale, 'diagnostics_body', { diagnostics: value(model, 'diagnostics', locale) });
		rows = [ [ button(locale, 'run_route_check', generation_value, 'execute', 'route_check') ],
			[ button(locale, 'refresh', generation_value, 'refresh', 'diagnostics') ], back(locale, generation_value) ];
	}
	else if (match(screen, /^confirm_(stop|guard_off|reboot|update_miclash|update_mihomo)$/)) {
		let target = substr(screen, 8);
		text = i18n.text(locale, screen + '_body');
		rows = [ [ button(locale, 'confirm', generation_value, 'execute', target) ],
			[ button(locale, 'back', generation_value, 'back', 'main') ] ];
	}
	else errors.fail('INVALID_ARGUMENT');
	if (length(text) > 4096 || length(sprintf('%J', rows)) > 8192)
		errors.fail('INVALID_RESPONSE');
	return { text, reply_markup: markup(rows) };
};
