import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';

const root = 'luci-app-miclash/rootfs/www/luci-static/resources/view/miclash';
const files = fs.readdirSync(root)
	.filter((name) => name.endsWith('.js'))
	.sort();
const forbidden = [
	[/['"]require fs['"]/, 'LuCI fs dependency'],
	[/\bfs\s*\./, 'direct filesystem access'],
	[/\/(?:bin|sbin|usr\/bin|opt\/clash\/bin)\//, 'direct executable path'],
	[/\bexecDetached\b/, 'detached shell execution']
];

const violations = [];
for (const name of files) {
	const source = fs.readFileSync(path.join(root, name), 'utf8');
	for (const [pattern, description] of forbidden)
		if (pattern.test(source)) violations.push(`${name}: ${description}`);
	if (name !== 'api.js' && /\brpc\s*\.\s*declare\s*\(/.test(source))
		violations.push(`${name}: rpc.declare outside api.js`);
	if (!/return\s+(?:baseclass|view|L\.Class)\.extend\s*\(\s*\{/m.test(source))
		violations.push(`${name}: factory does not return a LuCI class constructor`);
}

assert.deepEqual(violations, [],
	`LuCI view modules must be UI-only and use typed api.js:\n${violations.join('\n')}`);
assert.match(fs.readFileSync(path.join(root, 'api.js'), 'utf8'),
	/\brpc\s*\.\s*declare\s*\(/,
	'api.js must remain the single typed ubus declaration boundary');

console.log(`LuCI UI-only boundary passed (${files.length} modules)`);
