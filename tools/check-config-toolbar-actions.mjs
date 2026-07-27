import { readFileSync } from 'node:fs';

const configPath = 'luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/config.js';
const storePath = 'luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/store.js';
const stylePath = 'luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/style.css';
const localePaths = [
	'luci-app-miclash/rootfs/po/ru/miclash.po',
	'luci-app-miclash/rootfs/po/zh-cn/miclash.po'
];

const config = readFileSync(configPath, 'utf8');
const store = readFileSync(storePath, 'utf8');
const style = readFileSync(stylePath, 'utf8');
const locales = localePaths.map((path) => [path, readFileSync(path, 'utf8')]);

let failed = false;

function check(condition, message) {
	if (!condition) {
		console.error(message);
		failed = true;
	}
}

function blockBetween(startNeedle, endNeedle, source = config) {
	const start = source.indexOf(startNeedle);
	const end = source.indexOf(endNeedle, start + startNeedle.length);
	return start >= 0 && end > start ? source.slice(start, end) : '';
}

function handlerBlock(selectorNeedle) {
	const start = config.indexOf(selectorNeedle);
	const nextConst = start >= 0 ? config.indexOf('\n\tconst ', start + selectorNeedle.length) : -1;
	return start >= 0 && nextConst > start ? config.slice(start, nextConst) : '';
}

function cssBlock(selector) {
	const start = style.indexOf(`${selector} {`);
	const end = start >= 0 ? style.indexOf('\n}', start + selector.length) : -1;
	return start >= 0 && end > start ? style.slice(start, end + 2) : '';
}

const toolbarBlock = blockBetween('<div class="sbox-config-toolbar">', '<div id="miclash-editor"', config);
const actionBlock = blockBetween('<div class="sbox-actions">', '<div id="sbox-pane-settings"', config);
const saveUrlHandler = handlerBlock("const saveUrlBtn = pageRoot.querySelector('#sbox-save-sub-url');");
const updateUrlHandler = handlerBlock("const updateUrlBtn = pageRoot.querySelector('#sbox-update-sub');");
const clearUrlHandler = handlerBlock("const clearUrlBtn = pageRoot.querySelector('#sbox-clear-sub-url');");
const profileSwitch = blockBetween('async function switchConfigProfile(', '\nasync function setSelectedConfigAsMain');
const mainAvailability = blockBetween('function updateSetMainAvailability(', '\nasync function switchConfigProfile');
const serviceJob = blockBetween('async function startMiClashServiceJob(', '\nasync function pollMiClashUpdateJob');
const configHydration = blockBetween('async function hydrateConfigWorkspace(', '\nfunction beginPageHydration');
const profileInventory = blockBetween('async function listConfigProfiles(', '\nasync function readSubscriptionUrl', store);
const subscriptionButtonStyle = [
	cssBlock('.sbox-subscription-action'),
	cssBlock('.sbox-url-clear-button')
].join('\n');

check(!config.includes('sbox-save-update-sub'),
	'Combined Save URL / Update Config button must be removed.');
check(!config.includes('Save URL / Update Config'),
	'Combined Save URL / Update Config label must be removed from UI code.');
check(toolbarBlock.includes('id="sbox-save-sub-url"') &&
	toolbarBlock.includes('id="sbox-update-sub"') &&
	toolbarBlock.includes('id="sbox-clear-sub-url"'),
	'Subscription toolbar must render save, update, and clear URL buttons.');
check(toolbarBlock.indexOf('id="sbox-save-sub-url"') < toolbarBlock.indexOf('id="sbox-update-sub"') &&
	toolbarBlock.indexOf('id="sbox-update-sub"') < toolbarBlock.indexOf('id="sbox-clear-sub-url"'),
	'Subscription toolbar button order must be Save, Update, clear.');
check(toolbarBlock.includes('id="sbox-save-sub-url" type="button" class="cbi-button cbi-button-positive sbox-subscription-action"'),
	'Subscription Save button must use the same positive style as the editor Save button.');
check(toolbarBlock.includes('id="sbox-update-sub" type="button" class="cbi-button cbi-button-apply sbox-subscription-action"'),
	'Subscription Update button must use the same apply style as the editor Check button.');
check(/id="sbox-clear-sub-url" type="button" class="[^"]*\bcbi-button\b[^"]*\bcbi-button-negative\b[^"]*\bsbox-url-clear-button\b[^"]*\bsbox-icon-button\b[^"]*"/.test(toolbarBlock),
	'Subscription clear button must keep the negative style and render as an icon button.');
check(style.includes('.sbox-subscription-actions') && style.includes('gap: 8px;'),
	'Subscription toolbar buttons must keep the same 8px gap as editor actions.');
