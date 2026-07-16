'use strict';
'require ui';

function operationWatch(api, operationId, onProgress) {
	let rawCancel = null, rejectPromise = null, settled = false, cancelPending = false;
	const promise = new Promise((resolve, reject) => {
		rejectPromise = reject;
		const finishCancel = () => { if (rawCancel) rawCancel(); else cancelPending = true; };
		rawCancel = api.watchOperation(operationId, (operation, error) => {
			if (settled) return;
			if (error) { settled = true; finishCancel(); reject(error); return; }
			if (operation && typeof onProgress === 'function') onProgress(operation);
			if (!operation || !/^(success|failure|interrupted)$/.test(operation.state || '')) return;
			settled = true; finishCancel();
			if (operation.state === 'success') resolve(operation);
			else {
				const failure = new Error(operation.error?.message || _('Operation failed'));
				failure.code = operation.error?.code || 'OPERATION_FAILED'; reject(failure);
			}
		});
		if (cancelPending && rawCancel) rawCancel();
	});
	return { promise, cancel() {
		if (settled) return;
		settled = true;
		if (rawCancel) rawCancel(); else cancelPending = true;
		const failure = new Error(_('Operation cancelled')); failure.code = 'CANCELLED';
		rejectPromise(failure);
	} };
}

function normalizeRecords(reply) {
	const values = Array.isArray(reply) ? reply : (reply?.revisions || reply?.records || []);
	return values.filter((record) => record && typeof record.revision === 'string')
		.sort((left, right) => {
			if (!!left.corrupt !== !!right.corrupt) return left.corrupt ? 1 : -1;
			const byTime = Number(right.timestamp || 0) - Number(left.timestamp || 0);
			return byTime || String(right.revision).localeCompare(String(left.revision));
		}).slice(0, 100);
}

function labelSource(source, corrupt) {
	if (corrupt) return _('Corrupt revision');
	const labels = {
		manual: _('Manual'), luci: _('LuCI'), subscription: _('Subscription'), auto: _('Automatic'),
		telegram: _('Telegram'), system: _('System'), 'restore-before': _('Before restore'),
		restore: _('Restore'), external: _('External change')
	};
	return labels[source] || _('Unknown source');
}

