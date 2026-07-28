import { assert_equal, assert_match, assert_throws, assert_true } from 'testlib';
import * as i18n from 'miclash.telegram-i18n';
import * as menu from 'miclash.telegram-menu';
import * as fakes from 'fakes';

function locale(value) {
	return i18n.locale({ uci: fakes.uci({ luci: { main: {
		'.type': 'core', lang: value
	} } }) });
};

function repeated(value, count) {
	let output = '';
	for (let index = 0; index < count; index++) output += value;
	return output;
};

function clone(value) { return json(sprintf('%J', value)); };

assert_equal(locale('en'), 'en');
assert_equal(locale('en-us'), 'en');
assert_equal(locale('ru'), 'ru');
assert_equal(locale('ru_RU'), 'ru');
assert_equal(locale('zh-cn'), 'zh-cn');
assert_equal(locale('zh_CN'), 'zh-cn');
assert_equal(locale('de'), 'en');
assert_equal(i18n.locale({ uci: { cursor: () => die('unavailable') } }), 'en');
assert_equal(i18n.locale({ uci: fakes.uci({ luci: { main: {
	'.type': 'core', lang: 'auto'
} } }) }, 'ru'), 'ru');
assert_equal(i18n.locale({ uci: fakes.uci({ luci: { main: {
	'.type': 'core', lang: 'auto'
} } }) }, 'zh-CN'), 'zh-cn');
assert_equal(i18n.locale({ uci: fakes.uci({ luci: { main: {
	'.type': 'core', lang: 'en'
} } }) }, 'ru'), 'en');
assert_equal(i18n.telegram_language('zh-cn'), 'zh');
assert_equal(i18n.telegram_language('ru'), 'ru');
assert_equal(i18n.telegram_language('en'), '');

assert_equal(i18n.text('ru', 'operation_accepted', { operation: 'MiClash' }),
	'Операция MiClash принята');
assert_equal(i18n.text('unknown', 'back'), '◀️ Back');
assert_throws(() => i18n.text('en', 'operation_accepted', { unknown: 'value' }),
	'INVALID_ARGUMENT');
assert_throws(() => i18n.text('en', 'missing_key'), 'INVALID_ARGUMENT');

assert_equal(menu.parse_command('/start').name, 'menu');
assert_equal(menu.parse_command('/menu').name, 'menu');
assert_equal(menu.parse_command('/start@MiClashBot').name, 'menu');
for (let removed in [ '/start-service', '/stop', '/reload', '/restart', '/reboot',
	'/start_service', '/stop_service', '/reload_service', '/restart_service',
	'/reboot_router', '/subscription https://example.test/config', '/diagnostics',
	'/logs', '/status', '/health', '/memory', '/help', '/update_subscription',
	'/update_miclash', '/update_mihomo', '/guard_on', '/guard_off' ])
	assert_equal(menu.parse_command(removed), null, removed + ' must not be accepted');
assert_equal(menu.parse_command('/unknown'), null);
assert_equal(menu.parse_command('not a command'), null);

let commands = menu.commands('ru');
assert_equal(length(commands), 1);
assert_equal(commands[0].command, 'menu');
assert_equal(menu.parse_command('/start').name, 'menu');
for (let command in commands) {
	assert_match(command.command, /^[a-z0-9_]{1,32}$/);
	assert_true(type(command.description) == 'string' &&
		length(command.description) >= 1 && length(command.description) <= 256);
}

let model = {
	miclash_version: '2.0.4', miclash_state: 'running',
	mihomo_version: '1.19.29', mihomo_state: 'ready',
	proxy_mode: 'tproxy', guard_enabled: true, internet_state: 'ready',
	service_running: true, subscription_url: 'https://example.test/subscription',
	last_subscription_update: '2026-07-20 02:00', last_subscription_result: 'success',
	memory_rss: '52.1 MiB', memory_baseline: '48.0 MiB', memory_state: 'monitoring',
	last_memory_action: 'not_required', logs: 'line one\nline two',
	diagnostics: 'All required components are ready',
	updates: {
		miclash_installed: '2.0.4', miclash_available: '2.1.0',
		miclash_action: 'update',
		mihomo_installed: '1.19.29', mihomo_available: '1.19.30',
		mihomo_action: 'update'
	}
};

for (let language in [ 'en', 'ru', 'zh-cn' ]) {
	let rendered = menu.render('main', model, language, 7);
	assert_match(rendered.text, /MiClash/);
	assert_true(type(rendered.reply_markup.inline_keyboard) == 'array');
	assert_true(length(sprintf('%J', rendered)) <= 8192);
	for (let row in rendered.reply_markup.inline_keyboard)
		for (let button in row) {
			assert_true(type(button.text) == 'string' && length(button.text));
			assert_true(type(button.callback_data) == 'string');
			assert_true(length(button.callback_data) <= 64);
		}
}

