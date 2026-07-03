'use strict';
'require view.miclash.utils';

const SERVICE_ACTION_TIMEOUT_MS = 10000;
const SERVICE_ACTION_SETTLE_MS = 300;

function delay(ms) {
	return new Promise((resolve) => setTimeout(resolve, ms));
}

async function getStatus() {
	return view_miclash_utils.getClashRunning();
}

async function waitForStatus(targetStatus, timeoutMs) {
	return view_miclash_utils.waitForServiceStatus(
		getStatus,
		!!targetStatus,
		timeoutMs || SERVICE_ACTION_TIMEOUT_MS
	);
}

async function dispatchActions(actions) {
	const script = (Array.isArray(actions) ? actions : [actions])
		.filter((action) => !!action)
		.map((action) => '/etc/init.d/clash ' + action)
		.join('; ');
	return view_miclash_utils.execDetached(script);
}

async function dispatchActionsAndWait(actions, targetStatus, timeoutMs) {
	await dispatchActions(actions);
	await delay(SERVICE_ACTION_SETTLE_MS);
	return waitForStatus(!!targetStatus, timeoutMs);
}

async function restartOrReload(action) {
	return dispatchActionsAndWait([action], true);
}

return L.Class.extend({
	getStatus: getStatus,
	waitForStatus: waitForStatus,
	dispatchActions: dispatchActions,
	dispatchActionsAndWait: dispatchActionsAndWait,
	restartOrReload: restartOrReload
});
