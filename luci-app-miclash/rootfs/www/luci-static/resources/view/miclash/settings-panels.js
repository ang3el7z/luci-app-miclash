'use strict';
'require baseclass';
'require ui';
'require view.miclash.background-refresh';
'require view.miclash.ui-shell';

const MASK = '[REDACTED]';
const SOURCE = 'luci';
const POLL_MS = 30000;
const MAX_POLL_MS = 300000;
const KNOWN_CHANNELS = [ 'luci', 'syslog', 'telegram' ];
const KNOWN_EVENTS = [ 'guard_outage', 'failure', 'recovery', 'fail_closed',
	'direct_fallback', 'memory_action', 'memory_outcome', 'subscription_outcome',
	'update_outcome', 'internet_restored' ];
const LUCI_ONLY_EVENTS = [ 'miclash_event' ];
const MEMORY_FIELDS = {
	sample_interval_ms: [ 10000, 3600000, 60000 ], sustained_samples: [ 2, 60, 5 ],
	warmup_ms: [ 60000, 86400000, 900000 ], baseline_samples: [ 3, 60, 6 ],
	anomaly_percent: [ 110, 500, 150 ], anomaly_growth_kb: [ 4096, 262144, 16384 ],
	reserve_percent: [ 5, 50, 10 ], reserve_min_kb: [ 4096, 262144, 16384 ],
	reserve_max_kb: [ 8192, 1048576, 65536 ], drop_percent: [ 5, 90, 10 ],
	drop_min_kb: [ 1024, 262144, 8192 ], success_cooldown_ms: [ 60000, 604800000, 21600000 ],
	failure_cooldown_ms: [ 60000, 604800000, 86400000 ], normal_rearm_ms: [ 60000, 86400000, 1800000 ]
};
const MEMORY_LABELS = {
	sample_interval_ms: () => _('Sample interval (ms)'), sustained_samples: () => _('Sustained samples'),
	warmup_ms: () => _('Warm-up time (ms)'), baseline_samples: () => _('Baseline samples'),
	anomaly_percent: () => _('Anomaly threshold (%)'), anomaly_growth_kb: () => _('Anomaly growth (KiB)'),
	reserve_percent: () => _('Memory reserve (%)'), reserve_min_kb: () => _('Minimum reserve (KiB)'),
	reserve_max_kb: () => _('Maximum reserve (KiB)'), drop_percent: () => _('Required drop (%)'),
	drop_min_kb: () => _('Minimum drop (KiB)'), success_cooldown_ms: () => _('Success cooldown (ms)'),
	failure_cooldown_ms: () => _('Failure cooldown (ms)'), normal_rearm_ms: () => _('Normal rearm delay (ms)')
};
const EVENT_LABELS = {
	miclash_event: () => _('MiClash events'),
	guard_outage: () => _('Guard outage'), failure: () => _('Component failure'), recovery: () => _('Recovery'),
	fail_closed: () => _('Fail-closed protection'), direct_fallback: () => _('Direct fallback'),
	memory_action: () => _('Memory action'), memory_outcome: () => _('Memory outcome'),
	subscription_outcome: () => _('Subscription result'), update_outcome: () => _('Update result'),
	internet_restored: () => _('Internet restored')
};

