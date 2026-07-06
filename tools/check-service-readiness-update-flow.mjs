import { existsSync, readFileSync } from 'node:fs';

const files = {
	config: 'luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/config.js',
	service: 'luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/service.js',
	serviceJob: 'luci-app-miclash/rootfs/opt/clash/bin/miclash-service',
	rules: 'luci-app-miclash/rootfs/opt/clash/bin/clash-rules',
	update: 'luci-app-miclash/rootfs/opt/clash/bin/miclash-update',
	style: 'luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/style.css',
	makefile: 'luci-app-miclash/Makefile'
};

const config = readFileSync(files.config, 'utf8');
const serviceJob = existsSync(files.serviceJob) ? readFileSync(files.serviceJob, 'utf8') : '';
const rules = readFileSync(files.rules, 'utf8');
const update = readFileSync(files.update, 'utf8');
const style = readFileSync(files.style, 'utf8');
const makefile = readFileSync(files.makefile, 'utf8');

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
check(config.includes('startMiClashServiceJob') && config.includes('pollMiClashServiceJob'),
	'Start/stop/restart UI must use detached service jobs and polling.');
check(config.includes('readMiClashServiceState') && config.includes("['state']"),
	'UI must read the combined router-side service state from miclash-service state.');
check(config.includes('refreshServiceState') && config.includes('appState.serviceHealth'),
	'UI controls must be refreshed from the combined service state.');
check(!config.includes("dispatchServiceActionsAndWaitOrThrow(['enable', 'start']"),
	'Start button must not dispatch service actions directly from LuCI.');
check(!config.includes("dispatchServiceActionsAndWaitOrThrow(['stop', 'disable']"),
	'Stop button must not dispatch service actions directly from LuCI.');
check(!config.includes('view_miclash_service.dispatchActionsAndWaitReadyOrThrow'),
	'UI must not keep the old JS readiness dispatch path after service jobs own readiness.');
check(config.includes('pollMiClashUpdateJob') && config.includes('startMiClashUpdateJob'),
	'Package/kernel updates must use detached update jobs and polling.');
check(config.includes('updateJobBusy: false') &&
	config.includes('appState.updateJobBusy = true') &&
	config.includes('appState.updateJobBusy = false'),
	'Update jobs must expose busy state to the service controls.');
check(config.includes('!!appState.updateJobBusy'),
	'Service controls must be disabled while update jobs can mutate the service.');
check(config.includes('clearOperationStatus();') && count(config, /clearOperationStatus\(\);/g) >= 3,
	'Successful service/update operations must clear stale operation errors.');
check(config.includes('checkServiceHealthOrThrow') &&
	config.includes('appState.serviceHealth !== \'ready\'') &&
	config.includes('readMiClashServiceState'),
	'Dashboard must verify router-side service health before opening.');

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

check(!config.includes('require view.miclash.service') &&
	!config.includes('view_miclash_service'),
	'UI must not keep the obsolete service.js module after miclash-service owns service state.');
check(!existsSync(files.service),
	'Obsolete service.js module must be removed after miclash-service owns service state.');

check(serviceJob.includes('STATUS_FILE="/tmp/miclash-service/status"'),
	'Service job script must write a persistent status file.');
check(serviceJob.includes('run_job()') && serviceJob.includes('write_status()'),
	'Service job script must support detached job status reporting.');
check(serviceJob.includes('wait_ready()') && serviceJob.includes('wait_stopped()'),
	'Service job script must wait for ready and stopped service states.');
check(serviceJob.includes('case "${1:-}" in') && serviceJob.includes('status)') && serviceJob.includes('clear-status)'),
	'Service job script must expose status and clear-status commands.');
check(serviceJob.includes('print_state()') &&
	serviceJob.includes('printf \'operation=%s\\n\'') &&
	serviceJob.includes('printf \'service=%s\\n\'') &&
	serviceJob.includes('printf \'health=%s\\n\''),
	'Service job script must expose a combined service state command.');
check(serviceJob.includes('state)'),
	'Service job script must expose a state command.');
check(makefile.includes('rootfs/opt/clash/bin/miclash-service'),
	'Package install must include the service job script.');

check(rules.includes('health_service_process') &&
	rules.includes('health_clash_api') &&
	rules.includes('health_dns_listener') &&
	rules.includes('health_tun_interface') &&
	rules.includes('health_check()'),
	'clash-rules must expose a staged health check for service readiness.');
check(rules.includes('health)'),
	'clash-rules must expose a health command.');

check(update.includes('STATUS_FILE="/tmp/miclash-update/status"'),
	'Update script must write a persistent status file.');
check(update.includes('write_status()') && update.includes('run_job()'),
	'Update script must support detached job status reporting.');
check(update.includes('case "${1:-}" in') && update.includes('status)') && update.includes('clear-status)'),
	'Update script must expose status and clear-status commands.');

if (failed) process.exit(1);
console.log('service readiness and update flow check passed');