let main_ru = menu.render('main', model, 'ru', 7);
assert_match(main_ru.reply_markup.inline_keyboard[0][0].text, /^📊 /);
assert_match(main_ru.reply_markup.inline_keyboard[1][0].text, /^🔗 /);

let updates_ru = menu.render('updates', model, 'ru', 7);
assert_match(updates_ru.text, /🟢 MiClash: 2\.0\.4 ↑ 2\.1\.0/);
assert_equal(updates_ru.reply_markup.inline_keyboard[1][0].text,
	'⬆️ Обновить MiClash до 2.1.0');

let reinstall_model = clone(model);
reinstall_model.updates.miclash_available = '2.0.4';
reinstall_model.updates.miclash_action = 'reinstall';
let reinstall_ru = menu.render('updates', reinstall_model, 'ru', 8);
assert_match(reinstall_ru.text, /🔄 MiClash: 2\.0\.4 = 2\.0\.4/);
assert_equal(reinstall_ru.reply_markup.inline_keyboard[1][0].text,
	'🔄 Переустановить MiClash 2.0.4');

let downgrade_model = clone(model);
downgrade_model.updates.miclash_available = '1.9.9';
downgrade_model.updates.miclash_action = 'downgrade';
let downgrade_ru = menu.render('updates', downgrade_model, 'ru', 9);
assert_match(downgrade_ru.text, /🔴 MiClash: 2\.0\.4 ↓ 1\.9\.9/);
assert_equal(downgrade_ru.reply_markup.inline_keyboard[1][0].text,
	'⬇️ Понизить MiClash до 1.9.9');
let confirm_downgrade_ru = menu.render('confirm_update_miclash', {
	...downgrade_model,
	update_action: 'downgrade',
	update_version: '1.9.9'
}, 'ru', 10);
assert_match(confirm_downgrade_ru.text, /Понизить MiClash до 1\.9\.9/);
assert_match(confirm_downgrade_ru.text, /более старая версия/);

let completed = menu.render('operation_result', {
	operation_result: 'Subscription update: completed', operation_failed: false
}, 'en', 8);
assert_equal(completed.text, 'Subscription update: completed');
assert_equal(length(completed.reply_markup.inline_keyboard), 0,
	'success result must not be mixed with a navigation menu');

for (let screen in [ 'status', 'management', 'subscription', 'updates', 'guard',
	'memory', 'logs', 'diagnostics', 'subscription_input', 'confirm_stop', 'confirm_guard_off',
	'confirm_reboot', 'confirm_update_miclash', 'confirm_update_mihomo', 'settings',
	'confirm_diagnostic_full', 'admin_input', 'confirm_admin_remove' ]) {
	let rendered = menu.render(screen, model, 'en', 7);
	assert_true(type(rendered.text) == 'string' && length(rendered.text));
	assert_true(type(rendered.reply_markup.inline_keyboard) == 'array');
}

let opened = menu.parse_callback('g7:open:status', 7);
assert_equal(opened.name, 'open'); assert_equal(opened.target, 'status');
let confirmed = menu.parse_callback('g7:confirm:stop', 7);
assert_equal(confirmed.name, 'confirm'); assert_equal(confirmed.target, 'stop');
assert_equal(menu.parse_callback('g7:execute:diagnostic_silent', 7).target,
	'diagnostic_silent');
assert_equal(menu.parse_callback('g7:execute:diagnostic_lite', 7).target,
	'diagnostic_lite');
assert_equal(menu.parse_callback('g7:confirm:diagnostic_full', 7).target,
	'diagnostic_full');
let executed = menu.parse_callback('g7:execute:reboot', 7);
assert_equal(executed.name, 'execute'); assert_equal(executed.target, 'reboot');
let backed = menu.parse_callback('g7:back:main', 7);
assert_equal(backed.name, 'back'); assert_equal(backed.target, 'main');
assert_equal(menu.parse_callback('g6:execute:reboot', 7), null,
	'stale callbacks must not execute');
assert_equal(menu.parse_callback('g7:execute:unknown', 7), null);
assert_equal(menu.parse_callback('g7:execute:reboot:extra', 7), null);
assert_equal(menu.parse_callback('g7:' + repeated('x', 64), 7), null);
assert_equal(menu.parse_callback('not-a-callback', 7), null);
assert_throws(() => menu.render('unknown', model, 'en', 7), 'INVALID_ARGUMENT');

print('telegram menu tests passed\n');
