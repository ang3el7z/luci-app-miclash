import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { webcrypto } from 'node:crypto';

const panelPath = 'luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/diagnostics-panel.js';
const configPath = 'luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/config.js';
const cssPath = 'luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/style.css';

assert.ok(existsSync(panelPath), `missing diagnostics panel: ${panelPath}`);

const panelSource = readFileSync(panelPath, 'utf8');
const apiSource = readFileSync('luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/api.js', 'utf8');
const configSource = readFileSync(configPath, 'utf8');
const css = readFileSync(cssPath, 'utf8');
assert.match(configSource, /Mode: Explicit \(proxy only selected interfaces\)/);
assert.match(configSource, /Mode: Exclude \(proxy all except selected interfaces\)/);
assert.match(configSource, /Proxy mode: %s/);
assert.match(configSource, /Tun stack: %s/);
assert.match(configSource, /view\.miclash\.api/);
assert.match(configSource, /view\.miclash\.diagnostics-panel/);
assert.match(configSource, /sbox-diagnostics-summary/);
assert.match(configSource, /diagnosticsOwner\s*=\s*view_miclash_diagnostics_panel\.createOwner/,
	'config.js must consume the executable diagnostics ownership helper');
assert.doesNotMatch(panelSource, /(?:innerHTML|outerHTML|insertAdjacentHTML|document\.write)/,
	'diagnostics data must be rendered through DOM text nodes');
assert.doesNotMatch(panelSource, /(?:fs\.|exec\s*\(|\/bin\/sh|\/usr\/bin\/|\/sbin\/)/,
	'diagnostics panel must use only the typed API');
assert.doesNotMatch(configSource, /sbox-diagnostics-dashboard-card/,
	'diagnostics must not become a standalone dashboard card');
assert.match(css, /\.sbox-settings-summary-grid[\s\S]*grid-template-columns:\s*repeat\(2/);
assert.match(css, /@media[^}]*max-width:[^}]*[\s\S]*\.sbox-settings-summary-grid[\s\S]*grid-template-columns:\s*1fr/);

class MiniNode {
	constructor(tag, attrs = {}) {
		this.tagName = String(tag || '').toUpperCase();
		this.attributes = {};
		this.children = [];
		this.parentNode = null;
		this.listeners = new Map();
		this.hidden = false;
		this.value = '';
		this.disabled = false;
		this._text = '';
		for (const [name, value] of Object.entries(attrs || {})) {
			if (name === 'class') this.className = String(value);
			else if (name === 'value') this.value = String(value);
			else if (name === 'hidden') this.hidden = !!value;
			else this.setAttribute(name, value);
		}
	}
	set className(value) { this.setAttribute('class', value || ''); }
	get className() { return this.getAttribute('class') || ''; }
	set id(value) { this.setAttribute('id', value); }
	get id() { return this.getAttribute('id') || ''; }
	set textContent(value) { this._text = String(value ?? ''); this.children = []; }
	get textContent() { return this._text + this.children.map((child) =>
		typeof child === 'string' ? child : child.textContent).join(''); }
	setAttribute(name, value) { this.attributes[String(name)] = String(value); }
	getAttribute(name) { return this.attributes[String(name)] ?? null; }
	removeAttribute(name) { delete this.attributes[String(name)]; }
	appendChild(child) {
		if (child == null) return child;
		if (typeof child !== 'string') child.parentNode = this;
		this.children.push(child);
		return child;
	}
	replaceChildren(...children) {
		for (const child of this.children) if (typeof child !== 'string') child.parentNode = null;
		this.children = [];
		this._text = '';
		for (const child of children) this.appendChild(child);
	}
	remove() {
		if (!this.parentNode) return;
		this.parentNode.children = this.parentNode.children.filter((child) => child !== this);
		this.parentNode = null;
	}
	addEventListener(type, listener) {
		if (!this.listeners.has(type)) this.listeners.set(type, new Set());
		this.listeners.get(type).add(listener);
	}
	removeEventListener(type, listener) { this.listeners.get(type)?.delete(listener); }
	dispatchEvent(event) {
		event.target ||= this;
		event.currentTarget = this;
		event.preventDefault ||= () => { event.defaultPrevented = true; };
		for (const listener of this.listeners.get(event.type) || []) listener.call(this, event);
		return !event.defaultPrevented;
	}
	click() { this.dispatchEvent({ type: 'click' }); }
	matches(selector) {
		if (selector.startsWith('#')) return this.id === selector.slice(1);
		if (selector.startsWith('.')) return this.className.split(/\s+/).includes(selector.slice(1));
		const attr = selector.match(/^([a-z]+)?\[([^=\]]+)(?:="([^"]*)")?\]$/i);
		if (attr) return (!attr[1] || this.tagName === attr[1].toUpperCase()) &&
			this.getAttribute(attr[2]) != null && (attr[3] == null || this.getAttribute(attr[2]) === attr[3]);
		return this.tagName === selector.toUpperCase();
	}
	querySelectorAll(selector) {
		const found = [];
		for (const child of this.children) {
			if (typeof child === 'string') continue;
			if (child.matches(selector)) found.push(child);
			found.push(...child.querySelectorAll(selector));
		}
		return found;
	}
	querySelector(selector) { return this.querySelectorAll(selector)[0] || null; }
}

