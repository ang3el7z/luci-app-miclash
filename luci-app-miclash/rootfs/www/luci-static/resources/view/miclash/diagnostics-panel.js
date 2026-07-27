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
const MODES = {
	silent: { button: 'cbi-button-positive', label: _('Download Silent') },
	lite: { button: 'cbi-button-action', label: _('Download Lite') },
	full: { button: 'cbi-button-negative', label: _('Download Full') }
};

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
	if (state === 'stopped') return _('Stopped');
	if (state === 'inactive') return _('Inactive');
	if (state === 'system') return _('OpenWrt');
	if (state === 'guard') return _('Guard');
	if (state === 'failed' || state === 'error') return _('Failed');
	return _('Unknown');
}

function stateClass(value) {
	const state = String(value || 'unknown').toLowerCase();
	if (state === 'ok' || state === 'running' || state === 'ready' || state === 'success' || state === 'guard') return 'sbox-diagnostics-state-ok';
	if (state === 'degraded' || state === 'warning') return 'sbox-diagnostics-state-warning';
	if (state === 'failed' || state === 'error') return 'sbox-diagnostics-state-error';
	return 'sbox-diagnostics-state-unknown';
}

function statusNode(label, value, displayName) {
	const readable = displayName || stateName(value);
	return E('span', {
		'class': 'sbox-diagnostics-state ' + stateClass(value),
		'role': 'status',
		'aria-label': label + ': ' + readable
	}, [ E('span', { 'class': 'sbox-diagnostics-state-icon', 'aria-hidden': 'true' }, '●'), readable ]);
}

function configSchedulerState(value) {
	if (!value || typeof value !== 'object') return { state: 'unknown', label: _('Unknown') };
	if (value.enabled !== true) {
		if (value.reason === 'no_url') return { state: 'unknown', label: _('Not configured') };
		if (value.reason === 'invalid_settings') return { state: 'error', label: _('Configuration error') };
		return { state: 'unknown', label: _('Disabled') };
	}
	if (value.running !== true) return { state: 'error', label: _('Failed') };
	if (value.pending_operation_id) return { state: 'warning', label: _('Updating') };
	if (value.last_failure_code) return { state: 'error', label: _('Failed') };
	if (value.next_attempt != null) return { state: 'warning', label: _('Scheduled') };
	return { state: 'ready', label: _('Ready') };
}

function miclashSchedulerState(value) {
	if (!value || typeof value !== 'object') return { state: 'unknown', label: _('Unknown') };
	if (value.enabled !== true) return { state: 'unknown', label: _('Disabled') };
	if (value.running !== true) return { state: 'error', label: _('Failed') };
	if (value.local_time_valid !== true || value.last_error_code === 'CLOCK_INVALID')
		return { state: 'error', label: _('Clock unavailable') };
	if (value.pending_operation_id) return { state: 'warning', label: _('Updating') };
	if ([ 'ASSETS_PENDING', 'BUSY', 'TRAFFIC_BUSY', 'TRAFFIC_UNAVAILABLE' ]
		.includes(value.last_error_code) || value.readiness === 'assets_pending' || value.pending_target)
		return { state: 'warning', label: _('Waiting') };
	if (value.last_error_code || value.readiness === 'error')
		return { state: 'error', label: _('Failed') };
	if (value.next_check != null) return { state: 'warning', label: _('Scheduled') };
	return { state: 'ready', label: _('Ready') };
}

function telegramComponentState(value) {
	if (!value || typeof value !== 'object') return { state: 'unknown', label: _('Unknown') };
	if (value.enabled !== true) return { state: 'unknown', label: _('Disabled') };
	if (value.configured !== true) return { state: 'unknown', label: _('Not configured') };
	if (value.running !== true || value.last_error || Number(value.failures) > 0)
		return { state: 'error', label: _('Failed') };
	return { state: 'ready', label: _('Ready') };
}

