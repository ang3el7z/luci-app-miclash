import { readFileSync } from 'node:fs';

const files = {
	config: 'luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/config.js',
	service: 'luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/service.js',
	update: 'luci-app-miclash/rootfs/opt/clash/bin/miclash-update',
	style: 'luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/style.css'
};

const config = readFileSync(files.config, 'utf8');
const service = readFileSync(files.service, 'utf8');
const update = readFileSync(files.update, 'utf8');
const style = readFileSync(files.style, 'utf8');

let failed = false;

function check(condition, message) {
	if (!condition) {
		console.error(message);
		failed = true;
	}
}

function count(text, pattern) {
	const matches = text.match(pattern);
	return matches ? matches.length : 0;
}

check(config.includes('operationStatus: null'),
	'UI state must keep a persistent operationStatus value.');
check(config.includes('id="sbox-operation-status"'),
	'Control row must render the operation status line next to service buttons.');
check(config.includes('function setOperationStatus(') && config.includes('function clearOperationStatus('),
	'UI must expose operation status set/clear helpers.');
check(config.includes('function getOperationRecommendation('),
	'UI must map failures to actionable recommendations.');
check(config.includes('view_miclash_service.dispatchActionsAndWaitReadyOrThrow'),
	'Start/stop/restart UI must use readiness-aware service actions.');
check(config.includes('pollMiClashUpdateJob') && config.includes('startMiClashUpdateJob'),
	'Package/kernel updates must use detached update jobs and polling.');
check(config.includes('clearOperationStatus();') && count(config, /clearOperationStatus\(\);/g) >= 3,
	'Successful service/update operations must clear stale operation errors.');

const updateStatusStart = config.indexOf('function formatMiClashUpdateStatus');
const updateStatusEnd = config.indexOf('async function clearMiClashUpdateStatus', updateStatusStart);
const updateStatusBlock = updateStatusStart >= 0 && updateStatusEnd > updateStatusStart
	? config.slice(updateStatusStart, updateStatusEnd)
	: '';
check(
	updateStatusBlock.indexOf('if (translated) return translated;') >= 0 &&
		updateStatusBlock.indexOf('const message =') > updateStatusBlock.indexOf('if (translated) return translated;'),
	'Update status UI must prefer translated phase labels before raw job messages.'
);

check(style.includes('.sbox-operation-status') &&
	style.includes('.sbox-operation-status-error') &&
	style.includes('.sbox-operation-status-running'),
	'CSS must style running and error operation status states.');

check(service.includes('async function waitForReadyStatus') &&
	service.includes('async function waitForClashApi') &&
	service.includes('async function waitForDnsReady') &&
	service.includes('async function waitForTunReady') &&
	service.includes('async function waitForPolicyReady'),
	'Service module must wait for process, Clash API, DNS, TUN, and routing readiness.');
check(service.includes('dispatchActionsAndWaitReadyOrThrow'),
	'Service module must export readiness-aware dispatch helper.');
check(service.includes('onStage') && service.includes('stageMessage'),
	'Readiness wait must report stage messages to the UI.');

check(update.includes('STATUS_FILE="/tmp/miclash-update/status"'),
	'Update script must write a persistent status file.');
check(update.includes('write_status()') && update.includes('run_job()'),
	'Update script must support detached job status reporting.');
check(update.includes('case "${1:-}" in') && update.includes('status)') && update.includes('clear-status)'),
	'Update script must expose status and clear-status commands.');

if (failed) process.exit(1);
console.log('service readiness and update flow check passed');
