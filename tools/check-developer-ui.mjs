import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const config = readFileSync(
	'luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/config.js', 'utf8');
const diagnostics = readFileSync(
	'luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/diagnostics-panel.js', 'utf8');
const helper = readFileSync(
	'luci-app-miclash/rootfs/usr/share/miclash/developer-remove', 'utf8');
const makefile = readFileSync('luci-app-miclash/Makefile', 'utf8');

assert.match(config, /const DEVELOPER_TAP_COUNT = 10;/,
	'developer tab must require ten Settings taps');
assert.match(config, /const DEVELOPER_SESSION_MS = 10 \* 60 \* 1000;/,
	'developer session must expire after ten minutes');
assert.match(config, /id="sbox-developer-tab"[^>]+data-cfg-tab="developer" hidden/,
	'developer tab must be hidden initially');
for (const action of [ 'restore-network', 'remove-guard', 'remove-miclash' ])
	assert.match(config, new RegExp(`data-developer-action="${action}"`),
		`developer action ${action} is missing`);
assert.match(config, /setDeveloperVisible\(!developerVisible, true\)/,
	'ten further Settings taps must toggle the developer tab off');
assert.match(config, /sbox-log-search[\s\S]*\.hidden\s*=\s*!developerVisible/,
	'log search toolbar must follow developer session visibility');
assert.match(config, /if \(!developerVisible\)[\s\S]*?clearLogSearch\(\)/,
	'disabling developer mode must clear the local log search state');
assert.doesNotMatch(diagnostics, /data-action[^\n]+recover-network/,
	'emergency actions must not leak into component diagnostics');

assert.match(helper, /command -v apk[\s\S]+apk del "\$PACKAGE"/,
	'self-removal must support OpenWrt apk');
assert.match(helper, /command -v opkg[\s\S]+opkg remove "\$PACKAGE"/,
	'self-removal must support OpenWrt opkg');
assert.match(makefile, /INSTALL_BIN[^\n]+developer-remove/,
	'self-removal helper must be packaged as an executable');

console.log('developer UI checks passed');