const E = (tag, attrs, children) => {
	const node = new MiniNode(tag, attrs || {});
	const values = Array.isArray(children) ? children : (children == null ? [] : [children]);
	for (const child of values.flat(Infinity)) {
		if (child == null) continue;
		if (typeof child === 'string' || typeof child === 'number') node.appendChild(String(child));
		else node.appendChild(child);
	}
	return node;
};

class EventTargetMock {
	constructor() { this.listeners = new Map(); }
	addEventListener(type, listener) {
		if (!this.listeners.has(type)) this.listeners.set(type, new Set());
		this.listeners.get(type).add(listener);
	}
	removeEventListener(type, listener) { this.listeners.get(type)?.delete(listener); }
	emit(type, detail) {
		for (const listener of this.listeners.get(type) || []) listener({ type, detail });
	}
	count(type) { return this.listeners.get(type)?.size || 0; }
}

let hidden = false;
const documentEvents = new EventTargetMock();
const documentMock = Object.assign(documentEvents, {
	createElement(tag) { return new MiniNode(tag); },
	body: new MiniNode('body')
});
Object.defineProperty(documentMock, 'hidden', { get: () => hidden });
const windowEvents = new EventTargetMock();
let timerSequence = 1;
const timers = new Map();
const revoked = [], createdUrls = [], clickedDownloads = [];
const windowMock = Object.assign(windowEvents, {
	crypto: webcrypto,
	setTimeout(callback, delay) { const id = timerSequence++; timers.set(id, { callback, delay }); return id; },
	clearTimeout(id) { timers.delete(id); },
	URL: {
		createObjectURL(blob) { const value = `blob:diagnostics-${createdUrls.length + 1}`; createdUrls.push({ value, blob }); return value; },
		revokeObjectURL(value) { revoked.push(value); }
	},
	document: documentMock
});
windowMock.dispatchEvent = (event) => { windowEvents.emit(event.type, event.detail); return true; };
documentMock.createElement = (tag) => {
	const node = new MiniNode(tag);
	if (String(tag).toLowerCase() === 'a') node.click = () => clickedDownloads.push({ href: node.href, download: node.download });
	return node;
};

const modalCalls = [];
const notifications = [];
const ui = {
	showModal(title, body) { modalCalls.push({ title, body }); },
	hideModal() {},
	addNotification(_title, body, type) { notifications.push({ type, text: body?.textContent || '' }); }
};
const translate = (value) => String(value);
const moduleApi = new Function('ui', 'E', '_', 'window', 'document', 'Blob', panelSource)(
	ui, E, translate, windowMock, documentMock, Blob);

