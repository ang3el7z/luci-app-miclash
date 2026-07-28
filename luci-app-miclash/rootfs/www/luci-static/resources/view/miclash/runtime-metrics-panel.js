'use strict';
'require baseclass';

const POLL_MS = 2000;
const MAX_SAMPLES = 60;
const SVG_NAMESPACE = 'http://www.w3.org/2000/svg';

function number(value) {
	const parsed = Number(value);
	return Number.isFinite(parsed) && parsed >= 0 ? parsed : 0;
}

function formatBytes(value, suffix) {
	const amount = number(value);
	const units = [ 'B', 'KiB', 'MiB', 'GiB', 'TiB' ];
	let unit = 0;
	let scaled = amount;
	while (scaled >= 1024 && unit < units.length - 1) {
		scaled /= 1024;
		unit++;
	}
	const precision = scaled >= 100 || unit === 0 ? 0 : (scaled >= 10 ? 1 : 2);
	return scaled.toFixed(precision).replace(/\.0+$/, '') + ' ' + units[unit] + (suffix || '');
}

function formatCount(value) {
	return String(Math.round(number(value)));
}

function interpolate(from, to, progress) {
	return number(from) + (number(to) - number(from)) * progress;
}

function interpolateSnapshot(from, to, progress) {
	return {
		running: true,
		available: true,
		upload_rate: interpolate(from.upload_rate, to.upload_rate, progress),
		download_rate: interpolate(from.download_rate, to.download_rate, progress),
		upload_total: interpolate(from.upload_total, to.upload_total, progress),
		download_total: interpolate(from.download_total, to.download_total, progress),
		connections: interpolate(from.connections, to.connections, progress),
		memory_bytes: interpolate(from.memory_bytes, to.memory_bytes, progress)
	};
}

function pushSample(samples, value) {
	samples.push(number(value));
	if (samples.length > MAX_SAMPLES) samples.splice(0, samples.length - MAX_SAMPLES);
}

function svgElement(doc, tag, attrs, children) {
	if (!doc || typeof doc.createElementNS !== 'function') return E(tag, attrs, children);
	const node = doc.createElementNS(SVG_NAMESPACE, tag);
	Object.keys(attrs || {}).forEach((name) => node.setAttribute(name, attrs[name]));
	function append(child) {
		if (child == null) return;
		if (Array.isArray(child)) {
			child.forEach(append);
			return;
		}
		node.appendChild(typeof child === 'string' || typeof child === 'number'
			? doc.createTextNode(String(child)) : child);
	}
	append(children);
	return node;
}

function chartPath(points) {
	if (points.length < 2)
		return 'M ' + points[0].x + ' ' + points[0].y + ' L 206 ' + points[0].y;
	let path = 'M ' + points[0].x + ' ' + points[0].y;
	for (let index = 0; index < points.length - 1; index++) {
		const previous = points[index - 1] || points[index];
		const current = points[index];
		const next = points[index + 1];
		const after = points[index + 2] || next;
		const controlOneX = Math.round((current.x + (next.x - previous.x) / 6) * 100) / 100;
		const controlOneY = Math.round((current.y + (next.y - previous.y) / 6) * 100) / 100;
		const controlTwoX = Math.round((next.x - (after.x - current.x) / 6) * 100) / 100;
		const controlTwoY = Math.round((next.y - (after.y - current.y) / 6) * 100) / 100;
		path += ' C ' + controlOneX + ' ' + controlOneY + ' ' + controlTwoX + ' ' + controlTwoY +
			' ' + next.x + ' ' + next.y;
	}
	return path;
}

