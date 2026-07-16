'use strict';
'require ui';

const COMPONENTS = [
	[ 'mihomo', () => _('Mihomo') ],
	[ 'dns', () => _('DNS') ],
	[ 'firewall', () => _('Firewall') ],
	[ 'routing', () => _('Routing') ],
	[ 'guard', () => _('Guard') ]
];
const SECRET_NAME = /(?:authorization|cookie|password|secret|token|subscription[_-]?url)/i;

function text(value) {
	return String(value == null || value === '' ? '-' : value);
}

function translated(template) {
	let output = _(template);
	for (let i = 1; i < arguments.length; i++)
		output = String(output).replace('%s', text(arguments[i]));
	return output;
}

function publicValue(value, key, depth) {
	if (depth > 6) return '[limited]';
	if (key && SECRET_NAME.test(key)) return '[redacted]';
	if (Array.isArray(value)) return value.slice(0, 32).map((item) => publicValue(item, '', depth + 1));
	if (value && typeof value === 'object') {
		const output = {};
		for (const name of Object.keys(value).slice(0, 64))
			output[name] = publicValue(value[name], name, depth + 1);
		return output;
	}
	if (typeof value === 'string' && value.length > 1024) return value.slice(0, 1021) + '...';
	return value;
}

function evidence(value) {
	try { return JSON.stringify(publicValue(value, '', 0)); }
	catch (error) { return text(value); }
}

function stateName(value) {
	const state = String(value || 'unknown').toLowerCase();
	if (state === 'ok' || state === 'running' || state === 'ready' || state === 'success') return _('Ready');
	if (state === 'degraded' || state === 'warning') return _('Degraded');
	if (state === 'failed' || state === 'error' || state === 'stopped') return _('Failed');
	return _('Unknown');
}

function stateClass(value) {
	const state = String(value || 'unknown').toLowerCase();
	if (state === 'ok' || state === 'running' || state === 'ready' || state === 'success') return 'sbox-diagnostics-state-ok';
	if (state === 'degraded' || state === 'warning') return 'sbox-diagnostics-state-warning';
	if (state === 'failed' || state === 'error' || state === 'stopped') return 'sbox-diagnostics-state-error';
	return 'sbox-diagnostics-state-unknown';
}

function statusNode(label, value) {
	const readable = stateName(value);
	return E('span', {
		'class': 'sbox-diagnostics-state ' + stateClass(value),
		'role': 'status',
		'aria-label': label + ': ' + readable
	}, [ E('span', { 'class': 'sbox-diagnostics-state-icon', 'aria-hidden': 'true' }, '●'), readable ]);
}

function enabledNode(label, value) {
	if (typeof value !== 'boolean') return statusNode(label, 'unknown');
	const readable = value ? _('Enabled') : _('Disabled');
	return E('span', {
		'class': 'sbox-diagnostics-state ' + (value ? 'sbox-diagnostics-state-ok' : 'sbox-diagnostics-state-error'),
		'role': 'status',
		'aria-label': label + ': ' + readable
	}, [ E('span', { 'class': 'sbox-diagnostics-state-icon', 'aria-hidden': 'true' }, '●'), readable ]);
}

function valueRow(label, value, className) {
	return E('div', { 'class': 'sbox-diagnostics-row ' + (className || '') }, [
		E('span', { 'class': 'sbox-diagnostics-label' }, label),
		E('span', { 'class': 'sbox-diagnostics-value' }, text(value))
	]);
}

function bytes(value) {
	const amount = Number(value);
	if (!Number.isFinite(amount) || amount < 0) return '-';
	if (amount < 1024) return Math.round(amount) + ' B';
	if (amount < 1024 * 1024) return (amount / 1024).toFixed(1) + ' KiB';
	return (amount / (1024 * 1024)).toFixed(1) + ' MiB';
}

function memoryBytes(memory, bytesName, kbName) {
	if (memory && memory[bytesName] != null) return bytes(memory[bytesName]);
	if (memory && memory[kbName] != null) return bytes(Number(memory[kbName]) * 1024);
	return '-';
}

function dateValue(value) {
	const amount = Number(value);
	if (!Number.isFinite(amount) || amount <= 0) return '-';
	const millis = amount < 100000000000 ? amount * 1000 : amount;
	try { return new Date(millis).toLocaleString(); }
	catch (error) { return text(value); }
}

