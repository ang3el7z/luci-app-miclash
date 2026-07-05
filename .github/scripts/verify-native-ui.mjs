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
	'editor.js',
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
	[/tomorrow_night_bright/i, 'bundled custom dark Ace theme'],
	[/ace\/theme\/(?!miclash_luci\b)[A-Za-z0-9_-]+/i, 'Ace theme must use the LuCI-derived MiClash theme'],
	[/theme-[A-Za-z0-9_-]+\.js/i, 'bundled Ace theme asset instead of LuCI-derived theme'],
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
	[/\.sbox-(?:native-)?editor\s*\{[^}]*\b(?:border|background|color)\s*:/i, 'custom editor surface styling instead of native cbi-input-text theme'],
	[/\.sbox-ruleset-(?:whitelist-)?editor\s*\{[^}]*\b(?:border|background|color)\s*:/i, 'custom ruleset editor surface styling instead of native cbi-input-text theme'],
	[/\.sbox-rulesets-example\s+pre\s*\{[^}]*\b(?:border|background|color)\s*:/i, 'custom ruleset example surface instead of native descriptive text'],
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
for (const aceRuntime of ['ace.js', 'mode-yaml.js', 'mode-text.js']) {
	if (!fs.existsSync(path.join(viewDir, 'ace', aceRuntime))) {
		failures.push(`ace/${aceRuntime}: Ace runtime/mode must be packaged for the config editor`);
	}
}

const editor = fs.readFileSync(path.join(viewDir, 'editor.js'), 'utf8');
if (!/function\s+createTextareaEditor\b/.test(editor)) {
	failures.push('editor.js: missing native textarea fallback when Ace cannot load');
}
if (!/ACE_BASE\s*\+\s*['"]ace\.js['"]/.test(editor)) {
	failures.push('editor.js: Ace must load through LuCI resource path wrapper');
}
if (!/ace\/theme\/miclash_luci/.test(editor) || !/var\(--sbox-text\)/.test(editor)) {
	failures.push('editor.js: Ace theme must be derived from LuCI/MiClash CSS variables');
}
if (!/useWorker:\s*false/.test(editor) || !/setUseWorker\(false\)/.test(editor)) {
	failures.push('editor.js: Ace background workers must stay disabled for OpenWrt packaging');
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
