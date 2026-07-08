import { existsSync, readFileSync } from 'node:fs';

const files = {
	config: 'luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/config.js',
	settings: 'luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/settings-model.js',
	subscription: 'luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/subscription.js',
	serviceJob: 'luci-app-miclash/rootfs/opt/clash/bin/miclash-service',
	autoUpdateJob: 'luci-app-miclash/rootfs/opt/clash/bin/miclash-autoupdate',
	autoUpdateInit: 'luci-app-miclash/rootfs/etc/init.d/miclash-autoupdate',
	makefile: 'luci-app-miclash/Makefile',
	acl: 'luci-app-miclash/rootfs/usr/share/rpcd/acl.d/luci-app-miclash.json'
};

const config = readFileSync(files.config, 'utf8');
const settings = readFileSync(files.settings, 'utf8');
const subscription = readFileSync(files.subscription, 'utf8');
const serviceJob = readFileSync(files.serviceJob, 'utf8');
const makefile = readFileSync(files.makefile, 'utf8');
const acl = readFileSync(files.acl, 'utf8');
const autoUpdateJob = existsSync(files.autoUpdateJob) ? readFileSync(files.autoUpdateJob, 'utf8') : '';
const autoUpdateInit = existsSync(files.autoUpdateInit) ? readFileSync(files.autoUpdateInit, 'utf8') : '';

let failed = false;

function check(condition, message) {
	if (!condition) {
		console.error(message);
		failed = true;
	}
}

function blockBetween(startNeedle, endNeedle, source) {
	const start = source.indexOf(startNeedle);
	const end = source.indexOf(endNeedle, start + startNeedle.length);
	return start >= 0 && end > start ? source.slice(start, end) : '';
}

const reloadCase = blockBetween('\n\t\treload)', '\n\t\twait-ready|health)', serviceJob);
const setMainBlock = blockBetween('async function setSelectedConfigAsMain()', '\nfunction bindConfigEvents()', config);

check(serviceJob.includes('hot_reload_config()'),
	'miclash-service must implement a Mihomo hot reload helper.');
check(serviceJob.includes('/configs?force=true') &&
	serviceJob.includes('-X') &&
	serviceJob.includes('PUT') &&
	serviceJob.includes('Authorization: Bearer $secret') &&
	serviceJob.includes('body=') &&
	serviceJob.includes('"path"') &&
	serviceJob.includes('$CONFIG_FILE'),
	'miclash-service hot reload must call Mihomo PUT /configs?force=true with config path and optional bearer secret.');
check(reloadCase.includes('hot_reload_config') &&
	!reloadCase.includes('"$CLASH_INIT" reload'),
	'miclash-service reload action must use Mihomo hot reload instead of init.d reload.');
check(config.includes("reload: _('Reloading Mihomo configuration...')") &&
	config.includes("? _('Reloading Mihomo configuration...')"),
	'UI service status text must describe hot configuration reload for reload operations.');
check(config.includes('Configuration applied and Mihomo reloaded.') &&
	config.includes('Subscription downloaded and applied.') &&
	config.includes("restartOrReloadServiceOrThrow('reload'"),
	'Config save/update flows must keep using reload but report Mihomo hot reload to the user.');
check(setMainBlock.includes('const wasRunning = await getServiceStatus();') &&
	setMainBlock.includes('if (wasRunning)') &&
	setMainBlock.includes("await restartOrReloadServiceOrThrow('reload'") &&
	!setMainBlock.includes("restartOrReloadServiceOrThrow('restart'"),
	'Set as Main must hot reload only when MiClash was running and must not start/restart a stopped service.');

check(subscription.includes('TMP_SUBSCRIPTION_HEADERS_PATH') &&
	subscription.includes("'-D'") &&
	subscription.includes('readProfileUpdateIntervalHours') &&
	subscription.includes('Profile-Update-Interval') &&
	subscription.includes('return { content:') &&
	subscription.includes('profileUpdateIntervalHours:'),
	'Subscription downloads must capture response headers and expose Profile-Update-Interval hours with the content.');
check(!subscription.includes('SUPPORTED_PROFILE_UPDATE_INTERVAL_HOURS') &&
	subscription.includes('parseInt(match[1], 10)') &&
	subscription.includes('value > 0 ? String(value)'),
	'Subscription Profile-Update-Interval must accept provider-supplied positive hour values such as 3.');
check(config.includes('applySubscriptionProfileUpdateInterval') &&
	config.includes('appliedInfo.profileUpdateIntervalHours') &&
	config.includes('intervalInfo.profileUpdateIntervalHours'),
	'Config update/probe flows must persist a supported Profile-Update-Interval value from router-side subscription downloads.');
check(config.includes('AUTO_UPDATE_PRESET_INTERVAL_HOURS') &&
	config.includes("['2', '4', '12', '24']") &&
	config.includes('buildAutoUpdateIntervalChoicesHtml') &&
	config.includes('sbox-auto-update-choice') &&
	config.includes('name="sbox-auto-update-interval"') &&
	!config.includes('id="sbox-auto-update-interval" class="cbi-input-select'),
	'Settings pane must render auto-update hours as radio choices, not as a select.');
check(config.includes('AUTO_UPDATE_PRESET_INTERVAL_HOURS.includes(current)') &&
	config.includes('const values = preset ? AUTO_UPDATE_PRESET_INTERVAL_HOURS : [current];'),
	'Settings pane must show only the provider interval when it is not one of the default choices.');