function value(value, fallback) { return value == null || value === '' ? (fallback || '-') : String(value); }
function exactTelegramId(value) { return /^(?:[1-9][0-9]{0,31})$/.test(String(value || '').trim()); }
function normalizeTelegramIds(value) {
	if (!String(value || '').trim()) return '';
	const seen = new Set();
	for (const item of String(value || '').split(',')) {
		const id = item.trim();
		if (!exactTelegramId(id)) throw new Error(_('Enter exact numeric Telegram user IDs separated by commas.'));
		seen.add(id);
	}
	return Array.from(seen).join(', ');
}
function exactTelegramToken(value) { return /^(?:[1-9][0-9]{0,19}:[A-Za-z0-9_-]{8,128})$/.test(String(value || '').trim()); }
function integer(value, bounds, name) {
	const text = String(value == null ? '' : value).trim();
	if (!/^[0-9]+$/.test(text)) throw new Error(_('%s must be an integer.').format(name));
	const number = Number(text);
	if (!Number.isSafeInteger(number) || number < bounds[0] || number > bounds[1])
		throw new Error(_('%s is outside the safe range.').format(name));
	return number;
}
function label(text, input) {
	const id = input.getAttribute('id');
	return E('label', id ? { 'for': id } : {}, text);
}
function field(id, title, input) {
	input.setAttribute('id', id);
	return E('div', { 'class': 'sbox-management-field' }, [ label(title, input), input ]);
}
function check(id, title, checked, group, name) {
	const attrs = { 'id': id, 'type': 'checkbox' };
	if (checked) attrs.checked = 'checked';
	if (group) attrs['data-' + group] = name;
	return E('label', { 'class': 'sbox-checkbox-row', 'for': id }, [ E('input', attrs), E('span', {}, title) ]);
}
function action(labelText, action, positive) {
	return E('button', { 'type': 'button', 'class': 'cbi-button ' + (positive ? 'cbi-button-apply' : 'cbi-button-neutral'),
		'data-action': action }, labelText);
}
function operationError(record) {
	const error = new Error(record?.error?.message || _('Operation failed.'));
	error.code = record?.error?.code || 'OPERATION_FAILED';
	return error;
}