function sparkline(doc, values, id, formatScale) {
	const points = values.length ? values : [ 0 ];
	const maximum = Math.max(1, ...points);
	const width = 206;
	const height = 48;
	const step = points.length > 1 ? width / (points.length - 1) : width;
	const coordinates = points.map((value, index) => ({
		x: Math.round(index * step * 100) / 100,
		y: Math.round((height - (number(value) / maximum) * (height - 5)) * 100) / 100
	}));
	const line = chartPath(coordinates);
	const area = line + ' L ' + width + ' ' + height + ' L 0 ' + height + ' Z';
	const gradientId = id + '-gradient';
	return svgElement(doc, 'svg', {
		'class': 'sbox-runtime-metric-sparkline', 'viewBox': '0 0 240 52',
		'preserveAspectRatio': 'none', 'aria-hidden': 'true', 'focusable': 'false'
	}, [
		svgElement(doc, 'defs', {}, svgElement(doc, 'linearGradient', {
			'id': gradientId, 'x1': '0', 'y1': '0', 'x2': '0', 'y2': '1'
		}, [
			svgElement(doc, 'stop', { 'class': 'sbox-runtime-metric-area-start', 'offset': '0%' }),
			svgElement(doc, 'stop', { 'class': 'sbox-runtime-metric-area-end', 'offset': '100%' })
		])),
		svgElement(doc, 'path', { 'class': 'sbox-runtime-metric-area', 'd': area, 'fill': 'url(#' + gradientId + ')' }),
		svgElement(doc, 'path', { 'class': 'sbox-runtime-metric-line', 'd': line }),
		svgElement(doc, 'g', { 'class': 'sbox-runtime-metric-scale' }, [
			svgElement(doc, 'text', { 'x': '239', 'y': '12', 'text-anchor': 'end' }, formatScale(maximum)),
			svgElement(doc, 'text', { 'x': '239', 'y': '36', 'text-anchor': 'end' }, formatScale(maximum / 2))
		])
	]);
}

function metricCard(doc, id, label, value, footer, samples, variant, formatScale) {
	return E('article', { 'id': id, 'class': 'sbox-settings-card sbox-runtime-metric-card ' +
		'sbox-runtime-metric-card--' + variant }, [
		E('div', { 'class': 'sbox-runtime-metric-label' }, label),
		E('div', { 'class': 'sbox-runtime-metric-value' }, value),
		sparkline(doc, samples, id, formatScale),
		E('div', { 'class': 'sbox-runtime-metric-footer' }, footer)
	]);
}

