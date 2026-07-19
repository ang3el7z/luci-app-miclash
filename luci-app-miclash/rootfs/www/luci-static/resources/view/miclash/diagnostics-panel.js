'use strict';
'require baseclass';
'require ui';
'require view.miclash.background-refresh';
'require view.miclash.ui-shell';

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

function normalizedGraph(value) {
	const graph = {};
	if (Array.isArray(value)) {
		for (const item of value.slice(0, 32)) {
			if (!item || typeof item !== 'object') continue;
			const name = String(item.name || item.component || '').toLowerCase();
			if (COMPONENTS.some(([ component ]) => component === name)) graph[name] = item;
		}
		return graph;
	}
	if (!value || typeof value !== 'object') return graph;
	if (value.components != null) {
		const nested = normalizedGraph(value.components);
		if (Object.keys(nested).length) return nested;
	}
	for (const [ name ] of COMPONENTS)
		if (value[name] && typeof value[name] === 'object') graph[name] = value[name];
	return graph;
}

function readinessByName(value) {
	const readiness = {};
	if (Array.isArray(value)) {
		for (const item of value.slice(0, 32)) {
			if (!item || typeof item !== 'object') continue;
			const name = String(item.name || item.component || '').toLowerCase();
			if (name) readiness[name] = item;
		}
		return readiness;
	}
	if (!value || typeof value !== 'object') return readiness;
	for (const [ name, item ] of Object.entries(value).slice(0, 32))
		if (item && typeof item === 'object') readiness[String(name).toLowerCase()] = item;
	return readiness;
}

function combineReadiness(process, api) {
	const records = [ process, api ].filter((item) => item && typeof item === 'object');
	if (!records.length) return null;
	const rank = { failed: 4, error: 4, stopped: 4, degraded: 3, warning: 3,
		unknown: 2, ready: 1, ok: 1, running: 1, success: 1 };
	let selected = records[0];
	for (const record of records)
		if ((rank[String(record.state || 'unknown').toLowerCase()] || 2) >
		    (rank[String(selected.state || 'unknown').toLowerCase()] || 2)) selected = record;
	return { ...selected, details: { process: process || null, api: api || null } };
}

function componentGraph(state) {
	const summary = normalizedGraph(state?.summary?.health);
	if (Object.keys(summary).length) return summary;
	const direct = normalizedGraph(state?.health);
	if (Object.keys(direct).length) return direct;
	const readiness = readinessByName(state?.summary?.state?.observed?.readiness?.components);
	if (Object.keys(readiness).length) return {
		mihomo: combineReadiness(readiness.process, readiness.api),
		dns: readiness.dns,
		routing: readiness.policy,
		firewall: readiness.forward
	};
	return normalizedGraph(state?.health?.observed?.readiness?.components);
}

function dateValue(value) {
	const amount = Number(value);
	if (!Number.isFinite(amount) || amount <= 0) return '-';
	const millis = amount < 100000000000 ? amount * 1000 : amount;
	try { return new Date(millis).toLocaleString(); }
	catch (error) { return text(value); }
}

function memoryPhaseValue(memory) {
	if (memory?.enabled !== true) return _('Disabled');
	const labels = {
		waiting_for_mihomo: _('Waiting for Mihomo'),
		warming_up: _('Warming up'),
		learning_baseline: _('Learning baseline'),
		monitoring: _('Monitoring'),
		recovery_queued: _('Recovery queued'),
		recovering: _('Recovery in progress'),
		recovery_deferred: _('Recovery postponed'),
		failure_rearm_wait: _('Waiting to resume monitoring')
	};
	if (memory?.phase === 'cooldown') {
		const deadline = dateValue(memory.cooldown_until);
		return deadline === '-' ? _('Cooldown') : String(_('Cooldown until %s')).replace('%s', deadline);
	}
	if (memory?.phase === 'failure_cooldown') {
		const deadline = dateValue(memory.cooldown_until);
		return deadline === '-' ? _('Paused after failed recovery') :
			String(_('Paused after failed recovery until %s')).replace('%s', deadline);
	}
	return labels[memory?.phase] || _('Inactive');
}

