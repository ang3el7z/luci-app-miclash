import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';

const panelPath = 'luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/runtime-metrics-panel.js';
const configPath = 'luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/config.js';
const cssPath = 'luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/style.css';

assert.ok(existsSync(panelPath), `missing runtime metrics panel: ${panelPath}`);

const panel = readFileSync(panelPath, 'utf8');
const config = readFileSync(configPath, 'utf8');
const css = readFileSync(cssPath, 'utf8');

assert.match(config, /view\.miclash\.runtime-metrics-panel/,
	'config view must load the native runtime metrics panel');
assert.match(config, /id="sbox-runtime-metrics"/,
	'the metrics block must sit between service control and Config');
assert.match(config, /runtimeMetricsOwner\.setActive\(appState\.serviceRunning\)/,
	'the metrics block must follow the service state');
assert.match(panel, /const POLL_MS = 2000/,
	'live metrics polling must stay bounded to two seconds');
assert.match(panel, /const MAX_SAMPLES = 60/,
	'sparklines must retain only a bounded sixty-point history');
assert.match(panel, /api\.runtimeMetrics\(\)/,
	'panel must use the typed MiClash metrics API');
assert.match(panel, /function setActive\(value\)/,
	'panel must expose service-aware visibility control');
assert.match(panel, /doc\.hidden/,
	'panel must pause background polling in hidden browser tabs');
assert.doesNotMatch(panel, /requestAnimationFrame|interpolateSnapshot/,
	'live values must use each received sample directly instead of counting through invented intermediate rates');
