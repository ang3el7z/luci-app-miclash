import fs from 'node:fs';
import path from 'node:path';

const viewDir = path.join(
	process.cwd(),
	'luci-app-miclash',
	'rootfs',
	'www',
	'luci-static',
	'resources',
	'view',
	'miclash'
);

const files = [
	'config.js',
	'ui-shell.js',
	'guard.js',
	'service.js',
	'subscription.js',
	'style.css'
].map((name) => path.join(viewDir, name));

const banned = [
	[/\bUI_THEME\b/, 'custom MiClash theme state'],
	[/\bthemeToggle\b/, 'custom theme toggle'],
	[/\bPAGE_CSS\b/, 'inline page stylesheet instead of a LuCI resource'],
	[/E\(\s*['"]style['"]/, 'inline style element instead of a LuCI resource stylesheet'],
	[/localStorage\.(?:getItem|setItem|removeItem)\([^)]*theme/i, 'persisted custom theme'],
	[/(?:style=|['"]style['"]\s*:|\b[A-Za-z0-9_$]+\s*\.\s*style\s*\.)/i, 'inline style instead of native classes/hidden state'],
	[/prefers-color-scheme/i, 'custom browser theme detection instead of native LuCI theme inheritance'],
	[/\bace\.(?:edit|config)\b/i, 'Ace editor runtime instead of native LuCI themed textarea'],
	[/tomorrow_night_bright/i, 'bundled custom dark Ace theme'],
	[/\bsbox-card\b/, 'custom card shell instead of cbi-section'],
	[/\bsbox-section\b/, 'custom cbi-section wrapper instead of native section styling'],
	[/\bsbox-modal-overlay\b/, 'custom modal overlay instead of ui.showModal'],
	[/\bsbox-modal-window\b/, 'custom modal window instead of ui.showModal'],
	[/\bsbox-modal-(body|actions|content)\b/, 'custom modal internals instead of native LuCI modal structure'],
	[/\bsbox-tab-active\b/, 'custom active tab state instead of native cbi-tab/cbi-tab-disabled'],
	[/\bsbox-header-dot\b/, 'custom header separator instead of native spacing'],
	[/\bsbox-(?:status-on|status-off|dot|dot-on|dot-off|guard-pill|guard-on|guard-off|guard-dot)\b/, 'custom colored state badge instead of native LuCI button state'],
	[/\bsbox-interface-auto\b/, 'custom colored interface state instead of native text state'],
	[/\bsbox-panel-bg\b/, 'custom panel background instead of native cbi-section theme'],
	[/\bsbox-ruleset-list-item['"][^]*?\bactive\b/, 'custom active ruleset state instead of native cbi-button state'],
	[/\bsbox-version-action-(?:icon|install|reinstall)\b/, 'custom colored header action instead of native LuCI button state'],
	[/\bsbox-log-(?:info|warn|error)\b/, 'custom log severity palette instead of native preformatted log text'],
	[/--sbox-(?:accent|success|danger|warn)\b/, 'custom semantic color variables instead of native LuCI button/text classes'],
	[/linear-gradient\(/i, 'custom gradient palette'],
	[/border-radius:\s*999px/i, 'pill-shaped custom shell radius'],
	[/transform:\s*scale\(/i, 'custom hover scaling instead of native LuCI interaction'],
	[/transition:\s*[^;]+/i, 'custom transitions instead of native LuCI interaction'],
	[/text-transform:\s*uppercase/i, 'custom uppercase tab typography'],
	[/letter-spacing:\s*(?!0(?:[;\s]|$))/i, 'custom letter spacing']
];

const colorLiteral = /(?:#[0-9a-fA-F]{3,8}|rgba?\([^)]*\))/g;
const failures = [];

for (const file of files) {
	const source = fs.readFileSync(file, 'utf8');
	const rel = path.relative(process.cwd(), file).replace(/\\/g, '/');

	for (const [pattern, reason] of banned) {
		const match = source.match(pattern);
		if (match) failures.push(`${rel}: ${reason} (${match[0]})`);
	}

	for (const match of source.matchAll(colorLiteral)) {
		failures.push(`${rel}: hard-coded color outside native theme (${match[0]})`);
	}
}

const config = fs.readFileSync(path.join(viewDir, 'config.js'), 'utf8');
if (!/class="cbi-section/.test(config)) {
	failures.push('config.js: missing native cbi-section shell');
}
if (!/class="cbi-tabmenu/.test(config)) {
	failures.push('config.js: missing native cbi-tabmenu tabs');
}

const uiShell = fs.readFileSync(path.join(viewDir, 'ui-shell.js'), 'utf8');
if (!/ui\.showModal\(/.test(uiShell) || !/ui\.hideModal\(/.test(uiShell)) {
	failures.push('ui-shell.js: modal helper must use native LuCI ui.showModal/ui.hideModal');
}
if (fs.existsSync(path.join(viewDir, 'ace', 'theme-tomorrow_night_bright.js'))) {
	failures.push('ace/theme-tomorrow_night_bright.js: custom dark editor palette must not be packaged');
}
if (fs.existsSync(path.join(viewDir, 'ace', 'ace.js'))) {
	failures.push('ace/ace.js: custom editor palette/runtime must not be packaged');
}
for (const legacyView of ['settings.js', 'rulesets.js', 'log.js', 'route.js']) {
	if (fs.existsSync(path.join(viewDir, legacyView))) {
		failures.push(`${legacyView}: legacy routed view proxy must not be packaged`);
	}
}

if (failures.length) {
	console.error('Native UI verification failed:');
	for (const failure of failures) console.error(`- ${failure}`);
	process.exit(1);
}

console.log(`Native UI verified: ${files.length} files`);
