'use strict';
'require rpc';

const METHOD_SPECS = [
	{ name: 'status', params: [], operation: false },
	{ name: 'health', params: [], operation: false },
	{ name: 'operation_get', params: ['operation_id'], operation: false },
	{ name: 'operation_list', params: ['state', 'kind', 'source'], operation: false },
	{ name: 'operation_start', params: ['kind', 'arguments', 'source'], operation: true },
	{ name: 'service_start', params: ['profile', 'source'], operation: true },
	{ name: 'service_stop', params: ['profile', 'source'], operation: true },
	{ name: 'service_reload', params: ['profile', 'source'], operation: true },
	{ name: 'service_restart', params: ['profile', 'source'], operation: true },
	{ name: 'config_list', params: [], operation: false },
	{ name: 'config_read', params: ['profile'], operation: false },
	{ name: 'config_validate', params: ['profile', 'content', 'source'], operation: true },
	{ name: 'config_apply', params: ['profile', 'content', 'source'], operation: true },
	{ name: 'config_external_adopt', params: ['profile', 'source'], operation: true },
	{ name: 'settings_get', params: [], operation: false },
	{ name: 'settings_set', params: ['settings', 'source'], operation: true },
	{ name: 'history_list', params: ['profile', 'limit'], operation: false },
	{ name: 'history_diff', params: ['profile', 'from_revision', 'to_revision'], operation: false },
	{ name: 'history_open_draft', params: ['profile', 'revision'], operation: false },
	{ name: 'history_restore', params: ['profile', 'revision', 'source'], operation: true },
	{ name: 'subscription_get', params: ['profile'], operation: false },
	{ name: 'subscription_set', params: ['profile', 'url', 'source'], operation: true },
	{ name: 'subscription_update', params: ['profile', 'source'], operation: true },
	{ name: 'subscription_probe', params: ['profile', 'url'], operation: false },
	{ name: 'update_release', params: ['kind', 'channel'], operation: false },
	{ name: 'update_miclash', params: ['channel', 'source'], operation: true },
	{ name: 'update_mihomo', params: ['channel', 'source'], operation: true },
	{ name: 'update_rollback_mihomo', params: ['source'], operation: true },
	{ name: 'memory_status', params: [], operation: false },
	{ name: 'memory_reset_baseline', params: ['source'], operation: true },
	{ name: 'memory_settings', params: [], operation: false },
	{ name: 'diagnostics_summary', params: [], operation: false },
	{ name: 'diagnostics_create_report', params: [], operation: false },
	{ name: 'diagnostics_route_test', params: ['target', 'device', 'interface'], operation: false },
	{ name: 'backup_list', params: [], operation: false },
	{ name: 'backup_create', params: ['options', 'source'], operation: true },
	{ name: 'backup_inspect', params: ['backup_id', 'options'], operation: false },
	{ name: 'backup_restore', params: ['inspection_id', 'source'], operation: true },
	{ name: 'telegram_status', params: [], operation: false },
	{ name: 'telegram_settings', params: [], operation: false },
	{ name: 'telegram_test', params: [], operation: false },
	{ name: 'devices_list', params: [], operation: false },
	{ name: 'devices_policy_list', params: [], operation: false },
	{ name: 'devices_policy_set', params: ['policy', 'source'], operation: true },
	{ name: 'devices_policy_delete', params: ['mac', 'source'], operation: true },
	{ name: 'notifications_settings', params: [], operation: false },
	{ name: 'notifications_test', params: ['channel'], operation: false },
	{ name: 'transfer_begin', params: ['direction', 'kind', 'object_id', 'size', 'sha256', 'metadata'], operation: false },
	{ name: 'transfer_write', params: ['transfer_id', 'seq', 'data'], operation: false },
	{ name: 'transfer_read', params: ['transfer_id', 'seq'], operation: false },
	{ name: 'transfer_finish', params: ['transfer_id'], operation: false },
	{ name: 'transfer_abort', params: ['transfer_id'], operation: false }
];

const TERMINAL = new Set(['success', 'failure', 'interrupted']);
const MAX_TRANSFER = 16777216;
const MAX_CHUNK = 49152;

