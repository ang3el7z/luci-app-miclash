import assert from 'node:assert/strict';
import fs from 'node:fs';

const root = 'luci-app-miclash/rootfs/www/luci-static/resources/view/miclash';

function load(name, globals) {
	let source = fs.readFileSync(`${root}/${name}`, 'utf8')
		.replace(/^'use strict';\s*/m, '')
		.replace(/^'require [^']+';\s*/gm, '');
	const names = Object.keys(globals);
	return Function(...names, source)(...names.map((key) => globals[key]));
}

const logCalls = [];
const logs = load('logs.js', {
	L: { Class: { extend: (value) => value } },
	view_miclash_utils: { formatClashLogMessage: (value) => value },
	view_miclash_api: { create: () => ({
		destroy: () => null,
		logs_read: async (generation, cursor, limit) => {
			logCalls.push({ generation, cursor, limit });
			return cursor === 0
				? { generation: 'log_1', cursor: 0, next_cursor: 2,
					lines: [ 'a', 'b' ], has_more: true, stale: false }
				: { generation: 'log_1', cursor: 2, next_cursor: 3,
					lines: [ 'c' ], has_more: false, stale: false };
		}
	}) }
});
assert.equal(await logs.readRaw(), 'a\nb\nc');
assert.deepEqual(logCalls, [
	{ generation: '', cursor: 0, limit: 200 },
	{ generation: 'log_1', cursor: 2, limit: 200 }
]);
const errLog = logs.formatLine('daemon.err miclash[123]: recoverable failure');
assert.equal(errLog.level, 'ERROR', 'syslog ERR must normalize to ERROR');
assert.equal(errLog.levelClass, 'sbox-log-level-error');
const critLog = logs.formatLine('daemon.crit miclash[123]: critical failure');
assert.equal(critLog.level, 'CRIT', 'syslog CRIT must retain a distinct critical level');
assert.equal(critLog.levelClass, 'sbox-log-level-crit');
const fatalLog = logs.formatLine('daemon.fatal miclash[123]: fatal failure');
assert.equal(fatalLog.level, 'FATAL', 'critical aliases must retain their original labels');
assert.equal(fatalLog.levelClass, 'sbox-log-level-fatal');

const styleSource = fs.readFileSync(`${root}/style.css`, 'utf8');
assert.match(styleSource,
	/\.sbox-log-level-crit \.sbox-log-level,[\s\S]*\.sbox-log-level-emerg \.sbox-log-level\s*\{[^}]*color:\s*var\(--sbox-code-key\)/,
	'critical badges must reuse the YAML key color');

const settingsCalls = [];
let nextOperationId = 0;
const typedSettings = {
	core: { proxy_mode: 'tun', tun_stack: 'gvisor', block_quic: false,
		use_tmpfs_rules: false, hwid_enabled: true, hwid_user_agent: 'Agent',
		hwid_device_os: 'OpenWrt' },
	interfaces: { mode: 'explicit', auto_detect_lan: true, auto_detect_wan: false,
		detected_lan: 'br-lan', detected_wan: 'wan', included: [ 'lan1' ], excluded: [] },
	memory: { enabled: true }, notifications: { auto_hide: false },
	updates: { auto_subscription: false, interval_hours: 12,
		miclash_release_channel: 'prerelease', mihomo_release_channel: 'release',
		auto_major_miclash: false }
};
const settingsModel = load('settings-model.js', {
	L: { Class: { extend: (value) => value }, resolveDefault: async (value, fallback) => {
		try { return await value; } catch (_) { return fallback; }
	} },
	fs: { read: async () => { throw new Error('direct fs is forbidden'); },
		exec: async () => { throw new Error('direct fs is forbidden'); } },
	network: { getDevices: async () => [], getNetworks: async () => [] },
	view_miclash_store: new Proxy({}, { get: () => { throw new Error('legacy store is forbidden'); } }),
	view_miclash_release: { normalizeReleaseChannel: (value) => value },
	view_miclash_api: { create: () => ({
		destroy: () => settingsCalls.push({ method: 'destroy' }),
		settings_get: async () => { settingsCalls.push({ method: 'settings_get' }); return typedSettings; },
		config_read: async (profile) => {
			settingsCalls.push({ method: 'config_read', profile });
			return { profile, content: 'mixed-port: 7890\ntproxy-port: 7893\n' };
		},
		operational_settings_apply: async (profile, content, settings, source) => {
			settingsCalls.push({ method: 'operational_settings_apply', profile, content, settings, source });
			return { operation_id: `settings-${++nextOperationId}` };
		},
		watchOperation: (operationId, callback) => {
			queueMicrotask(() => callback({ id: operationId, state: 'success' }));
			return () => null;
		},
		network_interfaces: async () => ({ interfaces: [ 'wan', 'br-lan', 'wlan0' ],
			detected_lan: 'br-lan', detected_wan: 'wan' }),
		system_info: async () => ({ hwid: 'abc', openwrt_version: '24.10', model: 'Router' })
	}) }
});
const mappedSettings = await settingsModel.loadOperationalSettings();
assert.equal(mappedSettings.proxyMode, 'tun');
assert.equal(mappedSettings.tunStack, 'gvisor');
assert.equal(mappedSettings.enableMemoryGuard, true);
assert.equal(mappedSettings.autoUpdateIntervalHours, '12');
assert.equal(mappedSettings.miclashReleaseChannel, 'prerelease');
assert.equal(mappedSettings.autoMajorMiclash, false);
const unchangedOperationalForm = {
	...mappedSettings,
	selected: [ 'lan1', 'br-lan' ]
};
assert.equal(settingsModel.operationalSettingsChanged(mappedSettings, {
	...unchangedOperationalForm,
	miclashReleaseChannel: 'release',
	autoMajorMiclash: true
}), false, 'update preferences alone must not apply or restart Mihomo');
assert.equal(settingsModel.operationalSettingsChanged(mappedSettings, {
	...unchangedOperationalForm,
	blockQuic: true
}), true, 'a runtime routing change must apply Mihomo settings');
assert.equal(settingsModel.operationalSettingsChanged(mappedSettings, {
	...unchangedOperationalForm,
	selected: [ 'lan2', 'br-lan' ]
}), true, 'an interface policy change must apply Mihomo settings');
assert.deepEqual((await settingsModel.getNetworkInterfaces()).map((item) => item.name),
	[ 'wan', 'br-lan', 'wlan0' ]);
