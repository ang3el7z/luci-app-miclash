import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const config = readFileSync('luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/config.js', 'utf8');
const model = readFileSync('luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/settings-model.js', 'utf8');

const start = config.indexOf('async function saveAllSettings(');
const end = config.indexOf('function bindSettingsPaneEvents()', start);
assert.ok(start >= 0 && end > start, 'unified settings save flow is missing');
const save = config.slice(start, end);
const managementStart = config.indexOf('const managementOwner =');
const managementEnd = config.indexOf('view_miclash_utils.bumpRpcTimeout()', managementStart);
const management = config.slice(managementStart, managementEnd);

assert.match(save, /managementOwner\.collectPatch\(\)/,
	'unified save does not collect Memory, Telegram, and notification settings');
assert.match(save, /operationalSettingsChanged\(/,
	'unified save does not classify service-affecting changes');
assert.match(save, /configApi\.settings_set\(/,
	'passive settings are not persisted through typed settings_set');
assert.match(save, /if \(runtimeChanged\)[\s\S]*saveOperationalSettings\(/,
	'operational apply is not conditional');
assert.doesNotMatch(save, /restartOrReloadServiceOrThrow\(['"]restart/,
	'unified settings save still forces an unconditional full restart');
assert.match(save, /guard_transition/,
	'Guard transition is not handled independently');
assert.match(management, /async function applyPending\(\)[\s\S]*panels\[1\]\.applyChanges\(\)/,
	'management owner must expose pending device policy application');
assert.match(save, /await managementOwner\.applyPending\(\)[\s\S]*await managementOwner\.markSaved\(\)/,
	'device policy drafts must apply before unified settings completion');
assert.match(config, /_\('Apply Settings'\)/,
	'the page-level action must describe applying all staged changes');
assert.doesNotMatch(config, /_\('Save Settings'\)/,
	'the obsolete page-level action label must be removed');

assert.match(model, /function operationalSettingsChanged\(/,
	'service-impact classifier is missing');
assert.match(model, /api\.operational_settings_apply\(/,
	'service-affecting changes do not use the atomic operational transaction');
const settingsObject = model.slice(model.indexOf('const settings = {'), model.indexOf('await waitOperation', model.indexOf('const settings = {')));
assert.doesNotMatch(settingsObject, /updates\s*:/,
	'passive update settings are coupled to Mihomo operational apply');

const proxyStart = config.indexOf('async function switchProxyModeFromHeader(');
const proxyEnd = config.indexOf('async function loadClashLogs()', proxyStart);
assert.doesNotMatch(config.slice(proxyStart, proxyEnd), /restartOrReloadServiceOrThrow\(['"]restart/,
	'proxy-mode operational apply is followed by a duplicate full restart');

const controlStart = config.indexOf('function bindControlAndHeaderEvents()');
const restartStart = config.indexOf("const restartBtn = pageRoot.querySelector('#sbox-restart');", controlStart);
const restartEnd = config.indexOf('const dashboardBtn', restartStart);
assert.match(config.slice(restartStart, restartEnd), /withRestartButtonFeedback/,
	'explicit Restart button lost service feedback');

console.log('conditional settings apply check passed');
