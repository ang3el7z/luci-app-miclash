import { readFileSync } from 'node:fs';

const configPath = 'luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/config.js';
const source = readFileSync(configPath, 'utf8');

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

check(/async function withRestartButtonFeedback\(fn\)/.test(source),
	'Missing withRestartButtonFeedback(fn) helper.');
check(settingsSaveBlock.includes('await withRestartButtonFeedback(async () => {'),
	'Settings save restart must show the same service feedback as the Restart button.');
check(/await restartOrReloadServiceOrThrow\('restart'(?:,|\))/.test(settingsSaveBlock),
	'Settings save must still restart the Clash service.');
check(restartButtonBlock.includes('withRestartButtonFeedback(async () => {'),
	'The Restart button must use the shared restart feedback helper.');
check(!restartButtonBlock.includes('withButtons(restartBtn'),
	'The Restart button should not bypass service restart feedback.');

if (failed) process.exit(1);
console.log('settings restart feedback check passed');