const calls = [];
let destroyedApi = 0;
const malicious = '<img src=x onerror=alert(1)>';
const replies = {
	status: { desired: { guard: { enabled: true } }, observed: { service: { running: true } } },
	health: { observed: { service: { running: true }, readiness: { components: [] } }, observed_at: 1710000000000 },
	summary: {
		health: {
			mihomo: { state: 'ok', code: 'READY', message: malicious, details: { pid: 7 } },
			dns: { state: 'ok', code: 'READY', message: 'DNS ready', details: { listener: '127.0.0.1' } },
			firewall: { state: 'degraded', code: 'DRIFT', message: 'Firewall drift', details: { table: 'miclash' } },
			routing: { state: 'ok', code: 'READY', message: 'Routes ready', details: { mark: '0x162' } },
			guard: { state: 'ok', code: 'ENABLED', message: 'Fail closed', details: { enabled: true } }
		},
		memory: { current_rss_kb: 102400, baseline_rss_kb: 81920, phase: 'monitoring', cooldown_until: 1710000200000 },
		last_repair: { component: 'firewall', action: 'reconcile', result: 'success', at: 1710000000 },
		updates: { running: true, enabled: true, last_activation: 1710000100000 },
		subscription: { configured: true, transport: 'https', insecure: false },
		telegram: { enabled: true, configured: true }
	}
};
const api = {
	async status() { calls.push(['status']); return replies.status; },
	async health() { calls.push(['health']); return replies.health; },
	async diagnosticsSummary() { calls.push(['diagnosticsSummary']); return replies.summary; },
	async createDiagnosticReport() { calls.push(['createDiagnosticReport']); return { id: 'rpt_' + 'a'.repeat(32) }; },
	async downloadChunks(...args) { calls.push(['downloadChunks', ...args]); return new TextEncoder().encode('{"safe":true}\n'); },
	async routeTest(...args) {
		calls.push(['routeTest', ...args]);
		return { decision: 'PROXY', steps: [
			{ name: 'device_policy', outcome: 'PROXY', details: { policy: malicious } },
			{ name: 'routing', outcome: 'PROXY', details: { mark: '0x162' } },
			{ name: 'guard', outcome: 'PROXY', details: { fail_closed: false } }
		] };
	},
	destroy() { destroyedApi++; }
};

const panel = moduleApi.create({ api, document: documentMock, window: windowMock, pollInterval: 30000 });
for (const method of ['renderSummary', 'openDetails', 'downloadReport', 'openRouteTest', 'mount', 'destroy'])
	assert.equal(typeof panel[method], 'function', `missing public method ${method}`);

const host = new MiniNode('div', { id: 'sbox-diagnostics-summary' });
panel.mount(host);
await new Promise((resolve) => setImmediate(resolve));
assert.deepEqual(calls.slice(0, 3).map((call) => call[0]).sort(),
	['diagnosticsSummary', 'health', 'status'], 'summary must use all typed read methods');
const summaryText = host.textContent;
for (const label of ['Mihomo', 'DNS', 'Firewall', 'Routing', 'Guard', 'RSS', 'Baseline',
	'Pressure', 'Cooldown', 'Last repair', 'Subscription activation', 'Telegram',
	'Details', 'Download diagnostic report', 'Route test'])
	assert.match(summaryText, new RegExp(label), `summary is missing ${label}`);
assert.equal(host.querySelectorAll('[role="status"]').length >= 5, true,
	'component states must expose accessible status roles');
for (const node of host.querySelectorAll('[role="status"]'))
	assert.ok(node.getAttribute('aria-label'), 'status icon/text needs an accessible label');
assert.equal(host.querySelector('a[data-action="download-report"]')?.textContent,
	'Download diagnostic report', 'report action must be hyperlink-styled semantic link');
