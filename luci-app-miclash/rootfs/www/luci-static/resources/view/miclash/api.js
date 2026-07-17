'use strict';
'require rpc';

const METHOD_SPECS = [
	{ name: 'status', params: [], operation: false, access: 'read' },
	{ name: 'health', params: [], operation: false, access: 'read' },
	{ name: 'operation_get', params: ['operation_id'], operation: false, access: 'read' },
	{ name: 'operation_list', params: ['state', 'kind', 'source'], operation: false, access: 'read' },
	{ name: 'operation_start', params: ['kind', 'arguments', 'source'], operation: true, access: 'write' },
	{ name: 'service_start', params: ['profile', 'source'], operation: true, access: 'write' },
	{ name: 'service_stop', params: ['profile', 'source'], operation: true, access: 'write' },
	{ name: 'service_reload', params: ['profile', 'source'], operation: true, access: 'write' },
	{ name: 'service_restart', params: ['profile', 'source'], operation: true, access: 'write' },
	{ name: 'config_list', params: [], operation: false, access: 'read' },
	{ name: 'config_read', params: ['profile'], operation: false, access: 'write' },
	{ name: 'config_read_draft', params: ['profile'], operation: false, access: 'write' },
	{ name: 'config_save_draft', params: ['profile', 'content', 'source'], operation: true, access: 'write' },
	{ name: 'config_validate', params: ['profile', 'content', 'source'], operation: true, access: 'write' },
	{ name: 'config_apply', params: ['profile', 'content', 'source'], operation: true, access: 'write' },
	{ name: 'operational_settings_apply', params: ['profile', 'content', 'settings', 'source'], operation: true, access: 'write' },
	{ name: 'config_swap', params: ['profile', 'source'], operation: true, access: 'write' },
	{ name: 'config_external_adopt', params: ['profile', 'source'], operation: true, access: 'write' },
	{ name: 'settings_get', params: [], operation: false, access: 'read' },
	{ name: 'settings_set', params: ['settings', 'source'], operation: true, access: 'write' },
	{ name: 'guard_transition', params: ['enabled', 'source'], operation: true, access: 'write' },
	{ name: 'history_list', params: ['profile', 'limit'], operation: false, access: 'read' },
	{ name: 'history_diff', params: ['profile', 'from_revision', 'to_revision'], operation: false, access: 'write' },
	{ name: 'history_open_draft', params: ['profile', 'revision', 'source'], operation: true, access: 'write' },
	{ name: 'history_restore', params: ['profile', 'revision', 'source'], operation: true, access: 'write' },
	{ name: 'subscription_get', params: ['profile'], operation: false, access: 'read' },
	{ name: 'subscription_set', params: ['profile', 'url', 'source'], operation: true, access: 'write' },
	{ name: 'subscription_update', params: ['profile', 'source'], operation: true, access: 'write' },
	{ name: 'update_release', params: ['kind', 'channel'], operation: false, access: 'read' },
	{ name: 'update_miclash', params: ['channel', 'source'], operation: true, access: 'write' },
	{ name: 'update_mihomo', params: ['channel', 'source'], operation: true, access: 'write' },
	{ name: 'update_rollback_mihomo', params: ['source'], operation: true, access: 'write' },
	{ name: 'memory_status', params: [], operation: false, access: 'read' },
	{ name: 'memory_reset_baseline', params: ['source'], operation: true, access: 'write' },
	{ name: 'memory_settings', params: [], operation: false, access: 'read' },
	{ name: 'diagnostics_summary', params: [], operation: false, access: 'read' },
	{ name: 'diagnostics_create_report', params: [], operation: false, access: 'write' },
	{ name: 'diagnostics_route_test', params: ['target', 'device', 'interface'], operation: false, access: 'write' },
	{ name: 'backup_list', params: [], operation: false, access: 'read' },
	{ name: 'backup_create', params: ['options', 'source'], operation: true, access: 'write' },
	{ name: 'backup_inspect', params: ['backup_id', 'options'], operation: false, access: 'write' },
	{ name: 'backup_restore', params: ['inspection_id', 'source'], operation: true, access: 'write' },
	{ name: 'telegram_status', params: [], operation: false, access: 'read' },
	{ name: 'telegram_settings', params: [], operation: false, access: 'read' },
	{ name: 'telegram_test', params: [], operation: false, access: 'write' },
	{ name: 'devices_list', params: [], operation: false, access: 'read' },
	{ name: 'devices_timezones', params: [], operation: false, access: 'read' },
	{ name: 'devices_policy_list', params: [], operation: false, access: 'read' },
	{ name: 'devices_policy_set', params: ['policy', 'source'], operation: true, access: 'write' },
	{ name: 'devices_policy_delete', params: ['policy_id', 'expected_revision', 'source'], operation: true, access: 'write' },
	{ name: 'notifications_settings', params: [], operation: false, access: 'read' },
	{ name: 'notifications_test', params: ['channel'], operation: false, access: 'write' },
	{ name: 'notifications_list', params: ['generation', 'cursor', 'limit'], operation: false, access: 'read' },
	{ name: 'logs_read', params: ['generation', 'cursor', 'limit'], operation: false, access: 'read' },
	{ name: 'system_info', params: [], operation: false, access: 'read' },
	{ name: 'network_interfaces', params: [], operation: false, access: 'read' },
	{ name: 'ruleset_list', params: [], operation: false, access: 'read' },
	{ name: 'ruleset_read', params: ['name'], operation: false, access: 'read' },
	{ name: 'ruleset_write', params: ['name', 'content', 'source'], operation: true, access: 'write' },
	{ name: 'ruleset_delete', params: ['name', 'source'], operation: true, access: 'write' },
	{ name: 'ruleset_apply_whitelist', params: ['content', 'source'], operation: true, access: 'write' },
	{ name: 'transfer_begin', params: ['direction', 'kind', 'object_id', 'size', 'sha256', 'metadata'], operation: false, access: 'write' },
	{ name: 'transfer_write', params: ['transfer_id', 'seq', 'data'], operation: false, access: 'write' },
	{ name: 'transfer_read', params: ['transfer_id', 'seq'], operation: false, access: 'write' },
	{ name: 'transfer_finish', params: ['transfer_id'], operation: false, access: 'write' },
	{ name: 'transfer_abort', params: ['transfer_id'], operation: false, access: 'write' }
];