function repairValue(repair) {
	if (!repair || typeof repair !== 'object' || !Object.keys(repair).length) return _('None');
	return [ repair.component, repair.action, repair.result || repair.outcome, dateValue(repair.at || repair.finished_at) ]
		.filter((item) => item != null && item !== '' && item !== '-').map(text).join(' · ') || _('None');
}

function subscriptionValue(summary) {
	const update = summary?.updates?.subscription || summary?.updates?.last_subscription || summary?.last_subscription;
	if (update && typeof update === 'object') {
		const state = update.state || update.result || update.outcome || '-';
		const at = dateValue(update.activated_at || update.finished_at || update.at);
		return at === '-' ? text(state) : text(state) + ' · ' + at;
	}
	if (summary?.subscription?.configured === true) return _('Configured');
	return _('Not configured');
}

function telegramValue(summary) {
	const telegram = summary?.telegram || {};
	if (telegram.enabled !== true) return _('Disabled');
	return telegram.configured === true ? _('Enabled and configured') : _('Enabled, not configured');
}

function targetValid(value) {
	if (typeof value !== 'string' || !value.length || value.length > 253 || /[\s\x00-\x1f\x7f]/.test(value)) return false;
	const parts = value.split('.');
	if (parts.length === 4 && parts.every((part) => /^(?:0|[1-9][0-9]{0,2})$/.test(part)))
		return parts.every((part) => Number(part) <= 255);
	if (value.includes(':')) return /^[0-9a-f:.]+$/i.test(value) && value.length <= 45;
	return value.length <= 253 && value.split('.').every((part) =>
		/^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/i.test(part));
}