assert.match(summaryText, /Guard●Enabled/, 'Guard must show desired enabled/disabled state, not only health');
assert.match(summaryText, /RSS100\.0 MiB/);
assert.match(summaryText, /Baseline80\.0 MiB/);
assert.match(summaryText, new RegExp(new Date(1710000200000).toLocaleString().replace(/[.*+?^${}()|[\]\\]/g, '\\$&')),
	'real memory cooldown_until was not rendered');
assert.match(summaryText, new RegExp(new Date(1710000100000).toLocaleString().replace(/[.*+?^${}()|[\]\\]/g, '\\$&')),
	'real scheduler last_activation was not rendered');
assert.equal(host.querySelector('img'), null, 'summary created an unexpected element');
const statusFallback = panel.renderSummary({
	status: { desired: { guard: { enabled: false } }, observed: { service: { running: true } } },
	health: {}, summary: { ...replies.summary, health: {} }
}).textContent;
assert.match(statusFallback, /Mihomo●Ready/, 'Mihomo status must fall back to typed status state');
assert.match(statusFallback, /Guard●Disabled/, 'Guard status must fall back to typed desired state');
const arrayHealth = panel.renderSummary({ status: replies.status, health: {}, summary: {
	...replies.summary, health: { components: [ { component: 'mihomo', state: 'degraded' } ] }
} }).textContent;
assert.match(arrayHealth, /Mihomo●Degraded/, 'component arrays must normalize safely');

assert.equal(timers.size, 1, 'visible page must schedule one bounded poll');
hidden = true;
documentEvents.emit('visibilitychange');
assert.equal(timers.size, 0, 'hidden page must cancel diagnostics polling');
hidden = false;
documentEvents.emit('visibilitychange');
await new Promise((resolve) => setImmediate(resolve));
assert.equal(timers.size, 1, 'visible page must resume exactly one diagnostics poll');
const callsBeforeEvent = calls.length;
windowEvents.emit('miclash:ubus-event', { object: 'miclash', type: 'health' });
assert.equal([...timers.values()].some((timer) => timer.delay < 1000), true,
	'ubus event must schedule an earlier refresh');
for (const [id, timer] of [...timers]) {
	if (timer.delay < 1000) { timers.delete(id); await timer.callback(); }
}
await new Promise((resolve) => setImmediate(resolve));
assert.ok(calls.length > callsBeforeEvent, 'ubus event refresh did not call typed API');

panel.openDetails();
let modal = modalCalls.at(-1);
assert.equal(modal.title, 'MiClash diagnostics');
assert.match(modal.body.textContent, /Component evidence/);
assert.match(modal.body.textContent, /Last self-heal/);
assert.match(modal.body.textContent, /Firewall drift/);
assert.match(modal.body.textContent, /"table":"miclash"/);
assert.match(modal.body.textContent, /Last self-healfirewall · reconcile · success/);
assert.match(modal.body.textContent, /<img src=x onerror=alert\(1\)>/,
	'backend evidence must remain literal text, proving no HTML interpretation');
assert.equal(modal.body.querySelector('img'), null, 'malicious evidence created an element');
assert.doesNotMatch(modal.body.textContent, /token=|authorization|123456:/i);

await panel.downloadReport();
assert.deepEqual(calls.find((call) => call[0] === 'downloadChunks')?.slice(1),
	['report', 'rpt_' + 'a'.repeat(32), { format: 'json' }]);
assert.equal(createdUrls.length, 1);
assert.equal(clickedDownloads[0].download, 'miclash-diagnostic-report.json');
assert.deepEqual(revoked, [createdUrls[0].value], 'object URL must always be revoked');