function apiError(code, message, details) {
	const error = new Error(String(message || code || 'INTERNAL'));
	error.code = String(code || 'INTERNAL');
	if (details != null) error.details = details;
	return error;
}

function normalizeReply(reply, operation) {
	if (reply == null || typeof reply !== 'object' || Array.isArray(reply))
		throw apiError('INVALID_RESPONSE', 'Invalid backend response');
	if (reply.error != null) {
		const error = reply.error;
		throw apiError(error.code, error.message, error.details);
	}
	if (operation && (typeof reply.operation_id !== 'string' ||
		!/^[A-Za-z0-9._-]+$/.test(reply.operation_id)))
		throw apiError('INVALID_RESPONSE', 'Invalid operation response');
	return reply;
}

function bytesOf(value) {
	if (value instanceof Uint8Array) return value;
	if (value instanceof ArrayBuffer) return new Uint8Array(value);
	if (typeof value === 'string') return new TextEncoder().encode(value);
	throw apiError('INVALID_ARGUMENT', 'Bytes are required');
}

function encodeBase64(bytes) {
	let binary = '';
	for (let i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
	return btoa(binary);
}

function decodeBase64(value) {
	if (typeof value !== 'string' || value.length > 65536)
		throw apiError('INVALID_RESPONSE', 'Invalid transfer chunk');
	let binary;
	try { binary = atob(value); }
	catch (error) { throw apiError('INVALID_RESPONSE', 'Invalid transfer chunk'); }
	if (binary.length > MAX_CHUNK) throw apiError('INVALID_RESPONSE', 'Oversized transfer chunk');
	const bytes = new Uint8Array(binary.length);
	for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
	return bytes;
}

async function sha256(bytes, cryptoProvider) {
	if (!cryptoProvider || !cryptoProvider.subtle)
		throw apiError('UNAVAILABLE', 'Secure digest unavailable');
	const digest = new Uint8Array(await cryptoProvider.subtle.digest('SHA-256', bytes));
	return Array.from(digest, (byte) => byte.toString(16).padStart(2, '0')).join('');
}

function createClient(options) {
	options = options || {};
	const timers = new Set();
	const calls = {};
	const timerSet = options.setTimeout || window.setTimeout.bind(window);
	const timerClear = options.clearTimeout || window.clearTimeout.bind(window);
	const cryptoProvider = options.crypto || window.crypto;
	let destroyed = false;

	for (const spec of METHOD_SPECS) {
		const declared = rpc.declare({ object: 'miclash', method: spec.name,
			params: spec.params, expect: {} });
		calls[spec.name] = (...args) => {
			if (destroyed) return Promise.reject(apiError('CANCELLED', 'View destroyed'));
			return Promise.resolve(declared(...args)).then((reply) => normalizeReply(reply, spec.operation));
		};
	}

	const client = {
		destroy() {
			if (destroyed) return;
			destroyed = true;
			for (const timer of timers) timerClear(timer);
			timers.clear();
		},

		watchOperation(operationId, callback, interval) {
			if (typeof operationId !== 'string' || typeof callback !== 'function')
				throw apiError('INVALID_ARGUMENT', 'Operation watcher arguments are invalid');
			let cancelled = false, ownedTimer = null;
			const delay = Math.max(250, Math.min(5000, Number(interval) || 1000));
			const poll = async () => {
				if (cancelled || destroyed) return;
				try {
					const reply = await client.operation_get(operationId);
					if (cancelled || destroyed) return;
					callback(reply.operation);
					if (TERMINAL.has(reply.operation && reply.operation.state)) return;
				} catch (error) {
					if (!cancelled && !destroyed) callback(null, error);
				}
				if (!cancelled && !destroyed) {
					ownedTimer = timerSet(() => {
						timers.delete(ownedTimer);
						ownedTimer = null;
						poll();
					}, delay);
					timers.add(ownedTimer);
				}
			};
			poll();
			return () => {
				cancelled = true;
				if (ownedTimer != null) {
					timerClear(ownedTimer);
					timers.delete(ownedTimer);
					ownedTimer = null;
				}
			};
		},

		subscribeOperation(operationId, callback, interval) {
			return this.watchOperation(operationId, callback, interval);
		},

		async uploadChunks(kind, metadata, value) {
			const bytes = bytesOf(value);
			if (!bytes.length || bytes.length > MAX_TRANSFER)
				throw apiError('RESPONSE_TOO_LARGE', 'Transfer size is outside the allowed range');
			const hash = await sha256(bytes, cryptoProvider);
			let transferId = null;
			try {
				const begun = await client.transfer_begin('upload', kind, '', bytes.length, hash,
					metadata || {});
				transferId = begun.transfer_id;
				const chunkSize = Math.min(MAX_CHUNK, Number(begun.chunk_size) || 0);
				if (!transferId || chunkSize < 1)
					throw apiError('INVALID_RESPONSE', 'Invalid transfer declaration');
				let seq = 0;
				for (let offset = 0; offset < bytes.length; offset += chunkSize) {
					const chunk = bytes.subarray(offset, Math.min(bytes.length, offset + chunkSize));
					const reply = await client.transfer_write(transferId, seq, encodeBase64(chunk));
					if (reply.next_seq !== seq + 1)
						throw apiError('INVALID_RESPONSE', 'Invalid transfer sequence');
					seq++;
				}
				const result = await client.transfer_finish(transferId);
				transferId = null;
				return result;
			} catch (error) {
				if (transferId) {
					try { await client.transfer_abort(transferId); } catch (ignore) {}
				}
				throw error;
			}
		},

		async downloadChunks(kind, opaqueId, metadata) {
			let transferId = null;
			try {
				const begun = await client.transfer_begin('download', kind, opaqueId, 0, '', metadata || {});
				transferId = begun.transfer_id;
				if (!transferId || !Number.isInteger(begun.size) || begun.size < 0 ||
					begun.size > MAX_TRANSFER || !/^[0-9a-f]{64}$/.test(begun.sha256 || ''))
					throw apiError('INVALID_RESPONSE', 'Invalid transfer declaration');
				const output = new Uint8Array(begun.size);
				let offset = 0, seq = 0, eof = false;
				while (!eof) {
					const reply = await client.transfer_read(transferId, seq);
					if (reply.seq !== seq || reply.next_seq !== seq + 1)
						throw apiError('INVALID_RESPONSE', 'Invalid transfer sequence');
					const chunk = decodeBase64(reply.data);
					if (offset + chunk.length > output.length)
						throw apiError('INVALID_RESPONSE', 'Transfer exceeds declared size');
					output.set(chunk, offset);
					offset += chunk.length;
					eof = reply.eof === true;
					if (!eof && !chunk.length) throw apiError('INVALID_RESPONSE', 'Empty transfer chunk');
					seq++;
				}
				if (offset !== output.length || await sha256(output, cryptoProvider) !== begun.sha256)
					throw apiError('VALIDATION_FAILED', 'Transfer digest mismatch');
				await client.transfer_finish(transferId);
				transferId = null;
				return output;
			} catch (error) {
				if (transferId) {
					try { await client.transfer_abort(transferId); } catch (ignore) {}
				}
				throw error;
			}
		}
	};

	for (const spec of METHOD_SPECS) client[spec.name] = calls[spec.name];
	Object.assign(client, {
		diagnosticsSummary: client.diagnostics_summary,
		createDiagnosticReport: client.diagnostics_create_report,
		routeTest: client.diagnostics_route_test,
		historyList: client.history_list,
		historyDiff: client.history_diff,
		historyOpenDraft: client.history_open_draft,
		historyRestore: client.history_restore,
		memoryStatus: client.memory_status,
		memoryResetBaseline: client.memory_reset_baseline,
		memorySettings: client.memory_settings,
		backupList: client.backup_list,
		backupCreate: client.backup_create,
		backupInspect: client.backup_inspect,
		backupRestore: client.backup_restore,
		devicesList: client.devices_list,
		devicePolicies: client.devices_policy_list,
		setDevicePolicy: client.devices_policy_set,
		deleteDevicePolicy: client.devices_policy_delete,
		notificationSettings: client.notifications_settings,
		testNotification: client.notifications_test
	});
	return client;
}

return {
	create: createClient,
	methods: METHOD_SPECS
};
