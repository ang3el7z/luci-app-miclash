import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';

const root = 'luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/';
const paths = {
	settings: root + 'settings-panels.js',
	devices: root + 'devices-panel.js',
	notifications: root + 'notification-poller.js',
	config: root + 'config.js',
	css: root + 'style.css'
};
for (const [name, path] of Object.entries(paths))
	assert.ok(existsSync(path), `missing ${name} module: ${path}`);
assert.equal(existsSync(root + 'backup-panel.js'), false, 'removed Backup panel is still shipped');

const settings = readFileSync(paths.settings, 'utf8');
const devices = readFileSync(paths.devices, 'utf8');
const notifications = readFileSync(paths.notifications, 'utf8');
const config = readFileSync(paths.config, 'utf8');
const css = readFileSync(paths.css, 'utf8');

for (const [name, source] of Object.entries({ settings, devices })) {
	assert.doesNotMatch(source, /(?:'require fs'|\bfs\.|\bexec\s*\(|\/bin\/sh|\/usr\/bin\/|\/sbin\/)/,
		`${name} panel bypasses the typed ubus API`);
	assert.doesNotMatch(source, /(?:innerHTML|outerHTML|insertAdjacentHTML|document\.write)/,
		`${name} panel renders untrusted values as HTML`);
}

for (const token of [
	'memoryStatus', 'memorySettings', 'memoryResetBaseline', 'telegram_status',
	'telegram_settings', 'telegram_token_reveal', 'telegram_test', 'notificationSettings', 'testNotification',
	'settings_get', 'collectPatch', 'markSaved', 'Expert settings', 'Reset baseline',
	'BotFather token', 'Allowed Telegram user ID', 'Send test', 'KNOWN_EVENTS',
	'MEMORY_LABELS', 'EVENT_LABELS', 'visibilitychange', 'destroy'
]) assert.match(settings, new RegExp(token), `settings panel missing ${token}`);
assert.match(settings, /view\.miclash\.ui-shell/,
	'settings panel must use the shared loading surface');
assert.match(settings, /let hydrated = false/,
	'settings panel must distinguish loading from real defaults');
assert.match(settings, /loadingBlock\(\{ kind: 'normal'/,
	'settings panel must render a card-level shimmer before RPC hydration');
assert.match(settings, /if \(!hydrated\)[\s\S]*Settings panel is still loading/,
	'settings cannot collect false defaults before hydration');
assert.match(settings, /Automatically close LuCI notifications/,
	'notification auto-close wording is not user friendly');
assert.match(settings, /Delivery channels/,
	'notification delivery channels must be named explicitly');
assert.match(settings, /Notification events/,
	'notification event selection must be named explicitly');
assert.doesNotMatch(settings, /Save management settings|data-action[^\n]*save/,
	'management panel still owns a separate save button');
assert.doesNotMatch(settings, /backup_outcome|Backup result/,
	'removed Backup notification remains in Settings');
assert.match(settings, /'value': configured \? MASK : ''/,
	'stored Telegram token must render only as a masked sentinel');
assert.match(settings, /await api\.telegram_token_reveal\(\)/,
	'token reveal must use the dedicated authenticated RPC method');
assert.doesNotMatch(settings, /Number\([^\n]*user[_-]?id|parseInt\([^\n]*user[_-]?id/i,
	'Telegram IDs must stay exact decimal strings beyond Number.MAX_SAFE_INTEGER');

for (const token of [
	'devicesList', 'deviceTimezones', 'devicePolicies', 'setDevicePolicy', 'deleteDevicePolicy',
	'AA:BB:CC:DD:EE:FF', 'inherit', 'proxy', 'direct', 'block', 'timezone',
	'expected_revision', 'Guard', 'visibilitychange', 'destroy'
]) assert.match(devices, new RegExp(token), `devices panel missing ${token}`);

for (const token of [ 'view.miclash.settings-panels', 'view.miclash.devices-panel',
	'view.miclash.notification-poller', 'managementOwner', 'notificationOwner',
	'sbox-management-panels', 'id="sbox-settings-save"' ])
	assert.match(config, new RegExp(token), `settings integration missing ${token}`);
assert.doesNotMatch(config, /view\.miclash\.backup-panel|sbox-management-backup/);
assert.match(css, /\.sbox-settings-zone\s*\{/,
	'settings page lacks semantic content zones');
assert.match(css, /\.sbox-overview-grid[\s\S]*grid-template-columns:\s*repeat\(12,/,
	'settings overview does not use the balanced twelve-column grid');
assert.match(css, /@media\s*\(max-width:\s*1050px\)[\s\S]*\.sbox-overview-routing/,
	'settings overview lacks its intermediate responsive layout');
assert.match(css, /@media\s*\(max-width:\s*760px\)[\s\S]*\.sbox-settings-pair-grid[\s\S]*grid-template-columns:\s*minmax\(0,\s*1fr\)/,
	'settings cards lack the compact single-column layout');
assert.match(config, /class="sbox-form-grid sbox-hwid-fields"[\s\S]{0,120}s\.enableHwid \? '' : ' hidden'/,
	'HWID detail fields must stay hidden until the option is enabled');

const identity = (value) => String(value);
const baseclass = { extend: (value) => value };
const module = new Function('baseclass', 'ui', 'E', '_', 'document', 'window', settings)(
	baseclass, {}, () => ({}), identity, {}, {});
assert.equal(module.exactTelegramId('9007199254740993123456789'), true);
assert.equal(module.exactTelegramId('9e18'), false);
assert.equal(module.exactTelegramToken('123456:telegram-secret'), true);
assert.equal(module.exactTelegramToken('not-a-token'), false);
assert.equal(Object.keys(module.MEMORY_FIELDS).length, 14);
assert.match(notifications, /let generation = ''/,
	'notification polling must not send a JSON null through the string ubus signature');

console.log('MiClash unified settings panels contract passed');