function create(options) {
	const opts = options || {}, api = opts.api;
	let destroyed = false, generation = 0, busy = false;
	let profile = String(opts.profile || 'config.yaml'), records = [], selected = null;
	let body = null, detail = null;
	const watches = new Set();
	const current = (token, ownedProfile) => !destroyed && token === generation && profile === ownedProfile;
	function cancelWatches() { for (const watch of watches) watch.cancel(); watches.clear(); }
	function invalidate(nextProfile) {
		generation++; cancelWatches(); busy = false; selected = null;
		if (nextProfile != null) profile = String(nextProfile);
	}
	function status(text, error) {
		if (!detail || destroyed) return;
		detail.replaceChildren(E('p', { 'class': error ? 'sbox-history-error' : 'sbox-history-status',
			'role': error ? 'alert' : 'status' }, [ String(text || '') ]));
	}
	function metadata(record) {
		return E('dl', { 'class': 'sbox-history-metadata' }, [
			E('dt', {}, [ _('Revision') ]), E('dd', {}, [ record.revision ]),
			E('dt', {}, [ _('Source') ]), E('dd', {}, [ labelSource(record.source, record.corrupt) ]),
			E('dt', {}, [ _('Created') ]), E('dd', {}, [
				Number.isFinite(Number(record.timestamp)) ? new Date(Number(record.timestamp)).toLocaleString() : '—' ]),
			E('dt', {}, [ _('Validation') ]), E('dd', {}, [ String(record.validation_result || '—') ]),
			E('dt', {}, [ _('Activation') ]), E('dd', {}, [ String(record.activation_result || '—') ])
		]);
	}
	function disableActions(value) {
		for (const node of body?.querySelectorAll('[data-history-action]') || []) node.disabled = value;
	}
	async function ownedOperation(operationId, token, ownedProfile) {
		if (!current(token, ownedProfile)) return false;
		const watch = operationWatch(api, operationId, (operation) => {
			if (current(token, ownedProfile) && typeof opts.onProgress === 'function') opts.onProgress(operation);
		});
		watches.add(watch);
		try { await watch.promise; return current(token, ownedProfile); }
		finally { watches.delete(watch); }
	}
	async function mutation(callback) {
		if (busy || destroyed) return false;
		busy = true; disableActions(true);
		try { await callback(); return true; }
		catch (error) { if (error?.code !== 'CANCELLED') status((error.code ? error.code + ': ' : '') + error.message, true); return false; }
		finally { busy = false; disableActions(false); }
	}
	async function selectRevision(record, token = generation) {
		const ownedProfile = profile;
		if (!current(token, ownedProfile)) return;
		selected = record;
		if (record.corrupt) { detail.replaceChildren(metadata(record),
			E('p', { 'class': 'sbox-history-error', 'role': 'alert' }, [ _('This revision is corrupt and cannot be opened or restored.') ])); return; }
		detail.replaceChildren(metadata(record), E('p', { 'role': 'status' }, [ _('Loading diff…') ]));
		try {
			const newest = records.find((entry) => !entry.corrupt) || record;
			const reply = record.revision === newest.revision ? { changed: false, text: '' } :
				await api.historyDiff(ownedProfile, record.revision, newest.revision);
			if (!current(token, ownedProfile) || selected !== record) return;
			const comparison = E('p', { 'class': 'sbox-history-comparison' }, [
				record.revision === newest.revision ? _('Selected revision is the newest retained revision.') :
					_('Compared with newest retained revision:') + ' ' + newest.revision
			]);
			const diff = E('pre', { 'class': 'sbox-history-diff', 'tabindex': '0' }, [
				String(reply?.text || _('No differences between the selected retained revisions.')) ]);
			const open = E('button', { 'type': 'button', 'class': 'cbi-button cbi-button-apply',
				'data-action': 'open-draft', 'data-history-action': '1' }, [ _('Open in editor') ]);
			const restore = E('button', { 'type': 'button', 'class': 'cbi-button cbi-button-negative',
				'data-action': 'restore', 'data-history-action': '1' }, [ _('Restore') ]);
			open.addEventListener('click', () => mutation(async () => {
				const actionToken = token, actionProfile = ownedProfile, revision = record.revision;
				const accepted = await api.historyOpenDraft(actionProfile, revision, 'luci');
				if (!current(actionToken, actionProfile) || !(await ownedOperation(accepted.operation_id, actionToken, actionProfile))) return;
				const draft = await api.configReadDraft(actionProfile);
				if (!current(actionToken, actionProfile)) return;
				if (typeof opts.onDraft === 'function')
					await opts.onDraft(String(draft?.content || ''), record,
						{ profile: actionProfile, generation: actionToken, revision });
				if (current(actionToken, actionProfile)) ui.hideModal();
			}));
			restore.addEventListener('click', () => mutation(async () => {
				const actionToken = token, actionProfile = ownedProfile, revision = record.revision;
				const accepted = await api.historyRestore(actionProfile, revision, 'luci');
				if (!current(actionToken, actionProfile) || !(await ownedOperation(accepted.operation_id, actionToken, actionProfile))) return;
				if (typeof opts.onRestored === 'function') await opts.onRestored(record,
					{ profile: actionProfile, generation: actionToken, revision });
				if (current(actionToken, actionProfile)) await refresh(actionToken, actionProfile);
			}));
			detail.replaceChildren(metadata(record), comparison, diff,
				E('div', { 'class': 'sbox-history-actions' }, [ open, restore ]));
		} catch (error) { if (current(token, ownedProfile)) status((error.code ? error.code + ': ' : '') + error.message, true); }
	}
	function renderList(token, ownedProfile) {
		const list = E('div', { 'class': 'sbox-history-list', 'role': 'list', 'aria-label': _('Configuration revisions') });
		for (const record of records) {
			const button = E('button', { 'type': 'button', 'class': 'sbox-history-item', 'role': 'listitem',
				'data-revision': record.revision }, [
				E('strong', {}, [ Number.isFinite(Number(record.timestamp)) ? new Date(Number(record.timestamp)).toLocaleString() : '—' ]),
				E('span', { 'class': 'sbox-history-source', 'data-source': String(record.source || '') },
					[ labelSource(record.source, record.corrupt) ]), E('small', {}, [ record.revision ]) ]);
			button.addEventListener('click', () => { if (!busy && current(token, ownedProfile)) selectRevision(record, token); });
			list.appendChild(button);
		}
		return list;
	}
	async function refresh(token = generation, ownedProfile = profile) {
		const reply = await api.historyList(ownedProfile, 50);
		if (!current(token, ownedProfile)) return;
		records = normalizeRecords(reply);
		const listHost = body?.querySelector('[data-history-list]');
		if (listHost) listHost.replaceChildren(renderList(token, ownedProfile));
		const newest = records.find((record) => !record.corrupt);
		if (newest) await selectRevision(newest, token);
		else if (records.length) await selectRevision(records[0], token);
		else status(_('No configuration revisions yet.'), false);
	}
	async function open(nextProfile) {
		invalidate(nextProfile || profile); destroyed = false;
		const token = generation, ownedProfile = profile;
		body = E('div', { 'class': 'sbox-history-layout' }, [
			E('section', { 'class': 'sbox-history-sidebar', 'data-history-list': '1',
				'aria-label': _('Configuration revisions') }, [ E('p', {}, [ _('Loading history…') ]) ]),
			E('section', { 'class': 'sbox-history-detail', 'aria-live': 'polite' }) ]);
		detail = body.querySelector('.sbox-history-detail'); ui.showModal(_('Configuration history'), body);
		try { await refresh(token, ownedProfile); }
		catch (error) { if (current(token, ownedProfile)) status((error.code ? error.code + ': ' : '') + error.message, true); }
		return body;
	}
	function destroy() { invalidate(); destroyed = true; body = null; detail = null; records = []; }
	return { open, refresh, destroy, invalidate, selectRevision };
}

return { create: create, operationWatch: operationWatch, normalizeRecords: normalizeRecords };
