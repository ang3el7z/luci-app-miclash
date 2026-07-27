import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';

const path = 'luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/background-refresh.js';
assert.ok(existsSync(path), `missing background refresh gate: ${path}`);

const source = readFileSync(path, 'utf8');
const baseclass = { extend: (value) => value };
const module = new Function('baseclass', source)(baseclass);

const reports = [];
const gate = module.create((error, context) => reports.push({ error, context }));
const transient = new Error('transient RPC failure');

assert.equal(await gate.run(async () => { throw transient; }), undefined);
assert.equal(reports.length, 0, 'one background failure must stay silent');

await gate.run(async () => { throw transient; });
assert.equal(reports.length, 1, 'two consecutive failures must report once');
assert.equal(reports[0].error, transient);
assert.deepEqual(reports[0].context, { background: true });

await gate.run(async () => { throw transient; });
assert.equal(reports.length, 1, 'persistent failure must not spam notifications');

assert.equal(await gate.run(async () => 'recovered'), 'recovered');
await gate.run(async () => { throw transient; });
assert.equal(reports.length, 1, 'success must reset the consecutive failure counter');
await gate.run(async () => { throw transient; });
assert.equal(reports.length, 2, 'a new persistent failure after recovery must report once');

const root = 'luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/';
for (const name of [ 'settings-panels.js', 'devices-panel.js', 'diagnostics-panel.js' ]) {
	const panel = readFileSync(root + name, 'utf8');
	assert.match(panel, /view\.miclash\.background-refresh/,
		`${name} does not use the shared background failure gate`);
	assert.match(panel, /backgroundRefresh\.run\(/,
		`${name} still reports the first background refresh failure directly`);
}

const config = readFileSync(root + 'config.js', 'utf8');
assert.match(config, /context\?\.background/,
	'background panel errors still become persistent operation errors');

console.log('MiClash background refresh gate contract passed');