check(!/\b(?:width|min-width|height|min-height|padding|font-weight)\s*:/.test(subscriptionButtonStyle),
	'Subscription toolbar buttons must not override native cbi-button sizing or weight.');

check(saveUrlHandler.includes("setOperationStatus('running', _('Saving subscription URL...'))"),
	'Save URL handler must show matching operation status.');
check(saveUrlHandler.includes('await saveSubscriptionUrl(url, selectedConfig);'),
	'Save URL handler must persist the current URL.');
check(!saveUrlHandler.includes('fetchSubscriptionAsYaml('),
	'Save URL handler must not download/update config.');

check(updateUrlHandler.includes("setOperationStatus('running', _('Saving subscription URL...'))"),
	'Update URL handler must save URL before downloading.');
check(updateUrlHandler.includes('applySubscriptionOnRouter(') &&
	!updateUrlHandler.includes('fetchSubscriptionAsYaml('),
	'Update URL handler must apply the subscription through the router-side helper.');

check(clearUrlHandler.includes("setOperationStatus('running', _('Clearing subscription URL...'))"),
	'Clear URL handler must show matching operation status.');
check(clearUrlHandler.includes("await saveSubscriptionUrl('', selectedConfig);"),
	'Clear URL handler must persist an empty subscription URL.');
check(!store.includes('ensureConfigProfilesReady') && !config.includes('ensureConfigProfilesReady'),
	'Profile hydration must not copy Config #1 into empty secondary slots.');
check(profileInventory.includes('api.config_list()') &&
	profileInventory.includes('CONFIG_PROFILES.filter('),
	'Profile inventory must map the typed backend list onto known package profiles.');
check(configHydration.includes('listConfigProfiles()') &&
	configHydration.includes('appState.configProfiles = profiles'),
	'Profile hydration must render only profiles reported by the backend inventory.');
check(profileSwitch.includes('readConfigFileByName(selected)') &&
	profileSwitch.includes('readSubscriptionUrl(selected)'),
	'Profile switching must load the selected profile and its own subscription URL.');
check(profileSwitch.includes('updateSetMainAvailability(appState.configContent, selected)'),
	'Profile switching must refresh Set as Main availability from persisted profile bytes.');
check(mainAvailability.includes('button.hidden = selected === MAIN_CONFIG_NAME') &&
	mainAvailability.includes("String(content || '').trim()") &&
	mainAvailability.includes('button.disabled ='),
	'Set as Main must remain visible but disabled for an empty secondary profile.');
check(serviceJob.includes("method('config.yaml', 'luci')"),
	'Top service controls must always target Config #1.');
check(config.includes('If Clash is running, it will reload; if stopped, it will remain stopped.'),
	'Set as Main confirmation must describe the real conditional service behavior.');

check(config.includes("_('Validate')") && !config.includes("_('Validate YAML')"),
	'Draft action must use the approved concise Validate label.');
check(config.includes("_('Clear editor content')") && !config.includes("_('Clear Editor')"),
	'Clear Editor button must use the MiClash-specific clear action label.');
check(config.includes('Direct connection guard') &&
	!config.includes('Client devices only through MiClash'),
	'Guard text must use the consistent full label.');

check(actionBlock.includes('id="sbox-open-rulesets"'),
	'Rulesets button must be in the editor action row.');
check(!config.includes('sbox-config-footer'),
	'Rulesets footer row must be removed.');
check(actionBlock.indexOf('id="sbox-set-main-config"') < actionBlock.indexOf('sbox-actions-spacer') &&
	actionBlock.indexOf('sbox-actions-spacer') < actionBlock.indexOf('id="sbox-open-rulesets"'),
	'Rulesets button must be separated from editor actions by a flex spacer.');
check(config.includes('sbox-rulesets-action') && style.includes('.sbox-rulesets-action') &&
	style.includes('.sbox-actions-spacer') && style.includes('flex: 1 1 auto;'),
	'Rulesets action must have an explicit right-pinning spacer and style.');

[
	'Save',
	'Update',
	'Check',
	'Clear editor content',
	'Clearing subscription URL...',
	'Subscription URL saved.',
	'Subscription URL cleared.',
	'Save or download this config before setting it as Main.',
	'Direct connection guard'
].forEach((msgid) => {
	for (const [path, po] of locales) {
		check(po.includes(`msgid "${msgid}"`) && !po.includes(`msgid "${msgid}"\nmsgstr ""`),
			`${path} must translate ${JSON.stringify(msgid)}`);
	}
});

if (failed) process.exit(1);
console.log('config toolbar actions check passed');
