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

const toolbarBlock = blockBetween('<div class="sbox-config-toolbar">', '<div id="miclash-editor"', config);
const actionBlock = blockBetween('<div class="sbox-actions">', '<div id="sbox-pane-settings"', config);
const saveUrlHandler = handlerBlock("const saveUrlBtn = pageRoot.querySelector('#sbox-save-sub-url');");
const updateUrlHandler = handlerBlock("const updateUrlBtn = pageRoot.querySelector('#sbox-update-sub');");
const clearUrlHandler = handlerBlock("const clearUrlBtn = pageRoot.querySelector('#sbox-clear-sub-url');");

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

check(saveUrlHandler.includes("setOperationStatus('running', _('Saving subscription URL...'))"),
	'Save URL handler must show matching operation status.');
check(saveUrlHandler.includes('await saveSubscriptionUrl(url, selectedConfig);'),
	'Save URL handler must persist the current URL.');
check(!saveUrlHandler.includes('fetchSubscriptionAsYaml('),
	'Save URL handler must not download/update config.');

check(updateUrlHandler.includes("setOperationStatus('running', _('Saving subscription URL...'))"),
	'Update URL handler must save URL before downloading.');
check(updateUrlHandler.includes('fetchSubscriptionAsYaml('),
	'Update URL handler must keep the subscription download/update flow.');

check(clearUrlHandler.includes("setOperationStatus('running', _('Clearing subscription URL...'))"),
	'Clear URL handler must show matching operation status.');
check(clearUrlHandler.includes("await saveSubscriptionUrl('', selectedConfig);"),
	'Clear URL handler must persist an empty subscription URL.');

check(config.includes("_('Check')") && !config.includes("_('Validate YAML')"),
	'Validate YAML button must be renamed to Check.');
check(config.includes("_('Clear')") && !config.includes("_('Clear Editor')"),
	'Clear Editor button must be renamed to Clear.');
check(config.includes('Client devices only through MiClash (Protection)') &&
	!config.includes('Client devices only through MiClash (beta)'),
	'Guard text must use Protection instead of beta.');

check(actionBlock.includes('id="sbox-open-rulesets"'),
	'Rulesets button must be in the editor action row.');
check(!config.includes('sbox-config-footer'),
	'Rulesets footer row must be removed.');
check(config.includes('sbox-rulesets-action') && style.includes('.sbox-rulesets-action'),
	'Rulesets action must have a right-pinning class and style.');

[
	'Save',
	'Update',
	'Check',
	'Clear',
	'Clearing subscription URL...',
	'Subscription URL saved.',
	'Subscription URL cleared.',
	'Client devices only through MiClash (Protection)'
].forEach((msgid) => {
	for (const [path, po] of locales) {
		check(po.includes(`msgid "${msgid}"`) && !po.includes(`msgid "${msgid}"\nmsgstr ""`),
			`${path} must translate ${JSON.stringify(msgid)}`);
	}
});

if (failed) process.exit(1);
console.log('config toolbar actions check passed');
