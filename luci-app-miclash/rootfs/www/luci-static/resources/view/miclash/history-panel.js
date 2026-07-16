'use strict';
'require ui';

function operationPromise(api, operationId) {
	return new Promise((resolve, reject) => {
		let cancel = null;
		cancel = api.watchOperation(operationId, (operation, error) => {
			if (error) { if (cancel) cancel(); reject(error); return; }
			if (!operation || !/^(success|failure|interrupted)$/.test(operation.state || '')) return;
			if (cancel) cancel();
			if (operation.state === 'success') resolve(operation);
			else {
				const failure = new Error(operation.error?.message || _('Operation failed'));
				failure.code = operation.error?.code || 'OPERATION_FAILED';
				reject(failure);
			}
		});
	});
}

function normalizeRecords(reply) {
	const values = Array.isArray(reply) ? reply : (reply?.revisions || reply?.records || []);
	return values.filter((record) => record && typeof record.revision === 'string')
		.slice(0, 100);
}

function labelSource(source) {
	const labels = {
		manual: _('Manual'), subscription: _('Subscription'),
		'restore-before': _('Before restore'), restore: _('Restore'),
		external: _('External change')
	};
	return labels[source] || String(source || _('Unknown'));
}

function create(options) {
	const opts = options || {};
	const api = opts.api;
	let destroyed = false;
	let profile = String(opts.profile || 'config.yaml');
	let records = [];
	let selected = null;
	let body = null;
	let detail = null;

	function status(text, error) {
		if (!detail || destroyed) return;
		const node = E('p', { 'class': error ? 'sbox-history-error' : 'sbox-history-status',
			'role': error ? 'alert' : 'status' }, [ String(text || '') ]);
		detail.replaceChildren(node);
	}
	function metadata(record) {
		return E('dl', { 'class': 'sbox-history-metadata' }, [
			E('dt', {}, [ _('Revision') ]), E('dd', {}, [ record.revision ]),
			E('dt', {}, [ _('Source') ]), E('dd', {}, [ labelSource(record.source) ]),
			E('dt', {}, [ _('Created') ]), E('dd', {}, [
				new Date(Number(record.timestamp || 0)).toLocaleString() ]),
			E('dt', {}, [ _('Validation') ]), E('dd', {}, [ String(record.validation_result || '—') ]),
			E('dt', {}, [ _('Activation') ]), E('dd', {}, [ String(record.activation_result || '—') ])
		]);
	}
	async function selectRevision(record) {
		if (destroyed) return;
		selected = record;
		detail.replaceChildren(metadata(record), E('p', { 'role': 'status' }, [ _('Loading diff…') ]));
		try {
			const newest = records[0] || record;
			const reply = record.revision === newest.revision
				? { changed: false, text: '' }
				: await api.historyDiff(profile, record.revision, newest.revision);
			if (destroyed || selected !== record) return;
			const diff = E('pre', { 'class': 'sbox-history-diff', 'tabindex': '0' }, [
				String(reply?.text || _('No differences from the newest revision.'))
			]);
			const open = E('button', { 'type': 'button', 'class': 'cbi-button cbi-button-apply',
				'data-action': 'open-draft' }, [ _('Open in editor') ]);
			const restore = E('button', { 'type': 'button', 'class': 'cbi-button cbi-button-negative',
				'data-action': 'restore' }, [ _('Restore') ]);
			open.addEventListener('click', async () => {
				open.disabled = true;
				try {
					const accepted = await api.historyOpenDraft(profile, record.revision, 'luci');
					await operationPromise(api, accepted.operation_id);
					const draft = await api.configReadDraft(profile);
					if (!destroyed && typeof opts.onDraft === 'function')
						await opts.onDraft(String(draft?.content || ''), record);
					if (!destroyed) ui.hideModal();
				} catch (error) { status((error.code ? error.code + ': ' : '') + error.message, true); }
				finally { open.disabled = false; }
			});
			restore.addEventListener('click', async () => {
				restore.disabled = true;
				try {
					const accepted = await api.historyRestore(profile, record.revision, 'luci');
					await operationPromise(api, accepted.operation_id);
					if (!destroyed && typeof opts.onRestored === 'function') await opts.onRestored(record);
					if (!destroyed) await refresh();
				} catch (error) { status((error.code ? error.code + ': ' : '') + error.message, true); }
				finally { restore.disabled = false; }
			});
			detail.replaceChildren(metadata(record), diff,
				E('div', { 'class': 'sbox-history-actions' }, [ open, restore ]));
		} catch (error) {
			status((error.code ? error.code + ': ' : '') + error.message, true);
		}
	}
	function renderList() {
		const list = E('div', { 'class': 'sbox-history-list', 'role': 'list',
			'aria-label': _('Configuration revisions') });
		for (const record of records) {
			const button = E('button', { 'type': 'button', 'class': 'sbox-history-item',
				'role': 'listitem', 'data-revision': record.revision }, [
				E('strong', {}, [ new Date(Number(record.timestamp || 0)).toLocaleString() ]),
				E('span', { 'class': 'sbox-history-source', 'data-source': String(record.source || '') },
					[ labelSource(record.source) ]),
				E('small', {}, [ record.revision ])
			]);
			button.addEventListener('click', () => selectRevision(record));
			list.appendChild(button);
		}
		return list;
	}
	async function refresh() {
		const reply = await api.historyList(profile, 50);
		if (destroyed) return;
		records = normalizeRecords(reply);
		const listHost = body?.querySelector('[data-history-list]');
		if (listHost) listHost.replaceChildren(renderList());
		if (records.length) await selectRevision(records[0]);
		else status(_('No configuration revisions yet.'), false);
	}
	async function open(nextProfile) {
		profile = String(nextProfile || profile);
		body = E('div', { 'class': 'sbox-history-layout' }, [
			E('section', { 'class': 'sbox-history-sidebar', 'data-history-list': '1',
				'aria-label': _('Configuration revisions') }, [ E('p', {}, [ _('Loading history…') ]) ]),
			E('section', { 'class': 'sbox-history-detail', 'aria-live': 'polite' })
		]);
		detail = body.querySelector('.sbox-history-detail');
		ui.showModal(_('Configuration history'), body);
		try { await refresh(); }
		catch (error) { status((error.code ? error.code + ': ' : '') + error.message, true); }
		return body;
	}
	function destroy() { destroyed = true; body = null; detail = null; records = []; }
	return { open, refresh, destroy, selectRevision };
}

return { create: create, operationPromise: operationPromise };