function create(options) {
	options = options || {};
	const api = options.api;
	const doc = options.document || document;
	const win = options.window || window;
	if (!api || typeof api.runtimeMetrics !== 'function')
		throw new Error('Typed runtime metrics API is required');

	let host = null;
	let active = false;
	let destroyed = false;
	let pollTimer = null;
	let animationFrame = null;
	let refreshPromise = null;
	let snapshot = null;
	let transition = null;
	const samples = { upload: [], download: [], connections: [] };

	function clearPoll() {
		if (pollTimer != null) win.clearTimeout(pollTimer);
		pollTimer = null;
	}

	function clearAnimation() {
		if (animationFrame != null && typeof win.cancelAnimationFrame === 'function')
			win.cancelAnimationFrame(animationFrame);
		animationFrame = null;
	}

	function reset() {
		clearAnimation();
		snapshot = null;
		transition = null;
		samples.upload = [];
		samples.download = [];
		samples.connections = [];
	}

	function displayedSnapshot() {
		if (!transition) return snapshot;
		return interpolateSnapshot(transition.from, transition.to, transition.progress);
	}

	function displayedSamples(name, current) {
		const values = samples[name].slice();
		if (transition) pushSample(values, current);
		return values;
	}

	function finishTransition() {
		if (!transition) return;
		snapshot = transition.to;
		pushSample(samples.upload, snapshot.upload_rate);
		pushSample(samples.download, snapshot.download_rate);
		pushSample(samples.connections, snapshot.connections);
		transition = null;
		clearAnimation();
	}

	function animate(timestamp) {
		animationFrame = null;
		if (destroyed || !active || doc.hidden || !transition) return;
		if (transition.startedAt == null) transition.startedAt = number(timestamp);
		transition.progress = Math.min(1, Math.max(0, (number(timestamp) - transition.startedAt) / POLL_MS));
		if (transition.progress >= 1) finishTransition();
		paint();
		if (transition && typeof win.requestAnimationFrame === 'function')
			animationFrame = win.requestAnimationFrame(animate);
	}

	function startTransition(next) {
		finishTransition();
		if (!snapshot) {
			snapshot = next;
			pushSample(samples.upload, snapshot.upload_rate);
			pushSample(samples.download, snapshot.download_rate);
			pushSample(samples.connections, snapshot.connections);
			return;
		}
		transition = { from: snapshot, to: next, progress: 0, startedAt: null };
		if (typeof win.requestAnimationFrame === 'function')
			animationFrame = win.requestAnimationFrame(animate);
		else {
			finishTransition();
		}
	}

	function paint() {
		if (!host) return;
		host.hidden = !active;
		if (!active) {
			host.replaceChildren();
			return;
		}
		const current = displayedSnapshot();
		const available = current?.available === true;
		const unavailable = _('Unavailable');
		const uploadRate = available ? formatBytes(current.upload_rate, '/s') : unavailable;
		const downloadRate = available ? formatBytes(current.download_rate, '/s') : unavailable;
		const connectionCount = available ? formatCount(current.connections) : unavailable;
		const uploadSamples = available ? displayedSamples('upload', current.upload_rate) : samples.upload;
		const downloadSamples = available ? displayedSamples('download', current.download_rate) : samples.download;
		const connectionSamples = available ? displayedSamples('connections', current.connections) : samples.connections;
		host.replaceChildren(E('div', { 'class': 'sbox-runtime-metrics-grid', 'aria-live': 'off' }, [
			metricCard(doc, 'sbox-runtime-metric-upload', _('Uploaded'), uploadRate,
				available ? _('Total: %s').format(formatBytes(current.upload_total)) : unavailable,
				uploadSamples,
				'upload', (value) => formatBytes(value, '/s')),
			metricCard(doc, 'sbox-runtime-metric-download', _('Downloaded'), downloadRate,
				available ? _('Total: %s').format(formatBytes(current.download_total)) : unavailable,
				downloadSamples,
				'download', (value) => formatBytes(value, '/s')),
			metricCard(doc, 'sbox-runtime-metric-connections', _('Connections'), connectionCount,
				available ? _('Memory: %s').format(formatBytes(current.memory_bytes)) : unavailable,
				connectionSamples,
				'connections', formatCount)
		]));
	}

	function schedule() {
		clearPoll();
		if (destroyed || !active || doc.hidden) return;
		pollTimer = win.setTimeout(() => {
			pollTimer = null;
			refresh();
		}, POLL_MS);
	}

	function ingest(next) {
		if (!next || next.running !== true) {
			active = false;
			reset();
			paint();
			return;
		}
		if (next.available !== true) {
			if (snapshot?.available !== true) snapshot = { running: true, available: false };
			paint();
			return;
		}
		startTransition(next);
		paint();
	}

	function refresh() {
		if (destroyed || !active || doc.hidden || refreshPromise) return refreshPromise;
		refreshPromise = Promise.resolve(api.runtimeMetrics()).then((next) => {
			if (!destroyed && active) ingest(next);
		}).catch(() => {
			if (!destroyed && active) {
				if (snapshot?.available !== true) snapshot = { running: true, available: false };
				paint();
			}
		}).finally(() => {
			refreshPromise = null;
			schedule();
		});
		return refreshPromise;
	}

	function visibilityChanged() {
		if (doc.hidden) {
			clearPoll();
			finishTransition();
		}
		else if (active) refresh();
	}

	function mount(node) {
		host = node;
		paint();
		if (active && !doc.hidden) refresh();
		return host;
	}

	function setActive(value) {
		const wasActive = active;
		active = value === true;
		if (!active) {
			clearPoll();
			reset();
			paint();
			return false;
		}
		if (!wasActive) {
			paint();
			if (!doc.hidden) refresh();
		}
		return true;
	}

	function destroy() {
		if (destroyed) return;
		destroyed = true;
		clearPoll();
		clearAnimation();
		doc.removeEventListener('visibilitychange', visibilityChanged);
		if (typeof api.destroy === 'function') api.destroy();
		host = null;
	}

	doc.addEventListener('visibilitychange', visibilityChanged);
	return { mount, setActive, refresh, destroy };
}

function createOwner(options) {
	if (!options || typeof options.createClient !== 'function')
		throw new Error('Runtime metrics owner factory is required');
	let panel = null;
	return {
		replace() {
			if (panel) panel.destroy();
			panel = create({ api: options.createClient() });
			return panel;
		},
		mount(node) {
			if (panel && node) panel.mount(node);
			return panel;
		},
		setActive(value) {
			return panel ? panel.setActive(value) : false;
		},
		destroy() {
			if (!panel) return false;
			const owned = panel;
			panel = null;
			owned.destroy();
			return true;
		}
	};
}

return baseclass.extend({ create, createOwner });
