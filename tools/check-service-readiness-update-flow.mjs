import { existsSync, readFileSync } from 'node:fs';

const files = {
	config: 'luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/config.js',
	service: 'luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/service.js',
	serviceJob: 'luci-app-miclash/rootfs/opt/clash/bin/miclash-service',
	rules: 'luci-app-miclash/rootfs/opt/clash/bin/clash-rules',
	update: 'luci-app-miclash/rootfs/opt/clash/bin/miclash-update',
	release: 'luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/release.js',
	acl: 'luci-app-miclash/rootfs/usr/share/rpcd/acl.d/luci-app-miclash.json',
	style: 'luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/style.css',
	makefile: 'luci-app-miclash/Makefile',
	clashInit: 'luci-app-miclash/rootfs/etc/init.d/clash',
	autoUpdateInit: 'luci-app-miclash/rootfs/etc/init.d/miclash-autoupdate'
};

const config = readFileSync(files.config, 'utf8');
const serviceJob = existsSync(files.serviceJob) ? readFileSync(files.serviceJob, 'utf8') : '';
const rules = readFileSync(files.rules, 'utf8');
const update = readFileSync(files.update, 'utf8');
const release = readFileSync(files.release, 'utf8');
const acl = readFileSync(files.acl, 'utf8');
const style = readFileSync(files.style, 'utf8');
const makefile = readFileSync(files.makefile, 'utf8');
const clashInit = readFileSync(files.clashInit, 'utf8');
const autoUpdateInit = readFileSync(files.autoUpdateInit, 'utf8');

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

function blockBetween(startNeedle, endNeedle, source = config) {
	const start = source.indexOf(startNeedle);
	const end = source.indexOf(endNeedle, start + startNeedle.length);
	return start >= 0 && end > start ? source.slice(start, end) : '';
}

check(config.includes('operationStatus: null'),
	'UI state must keep a persistent operationStatus value.');
check(config.includes('id="sbox-operation-status"'),
	'Control row must render the operation status line next to service buttons.');
check(config.includes('function setOperationStatus(') && config.includes('function clearOperationStatus('),
	'UI must expose operation status set/clear helpers.');
check(config.includes('detail:') &&
	config.includes('dismissible: false') &&
	config.includes('autoClearMs == null ? 3000') &&
	!config.includes('sbox-operation-status-detail') &&
	!config.includes('sbox-operation-status-close'),
	'UI must keep operation error details internally while showing a passive 3-second error bar.');
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
const installMiClashUiBlock = blockBetween(
	'async function installMiClashFromSettings(',
	'async function downloadMihomoKernel('
);
check(installMiClashUiBlock.includes("['--target-tag', release.version, '--mode', mode]"),
	'MiClash app updates must pass the target release tag to miclash-update.');
check(!installMiClashUiBlock.includes('asset.browser_download_url') &&
	!installMiClashUiBlock.includes('findMiClashAsset('),
	'MiClash app updates must not pass a package asset URL from LuCI.');
check(config.includes('createOperationToken(') &&
	config.includes('getStoredOperationToken(') &&
	config.includes('clearStoredOperationToken(') &&
	config.includes('isCurrentOperationToken('),
	'UI must track operation tokens in sessionStorage.');
check(config.includes("['job', '--token', token, kind]") &&
	config.includes("['job', '--token', token, action]"),
	'UI must pass operation tokens to update and service jobs.');
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
const resumeUpdateBlock = blockBetween(
	'async function resumeMiClashUpdateJobStatus()',
	'async function resumeMiClashServiceJobStatus()'
);
const resumeServiceBlock = blockBetween(
	'async function resumeMiClashServiceJobStatus()',
	'async function installMiClashFromSettings('
);
const startAction = blockBetween('\n\t\tstart)', '\n\t\tstop)', serviceJob);
const kernelCheck = startAction.indexOf('require_kernel');
check(
	updateStatusBlock.indexOf('if (translated) return translated;') >= 0 &&
		updateStatusBlock.indexOf('const message =') > updateStatusBlock.indexOf('if (translated) return translated;'),
	'Update status UI must prefer translated phase labels before raw job messages.'
);
check(resumeUpdateBlock.includes("if (state === 'running')") &&
	resumeUpdateBlock.includes('pollMiClashUpdateJob'),
	'Update status resume must continue actively running update jobs.');
check(resumeUpdateBlock.includes("if (state === 'failed' && isCurrentOperationToken('update', status))") &&
	resumeUpdateBlock.includes("setOperationError(new Error(status.message || _('Update failed.')))"),
	'Update status resume must show failed status only when its token matches the current tab operation.');
check(!resumeUpdateBlock.includes("if (state === 'failed')") &&
	!resumeUpdateBlock.includes("if (state === 'failed') {\n\t\tsetOperationError(new Error(status.message || _('Update failed.')))"),
	'Update status resume must not resurrect stale failed update errors from /tmp.');
check(resumeUpdateBlock.includes("if (state === 'failed' || state === 'success')") &&
	resumeUpdateBlock.includes('await clearMiClashUpdateStatus();'),
	'Update status resume must clear completed failed/success update status files.');
check(resumeServiceBlock.includes("if (state === 'running')") &&
	resumeServiceBlock.includes('pollMiClashServiceJob'),
	'Service status resume must continue actively running service jobs.');
check(resumeServiceBlock.includes("if (state === 'failed' && isCurrentOperationToken('service', status))") &&
	resumeServiceBlock.includes("setOperationError(new Error(status.message || _('Service operation failed.')))"),
	'Service status resume must show failed status only when its token matches the current tab operation.');
check(!resumeServiceBlock.includes("if (state === 'failed')") &&
	!resumeServiceBlock.includes("if (state === 'failed') {\n\t\tsetOperationError(new Error(status.message || _('Service operation failed.')))"),
	'Service status resume must not resurrect stale failed service errors from /tmp.');