function providerSyncState(value) {
	if (!value || typeof value !== 'object') return { state: 'unknown', label: _('Unknown') };
	if (value.running === true) return { state: 'warning', label: _('Updating') };
	if (value.reason === 'synchronized') return { state: 'ready', label: _('Synchronized') };
	if (value.reason === 'waiting_for_mihomo')
		return { state: 'unknown', label: _('Waiting for Mihomo') };
	if (value.reason === 'waiting_for_providers')
		return { state: 'warning', label: _('Waiting for providers') };
	if (value.reason === 'pending') return { state: 'warning', label: _('Scheduled') };
	if (value.reason) return { state: 'error', label: _('Failed') };
	return { state: 'unknown', label: _('Unknown') };
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

function memoryRssValue(memory, serviceState) {
	if (serviceState === 'stopped') return _('Inactive');
	if (serviceState !== 'running') return _('Unknown');
	let value = memoryBytes(memory, 'rss_bytes', 'current_rss_kb');
	if (value === '-') value = memoryBytes(memory, 'rss_bytes', 'rss_kb');
	return value === '-' ? _('Error') : value;
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

function memoryPhaseState(memory) {
	if (memory?.enabled !== true) return 'inactive';
	if (memory?.phase === 'monitoring') return 'ready';
	if (memory?.phase === 'failure_cooldown') return 'error';
	if ([
		'warming_up', 'learning_baseline', 'recovery_queued', 'recovering',
		'recovery_deferred', 'failure_rearm_wait', 'cooldown'
	].includes(memory?.phase)) return 'warning';
	return 'unknown';
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
	let refreshPromise = null;
	let destroyed = false;
	let active = false;
	let hasGoodSummary = false;
	const objectUrls = new Set();
	const operationCancels = new Set();
	const backgroundRefresh = view_miclash_background_refresh.create((error) => showError(error));

	function clearTimer(name) {
		const value = name === 'poll' ? pollTimer : eventTimer;
		if (value != null) win.clearTimeout(value);
		if (name === 'poll') pollTimer = null;
		else eventTimer = null;
	}

	function schedulePoll() {
		clearTimer('poll');
		if (destroyed || !active || doc.hidden) return;
		pollTimer = win.setTimeout(() => {
			pollTimer = null;
			backgroundRefresh.run(() => refresh());
		}, pollInterval);
	}

	function actionButton(label, action) {
		const button = E('button', { 'type': 'button',
			'class': 'cbi-button cbi-button-neutral', 'data-action': action }, label);
		button.addEventListener('click', () => {
			if (action === 'download-report') openReportModal();
		});
		return button;
	}

	function renderLoading() {
		return E('div', { 'class': 'sbox-diagnostics-card-grid' }, [
			E('article', { 'class': 'sbox-settings-card sbox-overview-card sbox-overview-health sbox-overview-components' }, [
				E('h4', {}, _('Components')),
				view_miclash_ui_shell.loadingBlock({ kind: 'compact', lines: 8 })
			]),
			E('article', { 'class': 'sbox-settings-card sbox-overview-card sbox-overview-protection' }, [
				E('h4', {}, _('Memory monitoring')),
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
		const serviceState = String(summary.state?.observed?.service?.state ??
			status.observed?.service?.state ?? status.state?.observed?.service?.state ??
			(typeof serviceRunning === 'boolean' ? (serviceRunning ? 'running' : 'stopped') : 'unknown')).toLowerCase();
		const diagnosticActions = [ actionButton(_('Diagnostics'), 'download-report') ];
		const componentRows = COMPONENTS.filter(([ name ]) => name !== 'guard').map(([ name, label ]) => {
			let componentState = summary.components?.[name]?.state ?? health[name]?.state;
			const guardEnabled = summary.components?.guard?.state === 'enabled';
			if (name === 'mihomo' && !componentState && typeof serviceRunning === 'boolean')
				componentState = serviceRunning ? 'running' : 'stopped';
			if (name !== 'mihomo' && !componentState && serviceState === 'stopped')
				componentState = 'inactive';
			return E('div', { 'class': 'sbox-diagnostics-row' }, [
				E('span', { 'class': 'sbox-diagnostics-label' }, label()),
				statusNode(label(), componentState, name === 'firewall' && guardEnabled && componentState === 'ready' ? _('Ready') + '*' : null)
			]);
		});
		for (const [ label, presentation ] of [
			[ _('Telegram'), telegramComponentState(summary.telegram) ],
			[ _('Provider synchronization'), providerSyncState(summary.updates?.providers) ],
			[ _('Config auto-update'), configSchedulerState(summary.updates?.automatic_config) ],
			[ _('MiClash auto-update'), miclashSchedulerState(summary.updates?.automatic_miclash) ]
		]) componentRows.push(E('div', { 'class': 'sbox-diagnostics-row' }, [
			E('span', { 'class': 'sbox-diagnostics-label' }, label),
			statusNode(label, presentation.state, presentation.label)
		]));
		return E('div', { 'class': 'sbox-diagnostics-card-grid' }, [
			E('article', { 'class': 'sbox-settings-card sbox-overview-card sbox-overview-health sbox-overview-components' }, [
				E('h4', {}, _('Components')),
				E('div', { 'class': 'sbox-diagnostics-components', 'aria-label': _('Component status') }, componentRows),
				E('div', { 'class': 'sbox-diagnostics-actions', 'aria-label': _('Diagnostic actions') },
					diagnosticActions)
			]),
			E('article', { 'class': 'sbox-settings-card sbox-overview-card sbox-overview-protection' }, [
				E('h4', {}, _('Memory monitoring')),
				E('div', { 'class': 'sbox-diagnostics-facts' }, [
					E('div', { 'class': 'sbox-diagnostics-row' }, [
						E('span', { 'class': 'sbox-diagnostics-label' }, _('Status')),
						statusNode(_('Status'), memoryPhaseState(memory), memoryPhaseValue(memory))
					]),
					valueRow(_('Mihomo memory (RSS)'), memoryRssValue(memory, serviceState)),
					valueRow(_('Baseline'), memoryBaselineValue(memory)),
					valueRow(_('Last action'), memoryActionValue(memory), 'sbox-diagnostics-row-nowrap')
				])
			])
		]);
	}

	function paint() {
		if (host && !destroyed) host.replaceChildren(renderSummary(current));
	}

	function refresh(force) {
		if (destroyed || !active && !force || doc.hidden && !force) return;
		if (refreshPromise) return refreshPromise;
		const running = (async () => {
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
				schedulePoll();
			}
		})();
		const tracked = running.finally(() => {
			if (refreshPromise === tracked) refreshPromise = null;
		});
		refreshPromise = tracked;
		return refreshPromise;
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

	function operationError(record) {
		const error = new Error(record?.error?.message || _('Unknown error'));
		error.code = record?.error?.code || 'INTERNAL';
		return error;
	}

	function reportStageLabel(stage) {
		const labels = {
			preflight: _('Preparing report'), system: _('Collecting system state'),
			configuration: _('Collecting configuration'), network: _('Collecting network state'),
			providers: _('Collecting provider state'), operations: _('Collecting operations'),
			logs: _('Collecting logs'), validation: _('Validating report'),
			complete: _('Finalizing report')
		};
		return labels[stage] || _('Creating report');
	}

	function timestampedReportName(mode) {
		const now = new Date();
		const pad = (value) => String(value).padStart(2, '0');
		return 'miclash-diagnostic-' + mode + '-' + now.getFullYear() +
			pad(now.getMonth() + 1) + pad(now.getDate()) + '-' +
			pad(now.getHours()) + pad(now.getMinutes()) + pad(now.getSeconds()) + '.json';
	}

	function waitForOperation(operationId, onProgress) {
		if (typeof api.watchOperation !== 'function' ||
			typeof operationId !== 'string' ||
			!/^[0-9]{13}-[0-9]{8}-[0-9a-f]{16}$/.test(operationId))
			return Promise.reject(Object.assign(
				new Error(_('Invalid diagnostic report response')), { code: 'INVALID_RESPONSE' }));
		return new Promise((resolve, reject) => {
			let settled = false, cancel = null, stop = null;
			const done = (callback, value) => {
				if (settled) return;
				settled = true;
				if (stop) operationCancels.delete(stop);
				if (typeof cancel === 'function') cancel();
				callback(value);
			};
			stop = () => done(reject, Object.assign(new Error('CANCELLED'), { code: 'CANCELLED' }));
			try {
				cancel = api.watchOperation(operationId, (record, error) => {
					if (destroyed) return stop();
					if (error) return done(reject, error);
					if (typeof onProgress === 'function') onProgress(record || {});
					if (record?.state === 'success') return done(resolve, record);
					if (record?.state === 'failure' || record?.state === 'interrupted')
						return done(reject, operationError(record));
				}, 1000);
			} catch (error) {
				return done(reject, error);
			}
			if (typeof cancel !== 'function')
				return done(reject, Object.assign(
					new Error(_('Invalid diagnostic report response')), { code: 'INVALID_RESPONSE' }));
			if (settled) cancel();
			else operationCancels.add(stop);
		});
	}

	function setReportButtonsDisabled(button, disabled) {
		const modal = button?.parentNode?.parentNode;
		for (const sibling of modal?.querySelectorAll('button[data-report-mode]') || [])
			sibling.disabled = disabled;
	}

	function reportProgressNode() {
		return E('div', {
			'class': 'sbox-report-progress',
			'data-report-progress': '',
			'role': 'progressbar',
			'aria-valuemin': '0',
			'aria-valuemax': '100',
			'aria-valuenow': '0',
			'aria-live': 'polite',
			'aria-atomic': 'true',
			'hidden': true
		}, [
			E('span', {
				'class': 'sbox-report-progress-fill',
				'data-report-progress-fill': '',
				'aria-hidden': 'true',
				'style': 'width: 0%'
			}),
			E('span', { 'class': 'sbox-report-progress-label',
				'data-report-progress-label': '' })
		]);
	}

	function reportErrorNode() {
		return E('p', {
			'class': 'sbox-diagnostics-error',
			'data-report-error': '',
			'role': 'alert',
			'hidden': true
		});
	}

	function reportProgressFor(button) {
		for (let node = button; node; node = node.parentNode) {
			const progress = node.querySelector?.('[data-report-progress]');
			if (progress) return progress;
		}
		return null;
	}

	function reportErrorFor(button) {
		for (let node = button; node; node = node.parentNode) {
			const error = node.querySelector?.('[data-report-error]');
			if (error) return error;
		}
		return null;
	}

	function clearReportError(button) {
		const error = reportErrorFor(button);
		if (!error) return;
		error.hidden = true;
		error.textContent = '';
	}

	function showReportModalError(button, failure) {
		const error = reportErrorFor(button);
		if (!error) return;
		const code = failure?.code ? String(failure.code) + ': ' : '';
		error.textContent = code + String(failure?.message || _('Unknown error'));
		error.hidden = false;
	}

	function setReportProgress(button, stage, value) {
		const progress = reportProgressFor(button);
		if (!progress) return;
		const amount = Number(value);
		const percent = Number.isFinite(amount)
			? Math.max(0, Math.min(100, Math.round(amount))) : 0;
		const label = String(stage || _('Creating...'));
		progress.hidden = false;
		progress.setAttribute('aria-valuenow', String(percent));
		progress.setAttribute('aria-valuetext', label + ' · ' + percent + '%');
		const fill = progress.querySelector('[data-report-progress-fill]');
		const textNode = progress.querySelector('[data-report-progress-label]');
		if (fill) fill.setAttribute('style', 'width: ' + percent + '%');
		if (textNode) textNode.textContent = label + ' · ' + percent + '%';
	}

	function resetReportProgress(button) {
		const progress = reportProgressFor(button);
		if (!progress) return;
		progress.hidden = true;
		progress.setAttribute('aria-valuenow', '0');
		progress.removeAttribute('aria-valuetext');
		const fill = progress.querySelector('[data-report-progress-fill]');
		const textNode = progress.querySelector('[data-report-progress-label]');
		if (fill) fill.setAttribute('style', 'width: 0%');
		if (textNode) textNode.textContent = '';
	}

	function openFullReportModal() {
		const confirm = E('button', { 'type': 'button',
			'class': 'cbi-button cbi-button-negative', 'data-action': 'confirm-full-report' }, _('I understand, download Full'));
		confirm.addEventListener('click', () => generateReport('full', true, confirm).catch(showError));
		const body = E('div', { 'class': 'sbox-diagnostics-modal sbox-modal-responsive sbox-report-confirmation' }, [
			E('p', {}, _('Full reports may include secrets such as subscription credentials and private configuration.')),
			E('p', { 'class': 'sbox-muted' }, _('Store this report safely and share it only with trusted support.')),
			reportProgressNode(),
			reportErrorNode(),
			E('div', { 'class': 'sbox-actions' }, [ closeButton(), confirm ])
		]);
		ui.showModal(_('Confirm Full diagnostic report'), body);
		return body;
	}

	function openReportModal() {
		const descriptions = {
			silent: _('Minimal system health only. Best for public issue reports.'),
			lite: _('Redacted diagnostics, configuration summary, and recent events.'),
			full: _('Includes private configuration and secrets. Use only with trusted support.')
		};
		const cards = Object.keys(MODES).map((mode) => {
			const button = E('button', { 'type': 'button',
				'class': 'cbi-button ' + MODES[mode].button, 'data-report-mode': mode }, MODES[mode].label);
			button.addEventListener('click', () => {
				if (mode === 'full') openFullReportModal();
				else generateReport(mode, false, button).catch(showError);
			});
			return E('article', { 'class': 'sbox-diagnostic-mode-card sbox-diagnostic-mode-' + mode }, [
				E('h4', {}, mode === 'silent' ? _('Silent') : mode === 'lite' ? _('Lite') : _('Full')),
				E('p', {}, descriptions[mode]), button
			]);
		});
		const body = E('div', { 'class': 'sbox-diagnostics-modal sbox-modal-responsive sbox-report-modal' }, [
			E('p', {}, _('Choose how much information to include in the diagnostic report.')),
			E('p', { 'class': 'sbox-muted' }, _('Lite is recommended for most support requests.')),
			E('div', { 'class': 'sbox-diagnostic-mode-grid' }, cards),
			reportProgressNode(),
			reportErrorNode(),
			E('div', { 'class': 'sbox-actions' }, [ closeButton() ])
		]);
		ui.showModal(_('Diagnostics'), body);
		return body;
	}

	async function generateReport(mode, acknowledged, button) {
		if (destroyed) return;
		if (!MODES[mode]) throw new Error(_('Invalid diagnostic report response'));
		const acknowledge_secrets = acknowledged === true;
		const originalLabel = button ? button.textContent : null;
		const originalDisabled = button ? button.disabled : false;
		if (button) {
			setReportButtonsDisabled(button, true);
			button.disabled = true;
			button.setAttribute('aria-busy', 'true');
			clearReportError(button);
			setReportProgress(button, _('Creating...'), 0);
		}
		try {
			const created = await api.createDiagnosticReport(mode, acknowledge_secrets, 'luci');
			if (destroyed) return;
			const operationId = created && created.operation_id;
			const reportId = created && created.report_id;
			if (typeof operationId !== 'string' ||
				!/^[0-9]{13}-[0-9]{8}-[0-9a-f]{16}$/.test(operationId) ||
				typeof reportId !== 'string' || !/^rpt_[0-9a-f]{32}$/.test(reportId)) {
				const error = new Error(_('Invalid diagnostic report response'));
				error.code = 'INVALID_RESPONSE';
				throw error;
			}
			await waitForOperation(operationId, (record) => {
				if (!button || destroyed) return;
				setReportProgress(button, reportStageLabel(record?.stage), record?.progress);
			});
			if (destroyed) return;
			if (button) setReportProgress(button, _('Downloading...'), 100);
			const payload = await api.downloadChunks('report', reportId, {});
			if (destroyed) return;
			const blob = new Blob([ payload ], { type: 'application/json;charset=utf-8' });
			const url = win.URL.createObjectURL(blob);
			objectUrls.add(url);
			try {
				const anchor = doc.createElement('a');
				anchor.href = url;
				anchor.download = timestampedReportName(mode);
				anchor.setAttribute('aria-hidden', 'true');
				anchor.click();
				anchor.remove();
			} finally {
				win.URL.revokeObjectURL(url);
				objectUrls.delete(url);
			}
		} catch (error) {
			if (button && !destroyed) showReportModalError(button, error);
			throw error;
		} finally {
			if (button) {
				setReportButtonsDisabled(button, false);
				button.disabled = originalDisabled;
				button.removeAttribute('aria-busy');
				button.replaceChildren(originalLabel || MODES[mode].label);
				resetReportProgress(button);
			}
		}
	}

	function downloadReport(button) {
		return generateReport('lite', false, button);
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
		} else if (active) backgroundRefresh.run(() => refresh());
	}

	function ubusEvent(event) {
		if (destroyed || !active || doc.hidden || event?.detail?.object && event.detail.object !== 'miclash') return;
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
		if (!destroyed && active && !doc.hidden) backgroundRefresh.run(() => refresh());
		return host;
	}

	function setActive(value) {
		active = value === true;
		if (!active) {
			clearTimer('poll');
			clearTimer('event');
			return false;
		}
		if (!destroyed && !doc.hidden) backgroundRefresh.run(() => refresh());
		return true;
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
		for (const cancel of operationCancels) cancel();
		operationCancels.clear();
		if (typeof api.destroy === 'function') api.destroy();
		host = null;
	}

	doc.addEventListener('visibilitychange', visibilityChanged);
	win.addEventListener('miclash:ubus-event', ubusEvent);

	return { renderSummary, downloadReport: generateReport, openReportModal, generateReport, openRouteTest, mount, refresh, setActive, destroy };
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
		refresh(force) {
			if (!panel || typeof panel.refresh !== 'function') return null;
			return panel.refresh(force === true);
		},
		setActive(value) {
			if (!panel || typeof panel.setActive !== 'function') return false;
			return panel.setActive(value);
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
