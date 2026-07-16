import assert from 'node:assert/strict';
import { existsSync, readFileSync, readdirSync, statSync } from 'node:fs';
import { webcrypto } from 'node:crypto';
import { join, relative } from 'node:path';

const fixturePath = 'tests/fixtures/api/methods.json';
const uiPath = 'luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/api.js';
const backendPath = 'luci-app-miclash/rootfs/usr/share/miclash/api.uc';
assert.ok(existsSync(uiPath), `missing ${uiPath}`);

const fixture = JSON.parse(readFileSync(fixturePath, 'utf8'));
const names = fixture.methods.map((entry) => entry.name);
assert.equal(new Set(names).size, names.length, 'canonical methods must be unique');
const ui = readFileSync(uiPath, 'utf8');
const backend = readFileSync(backendPath, 'utf8');
const declared = [ ...ui.matchAll(/\{ name: '([a-z0-9_]+)', params: \[([^\]]*)\], operation: (true|false) \}/g) ]
	.map((match) => ({
		name: match[1],
		params: [ ...match[2].matchAll(/'([^']+)'/g) ].map((item) => item[1]),
		operation: match[3] === 'true'
	}));
assert.deepEqual(declared, fixture.methods, 'api.js declarations must equal the canonical fixture');
assert.equal((ui.match(/rpc\.declare\s*\(/g) || []).length, 1,
	'all declarations must use the single typed declaration factory');
assert.match(ui, /object:\s*'miclash'/);
for (const method of fixture.methods) {
	assert.match(backend, new RegExp(`\\n\\s*${method.name}:\\s*method\\(`),
		`backend missing ${method.name}`);
}

// These are the exact, bounded legacy call sites intentionally retained until
// Task 6. New files and new/changed call lines fail this gate immediately.
const legacy = {
	'config.js': [
		"await fs.exec('/usr/bin/logger', ['-p', 'daemon.' + cleanLevel, '-t', 'miclash', String(message || '')]);",
		"const clashV = await fs.exec('/opt/clash/bin/clash', ['-v']);",
		"const alt = await fs.exec('/opt/clash/bin/clash', ['version']);",
		"const result = await fs.exec('/bin/opkg', ['list-installed', packageName]);",
		"const result = await fs.exec('/usr/bin/apk', ['info', '-v', packageName]);",
		"const result = await fs.exec(binPath, ['-v']);",
		"const result = await fs.exec(binPath, ['version']);",
		"const result = await fs.exec('/opt/clash/bin/miclash-update', ['status']);",
		"await L.resolveDefault(fs.exec('/opt/clash/bin/miclash-update', ['clear-status']), null);",
		"const result = await fs.exec('/opt/clash/bin/miclash-service', ['state']);",
		"await L.resolveDefault(fs.exec('/opt/clash/bin/miclash-service', ['clear-status']), null);",
		"const result = await fs.exec('/opt/clash/bin/miclash-update', ['job', '--token', token, kind].concat(args || []));",
		"const result = await fs.exec('/opt/clash/bin/miclash-service', ['job', '--token', token, action]);",
		"const result = await fs.exec('/opt/clash/bin/clash-rules', ['guard_refresh']);",
		"const result = await fs.exec('/opt/clash/bin/miclash-memory-guard', ['sync']);"
	],
	'logs.js': [
		"const all = await fs.exec('/sbin/logread', []);",
		"const direct = await fs.exec('/sbin/logread', ['-e', 'clash']);"
	],
	'package.js': [
		"const probe = await fs.exec(checks[i].bin, ['--version']);",
		"const result = await fs.exec(bin, args);",
		"const probe = await fs.exec('/usr/bin/curl', ['--version']);",
		"const retry = await fs.exec('/usr/bin/curl', ['--version']);",
		"const forcedRetry = await fs.exec('/usr/bin/curl', ['--version']);"
	],
	'release.js': [ "const result = await fs.exec('/opt/clash/bin/miclash-update', ['release', kind, channel]);" ],
	'rulesets-model.js': [
		"await fs.exec('/bin/mkdir', ['-p', RULESET_PATH]);",
		"await fs.remove(RULESET_PATH + fileName);",
		"return fs.exec('/opt/clash/bin/clash-rules', ['update-ip-whitelist']);"
	],
	'settings-model.js': [
		"const r = await fs.exec('/bin/ls', ['/sys/class/net/']);",
		"const r = await fs.exec('/sbin/ip', ['link', 'show']);",
		"const macResult = await fs.exec('/bin/sh', ['-c',",
		"const verResult = await fs.exec('/bin/sh', ['-c',",
		"const modelResult = await fs.exec('/bin/sh', ['-c', 'cat /tmp/sysinfo/model 2>/dev/null']);",
		"const ipResult = await fs.exec('/sbin/ip', ['addr', 'show']);"
	],
	'store.js': [
		"await L.resolveDefault(fs.exec('/bin/chmod', ['0644', path]), null);",
		"await L.resolveDefault(fs.exec('/usr/bin/chmod', ['0644', path]), null);",
		"const result = await fs.exec('/bin/sh', ["
	],
	'subscription.js': [
		"const r = await fs.exec('/bin/sh', ['-c', probes[i]]);",
		"const dl = await fs.exec('/usr/bin/curl', args);",
		"const catResult = await fs.exec('/bin/cat', [TMP_SUBSCRIPTION_PATH]);",
		"const result = await fs.exec('/opt/clash/bin/miclash-subscription', args);",
		"const result = await fs.exec('/opt/clash/bin/miclash-subscription', args);",
		"await fs.remove(TMP_SUBSCRIPTION_PATH);",
		"await fs.remove(TMP_SUBSCRIPTION_HEADERS_PATH);",
		"let testResult = await fs.exec('/opt/clash/bin/clash', ['-d', '/opt/clash', '-f', configPath, '-t']);",
		"testResult = await fs.exec('/opt/clash/bin/clash', ['-d', '/opt/clash', '-t']);"
	],
	'utils.js': [
		'return fs.write(path, content);',
		"await fs.exec('/bin/sh', ['-c', 'rm -f ' + shellQuote(tmpB64)]);",
		"const res = await fs.exec('/bin/sh', ['-c',",
		"const res = await fs.exec('/bin/sh', ['-c',",
		"return fs.exec('/bin/sh', ['-c', wrapped]);"
	]
};
const viewRoot = 'luci-app-miclash/rootfs/www/luci-static/resources/view/miclash';
const forbidden = /fs\.(?:exec|write|remove)\s*\(|fs\.exec\s*\([^\n]*(?:\/bin\/sh|\/\w*\/?(?:opkg|apk))|(?:\/bin\/sh|\/\w*\/?(?:opkg|apk))[^\n]*fs\.exec/;
function walk(directory) {
	let files = [];
	for (const name of readdirSync(directory)) {
		if (name === 'ace') continue;
		const path = join(directory, name);
		if (statSync(path).isDirectory()) files = files.concat(walk(path));
		else if (path.endsWith('.js')) files.push(path);
	}
	return files;
}
for (const path of walk(viewRoot)) {
	const name = relative(viewRoot, path).replaceAll('\\', '/');
	const lines = readFileSync(path, 'utf8').split(/\r?\n/)
		.map((line) => line.trim()).filter((line) => forbidden.test(line));
	assert.deepEqual(lines, legacy[name] || [], `${name} has an unapproved direct backend call`);
}

assert.match(ui, /function normalizeReply\(/);
assert.match(ui, /destroy\(\)/);
assert.match(ui, /uploadChunks\(/);
assert.match(ui, /downloadChunks\(/);

const replies = new Map();
const calls = [];
const declarations = [];
const rpcMock = {
	declare(spec) {
		declarations.push(spec);
		return async (...args) => {
			calls.push({ method: spec.method, args });
			const handler = replies.get(spec.method);
			return typeof handler === 'function' ? handler(...args) : (handler || {});
		};
	}
};
let nextTimer = 1;
const scheduled = new Map(), cleared = [];
const windowMock = {
	crypto: webcrypto,
	setTimeout(callback) { const id = nextTimer++; scheduled.set(id, callback); return id; },
	clearTimeout(id) { cleared.push(id); scheduled.delete(id); }
};
const moduleApi = new Function('rpc', 'window', 'TextEncoder', 'Uint8Array', 'ArrayBuffer',
	'btoa', 'atob', ui)(rpcMock, windowMock, TextEncoder, Uint8Array, ArrayBuffer,
	(value) => Buffer.from(value, 'binary').toString('base64'),
	(value) => Buffer.from(value, 'base64').toString('binary'));

replies.set('service_start', { error: { code: 'BUSY', message: 'Busy' } });
const errorClient = moduleApi.create();
assert.deepEqual(declarations.slice(0, fixture.methods.length), fixture.methods.map((method) => ({
	object: 'miclash', method: method.name, params: method.params, expect: { '': {} }, reject: true
})), 'every rpc declaration must use exact object/method/params/expect/reject semantics');
await assert.rejects(errorClient.service_start('config.yaml', 'luci'),
	(error) => error.code === 'BUSY' && error.message === 'Busy');
replies.set('service_start', { operation_id: '../invalid' });
await assert.rejects(errorClient.service_start('config.yaml', 'luci'),
	(error) => error.code === 'INVALID_RESPONSE');
replies.set('health', async () => { throw { code: 'PERMISSION_DENIED', message: 'Denied' }; });
await assert.rejects(errorClient.health(),
	(error) => error instanceof Error && error.code === 'PERMISSION_DENIED' && error.message === 'Denied');

replies.set('operation_get', { operation: { id: 'op_1', state: 'running' } });
let watched = 0;
const cancelClient = moduleApi.create();
const cancel = cancelClient.watchOperation('op_1', () => watched++);
await new Promise((resolve) => setImmediate(resolve));
assert.equal(watched, 1);
assert.equal(scheduled.size, 1);
cancel();
assert.equal(scheduled.size, 0, 'subscription cancellation must clear its pending poll');

let uploaded = Buffer.alloc(0), uploadSeq = 0;
replies.set('transfer_begin', (direction, kind) => direction === 'upload'
	? { transfer_id: 'a'.repeat(64), chunk_size: 4, expires_at: 1 }
	: { transfer_id: 'b'.repeat(64), chunk_size: 4, size: 10,
		sha256: 'b'.repeat(64), expires_at: 1 });
replies.set('transfer_write', (id, seq, data) => {
	assert.equal(seq, uploadSeq++);
	uploaded = Buffer.concat([uploaded, Buffer.from(data, 'base64')]);
	return { next_seq: uploadSeq, received: uploaded.length };
});
replies.set('transfer_finish', { completed: true });
replies.set('transfer_abort', { aborted: true });
const transferClient = moduleApi.create();
await transferClient.uploadChunks('backup', { secrets: false }, new TextEncoder().encode('hello world'));
assert.equal(uploaded.toString(), 'hello world');
replies.set('transfer_begin', { transfer_id: 'a'.repeat(64), chunk_size: Number.NaN, expires_at: 1 });
await assert.rejects(transferClient.uploadChunks('backup', {}, new Uint8Array([1])),
	(error) => error.code === 'INVALID_RESPONSE');

const downloadBytes = Buffer.from('diagnostic');
const downloadHash = Buffer.from(await webcrypto.subtle.digest('SHA-256', downloadBytes)).toString('hex');
let readOffset = 0;
replies.set('transfer_begin', { transfer_id: 'b'.repeat(64), chunk_size: 4,
	size: downloadBytes.length, sha256: downloadHash, expires_at: 1 });
replies.set('transfer_read', (id, seq) => {
	const chunk = downloadBytes.subarray(readOffset, readOffset + 4);
	readOffset += chunk.length;
	return { seq, next_seq: seq + 1, data: chunk.toString('base64'), eof: readOffset === downloadBytes.length };
});
const downloadedBytes = await transferClient.downloadChunks('report', 'rpt_' + 'c'.repeat(32),
	{ format: 'text' });
assert.equal(Buffer.from(downloadedBytes).toString(), 'diagnostic');
assert.equal(calls.filter((call) => call.method === 'transfer_read').length, 3,
	'download must use exactly ceil(size/chunk_size) reads');

// Destroying a view aborts already-begun transfers through the raw declaration,
// even though public wrappers reject after destroy.
let releaseWrite;
replies.set('transfer_begin', { transfer_id: 'd'.repeat(64), chunk_size: 4, expires_at: 1 });
replies.set('transfer_write', () => new Promise((resolve) => { releaseWrite = resolve; }));
const destroyTransferClient = moduleApi.create();
const pendingUpload = destroyTransferClient.uploadChunks('backup', {}, new Uint8Array([1, 2, 3]));
while (!releaseWrite) await new Promise((resolve) => setImmediate(resolve));
const abortsBeforeDestroy = calls.filter((call) => call.method === 'transfer_abort').length;
destroyTransferClient.destroy();
await new Promise((resolve) => setImmediate(resolve));
assert.ok(calls.filter((call) => call.method === 'transfer_abort').length > abortsBeforeDestroy,
	'destroy did not best-effort abort its active transfer');
releaseWrite({ next_seq: 1, received: 3 });
await assert.rejects(pendingUpload, (error) => error.code === 'CANCELLED');

let releaseBegin;
replies.set('transfer_begin', () => new Promise((resolve) => { releaseBegin = resolve; }));
const destroyBeginClient = moduleApi.create();
const pendingBegin = destroyBeginClient.uploadChunks('backup', {}, new Uint8Array([9]));
while (!releaseBegin) await new Promise((resolve) => setImmediate(resolve));
destroyBeginClient.destroy();
const abortsBeforeBeginRelease = calls.filter((call) => call.method === 'transfer_abort').length;
releaseBegin({ transfer_id: '2'.repeat(64), chunk_size: 4, expires_at: 1 });
await assert.rejects(pendingBegin, (error) => error.code === 'CANCELLED');
assert.ok(calls.filter((call) => call.method === 'transfer_abort').length > abortsBeforeBeginRelease,
	'destroy during transfer_begin leaked the returned transfer authority');

async function expectDownloadAbort(beginReply, readHandler, predicate) {
	const before = calls.filter((call) => call.method === 'transfer_abort').length;
	replies.set('transfer_begin', beginReply);
	replies.set('transfer_read', readHandler);
	const value = moduleApi.create().downloadChunks('report', 'rpt_' + 'e'.repeat(32), {});
	await assert.rejects(value, predicate);
	assert.ok(calls.filter((call) => call.method === 'transfer_abort').length > before,
		'failed download did not abort');
}
await expectDownloadAbort({ transfer_id: 'BAD', chunk_size: 4, size: 1, sha256: 'a'.repeat(64) },
	() => ({}), (error) => error.code === 'INVALID_RESPONSE');
for (const chunkSize of [0, 1.5, 49153])
	await expectDownloadAbort({ transfer_id: 'e'.repeat(64), chunk_size: chunkSize,
		size: 1, sha256: 'a'.repeat(64) }, () => ({}),
		(error) => error.code === 'INVALID_RESPONSE');
await expectDownloadAbort({ transfer_id: 'e'.repeat(64), chunk_size: 4,
	size: 5, sha256: 'a'.repeat(64) },
	(id, seq) => ({ seq, next_seq: seq + 1, data: Buffer.from('x').toString('base64'), eof: false }),
	(error) => error.code === 'INVALID_RESPONSE');
await expectDownloadAbort({ transfer_id: 'e'.repeat(64), chunk_size: 4,
	size: 1, sha256: 'a'.repeat(64) },
	(id, seq) => ({ seq, next_seq: seq + 1, data: 'YQ===', eof: true }),
	(error) => error.code === 'INVALID_RESPONSE');
await expectDownloadAbort({ transfer_id: 'e'.repeat(64), chunk_size: 4,
	size: 1, sha256: 'a'.repeat(64) },
	(id, seq) => ({ seq: seq + 1, next_seq: seq + 1,
		data: Buffer.from('x').toString('base64'), eof: true }),
	(error) => error.code === 'INVALID_RESPONSE');
await expectDownloadAbort({ transfer_id: 'e'.repeat(64), chunk_size: 4,
	size: 1, sha256: 'a'.repeat(64) },
	(id, seq) => ({ seq, next_seq: seq + 1,
		data: Buffer.from('x').toString('base64'), eof: false }),
	(error) => error.code === 'INVALID_RESPONSE');
await expectDownloadAbort({ transfer_id: 'e'.repeat(64), chunk_size: 4,
	size: 1, sha256: 'a'.repeat(64) },
	(id, seq) => ({ seq, next_seq: seq + 1,
		data: Buffer.from('x').toString('base64'), eof: true }),
	(error) => error.code === 'VALIDATION_FAILED');

let releaseRead;
replies.set('transfer_begin', { transfer_id: '1'.repeat(64), chunk_size: 4, size: 1,
	sha256: 'a'.repeat(64) });
replies.set('transfer_read', () => new Promise((resolve) => { releaseRead = resolve; }));
const destroyDownloadClient = moduleApi.create();
const pendingDownload = destroyDownloadClient.downloadChunks('report', 'rpt_' + '1'.repeat(32), {});
while (!releaseRead) await new Promise((resolve) => setImmediate(resolve));
const abortsBeforeDownloadDestroy = calls.filter((call) => call.method === 'transfer_abort').length;
destroyDownloadClient.destroy();
await new Promise((resolve) => setImmediate(resolve));
assert.ok(calls.filter((call) => call.method === 'transfer_abort').length > abortsBeforeDownloadDestroy,
	'destroy did not abort an active download');
releaseRead({ seq: 0, next_seq: 1, data: Buffer.from('x').toString('base64'), eof: true });
await assert.rejects(pendingDownload, (error) => error.code === 'CANCELLED');
let zeroReads = 0;
replies.set('transfer_begin', { transfer_id: 'f'.repeat(64), chunk_size: 4, size: 0,
	sha256: Buffer.from(await webcrypto.subtle.digest('SHA-256', new Uint8Array())).toString('hex') });
replies.set('transfer_read', () => { zeroReads++; return {}; });
replies.set('transfer_finish', { completed: true });
await moduleApi.create().downloadChunks('report', 'rpt_' + 'f'.repeat(32), {});
assert.equal(zeroReads, 0, 'zero-sized download must finalize without a read');

const destroyClient = moduleApi.create();
destroyClient.watchOperation('op_1', () => {});
await new Promise((resolve) => setImmediate(resolve));
assert.equal(scheduled.size, 1);
destroyClient.destroy();
assert.equal(scheduled.size, 0, 'view destruction must clear every pending poll');
console.log(`typed MiClash ubus UI check passed (${names.length} methods)`);
