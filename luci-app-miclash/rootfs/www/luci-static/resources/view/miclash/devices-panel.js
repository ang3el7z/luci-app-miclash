'use strict';
'require baseclass';
'require ui';
'require view.miclash.background-refresh';
'require view.miclash.device-vendors';
'require view.miclash.ui-shell';

const SOURCE = 'luci';
const POLL_MS = 30000;
const MAX_POLL_MS = 300000;
const MAC = /^[0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){5}$/;
const ACTIONS = [ 'inherit', 'direct', 'block' ];

function text(value, fallback) { return String(value == null || value === '' ? (fallback || '-') : value); }
function normalizedMac(value) {
	const mac = String(value || '').trim().toUpperCase();
	const first = MAC.test(mac) ? Number.parseInt(mac.slice(0, 2), 16) : -1;
	if (!MAC.test(mac) || (first & 1) !== 0 || mac === '00:00:00:00:00:00' || mac === 'FF:FF:FF:FF:FF:FF')
		throw new Error(_('Enter a valid MAC address such as AA:BB:CC:DD:EE:FF.'));
	return mac;
}
function currentAddresses(device) {
	const addresses = (Array.isArray(device?.addresses) ? device.addresses : [])
		.filter((item) => item?.current === true).map((item) => text(item.address));
	return Array.from(new Set(addresses)).slice(0, 8);
}
function deviceMac(value) {
	const mac = String(value || '').trim().toUpperCase();
	return MAC.test(mac) ? mac : '';
}
function deviceOnline(device) {
	return (Array.isArray(device?.addresses) ? device.addresses : [])
		.some((item) => item?.current === true && item?.source === 'neighbor');
}
function explicitPolicy(policy) {
	return !!policy && [ 'direct', 'block' ].includes(policy.action);
}
function policyIntent(policy, mac) {
	const schedule = policy?.schedule;
	return {
		scope: 'device',
		mac: deviceMac(mac || policy?.mac),
		action: ACTIONS.includes(policy?.action) ? policy.action : 'inherit',
		schedule: schedule ? {
			days: Array.isArray(schedule.days) ? schedule.days.slice() : [],
			start: String(schedule.start || ''), end: String(schedule.end || ''),
			timezone: String(schedule.timezone || '')
		} : null
	};
}
function samePolicyIntent(left, right, mac) {
	return JSON.stringify(policyIntent(left, mac)) === JSON.stringify(policyIntent(right, mac));
}
function createPolicyDrafts() {
	const drafts = new Map();
	return {
		stage(mac, wanted, persisted) {
			const key = deviceMac(mac);
			if (!key) throw new Error(_('Enter a valid MAC address such as AA:BB:CC:DD:EE:FF.'));
			const base = explicitPolicy(persisted) ? persisted : null;
			const next = policyIntent(wanted, key);
			if ((!base && next.action === 'inherit') || (base && samePolicyIntent(next, base, key))) {
				drafts.delete(key);
				return null;
			}
			const draft = {
				...next,
				id: base?.id || null,
				expected_revision: base?.revision == null ? null : Number(base.revision)
			};
			drafts.set(key, draft);
			return { ...draft };
		},
		get(mac) { const value = drafts.get(deviceMac(mac)); return value ? { ...value } : null; },
		has(mac) { return drafts.has(deviceMac(mac)); },
		remove(mac) { drafts.delete(deviceMac(mac)); },
		list() { return Array.from(drafts.values(), (value) => ({ ...value })); }
	};
}
function policyPresentation(policy, effective) {
	const configured = ACTIONS.includes(policy?.action) ? policy.action : 'inherit';
	const enforced = ACTIONS.includes(effective?.action) ? effective.action : configured;
	const safety = String(effective?.safety || 'ordinary');
	return { configured, effective: enforced, safety, overridden: enforced !== configured };
}
function deviceDisplayName(label, unknownLabel) {
	const unknown = String(unknownLabel || 'Unknown device');
	if (label?.kind === 'hostname') return label.hostname;
	if (label?.kind === 'generic') return label.manufacturer
		? `${label.manufacturer} · ${label.hostname}` : label.hostname;
	if (label?.kind === 'manufacturer') return `${label.manufacturer} — ${unknown}`;
	return unknown;
}
async function loadVendorDatabase(loader) {
	try {
		const content = await loader();
		return view_miclash_device_vendors.parseDatabase(content);
	}
	catch (error) { return null; }
}
function mergeDevice(current, incoming, mac) {
	const addresses = [], seen = new Set();
	for (const item of [ ...(current?.addresses || []), ...(incoming?.addresses || []) ]) {
		const key = [ item?.family, item?.address, item?.source, ...(item?.interfaces || []) ].join('|');
		if (!seen.has(key)) { seen.add(key); addresses.push(item); }
	}
	return {
		...(current || {}), ...(incoming || {}), mac,
		hostname: current?.hostname || incoming?.hostname || null,
		last_seen: Math.max(Number(current?.last_seen) || 0, Number(incoming?.last_seen) || 0),
		addresses
	};
}
function deviceRows(discovered, savedPolicies, vendorDatabase) {
	const devices = new Map(), policies = new Map();
	for (const device of Array.isArray(discovered) ? discovered : []) {
		const mac = deviceMac(device?.mac);
		if (mac) devices.set(mac, mergeDevice(devices.get(mac), device, mac));
	}
	for (const policy of Array.isArray(savedPolicies) ? savedPolicies : []) {
		if (policy?.scope !== 'device') continue;
		const mac = deviceMac(policy?.mac);
		if (mac && !policies.has(mac)) policies.set(mac, policy);
	}
	for (const [ mac, policy ] of policies)
		if (explicitPolicy(policy) && !devices.has(mac))
			devices.set(mac, { mac, hostname: null, last_seen: 0, addresses: [] });
	const rows = [];
	for (const [ mac, device ] of devices) {
		const policy = policies.get(mac) || null;
		rows.push({ mac, device, policy, effective: device?.effective || null,
			explicit: explicitPolicy(policy), online: deviceOnline(device),
			label: view_miclash_device_vendors.resolveDeviceLabel(device, vendorDatabase) });
	}
	return rows.sort((left, right) => {
		if (left.explicit !== right.explicit) return left.explicit ? -1 : 1;
		if (left.online !== right.online) return left.online ? -1 : 1;
		const leftName = deviceDisplayName(left.label, '').toLocaleLowerCase();
		const rightName = deviceDisplayName(right.label, '').toLocaleLowerCase();
		if (leftName !== rightName) return leftName < rightName ? -1 : 1;
		return left.mac.localeCompare(right.mac);
	});
}
function operationError(record) {
	const error = new Error(record?.error?.message || _('Operation failed.'));
	error.code = record?.error?.code || 'OPERATION_FAILED'; return error;
}

