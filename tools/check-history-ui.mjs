import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';

const panelPath = 'luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/history-panel.js';
const configPath = 'luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/config.js';
const editorPath = 'luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/editor.js';
const cssPath = 'luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/style.css';

assert.ok(existsSync(panelPath), `missing history panel: ${panelPath}`);
const panel = readFileSync(panelPath, 'utf8');
const config = readFileSync(configPath, 'utf8');
const editor = readFileSync(editorPath, 'utf8');
const css = readFileSync(cssPath, 'utf8');

assert.doesNotMatch(panel, /(?:innerHTML|outerHTML|insertAdjacentHTML|document\.write)/,
	'history and diff data must only be rendered as text DOM');
assert.doesNotMatch(panel, /(?:fs\.|exec\s*\(|\/bin\/sh|\/usr\/bin\/|\/sbin\/)/,
	'history panel must use only the typed ubus API');
for (const token of ['historyList', 'historyDiff', 'historyOpenDraft', 'historyRestore',
	'watchOperation', 'Open in editor', 'Restore', 'Close', 'Configuration history', 'source'])
	assert.match(panel, new RegExp(token), `history panel missing ${token}`);
for (const token of ['Draft', 'Validate', 'Apply', 'History'])
	assert.match(config, new RegExp(token), `configuration UI missing ${token}`);
assert.match(editor, /config_validate/);
assert.match(editor, /config_apply/);
assert.match(config, /draftActions\.save\(editor\.getValue\(\)\)/);
assert.match(config, /destroyConfigDraftRuntime/);
assert.match(config, /const createdHistoryPanel = [\s\S]*historyPanel = createdHistoryPanel/,
	'history callbacks do not capture the exact panel instance');
assert.match(config, /historyPanel !== owner \|\| !owner\.owns\(token\)/,
	'history callbacks lack exact panel identity and modal generation ownership');
assert.match(config, /historyPanel === owner && owner\.owns\(token\)/,
	'late Restore refresh lacks post-RPC history ownership check');
assert.match(config, /adoptRouterDraft\(token\.profile, content, record\?\.revision\)/,
	'Open revision does not adopt the confirmed Router Draft baseline');
assert.match(config, /Active configuration changed; Draft preserved\./);
const subscriptionBlock = config.slice(config.indexOf("const updateUrlBtn ="), config.indexOf("const clearUrlBtn ="));
assert.doesNotMatch(subscriptionBlock, /freshConfig[\s\S]{0,300}editor\.setValue/,
	'subscription success must not silently replace Draft editor content');
assert.match(editor, /localStorage/);
assert.match(editor, /draft/i);
assert.match(css, /sbox-history-layout/);
assert.match(css, /@media[\s\S]*max-width:[\s\S]*sbox-history-layout/);

class MiniNode {
	constructor(tag, attrs = {}) {
		this.tagName = String(tag).toUpperCase(); this.attrs = {}; this.children = [];
		this.listeners = new Map(); this.parentNode = null; this.disabled = false; this._text = '';
		for (const [name, value] of Object.entries(attrs || {})) this.setAttribute(name, value);
	}
	set textContent(value) { this._text = String(value ?? ''); this.children = []; }
	get textContent() { return this._text + this.children.map((node) =>
		typeof node === 'string' ? node : node.textContent).join(''); }
	setAttribute(name, value) { this.attrs[name] = String(value); }
	getAttribute(name) { return this.attrs[name] ?? null; }
	appendChild(node) { if (typeof node !== 'string') node.parentNode = this; this.children.push(node); return node; }
	replaceChildren(...nodes) { this.children = []; this._text = ''; for (const node of nodes) this.appendChild(node); }
	addEventListener(type, callback) { if (!this.listeners.has(type)) this.listeners.set(type, []); this.listeners.get(type).push(callback); }
	removeEventListener(type, callback) { this.listeners.set(type, (this.listeners.get(type) || []).filter((item) => item !== callback)); }
	click() { for (const callback of this.listeners.get('click') || []) callback({ type: 'click', target: this }); }
	matches(selector) {
		if (selector.startsWith('.')) return (this.getAttribute('class') || '').split(/\s+/).includes(selector.slice(1));
		const attr = selector.match(/^\[([^=\]]+)(?:="([^"]*)")?\]$/);
		if (attr) return this.getAttribute(attr[1]) != null && (attr[2] == null || this.getAttribute(attr[1]) === attr[2]);
		return this.tagName === selector.toUpperCase();
	}
	querySelectorAll(selector) { const found = []; for (const node of this.children) if (typeof node !== 'string') {
		if (node.matches(selector)) found.push(node); found.push(...node.querySelectorAll(selector)); } return found; }
	querySelector(selector) { return this.querySelectorAll(selector)[0] || null; }
}
const E = (tag, attrs, children) => {
	const node = new MiniNode(tag, attrs || {});
	for (const child of (Array.isArray(children) ? children : [children]).flat(Infinity))
		if (child != null) node.appendChild(typeof child === 'number' ? String(child) : child);
	return node;
};
const _ = (value) => String(value);
const modalCalls = [];
const ui = { showModal(title, body) { modalCalls.push({ title, body }); }, hideModal() { modalCalls.push({ hidden: true }); } };
const historyModule = new Function('baseclass', 'ui', 'E', '_', panel)(
	{ extend: (value) => value }, ui, E, _);
const calls = [];
const revisions = [
	{ revision: '0000000000001-aaaaaaaaaaaaaaaa', timestamp: 1, source: '<img src=x onerror=alert(1)>', validation_result: 'success' },
	{ revision: '0000000000002-bbbbbbbbbbbbbbbb', timestamp: 2, source: 'manual', validation_result: 'success', activation_result: 'success' },
	{ revision: 'corrupt', timestamp: 3, source: 'system', corrupt: true }
];
const api = {
	async historyList(...args) { calls.push(['historyList', ...args]); return revisions; },
	async historyDiff(...args) { calls.push(['historyDiff', ...args]); return { changed: true, text: '<img src=x onerror=alert(1)>\n-old\n+new' }; },
	async historyOpenDraft(...args) { calls.push(['historyOpenDraft', ...args]); return { operation_id: 'open-1' }; },
	async historyRestore(...args) { calls.push(['historyRestore', ...args]); return { operation_id: 'restore-1' }; },
	async configReadDraft(...args) { calls.push(['configReadDraft', ...args]); return { content: 'opened Draft\n' }; },
	watchOperation(id, callback) { setImmediate(() => callback({ id, state: 'success' })); return () => {}; }
};
let openedDraft = null, restores = 0;
const history = historyModule.create({ api, profile: 'config.yaml',
	onDraft(content) { openedDraft = content; }, onRestored() { restores++; } });
const modalBody = await history.open('config.yaml');
assert.equal(modalCalls[0].title, 'Configuration history');
assert.ok(modalBody.querySelector('[data-action="close-history"]'), 'history modal lacks accessible Close action');
assert.equal(calls[0][0], 'historyList');
const items = modalBody.querySelectorAll('.sbox-history-item');
assert.equal(items.length, 3);
assert.equal(items[0].getAttribute('data-revision'), '0000000000002-bbbbbbbbbbbbbbbb',
	'ascending domain history was not normalized newest-first');
assert.match(modalBody.textContent, /Unknown source/);
assert.equal(modalBody.querySelector('img'), null, 'malicious history metadata created an element');
items[1].click(); await new Promise((resolve) => setImmediate(resolve));
assert.deepEqual(calls.find((call) => call[0] === 'historyDiff'),
	['historyDiff', 'config.yaml', '0000000000001-aaaaaaaaaaaaaaaa', '0000000000002-bbbbbbbbbbbbbbbb']);
assert.equal(modalBody.querySelector('img'), null, 'malicious diff created an element');
modalBody.querySelector('[data-action="open-draft"]').click();
await new Promise((resolve) => setImmediate(resolve)); await new Promise((resolve) => setImmediate(resolve));
assert.deepEqual(calls.find((call) => call[0] === 'historyOpenDraft'),
	['historyOpenDraft', 'config.yaml', '0000000000001-aaaaaaaaaaaaaaaa', 'luci']);
assert.equal(openedDraft, 'opened Draft\n', 'open revision must update Draft callback only');
modalBody.querySelector('[data-action="restore"]').click();
await new Promise((resolve) => setImmediate(resolve)); await new Promise((resolve) => setImmediate(resolve));
assert.deepEqual(calls.find((call) => call[0] === 'historyRestore'),
	['historyRestore', 'config.yaml', '0000000000001-aaaaaaaaaaaaaaaa', 'luci']);
assert.equal(restores, 1, 'manual restore did not refresh Active owner');
assert.equal(calls.filter((call) => call[0] === 'historyRestore').length, 1,
	'restore must use the existing modal action without a second token/confirmation call');
const currentItems = modalBody.querySelectorAll('.sbox-history-item');
currentItems.at(-1).click(); await new Promise((resolve) => setImmediate(resolve));
assert.match(modalBody.textContent, /Corrupt revision/);
assert.equal(modalBody.querySelector('[data-action="open-draft"]'), null,
	'corrupt revision exposed Open Draft action');
assert.equal(modalBody.querySelector('[data-action="restore"]'), null,
	'corrupt revision exposed Restore action');

let releaseOldOpen, lateDrafts = 0, raceRestoreCalls = 0;
const raceApi = {
	async historyList() { return [revisions[1]]; },
	async historyDiff() { return { text: '' }; },
	historyOpenDraft() { return new Promise((resolve) => { releaseOldOpen = resolve; }); },
	async historyRestore() { raceRestoreCalls++; return { operation_id: 'race-restore' }; },
	async configReadDraft() { return { content: 'A late Draft\n' }; },
	watchOperation(id, callback) { callback({ id, state: 'success' }); return () => {}; }
};
const raceHistory = historyModule.create({ api: raceApi, profile: 'config.yaml', onDraft() { lateDrafts++; } });
const raceBody = await raceHistory.open('config.yaml');
raceBody.querySelector('[data-action="open-draft"]').click();
raceBody.querySelector('[data-action="restore"]').click();
assert.equal(raceRestoreCalls, 0, 'history mutations were not mutually exclusive');
raceHistory.invalidate('config2.yaml');
releaseOldOpen({ operation_id: 'old-open' });
await new Promise((resolve) => setImmediate(resolve)); await new Promise((resolve) => setImmediate(resolve));
assert.equal(lateDrafts, 0, 'late Open Draft reply mutated a different profile/editor generation');
raceHistory.destroy();
let pendingCallback = null, pendingCancelled = 0, pendingRestored = 0;
const pendingApi = {
	async historyList() { return [revisions[1]]; }, async historyDiff() { return { text: '' }; },
	async historyOpenDraft() { return { operation_id: 'pending-open' }; },
	async historyRestore() { return { operation_id: 'pending-restore' }; },
	async configReadDraft() { return { content: 'too late\n' }; },
	watchOperation(id, callback) { pendingCallback = callback; return () => { pendingCancelled++; }; }
};
const pendingHistory = historyModule.create({ api: pendingApi, onDraft() { pendingRestored++; } });
const pendingBody = await pendingHistory.open('config.yaml');
pendingBody.querySelector('[data-action="open-draft"]').click();
await new Promise((resolve) => setImmediate(resolve));
const hiddenBeforeClose = modalCalls.filter((entry) => entry.hidden).length;
pendingBody.querySelector('[data-action="close-history"]').click();
assert.equal(modalCalls.filter((entry) => entry.hidden).length, hiddenBeforeClose + 1,
	'Close did not dismiss history modal');
assert.equal(pendingCancelled, 1, 'Close did not cancel the owned history UI watcher');
pendingCallback({ id: 'pending-open', state: 'success' });
await new Promise((resolve) => setImmediate(resolve));
assert.equal(pendingRestored, 0, 'late watcher completion mutated closed history/editor state');
const reopenedPending = await pendingHistory.open('config.yaml');
assert.ok(reopenedPending.querySelector('[data-action="open-draft"]'), 'history modal did not reopen cleanly');
pendingHistory.destroy();
let failedRestoreCallbacks = 0, preservedDraftMarker = 'exact Draft before restore';
const restoreFailureApi = {
	async historyList() { return [revisions[1]]; }, async historyDiff() { return { text: '' }; },
	async historyOpenDraft() { return { operation_id: 'unused' }; },
	async historyRestore() { return { operation_id: 'restore-failure' }; },
	async configReadDraft() { return { content: preservedDraftMarker }; },
	watchOperation(id, callback) {
		callback({ id, state: 'failure', error: { code: 'HEALTH_FAILED', message: 'restore failed' } });
		return () => {};
	}
};
const restoreFailure = historyModule.create({ api: restoreFailureApi,
	onRestored() { failedRestoreCallbacks++; preservedDraftMarker = 'changed'; } });
const restoreFailureBody = await restoreFailure.open('config.yaml');
restoreFailureBody.querySelector('[data-action="restore"]').click();
await new Promise((resolve) => setImmediate(resolve));
assert.equal(failedRestoreCallbacks, 0, 'failed restore invoked Active/Draft refresh callback');
assert.equal(preservedDraftMarker, 'exact Draft before restore', 'failed restore changed Draft content');
restoreFailure.destroy();

const storageData = new Map();
const storage = { get length() { return storageData.size; }, key(index) { return [...storageData.keys()][index] || null; },
	getItem(key) { return storageData.get(key) ?? null; }, setItem(key, value) { storageData.set(key, value); }, removeItem(key) { storageData.delete(key); } };
const windowMock = { localStorage: storage, setTimeout, clearTimeout };
const L = { Class: { extend(value) { return value; } }, resource(value) { return value; } };
const editorModule = new Function('L', 'E', 'window', 'document', editor)(L, E, windowMock, { head: new MiniNode('head') });
assert.equal(typeof editorModule.createDraftLoadCoordinator, 'function', 'missing stale-load ownership coordinator');
let loadRuntime = { generation: 1, api: {}, controller: {}, editor: {}, selectedProfile: 'config.yaml' };
let releaseLoad, staleCommits = 0;
const loadCoordinator = editorModule.createDraftLoadCoordinator(() => loadRuntime);
const staleLoad = loadCoordinator.load('config.yaml', () => new Promise((resolve) => { releaseLoad = resolve; }),
	() => { staleCommits++; });
loadRuntime = { generation: 2, api: {}, controller: {}, editor: {}, selectedProfile: 'config2.yaml' };
releaseLoad({ active: { content: 'A' }, draft: { content: 'A draft' } });
assert.equal((await staleLoad).stale, true);
assert.equal(staleCommits, 0, 'late Restore A committed into replacement runtime B');
let currentCommits = 0;
const currentLoad = await loadCoordinator.load('config2.yaml', async () => ({ active: { content: 'B' } }),
	() => { currentCommits++; return 'B committed'; });
assert.deepEqual(currentLoad, { stale: false, value: 'B committed' });
assert.equal(currentCommits, 1, 'replacement runtime could not perform its own current Draft load');
let releaseOverlapped, overlappedCommits = [];
const overlapped = loadCoordinator.load('config2.yaml', () => new Promise((resolve) => { releaseOverlapped = resolve; }),
	(captured, replies, profile) => { overlappedCommits.push(profile); });
const latest = await loadCoordinator.load('config3.yaml', async () => ({}),
	(captured, replies, profile) => { overlappedCommits.push(profile); });
assert.equal(latest.stale, false);
releaseOverlapped({});
assert.equal((await overlapped).stale, true, 'older same-runtime profile load retained commit ownership');
assert.deepEqual(overlappedCommits, ['config3.yaml'], 'overlapped profile load committed stale Draft bytes');
const lifecycle = editorModule.createLifecycleOwner();
let lifecycleDestroys = 0;
lifecycle.replace({ destroy() { lifecycleDestroys++; } });
lifecycle.replace({ destroy() { lifecycleDestroys++; } });
assert.equal(lifecycleDestroys, 1, 'rerender did not destroy the prior Draft runtime exactly once');
lifecycle.destroy(); lifecycle.destroy();
assert.equal(lifecycleDestroys, 2, 'unload lifecycle was not idempotent');
const draft = editorModule.createDraftController({ storage, profile: 'config.yaml', content: 'router\n', debounceMs: 250 });
let saves = 0;
const draftApi = { async configSaveDraft(profile, content, source) { saves++; calls.push(['configSaveDraft', profile, content, source]); return { operation_id: 'save-1' }; } };
assert.equal((await draft.saveRouter(draftApi, 'router\n')).changed, false, 'unchanged Draft caused flash write');
draft.setContent('local\n'); draft.flushLocal();
const acceptedDraft = await draft.saveRouter(draftApi, 'changed\n');
assert.equal(acceptedDraft.changed, true);
assert.equal(saves, 1);
assert.equal((await draft.saveRouter(draftApi, 'changed\n')).changed, true,
	'failed/unconfirmed Draft operation was incorrectly treated as persisted');
assert.equal(saves, 2);
assert.equal(draft.confirmRouterSaved(acceptedDraft), true);
assert.equal((await draft.saveRouter(draftApi, 'changed\n')).changed, false);
let adoptedTimers = 0, adoptedSaves = 0, adoptedValidations = 0;
const adoptedController = editorModule.createDraftController({ storage, profile: 'adopt.yaml',
	content: 'old Router Draft\n', routerContent: 'old Router Draft\n',
	setTimeout() { adoptedTimers++; return adoptedTimers; }, clearTimeout() {} });
assert.equal(adoptedController.adoptRouterDraft('wrong.yaml', 'must not adopt\n', 'wrong-revision'), false,
	'profile mismatch adopted another profile Router Draft');
assert.equal(adoptedController.getContent(), 'old Router Draft\n');
assert.equal(adoptedController.adoptRouterDraft('adopt.yaml', 'opened exact bytes\n', 'opened-revision'), true);
assert.equal(adoptedTimers, 0, 'adopting a confirmed Router Draft scheduled an extra local/flash write');
const adoptedApi = {
	async configSaveDraft() { adoptedSaves++; return { operation_id: 'redundant-save' }; },
	async config_validate(profile, content) {
		adoptedValidations++; assert.equal(content, 'opened exact bytes\n');
		return { operation_id: 'adopt-validate' };
	},
	watchOperation(id, callback) { callback({ id, state: 'success', percent: 100 }); return () => {}; }
};
assert.equal((await adoptedController.saveRouter(adoptedApi, 'opened exact bytes\n')).changed, false,
	'unchanged navigation after Open revision caused an additional Router Draft save');
const adoptedActions = editorModule.createDraftActions({ api: adoptedApi, controller: adoptedController,
	getProfile: () => 'adopt.yaml', getContent: () => 'opened exact bytes\n' });
await adoptedActions.validate();
assert.equal(adoptedValidations, 1);
assert.equal(adoptedSaves, 0, 'Validate preliminary save rewrote the just-opened Router Draft');
const originalCrashBytes = storage.getItem('miclash-draft-v1:config.yaml');
const routerDraft = editorModule.createDraftController({ storage, profile: 'config.yaml', content: 'router\n' });
const loaded = await routerDraft.load('config.yaml', { content: 'active\n', revision: 'active-1' },
	{ content: 'router newer\n', revision: 'draft-2' });
assert.equal(loaded.conflict, true, 'different crash copy was silently overwritten');
assert.equal(routerDraft.adoptRouterDraft('config.yaml', 'opened during conflict\n', 'conflict-revision'), false,
	'unresolved crash-copy conflict adopted a new Router Draft baseline');
assert.equal(storage.getItem('miclash-draft-v1:config.yaml'), originalCrashBytes,
	'failed conflict adoption deleted or replaced the original crash copy');
assert.equal(loaded.content, 'router newer\n', 'router Draft must remain selected until explicit user choice');
routerDraft.setContent('router newer\n');
await new Promise((resolve) => setTimeout(resolve, 300));
assert.equal(storage.getItem('miclash-draft-v1:config.yaml'), originalCrashBytes,
	'pending conflict overwrote the original crash copy before user choice');
assert.equal(routerDraft.useCrashCopy(loaded.crash), 'changed\n');
storage.setItem('miclash-draft-v1:config2.yaml', JSON.stringify({ version: 1, profile: 'config2.yaml',
	revision: 'old', content: 'local choice\n', hash: editorModule.contentHash('local choice\n'), savedAt: 1 }));
const keepController = editorModule.createDraftController({ storage, profile: 'config2.yaml', content: 'active\n', debounceMs: 250 });
const keepLoaded = await keepController.load('config2.yaml', { content: 'active\n' }, { content: 'router choice\n' });
assert.equal(keepLoaded.conflict, true);
assert.equal(keepController.keepRouterCopy(), true);
await new Promise((resolve) => setTimeout(resolve, 300));
assert.equal(JSON.parse(storage.getItem('miclash-draft-v1:config2.yaml')).content, 'router choice\n',
	'Keep router choice did not deterministically replace the local crash copy');
const collisionController = editorModule.createDraftController({ storage, profile: 'config2.yaml',
	content: 'e703069b9c915dd3' });
let collisionSaves = 0;
const collisionReply = await collisionController.saveRouter({ async configSaveDraft() {
	collisionSaves++; return { operation_id: 'collision-save' };
} }, '121ffc58fd88877d');
assert.equal(collisionReply.changed, true, 'hash collision incorrectly suppressed exact-byte Draft save');
assert.equal(collisionSaves, 1);
const brokenStorage = { length: 0, key() { throw new Error('denied'); }, getItem() { throw new Error('denied'); },
	setItem() { throw new Error('denied'); }, removeItem() { throw new Error('denied'); } };
const noDraftController = editorModule.createDraftController({ storage: brokenStorage, profile: 'config3.yaml',
	content: 'same as Active\n' });
noDraftController.load('config3.yaml', { content: 'same as Active\n' }, { content: null });
let noDraftSaves = 0;
const noDraftSaved = await noDraftController.saveRouter({ async configSaveDraft(profile, content) {
	noDraftSaves++; assert.equal(content, 'same as Active\n'); return { operation_id: 'first-durable-draft' };
} }, 'same as Active\n');
assert.equal(noDraftSaved.changed, true, 'missing Router Draft file suppressed first durable save');
assert.equal(noDraftSaves, 1);
const runMissingDraft = async (failMutation) => {
	const sequence = [];
	const controller = editorModule.createDraftController({ storage: brokenStorage,
		profile: 'missing.yaml', content: 'same as Active\n' });
	controller.load('missing.yaml', { content: 'same as Active\n' }, { content: null });
	let saveCalls = 0;
	const actions = editorModule.createDraftActions({ controller,
		getProfile: () => 'missing.yaml', getContent: () => 'same as Active\n', api: {
			async configSaveDraft(profile, content) {
				saveCalls++; sequence.push('save'); assert.equal(content, 'same as Active\n');
				return { operation_id: 'save-missing' };
			},
			watchOperation(id, callback) { callback({ id, state: 'success', percent: 100 }); return () => {}; }
		} });
	const operation = actions.runExternal(async () => {
		sequence.push('mutation');
		if (failMutation) throw new Error('subscription failed');
	});
	if (failMutation) await assert.rejects(operation, /subscription failed/); else await operation;
	assert.deepEqual(sequence, ['save', 'mutation'], 'subscription mutation ran before first durable Router Draft save');
	assert.equal(saveCalls, 1, 'missing Router Draft was not saved exactly once before subscription mutation');
	assert.equal(controller.routerDraftExists(), true, 'confirmed Router Draft existence was not retained');
	controller.destroy();
};
await runMissingDraft(false);
await runMissingDraft(true);
const isolated = editorModule.createDraftController({ storage: brokenStorage, profile: 'config2.yaml', content: 'safe\n' });
assert.equal(isolated.flushLocal(), false, 'storage exception was not isolated');
const exactFailedContent = 'rules:\n  - MATCH,DIRECT  # keep exact bytes\n';
const failedController = editorModule.createDraftController({ storage, profile: 'config3.yaml', content: exactFailedContent });
let applyCalls = 0;
const failedApi = {
	async configSaveDraft() { return { operation_id: 'save-ok' }; },
	async config_validate(profile, content, source) {
		assert.equal(content, exactFailedContent); return { operation_id: 'validate-fail' };
	},
	async config_apply() { applyCalls++; return { operation_id: 'must-not-run' }; },
	async config_read() { throw new Error('must not read Active after failed validation'); },
	watchOperation(id, callback) {
		setImmediate(() => {
			callback({ id, state: 'running', percent: 175, stage: 'x'.repeat(200) });
			callback(id === 'validate-fail'
				? { id, state: 'failure', error: { code: 'VALIDATION_FAILED', message: 'bad yaml' } }
				: { id, state: 'success', percent: 100, stage: 'done' });
		});
		return () => {};
	}
};
const failedActions = editorModule.createDraftActions({ api: failedApi, controller: failedController,
	getProfile: () => 'config3.yaml', getContent: () => exactFailedContent,
	onProgress(update) { calls.push(['progress', update.phase, update.percent, update.stage]); } });
await assert.rejects(failedActions.validate(), (error) => error.code === 'VALIDATION_FAILED');
assert.equal(applyCalls, 0, 'config_apply ran after validation failure');
assert.equal(failedController.getContent(), exactFailedContent,
	'failed validation changed exact editor/Draft content');
failedController.flushLocal();
const failedCrash = JSON.parse(storage.getItem('miclash-draft-v1:config3.yaml'));
assert.equal(failedCrash.content, exactFailedContent, 'failed validation changed local crash copy');
assert.ok(calls.some((call) => call[0] === 'progress'), 'Draft actions did not expose progress updates');
for (const call of calls.filter((item) => item[0] === 'progress')) {
	assert.ok(call[2] >= 0 && call[2] <= 100, 'progress percent is unbounded');
	assert.ok(String(call[3]).length <= 80, 'progress stage is unbounded');
}
let externalActive = 'old active\n';
await failedActions.runExternal(async ({ profile, content }) => {
	assert.equal(failedActions.isBusy(), true);
	await assert.rejects(failedActions.validate(), (error) => error.code === 'BUSY');
	externalActive = 'subscription active\n';
	assert.equal(content, exactFailedContent); assert.equal(profile, 'config3.yaml');
});
assert.equal(externalActive, 'subscription active\n');
assert.equal(failedController.getContent(), exactFailedContent,
	'subscription success silently replaced exact Draft content');
await assert.rejects(failedActions.runExternal(async () => { throw new Error('download failed'); }), /download failed/);
assert.equal(failedController.getContent(), exactFailedContent,
	'subscription failure changed exact Draft content');
let applyValidateCalls = 0, successfulApplyCalls = 0;
const applyController = editorModule.createDraftController({ storage, profile: 'config.yaml', content: 'apply exact\n' });
const applyActions = editorModule.createDraftActions({ controller: applyController,
	getProfile: () => 'config.yaml', getContent: () => 'apply exact\n', api: {
		async configSaveDraft() { return { operation_id: 'save-apply' }; },
		async config_validate() { applyValidateCalls++; return { operation_id: 'redundant' }; },
		async config_apply() { successfulApplyCalls++; return { operation_id: 'apply-success' }; },
		async config_read() { return { content: 'apply exact\n' }; },
		watchOperation(id, callback) { callback({ id, state: 'success', percent: 100, stage: 'done' }); return () => {}; }
	} });
await applyActions.apply();
assert.equal(applyValidateCalls, 0, 'Apply redundantly called config_validate before backend config_apply');
assert.equal(successfulApplyCalls, 1);
applyController.destroy(); adoptedController.destroy();
failedController.destroy(); collisionController.destroy(); keepController.destroy(); isolated.destroy(); routerDraft.destroy(); draft.destroy(); history.destroy();

console.log('Draft and configuration history UI contract passed');