panel.openRouteTest();
modal = modalCalls.at(-1);
assert.equal(modal.title, 'Route test');
const routeBody = modal.body;
const target = routeBody.querySelector('#sbox-route-target');
const device = routeBody.querySelector('#sbox-route-device');
const iface = routeBody.querySelector('#sbox-route-interface');
const submit = routeBody.querySelector('[data-action="run-route-test"]');
target.value = 'bad target!';
submit.click();
await new Promise((resolve) => setImmediate(resolve));
assert.equal(calls.filter((call) => call[0] === 'routeTest').length, 0,
	'invalid target must not reach the daemon');
assert.match(routeBody.textContent, /Enter a valid domain or IP address/);
target.value = 'example.org'; device.value = 'not-a-mac'; iface.value = 'br-lan';
submit.click();
await new Promise((resolve) => setImmediate(resolve));
assert.equal(calls.filter((call) => call[0] === 'routeTest').length, 0,
	'invalid optional device must not reach the daemon');
assert.match(routeBody.textContent, /Device or interface is invalid/);
target.value = 'example.org'; device.value = 'AA:BB:CC:DD:EE:FF'; iface.value = 'br-lan';
submit.click();
await new Promise((resolve) => setImmediate(resolve));
assert.deepEqual(calls.find((call) => call[0] === 'routeTest')?.slice(1),
	['example.org', 'AA:BB:CC:DD:EE:FF', 'br-lan']);
const ordered = routeBody.querySelector('ol');
assert.ok(ordered, 'route explanation must use an ordered list');
assert.equal(ordered.querySelectorAll('li').length, 3);
assert.match(ordered.textContent, /device_policy[\s\S]*routing[\s\S]*guard/);
assert.match(routeBody.textContent, /<img src=x onerror=alert\(1\)>/);
assert.equal(routeBody.querySelector('img'), null, 'route evidence created an element');

api.routeTest = async () => { const error = new Error('Target rejected'); error.code = 'VALIDATION_FAILED'; throw error; };
target.value = '1.1.1.1'; submit.click();
await new Promise((resolve) => setImmediate(resolve));
assert.match(routeBody.textContent, /VALIDATION_FAILED: Target rejected/,
	'typed route errors must remain visible');

let releaseRoute;
api.routeTest = async () => new Promise((resolve) => { releaseRoute = resolve; });
const pendingRouteBody = panel.openRouteTest();
pendingRouteBody.querySelector('#sbox-route-target').value = 'example.net';
pendingRouteBody.querySelector('[data-action="run-route-test"]').click();
while (!releaseRoute) await new Promise((resolve) => setImmediate(resolve));
panel.destroy();
releaseRoute({ decision: 'DIRECT', steps: [ { source: 'routing', decision: 'DIRECT' } ] });
await new Promise((resolve) => setImmediate(resolve));
assert.equal(pendingRouteBody.querySelector('ol'), null,
	'destroyed panel must ignore an in-flight route reply');
assert.equal(timers.size, 0, 'destroy must cancel every panel timer');
assert.equal(documentEvents.count('visibilitychange'), 0, 'destroy leaked visibility listener');
assert.equal(windowEvents.count('miclash:ubus-event'), 0, 'destroy leaked ubus event listener');
assert.equal(destroyedApi, 1, 'destroy must cancel typed client transfer work');

assert.equal(typeof moduleApi.createOwner, 'function', 'missing executable config diagnostics owner');
let clientsCreated = 0, panelsCreated = 0;
const ownedPanels = [], ownedClients = [];
const owner = moduleApi.createOwner({
	createClient() {
		clientsCreated++;
		const client = { id: clientsCreated, destroys: 0, destroy() { this.destroys++; } };
		ownedClients.push(client);
		return client;
	},
	createPanel(options) {
		panelsCreated++;
		const owned = { api: options.api, mounts: [], destroys: 0,
			mount(node) { this.mounts.push(node); },
			destroy() { this.destroys++; this.api.destroy(); } };
		ownedPanels.push(owned);
		return owned;
	}
});
owner.replace();
owner.mount('first-host');
owner.mount('rerendered-settings-host');
assert.equal(clientsCreated, 1, 'settings rerender created a duplicate typed client');
assert.equal(panelsCreated, 1, 'settings rerender created a duplicate panel');
assert.deepEqual(ownedPanels[0].mounts, ['first-host', 'rerendered-settings-host']);
owner.replace();
assert.equal(ownedPanels[0].destroys, 1, 'view rerender did not destroy prior panel exactly once');
assert.equal(ownedClients[0].destroys, 1, 'view rerender did not destroy prior typed client exactly once');
owner.destroy(); owner.destroy();
assert.equal(ownedPanels[1].destroys, 1, 'unload must destroy current panel exactly once');
assert.equal(ownedClients[1].destroys, 1, 'unload must destroy current typed client exactly once');