const TERMINAL = new Set(['success', 'failure', 'interrupted']);
const MAX_TRANSFER = 16777216;
const MAX_CHUNK = 49152;
const MAX_TRANSFER_CHUNKS = Math.ceil(MAX_TRANSFER / MAX_CHUNK);

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

function normalizeFailure(error) {
	if (error instanceof Error && typeof error.code === 'string') return error;
	const code = typeof error?.code === 'string' && /^[A-Z][A-Z0-9_]*$/.test(error.code)
		? error.code : 'RPC_ERROR';
	const message = typeof error?.message === 'string' && error.message.length
		? error.message : 'RPC request failed';
	return apiError(code, message);
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
	if (encodeBase64(bytes) !== value)
		throw apiError('INVALID_RESPONSE', 'Non-canonical transfer chunk');
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
	const rawCalls = {};
	const activeTransfers = new Set();
	const timerSet = options.setTimeout || window.setTimeout.bind(window);
	const timerClear = options.clearTimeout || window.clearTimeout.bind(window);
	const cryptoProvider = options.crypto || window.crypto;
	const eventTarget = options.eventTarget || window;
	const EventConstructor = options.CustomEvent || window.CustomEvent;
	let destroyed = false;
	function emitChange(method, operationId, state) {
		if (destroyed || !eventTarget || typeof eventTarget.dispatchEvent !== 'function') return;
		const detail = { object: 'miclash', method, operation_id: operationId, state };
		try {
			const event = typeof EventConstructor === 'function'
				? new EventConstructor('miclash:ubus-event', { detail })
				: { type: 'miclash:ubus-event', detail };
			eventTarget.dispatchEvent(event);
		} catch (error) {}
	}

	for (const spec of METHOD_SPECS) {
		const declared = rpc.declare({ object: 'miclash', method: spec.name,
			params: spec.params, expect: { '': {} }, reject: true });
		rawCalls[spec.name] = declared;
		calls[spec.name] = (...args) => {
			if (destroyed) return Promise.reject(apiError('CANCELLED', 'View destroyed'));
			return Promise.resolve(declared(...args))
				.then((reply) => {
					const normalized = normalizeReply(reply, spec.operation);
					if (spec.operation) emitChange(spec.name, normalized.operation_id, 'accepted');
					return normalized;
				})
				.catch((error) => { throw normalizeFailure(error); });
		};
	}
	function abortTransfer(transferId) {
		activeTransfers.delete(transferId);
		const call = destroyed ? rawCalls.transfer_abort : calls.transfer_abort;
		return Promise.resolve(call(transferId)).catch(() => null);
	}
	function ensureActive() {
		if (destroyed) throw apiError('CANCELLED', 'View destroyed');
	}

	const client = {
		destroy() {
			if (destroyed) return;
			destroyed = true;
			for (const timer of timers) timerClear(timer);
			timers.clear();
			for (const transferId of activeTransfers)
				Promise.resolve(rawCalls.transfer_abort(transferId)).catch(() => null);
			activeTransfers.clear();
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
					if (TERMINAL.has(reply.operation && reply.operation.state)) {
						emitChange('operation_get', operationId, reply.operation.state);
						return;
					}
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
				ensureActive();
				const chunkSize = begun.chunk_size;
				if (typeof transferId !== 'string' || !/^[0-9a-f]{64}$/.test(transferId) ||
					!Number.isInteger(chunkSize) || chunkSize < 1 || chunkSize > MAX_CHUNK ||
					Math.ceil(bytes.length / chunkSize) > MAX_TRANSFER_CHUNKS)
					throw apiError('INVALID_RESPONSE', 'Invalid transfer declaration');
				activeTransfers.add(transferId);
				let seq = 0;
				for (let offset = 0; offset < bytes.length; offset += chunkSize) {
					const chunk = bytes.subarray(offset, Math.min(bytes.length, offset + chunkSize));
					const reply = await client.transfer_write(transferId, seq, encodeBase64(chunk));
					ensureActive();
					if (reply.next_seq !== seq + 1)
						throw apiError('INVALID_RESPONSE', 'Invalid transfer sequence');
					seq++;
				}
				const result = await client.transfer_finish(transferId);
				activeTransfers.delete(transferId);
				transferId = null;
				return result;
			} catch (error) {
				if (transferId) {
					await abortTransfer(transferId);
				}
				throw error;
			}
		},

		async downloadChunks(kind, opaqueId, metadata) {
			let transferId = null;
			try {
				const begun = await client.transfer_begin('download', kind, opaqueId, 0, '', metadata || {});
				transferId = begun.transfer_id;
				ensureActive();
				const chunkSize = begun.chunk_size;
				if (typeof transferId !== 'string' || !/^[0-9a-f]{64}$/.test(transferId) ||
					!Number.isInteger(chunkSize) || chunkSize < 1 || chunkSize > MAX_CHUNK ||
					!Number.isInteger(begun.size) || begun.size < 0 || begun.size > MAX_TRANSFER ||
					!/^[0-9a-f]{64}$/.test(begun.sha256 || '') ||
					Math.ceil(begun.size / chunkSize) > MAX_TRANSFER_CHUNKS)
					throw apiError('INVALID_RESPONSE', 'Invalid transfer declaration');
				activeTransfers.add(transferId);
				const output = new Uint8Array(begun.size);
				let offset = 0;
				const reads = Math.ceil(begun.size / chunkSize);
				for (let seq = 0; seq < reads; seq++) {
					const reply = await client.transfer_read(transferId, seq);
					ensureActive();
					if (reply.seq !== seq || reply.next_seq !== seq + 1)
						throw apiError('INVALID_RESPONSE', 'Invalid transfer sequence');
					const chunk = decodeBase64(reply.data);
					const expected = Math.min(chunkSize, output.length - offset);
					if (chunk.length !== expected || reply.eof !== (seq === reads - 1))
						throw apiError('INVALID_RESPONSE', 'Invalid transfer chunk length');
					output.set(chunk, offset);
					offset += chunk.length;
				}
				let measuredHash = await sha256(output, cryptoProvider);
				ensureActive();
				if (offset !== output.length || measuredHash !== begun.sha256)
					throw apiError('VALIDATION_FAILED', 'Transfer digest mismatch');
				await client.transfer_finish(transferId);
				activeTransfers.delete(transferId);
				transferId = null;
				return output;
			} catch (error) {
				if (transferId) {
					await abortTransfer(transferId);
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
		configReadDraft: client.config_read_draft,
		configSaveDraft: client.config_save_draft,
		memoryStatus: client.memory_status,
		memoryResetBaseline: client.memory_reset_baseline,
		memorySettings: client.memory_settings,
		backupList: client.backup_list,
		backupCreate: client.backup_create,
		backupInspect: client.backup_inspect,
		backupRestore: client.backup_restore,
		devicesList: client.devices_list,
		deviceTimezones: client.devices_timezones,
		devicePolicies: client.devices_policy_list,
		setDevicePolicy: client.devices_policy_set,
		deleteDevicePolicy: client.devices_policy_delete,
		notificationSettings: client.notifications_settings,
		testNotification: client.notifications_test,
		notificationEvents: client.notifications_list
	});
	return client;
}

return {
	create: createClient,
	methods: METHOD_SPECS
};