function create(options) {
	options = options || {};
	const api = options.api;
	const doc = options.document || document;
	const win = options.window || window;
	const pollInterval = Math.max(5000, Number(options.pollInterval) || 30000);
	if (!api || typeof api.status !== 'function' || typeof api.health !== 'function' ||
		typeof api.diagnosticsSummary !== 'function')
		throw new Error('Typed diagnostics API is required');

	let host = null;
	let current = { status: {}, health: {}, summary: {} };
	let pollTimer = null;
	let eventTimer = null;
	let refreshing = false;
	let refreshPending = false;
	let destroyed = false;
	const objectUrls = new Set();

	function clearTimer(name) {
		const value = name === 'poll' ? pollTimer : eventTimer;
		if (value != null) win.clearTimeout(value);
		if (name === 'poll') pollTimer = null;
		else eventTimer = null;
	}

	function schedulePoll() {
		clearTimer('poll');
		if (destroyed || doc.hidden) return;
		pollTimer = win.setTimeout(() => {
			pollTimer = null;
			refresh().catch(() => {});
		}, pollInterval);
	}

	function actionLink(label, action) {
		const link = E('a', { 'href': '#', 'class': 'sbox-diagnostics-link', 'data-action': action }, label);
		link.addEventListener('click', (event) => {
			event.preventDefault();
			if (action === 'details') openDetails();
			else if (action === 'download-report') downloadReport().catch(showError);
			else if (action === 'route-test') openRouteTest();
		});
		return link;
	}

	function renderSummary(state) {
		state = state || current;
		const summary = state.summary || {};
		const summaryHealth = summary.health || {};
		const apiHealth = state.health?.components || state.health || {};
		const health = COMPONENTS.some(([ name ]) => summaryHealth[name]) ? summaryHealth : apiHealth;
		const memory = summary.memory || {};
		const status = state.status || {};
		const serviceRunning = status.observed?.service?.running ?? status.state?.observed?.service?.running ?? status.running;
		const guardEnabled = summary.state?.desired?.guard?.enabled ?? status.desired?.guard?.enabled ??
			status.state?.desired?.guard?.enabled;
		const componentRows = COMPONENTS.map(([ name, label ]) => {
			let componentState = health[name]?.state;
			if (name === 'mihomo' && !componentState && typeof serviceRunning === 'boolean')
				componentState = serviceRunning ? 'running' : 'stopped';
			return E('div', { 'class': 'sbox-diagnostics-row' }, [
				E('span', { 'class': 'sbox-diagnostics-label' }, label()),
				name === 'guard' ? enabledNode(label(), guardEnabled) : statusNode(label(), componentState)
			]);
		});
		const cooldown = memory.cooldown_until ? dateValue(memory.cooldown_until) : _('Inactive');
		return E('div', { 'class': 'sbox-diagnostics-content' }, [
			E('div', { 'class': 'sbox-diagnostics-components', 'aria-label': _('Component status') }, componentRows),
			E('div', { 'class': 'sbox-diagnostics-facts' }, [
				valueRow(_('RSS'), memoryBytes(memory, 'rss_bytes', 'rss_kb')),
				valueRow(_('Baseline'), memoryBytes(memory, 'baseline_bytes', 'baseline_rss_kb')),
				valueRow(_('Pressure'), memory.pressure || memory.phase || '-'),
				valueRow(_('Cooldown'), cooldown),
				valueRow(_('Last repair'), repairValue(summary.last_repair)),
				valueRow(_('Subscription activation'), subscriptionValue(summary)),
				valueRow(_('Telegram'), telegramValue(summary))
			]),
			E('div', { 'class': 'sbox-diagnostics-actions', 'aria-label': _('Diagnostic actions') }, [
				actionLink(_('Details'), 'details'),
				actionLink(_('Download diagnostic report'), 'download-report'),
				actionLink(_('Route test'), 'route-test')
			])
		]);
	}

	function paint() {
		if (host && !destroyed) host.replaceChildren(renderSummary(current));
	}

	async function refresh() {
		if (destroyed || doc.hidden) return;
		if (refreshing) { refreshPending = true; return; }
		refreshing = true;
		try {
			const values = await Promise.all([ api.status(), api.health(), api.diagnosticsSummary() ]);
			if (!destroyed) {
				current = { status: values[0] || {}, health: values[1] || {}, summary: values[2] || {} };
				paint();
			}
		} catch (error) {
			if (!destroyed) showError(error);
		} finally {
			refreshing = false;
			if (!destroyed && refreshPending) {
				refreshPending = false;
				return refresh();
			}
			schedulePoll();
		}
	}

	function showError(error) {
		if (destroyed) return;
		const code = error && error.code ? String(error.code) + ': ' : '';
		const message = code + String(error && error.message ? error.message : _('Unknown error'));
		ui.addNotification(null, E('p', {}, message), 'error');
	}

	function detailsEvidence(record) {
		return E('li', {}, [
			E('strong', {}, text(record.label) + ': '),
			stateName(record.value?.state) + ' · ' + text(record.value?.code) + ' · ' +
			text(record.value?.message) + ' · ' + evidence(record.value?.details || {})
		]);
	}

	function closeButton() {
		const button = E('button', { 'type': 'button', 'class': 'cbi-button cbi-button-neutral' }, _('Close'));
		button.addEventListener('click', () => ui.hideModal());
		return button;
	}

	function openDetails() {
		const records = COMPONENTS.map(([ name, label ]) => ({ label: label(), value: current.health?.[name] || {} }));
		const body = E('div', { 'class': 'sbox-diagnostics-modal' }, [
			E('h4', {}, _('Component evidence')),
			E('ul', { 'class': 'sbox-diagnostics-evidence' }, records.map(detailsEvidence)),
			E('h4', {}, _('Last self-heal')),
			E('p', {}, repairValue(current.summary?.last_repair)),
			E('div', { 'class': 'right' }, closeButton())
		]);
		ui.showModal(_('MiClash diagnostics'), body);
		return body;
	}

	async function downloadReport() {
		if (destroyed) return;
		const created = await api.createDiagnosticReport();
		if (destroyed) return;
		const id = created && created.id;
		if (typeof id !== 'string' || !/^rpt_[0-9a-f]{32}$/.test(id)) {
			const error = new Error(_('Invalid diagnostic report response'));
			error.code = 'INVALID_RESPONSE';
			throw error;
		}
		const payload = await api.downloadChunks('report', id, { format: 'json' });
		if (destroyed) return;
		const blob = new Blob([ payload ], { type: 'application/json;charset=utf-8' });
		const url = win.URL.createObjectURL(blob);
		objectUrls.add(url);
		try {
			const anchor = doc.createElement('a');
			anchor.href = url;
			anchor.download = 'miclash-diagnostic-report.json';
			anchor.setAttribute('aria-hidden', 'true');
			anchor.click();
			anchor.remove();
		} finally {
			win.URL.revokeObjectURL(url);
			objectUrls.delete(url);
		}
	}

	function routeError(container, error) {
		const code = error && error.code ? String(error.code) + ': ' : '';
		container.replaceChildren(E('p', { 'class': 'sbox-diagnostics-error', 'role': 'alert' },
			code + String(error && error.message ? error.message : error)));
	}

	function renderRouteResult(container, result) {
		const steps = Array.isArray(result?.steps) ? result.steps.slice(0, 16) : [];
		const list = E('ol', { 'class': 'sbox-route-steps' }, steps.map((item) => {
			const source = item?.source || item?.name || _('Unknown');
			const decision = item?.decision || item?.outcome || '-';
			const details = item?.evidence || item?.details || {};
			return E('li', {}, [ E('strong', {}, text(source) + ': '), text(decision) + ' · ' + evidence(details) ]);
		}));
		container.replaceChildren(
			E('p', { 'class': 'sbox-route-decision', 'role': 'status',
				'aria-label': translated(_('Expected route: %s'), result?.decision || 'unknown') },
				translated(_('Expected route: %s'), result?.decision || 'unknown')),
			list
		);
	}

	function openRouteTest() {
		const target = E('input', { 'id': 'sbox-route-target', 'class': 'cbi-input-text', 'type': 'text',
			'placeholder': 'example.org / 1.1.1.1', 'autocomplete': 'off' });
		const device = E('input', { 'id': 'sbox-route-device', 'class': 'cbi-input-text', 'type': 'text',
			'placeholder': _('Optional device') });
		const iface = E('input', { 'id': 'sbox-route-interface', 'class': 'cbi-input-text', 'type': 'text',
			'placeholder': _('Optional interface') });
		const result = E('div', { 'class': 'sbox-route-result', 'aria-live': 'polite' });
		const run = E('button', { 'type': 'button', 'class': 'cbi-button cbi-button-apply',
			'data-action': 'run-route-test' }, _('Run route test'));
		run.addEventListener('click', async () => {
			const targetValue = String(target.value || '').trim();
			const deviceValue = String(device.value || '').trim();
			const interfaceValue = String(iface.value || '').trim();
			if (!targetValid(targetValue)) {
				routeError(result, new Error(_('Enter a valid domain or IP address')));
				return;
			}
			if (deviceValue && !/^[0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){5}$/.test(deviceValue) ||
				interfaceValue && (interfaceValue.length > 15 || !/^[A-Za-z0-9][A-Za-z0-9_.:-]*$/.test(interfaceValue))) {
				routeError(result, new Error(_('Device or interface is invalid')));
				return;
			}
			run.disabled = true;
			try {
				const route = await api.routeTest(targetValue, deviceValue, interfaceValue);
				if (!destroyed) renderRouteResult(result, route);
			}
			catch (error) { if (!destroyed) routeError(result, error); }
			finally { if (!destroyed) run.disabled = false; }
		});
		const body = E('div', { 'class': 'sbox-diagnostics-modal sbox-route-modal' }, [
			E('div', { 'class': 'sbox-route-form' }, [
				E('label', { 'for': 'sbox-route-target' }, _('Domain or IP address')),
				target,
				E('label', { 'for': 'sbox-route-device' }, _('Device (optional)')),
				device,
				E('label', { 'for': 'sbox-route-interface' }, _('Interface (optional)')),
				iface,
				E('div', { 'class': 'sbox-actions' }, [ run, closeButton() ])
			]),
			result
		]);
		ui.showModal(_('Route test'), body);
		return body;
	}

	function visibilityChanged() {
		if (doc.hidden) {
			clearTimer('poll');
			clearTimer('event');
		} else refresh().catch(() => {});
	}

	function ubusEvent(event) {
		if (destroyed || doc.hidden || event?.detail?.object && event.detail.object !== 'miclash') return;
		clearTimer('event');
		eventTimer = win.setTimeout(() => {
			eventTimer = null;
			refresh().catch(() => {});
		}, 150);
	}

	function mount(node) {
		host = node;
		paint();
		if (!destroyed && !doc.hidden) refresh().catch(() => {});
		return host;
	}

	function destroy() {
		if (destroyed) return;
		destroyed = true;
		clearTimer('poll');
		clearTimer('event');
		doc.removeEventListener('visibilitychange', visibilityChanged);
		win.removeEventListener('miclash:ubus-event', ubusEvent);
		for (const url of objectUrls) win.URL.revokeObjectURL(url);
		objectUrls.clear();
		if (typeof api.destroy === 'function') api.destroy();
		host = null;
	}

	doc.addEventListener('visibilitychange', visibilityChanged);
	win.addEventListener('miclash:ubus-event', ubusEvent);

	return { renderSummary, openDetails, downloadReport, openRouteTest, mount, refresh, destroy };
}

return { create };
