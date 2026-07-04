'use strict';
'require view.miclash.utils';
'require view.miclash.logs';

const SERVICE_ACTION_SETTLE_MS = 300;
const DIAGNOSTIC_LOG_LINES = 12;
const START_SERVICE_TIMEOUT_MS = 180000;
const STOP_SERVICE_TIMEOUT_MS = 60000;
const RESTART_SERVICE_TIMEOUT_MS = 180000;

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
	return dispatchActionsAndWait([action], true, RESTART_SERVICE_TIMEOUT_MS);
}

function formatActionList(actions) {
	return (Array.isArray(actions) ? actions : [actions]).filter(Boolean).join(', ');
}

function getActionTimeout(actions, targetStatus, timeoutMs) {
	if (timeoutMs) return timeoutMs;
	if (!targetStatus) return STOP_SERVICE_TIMEOUT_MS;
	const list = (Array.isArray(actions) ? actions : [actions]).filter(Boolean);
	if (list.some((action) => /^(restart|reload)$/.test(action))) {
		return RESTART_SERVICE_TIMEOUT_MS;
	}
	return START_SERVICE_TIMEOUT_MS;
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

async function describeTimeout(actions, targetStatus, timeoutMs) {
	const actionText = formatActionList(actions) || 'service action';
	const timeoutSec = Math.round(getActionTimeout(actions, targetStatus, timeoutMs) / 1000);
	let message = targetStatus
		? _('Service did not enter running state within %ss after: %s').format(timeoutSec, actionText)
		: _('Service did not stop within %ss after: %s').format(timeoutSec, actionText);

	const logs = await readDiagnostics();
	if (logs) message += '\n\n' + logs;
	return message;
}

async function dispatchActionsAndWaitOrThrow(actions, targetStatus, timeoutMs) {
	const effectiveTimeout = getActionTimeout(actions, !!targetStatus, timeoutMs);
	const ok = await dispatchActionsAndWait(actions, targetStatus, effectiveTimeout);
	if (ok) return true;
	throw new Error(await describeTimeout(actions, !!targetStatus, effectiveTimeout));
}

async function restartOrReloadOrThrow(action) {
	return dispatchActionsAndWaitOrThrow([action], true, RESTART_SERVICE_TIMEOUT_MS);
}

return L.Class.extend({
	getStatus: getStatus,
	waitForStatus: waitForStatus,
	dispatchActions: dispatchActions,
	dispatchActionsAndWait: dispatchActionsAndWait,
	dispatchActionsAndWaitOrThrow: dispatchActionsAndWaitOrThrow,
	restartOrReload: restartOrReload,
	restartOrReloadOrThrow: restartOrReloadOrThrow,
	describeTimeout: describeTimeout,
	START_SERVICE_TIMEOUT_MS: START_SERVICE_TIMEOUT_MS,
	STOP_SERVICE_TIMEOUT_MS: STOP_SERVICE_TIMEOUT_MS,
	RESTART_SERVICE_TIMEOUT_MS: RESTART_SERVICE_TIMEOUT_MS
});