// The genuine typed API producer and reader share one event target. A mutating
// operation refreshes a visible panel sooner; read-only refresh calls never emit.
const rpcReplies = new Map();
const rpcCalls = [];
const rpcMock = { declare(spec) { return async (...args) => {
	rpcCalls.push({ method: spec.method, args });
	const reply = rpcReplies.get(spec.method);
	return typeof reply === 'function' ? reply(...args) : (reply || {});
}; } };
const typedApi = new Function('rpc', 'window', 'TextEncoder', 'Uint8Array', 'ArrayBuffer',
	'btoa', 'atob', apiSource)(rpcMock, windowMock, TextEncoder, Uint8Array, ArrayBuffer,
	(value) => Buffer.from(value, 'binary').toString('base64'),
	(value) => Buffer.from(value, 'base64').toString('binary'));
rpcReplies.set('status', replies.status);
rpcReplies.set('health', { observed: { service: { running: true }, readiness: { components: [] } }, observed_at: 1710000000000 });
rpcReplies.set('diagnostics_summary', replies.summary);
rpcReplies.set('service_restart', { operation_id: 'op_event_1' });
const typedReader = typedApi.create({ eventTarget: windowMock });
const typedProducer = typedApi.create({ eventTarget: windowMock });
const eventPanel = moduleApi.create({ api: typedReader, document: documentMock, window: windowMock, pollInterval: 30000 });
const eventHost = new MiniNode('div');
eventPanel.mount(eventHost);
await new Promise((resolve) => setImmediate(resolve));
const readsBeforeMutation = rpcCalls.filter((call) => ['status', 'health', 'diagnostics_summary'].includes(call.method)).length;
await typedProducer.service_restart('config.yaml', 'luci');
assert.equal([...timers.values()].some((timer) => timer.delay < 1000), true,
	'typed mutation did not produce an early panel refresh event');
for (const [id, timer] of [...timers]) if (timer.delay < 1000) { timers.delete(id); await timer.callback(); }
await new Promise((resolve) => setImmediate(resolve));
assert.ok(rpcCalls.filter((call) => ['status', 'health', 'diagnostics_summary'].includes(call.method)).length > readsBeforeMutation,
	'visible panel did not consume genuine typed operation event');
const shortTimersBeforeRead = [...timers.values()].filter((timer) => timer.delay < 1000).length;
await typedProducer.status();
assert.equal([...timers.values()].filter((timer) => timer.delay < 1000).length, shortTimersBeforeRead,
	'read-only status produced a refresh loop event');
hidden = true; documentEvents.emit('visibilitychange');
await typedProducer.service_restart('config.yaml', 'luci');
assert.equal([...timers.values()].filter((timer) => timer.delay < 1000).length, 0,
	'hidden panel reacted to a genuine typed operation event');
hidden = false; documentEvents.emit('visibilitychange');
await new Promise((resolve) => setImmediate(resolve));
eventPanel.destroy();
await typedProducer.service_restart('config.yaml', 'luci');
assert.equal(timers.size, 0, 'destroyed panel reacted to a genuine typed operation event');
typedProducer.destroy();

console.log('integrated diagnostics UI contract passed');
