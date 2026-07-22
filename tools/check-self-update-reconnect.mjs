import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const installer = readFileSync('install-miclash.sh', 'utf8');
const config = readFileSync(
	'luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/config.js', 'utf8');

const classifierStart = config.indexOf('function isRpcReconnectLikeError(');
const classifierEnd = config.indexOf('\nasync function clearMiClashUpdateStatus', classifierStart);
assert.ok(classifierStart >= 0 && classifierEnd > classifierStart,
	'missing RPC reconnect classifier');
const classifierSource = config.slice(classifierStart, classifierEnd);
const isRpcReconnectLikeError = new Function(`${classifierSource}; return isRpcReconnectLikeError;`)();

assert.equal(isRpcReconnectLikeError({
	code: 'RPC_ERROR',
	message: 'RPC call to miclash/operation_get failed with ubus code 7: Тайм-аут запроса'
}), true, 'localized ubus timeout during self-update must be treated as a reconnect');
assert.equal(isRpcReconnectLikeError(new Error('Request timed out')), true);
assert.equal(isRpcReconnectLikeError({ code: 'HEALTH_FAILED', message: 'Health check failed' }), false,
	'a real update health failure must remain visible');

const reloadStart = installer.indexOf('schedule_backend_reload()');
const reloadEnd = installer.indexOf('\nrun_app_mode()', reloadStart);
assert.ok(reloadStart >= 0 && reloadEnd > reloadStart, 'missing backend reload scheduler');
const reloadSource = installer.slice(reloadStart, reloadEnd);
assert.match(reloadSource, /while[^\n]*STATUS_FILE[^\n]*-e/,
	'backend reload must wait while the authenticated handoff is owned by the update operation');
assert.match(reloadSource, /MAX_BACKEND_RELOAD_WAIT/,
	'backend reload wait must remain bounded');

console.log('self-update reconnect contract passed');