function create(options) {
	options = options || {};
	const api = options.api, doc = options.document || document, win = options.window || window;
	if (!api || typeof api.devicesList !== 'function' || typeof api.deviceTimezones !== 'function' ||
		typeof api.devicePolicies !== 'function' ||
		typeof api.setDevicePolicy !== 'function' || typeof api.deleteDevicePolicy !== 'function' ||
		typeof api.watchOperation !== 'function') throw new Error('Typed devices API is required');
	let host = null, destroyed = false, generation = 0, timer = null, modalGeneration = 0;
	let active = false;
	let devices = [], policies = [], timezones = [ 'UTC' ], busy = false, pendingMac = '', retryMs = POLL_MS;
	let refreshPromise = null;
	let hydrated = false;
	let devicesReady = false, policiesReady = false, timezonesReady = false;
	const policyDrafts = createPolicyDrafts();
	let vendorDatabase = null, vendorLoadState = 'idle';
	const cancels = new Set();
	const vendorLoader = typeof options.loadVendorDatabase === 'function'
		? options.loadVendorDatabase
		: async () => {
			if (typeof win.fetch !== 'function') throw new Error('fetch unavailable');
			const response = await win.fetch('/cgi-bin/miclash-device-vendors', {
				credentials: 'same-origin', cache: 'default'
			});
			if (!response?.ok) throw new Error('vendor database unavailable');
			return response.text();
		};

	function report(error, context) {
		if (destroyed) return;
		if (typeof options.onError === 'function') options.onError(error, context || {});
		else ui.addNotification(null, E('p', {}, String(error?.message || error)), 'error');
	}
	const backgroundRefresh = view_miclash_background_refresh.create(report);
	function progress(message, record) { if (typeof options.onProgress === 'function') options.onProgress(message, record || null); }
	function clearTimer() { if (timer != null) win.clearTimeout(timer); timer = null; }
	function schedule(delay) {
		clearTimer(); if (destroyed || !active || doc.hidden || !host) return;
		timer = win.setTimeout(() => { timer = null; backgroundRefresh.run(() => refresh()); }, delay || retryMs);
	}
	function wait(reply, message) {
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
				if (error) return done(reject, error); progress(message, record);
				if (record?.state === 'success') done(resolve, record);
				else if (record?.state === 'failure' || record?.state === 'interrupted') done(reject, operationError(record));
			});
			if (!finished && typeof cancel === 'function') cancels.add(cancel);
		});
	}
	async function refreshAfterMutation() {
		// The operation result is authoritative. Discovery is a separate live
		// snapshot and may transiently fail while neighbor data changes; its
		// scheduled retry must not turn a successful policy mutation into an
		// error shown to the user.
		try { await refresh(true); } catch (error) {}
	}
	const actionLabels = {
		inherit: () => _('Inherit'), direct: () => _('Direct'), block: () => _('Block')
	};
	function policyCell(row) {
		const view = policyPresentation(row.policy, row.effective);
		const children = [ E('strong', {}, (actionLabels[view.configured] || actionLabels.inherit)()) ];
		if (row.explicit && view.overridden) {
			const effective = (actionLabels[view.effective] || actionLabels.inherit)();
			const guard = /^guard_/.test(view.safety) ? ' · ' + _('Guard') : '';
			children.push(E('small', { 'class': 'sbox-device-effective' },
				_('Now: %s').format(effective) + guard));
		}
		return E('span', { 'class': 'sbox-device-policy-value' }, children);
	}
	const dayLabels = [
		() => _('Monday'), () => _('Tuesday'), () => _('Wednesday'),
		() => _('Thursday'), () => _('Friday'), () => _('Saturday'), () => _('Sunday')
	];
	function table(models) {
		const rows = models.slice(0, 512).map((row) => {
			const { device, mac, policy, explicit, online, label } = row;
			const pending = pendingMac === mac;
			const draft = policyDrafts.get(mac);
			const displayedPolicy = draft || policy;
			const edit = E('button', { 'type': 'button', 'class': 'cbi-button cbi-button-neutral',
				'data-device-mac': mac, 'disabled': pending ? 'disabled' : null,
				'aria-busy': pending ? 'true' : null }, pending
				? [ E('span', { 'class': 'sbox-spinner' }), ' ', _('Saving…') ]
				: (draft ? _('Save required') : (explicit ? _('Change policy') : _('Set policy'))));
			edit.addEventListener('click', () => openEditor(mac, device, displayedPolicy, policy));
			return E('tr', {}, [
				E('td', {}, deviceDisplayName(label, _('Unknown device'))),
				E('td', {}, E('span', { 'class': online ? 'sbox-device-online' : 'sbox-device-offline' },
					online ? _('Online') : _('Offline'))),
				E('td', {}, currentAddresses(device).join(', ') || '-'), E('td', {}, text(mac)),
				E('td', {}, policyCell({ ...row, policy: displayedPolicy })), E('td', {}, edit)
			]);
		});
		if (!rows.length) rows.push(E('tr', { 'class': 'sbox-device-empty' }, [ E('td', { 'colspan': '6', 'class': 'sbox-muted' }, _('No devices discovered.')) ]));
		return E('div', { 'class': 'sbox-management-table-wrap', 'tabindex': '0', 'role': 'region',
			'aria-label': _('Device policies') }, [ E('table', { 'class': 'table sbox-device-table' }, [
			E('thead', {}, E('tr', {}, [ _('Device'), _('State'), _('IP'), _('MAC'), _('Policy'), _('Action') ]
				.map((name) => E('th', {}, name)))), E('tbody', {}, rows)
		]) ]);
	}
	function paint() {
		if (!host || destroyed) return;
		const rows = deviceRows(devices, policies, vendorDatabase);
		const content = hydrated ? table(rows) :
			view_miclash_ui_shell.loadingBlock({ kind: 'table', lines: 6 });
		const heading = E('h4', {}, _('Device policies'));
		if (!hydrated) { host.replaceChildren(heading, content); return; }
		host.replaceChildren(
			heading,
			E('div', { 'class': 'sbox-device-scope-row' }, [
				E('div', { 'class': 'sbox-device-scope-copy' }, [
					E('p', { 'class': 'sbox-muted' }, _('Priority: Block → Direct → Inherit')),
					E('p', { 'class': 'sbox-muted' }, _('Online devices are shown only for interfaces in the current traffic scope. Saved policies remain visible while devices are offline.'))
				]),
				E('span', { 'class': 'sbox-device-count', 'aria-live': 'polite' },
					String(rows.length))
			]),
			content);
	}
	function needsVendorDatabase() {
		return devices.some((device) => !String(device?.hostname || '').trim() ||
			view_miclash_device_vendors.isGenericHostname(device?.hostname));
	}
	function ensureVendorDatabase() {
		if (destroyed || vendorLoadState !== 'idle' || !needsVendorDatabase()) return;
		vendorLoadState = 'loading';
		loadVendorDatabase(vendorLoader).then((database) => {
			if (destroyed) return;
			vendorLoadState = database == null ? 'failed' : 'ready';
			if (database != null) { vendorDatabase = database; paint(); }
		});
	}
	function optionSelect(policy) {
		return E('select', { 'id': 'sbox-device-policy-action', 'class': 'cbi-input-select' }, ACTIONS.map((name) => {
			const attrs = { 'value': name }; if ((policy?.action || 'inherit') === name) attrs.selected = 'selected';
			return E('option', attrs, actionLabels[name]());
		}));
	}
	function dayChecks(schedule) {
		const selected = Array.isArray(schedule?.days) ? schedule.days : [];
		return E('div', { 'class': 'sbox-device-days', 'aria-label': _('Schedule days') },
			[ 1, 2, 3, 4, 5, 6, 7 ].map((day) => E('label', {}, [
				E('input', { 'type': 'checkbox', 'data-day': day, 'checked': selected.includes(day) ? 'checked' : null }), dayLabels[day - 1]()
			])));
	}
	function openEditor(mac, device, policy, persistedPolicy) {
		modalGeneration++;
		const schedule = policy?.schedule || null;
		const selectedZone = timezones.includes(schedule?.timezone) ? schedule.timezone : 'UTC';
		const scheduleEnabled = E('input', { 'id': 'sbox-device-schedule-enabled', 'type': 'checkbox',
			'checked': schedule ? 'checked' : null });
		const scheduleFields = E('div', {
			'class': 'sbox-device-schedule-fields',
			'hidden': schedule ? null : 'hidden'
		}, [
			dayChecks(schedule),
			E('div', { 'class': 'sbox-management-form-grid' }, [
				E('label', {}, [ _('Start'), E('input', { 'id': 'sbox-device-start', 'type': 'time',
					'value': schedule?.start || '00:00' }) ]),
				E('label', {}, [ _('End'), E('input', { 'id': 'sbox-device-end', 'type': 'time',
					'value': schedule?.end || '23:59' }) ]),
				E('label', {}, [ _('Timezone'), E('select', { 'id': 'sbox-device-timezone',
					'class': 'cbi-input-select', 'value': selectedZone }, timezones.map((name) => E('option', {
						'value': name, 'selected': name === selectedZone ? 'selected' : null
					}, name))) ])
			])
		]);
		const label = view_miclash_device_vendors.resolveDeviceLabel(device, vendorDatabase);
		const body = E('div', { 'class': 'sbox-device-policy-editor sbox-modal-responsive' }, [
			E('p', {}, [ E('strong', {}, deviceDisplayName(label, _('Unknown device'))), ' · ', text(mac) ]),
			...(device?.identity?.persistent_policy_eligible === false
				? [ E('p', { 'class': 'sbox-device-identity-warning' },
					_('This device uses a private MAC address. The policy remains linked to this address and may stop applying if it changes.')) ]
				: []),
			E('label', { 'for': 'sbox-device-policy-action' }, _('Policy')), optionSelect(policy),
			E('label', { 'class': 'sbox-checkbox-row', 'for': 'sbox-device-schedule-enabled' }, [ scheduleEnabled, _('Use schedule') ]),
			scheduleFields,
			E('p', { 'class': 'sbox-muted' }, _('Priority: Block → Direct → Inherit')),
			E('p', { 'class': 'sbox-muted' }, _('Direct devices use the router shared DNS. If Mihomo fails unexpectedly, access by domain name may be temporarily unavailable.')),
			E('div', { 'class': 'right sbox-management-actions' }, [
				...(explicitPolicy(policy) || persistedPolicy ? [ E('button', { 'type': 'button', 'class': 'cbi-button cbi-button-negative', 'data-action': 'reset' }, _('Reset')) ] : []),
				E('button', { 'type': 'button', 'class': 'cbi-button cbi-button-apply', 'data-action': 'save' }, _('Save')),
				E('button', { 'type': 'button', 'class': 'cbi-button cbi-button-neutral', 'data-action': 'close' }, _('Close'))
			])
		]);
		const syncScheduleVisibility = () => { scheduleFields.hidden = !scheduleEnabled.checked; };
		scheduleEnabled.addEventListener('change', syncScheduleVisibility);
		syncScheduleVisibility();
		body.querySelector('[data-action="close"]').addEventListener('click', () => { modalGeneration++; ui.hideModal(); });
		body.querySelector('[data-action="save"]').addEventListener('click', () => {
			let wanted;
			try { wanted = policyFromEditor(body, mac, persistedPolicy); }
			catch (error) { report(error); return; }
			policyDrafts.stage(mac, wanted, persistedPolicy);
			modalGeneration++; ui.hideModal(); paint();
		});
		const reset = body.querySelector('[data-action="reset"]');
		if (reset) reset.addEventListener('click', () => {
			policyDrafts.stage(mac, { scope: 'device', mac, action: 'inherit', schedule: null },
				persistedPolicy);
			modalGeneration++; ui.hideModal(); paint();
		});
		ui.showModal(_('Device policy'), body);
		return body;
	}
	function policyFromEditor(body, mac, existing) {
		const action = body.querySelector('#sbox-device-policy-action')?.value;
		if (!ACTIONS.includes(action)) throw new Error(_('Invalid device policy.'));
		const policy = { id: existing?.id || null, expected_revision: existing?.revision || null,
			scope: 'device', mac: normalizedMac(mac), interface: null, action, schedule: null };
		if (body.querySelector('#sbox-device-schedule-enabled')?.checked) {
			const days = Array.from(body.querySelectorAll('[data-day]')).filter((node) => node.checked)
				.map((node) => Number(node.getAttribute('data-day')));
			const start = String(body.querySelector('#sbox-device-start')?.value || '');
			const end = String(body.querySelector('#sbox-device-end')?.value || '');
			const timezone = String(body.querySelector('#sbox-device-timezone')?.value || '').trim();
			if (!days.length || days.some((day) => !Number.isInteger(day) || day < 1 || day > 7) ||
				!/^([01][0-9]|2[0-3]):[0-5][0-9]$/.test(start) ||
				!/^([01][0-9]|2[0-3]):[0-5][0-9]$/.test(end) || start === end || !timezones.includes(timezone))
				throw new Error(_('Enter valid schedule days, times, and IANA timezone.'));
			policy.schedule = { days, start, end, timezone };
		}
		return policy;
	}
	function collectChanges() {
		return policyDrafts.list();
	}
	async function applyChanges() {
		if (busy || destroyed) throw new Error(_('Device policies are busy.'));
		const changes = policyDrafts.list();
		if (!changes.length) return false;
		busy = true;
		try {
			for (const change of changes) {
				pendingMac = change.mac; paint();
				if (change.action === 'inherit') {
					if (change.id) await wait(await api.deleteDevicePolicy(change.id,
						change.expected_revision, SOURCE), _('Resetting device policy…'));
				} else {
					await wait(await api.setDevicePolicy(change, SOURCE), _('Saving device policy…'));
				}
				policyDrafts.remove(change.mac);
			}
			await refreshAfterMutation();
			return true;
		} catch (error) {
			await refreshAfterMutation();
			throw error;
		} finally {
			busy = false; pendingMac = ''; paint();
		}
	}
	async function markSaved() {
		await refresh(true);
	}
	function refresh(force) {
		if (destroyed || !active && !force || doc.hidden && !force) return;
		if (refreshPromise) return refreshPromise;
		const token = ++generation;
		const running = (async () => {
			try {
				const repaint = () => {
					if (destroyed || token !== generation) return;
					hydrated = devicesReady && policiesReady; paint();
					if (hydrated) ensureVendorDatabase();
				};
				const replies = await Promise.allSettled([
					Promise.resolve().then(() => api.devicesList()).then((reply) => {
						if (destroyed || token !== generation) return;
						devices = Array.isArray(reply) ? reply : (Array.isArray(reply?.devices) ? reply.devices : []);
						devicesReady = true; repaint();
					}),
					Promise.resolve().then(() => api.devicePolicies()).then((reply) => {
						if (destroyed || token !== generation) return;
						policies = Array.isArray(reply) ? reply : (Array.isArray(reply?.policies) ? reply.policies : []);
						policiesReady = true; repaint();
					}),
					Promise.resolve().then(() => api.deviceTimezones()).then((reply) => {
						if (destroyed || token !== generation) return;
						const zones = Array.isArray(reply) ? reply : reply?.timezones;
						if (!Array.isArray(zones) || !zones.length || zones.length > 512 || zones[0] !== 'UTC' ||
							zones.some((name, index) => typeof name !== 'string' || name.length > 64 || zones.indexOf(name) !== index))
							throw new Error(_('Invalid timezone response.'));
						timezones = zones.slice(); timezonesReady = true; repaint();
					})
				]);
				const failed = replies.find((reply) => reply.status === 'rejected');
				if (failed) throw failed.reason;
				retryMs = POLL_MS;
			}
			catch (error) { retryMs = Math.min(MAX_POLL_MS, Math.max(POLL_MS, retryMs * 2)); throw error; }
			finally { if (!destroyed && token === generation) schedule(); }
		})();
		const tracked = running.finally(() => {
			if (refreshPromise === tracked) refreshPromise = null;
		});
		refreshPromise = tracked;
		return refreshPromise;
	}
	function visibilitychange() {
		if (doc.hidden) clearTimer();
		else if (active) backgroundRefresh.run(() => refresh());
	}
	function mount(node) {
		host = node; destroyed = false; paint();
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
		if (destroyed) return; destroyed = true; generation++; modalGeneration++; clearTimer();
		doc.removeEventListener('visibilitychange', visibilitychange);
		for (const cancel of cancels) cancel(); cancels.clear();
		if (typeof api.destroy === 'function') api.destroy(); host = null;
	}
	doc.addEventListener('visibilitychange', visibilitychange);
	return { mount, refresh, setActive, destroy, openEditor, policyFromEditor,
		collectChanges, applyChanges, markSaved, ready: () => hydrated };
}

return baseclass.extend({
	create, normalizedMac, currentAddresses, deviceRows, deviceDisplayName, loadVendorDatabase,
	policyPresentation, createPolicyDrafts
});
