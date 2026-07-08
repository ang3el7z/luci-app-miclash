import { readFileSync } from 'node:fs';

const configPath = 'luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/config.js';
const stylePath = 'luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/style.css';
const config = readFileSync(configPath, 'utf8');
const style = readFileSync(stylePath, 'utf8');

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

function functionBlock(name) {
	const start = config.indexOf(`function ${name}(`);
	const next = start >= 0 ? config.indexOf('\nfunction ', start + 1) : -1;
	if (start < 0) return '';
	return next > start ? config.slice(start, next) : config.slice(start);
}

const buildPageBlock = functionBlock('buildPageHtml');
const setOperationErrorBlock = functionBlock('setOperationError');
const bindTabEventsBlock = functionBlock('bindTabEvents');
const controlTabBindingBlock = blockBetween("tabAttr: 'ctrl-tab'", "tabAttr: 'cfg-tab'", bindTabEventsBlock);
const configTabBindingBlock = bindTabEventsBlock.slice(bindTabEventsBlock.indexOf("tabAttr: 'cfg-tab'"));
const bindConfigEventsBlock = functionBlock('bindConfigEvents');
const bindControlBlock = functionBlock('bindControlAndHeaderEvents');
const operationStatusRenderBlock = blockBetween('operationStatus.innerHTML =', 'operationStatus.title = state.message;', config);
const rulesetsSaveBlock = blockBetween("const saveBtn = body.querySelector('#sbox-ruleset-save');", 'if (data.whitelistMode', config);
const rulesetsWhitelistBlock = blockBetween("const saveWhitelistBtn = body.querySelector('#sbox-ruleset-save-whitelist');", '\n}\n\nfunction buildSettingsPaneHtml', config);

check(!config.includes('data-ctrl-tab="settings"'),
	'Settings must move out of the top control tab group.');
check(buildPageBlock.includes('data-cfg-tab="settings"'),
	'Lower config tab group must include a Settings tab.');
check(buildPageBlock.indexOf('data-cfg-tab="config"') < buildPageBlock.indexOf('data-cfg-tab="settings"') &&
	buildPageBlock.indexOf('data-cfg-tab="settings"') < buildPageBlock.indexOf('data-cfg-tab="logs"'),
	'Lower tab order must be Config, Settings, Logs.');
check(configTabBindingBlock.includes("settings: '#sbox-pane-settings'"),
	'Config tab binding must include the settings pane.');
check(!controlTabBindingBlock.includes("settings: '#sbox-pane-settings'"),
	'Settings pane must not remain wired to the control tab group.');

check(config.includes('detail:') && config.includes('showCloseAt:'),
	'operationStatus must store full detail and delayed close metadata.');
check(!setOperationErrorBlock.includes('getOperationRecommendation('),
	'Visible operation errors must not append recommendation text.');
check(config.includes('function showOperationErrorDetails('),
	'Missing showOperationErrorDetails() helper.');
check(config.includes('async function copyOperationErrorDetail('),
	'Missing copyOperationErrorDetail() helper.');
check(config.includes('sbox-operation-status-detail') &&
	config.includes('sbox-operation-status-close'),
	'Operation status DOM must render detail and close controls.');
check(style.includes('.sbox-operation-status-detail') &&
	style.includes('.sbox-operation-status-close'),
	'Operation status detail and close controls must be styled.');
check(operationStatusRenderBlock.indexOf('sbox-operation-status-content') >= 0 &&
	operationStatusRenderBlock.indexOf('sbox-operation-status-message') < operationStatusRenderBlock.indexOf('sbox-operation-status-detail') &&
	operationStatusRenderBlock.indexOf('sbox-operation-status-detail') < operationStatusRenderBlock.indexOf('sbox-operation-status-close'),
	'Operation status detail control must stay inline after the message before the close control.');
check(!operationStatusRenderBlock.includes('sbox-operation-status-spacer') &&
	!style.includes('.sbox-operation-status-spacer'),
	'Operation status must not use a spacer between details and close.');
check(style.includes('.sbox-operation-status-content') &&
	style.includes('position: relative;') &&
	style.includes('position: absolute;') &&
	style.includes('right: 10px;') &&
	style.includes('top: 6px;'),
	'Operation status close control must be pinned to the top-right corner.');
check(style.includes('.sbox-operation-status {\n\tdisplay: flex;') &&
	style.includes('align-items: center;') &&
	style.includes('padding: 6px 38px 6px 10px;'),
	'Operation status content must be vertically centered with balanced padding.');
check(style.includes('.sbox-operation-status-detail') &&
	style.includes('width: 16px;') &&
	style.includes('height: 16px;') &&
	style.includes('font-size: 11px;') &&
	style.includes('font-weight: 600;') &&
	style.includes('vertical-align: -0.15em;'),
	'Operation detail info button must be visually compact and aligned with text.');
check(config.includes('sbox-operation-error-section') &&
	config.includes('sbox-operation-error-label') &&
	config.includes('sbox-operation-error-actions'),
	'Operation error modal must use structured visual sections.');
check(style.includes('.sbox-operation-error-section') &&
	style.includes('.sbox-operation-error-label') &&
	style.includes('.sbox-operation-error-actions') &&
	style.includes('.sbox-operation-error-detail'),
	'Full error detail modal sections must be styled.');

[
	"Saving settings...",
	"Switching proxy mode...",
	"Saving subscription URL...",
	"Validating YAML...",
	"Saving configuration...",
	"Setting selected config as Main...",
	"Saving ruleset...",
	"Saving IP-CIDR list...",
	"Checking Clash service readiness..."
].forEach((message) => {
	check(config.includes(`_('${message}')`), `Missing operation status message: ${message}`);
});

check(bindControlBlock.includes("setOperationStatus('running', _('Switching proxy mode...'))"),
	'Proxy mode changes must show operation status before saving/restarting.');
check(bindConfigEventsBlock.includes("setOperationStatus('running', _('Saving subscription URL...'))"),
	'Subscription update must show operation status before saving/downloading.');
check(bindConfigEventsBlock.includes("setOperationStatus('running', _('Validating YAML...'))"),
	'YAML validation must show operation status.');
check(bindConfigEventsBlock.includes("setOperationStatus('running', _('Saving configuration...'))"),
	'Config save/apply must show operation status.');
check(config.includes("setOperationStatus('running', _('Setting selected config as Main...'))"),
	'Set as Main must show operation status.');
check(rulesetsSaveBlock.includes("setOperationStatus('running', _('Saving ruleset...'))"),
	'Ruleset save must show operation status.');
check(rulesetsWhitelistBlock.includes("setOperationStatus('running', _('Saving IP-CIDR list...'))"),
	'IP-CIDR list save must show operation status.');

if (failed) process.exit(1);
console.log('operation status expansion check passed');
