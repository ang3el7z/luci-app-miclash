'use strict';
'require view.miclash.utils';
'require view.miclash.logs';

const SERVICE_ACTION_SETTLE_MS = 300;
const DIAGNOSTIC_LOG_LINES = 12;

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
		timeoutMs || view_miclash_utils.SERVICE_POLL_TIMEOUT_MS
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

function formatActionList(actions) {
	return (Array.isArray(actions) ? actions : [actions]).filter(Boolean).join(', ');
}

async function readDiagnostics() {
	const raw = await view_miclash_logs.readRaw();
	return String(raw || '')
		.split(/\r?\n/)
		.map((line) => line.trim())
		.filter(Boolean)
		.slice(-DIAGNOSTIC_LOG_LINES)
		.join('\n');
}

async function describeTimeout(actions, targetStatus) {
	const actionText = formatActionList(actions) || 'service action';
	let message = targetStatus
		? _('Service did not enter running state in time after: %s').format(actionText)
		: _('Service did not stop in time after: %s').format(actionText);

	const logs = await readDiagnostics();
	if (logs) message += '\n\n' + logs;
	return message;
}

async function dispatchActionsAndWaitOrThrow(actions, targetStatus, timeoutMs) {
	const ok = await dispatchActionsAndWait(actions, targetStatus, timeoutMs);
	if (ok) return true;
	throw new Error(await describeTimeout(actions, !!targetStatus));
}

async function restartOrReloadOrThrow(action) {
	return dispatchActionsAndWaitOrThrow([action], true);
}

return L.Class.extend({
	getStatus: getStatus,
	waitForStatus: waitForStatus,
	dispatchActions: dispatchActions,
	dispatchActionsAndWait: dispatchActionsAndWait,
	dispatchActionsAndWaitOrThrow: dispatchActionsAndWaitOrThrow,
	restartOrReload: restartOrReload,
	restartOrReloadOrThrow: restartOrReloadOrThrow,
	describeTimeout: describeTimeout
});
