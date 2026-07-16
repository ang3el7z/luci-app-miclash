import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';

const root = 'luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/';
const paths = {
	settings: root + 'settings-panels.js',
	devices: root + 'devices-panel.js',
	backup: root + 'backup-panel.js',
	notifications: root + 'notification-poller.js',
	config: root + 'config.js',
	api: root + 'api.js',
	css: root + 'style.css'
};
for (const [name, path] of Object.entries(paths))
	assert.ok(existsSync(path), `missing ${name} module: ${path}`);

const settings = readFileSync(paths.settings, 'utf8');
const devices = readFileSync(paths.devices, 'utf8');
const backup = readFileSync(paths.backup, 'utf8');
const notificationPoller = readFileSync(paths.notifications, 'utf8');
const config = readFileSync(paths.config, 'utf8');
const api = readFileSync(paths.api, 'utf8');
const css = readFileSync(paths.css, 'utf8');

for (const [name, source] of Object.entries({ settings, devices, backup })) {
	assert.doesNotMatch(source, /(?:'require fs'|\bfs\.|\bexec\s*\(|\/bin\/sh|\/usr\/bin\/|\/sbin\/)/,
		`${name} panel bypasses the typed ubus API`);
	assert.doesNotMatch(source, /(?:innerHTML|outerHTML|insertAdjacentHTML|document\.write)/,
		`${name} panel renders untrusted values as HTML`);
}

for (const token of [
	'memoryStatus', 'memorySettings', 'memoryResetBaseline', 'telegram_status',
	'telegram_settings', 'telegram_test', 'notificationSettings', 'testNotification',
	'settings_get', 'settings_set', 'watchOperation', 'Expert settings', 'Reset baseline',
	'BotFather token', 'Allowed Telegram user ID', 'Send test', 'KNOWN_EVENTS',
	'MEMORY_LABELS', 'EVENT_LABELS', 'visibilitychange', 'destroy'
]) assert.match(settings, new RegExp(token), `settings panel missing ${token}`);
assert.match(settings, /token[^\n]*value[^\n]*''|value[^\n]*''[^\n]*token/i,
	'stored Telegram token may be populated into the input');
assert.doesNotMatch(settings, /Number\([^\n]*user[_-]?id|parseInt\([^\n]*user[_-]?id/i,
	'Telegram IDs must stay exact decimal strings beyond Number.MAX_SAFE_INTEGER');
assert.match(settings, /\[REDACTED\]/, 'masked token state is not distinguished');
assert.match(settings, /10000/); // lower expert cadence bound
assert.match(settings, /86400000/); // bounded notification dedupe window

for (const token of [
	'devicesList', 'deviceTimezones', 'devicePolicies', 'setDevicePolicy', 'deleteDevicePolicy',
	'AA:BB:CC:DD:EE:FF', 'inherit', 'proxy', 'direct', 'block', 'timezone',
	'expected_revision', 'Guard', 'visibilitychange', 'destroy'
]) assert.match(devices, new RegExp(token), `devices panel missing ${token}`);
assert.match(devices, /\^\[0-9A-Fa-f\]\{2\}/, 'device policy lacks an exact MAC validator');

for (const token of [
	'backupCreate', 'backupInspect', 'backupRestore', 'downloadChunks', 'uploadChunks',
	'settings_get', 'settings_set', 'retention', 'watchOperation', 'inspection_id', 'include_secrets', 'manifest', 'revokeObjectURL',
	'16777216', 'destroy'
]) assert.match(backup, new RegExp(token), `backup panel missing ${token}`);
assert.match(backup, /type[^\n]*file/i, 'backup import lacks a file input');
assert.match(backup, /warning|Warning/i, 'include-secrets warning is missing');

for (const token of [ 'view.miclash.settings-panels', 'view.miclash.devices-panel',
	'view.miclash.backup-panel', 'view.miclash.notification-poller', 'managementOwner',
	'notificationOwner', 'sbox-management-panels' ])
	assert.match(config, new RegExp(token), `settings integration missing ${token}`);
assert.match(css, /sbox-management-grid/);
assert.match(css, /@media[\s\S]*max-width:[\s\S]*sbox-management-grid/,
	'management panels lack a responsive layout');

assert.match(api, /devices_policy_delete[^\n]*policy_id[^\n]*expected_revision/,
	'device delete transport does not match the domain CAS contract');
assert.doesNotMatch(config, /id="sbox-memory-guard"|id="sbox-auto-hide-notifications"|miclash-memory-guard[^\n]*sync/,
	'legacy Settings form still owns Memory Guard or notification controls');
assert.doesNotMatch(config, /settings\.autoHideNotifications/,
	'notification toasts still read the removed legacy settings owner');
assert.match(config, /notificationAutoHide/,
	'notification toasts do not consume typed notifications.auto_hide state');
assert.match(api, /devices_timezones/, 'typed timezone allowlist method is missing');

const identity = (value) => String(value);
const load = (source) => new Function('ui', 'E', '_', 'document', 'window', source)(
	{}, () => ({}), identity, {}, {});
const settingsModule = load(settings);
assert.equal(settingsModule.exactTelegramId('9007199254740993123456789'), true,
	'Telegram ID beyond JS safe integer lost exact string semantics');
assert.equal(settingsModule.exactTelegramId('9e18'), false);
assert.equal(settingsModule.exactTelegramId('-42'), false);
assert.equal(settingsModule.exactTelegramToken('123456:telegram-secret'), true);
assert.equal(settingsModule.exactTelegramToken('not-a-token'), false);
assert.equal(settingsModule.exactTelegramToken('0:abcdefgh'), false);
assert.equal(Object.keys(settingsModule.MEMORY_FIELDS).length, 14);
const devicesModule = load(devices);
assert.equal(devicesModule.normalizedMac('aa:bb:cc:dd:ee:ff'), 'AA:BB:CC:DD:EE:FF');
assert.throws(() => devicesModule.normalizedMac('aa:bb:cc:dd:ee:ff; reboot'));
assert.throws(() => devicesModule.normalizedMac('ff:ff:ff:ff:ff:ff'));
assert.throws(() => devicesModule.normalizedMac('00:00:00:00:00:00'));
const backupModule = load(backup);
assert.equal(backupModule.MAX_ARCHIVE, 16777216);

if (!String.prototype.format) Object.defineProperty(String.prototype, 'format', {
	configurable: true, value(...values) { let i = 0; return this.replace(/%[sd]/g, () => String(values[i++])); }
});
class MiniNode {
	constructor(tag, attrs = {}) {
		this.tagName = String(tag).toUpperCase(); this.attrs = {}; this.children = []; this.listeners = new Map();
		this.parentNode = null; this.disabled = false; this.checked = false; this.value = ''; this.files = [];
		for (const [name, value] of Object.entries(attrs || {})) if (value != null) this.setAttribute(name, value);
	}
	set textContent(value) { this.children = [String(value ?? '')]; }
	get textContent() { return this.children.map((node) => typeof node === 'string' ? node : node.textContent).join(''); }
	setAttribute(name, value) {
		this.attrs[name] = String(value);
		if (name === 'value') this.value = String(value);
		if (name === 'checked') this.checked = true;
		if (name === 'disabled') this.disabled = true;
	}
	getAttribute(name) { return this.attrs[name] ?? null; }
	appendChild(node) { if (typeof node !== 'string') node.parentNode = this; this.children.push(node); return node; }
	replaceChildren(...nodes) { this.children = []; for (const node of nodes.flat(Infinity)) if (node != null) this.appendChild(node); }
	addEventListener(type, callback) { if (!this.listeners.has(type)) this.listeners.set(type, []); this.listeners.get(type).push(callback); }
	removeEventListener(type, callback) { this.listeners.set(type, (this.listeners.get(type) || []).filter((item) => item !== callback)); }
	click() { for (const callback of this.listeners.get('click') || []) callback({ preventDefault() {}, target: this }); }
	dispatch(type) { for (const callback of this.listeners.get(type) || []) callback({ target: this }); }
	remove() { if (this.parentNode) this.parentNode.children = this.parentNode.children.filter((item) => item !== this); }
	matches(selector) {
		if (selector.startsWith('#')) return this.getAttribute('id') === selector.slice(1);
		if (selector.startsWith('.')) return (this.getAttribute('class') || '').split(/\s+/).includes(selector.slice(1));
		const attr = selector.match(/^\[([^=\]]+)(?:="([^"]*)")?\]$/);
		if (attr) return this.getAttribute(attr[1]) != null && (attr[2] == null || this.getAttribute(attr[1]) === attr[2]);
		return this.tagName === selector.toUpperCase();
	}
	querySelectorAll(selector) { const output = []; for (const child of this.children) if (typeof child !== 'string') {
		if (child.matches(selector)) output.push(child); output.push(...child.querySelectorAll(selector)); } return output; }
	querySelector(selector) { return this.querySelectorAll(selector)[0] || null; }
}
const E = (tag, attrs, children) => {
	const node = new MiniNode(tag, attrs || {});
	for (const child of (Array.isArray(children) ? children : [children]).flat(Infinity))
		if (child != null) node.appendChild(typeof child === 'string' || typeof child === 'number' ? String(child) : child);
	return node;
};
const listeners = new Map(), timers = new Set(), urls = new Set(), modalCalls = [];
const documentMock = {
	hidden: false, addEventListener(type, fn) { listeners.set(type, fn); },
	removeEventListener(type, fn) { if (listeners.get(type) === fn) listeners.delete(type); },
	createElement(tag) { return new MiniNode(tag); }
};
const windowMock = {
	setTimeout(fn) { const token = { fn }; timers.add(token); return token; },
	clearTimeout(token) { timers.delete(token); },
	URL: { createObjectURL() { const url = 'blob:test-' + urls.size; urls.add(url); return url; },
		revokeObjectURL(url) { urls.delete(url); } }
};
const uiMock = { showModal(title, body) { modalCalls.push({ title, body }); }, hideModal() { modalCalls.push({ hidden: true }); }, addNotification() {} };
const dynamicLoad = (source) => new Function('ui', 'E', '_', 'document', 'window', source)(
	uiMock, E, identity, documentMock, windowMock);
const tick = () => new Promise((resolve) => setImmediate(resolve));

const settingsCalls = [], settingsErrors = [], autoHideChanges = [];
let settingsFailNext = false, notificationSent = true;
const settingsApi = {
	async settings_get() { if (settingsFailNext) { settingsFailNext = false; throw new Error('transient'); }
		return { memory: { enabled: true }, telegram: { enabled: true },
		notifications: { auto_hide: true, channels: [ 'telegram' ], events: [ 'failure' ] } }; },
	async memoryStatus() { return { phase: 'monitoring', current_rss_kb: 64000, baseline_rss_kb: 32000 }; },
	async memorySettings() { return Object.fromEntries(Object.entries(settingsModule.MEMORY_FIELDS).map(([name, range]) => [name, range[2]])); },
	async telegram_status() { return { running: true, configured: true }; },
	async telegram_settings() { return { enabled: true, token: '[REDACTED]', user_id: '9007199254740993123456789' }; },
	async notificationSettings() { return {}; },
	async settings_set(patch, source) { settingsCalls.push([ 'settings_set', patch, source ]); return { operation_id: 'save-settings' }; },
	async telegram_test() { settingsCalls.push([ 'telegram_test' ]); return { sent: true }; },
	async testNotification(channel) { settingsCalls.push([ 'notifications_test', channel ]); return { sent: notificationSent }; },
	async memoryResetBaseline() { return { operation_id: 'reset-memory' }; },
	watchOperation(id, callback) { callback({ id, state: 'success', progress: 100 }); return () => settingsCalls.push([ 'cancel', id ]); },
	destroy() { settingsCalls.push([ 'destroy' ]); }
};
const settingsPanel = dynamicLoad(settings).create({ api: settingsApi, document: documentMock, window: windowMock,
	onError(error) { settingsErrors.push(error); },
	onNotificationSettings(value) { autoHideChanges.push(value); } });
const settingsHost = new MiniNode('div'); settingsPanel.mount(settingsHost); await tick();
assert.equal(autoHideChanges.at(-1)?.auto_hide, true,
	'typed notification auto_hide state was not published to the page owner');
assert.equal(settingsHost.querySelector('#sbox-telegram-token').value, '', 'stored Telegram token entered the DOM input');
assert.equal(settingsHost.querySelector('#sbox-telegram-user-id').value, '9007199254740993123456789');
assert.equal(settingsHost.querySelector('.sbox-management-expert').getAttribute('open'), null,
	'expert memory settings are expanded by default');
const dirtyToken = settingsHost.querySelector('#sbox-telegram-token');
dirtyToken.value = 'draft-token'; dirtyToken.dispatch('input');
const firstPoll = Array.from(timers)[0]; timers.delete(firstPoll); settingsFailNext = true; firstPoll.fn();
await tick(); await tick();
assert.equal(settingsHost.querySelector('#sbox-telegram-token'), dirtyToken,
	'failed status poll replaced a dirty token input');
assert.equal(dirtyToken.value, 'draft-token');
const recoveryPoll = Array.from(timers)[0]; timers.delete(recoveryPoll); recoveryPoll.fn(); await tick(); await tick();
assert.equal(settingsHost.querySelector('#sbox-telegram-token'), dirtyToken,
	'successful status poll replaced a dirty form');
dirtyToken.value = '';
settingsHost.querySelector('[data-action="telegram-test"]').click(); await tick(); await tick();
assert.equal(settingsCalls.findIndex((call) => call[0] === 'settings_set') <
	settingsCalls.findIndex((call) => call[0] === 'telegram_test'), true,
	'Telegram test ran before validated settings save completed');
assert.equal(settingsCalls.find((call) => call[0] === 'settings_set')[1].telegram.token, undefined,
	'blank Telegram token overwrote the stored secret');
notificationSent = false;
settingsHost.querySelector('#sbox-notification-test-channel').value = 'telegram';
settingsHost.querySelector('[data-action="notification-test"]').click(); await tick(); await tick(); await tick();
assert.match(String(settingsErrors.at(-1)?.message || ''), /not sent/i,
	'notification sent=false was reported as success');
settingsPanel.destroy();
assert.ok(settingsCalls.some((call) => call[0] === 'destroy'));
assert.equal(Array.from(timers).length, 0, 'destroy left a settings poll timer behind');

const notificationCalls = [], notificationToasts = [];
let notificationPage = 0;
const notificationApi = {
	async notificationEvents(generation, cursor, limit) {
		notificationCalls.push([ generation, cursor, limit ]);
		if (notificationPage++ === 0) return {
			generation: 'ng_00000000000000000000000000000001', cursor: 0,
			stale: false, has_more: false, events: []
		};
		if (notificationPage === 2) return {
			generation: 'ng_00000000000000000000000000000001', cursor: 1,
			stale: false, has_more: false, events: [ { cursor: 1, event: {
				type: 'subscription_outcome', severity: 'notice', component: 'subscription',
				title: 'Subscription updated', message: 'Validated configuration is active'
			} } ]
		};
		return { generation: 'ng_00000000000000000000000000000001',
			cursor, stale: false, has_more: false, events: [] };
	},
	destroy() { notificationCalls.push([ 'destroy' ]); }
};
const poller = dynamicLoad(notificationPoller).create({ api: notificationApi,
	document: documentMock, window: windowMock,
	onEvent(event) { notificationToasts.push(event); } });
poller.start(); await tick(); await tick();
assert.equal(notificationToasts.length, 0, 'bootstrap replayed old daemon notifications as LuCI toasts');
const notificationTimer = Array.from(timers)[0]; timers.delete(notificationTimer);
notificationTimer.fn(); await tick(); await tick();
assert.equal(notificationToasts.length, 1, 'one daemon event did not produce exactly one LuCI toast');
const duplicateTimer = Array.from(timers)[0]; timers.delete(duplicateTimer);
duplicateTimer.fn(); await tick(); await tick();
assert.equal(notificationToasts.length, 1, 'cursor polling repeated an already consumed LuCI toast');
poller.destroy();
assert.ok(notificationCalls.some((call) => call[0] === 'destroy'));
assert.equal(Array.from(timers).length, 0, 'notification poller left a lifecycle timer behind');

const deviceCalls = [];
const knownPolicy = { id: 'dp_1_0000000000000001', revision: 7, scope: 'device',
	mac: 'aa:bb:cc:dd:ee:ff', action: 'proxy', schedule: null };
const devicesApi = {
	async devicesList() { return [ { hostname: '<script>alert(1)</script>', mac: 'aa:bb:cc:dd:ee:ff',
		last_seen: 1, addresses: [ { address: '192.0.2.2', current: true } ] } ]; },
	async devicePolicies() { return [ knownPolicy ]; },
	async deviceTimezones() { return [ 'UTC', 'Europe/Berlin' ]; },
	async setDevicePolicy(policy, source) { deviceCalls.push([ 'set', policy, source ]); return { operation_id: 'policy-save' }; },
	async deleteDevicePolicy(id, revision, source) { deviceCalls.push([ 'delete', id, revision, source ]); return { operation_id: 'policy-delete' }; },
	watchOperation(id, callback) { callback({ id, state: 'success' }); return () => {}; }, destroy() { deviceCalls.push([ 'destroy' ]); }
};
const devicesPanel = dynamicLoad(devices).create({ api: devicesApi, document: documentMock, window: windowMock });
const devicesHost = new MiniNode('div'); devicesPanel.mount(devicesHost); await tick();
assert.match(devicesHost.textContent, /proxy/, 'lowercase domain MAC did not match the displayed device policy');
assert.equal(devicesHost.querySelector('script'), null, 'hostile hostname was interpreted as HTML');
assert.match(devicesHost.textContent, /Guard has highest precedence/);
const deviceModal = devicesPanel.openEditor('AA:BB:CC:DD:EE:FF', { hostname: 'router' }, knownPolicy);
assert.equal(deviceModal.querySelector('#sbox-device-timezone').tagName, 'SELECT');
deviceModal.querySelector('#sbox-device-policy-action').value = 'block';
deviceModal.querySelector('[data-action="save"]').click(); await tick(); await tick();
assert.deepEqual(deviceCalls.find((call) => call[0] === 'set'), [ 'set', {
	id: knownPolicy.id, expected_revision: 7, scope: 'device', mac: 'AA:BB:CC:DD:EE:FF',
	interface: null, action: 'block', schedule: null
}, 'luci' ]);
devicesPanel.destroy();
assert.ok(deviceCalls.some((call) => call[0] === 'destroy'));
let releaseDevices, releasePolicies;
const lateApi = {
	devicesList() { return new Promise((resolve) => { releaseDevices = resolve; }); },
	devicePolicies() { return new Promise((resolve) => { releasePolicies = resolve; }); },
	async deviceTimezones() { return [ 'UTC' ]; },
	async setDevicePolicy() { return { operation_id: 'unused' }; }, async deleteDevicePolicy() { return { operation_id: 'unused' }; },
	watchOperation() { return () => {}; }, destroy() {}
};
const latePanel = dynamicLoad(devices).create({ api: lateApi, document: documentMock, window: windowMock });
const lateHost = new MiniNode('div'); latePanel.mount(lateHost); const beforeLate = lateHost.textContent;
latePanel.destroy(); releaseDevices([ { hostname: 'late mutation', mac: 'aa:bb:cc:dd:ee:ff' } ]); releasePolicies([]);
await tick(); await tick();
assert.equal(lateHost.textContent, beforeLate, 'late device reply mutated a destroyed/replaced panel');

const backupCalls = [];
const fullManifest = Array.from({ length: 1024 }, (_, index) => ({
	path: index === 0 ? '<img src=x onerror=alert(1)>' : `config/file-${index + 1}.yaml`,
	size: index + 1,
	sha256: 'a'.repeat(64), secret: index === 0,
	content: 'DO_NOT_RENDER'
}));
const backupApi = {
	async backupList() { return []; }, async settings_get() { return { backup: { enabled: true,
		retention: 7, include_secrets: false, interval_hours: 24, schedule_time: '03:00' } }; },
	async settings_set(patch, source) { backupCalls.push([ 'settings', patch, source ]); return { operation_id: 'backup-settings' }; },
	async backupCreate() { return { operation_id: 'backup-create' }; },
	async backupInspect(id) { backupCalls.push([ 'inspect', id ]); return { id: 'x-0000000000001-00000000000000000000000000000003',
		source_id: id, created_at: 1710000000000, inspected_at: 1710000001000, expires_at: 1710000900000,
		includes: [ 'settings', '<b>rulesets</b>' ],
		files: fullManifest, app_version: '1' }; },
	async backupRestore(id, source) { backupCalls.push([ 'restore', id, source ]); return { operation_id: 'restore-one' }; },
	async downloadChunks() { return new Uint8Array([1]); },
	async uploadChunks(kind, metadata, payload) { backupCalls.push([ 'upload', kind, metadata, payload.byteLength ]);
		return { completed: true, result: { import_id: 'i-0000000000001-00000000000000000000000000000002' } }; },
	watchOperation(id, callback) { callback({ id, state: 'success' }); return () => {}; }, destroy() {}
};
const backupPanel = dynamicLoad(backup).create({ api: backupApi, document: documentMock, window: windowMock });
const backupHost = new MiniNode('div'); backupPanel.mount(backupHost); await tick();
assert.equal(backupHost.querySelector('#sbox-backup-retention').value, '7');
assert.equal(backupHost.querySelector('#sbox-backup-interval').value, '24');
assert.equal(backupHost.querySelector('#sbox-backup-time').value, '03:00');
assert.equal(backupHost.querySelector('[role="alert"]')?.textContent.includes('Warning'), true,
	'secret-backup warning does not use the standard alert role');
backupHost.querySelector('[data-action="save-settings"]').click(); await tick(); await tick();
assert.deepEqual(backupCalls.find((call) => call[0] === 'settings'), [ 'settings', {
	backup: { enabled: true, retention: 7, include_secrets: false,
		interval_hours: 24, schedule_time: '03:00' }
}, 'luci' ]);
backupCalls.length = 0;
const archive = { size: 1, async arrayBuffer() { return new Uint8Array([7]).buffer; } };
await backupPanel.importArchive(archive);
assert.deepEqual(backupCalls.map((call) => call[0]), [ 'upload', 'inspect' ], 'import restored before inspection preview');
const planBody = modalCalls.at(-1).body;
assert.equal(planBody.querySelector('img'), null, 'backup manifest was interpreted as HTML');
for (const expected of [ 'x-0000000000001-00000000000000000000000000000003',
	'i-0000000000001-00000000000000000000000000000002', 'settings', '<b>rulesets</b>',
	'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'secret' ])
	assert.ok(planBody.textContent.includes(expected), `manifest preview omitted ${expected}`);
assert.doesNotMatch(planBody.textContent, /DO_NOT_RENDER/, 'manifest preview rendered an unapproved secret field');
assert.ok(planBody.textContent.includes('config/file-1024.yaml'),
	'manifest preview omitted the backend-supported 1024th file');
assert.equal(planBody.querySelectorAll('.sbox-backup-manifest')[0]?.getAttribute('aria-label'), 'Backup manifest',
	'backup manifest has no accessible name');
planBody.querySelector('[data-action="restore"]').click(); await tick(); await tick();
assert.equal(backupCalls.at(-1)[0], 'restore');
assert.match(backupCalls.at(-1)[1], /^x-/, 'restore did not use the opaque inspection ID');
backupApi.uploadChunks = async () => ({ completed: true,
	import_id: 'i-0000000000001-00000000000000000000000000000004' });
await assert.rejects(backupPanel.importArchive(archive), /Invalid backup import response/,
	'non-envelope import response was accepted');
backupPanel.destroy();

console.log('MiClash management panels contract passed');
