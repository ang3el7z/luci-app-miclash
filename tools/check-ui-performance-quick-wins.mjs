import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const config = readFileSync(
	'luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/config.js', 'utf8');

function block(startText, endText) {
	const start = config.indexOf(startText);
	assert.notEqual(start, -1, `missing block start: ${startText}`);
	const end = config.indexOf(endText, start + startText.length);
	assert.notEqual(end, -1, `missing block end: ${endText}`);
	return config.slice(start, end);
}

const headerRefresh = block(
	'async function refreshHeaderAndControl()',
	'\nasync function refreshServiceState()'
);
assert.equal((headerRefresh.match(/system_info\(\)/g) || []).length, 1,
	'header refresh must obtain one shared system_info snapshot');
assert.doesNotMatch(headerRefresh, /getVersions\(\)|getMihomoStatus\(\)/,
	'header refresh still calls duplicate system-info wrappers');

const subscriptionHandler = block(
	"const updateUrlBtn = pageRoot.querySelector('#sbox-update-sub');",
	"\n\tconst clearUrlBtn = pageRoot.querySelector('#sbox-clear-sub-url');"
);
const afterApply = subscriptionHandler.slice(
	subscriptionHandler.indexOf('const appliedInfo = await applySubscriptionOnRouter(')
);
assert.doesNotMatch(afterApply, /restartOrReloadServiceOrThrow\('reload'/,
	'UI reloads Mihomo after the backend subscription operation already did it');
assert.doesNotMatch(subscriptionHandler, /const versions = await getVersions\(\)/,
	'subscription update reads versions that the backend operation does not consume');

const subscriptionSource = readFileSync(
	'luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/subscription.js', 'utf8');
const subscriptionCalls = [];
const subscriptionApi = {
	subscription_get: async (...args) => {
		subscriptionCalls.push([ 'subscription_get', ...args ]);
		return { configured: true, url: 'https://example.test/sub' };
	},
	subscription_set: async (...args) => {
		subscriptionCalls.push([ 'subscription_set', ...args ]);
		return { operation_id: 'set-op' };
	},
	subscription_update: async (...args) => {
		subscriptionCalls.push([ 'subscription_update', ...args ]);
		return { operation_id: 'update-op' };
	},
	watchOperation(operationId, callback) {
		callback({ state: 'success', result: { interval_hours: 4 } });
		return () => {};
	},
	destroy() {}
};
const subscriptionModule = new Function(
	'L', 'view_miclash_api', 'URL', 'atob', subscriptionSource
)(
	{ Class: { extend: (value) => value } },
	{ create: () => subscriptionApi }, URL,
	(value) => Buffer.from(value, 'base64').toString('binary')
);
const applied = await subscriptionModule.applySubscriptionOnRouter({
	targetName: 'config.yaml'
});
assert.deepEqual(subscriptionCalls, [
	[ 'subscription_update', 'config.yaml', 'luci' ]
], 'subscription helper repeated URL reads or writes before the authoritative update operation');
assert.equal(applied.profileUpdateIntervalHours, '4');

console.log('MiClash UI performance quick wins contract passed');
