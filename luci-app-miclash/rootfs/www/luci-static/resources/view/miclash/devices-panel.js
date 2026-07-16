'use strict';
'require ui';

const SOURCE = 'luci';
const POLL_MS = 30000;
const MAX_POLL_MS = 300000;
const MAC = /^[0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){5}$/;
const ACTIONS = [ 'inherit', 'proxy', 'direct', 'block' ];

function text(value, fallback) { return String(value == null || value === '' ? (fallback || '-') : value); }
function normalizedMac(value) {
	const mac = String(value || '').trim().toUpperCase();
	const first = MAC.test(mac) ? Number.parseInt(mac.slice(0, 2), 16) : -1;
	if (!MAC.test(mac) || (first & 1) !== 0 || mac === '00:00:00:00:00:00' || mac === 'FF:FF:FF:FF:FF:FF')
		throw new Error(_('Enter a valid MAC address such as AA:BB:CC:DD:EE:FF.'));
	return mac;
}
function currentAddresses(device) {
	return (Array.isArray(device?.addresses) ? device.addresses : []).filter((item) => item?.current === true)
		.map((item) => text(item.address)).slice(0, 8);
}
function when(value) {
	const n = Number(value);
	if (!Number.isFinite(n) || n <= 0) return '-';
	try { return new Date(n < 100000000000 ? n * 1000 : n).toLocaleString(); }
	catch (error) { return '-'; }
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
	let devices = [], policies = [], timezones = [ 'UTC' ], busy = false, retryMs = POLL_MS;
	const cancels = new Set();

	function report(error) {
		if (destroyed) return;
		if (typeof options.onError === 'function') options.onError(error);
		else ui.addNotification(null, E('p', {}, String(error?.message || error)), 'error');
	}
	function progress(message, record) { if (typeof options.onProgress === 'function') options.onProgress(message, record || null); }
	function clearTimer() { if (timer != null) win.clearTimeout(timer); timer = null; }
	function schedule(delay) {
		clearTimer(); if (destroyed || doc.hidden || !host) return;
		timer = win.setTimeout(() => { timer = null; refresh().catch(report); }, delay || retryMs);
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
	function policyFor(mac) {
		const key = String(mac || '').toLowerCase();
		return policies.find((item) => item?.scope === 'device' && String(item.mac || '').toLowerCase() === key) || null;
	}
	function table() {
		const rows = devices.slice(0, 512).map((device) => {
			const mac = device.mac && MAC.test(device.mac) ? device.mac.toUpperCase() : '';
			const policy = mac ? policyFor(mac) : null;
			const edit = E('button', { 'type': 'button', 'class': 'cbi-button cbi-button-neutral',
				'data-device-mac': mac, 'disabled': mac ? null : 'disabled' }, policy ? _('Edit') : _('Set policy'));
			edit.addEventListener('click', () => openEditor(mac, device, policy));
			return E('tr', {}, [
				E('td', {}, text(device.hostname, _('Unknown device'))), E('td', {}, text(mac)),
				E('td', {}, currentAddresses(device).join(', ') || '-'), E('td', {}, when(device.last_seen)),
				E('td', {}, text(policy?.action, 'inherit')), E('td', {}, edit)
			]);
		});
		if (!rows.length) rows.push(E('tr', {}, [ E('td', { 'colspan': '6', 'class': 'sbox-muted' }, _('No devices discovered.')) ]));
		return E('div', { 'class': 'sbox-management-table-wrap' }, [ E('table', { 'class': 'table sbox-device-table' }, [
			E('thead', {}, E('tr', {}, [ _('Hostname'), _('MAC'), _('Current IP'), _('Last seen'), _('Policy'), _('Actions') ]
				.map((name) => E('th', {}, name)))), E('tbody', {}, rows)
		]) ]);
	}
	function paint() {
		if (!host || destroyed) return;
		host.replaceChildren(
			E('h4', {}, _('Device policies')),
			E('p', { 'class': 'sbox-muted' }, _('Guard has highest precedence. A direct policy never disables or bypasses Guard protection.')),
			table());
	}
	function optionSelect(policy) {
		return E('select', { 'id': 'sbox-device-policy-action', 'class': 'cbi-input-select' }, ACTIONS.map((name) => {
			const attrs = { 'value': name }; if ((policy?.action || 'inherit') === name) attrs.selected = 'selected';
			return E('option', attrs, name);
		}));
	}
	function dayChecks(schedule) {
		const selected = Array.isArray(schedule?.days) ? schedule.days : [];
		return E('div', { 'class': 'sbox-device-days', 'aria-label': _('Schedule days') },
			[ 1, 2, 3, 4, 5, 6, 7 ].map((day) => E('label', {}, [
				E('input', { 'type': 'checkbox', 'data-day': day, 'checked': selected.includes(day) ? 'checked' : null }), String(day)
			])));
	}
	function openEditor(mac, device, policy) {
		const token = ++modalGeneration, schedule = policy?.schedule || null;
		const selectedZone = timezones.includes(schedule?.timezone) ? schedule.timezone : 'UTC';
		const scheduleEnabled = E('input', { 'id': 'sbox-device-schedule-enabled', 'type': 'checkbox',
			'checked': schedule ? 'checked' : null });
		const body = E('div', { 'class': 'sbox-device-policy-editor' }, [
			E('p', {}, [ E('strong', {}, text(device?.hostname, _('Unknown device'))), ' · ', text(mac) ]),
			E('label', { 'for': 'sbox-device-policy-action' }, _('Policy')), optionSelect(policy),
			E('label', { 'class': 'sbox-checkbox-row', 'for': 'sbox-device-schedule-enabled' }, [ scheduleEnabled, _('Use schedule') ]),
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
			]),
			E('p', { 'class': 'sbox-muted' }, _('Guard precedence: fail-closed protection is evaluated before device direct/proxy policy.')),
			E('div', { 'class': 'right sbox-management-actions' }, [
				policy ? E('button', { 'type': 'button', 'class': 'cbi-button cbi-button-negative', 'data-action': 'delete' }, _('Delete')) : null,
				E('button', { 'type': 'button', 'class': 'cbi-button cbi-button-apply', 'data-action': 'save' }, _('Save')),
				E('button', { 'type': 'button', 'class': 'cbi-button cbi-button-neutral', 'data-action': 'close' }, _('Close'))
			])
		]);
		body.querySelector('[data-action="close"]').addEventListener('click', () => { modalGeneration++; ui.hideModal(); });
		body.querySelector('[data-action="save"]').addEventListener('click', () => mutate(async () => {
			const wanted = policyFromEditor(body, mac, policy);
			await wait(await api.setDevicePolicy(wanted, SOURCE), _('Saving device policy…'));
			if (!destroyed && token === modalGeneration) ui.hideModal();
			await refresh(true);
		}));
		const remove = body.querySelector('[data-action="delete"]');
		if (remove) remove.addEventListener('click', () => mutate(async () => {
			await wait(await api.deleteDevicePolicy(policy.id, policy.revision, SOURCE), _('Deleting device policy…'));
			if (!destroyed && token === modalGeneration) ui.hideModal();
			await refresh(true);
		}));
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
	async function mutate(callback) {
		if (busy || destroyed) return; busy = true;
		try { await callback(); } catch (error) { report(error); } finally { busy = false; }
	}
	async function refresh(force) {
		if (destroyed || doc.hidden && !force) return;
		const token = ++generation;
		try {
			const replies = await Promise.all([ api.devicesList(), api.devicePolicies(), api.deviceTimezones() ]);
			if (destroyed || token !== generation) return;
			const zones = Array.isArray(replies[2]) ? replies[2] : replies[2]?.timezones;
			if (!Array.isArray(zones) || !zones.length || zones.length > 512 || zones[0] !== 'UTC' ||
				zones.some((name, index) => typeof name !== 'string' || name.length > 64 || zones.indexOf(name) !== index))
				throw new Error(_('Invalid timezone response.'));
			devices = Array.isArray(replies[0]) ? replies[0] : (Array.isArray(replies[0]?.devices) ? replies[0].devices : []);
			policies = Array.isArray(replies[1]) ? replies[1] : (Array.isArray(replies[1]?.policies) ? replies[1].policies : []);
			timezones = zones.slice(); retryMs = POLL_MS; paint();
		}
		catch (error) { retryMs = Math.min(MAX_POLL_MS, Math.max(POLL_MS, retryMs * 2)); throw error; }
		finally { if (!destroyed && token === generation) schedule(); }
	}
	function visibilitychange() { if (doc.hidden) clearTimer(); else refresh().catch(report); }
	function mount(node) { host = node; destroyed = false; paint(); refresh().catch(report); return host; }
	function destroy() {
		if (destroyed) return; destroyed = true; generation++; modalGeneration++; clearTimer();
		doc.removeEventListener('visibilitychange', visibilitychange);
		for (const cancel of cancels) cancel(); cancels.clear();
		if (typeof api.destroy === 'function') api.destroy(); host = null;
	}
	doc.addEventListener('visibilitychange', visibilitychange);
	return { mount, refresh, destroy, openEditor, policyFromEditor };
}

return { create, normalizedMac, currentAddresses };
