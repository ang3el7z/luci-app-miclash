import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';

const root = 'luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/';
const recorderPath = root + 'performance.js';
const panelPath = root + 'performance-panel.js';

assert.ok(existsSync(recorderPath), 'performance recorder module is missing');
assert.ok(existsSync(panelPath), 'Developer performance panel module is missing');

let clock = 100;
const recorderSource = readFileSync(recorderPath, 'utf8');
const recorder = new Function('baseclass', 'performance', 'Date', recorderSource)(
	{ extend: (value) => value },
	{ now: () => clock },
	{ now: () => 1700000000000 + clock }
);

const page = recorder.begin('page.hydration');
clock = 125.5;
recorder.end(page, true);
recorder.recordRpc('system_info', 120, true, 145);
recorder.recordRpc('subscription_get', 140, false, 150);

const first = recorder.snapshot();
assert.equal(first.records.length, 3, 'recorder did not retain real timing entries');
assert.deepEqual(first.methods.system_info, {
	count: 1, failures: 0, total_ms: 25, average_ms: 25, maximum_ms: 25
});
assert.deepEqual(first.methods.subscription_get, {
	count: 1, failures: 1, total_ms: 10, average_ms: 10, maximum_ms: 10
});
assert.equal(first.timings['page.hydration'].count, 1);
assert.equal(first.timings['page.hydration'].average_ms, 25.5);

const serialized = JSON.stringify(first);
for (const secret of [ 'arguments', 'payload', 'url', 'content', 'token' ])
	assert.equal(serialized.includes(secret), false, `metrics leaked forbidden field: ${secret}`);

for (let index = 0; index < 250; index++) {
	clock++;
	recorder.recordRpc('overview', clock - 1, true, clock);
}
assert.equal(recorder.snapshot().records.length, 200, 'history is not bounded to 200 records');

let notifications = 0;
const unsubscribe = recorder.subscribe(() => notifications++);
recorder.clear();
assert.equal(notifications, 1, 'subscribers were not notified after reset');
assert.equal(recorder.snapshot().records.length, 0, 'reset did not clear timing history');
unsubscribe();

const panelSource = readFileSync(panelPath, 'utf8');
assert.match(panelSource, /view_miclash_performance\.subscribe/,
	'Developer panel does not react to recorder changes');
assert.match(panelSource, /data-performance-action.*refresh/,
	'Developer panel has no refresh control');
assert.match(panelSource, /data-performance-action.*clear/,
	'Developer panel has no reset control');

const apiSource = readFileSync(root + 'api.js', 'utf8');
const measured = [];
const rpc = {
	declare(spec) {
		return async () => spec.method === 'overview'
			? { desired: {}, observed: {} }
			: {};
	}
};
let apiClock = 10;
const recorderProbe = {
	now() { return apiClock++; },
	recordRpc(method, startedAt, succeeded, finishedAt) {
		measured.push({ method, startedAt, succeeded, finishedAt });
	}
};
const apiModule = new Function(
	'baseclass', 'rpc', 'window', 'TextEncoder', 'Uint8Array', 'ArrayBuffer',
	'btoa', 'atob', 'view_miclash_performance', apiSource
)(
	{ extend: (value) => value }, rpc,
	{
		crypto: {},
		setTimeout,
		clearTimeout,
		CustomEvent: class {
			constructor(type, options) { this.type = type; this.detail = options.detail; }
		}
	},
	TextEncoder, Uint8Array, ArrayBuffer,
	(value) => Buffer.from(value, 'binary').toString('base64'),
	(value) => Buffer.from(value, 'base64').toString('binary'),
	recorderProbe
);
await apiModule.create({ startupRetryMs: 0 }).overview();
assert.deepEqual(measured, [ {
	method: 'overview', startedAt: 10, succeeded: true, finishedAt: 11
} ], 'typed RPC boundary did not emit one sanitized duration');

const configSource = readFileSync(root + 'config.js', 'utf8');
assert.match(configSource, /require view\.miclash\.performance-panel/,
	'main view does not load the Developer performance panel');
assert.match(configSource, /id="sbox-performance-panel"/,
	'Developer pane has no performance panel host');
const developerVisibilityStart = configSource.indexOf('function setDeveloperVisible(visible, activate)');
const developerVisibilityEnd = configSource.indexOf('\nfunction registerDeveloperTap()', developerVisibilityStart);
const developerVisibility = configSource.slice(developerVisibilityStart, developerVisibilityEnd);
assert.match(developerVisibility, /performanceOwner\.mount/,
	'Developer performance panel is not mounted when Developer tools open');
assert.match(developerVisibility, /performanceOwner\.destroy/,
	'Developer performance panel keeps repainting after Developer tools close');
const renderStart = configSource.indexOf('render: function(data)');
const renderEnd = configSource.indexOf('\n\tunload: function()', renderStart);
assert.doesNotMatch(configSource.slice(renderStart, renderEnd),
	/performanceOwner\.mount/,
	'hidden Developer metrics must not repaint on every background RPC');
assert.match(configSource, /view_miclash_performance\.begin\('page\.hydration'\)/,
	'page hydration duration is not recorded');
assert.match(configSource, /view_miclash_performance\.begin\('tab\.' \+ name \+ '\.open'\)/,
	'tab opening duration is not recorded');
assert.match(configSource, /view_miclash_performance\.begin\('action\.' \+ actionMetricName/,
	'user-action completion duration is not recorded');

console.log('MiClash performance recorder and Developer panel contract passed');