function memoryBaselineValue(memory) {
	if (memory?.enabled !== true) return _('Inactive');
	const baseline = memoryBytes(memory, 'baseline_bytes', 'baseline_rss_kb');
	return baseline === '-' ? _('Not learned yet') : baseline;
}

function memoryActionValue(memory) {
	const action = {
		reload: _('Reload'), restart_core: _('Restart core'), restart_service: _('Restart service')
	}[memory?.last_action];
	if (!action) return _('Not required');
	const result = {
		success: _('Success'), failed: _('Failed'), rearmed: _('Monitoring resumed'),
		service_busy: _('Service was busy'), operation_failed: _('Operation failed'),
		interrupted: _('Interrupted')
	}[memory?.last_result];
	return result ? action + ' · ' + result : action;
}

function subscriptionValue(summary) {
	const update = summary?.updates?.subscription || summary?.updates?.last_subscription || summary?.last_subscription;
	if (update && typeof update === 'object') {
		const state = update.state || update.result || update.outcome || '-';
		const at = dateValue(update.activated_at || update.finished_at || update.at);
		return at === '-' ? text(state) : text(state) + ' · ' + at;
	}
	if (summary?.updates?.last_activation != null)
		return dateValue(summary.updates.last_activation);
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
	if (!api || typeof api.diagnosticsSummary !== 'function')
		throw new Error('Typed diagnostics API is required');

	let host = null;
	let current = { status: {}, health: {}, summary: {} };
	let pollTimer = null;
	let eventTimer = null;
	let refreshing = false;
	let refreshPending = false;
	let destroyed = false;
	let hasGoodSummary = false;
	const objectUrls = new Set();
	const backgroundRefresh = view_miclash_background_refresh.create((error) => showError(error));

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
			backgroundRefresh.run(() => refresh());
		}, pollInterval);
	}

	function actionButton(label, action) {
		const button = E('button', { 'type': 'button',
			'class': 'cbi-button cbi-button-neutral', 'data-action': action }, label);
		button.addEventListener('click', () => {
			if (action === 'download-report') downloadReport(button).catch(showError);
		});
		return button;
	}

	function renderLoading() {
		return E('div', { 'class': 'sbox-diagnostics-card-grid' }, [
			E('article', { 'class': 'sbox-settings-card sbox-overview-card sbox-overview-health sbox-overview-components' }, [
				E('h4', {}, _('Component status')),
				view_miclash_ui_shell.loadingBlock({ kind: 'compact', lines: 4 })
			]),
			E('article', { 'class': 'sbox-settings-card sbox-overview-card sbox-overview-protection' }, [
				E('h4', {}, _('Memory Guard')),
				view_miclash_ui_shell.loadingBlock({ kind: 'compact', lines: 4 })
			])
		]);
	}

	function renderSummary(state) {
		state = state || current;
		const summary = state.summary || {};
		const health = componentGraph(state);
		const memory = summary.memory || {};
		const status = state.status || {};
		const serviceRunning = summary.state?.observed?.service?.running ??
			status.observed?.service?.running ?? status.state?.observed?.service?.running ?? status.running;
		const componentRows = COMPONENTS.filter(([ name ]) => name !== 'guard').map(([ name, label ]) => {
			let componentState = health[name]?.state;
			if (name === 'mihomo' && !componentState && typeof serviceRunning === 'boolean')
				componentState = serviceRunning ? 'running' : 'stopped';
			return E('div', { 'class': 'sbox-diagnostics-row' }, [
				E('span', { 'class': 'sbox-diagnostics-label' }, label()),
				statusNode(label(), componentState)
			]);
		});
		return E('div', { 'class': 'sbox-diagnostics-card-grid' }, [
			E('article', { 'class': 'sbox-settings-card sbox-overview-card sbox-overview-health' }, [
				E('h4', {}, _('Component status')),
				E('div', { 'class': 'sbox-diagnostics-components', 'aria-label': _('Component status') }, componentRows),
				E('div', { 'class': 'sbox-diagnostics-facts' }, [
					valueRow(_('Subscription'), subscriptionValue(summary)),
					valueRow(_('Telegram'), telegramValue(summary))
				]),
				E('div', { 'class': 'sbox-diagnostics-actions', 'aria-label': _('Diagnostic actions') }, [
					actionButton(_('Download diagnostic report'), 'download-report')
				])
			]),
			E('article', { 'class': 'sbox-settings-card sbox-overview-card sbox-overview-protection' }, [
				E('h4', {}, _('Memory Guard')),
				E('div', { 'class': 'sbox-diagnostics-facts' }, [
					valueRow(_('Mihomo memory (RSS)'), memoryBytes(memory, 'rss_bytes', 'current_rss_kb') !== '-'
						? memoryBytes(memory, 'rss_bytes', 'current_rss_kb') : memoryBytes(memory, 'rss_bytes', 'rss_kb')),
					valueRow(_('Status'), memoryPhaseValue(memory)),
					valueRow(_('Baseline'), memoryBaselineValue(memory)),
					valueRow(_('Last action'), memoryActionValue(memory), 'sbox-diagnostics-row-nowrap')
				])
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
			const summary = await api.diagnosticsSummary();
			if (!summary || typeof summary !== 'object' || Array.isArray(summary))
				throw Object.assign(new Error(_('Invalid diagnostics response')), { code: 'INVALID_RESPONSE' });
			if (!destroyed) {
				current = { summary: summary || {} };
				hasGoodSummary = true;
				paint();
			}
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

	function closeButton() {
		const button = E('button', { 'type': 'button', 'class': 'cbi-button cbi-button-neutral' }, _('Close'));
		button.addEventListener('click', () => ui.hideModal());
		return button;
	}

	async function downloadReport(button) {
		if (destroyed) return;
		const originalLabel = button ? button.textContent : null;
		const originalDisabled = button ? button.disabled : false;
		if (button) {
			button.disabled = true;
			button.setAttribute('aria-busy', 'true');
			button.replaceChildren(E('span', { 'class': 'sbox-spinner', 'aria-hidden': 'true' }),
				' ' + _('Creating...'));
		}
		try {
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
		} finally {
			if (button) {
				button.disabled = originalDisabled;
				button.removeAttribute('aria-busy');
				button.replaceChildren(originalLabel || _('Download diagnostic report'));
			}
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
		const body = E('div', { 'class': 'sbox-diagnostics-modal sbox-route-modal sbox-modal-responsive' }, [
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
		} else backgroundRefresh.run(() => refresh());
	}

	function ubusEvent(event) {
		if (destroyed || doc.hidden || event?.detail?.object && event.detail.object !== 'miclash') return;
		clearTimer('event');
		eventTimer = win.setTimeout(() => {
			eventTimer = null;
			backgroundRefresh.run(() => refresh());
		}, 150);
	}

	function mount(node) {
		host = node;
		if (hasGoodSummary) paint();
		else host.replaceChildren(renderLoading());
		if (!destroyed && !doc.hidden) backgroundRefresh.run(() => refresh());
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

	return { renderSummary, downloadReport, openRouteTest, mount, refresh, destroy };
}

function createOwner(options) {
	if (!options || typeof options.createClient !== 'function' || typeof options.createPanel !== 'function')
		throw new Error('Diagnostics owner factories are required');
	let panel = null;
	return {
		replace() {
			if (panel) panel.destroy();
			panel = null;
			const client = options.createClient();
			try { panel = options.createPanel({ api: client }); }
			catch (error) {
				if (client && typeof client.destroy === 'function') client.destroy();
				throw error;
			}
			return panel;
		},
		mount(node) {
			if (panel && node) panel.mount(node);
			return panel;
		},
		openRouteTest() {
			if (!panel || typeof panel.openRouteTest !== 'function') return null;
			return panel.openRouteTest();
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
