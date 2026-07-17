import { readFileSync } from 'node:fs';

const config = readFileSync('luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/config.js', 'utf8');
const css = readFileSync('luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/style.css', 'utf8');
const ru = readFileSync('luci-app-miclash/rootfs/po/ru/miclash.po', 'utf8');
const settingsPanels = readFileSync('luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/settings-panels.js', 'utf8');
const historyPanel = readFileSync('luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/history-panel.js', 'utf8');
const uiShell = readFileSync('luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/ui-shell.js', 'utf8');
const devicesPanel = readFileSync('luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/devices-panel.js', 'utf8');

function cssBlock(selector) {
	const escaped = selector.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
	const match = css.match(new RegExp(escaped + '\\s*\\{([\\s\\S]*?)\\}', 'm'));
	return match ? match[1] : '';
}

function msgstr(po, id) {
	const escaped = id.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
	const match = po.match(new RegExp('msgid "' + escaped + '"\\nmsgstr "([^"]*)"', 'm'));
	return match ? match[1] : null;
}

const modalWide = cssBlock('.sbox-modal-wide');
const rulesetsBody = cssBlock('.sbox-modal-wide .sbox-rulesets-modal-body');
const iconButton = cssBlock('.sbox-icon-button');
const versionActionButton = cssBlock('.sbox-version-action-button');
const versionActionIcon = cssBlock('.sbox-version-action-icon');

const checks = [
	{
		name: 'wide modal stays inside LuCI modal padding',
		pass: /box-sizing:\s*border-box;/.test(modalWide) && /max-width:\s*100%;/.test(modalWide)
	},
	{
		name: 'rulesets modal body can scroll when editor/whitelist content is taller than mobile viewport',
		pass: /overflow:\s*auto;/.test(rulesetsBody) && !/overflow:\s*hidden;/.test(rulesetsBody)
	},
	{
		name: 'URL clear button is styled as an icon button and renders a normalized close icon',
		pass: /sbox-url-clear-button[^']*sbox-icon-button/.test(config) &&
			/sbox-clear-sub-url[\s\S]*buildInlineIcon\('x', 'sbox-button-icon'\)/.test(config) &&
			!/sbox-clear-sub-url[\s\S]{0,260}>(?:x|&times;)<\/button>/.test(config)
	},
	{
		name: 'operation errors persist as dismissible assertive live alerts',
		pass: !config.includes('sbox-operation-status-detail') &&
			config.includes('sbox-operation-dismiss') &&
			config.includes("type === 'error' ? 'alert' : 'status'") &&
			config.includes('autoClearMs: opts.autoClearMs == null ? 0') &&
			config.includes('dismissible: true')
	},
	{
		name: 'primary controls expose accessible names and tab state',
		pass: /sbox-mode-select[^>]*aria-label/.test(config) &&
			/sbox-config-select[^>]*aria-label/.test(config) &&
			/sbox-subscription-url[^>]*aria-label/.test(config) &&
			/sbox-notification-test-channel[\s\S]{0,180}aria-label/.test(settingsPanels) &&
			uiShell.includes("const tabName = tab.getAttribute('data-' + tabAttr)") &&
			uiShell.includes("const pane = paneNodes[tabName]") &&
			uiShell.includes("setAttribute('aria-pressed'") && uiShell.includes("setAttribute('aria-controls'")
	},
	{
		name: 'periodic panel repaints are not broad live regions',
		pass: !/sbox-diagnostics-summary[^>]*aria-live/.test(config) &&
			!/sbox-management-(?:settings|backup|devices)[^>]*aria-live/.test(config)
	},
	{
		name: 'history retains native button roles and device choices are localized',
		pass: !historyPanel.includes("'role': 'listitem'") &&
			devicesPanel.includes("inherit: () => _('Inherit')") &&
			devicesPanel.includes("() => _('Monday')") &&
			!devicesPanel.includes('}), String(day)')
	},
	{
		name: 'header version actions render normalized SVG icons instead of font glyphs',
		pass: config.includes('function buildVersionActionIcon') &&
			config.includes('sbox-version-action-icon') &&
			!config.includes("safeText(appActionState.icon)") &&
			!config.includes("safeText(kernelActionState.icon)") &&
			/width:\s*14px;/.test(versionActionIcon) &&
			/height:\s*14px;/.test(versionActionIcon) &&
			/flex:\s*0 0 14px;/.test(versionActionIcon)
	},
	{
		name: 'icon-only buttons use native cbi-button height and centered glyphs',
		pass: /width:\s*28px;/.test(iconButton) &&
			/min-width:\s*28px;/.test(iconButton) &&
			/height:\s*28px;/.test(iconButton) &&
			/min-height:\s*28px;/.test(iconButton) &&
			/font-size:\s*14px;/.test(iconButton) &&
			/text-align:\s*center;/.test(iconButton) &&
			/width:\s*22px;/.test(versionActionButton) &&
			/height:\s*22px;/.test(versionActionButton)
	},
	{
		name: 'obsolete operation error details modal is removed',
		pass: !config.includes('showOperationErrorDetails') &&
			!config.includes('copyOperationErrorDetail') &&
			!config.includes('sbox-operation-error-') &&
			!css.includes('sbox-operation-error-') &&
			!config.includes('Copy details')
	},
	{
		name: 'auto-update interval radio has no redundant Every label',
		pass: /'<label class="sbox-auto-update-choice">' \+\s*'<input type="radio" name="sbox-auto-update-interval"/.test(config) &&
			!config.includes("safeText(_('Every'))") &&
			!config.includes('sbox-auto-update-interval-label')
	},
	{
		name: 'auto-update row uses checkbox spacing before HWID row',
		pass: config.includes('sbox-checkbox-row sbox-auto-update-row') &&
			!config.includes('sbox-settings-field sbox-auto-update-field')
	},
	{
		name: 'Russian release channel labels are localized',
		pass: msgstr(ru, 'Latest') !== 'Latest' && msgstr(ru, 'Pre-release') !== 'Pre-release'
	},
	{
		name: 'Russian action labels use verbs',
		pass: msgstr(ru, 'Start') === 'Запустить' &&
			msgstr(ru, 'Stop core') === 'Остановить' &&
			msgstr(ru, 'Restart') === 'Перезапустить' &&
			msgstr(ru, 'Clear editor content') === 'Очистить'
	},
	{
		name: 'MiClash action buttons avoid base LuCI translation collisions',
		pass: config.includes("_('Stop core')") &&
			config.includes("_('Clear editor content')") &&
			!config.includes("id=\"sbox-stop\" type=\"button\" class=\"cbi-button cbi-button-negative sbox-service-button\"' + (appState.serviceRunning ? '' : ' hidden') + '>' + safeText(_('Stop'))") &&
			!config.includes("id=\"sbox-clear-editor\" type=\"button\" class=\"cbi-button cbi-button-negative\">' + safeText(_('Clear'))")
	}
];

const failed = checks.filter((check) => !check.pass);

if (failed.length) {
	for (const check of failed) {
		console.error('failed: ' + check.name);
	}
	process.exit(1);
}

console.log('ui release polish check passed');
