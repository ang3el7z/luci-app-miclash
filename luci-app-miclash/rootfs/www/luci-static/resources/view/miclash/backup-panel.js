'use strict';
'require ui';

const SOURCE = 'luci';
const MAX_ARCHIVE = 16777216;
const BACKUP_ID = /^b-[0-9]{13}-[0-9a-f]{32}$/;
const IMPORT_ID = /^i-[0-9]{13}-[0-9a-f]{32}$/;
const INSPECTION_ID = /^x-[0-9]{13}-[0-9a-f]{32}$/;

function text(value, fallback) { return String(value == null || value === '' ? (fallback || '-') : value); }
function boundedText(value, maximum, fallback) {
	const result = text(value, fallback);
	return result.length <= maximum ? result : result.slice(0, maximum) + '…';
}
function bytes(value) {
	const n = Number(value); if (!Number.isFinite(n) || n < 0) return '-';
	if (n < 1024) return Math.round(n) + ' B';
	if (n < 1048576) return (n / 1024).toFixed(1) + ' KiB';
	return (n / 1048576).toFixed(1) + ' MiB';
}
function when(value) {
	const n = Number(value); if (!Number.isFinite(n) || n <= 0) return '-';
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
	if (!api || typeof api.backupList !== 'function' || typeof api.backupCreate !== 'function' ||
		typeof api.backupInspect !== 'function' || typeof api.backupRestore !== 'function' ||
		typeof api.downloadChunks !== 'function' || typeof api.uploadChunks !== 'function' ||
		typeof api.settings_get !== 'function' || typeof api.settings_set !== 'function' ||
		typeof api.watchOperation !== 'function') throw new Error('Typed backup API is required');
	let host = null, destroyed = false, generation = 0, modalGeneration = 0, busy = false;
	let backups = [], backupSettings = { enabled: false, retention: 5, include_secrets: false,
		interval_hours: 24, schedule_time: '03:00' };
	const cancels = new Set(), objectUrls = new Set();

	function report(error) {
		if (destroyed) return;
		if (typeof options.onError === 'function') options.onError(error);
		else ui.addNotification(null, E('p', {}, String(error?.message || error)), 'error');
	}
	function progress(message, record) { if (typeof options.onProgress === 'function') options.onProgress(message, record || null); }
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
	function action(label, name, positive) {
		return E('button', { 'type': 'button', 'class': 'cbi-button ' + (positive ? 'cbi-button-apply' : 'cbi-button-neutral'),
			'data-action': name }, label);
	}
	function backupRows() {
		const rows = backups.slice(0, 100).map((record) => {
			const id = BACKUP_ID.test(record?.id || '') ? record.id : '';
			const download = action(_('Download'), 'download'); download.setAttribute('data-backup-id', id);
			const inspect = action(_('Inspect'), 'inspect'); inspect.setAttribute('data-backup-id', id);
			if (!id) { download.disabled = true; inspect.disabled = true; }
			return E('tr', {}, [ E('td', {}, when(record.created_at)), E('td', {}, text(record.app_version)),
				E('td', {}, bytes(record.size)), E('td', {}, (record.includes || []).map(text).join(', ') || '-'),
				E('td', {}, [ download, ' ', inspect ]) ]);
		});
		if (!rows.length) rows.push(E('tr', {}, [ E('td', { 'colspan': '5', 'class': 'sbox-muted' }, _('No backups yet.')) ]));
		return rows;
	}
	function paint() {
		if (!host || destroyed) return;
		const enabled = E('input', { 'id': 'sbox-backup-enabled', 'type': 'checkbox',
			'checked': backupSettings.enabled === true ? 'checked' : null });
		const include = E('input', { 'id': 'sbox-backup-include-secrets', 'type': 'checkbox',
			'checked': backupSettings.include_secrets === true ? 'checked' : null });
		const retention = E('input', { 'id': 'sbox-backup-retention', 'type': 'number', 'min': '1', 'max': '100',
			'step': '1', 'value': backupSettings.retention || 5, 'class': 'cbi-input-text' });
		const interval = E('input', { 'id': 'sbox-backup-interval', 'type': 'number', 'min': '1', 'max': '168',
			'step': '1', 'value': backupSettings.interval_hours || 24, 'class': 'cbi-input-text' });
		const scheduleTime = E('input', { 'id': 'sbox-backup-time', 'type': 'time',
			'value': backupSettings.schedule_time || '03:00', 'class': 'cbi-input-text' });
		const file = E('input', { 'id': 'sbox-backup-import', 'type': 'file', 'accept': '.tar,application/x-tar,application/octet-stream' });
		host.replaceChildren(
			E('h4', {}, _('Backup and restore')),
			E('p', { 'class': 'sbox-muted' }, _('Backups are validated and previewed before restore.')),
			E('label', { 'class': 'sbox-checkbox-row', 'for': 'sbox-backup-enabled' }, [ enabled, _('Enable scheduled backups') ]),
			E('label', { 'for': 'sbox-backup-interval' }, [ _('Backup interval (hours)'), ' ', interval ]),
			E('label', { 'for': 'sbox-backup-time' }, [ _('Schedule anchor (UTC)'), ' ', scheduleTime ]),
			E('label', { 'for': 'sbox-backup-retention' }, [ _('Retention'), ' ', retention ]),
			E('label', { 'class': 'sbox-checkbox-row', 'for': 'sbox-backup-include-secrets' }, [ include, _('Include secrets') ]),
			E('p', { 'class': 'sbox-management-warning', 'role': 'alert' },
				_('Warning: a backup with secrets contains subscription credentials and private configuration. Store it safely.')),
			E('div', { 'class': 'sbox-management-actions' }, [ action(_('Save backup settings'), 'save-settings'),
				action(_('Create and download'), 'create', true), file, action(_('Inspect import'), 'import') ]),
			E('div', { 'class': 'sbox-management-table-wrap' }, E('table', { 'class': 'table' }, [
				E('thead', {}, E('tr', {}, [ _('Created'), _('Version'), _('Size'), _('Contents'), _('Actions') ]
					.map((name) => E('th', {}, name)))), E('tbody', {}, backupRows())
			]))
		);
		for (const button of host.querySelectorAll('[data-action]')) button.addEventListener('click', () => mutate(async () => {
			const name = button.getAttribute('data-action'), id = button.getAttribute('data-backup-id');
			if (name === 'create') await createAndDownload(!!include.checked);
			else if (name === 'save-settings') await saveSettings(enabled, retention, include, interval, scheduleTime);
			else if (name === 'download') await download(id);
			else if (name === 'inspect') await inspect(id);
			else if (name === 'import') await importArchive(file.files?.[0]);
		}));
	}
	async function saveSettings(enabled, retention, include, interval, scheduleTime) {
		const raw = String(retention.value || '').trim(), amount = /^[0-9]+$/.test(raw) ? Number(raw) : 0;
		if (!Number.isInteger(amount) || amount < 1 || amount > 100)
			throw new Error(_('Retention must be between 1 and 100.'));
		const intervalRaw = String(interval.value || '').trim();
		const intervalHours = /^[0-9]+$/.test(intervalRaw) ? Number(intervalRaw) : 0;
		if (!Number.isInteger(intervalHours) || intervalHours < 1 || intervalHours > 168)
			throw new Error(_('Backup interval must be between 1 and 168 hours.'));
		const time = String(scheduleTime.value || '').trim();
		if (!/^([01][0-9]|2[0-3]):[0-5][0-9]$/.test(time))
			throw new Error(_('Choose a valid UTC schedule time.'));
		const patch = { backup: { enabled: !!enabled.checked, retention: amount,
			include_secrets: !!include.checked, interval_hours: intervalHours,
			schedule_time: time } };
		await wait(await api.settings_set(patch, SOURCE), _('Saving backup settings…'));
		await refresh();
	}
	async function mutate(callback) {
		if (busy || destroyed) return; busy = true;
		try { await callback(); } catch (error) { report(error); } finally { busy = false; }
	}
	function operationBackupId(record) {
		for (const candidate of [ record?.result?.backup_id, record?.result?.id, record?.backup_id ])
			if (BACKUP_ID.test(candidate || '')) return candidate;
		return null;
	}
	async function createAndDownload(includeSecrets) {
		const before = new Set(backups.map((item) => item.id));
		const terminal = await wait(await api.backupCreate({ include_secrets: includeSecrets }, SOURCE), _('Creating backup…'));
		let id = operationBackupId(terminal);
		if (!id) {
			await refresh();
			const created = backups.filter((item) => !before.has(item.id));
			if (created.length === 1) id = created[0].id;
		}
		if (!BACKUP_ID.test(id || '')) throw new Error(_('Backup completed but returned no safe backup ID.'));
		await download(id);
	}
	async function download(id) {
		if (!BACKUP_ID.test(id || '')) throw new Error(_('Invalid backup ID.'));
		const data = await api.downloadChunks('backup', id, {});
		if (destroyed) return;
		if (!(data instanceof Uint8Array) || data.byteLength > MAX_ARCHIVE) throw new Error(_('Invalid backup payload.'));
		const url = win.URL.createObjectURL(new Blob([ data ], { type: 'application/x-tar' })); objectUrls.add(url);
		try {
			const anchor = doc.createElement('a'); anchor.href = url; anchor.download = 'miclash-backup.tar';
			anchor.setAttribute('aria-hidden', 'true'); anchor.click(); anchor.remove();
		} finally { win.URL.revokeObjectURL(url); objectUrls.delete(url); }
	}
	async function importArchive(file) {
		if (!file || typeof file.arrayBuffer !== 'function') throw new Error(_('Choose a backup archive first.'));
		if (!Number.isInteger(file.size) || file.size < 1 || file.size > MAX_ARCHIVE)
			throw new Error(_('Backup archive size is outside the safe limit.'));
		const bytesValue = new Uint8Array(await file.arrayBuffer());
		if (destroyed || bytesValue.byteLength !== file.size) throw new Error(_('Backup archive changed while reading.'));
		const staged = await api.uploadChunks('backup', { purpose: 'inspect' }, bytesValue);
		if (!staged || staged.completed !== true || Object.keys(staged).length !== 2 ||
			!staged.result || typeof staged.result !== 'object' || Array.isArray(staged.result) ||
			Object.keys(staged.result).length !== 1 || !IMPORT_ID.test(staged.result.import_id || ''))
			throw new Error(_('Invalid backup import response.'));
		await inspect(staged.result.import_id);
	}
	async function inspect(id) {
		if (!BACKUP_ID.test(id || '') && !IMPORT_ID.test(id || '')) throw new Error(_('Invalid backup/import ID.'));
		const token = ++modalGeneration, plan = await api.backupInspect(id, {});
		if (destroyed || token !== modalGeneration || !INSPECTION_ID.test(plan?.id || ''))
			throw new Error(_('Invalid backup inspection response.'));
		showPlan(plan, token);
	}
	function showPlan(plan, token) {
		const inspection_id = plan.id;
		const files = Array.isArray(plan.files) ? plan.files.slice(0, 1024) : [];
		const groups = Array.isArray(plan.includes) ? plan.includes.slice(0, 32) : [];
		const manifest = E('ul', { 'class': 'sbox-backup-manifest', 'aria-label': _('Backup manifest') }, files.map((file) => E('li', {}, [
			boundedText(file.path, 512), ' · ', bytes(file.size), ' · ',
			/^[0-9a-f]{64}$/.test(file.sha256 || '') ? file.sha256 : '-', ' · ',
			file.secret === true ? _('secret') : _('public')
		])));
		const restore = action(_('Restore inspected backup'), 'restore', true), close = action(_('Close'), 'close');
		const body = E('div', { 'class': 'sbox-backup-plan' }, [
			E('p', {}, [ E('strong', {}, _('Restore plan')), ' · ', boundedText(plan.app_version, 64),
				' · ', when(plan.created_at) ]),
			E('p', { 'class': 'sbox-muted' }, [ _('Inspection ID'), ': ', inspection_id,
				' · ', _('Source ID'), ': ', boundedText(plan.source_id, 64) ]),
			E('p', { 'class': 'sbox-muted' }, [ _('Created'), ': ', when(plan.created_at),
				' · ', _('Inspected'), ': ', when(plan.inspected_at),
				' · ', _('Expires'), ': ', when(plan.expires_at) ]),
			E('p', {}, [ _('Contents'), ': ', groups.map((name) => boundedText(name, 64)).join(', ') || '-' ]),
			E('p', { 'class': 'sbox-muted' }, _('Review this exact manifest before restore. Restore uses only the opaque inspection ID.')),
			manifest, E('div', { 'class': 'right sbox-management-actions' }, [ restore, close ])
		]);
		close.addEventListener('click', () => { modalGeneration++; ui.hideModal(); });
		restore.addEventListener('click', () => mutate(async () => {
			if (destroyed || token !== modalGeneration || !INSPECTION_ID.test(inspection_id)) return;
			await wait(await api.backupRestore(inspection_id, SOURCE), _('Restoring backup…'));
			if (!destroyed && token === modalGeneration) { modalGeneration++; ui.hideModal(); }
			await refresh();
		}));
		ui.showModal(_('Backup inspection'), body);
	}
	async function refresh() {
		if (destroyed) return;
		const token = ++generation, replies = await Promise.all([ api.backupList(), api.settings_get() ]);
		if (destroyed || token !== generation) return;
		const reply = replies[0], desired = replies[1]?.backup;
		backups = Array.isArray(reply) ? reply : (Array.isArray(reply?.backups) ? reply.backups : []);
		backups = backups.filter((item) => item && BACKUP_ID.test(item.id || '')).slice(0, 100);
		if (desired && typeof desired === 'object') backupSettings = Object.assign({}, backupSettings, desired);
		paint();
	}
	function mount(node) { host = node; destroyed = false; paint(); refresh().catch(report); return host; }
	function destroy() {
		if (destroyed) return; destroyed = true; generation++; modalGeneration++;
		for (const cancel of cancels) cancel(); cancels.clear();
		for (const url of objectUrls) win.URL.revokeObjectURL(url); objectUrls.clear();
		if (typeof api.destroy === 'function') api.destroy(); host = null;
	}
	return { mount, refresh, destroy, importArchive, inspect, download, showPlan };
}

return { create, MAX_ARCHIVE };
