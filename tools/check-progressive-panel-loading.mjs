import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const settings = readFileSync('luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/settings-panels.js', 'utf8');
const devices = readFileSync('luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/devices-panel.js', 'utf8');
const config = readFileSync('luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/config.js', 'utf8');
const css = readFileSync('luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/style.css', 'utf8');
const application = readFileSync('luci-app-miclash/rootfs/usr/share/miclash/application.uc', 'utf8');

assert.doesNotMatch(settings, /Promise\.all\(\[ api\.settings_get\(\), api\.memoryStatus\(\), api\.telegram_status\(\) \]\)/,
	'Settings must not hold Memory and Telegram behind one combined RPC wait');
assert.match(settings, /let settingsReady = false, memoryReady = false, telegramStatusReady = false, telegramSettingsReady = false/,
	'Settings must track readiness of Memory and both independent Telegram responses');
assert.doesNotMatch(devices, /Promise\.all\(\[ api\.devicesList\(\), api\.devicePolicies\(\), api\.deviceTimezones\(\) \]\)/,
	'Devices must not hold the list behind timezone loading');
assert.match(devices, /let devicesReady = false, policiesReady = false, timezonesReady = false/,
	'Devices must track list, policies, and timezones independently');
assert.doesNotMatch(css, /#[0-9a-fA-F]{3,8}|rgba?\(/,
	'MiClash styles must derive colors only from LuCI theme variables');
assert.match(css, /--sbox-accent:\s*var\(--primary-color-high\)/,
	'Active controls must use the theme primary color');
assert.match(css, /--sbox-success:\s*var\(--success-color-high\)/,
	'Running service status must use the theme success color');
assert.match(css, /--sbox-danger:\s*var\(--error-color-high\)/,
	'Stopped service status must use the theme negative color');
assert.match(css, /--sbox-warn:\s*var\(--warn-color-high\)/,
	'Warnings must use the theme warning color');
assert.doesNotMatch(css, /--sbox-warning/,
	'Warning styles must use the declared --sbox-warn semantic token');
assert.match(css, /\.sbox-overview-card[\s\S]*color-mix\(in srgb, var\(--sbox-panel-soft\) 94%, var\(--sbox-text\) 6%\)/,
	'Overview cards must use the traffic-scope surface with a subtle theme-derived lift');
assert.match(config, /-ui4'/,
	'Changed UI assets must use a new cache revision so LuCI loads their current colors');
assert.match(application, /ctx\.stage\('service_' \+ action \+ '_dispatched', 45, ''\)/,
	'Service timelines must show when the lifecycle command has been dispatched');
assert.match(application, /ctx\.stage\('service_' \+ action \+ '_readiness', 70, ''\)/,
	'Service timelines must isolate readiness waiting from command dispatch');

const settingsRenderStart = config.indexOf('function renderSettingsPane()');
const settingsRenderEnd = config.indexOf('\nasync function collectSettingsFormState()', settingsRenderStart);
const settingsRender = config.slice(settingsRenderStart, settingsRenderEnd);
assert.doesNotMatch(settingsRender, /else managementOwner\.refresh\(\)/,
	'rerendering the mounted Settings pane must not issue another refresh');
assert.match(config, /async function warmBackgroundPanels\(generation, configHydration\)/,
	'background panels are not warmed through one staged path');
assert.match(config, /initialHydration\.finally\([\s\S]*warmBackgroundPanels\(generation, configHydration\)/,
	'background panels are not warmed promptly after the initial state');
const warmStart = config.indexOf('async function warmBackgroundPanels(generation, configHydration)');
const warmEnd = config.indexOf('\nfunction ', warmStart + 1);
const warmSource = config.slice(warmStart, warmEnd);
for (const call of [
	'managementOwner.refresh(true)', 'diagnosticsOwner.refresh(true)',
	'refreshLogs()', 'refreshReleaseMeta({ force: false })'
]) assert.match(warmSource, new RegExp(call.replace(/[().{}]/g, '\\$&')),
	`background warm-up is missing ${call}`);
assert.match(warmSource, /await configHydration;[\s\S]*refreshReleaseMeta\(\{ force: false \}\)/,
	'release check must wait for Config while other panels warm in parallel');

console.log('progressive panels, theme colors, and service timeline contracts passed');