assert.equal(await settingsModel.detectLanBridge(), 'br-lan');
assert.equal(await settingsModel.detectWanInterface(), 'wan');
assert.ok(settingsCalls.some((call) => call.method === 'settings_get'));
assert.equal(await settingsModel.saveOperationalSettings(
	'explicit', 'tun', 'system', true, false, true, true,
	[ 'br-lan', 'lan1' ], false, 'MiClash', 'OpenWrt',
	'release', 'release', true, '12', false
), true);
assert.deepEqual(settingsCalls
	.filter((call) => call.method === 'operational_settings_apply')
	.map((call) => call.method),
[ 'operational_settings_apply' ]);
assert.deepEqual(settingsCalls.find((call) => call.method === 'operational_settings_apply').settings.interfaces.included, [ 'lan1' ]);
assert.equal(settingsCalls.find((call) => call.method === 'operational_settings_apply').settings.updates, undefined,
	'passive update preferences must not trigger a Mihomo operational apply');

const rulesetCalls = [];
const rulesets = load('rulesets-model.js', {
	L: { Class: { extend: (value) => value }, resolveDefault: async (value, fallback) => {
		try { return await value; } catch (_) { return fallback; }
	} },
	fs: new Proxy({}, { get: () => { throw new Error('direct fs is forbidden'); } }),
	view_miclash_utils: {},
	view_miclash_api: { create: () => ({
		destroy: () => null,
		ruleset_list: async () => ({ names: [ 'ads.txt' ] }),
		ruleset_read: async (name) => {
			rulesetCalls.push({ method: 'read', name });
			return { name, content: name === 'fakeip-whitelist-ipcidr.txt' ? '10.0.0.0/8\n' : 'DOMAIN,ads.test\n' };
		},
		config_read: async () => 'dns:\n  enable: true\n  enhanced-mode: fake-ip\n  fake-ip-filter-mode: whitelist\n'
	}) }
});
const rulesetData = await rulesets.readData('config.yaml');
assert.deepEqual(rulesetData.rulesetNames, [ 'ads.txt' ]);
assert.equal(rulesetData.contentMap['ads.txt'], 'DOMAIN,ads.test\n');
assert.equal(rulesetData.whitelistMode, true);
assert.equal(rulesetData.whitelistContent, '10.0.0.0/8\n');
assert.equal(await rulesets.readFile('ads.txt'), 'DOMAIN,ads.test\n');

const boundedRulesetCalls = [];
const boundedRulesets = load('rulesets-model.js', {
	L: { Class: { extend: (value) => value } },
	view_miclash_api: { create: () => ({
		destroy: () => null,
		ruleset_list: async () => ({ names: [ 'a.txt', 'b.txt', 'c.txt' ] }),
		ruleset_read: async (name) => {
			boundedRulesetCalls.push(name);
			return { name, content: `${name}\n` };
		},
		config_read: async () => ({ content: 'dns:\n  enable: false\n' })
	}) }
});
const boundedData = await boundedRulesets.readData('config.yaml');
assert.deepEqual(boundedData.rulesetNames, [ 'a.txt', 'b.txt', 'c.txt' ]);
assert.deepEqual(boundedRulesetCalls, [ 'a.txt' ],
	'ruleset inventory must load only the initially selected file');
assert.equal(boundedData.contentMap['a.txt'], 'a.txt\n');
assert.equal(boundedData.contentMap['b.txt'], undefined);

const configSource = fs.readFileSync(`${root}/config.js`, 'utf8');
assert.ok(!/saveRulesetWhitelist[\s\S]{0,200}\.code\s*===\s*0/.test(configSource),
	'whitelist save must use typed operation success, not legacy exec status');
assert.ok(configSource.includes('installed && !!local && !!latest'),
	'unknown installed Mihomo version must not be presented as a confirmed update');

const operationStore = load('store.js', {
	L: { Class: { extend: (value) => value } },
	view_miclash_api: { create: () => ({ destroy: () => null }) }
});
assert.equal(operationStore.selectActiveOperation([
	{ id: 'old-running', kind: 'updates.miclash', state: 'running', created_at: 10 },
	{ id: 'new-queued', kind: 'updates.mihomo', state: 'queued', created_at: 20 },
	{ id: 'done', kind: 'updates.mihomo', state: 'success', created_at: 30 }
], 'updates.').id, 'new-queued');
assert.equal(operationStore.selectActiveOperation([
	{ id: 'service', kind: 'service.restart', state: 'running', created_at: 1 }
], 'updates.'), null);

console.log('LuCI typed domain adapters passed');
