import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const config = readFileSync('luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/config.js', 'utf8');
const logs = readFileSync('luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/logs.js', 'utf8');
const daemon = readFileSync('luci-app-miclash/rootfs/usr/share/miclash/daemon.uc', 'utf8');
const activation = readFileSync('luci-app-miclash/rootfs/usr/share/miclash/daemon-activation.uc', 'utf8');
const platform = readFileSync('luci-app-miclash/rootfs/usr/share/miclash/platform.uc', 'utf8');
const producers = new Map([
	['daemon-activation.uc', /write\('daemon: ' \+ message\)/],
	['operations.uc', /write\('operations: ' \+ message\)/],
	['reconcile-adapter.uc', /write\('reconcile: ' \+ message\)/],
	['provider-sync.uc', /logger\?\.\[level\]\?\.\('provider-sync: ' \+ message\)/],
	['telegram.uc', /logger\?\.warn\('telegram: ' \+ message\)/],
	['http.uc', /logger\?\.warn\('http: /],
	['device-vendor-update.uc', /logger\?\.warn\('device-vendors: /]
]);

assert.ok(!config.includes('No logs yet.'), 'empty logs must explain why no records are shown');
assert.match(config, /function configuredLogLevel\(/, 'logs must derive the configured Mihomo log level');
assert.match(config, /No MiClash or Mihomo records match the current log level yet/,
	'empty logs must describe the active filter');
assert.match(platform, /runtime\?\.fs\?\.stat/, 'package manager detection must use filesystem metadata');
assert.ok(!platform.includes("args: [ '--version' ]"),
	'package manager detection must not poll noisy version subprocesses');
assert.match(config, /view_miclash_api\.isSessionExpired\(error\)/,
	'operation errors must defer session expiry to the native LuCI login modal');
assert.match(config, /function suspendForSessionExpiry\([\s\S]*stopInterval\(controlPollTimer\)[\s\S]*diagnosticsOwner\.destroy\(\)[\s\S]*managementOwner\.destroy\(\)/,
	'session expiry must stop background MiClash owners instead of stacking RPC banners');
assert.ok(!logs.includes('clash-rules') && !logs.includes('clash-hotplug'),
	'LuCI log parser must not retain removed legacy producers');
assert.ok(!daemon.includes('clash(-rules|-hotplug)'),
	'backend log reader must not retain removed legacy producers');
assert.ok(!/catch \(e\) \{\s*return '';\s*\}/.test(logs),
	'transient RPC errors must not be converted into a successful empty log response');
assert.match(logs, /let readerState = \{ generation: '', cursor: 0, lines: \[\] \}/,
	'log reader must retain its page-session cursor');
assert.match(logs, /api\.logs_read\(readerState\.generation, readerState\.cursor, 200\)/,
	'subsequent log refreshes must request only appended records');
assert.match(logs, /reset: reset/,
	'route unload must be able to clear the page-session log cursor');
assert.match(config, /view_miclash_logs\.reset\(\)/,
	'route unload must reset incremental log state');
const tabs = config.slice(config.indexOf('function bindTabEvents()'), config.indexOf('\nreturn view.extend'));
assert.match(tabs, /if \(name !== 'logs'\) stopLogPolling\(\)/,
	'log polling must stop whenever the Logs tab is not active');
assert.match(config, /else if \(appState\.activeCfgTab === 'logs' && logsLoaded\)/,
	'visibility recovery must restart polling only on the active Logs tab');
assert.match(activation, /operational_log\('info', 'starting'\)/);
assert.match(activation, /operational_log\('info', 'ready'\)/);
assert.match(activation, /operational_log\('info', 'stopped'\)/);
for (const [file, contract] of producers) {
	const source = readFileSync(`luci-app-miclash/rootfs/usr/share/miclash/${file}`, 'utf8');
	assert.match(source, contract,
		`${file} must identify its component in the shared miclash log`);
}

console.log('PASS logs UI and quiet platform detection contracts');
