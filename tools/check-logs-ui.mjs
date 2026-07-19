import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const config = readFileSync('luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/config.js', 'utf8');
const platform = readFileSync('luci-app-miclash/rootfs/usr/share/miclash/platform.uc', 'utf8');

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

console.log('PASS logs UI and quiet platform detection contracts');
