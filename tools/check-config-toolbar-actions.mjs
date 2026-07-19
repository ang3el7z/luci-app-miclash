import { readFileSync } from 'node:fs';

const configPath = 'luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/config.js';
const stylePath = 'luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/style.css';
const localePaths = [
	'luci-app-miclash/rootfs/po/ru/miclash.po',
	'luci-app-miclash/rootfs/po/zh-cn/miclash.po'
];

const config = readFileSync(configPath, 'utf8');
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
	'Direct connection guard'
].forEach((msgid) => {
	for (const [path, po] of locales) {
		check(po.includes(`msgid "${msgid}"`) && !po.includes(`msgid "${msgid}"\nmsgstr ""`),
			`${path} must translate ${JSON.stringify(msgid)}`);
	}
});

if (failed) process.exit(1);
console.log('config toolbar actions check passed');