assert.doesNotMatch(panel, /(?:WebSocket|external-controller|token=|fs\.|exec\s*\()/,
	'panel must not expose panel credentials or call the backend directly');
assert.match(panel, /sbox-runtime-metric-upload/);
assert.match(panel, /sbox-runtime-metric-download/);
assert.match(panel, /sbox-runtime-metric-connections/);
assert.match(css, /\.sbox-runtime-metrics-grid\s*\{[^}]*grid-template-columns:\s*repeat\(3,/s,
	'desktop metrics must use three equal cards');
assert.match(css, /@media \(max-width: 760px\)[\s\S]*?\.sbox-runtime-metrics-grid\s*\{[^}]*grid-template-columns:\s*minmax\(0, 1fr\)/s,
	'metric cards must stack on narrow screens like the rest of the interface');
assert.match(css, /\.sbox-runtime-metric-card--upload\s*\{[^}]*--sbox-runtime-metric-line:/s,
	'upload trend must use its LuCI theme colour');
assert.match(css, /\.sbox-runtime-metric-card--download\s*\{[^}]*--sbox-runtime-metric-line:/s,
	'download trend must use its LuCI theme colour');
assert.match(css, /\.sbox-runtime-metric-card--connections\s*\{[^}]*--sbox-runtime-metric-line:/s,
	'connection trend must use its LuCI theme colour');
assert.match(css, /\.sbox-runtime-metric-scale\s*\{[^}]*font-size:/s,
	'trend scale must remain readable within a LuCI card');
assert.match(css, /\.sbox-runtime-metric-area-start\s*\{[^}]*stop-color:/s,
	'trend area must begin with the card colour');
assert.match(css, /\.sbox-runtime-metric-area-end\s*\{[^}]*stop-opacity:/s,
	'trend area must fade to the baseline');

class MiniNode {
	constructor(tag, attrs) {
		this.tagName = String(tag).toUpperCase();
		this.attrs = attrs || {};
		this.children = [];
		this.hidden = !!this.attrs.hidden;
		this.text = '';
	}
	appendChild(child) { this.children.push(child); return child; }
	replaceChildren(...children) { this.children = children; this.text = ''; }
	setAttribute(name, value) { this.attrs[name] = String(value); }
	set textContent(value) { this.text = String(value); this.children = []; }
	get textContent() {
		return this.text + this.children.map((child) => typeof child === 'string' ? child : child.textContent).join('');
	}
	querySelectorAll(selector) {
		const className = selector.startsWith('.') ? selector.slice(1) : null;
		const id = selector.startsWith('#') ? selector.slice(1) : null;
		const found = [];
		for (const child of this.children) {
			if (typeof child === 'string') continue;
			const classes = String(child.attrs.class || '').split(/\s+/);
			if ((className && classes.includes(className)) || (id && child.attrs.id === id)) found.push(child);
			found.push(...child.querySelectorAll(selector));
		}
		return found;
	}
}

const E = (tag, attrs, children) => {
	const node = new MiniNode(tag, attrs);
	for (const child of (Array.isArray(children) ? children.flat(Infinity) : [ children ])) {
		if (child == null) continue;
		node.appendChild(typeof child === 'string' || typeof child === 'number' ? String(child) : child);
	}
	return node;
};
const documentListeners = new Map();
const documentMock = {
	hidden: false,
	createElementNS(namespace, tag) {
		const node = new MiniNode(tag);
		node.namespaceURI = namespace;
		return node;
	},
	createTextNode(value) { return String(value); },
	addEventListener(type, listener) { documentListeners.set(type, listener); },
	removeEventListener(type) { documentListeners.delete(type); }
};
let nextTimer = 0;
const timers = new Map();
const windowMock = {
	setTimeout(callback, delay) { const id = ++nextTimer; timers.set(id, { callback, delay }); return id; },
	clearTimeout(id) { timers.delete(id); }
};
const baseclass = { extend: (value) => value };
if (typeof ''.format !== 'function') {
	Object.defineProperty(String.prototype, 'format', {
		value(...values) {
			let index = 0;
			return String(this).replace(/%s/g, () => String(values[index++] ?? ''));
		}
	});
}
const moduleApi = new Function('baseclass', 'E', '_', 'window', 'document', panel)(
	baseclass, E, (value) => String(value), windowMock, documentMock);
let metricCalls = 0;
const runtimePanel = moduleApi.create({
	api: {
	async runtimeMetrics() {
		metricCalls++;
		if (metricCalls === 3) return { running: true, available: false };
		if (metricCalls === 2) return { running: true, available: true, upload_rate: 15360, download_rate: 32768,
			upload_total: 10501120, download_total: 53477376, connections: 97, memory_bytes: 56890100 };
		return { running: true, available: true, upload_rate: 7680, download_rate: 16384,
				upload_total: 10485760, download_total: 52428800, connections: 95, memory_bytes: 55889100 };
		},
		destroy() {}
	},
	document: documentMock,
	window: windowMock
});
const host = new MiniNode('section');
runtimePanel.mount(host);
assert.equal(host.hidden, true, 'metrics must remain hidden while the service is stopped');
runtimePanel.setActive(true);
await new Promise((resolve) => setImmediate(resolve));
assert.equal(metricCalls, 1, 'starting the service must fetch one typed metrics snapshot');
assert.equal(host.hidden, false, 'running service must reveal the metrics block');
assert.equal(host.querySelectorAll('.sbox-runtime-metric-card').length, 3,
	'visible metrics block must contain the three native cards');
assert.equal(host.querySelectorAll('.sbox-runtime-metric-area').length, 3,
	'live metric cards must render a filled trend area');
assert.equal(host.querySelectorAll('.sbox-runtime-metric-scale').length, 3,
	'live metric cards must render a right-side trend scale');
assert.equal(host.querySelectorAll('.sbox-runtime-metric-sparkline')[0].namespaceURI,
	'http://www.w3.org/2000/svg', 'trend graphics must use the SVG namespace');
assert.match(host.querySelectorAll('.sbox-runtime-metric-area')[0].attrs.d,
	/^M 0 48[\s\S]*206 42\.5 L 206 48 L 0 48 Z$/,
	'the first live sample must extend a sixty-point zero baseline using the original traffic scale');
assert.match(host.textContent, /Uploaded7\.50 KiB\/s[\s\S]*Downloaded16 KiB\/s[\s\S]*Connections95/,
	'metric cards must present rates and active connection count');
await runtimePanel.refresh();
assert.equal(metricCalls, 2, 'a visible panel must accept a second metrics snapshot');
assert.match(host.textContent, /Uploaded15 KiB\/s[\s\S]*Downloaded32 KiB\/s[\s\S]*Connections97/,
	'each received speed sample must replace the display directly without synthesized intermediate rates');
assert.match(host.querySelectorAll('.sbox-runtime-metric-line')[0].attrs.d, / C /,
	'the discrete live samples must still render as a smoothed trend line');
await runtimePanel.refresh();
assert.equal(metricCalls, 3, 'a visible panel must tolerate one unavailable snapshot');
assert.doesNotMatch(host.textContent, /Unavailable/,
	'a single unavailable snapshot must keep the last displayed metrics visible');
assert.equal(host.querySelectorAll('.sbox-runtime-metric-area').length, 3,
	'a single unavailable snapshot must preserve the graph history');
assert.equal([...timers.values()].filter((timer) => timer.delay === 2000).length, 1,
	'visible service must schedule exactly one next metrics poll');
runtimePanel.setActive(false);
assert.equal(host.hidden, true, 'stopping the service must hide the metrics block immediately');
assert.equal(timers.size, 0, 'stopping the service must cancel the live poll');
runtimePanel.destroy();

console.log('runtime metrics UI contract passed');