check(resumeServiceBlock.includes("if (state === 'failed' || state === 'success')") &&
	resumeServiceBlock.includes('await clearMiClashServiceStatus();') &&
	resumeServiceBlock.includes('clearOperationStatus();'),
	'Service status resume must clear completed failed/success service status files.');
check(kernelCheck >= 0 &&
	kernelCheck < startAction.indexOf('"$CLASH_INIT" enable') &&
	kernelCheck < startAction.indexOf('"$CLASH_INIT" start'),
	'Service start must reject a missing kernel before changing enable or process state.');
check(serviceJob.includes('require_kernel()') &&
	serviceJob.includes('[ -x "$CLASH_BIN" ] || fail "Install the Mihomo kernel first."'),
	'Service kernel preflight must return the actionable missing-kernel error.');
check(config.includes('Install the Mihomo kernel first.'),
	'UI must show the actionable missing-kernel instruction.');
check(!config.includes('Subscription downloaded and applied (Remnawave /mihomo fallback).'),
	'UI must not expose the internal Remnawave fallback in successful subscription copy.');

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
check(serviceJob.includes('CURRENT_TOKEN=') &&
	serviceJob.includes("printf 'token=%s\\n'") &&
	serviceJob.includes('token="$(status_value token)"') &&
	serviceJob.includes("printf 'token=%s\\n' \"$token\""),
	'Service job script must persist operation tokens and expose them from state.');
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
check(makefile.includes('rm -rf /tmp/luci-indexcache* /tmp/luci-modulecache*') &&
	!makefile.includes('rm -rf /tmp/luci-indexcache /tmp/luci-modulecache') &&
	!makefile.includes('rm -f /tmp/luci-*'),
	'Package postinst must clear only LuCI index/module cache patterns after install.');
check(acl.includes('"/opt/clash/bin/miclash-service": [ "read", "stat", "exec" ]'),
	'ACL read permissions must allow LuCI to inspect and execute miclash-service.');
check(acl.includes('"/opt/clash/bin/miclash-service": [ "exec" ]'),
	'ACL write permissions must allow LuCI to start miclash-service jobs.');

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
check(update.includes('CURRENT_TOKEN=') &&
	update.includes("printf 'token=%s\\n'") &&
	update.includes('parse_job_token "$@"'),
	'Update script must persist operation tokens in job status.');
check(update.includes('write_status()') && update.includes('run_job()'),
	'Update script must support detached job status reporting.');
check(update.includes('case "${1:-}" in') && update.includes('status)') && update.includes('clear-status)'),
	'Update script must expose status and clear-status commands.');
check(release.includes("'require fs';") &&
	release.includes("fs.exec('/opt/clash/bin/miclash-update'") &&
	release.includes("['release', kind, channel]") &&
	!release.includes('await fetch('),
	'Release metadata must be fetched by the router through miclash-update, not by the browser.');
check(update.includes('print_release_info()') &&
	update.includes('MICLASH_RELEASE_API=') &&
	update.includes('MIHOMO_RELEASE_API=') &&
	update.includes('uclient-fetch') &&
	update.includes('release)'),
	'miclash-update must expose router-side release metadata fetching with a uclient-fetch fallback.');

const installAppStart = update.indexOf('\ninstall_app()');
const installKernelStart = update.indexOf('\ninstall_kernel()');
const dispatchStart = update.indexOf('\ncase "${1:-}" in');
const installAppBlock = installAppStart >= 0 && installKernelStart > installAppStart
	? update.slice(installAppStart, installKernelStart)
	: '';
const installKernelBlock = installKernelStart >= 0 && dispatchStart > installKernelStart
	? update.slice(installKernelStart, dispatchStart)
	: '';
check(installAppBlock.includes('--target-tag') &&
	installAppBlock.includes('resolve_miclash_asset') &&
	installAppBlock.includes('Installing MiClash package') &&
	!installAppBlock.includes('install-miclash.sh') &&
	!installAppBlock.includes('missing --url'),
	'miclash-update app mode must resolve and install the release package directly.');

const postinstBlock = blockBetween(
	'define Package/$(PKG_NAME)/postinst',
	'endef',
	makefile
);
const prermBlock = blockBetween(
	'define Package/$(PKG_NAME)/prerm',
	'endef',
	makefile
);
const postrmBlock = blockBetween(
	'define Package/$(PKG_NAME)/postrm',
	'endef',
	makefile
);
check(!prermBlock.includes('/etc/init.d/clash stop'),
	'Package prerm must let default_prerm stop Clash exactly once.');
check(!postinstBlock.includes('/etc/init.d/miclash-autoupdate start'),
	'Package postinst must not start auto-update before default_postinst.');
check(clashInit.includes('/tmp/miclash-package-no-autostart-clash'),
	'Clash init must consume its package no-autostart marker.');
check(autoUpdateInit.includes('/tmp/miclash-package-no-autostart-autoupdate'),
	'Auto-update init must consume its package no-autostart marker.');
check(postrmBlock.includes('/tmp/miclash-hard-reinstall'),
	'Package postrm must remove the kernel only for explicit hard reinstall or full removal.');
check(!update.includes('cleanup_legacy_output_guard') &&
	!update.includes('MICLASH_GUARD_OUTPUT'),
	'Update script must not own legacy guard cleanup; clash-rules owns firewall cleanup.');
check(rules.includes('MICLASH_GUARD_OUTPUT') &&
	rules.includes('remove_iptables_legacy_output_guard_rules'),
	'clash-rules must keep the legacy OUTPUT guard migration cleanup.');

if (failed) process.exit(1);
console.log('service readiness and update flow check passed');
