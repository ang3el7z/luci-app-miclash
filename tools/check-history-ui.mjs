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
	'watchOperation', 'Open in editor', 'Restore', 'Configuration history', 'source'])
	assert.match(panel, new RegExp(token), `history panel missing ${token}`);
for (const token of ['Draft', 'Validate', 'Apply', 'History'])
	assert.match(config, new RegExp(token), `configuration UI missing ${token}`);
assert.match(editor, /config_validate/);
assert.match(editor, /config_apply/);
assert.match(config, /draftActions\.save\(editor\.getValue\(\)\)/);
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
const historyModule = new Function('ui', 'E', '_', panel)(ui, E, _);
const calls = [];
const revisions = [
	{ revision: 'newest', timestamp: 2, source: 'manual', validation_result: 'success', activation_result: 'success' },
	{ revision: 'older', timestamp: 1, source: '<img src=x onerror=alert(1)>', validation_result: 'success' }
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
assert.equal(calls[0][0], 'historyList');
const items = modalBody.querySelectorAll('.sbox-history-item');
assert.equal(items.length, 2);
assert.match(modalBody.textContent, /<img src=x onerror=alert\(1\)>/);
assert.equal(modalBody.querySelector('img'), null, 'malicious history metadata created an element');
items[1].click(); await new Promise((resolve) => setImmediate(resolve));
assert.deepEqual(calls.find((call) => call[0] === 'historyDiff'),
	['historyDiff', 'config.yaml', 'older', 'newest']);
assert.equal(modalBody.querySelector('img'), null, 'malicious diff created an element');
modalBody.querySelector('[data-action="open-draft"]').click();
await new Promise((resolve) => setImmediate(resolve)); await new Promise((resolve) => setImmediate(resolve));
assert.deepEqual(calls.find((call) => call[0] === 'historyOpenDraft'),
	['historyOpenDraft', 'config.yaml', 'older', 'luci']);
assert.equal(openedDraft, 'opened Draft\n', 'open revision must update Draft callback only');
modalBody.querySelector('[data-action="restore"]').click();
await new Promise((resolve) => setImmediate(resolve)); await new Promise((resolve) => setImmediate(resolve));
assert.deepEqual(calls.find((call) => call[0] === 'historyRestore'),
	['historyRestore', 'config.yaml', 'older', 'luci']);
assert.equal(restores, 1, 'manual restore did not refresh Active owner');
assert.equal(calls.filter((call) => call[0] === 'historyRestore').length, 1,
	'restore must use the existing modal action without a second token/confirmation call');

const storageData = new Map();
const storage = { get length() { return storageData.size; }, key(index) { return [...storageData.keys()][index] || null; },
	getItem(key) { return storageData.get(key) ?? null; }, setItem(key, value) { storageData.set(key, value); }, removeItem(key) { storageData.delete(key); } };
const windowMock = { localStorage: storage, setTimeout, clearTimeout };
const L = { Class: { extend(value) { return value; } }, resource(value) { return value; } };
const editorModule = new Function('L', 'E', 'window', 'document', editor)(L, E, windowMock, { head: new MiniNode('head') });
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
const routerDraft = editorModule.createDraftController({ storage, profile: 'config.yaml', content: 'router\n' });
const loaded = await routerDraft.load('config.yaml', { content: 'active\n', revision: 'active-1' },
	{ content: 'router newer\n', revision: 'draft-2' });
assert.equal(loaded.conflict, true, 'different crash copy was silently overwritten');
assert.equal(loaded.content, 'router newer\n', 'router Draft must remain selected until explicit user choice');
assert.equal(routerDraft.useCrashCopy(loaded.crash), 'changed\n');
const brokenStorage = { length: 0, key() { throw new Error('denied'); }, getItem() { throw new Error('denied'); },
	setItem() { throw new Error('denied'); }, removeItem() { throw new Error('denied'); } };
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
		setImmediate(() => callback(id === 'validate-fail'
			? { id, state: 'failure', error: { code: 'VALIDATION_FAILED', message: 'bad yaml' } }
			: { id, state: 'success' }));
		return () => {};
	}
};
const failedActions = editorModule.createDraftActions({ api: failedApi, controller: failedController,
	getProfile: () => 'config3.yaml', getContent: () => exactFailedContent });
await assert.rejects(failedActions.apply(), (error) => error.code === 'VALIDATION_FAILED');
assert.equal(applyCalls, 0, 'config_apply ran after validation failure');
assert.equal(failedController.getContent(), exactFailedContent,
	'failed validation changed exact editor/Draft content');
failedController.flushLocal();
const failedCrash = JSON.parse(storage.getItem('miclash-draft-v1:config3.yaml'));
assert.equal(failedCrash.content, exactFailedContent, 'failed validation changed local crash copy');
failedController.destroy(); isolated.destroy(); routerDraft.destroy(); draft.destroy(); history.destroy();

console.log('Draft and configuration history UI contract passed');
