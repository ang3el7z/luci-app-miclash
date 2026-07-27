import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const source = readFileSync(
	'luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/config.js', 'utf8'
);

assert.match(source, /function refreshAutoUpdateIntervalChoices\(hours\)/,
	'manual subscription updates must refresh the visible interval choices');
assert.match(source,
	/await applySubscriptionProfileUpdateInterval\(appliedInfo\.profileUpdateIntervalHours\);\s*refreshAutoUpdateIntervalChoices\(appliedInfo\.profileUpdateIntervalHours\);/,
	'the interval selector must refresh after a successful manual subscription update');
assert.match(source, /autoUpdateIntervalSource === 'provider'/,
	'the selector must distinguish a provider-supplied interval from a manual one');
assert.match(source, /const values = fixed \? \[current\] : preset \? AUTO_UPDATE_PRESET_INTERVAL_HOURS : \[current\];/,
	'a provider-supplied preset value must still replace the manual preset choices');
assert.match(source, /Interval set by subscription/,
	'a provider-supplied interval must be explained in the settings UI');

console.log('Profile update interval UI contract passed');