check(settings.includes('autoUpdateConfig: true') &&
	settings.includes("autoUpdateIntervalHours: '4'") &&
	settings.includes('autoUpdateIntervalStored: false') &&
	settings.includes("case 'AUTO_UPDATE_CONFIG'") &&
	settings.includes("case 'AUTO_UPDATE_INTERVAL_HOURS'") &&
	settings.includes('settings.autoUpdateIntervalStored = true') &&
	settings.includes('settings.AUTO_UPDATE_CONFIG =') &&
	settings.includes('settings.AUTO_UPDATE_INTERVAL_HOURS ='),
	'Settings model must load, default, save, and expose whether auto-update interval was explicitly stored.');
check(config.includes('id="sbox-auto-update-config"') &&
	config.includes('id="sbox-auto-update-interval"') &&
	config.includes('Auto-update config') &&
	!config.includes("safeText(_('Every'))") &&
	!config.includes('sbox-auto-update-interval-label') &&
	config.includes("safeText(_('%s h').format(value))") &&
	config.includes('autoUpdateConfig') &&
	config.includes('autoUpdateIntervalHours'),
	'Settings pane must expose auto-update checkbox and interval choices without a redundant Every label.');
check(config.includes('async function probeAutoUpdateIntervalFromSubscription()') &&
	config.includes('readSubscriptionUrl(MAIN_CONFIG_NAME)') &&
	config.includes('probeSubscriptionUpdateIntervalOnRouter') &&
	config.includes('applySubscriptionProfileUpdateInterval(intervalInfo.profileUpdateIntervalHours)') &&
	!blockBetween('async function probeAutoUpdateIntervalFromSubscription()', 'async function testConfigContent', config).includes('downloadSubscriptionWithProfile') &&
	config.includes("setOperationStatus('running', _('Checking subscription update interval...'))"),
	'Settings pane must probe subscription Profile-Update-Interval through the router-side helper when enabling auto-update without a stored interval.');
check(config.includes('syncAutoUpdateInterval = async () =>') &&
	config.includes('autoUpdateConfigEl.checked && !(appState.settings && appState.settings.autoUpdateIntervalStored)') &&
	config.includes('await probeAutoUpdateIntervalFromSubscription();') &&
	config.includes('renderSettingsPane();'),
	'Auto-update checkbox must trigger interval probing only when enabling and no interval was stored yet.');

check(existsSync(files.autoUpdateJob),
	'Package must include /opt/clash/bin/miclash-autoupdate worker.');
check(autoUpdateJob.includes('AUTO_UPDATE_CONFIG') &&
	autoUpdateJob.includes('AUTO_UPDATE_INTERVAL_HOURS') &&
	autoUpdateJob.includes('PROXY_MODE') &&
	autoUpdateJob.includes('TUN_STACK') &&
	autoUpdateJob.includes('SUBSCRIPTION_URL') &&
	autoUpdateJob.includes('Profile-Update-Interval') &&
	autoUpdateJob.includes('apply_proxy_mode') &&
	autoUpdateJob.includes('tproxy-port: 7894') &&
	autoUpdateJob.includes('device: clash-tun') &&
	autoUpdateJob.includes('/opt/clash/bin/clash') &&
	autoUpdateJob.includes('-t') &&
	autoUpdateJob.includes('/opt/clash/bin/miclash-service') &&
	autoUpdateJob.includes('reload') &&
	autoUpdateJob.includes('is_service_running') &&
	autoUpdateJob.includes('sleep "$POLL_INTERVAL_SEC"'),
	'Auto-update worker must poll settings, download/validate Main config, and hot reload only when service is running.');
check(autoUpdateJob.includes('case "$hours" in') &&
	autoUpdateJob.includes('*[!0-9]*|0|"")') &&
	!autoUpdateJob.includes('2|4|12|24'),
	'Auto-update worker must accept provider-supplied positive hour values such as 3.');
check(existsSync(files.autoUpdateInit),
	'Package must include /etc/init.d/miclash-autoupdate procd service.');
check(autoUpdateInit.includes('USE_PROCD=1') &&
	autoUpdateInit.includes('procd_set_param command /opt/clash/bin/miclash-autoupdate run') &&
	autoUpdateInit.includes('procd_set_param respawn'),
	'Auto-update init script must run the worker under procd with respawn.');
check(makefile.includes('rootfs/opt/clash/bin/miclash-autoupdate') &&
	makefile.includes('rootfs/etc/init.d/miclash-autoupdate') &&
	makefile.includes('/etc/init.d/miclash-autoupdate enable') &&
	makefile.includes('/etc/init.d/miclash-autoupdate start') &&
	makefile.includes('/etc/init.d/miclash-autoupdate stop'),
	'Makefile must install, enable/start, and remove the auto-update service.');
check(!/CRON_LINE=.*miclash-autoupdate/.test(makefile),
	'Auto-update config must not be scheduled through cron.');
check(acl.includes('"/opt/clash/bin/miclash-autoupdate": [ "read", "stat", "exec" ]') &&
	acl.includes('"/opt/clash/bin/miclash-autoupdate": [ "exec" ]') &&
	acl.includes('"/etc/init.d/miclash-autoupdate": [ "exec" ]'),
	'ACL must allow LuCI to inspect and restart the auto-update service.');

if (failed) process.exit(1);
console.log('hot reload and auto-update check passed');
