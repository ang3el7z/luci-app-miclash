import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const installer = readFileSync('install-miclash.sh', 'utf8');
const config = readFileSync(
	'luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/config.js', 'utf8');
const api = readFileSync(
	'luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/api.js', 'utf8');

const classifierStart = config.indexOf('function isRpcReconnectLikeError(');
const classifierEnd = config.indexOf('\nasync function clearMiClashUpdateStatus', classifierStart);
assert.ok(classifierStart >= 0 && classifierEnd > classifierStart,
	'missing RPC reconnect classifier');
const helperSource = config.slice(classifierStart, classifierEnd);
const helpers = new Function(
	`${helperSource}; return { isRpcReconnectLikeError, waitForMiClashBackendRestart };`)();
const { isRpcReconnectLikeError, waitForMiClashBackendRestart } = helpers;

assert.equal(isRpcReconnectLikeError({
	code: 'RPC_ERROR',
	message: 'RPC call to miclash/operation_get failed with ubus code 7: Тайм-аут запроса'
}), true, 'localized ubus timeout during self-update must be treated as a reconnect');
assert.equal(isRpcReconnectLikeError(new Error('Request timed out')), true);
assert.equal(isRpcReconnectLikeError({ code: 'HEALTH_FAILED', message: 'Health check failed' }), false,
	'a real update health failure must remain visible');

const restartWaitStart = config.indexOf('async function waitForMiClashBackendRestart(');
const restartWaitEnd = config.indexOf('\nasync function clearMiClashUpdateStatus', restartWaitStart);
assert.ok(restartWaitStart >= 0 && restartWaitEnd > restartWaitStart,
	'missing event-driven backend restart wait');
let now = 0, calls = 0;
const restarted = await waitForMiClashBackendRestart({
	system_info: async () => {
		calls++;
		if (calls < 3) throw new Error('RPC failed with ubus code 4: Ресурс не найден');
		return { app_version: '2.2.4' };
	}
}, { timeoutMs: 1000, intervalMs: 10, now: () => now,
	sleep: async (delay) => { now += delay; } });
assert.equal(restarted, true);
assert.equal(calls, 3, 'reload waits until the restarted backend answers again');

const installStart = config.indexOf('async function installMiClashFromSettings(');
const installEnd = config.indexOf('\nasync function downloadMihomoKernel', installStart);
const installSource = config.slice(installStart, installEnd);
assert.match(installSource, /suspendForBackendRestart\(\)/,
	'background panels must stop before the expected ubus outage');
assert.match(installSource, /await waitForCurrentMiClashBackendRestart\(\)/,
	'the page must reload only after the replacement backend is reachable');
assert.doesNotMatch(installSource, /setTimeout\([^]*window\.location\.reload/,
	'self-update reload must not race the backend on a fixed timer');
assert.match(api, /function isTransientBackendUnavailable\(/,
	'newly loaded panels must recognize the expected ubus restart outage');
assert.match(api, /spec\.access === 'read'[^]*isTransientBackendUnavailable/,
	'only safe read calls may retry during page startup');
assert.match(api, /startupRetryMs[^]*timerSet/,
	'initial reads must retry for a bounded startup window');

const reloadStart = installer.indexOf('schedule_backend_reload()');
const reloadEnd = installer.indexOf('\nrun_app_mode()', reloadStart);
assert.ok(reloadStart >= 0 && reloadEnd > reloadStart, 'missing backend reload scheduler');
const reloadSource = installer.slice(reloadStart, reloadEnd);
assert.match(reloadSource, /while[^\n]*STATUS_FILE[^\n]*-e/,
	'backend reload must wait while the authenticated handoff is owned by the update operation');
assert.match(reloadSource, /MAX_BACKEND_RELOAD_WAIT/,
	'backend reload wait must remain bounded');

console.log('self-update reconnect contract passed');
