import { readFileSync } from 'node:fs';

const configPath = 'luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/config.js';
const settingsModelPath = 'luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/settings-model.js';
const makefilePath = 'luci-app-miclash/Makefile';
const source = readFileSync(configPath, 'utf8');
const settingsModel = readFileSync(settingsModelPath, 'utf8');
const makefile = readFileSync(makefilePath, 'utf8');

let failed = false;

function check(condition, message) {
	if (!condition) {
		console.error(message);
		failed = true;
	}
}

const settingsSaveStart = source.indexOf("const saveBtn = pane.querySelector('#sbox-settings-save');");
const settingsSaveEnd = source.indexOf('const releaseChannelChanged', settingsSaveStart);
const settingsSaveBlock = settingsSaveStart >= 0 && settingsSaveEnd > settingsSaveStart
	? source.slice(settingsSaveStart, settingsSaveEnd)
	: '';

const controlEventsStart = source.indexOf('function bindControlAndHeaderEvents()');
const restartButtonStart = source.indexOf("const restartBtn = pageRoot.querySelector('#sbox-restart');", controlEventsStart);
const restartButtonEnd = source.indexOf('const dashboardBtn', restartButtonStart);
const restartButtonBlock = restartButtonStart >= 0 && restartButtonEnd > restartButtonStart
	? source.slice(restartButtonStart, restartButtonEnd)
	: '';
const proxyModeStart = source.indexOf('async function switchProxyModeFromHeader(targetMode)');
const proxyModeEnd = source.indexOf('async function loadClashLogs()', proxyModeStart);
const proxyModeBlock = proxyModeStart >= 0 && proxyModeEnd > proxyModeStart
	? source.slice(proxyModeStart, proxyModeEnd)
	: '';

check(/async function withRestartButtonFeedback\(fn\)/.test(source),
	'Missing withRestartButtonFeedback(fn) helper.');
check(settingsSaveBlock.includes('await withRestartButtonFeedback(async () => {'),
	'Settings save restart must show the same service feedback as the Restart button.');
check(settingsSaveBlock.includes('const wasRunning = await getServiceStatus();'),
	'Settings save must check whether MiClash is running before restart.');
check(settingsSaveBlock.includes('if (wasRunning)') &&
	settingsSaveBlock.includes("await restartOrReloadServiceOrThrow('restart'"),
	'Settings save must restart only when MiClash was already running.');
check(/await restartOrReloadServiceOrThrow\('restart'(?:,|\))/.test(settingsSaveBlock),
	'Settings save must still restart the Clash service.');
check(source.includes('configApi.guard_transition') && source.includes('awaitTypedOperation'),
	'Settings save must use and await the typed Guard transition backend.');
check(!source.includes("fs.exec('/opt/clash/bin/clash-rules', ['guard_refresh'])"),
	'Main LuCI settings must not execute the Guard backend directly.');
check(!settingsModel.includes("case 'INTERNET_ONLY_MICLASH'") &&
	!settingsModel.includes('settings.INTERNET_ONLY_MICLASH ='),
	'Operational settings model must not read or write the legacy Guard key.');
check(source.includes('settings_get') && source.includes('typed.guard') &&
	source.includes('internetOnlyMiclash'),
	'Main LuCI settings must display canonical typed Guard state.');
check(proxyModeBlock.includes('const wasRunning = await getServiceStatus();'),
	'Proxy mode switch must check whether MiClash is running before restart.');
check(proxyModeBlock.includes('if (wasRunning)') &&
	proxyModeBlock.includes("await restartOrReloadServiceOrThrow('restart'"),
	'Proxy mode switch must restart only when MiClash was already running.');
check(restartButtonBlock.includes('withRestartButtonFeedback(async () => {'),
	'The Restart button must use the shared restart feedback helper.');
check(!restartButtonBlock.includes('withButtons(restartBtn'),
	'The Restart button should not bypass service restart feedback.');
check(settingsModel.includes('api.operational_settings_apply(') &&
	!settingsModel.includes('api.config_save_draft(') &&
	!settingsModel.includes("'require fs'"),
	'Operational settings and generated config must use one typed transaction.');
check(makefile.includes('/usr/libexec/miclash/migrate.uc prepare') &&
	makefile.includes('/usr/libexec/miclash/migrate.uc verify') &&
	!makefile.includes('.settings.upgrade.bak'),
	'Package upgrades must use the journaled canonical migration.');

if (failed) process.exit(1);
console.log('settings restart feedback check passed');