function create(options) {
	options = options || {};
	const api = options.api, doc = options.document || document, win = options.window || window;
	if (!api || typeof api.memoryStatus !== 'function' || typeof api.memorySettings !== 'function' ||
		typeof api.memoryResetBaseline !== 'function' || typeof api.telegram_status !== 'function' ||
		typeof api.telegram_settings !== 'function' || typeof api.telegram_token_reveal !== 'function' ||
		typeof api.telegram_test !== 'function' ||
		typeof api.notificationSettings !== 'function' || typeof api.testNotification !== 'function' ||
		typeof api.settings_get !== 'function' ||
		typeof api.watchOperation !== 'function') throw new Error('Typed settings API is required');
	let host = null, destroyed = false, generation = 0, timer = null, busy = false,
		dirty = false, retryMs = POLL_MS;
	let active = false;
	let hydrated = false;
	let notificationTab = 'luci';
	let state = { desired: {}, memory: {}, memorySettings: {}, telegram: {}, telegramSettings: {}, notifications: {} };
	const cancels = new Set();

	function report(error, context) {
		if (destroyed) return;
		if (typeof options.onError === 'function') options.onError(error, context || {});
		else ui.addNotification(null, E('p', {}, String(error?.message || error)), 'error');
	}
	const backgroundRefresh = view_miclash_background_refresh.create(report);
	function progress(message, record) {
		if (typeof options.onProgress === 'function') options.onProgress(message, record || null);
	}
	function publishNotificationSettings() {
		if (typeof options.onNotificationSettings !== 'function') return;
		const desired = state.desired?.notifications || {};
		options.onNotificationSettings({
			auto_hide: desired.auto_hide !== false,
			luci_enabled: desired.luci_enabled === true,
			luci_events: Array.isArray(desired.luci_events) ? desired.luci_events.slice() : []
		});
	}
	function clearTimer() { if (timer != null) win.clearTimeout(timer); timer = null; }
	function schedule(delay) {
		clearTimer();
		if (destroyed || !active || doc.hidden || !host) return;
		timer = win.setTimeout(() => { timer = null; backgroundRefresh.run(() => refresh()); }, delay || retryMs);
	}
	function awaitOperation(reply, title) {
		const id = reply?.operation_id;
		if (typeof id !== 'string' || !id.length) return Promise.reject(new Error(_('Invalid operation response.')));
		return new Promise((resolve, reject) => {
			let finished = false, cancel = null;
			const done = (callback, argument) => {
				if (finished) return; finished = true;
				if (cancel) { cancels.delete(cancel); cancel(); }
				callback(argument);
			};
			cancel = api.watchOperation(id, (record, error) => {
				if (destroyed) return done(reject, new Error('CANCELLED'));
				if (error) return done(reject, error);
				progress(title, record);
				if (record?.state === 'success') done(resolve, record);
				else if (record?.state === 'failure' || record?.state === 'interrupted') done(reject, operationError(record));
			});
			if (!finished && typeof cancel === 'function') cancels.add(cancel);
		});
	}

	function memorySection() {
		const desired = state.desired.memory || {}, current = state.memory || {};
		const settings = Object.assign({}, Object.fromEntries(Object.entries(MEMORY_FIELDS).map(([ name, bound ]) => [ name, bound[2] ])),
			state.memorySettings || {}, desired || {});
		const expertFields = Object.entries(MEMORY_FIELDS).map(([ name, bounds ]) => field(
			'sbox-memory-' + name.replaceAll('_', '-'), MEMORY_LABELS[name](),
			E('input', { 'type': 'number', 'class': 'cbi-input-text', 'min': bounds[0], 'max': bounds[1],
				'step': '1', 'value': settings[name] })
		));
		const children = [
			E('h4', {}, _('Memory monitoring')),
			check('sbox-management-memory-enabled', _('Monitor abnormal Mihomo memory usage'), desired.enabled === true),
			E('p', { 'class': 'sbox-muted sbox-settings-help' },
				_('Learns normal Mihomo memory use and applies staged recovery only during sustained system memory pressure.')),
			E('details', { 'class': 'sbox-management-expert' }, [
				E('summary', {}, _('Expert settings')),
				E('p', { 'class': 'sbox-muted' }, _('Adaptive defaults are recommended. Unsafe values are rejected.')),
				E('div', { 'class': 'sbox-management-form-grid' }, expertFields)
			])
		];
		if (desired.enabled === true && current.baseline_rss_kb != null)
			children.push(E('div', { 'class': 'sbox-management-actions' }, [ action(_('Reset baseline'), 'memory-reset') ]));
		return E('section', { 'class': 'sbox-integration-pane sbox-memory-pane', 'data-panel': 'memory' }, children);
	}

	function telegramSection() {
		const desired = state.desired.telegram || {}, settings = state.telegramSettings || {}, status = state.telegram || {};
		const userId = settings.user_id ? normalizeTelegramIds(settings.user_id) : '';
		// telegram_settings always redacts the token field, including an empty one;
		// only the dedicated status flag can tell whether a secret is configured.
		const configured = status.configured === true;
		const tokenInput = E('input', { 'id': 'sbox-telegram-token', 'type': 'password', 'class': 'cbi-input-text',
			'value': configured ? MASK : '', 'autocomplete': 'new-password' });
		const reveal = E('button', { 'type': 'button', 'class': 'cbi-button cbi-button-neutral sbox-secret-reveal',
			'data-action': 'telegram-token-reveal', 'aria-label': _('Show token'), 'aria-pressed': 'false' },
			[ E('span', { 'aria-hidden': 'true' }, '*') ]);
		const tokenField = E('div', { 'class': 'sbox-management-field' }, [
			E('label', { 'for': 'sbox-telegram-token' }, _('BotFather token')),
			E('div', { 'class': 'sbox-secret-input' }, [ tokenInput, reveal ])
		]);
		const userInput = E('input', { 'id': 'sbox-telegram-user-id', 'type': 'text',
			'class': 'cbi-input-text', 'value': userId, 'inputmode': 'numeric', 'autocomplete': 'off' });
		const userField = E('div', { 'class': 'sbox-management-field' }, [
			label(_('Allowed Telegram user IDs'), userInput),
			userInput,
			E('p', { 'class': 'sbox-muted', 'data-telegram-id-hint': 'true' },
				_('List IDs separated by commas.'))
		]);
		const pollTimeout = Number.isInteger(desired.poll_timeout_seconds) ? desired.poll_timeout_seconds : 25;
		const timeoutField = field('sbox-telegram-poll-timeout', _('Telegram polling timeout (seconds)'), E('input', {
			'type': 'number', 'class': 'cbi-input-text', 'min': '5', 'max': '50', 'step': '1', 'value': pollTimeout
		}));
		const children = [
			E('h4', {}, _('Telegram')),
			check('sbox-telegram-enabled', _('Enable Telegram control'), desired.enabled === true),
			E('p', { 'class': 'sbox-muted', 'role': 'status', 'data-telegram-status': 'running' },
				status.running === true ? _('Poller is running') : _('Poller is stopped')),
			E('div', { 'class': 'sbox-telegram-fields' }, [ tokenField, userField, timeoutField ])
		];
		if (desired.enabled === true)
			children.push(E('div', { 'class': 'sbox-management-actions' }, [
				action(_('Send test'), 'telegram-test')
			]));
		return E('section', { 'class': 'sbox-integration-pane sbox-telegram-pane',
			'data-panel': 'telegram' }, children);
	}

	function protectionIntegrationSection() {
		return E('article', {
			'class': 'sbox-settings-card sbox-integration-card sbox-protection-integration-card sbox-management-card sbox-management-wide'
		}, [ memorySection(), telegramSection() ]);
	}

	function notificationSection() {
		const desired = state.desired.notifications || {}, runtime = state.notifications || {};
		const channelLabel = (name) => name === 'syslog' ? _('Logs') : name === 'telegram' ? _('Telegram') : _('LuCI');
		const tabs = KNOWN_CHANNELS.map((name) => E('button', {
			'type': 'button',
			'class': (notificationTab === name ? 'cbi-tab' : 'cbi-tab-disabled') + ' sbox-tab',
			'role': 'tab',
			'id': 'sbox-notification-tab-' + name,
			'data-notification-tab': name,
			'aria-controls': 'sbox-notification-pane-' + name,
			'aria-selected': notificationTab === name ? 'true' : 'false'
		}, channelLabel(name)));
		const panes = KNOWN_CHANNELS.map((name) => {
			const configured = desired[name + '_enabled'] ?? runtime[name + '_enabled'];
			const selected = Array.isArray(desired[name + '_events']) ? desired[name + '_events'] :
				(Array.isArray(runtime[name + '_events']) ? runtime[name + '_events'] : []);
			const enabled = check('sbox-notify-enabled-' + name, _('Enabled'), configured === true,
				'notification-enabled', name);
			const channelEvents = name === 'luci' ? [ ...LUCI_ONLY_EVENTS, ...KNOWN_EVENTS ] : KNOWN_EVENTS;
			const events = channelEvents.map((event) => {
				const node = check('sbox-notify-' + name + '-' + event, EVENT_LABELS[event](),
					selected.includes(event), 'notification-event', event);
				const input = node.querySelector('input');
				if (input) input.setAttribute('data-notification-channel', name);
				return node;
			});
			const children = [
				enabled,
				E('h5', {}, _('Notification events')),
				E('div', { 'class': 'sbox-management-switches sbox-notification-event-grid' }, events)
			];
			if (name === 'luci')
				children.splice(1, 0, check('sbox-notification-auto-hide',
					_('Automatically close LuCI notifications'), desired.auto_hide !== false));
			if (configured === true) {
				const test = action(_('Send test'), 'notification-test');
				test.setAttribute('data-notification-test', name);
				children.push(E('div', { 'class': 'sbox-management-actions' }, [ test ]));
			}
			return E('section', {
				'class': 'sbox-notification-pane',
				'role': 'tabpanel',
				'id': 'sbox-notification-pane-' + name,
				'data-notification-pane': name,
				'aria-labelledby': 'sbox-notification-tab-' + name,
				'hidden': notificationTab === name ? null : 'hidden'
			}, children);
		});
		return E('article', { 'class': 'sbox-settings-card sbox-integration-card sbox-notifications-card sbox-management-card sbox-management-wide',
			'data-panel': 'notifications' }, [
			E('h4', {}, _('Notifications')),
			E('div', { 'class': 'cbi-tabmenu sbox-tabs sbox-notification-tabs', 'role': 'tablist' }, tabs),
			...panes
		]);
	}
	function loadingPane(title) {
		return E('section', { 'class': 'sbox-integration-pane' }, [
			E('h4', {}, title),
			view_miclash_ui_shell.loadingBlock({ kind: 'normal', lines: 4 })
		]);
	}
	function paintLoading() {
		if (!host || destroyed) return;
		host.replaceChildren(
			E('article', { 'class': 'sbox-settings-card sbox-integration-card sbox-protection-integration-card sbox-management-card sbox-management-wide' }, [
				loadingPane(_('Memory monitoring')), loadingPane(_('Telegram'))
			]),
			E('article', { 'class': 'sbox-settings-card sbox-integration-card sbox-notifications-card sbox-management-card sbox-management-wide' }, [
				E('h4', {}, _('Notifications')),
				view_miclash_ui_shell.loadingBlock({ kind: 'normal', lines: 5 })
			])
		);
	}

	function paint() {
		if (!host || destroyed) return;
		host.replaceChildren(protectionIntegrationSection(), notificationSection());
		bind();
	}
	function formPatch() {
		const memory = { enabled: !!host.querySelector('#sbox-management-memory-enabled')?.checked };
		for (const [ name, bounds ] of Object.entries(MEMORY_FIELDS)) {
			const input = host.querySelector('#sbox-memory-' + name.replaceAll('_', '-'));
			memory[name] = integer(input?.value, bounds, name);
		}
		if (memory.reserve_min_kb > memory.reserve_max_kb ||
			memory.failure_cooldown_ms < memory.success_cooldown_ms ||
			memory.warmup_ms < memory.sample_interval_ms)
			throw new Error(_('Memory expert settings are internally inconsistent.'));
		const enabled = !!host.querySelector('#sbox-telegram-enabled')?.checked;
		const token = String(host.querySelector('#sbox-telegram-token')?.value || '').trim();
		const userId = normalizeTelegramIds(host.querySelector('#sbox-telegram-user-id')?.value || '');
		if (token !== MASK && token && !exactTelegramToken(token)) throw new Error(_('Enter a valid BotFather token.'));
		const normalizedUserIds = userId ? normalizeTelegramIds(userId) : '';
		const configured = state.telegram?.configured === true;
		const hasToken = token === MASK ? configured : exactTelegramToken(token);
		if (enabled && !(hasToken && normalizedUserIds))
			throw new Error(_('Enabling Telegram requires a BotFather token and exact user IDs.'));
		const telegram = { enabled, user_id: normalizedUserIds };
		telegram.poll_timeout_seconds = integer(host.querySelector('#sbox-telegram-poll-timeout')?.value,
			[ 5, 50 ], _('Telegram polling timeout'));
		if (token !== MASK) telegram.token = token;
		const notifications = {
			auto_hide: !!host.querySelector('#sbox-notification-auto-hide')?.checked
		};
		for (const channel of KNOWN_CHANNELS) {
			notifications[channel + '_enabled'] =
				!!host.querySelector('[data-notification-enabled="' + channel + '"]')?.checked;
			notifications[channel + '_events'] = Array.from(host.querySelectorAll(
				'[data-notification-channel="' + channel + '"][data-notification-event]'))
				.filter((input) => input.checked)
				.map((input) => input.getAttribute('data-notification-event'))
				.filter((event) => (channel === 'luci' ?
					[ ...LUCI_ONLY_EVENTS, ...KNOWN_EVENTS ] : KNOWN_EVENTS).includes(event));
		}
		return { memory, telegram, notifications };
	}
	function collectPatch() {
		if (!host || destroyed) throw new Error(_('Settings panel is not available.'));
		if (!hydrated) throw new Error(_('Settings panel is still loading.'));
		return formPatch();
	}
	async function markSaved() {
		dirty = false;
		await refresh(true, true);
	}
	async function sendTelegramTest() {
		progress(_('Sending Telegram test message…'));
		const reply = await api.telegram_test();
		if (reply?.sent !== true) throw new Error(_('Telegram test message was not sent.'));
		if (typeof options.onSuccess === 'function') options.onSuccess(_('Telegram test message sent.'));
	}
	async function withBusy(button, callback) {
		if (busy || destroyed) return;
		busy = true; if (button) button.disabled = true;
		try { return await callback(); }
		finally { busy = false; if (button && !destroyed) button.disabled = false; }
	}
	function bind() {
		const markDirty = () => { dirty = true; };
		for (const input of [ ...host.querySelectorAll('input'), ...host.querySelectorAll('select') ]) {
			input.addEventListener('input', markDirty);
			input.addEventListener('change', markDirty);
		}
		for (const tab of host.querySelectorAll('[data-notification-tab]'))
			tab.addEventListener('click', () => {
				const selected = tab.getAttribute('data-notification-tab');
				if (!KNOWN_CHANNELS.includes(selected)) return;
				notificationTab = selected;
				for (const button of host.querySelectorAll('[data-notification-tab]')) {
					const active = button.getAttribute('data-notification-tab') === selected;
					button.classList.toggle('cbi-tab', active);
					button.classList.toggle('cbi-tab-disabled', !active);
					button.setAttribute('aria-selected', active ? 'true' : 'false');
				}
				for (const pane of host.querySelectorAll('[data-notification-pane]'))
					pane.hidden = pane.getAttribute('data-notification-pane') !== selected;
			});
		for (const button of host.querySelectorAll('[data-action]')) button.addEventListener('click', () => {
			const actionName = button.getAttribute('data-action');
			const testAction = [ 'telegram-test', 'notification-test' ].includes(actionName);
			const run = () => withBusy(testAction ? null : button, async () => {
				if (actionName === 'telegram-token-reveal') {
					const input = host.querySelector('#sbox-telegram-token');
					if (!input) return;
					if (input.type === 'text') {
						input.type = 'password';
						button.setAttribute('aria-label', _('Show token'));
						button.setAttribute('aria-pressed', 'false');
						return;
					}
					if (input.value === MASK) {
						const reply = await api.telegram_token_reveal();
						if (!exactTelegramToken(reply?.token)) throw new Error(_('Telegram token is not configured.'));
						input.value = reply.token;
						input.dataset.originalTelegramToken = reply.token;
					}
					input.type = 'text';
					button.setAttribute('aria-label', _('Hide token'));
					button.setAttribute('aria-pressed', 'true');
				}
				else if (actionName === 'memory-reset') {
					await awaitOperation(await api.memoryResetBaseline(SOURCE), _('Resetting memory baseline…'));
					await refresh(true);
				}
				else if (actionName === 'telegram-test') {
					await sendTelegramTest();
				}
				else if (actionName === 'notification-test') {
					const channel = button.getAttribute('data-notification-test');
					if (!KNOWN_CHANNELS.includes(channel)) throw new Error(_('Invalid notification channel.'));
					const reply = await api.testNotification(channel);
					if (reply?.sent !== true) throw new Error(_('Notification test message was not sent.'));
				}
			});
			const promise = testAction
				? view_miclash_ui_shell.withButtons(button, run)
				: run();
			promise.catch(report);
		});
	}

	async function refresh(force, replaceForm) {
		if (destroyed || !active && !force || doc.hidden && !force) return;
		const token = ++generation;
		try {
			const replies = await Promise.all([ api.settings_get(), api.memoryStatus(), api.telegram_status() ]);
			if (destroyed || token !== generation) return;
			const desired = replies[0] || {};
			state = { desired, memory: replies[1] || {}, memorySettings: desired.memory || {},
				telegram: replies[2] || {}, telegramSettings: desired.telegram || {},
				notifications: desired.notifications || {} };
			hydrated = true;
			publishNotificationSettings();
			retryMs = POLL_MS;
			if (replaceForm || (!dirty && !busy)) paint();
		}
		catch (error) { retryMs = Math.min(MAX_POLL_MS, Math.max(POLL_MS, retryMs * 2)); throw error; }
		finally { if (!destroyed && token === generation) schedule(); }
	}
	function visibilitychange() {
		if (doc.hidden) clearTimer();
		else if (active) backgroundRefresh.run(() => refresh());
	}
	function mount(node) {
		host = node; destroyed = false;
		if (hydrated) paint(); else paintLoading();
		if (active) backgroundRefresh.run(() => refresh());
		return host;
	}
	function setActive(value) {
		active = value === true;
		if (!active) { clearTimer(); return false; }
		if (!destroyed && !doc.hidden) backgroundRefresh.run(() => refresh());
		return true;
	}
	function destroy() {
		if (destroyed) return; destroyed = true; generation++; clearTimer();
		doc.removeEventListener('visibilitychange', visibilitychange);
		for (const cancel of cancels) cancel(); cancels.clear();
		if (typeof api.destroy === 'function') api.destroy(); host = null;
	}
	doc.addEventListener('visibilitychange', visibilitychange);
	return { mount, refresh, setActive, destroy, collectPatch, markSaved, ready: () => hydrated,
		exactTelegramId, exactTelegramToken };
}

return baseclass.extend({
	create,
	exactTelegramId,
	exactTelegramToken,
	KNOWN_EVENTS,
	LUCI_ONLY_EVENTS,
	KNOWN_CHANNELS,
	MEMORY_FIELDS,
	MEMORY_LABELS,
	EVENT_LABELS
});
