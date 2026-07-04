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
	'settings.js',
	'rulesets.js',
	'subscription.js'
].map((name) => path.join(viewDir, name));

const banned = [
	[/\bUI_THEME\b/, 'custom MiClash theme state'],
	[/\bthemeToggle\b/, 'custom theme toggle'],
	[/localStorage\.(?:getItem|setItem|removeItem)\([^)]*theme/i, 'persisted custom theme'],
	[/\bsbox-card\b/, 'custom card shell instead of cbi-section'],
	[/\bsbox-modal-overlay\b/, 'custom modal overlay instead of ui.showModal'],
	[/\bsbox-modal-window\b/, 'custom modal window instead of ui.showModal'],
	[/linear-gradient\(/i, 'custom gradient palette']
];

const allowedNativeColorFallback = /var\([^;\n{}]*#[0-9a-fA-F]{3,8}[^;\n{}]*\)/g;
const colorLiteral = /(?:#[0-9a-fA-F]{3,8}|rgba?\([^)]*\))/g;
const failures = [];

for (const file of files) {
	const source = fs.readFileSync(file, 'utf8');
	const rel = path.relative(process.cwd(), file).replace(/\\/g, '/');

	for (const [pattern, reason] of banned) {
		const match = source.match(pattern);
		if (match) failures.push(`${rel}: ${reason} (${match[0]})`);
	}

	const withoutAllowedFallbacks = source.replace(allowedNativeColorFallback, 'var(--native-fallback)');
	for (const match of withoutAllowedFallbacks.matchAll(colorLiteral)) {
		failures.push(`${rel}: hard-coded color outside native var fallback (${match[0]})`);
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

if (failures.length) {
	console.error('Native UI verification failed:');
	for (const failure of failures) console.error(`- ${failure}`);
	process.exit(1);
}

console.log(`Native UI verified: ${files.length} files`);
