import * as errors from 'miclash.errors';
import * as redact from 'miclash.redact';
import * as schema from 'miclash.schema';

const MAX_CONTENT = 1048576;
const MUTATION_SOURCES = [ 'luci', 'telegram' ];
const OPERATION_SOURCES = [ 'luci', 'telegram', 'auto', 'system' ];
const OPERATION_STATES = [ 'queued', 'running', 'success', 'failure', 'interrupted' ];
const OPERATION_KINDS = [
	'service.start', 'service.stop', 'service.reload', 'service.restart',
	'config.validate', 'config.apply', 'config.external_adopt', 'history.restore',
	'subscription.set', 'subscription.update', 'update.miclash', 'update.mihomo',
	'update.rollback_mihomo', 'memory.reset_baseline', 'backup.create', 'backup.restore',
	'devices.policy_set', 'devices.policy_delete'
];
const TRANSFER_ROOT = '/tmp/miclash/transfers';
const TRANSFER_TTL = 300000;
const TRANSFER_CHUNK = 49152;
const TRANSFER_LIMIT = 8;
const TRANSFER_UPLOAD_LIMIT = 1;
const TRANSFER_MAX = 16777216;
const REPORT_MAX = 262144;

function canonical_error(error) {
	let normalized = errors.normalize(error);
	return {
		error: {
			code: normalized.code,
			message: normalized.code == 'INTERNAL' ? 'Internal error' : normalized.code
		}
	};
};

function guarded(callback) {
	return (request) => {
		try { return callback(request?.args ?? {}); }
		catch (error) { return canonical_error(error); }
	};
};

function exact(arguments, fields) {
	return schema.object(arguments, fields);
};

function source(arguments) {
	return schema.enum_value(arguments.source ?? 'luci', MUTATION_SOURCES);
};

function profile(arguments) {
	return schema.profile_name(arguments.profile ?? 'config.yaml');
};

function content(arguments) {
	return schema.validate({ type: 'string', min_length: 1, max_length: MAX_CONTENT },
		arguments.content);
};

function safe_id(value) {
	if (type(value) != 'string' || length(value) < 1 || length(value) > 128 ||
		!match(value, /^[A-Za-z0-9][A-Za-z0-9._-]*$/))
		errors.fail('INVALID_ARGUMENT');
	return value;
};

function safe_text(value, maximum) {
	if (type(value) != 'string' || length(value) < 1 || length(value) > maximum ||
		match(value, /[[:cntrl:]]/))
		errors.fail('INVALID_ARGUMENT');
	return value;
};

function safe_ruleset_name(value) {
	if (type(value) != 'string' || length(value) < 5 || length(value) > 90 ||
	    !match(value, /^[a-z0-9][a-z0-9_-]*\.txt$/))
		errors.fail('INVALID_ARGUMENT');
	return value;
};

function ruleset_content(value) {
	if (type(value) != 'string' || length(value) > 4194304 ||
	    index(value, sprintf('%c', 0)) >= 0)
		errors.fail('INVALID_ARGUMENT');
	return value;
};

function operation_reply(record) {
	if (type(record?.id) != 'string')
		errors.fail('INTERNAL');
	return { operation_id: schema.operation_id(record.id) };
};

function method(policy, callback) {
	return { args: policy, call: guarded(callback) };
};

function telegram_settings_value(app) {
	let settings = type(app.telegram_settings) == 'function' ? app.telegram_settings() :
		app.settings_get()?.telegram;
	if (type(settings) != 'object')
		settings = {};
	settings = redact.value('telegram', settings);
	return settings;
};

function telegram_status_value(app) {
	if (type(app.telegram_status) == 'function') {
		let status = redact.value('telegram_status', app.telegram_status());
		if (type(status) != 'object')
			errors.fail('INTERNAL');
		return status;
	}
	let settings = app.settings_get()?.telegram;
	return {
		running: false,
		enabled: settings?.enabled === true,
		configured: type(settings?.token) == 'string' && length(settings.token) > 0 &&
			type(settings?.user_id) == 'string' && length(settings.user_id) > 0
	};
};

function same_file(left, right) {
	return left?.type == 'file' && right?.type == 'file' &&
		left.inode == right.inode && left.dev?.major == right.dev?.major &&
		left.dev?.minor == right.dev?.minor &&
		left.nlink == 1 && right.nlink == 1;
};

function same_directory(left, right) {
	return left?.type == 'directory' && right?.type == 'directory' &&
		left.inode == right.inode && left.dev?.major == right.dev?.major &&
		left.dev?.minor == right.dev?.minor;
};

function secure_directory(runtime, path, expected) {
	let current = runtime.fs.lstat(path);
	if (current?.type != 'directory' || (current.uid != null && current.uid != 0) ||
		current.mode != 0o700 || runtime.fs.realpath(path) != path ||
		(expected != null && !same_directory(expected, current)))
		errors.fail('INTERNAL');
	return current;
};

function ensure_directory(runtime, path) {
	let current = runtime.fs.lstat(path);
	if (current == null) {
		if (runtime.fs.mkdir(path) !== true) errors.fail('INTERNAL');
		current = runtime.fs.lstat(path);
	}
	if (current?.type != 'directory' || (current.uid != null && current.uid != 0) ||
		runtime.fs.realpath(path) != path)
		errors.fail('INTERNAL');
	if (current.mode != 0o700 && runtime.fs.chmod(path, 0o700) !== true)
		errors.fail('INTERNAL');
	return secure_directory(runtime, path, null);
};

function transfer_id(value) {
	if (type(value) != 'string' || !match(value, /^[0-9a-f]{64}$/))
		errors.fail('INVALID_ARGUMENT');
	return value;
};

function transfer_metadata(value) {
	if (value == null) return {};
	if (type(value) != 'object' || type(value) == 'array') errors.fail('INVALID_ARGUMENT');
	let encoded;
	try { encoded = sprintf('%J', value); }
	catch (error) { errors.fail('INVALID_ARGUMENT'); }
	if (length(encoded) > 4096) errors.fail('RESPONSE_TOO_LARGE');
	try { return json(encoded); }
	catch (error) { errors.fail('INVALID_ARGUMENT'); }
};

function canonical_base64(value) {
	if (type(value) != 'string' || !length(value) || length(value) > 65536 ||
		length(value) % 4 != 0 || !match(value, /^[A-Za-z0-9+\/]*={0,2}$/))
		errors.fail('INVALID_ARGUMENT');
	let decoded;
	try { decoded = b64dec(value); }
	catch (error) { errors.fail('INVALID_ARGUMENT'); }
	if (b64enc(decoded) != value || length(decoded) > TRANSFER_CHUNK)
		errors.fail('INVALID_ARGUMENT');
	return decoded;
};

function write_all(runtime, handle, content) {
	let offset = 0;
	while (offset < length(content)) {
		let written = runtime.fs.write(handle, substr(content, offset));
		if (type(written) != 'int' || written < 1 || written > length(content) - offset)
			errors.fail('INTERNAL');
		offset += written;
	}
};

function transfer_result(value) {
	if (type(value) != 'object' || type(value) == 'array') errors.fail('INVALID_RESPONSE');
	let names = keys(value);
	if (length(names) != 1) errors.fail('INVALID_RESPONSE');
	if (names[0] == 'import_id' && type(value.import_id) == 'string' &&
		match(value.import_id, /^i-[0-9]{13}-[0-9a-f]{32}$/))
		return { import_id: value.import_id };
	if (names[0] == 'inspection_id' && type(value.inspection_id) == 'string' &&
		match(value.inspection_id, /^x-[0-9]{13}-[0-9a-f]{32}$/))
		return { inspection_id: value.inspection_id };
	errors.fail('INVALID_RESPONSE');
};

export function create_transfers(dependencies) {
	let runtime = dependencies?.runtime;
	if (type(runtime?.fs) != 'object' || type(runtime?.clock?.now) != 'function' ||
		type(runtime?.clock?.set_timeout) != 'function' ||
		type(runtime?.random?.hex) != 'function' || type(runtime?.digest?.sha256) != 'function' ||
		type(runtime?.digest?.sha256_file) != 'function' || runtime?.paths?.tmp != '/tmp/miclash' ||
		type(dependencies?.uploads) != 'object' || type(dependencies?.downloads) != 'object')
		errors.fail('INVALID_ARGUMENT');
	ensure_directory(runtime, runtime.paths.tmp);
	let root = ensure_directory(runtime, TRANSFER_ROOT), records = {};
	let expiry_timer = null, expiry_due = null, closed = false;

	function verify_root() {
		root = secure_directory(runtime, TRANSFER_ROOT, root);
		return root;
	};
	function recover_stale() {
		let entries = runtime.fs.lsdir(TRANSFER_ROOT);
		if (type(entries) != 'array' || length(entries) > TRANSFER_LIMIT)
			errors.fail('INTERNAL');
		for (let name in entries) {
			if (!match(name, /^[0-9a-f]{64}$/)) errors.fail('INTERNAL');
			let path = TRANSFER_ROOT + '/' + name, identity = runtime.fs.lstat(path);
			if (!same_file(identity, identity) || identity.mode != 0o600 ||
				(identity.uid != null && identity.uid != 0) || runtime.fs.realpath(path) != path)
				errors.fail('INTERNAL');
			verify_root();
			if (!same_file(identity, runtime.fs.lstat(path)) || runtime.fs.unlink(path) !== true)
				errors.fail('INTERNAL');
			verify_root();
		}
	};
	function safe_unlink(record) {
		if (record.path == null) return;
		let current = runtime.fs.lstat(record.path);
		if (same_file(record.identity, current) && runtime.fs.realpath(record.path) == record.path)
			runtime.fs.unlink(record.path);
	};
	function discard_created(path, handle, identity) {
		try { runtime.fs.close(handle); } catch (error) {}
		try {
			let current = runtime.fs.lstat(path);
			if (same_file(identity, current) && runtime.fs.realpath(path) == path)
				runtime.fs.unlink(path);
		} catch (error) {}
	};
	function dispose(record) {
		if (record == null) return;
		if (record.handle != null) {
			try { runtime.fs.close(record.handle); } catch (error) {}
			record.handle = null;
		}
		if (record.source?.close != null)
			try { record.source.close(); } catch (error) {}
		try { safe_unlink(record); } catch (error) {}
		delete records[record.id];
	};
	function cancel_timer(timer) {
		if (timer?.cancel == null) return;
		try { timer.cancel(); } catch (error) {}
	};
	function cancel_expiry() {
		let timer = expiry_timer;
		expiry_timer = null;
		expiry_due = null;
		cancel_timer(timer);
	};
	function dispose_all() {
		cancel_expiry();
		for (let record in values(records)) {
			try { dispose(record); }
			catch (error) { delete records[record.id]; }
		}
	};
	function prune() {
		let now = runtime.clock.now();
		for (let record in values(records))
			if (now >= record.expires_at) dispose(record);
	};
	function schedule_expiry() {
		if (closed) return cancel_expiry();
		let earliest = null;
		for (let id, record in records)
			if (earliest == null || record.expires_at < earliest) earliest = record.expires_at;
		if (earliest == null) return cancel_expiry();
		if (expiry_timer != null && expiry_due == earliest) return;
		let previous = expiry_timer, timer = null, activated = false, fired = false;
		try {
			timer = runtime.clock.set_timeout(max(0, earliest - runtime.clock.now()), () => {
				if (!activated) { fired = true; return; }
				if (expiry_timer !== timer || closed) return;
				expiry_timer = null;
				expiry_due = null;
				prune();
				try { schedule_expiry(); }
				catch (error) { dispose_all(); }
			});
		} catch (error) { errors.fail('INTERNAL'); }
		if (timer == null || type(timer.cancel) != 'function' || fired) {
			cancel_timer(timer);
			errors.fail('INTERNAL');
		}
		expiry_timer = timer;
		expiry_due = earliest;
		activated = true;
		cancel_timer(previous);
	};
	function acquire(id, direction) {
		prune();
		id = transfer_id(id);
		let record = records[id];
		if (record == null) errors.fail('NOT_FOUND');
		if (record.direction != direction) errors.fail('INVALID_ARGUMENT');
		verify_root();
		if (record.path != null) {
			let path_identity = runtime.fs.lstat(record.path);
			let handle_identity = runtime.fs.fstat(record.handle);
			if (!same_file(record.identity, path_identity) ||
				!same_file(record.identity, handle_identity) ||
				path_identity.mode != 0o600 || handle_identity.mode != 0o600 ||
				(path_identity.uid != null && path_identity.uid != 0) ||
				(handle_identity.uid != null && handle_identity.uid != 0) ||
				runtime.fs.realpath(record.path) != record.path)
				errors.fail('INTERNAL');
		}
		return record;
	};
	function allocate_id() {
		for (let attempt = 0; attempt < 16; attempt++) {
			let id = runtime.random.hex(32);
			if (!match(id, /^[0-9a-f]{64}$/)) errors.fail('INTERNAL');
			if (records[id] == null && runtime.fs.lstat(TRANSFER_ROOT + '/' + id) == null)
				return id;
		}
		errors.fail('BUSY');
	};
	function begin(arguments) {
		if (closed) errors.fail('HEALTH_FAILED');
		prune();
		verify_root();
		if (length(keys(records)) >= TRANSFER_LIMIT) errors.fail('BUSY');
		exact(arguments, {
			direction: { type: 'string', required: true }, kind: { type: 'string', required: true },
			object_id: { type: 'string' }, size: { type: 'int', required: true },
			sha256: { type: 'string', required: true }, metadata: { type: 'object' }
		});
		let metadata = transfer_metadata(arguments.metadata), id = allocate_id();
		if (arguments.direction == 'upload') {
			let upload_count = 0, reserved = 0;
			for (let record in values(records))
				if (record.direction == 'upload') { upload_count++; reserved += record.size; }
			if (arguments.kind != 'backup' || type(dependencies.uploads.backup) != 'function' ||
				length(arguments.object_id ?? '') || arguments.size < 1 || arguments.size > TRANSFER_MAX ||
				!match(arguments.sha256, /^[0-9a-f]{64}$/))
				errors.fail('INVALID_ARGUMENT');
			if (upload_count >= TRANSFER_UPLOAD_LIMIT || reserved + arguments.size > TRANSFER_MAX)
				errors.fail('BUSY');
			let path = TRANSFER_ROOT + '/' + id, handle = runtime.fs.open(path, 'wx', 0o600);
			if (handle == null) errors.fail('INTERNAL');
			let identity = runtime.fs.fstat(handle), path_identity = runtime.fs.lstat(path);
			if (!same_file(identity, path_identity) || identity.size != 0 || identity.mode != 0o600 ||
				(identity.uid != null && identity.uid != 0) || runtime.fs.realpath(path) != path) {
				discard_created(path, handle, identity);
				errors.fail('INTERNAL');
			}
			try { verify_root(); }
			catch (error) {
				discard_created(path, handle, identity);
				errors.fail(errors.normalize(error).code);
			}
			let record = { id, direction: 'upload', kind: arguments.kind, metadata,
				size: arguments.size, sha256: arguments.sha256, received: 0, next_seq: 0,
				expires_at: runtime.clock.now() + TRANSFER_TTL, path, handle, identity };
			records[id] = record;
			try { schedule_expiry(); }
			catch (error) {
				dispose(record);
				errors.fail(errors.normalize(error).code);
			}
			return { transfer_id: id, chunk_size: TRANSFER_CHUNK,
				expires_at: records[id].expires_at };
		}
		if (arguments.direction != 'download' ||
			(arguments.kind != 'report' && arguments.kind != 'backup') ||
			type(dependencies.downloads[arguments.kind]) != 'function' ||
			arguments.size != 0 || length(arguments.sha256) ||
			type(arguments.object_id) != 'string')
			errors.fail('INVALID_ARGUMENT');
		if ((arguments.kind == 'report' && !match(arguments.object_id, /^rpt_[0-9a-f]{32}$/)) ||
			(arguments.kind == 'backup' &&
			 !match(arguments.object_id, /^b-[0-9]{13}-[0-9a-f]{32}$/)))
			errors.fail('INVALID_ARGUMENT');
		for (let active in values(records))
			if (active.direction == 'download') errors.fail('BUSY');
		let source = dependencies.downloads[arguments.kind](arguments.object_id, metadata);
		let maximum = arguments.kind == 'report' ? REPORT_MAX : TRANSFER_MAX;
		if (type(source?.read) != 'function' || type(source?.finish) != 'function' ||
			type(source?.size) != 'int' ||
			source.size < 0 || source.size > maximum || type(source.sha256) != 'string' ||
			!match(source.sha256, /^[0-9a-f]{64}$/)) {
			try { source?.close?.(); } catch (error) {}
			errors.fail('INVALID_RESPONSE');
		}
		let record = { id, direction: 'download', kind: arguments.kind, metadata,
			size: source.size, sha256: source.sha256, offset: 0, next_seq: 0,
			expires_at: runtime.clock.now() + TRANSFER_TTL, source };
		records[id] = record;
		try { schedule_expiry(); }
		catch (error) {
			dispose(record);
			errors.fail(errors.normalize(error).code);
		}
		return { transfer_id: id, chunk_size: TRANSFER_CHUNK, size: source.size,
			sha256: source.sha256, expires_at: records[id].expires_at };
	};
	function write(arguments) {
		exact(arguments, { transfer_id: { type: 'string', required: true },
			seq: { type: 'int', required: true }, data: { type: 'string', required: true } });
		let record = acquire(arguments.transfer_id, 'upload');
		if (arguments.seq != record.next_seq) errors.fail('INVALID_ARGUMENT');
		let decoded = canonical_base64(arguments.data);
		if (record.received + length(decoded) > record.size) errors.fail('RESPONSE_TOO_LARGE');
		write_all(runtime, record.handle, decoded);
		record.received += length(decoded);
		record.next_seq++;
		return { next_seq: record.next_seq, received: record.received };
	};
	function read(arguments) {
		exact(arguments, { transfer_id: { type: 'string', required: true },
			seq: { type: 'int', required: true } });
		let record = acquire(arguments.transfer_id, 'download');
		if (arguments.seq != record.next_seq) errors.fail('INVALID_ARGUMENT');
		let remaining = record.size - record.offset;
		let content = record.source.read(record.offset, min(remaining, TRANSFER_CHUNK));
		if (type(content) != 'string' || length(content) > min(remaining, TRANSFER_CHUNK) ||
			(remaining > 0 && !length(content)))
			errors.fail('INVALID_RESPONSE');
		record.offset += length(content);
		let sequence = record.next_seq++;
		return { seq: sequence, data: b64enc(content), eof: record.offset == record.size,
			next_seq: record.next_seq };
	};
	function finish(arguments) {
		exact(arguments, { transfer_id: { type: 'string', required: true } });
		let id = transfer_id(arguments.transfer_id), record = records[id];
		if (record == null) errors.fail('NOT_FOUND');
		if (record.direction == 'download') {
			record = acquire(id, 'download');
			if (record.offset != record.size) errors.fail('VALIDATION_FAILED');
			let measured = null;
			try { measured = record.source.finish(); } catch (error) {}
			if (type(measured) != 'object' || length(keys(measured)) != 2 ||
				!exists(measured, 'size') || !exists(measured, 'sha256') ||
				measured.size != record.size || measured.sha256 != record.sha256) {
				dispose(record);
				schedule_expiry();
				errors.fail('VALIDATION_FAILED');
			}
			dispose(record);
			schedule_expiry();
			return { completed: true };
		}
		record = acquire(id, 'upload');
		if (record.received != record.size) errors.fail('VALIDATION_FAILED');
		if (runtime.fs.flush(record.handle) !== true || runtime.fs.close(record.handle) !== true)
			errors.fail('INTERNAL');
		record.handle = null;
		let before = runtime.fs.lstat(record.path);
		let after;
		if (!same_file(record.identity, before) || before.size != record.size ||
			before.mode != 0o600 || (before.uid != null && before.uid != 0) ||
			runtime.fs.realpath(record.path) != record.path ||
			runtime.digest.sha256_file(record.path) != record.sha256 ||
			!same_file(before, after = runtime.fs.lstat(record.path)) || after.size != before.size) {
			dispose(record);
			schedule_expiry();
			errors.fail('VALIDATION_FAILED');
		}
		let reader = runtime.fs.open(record.path, 're');
		if (reader == null || !same_file(record.identity, runtime.fs.fstat(reader))) {
			if (reader != null) try { runtime.fs.close(reader); } catch (error) {}
			dispose(record);
			errors.fail('INTERNAL');
		}
		let closed = false;
		let staged = {
			kind: record.kind, metadata: record.metadata, size: record.size, sha256: record.sha256,
			read: (amount) => {
				if (closed || type(amount) != 'int' || amount < 1 || amount > TRANSFER_CHUNK)
					errors.fail('INVALID_ARGUMENT');
				let chunk = runtime.fs.read(reader, amount);
				if (type(chunk) != 'string' || length(chunk) > amount) errors.fail('INTERNAL');
				return chunk;
			}
		};
		let result, failure = null;
		try { result = dependencies.uploads[record.kind](staged); }
		catch (error) { failure = errors.normalize(error).code; }
		closed = true;
		if (runtime.fs.close(reader) !== true) failure = 'INTERNAL';
		if (!same_file(record.identity, runtime.fs.lstat(record.path))) failure = 'INTERNAL';
		dispose(record);
		schedule_expiry();
		if (failure != null) errors.fail(failure);
		return { completed: true, result: transfer_result(result) };
	};
	function abort(arguments) {
		exact(arguments, { transfer_id: { type: 'string', required: true } });
		let id = transfer_id(arguments.transfer_id), record = records[id];
		if (record == null) errors.fail('NOT_FOUND');
		dispose(record);
		schedule_expiry();
		return { aborted: true };
	};
	function close() {
		if (closed) return true;
		closed = true;
		dispose_all();
		return true;
	};
	function safe(callback) {
		return (arguments) => {
			try { return callback(arguments ?? {}); }
			catch (error) { return canonical_error(error); }
		};
	};
	recover_stale();
	return { begin: safe(begin), write: safe(write), read: safe(read),
		finish: safe(finish), abort: safe(abort), close };
};

export function method_table(app, transfers) {
	for (let name in [
		'status', 'health', 'operation_get', 'operation_list',
		'service_start', 'service_stop', 'service_reload', 'service_restart',
		'config_list', 'config_read', 'config_read_draft', 'config_save_draft',
		'config_validate', 'config_apply', 'operational_settings_apply', 'config_swap',
		'settings_get', 'settings_set', 'guard_transition', 'set_draining'
	]) if (type(app?.[name]) != 'function')
		errors.fail('INVALID_ARGUMENT');

	let empty = {};
	let service_policy = { profile: '', source: '' };
	let config_policy = { profile: '', content: '', source: '' };
	function transfer(method_name, arguments) {
		if (type(transfers?.[method_name]) != 'function') errors.fail('HEALTH_FAILED');
		let reply = transfers[method_name](arguments);
		if (reply?.error != null) errors.fail(reply.error.code ?? 'INTERNAL');
		return reply;
	};
	function domain_read(name, arguments) {
		if (type(app?.[name]) != 'function') errors.fail('HEALTH_FAILED');
		return app[name](arguments);
	};
	function domain_operation(name, arguments) {
		if (type(app?.[name]) != 'function') errors.fail('HEALTH_FAILED');
		return operation_reply(app[name](arguments));
	};

	return {
		status: method(empty, (arguments) => {
			exact(arguments, {});
			return app.status();
		}),
		health: method(empty, (arguments) => {
			exact(arguments, {});
			return app.health();
		}),
		operation_get: method({ operation_id: '' }, (arguments) => {
			exact(arguments, { operation_id: { type: 'string', required: true } });
			let operation = app.operation_get(schema.operation_id(arguments.operation_id));
			if (operation == null)
				errors.fail('NOT_FOUND');
			return { operation: redact.value('operation', operation) };
		}),
		operation_list: method({ state: '', kind: '', source: '' }, (arguments) => {
			exact(arguments, {
				state: { type: 'string', nullable: true },
				kind: { type: 'string', max_length: 128, nullable: true },
				source: { type: 'string', nullable: true }
			});
			if (arguments.state != null)
				schema.enum_value(arguments.state, OPERATION_STATES);
			if (arguments.source != null)
				schema.enum_value(arguments.source, OPERATION_SOURCES);
			if (arguments.kind != null && !match(arguments.kind,
				/^[A-Za-z0-9][A-Za-z0-9._-]*$/))
				errors.fail('INVALID_ARGUMENT');
			return { operations: redact.value('operations', app.operation_list(arguments)) };
		}),
		operation_start: method({ kind: '', arguments: {}, source: '' }, (arguments) => {
			exact(arguments, { kind: { type: 'string', required: true },
				arguments: { type: 'object', required: true }, source: { type: 'string' } });
			return domain_operation('operation_start', {
				kind: schema.enum_value(arguments.kind, OPERATION_KINDS),
				arguments: transfer_metadata(arguments.arguments), source: source(arguments) });
		}),
		service_start: method(service_policy, (arguments) => {
			exact(arguments, { profile: { type: 'string' }, source: { type: 'string' } });
			return operation_reply(app.service_start(profile(arguments), source(arguments)));
		}),
		service_stop: method(service_policy, (arguments) => {
			exact(arguments, { profile: { type: 'string' }, source: { type: 'string' } });
			return operation_reply(app.service_stop(profile(arguments), source(arguments)));
		}),
		service_reload: method(service_policy, (arguments) => {
			exact(arguments, { profile: { type: 'string' }, source: { type: 'string' } });
			return operation_reply(app.service_reload(profile(arguments), source(arguments)));
		}),
		service_restart: method(service_policy, (arguments) => {
			exact(arguments, { profile: { type: 'string' }, source: { type: 'string' } });
			return operation_reply(app.service_restart(profile(arguments), source(arguments)));
		}),
		config_list: method(empty, (arguments) => {
			exact(arguments, {});
			return { profiles: app.config_list() };
		}),
		config_read: method({ profile: '' }, (arguments) => {
			exact(arguments, { profile: { type: 'string' } });
			let selected_profile = profile(arguments);
			return {
				profile: selected_profile,
				content: app.config_read(selected_profile)
			};
		}),
		config_read_draft: method({ profile: '' }, (arguments) => {
			exact(arguments, { profile: { type: 'string' } });
			let selected_profile = profile(arguments);
			return { profile: selected_profile,
				content: app.config_read_draft(selected_profile) };
		}),
		config_save_draft: method(config_policy, (arguments) => {
			exact(arguments, {
				profile: { type: 'string' }, content: { type: 'string', required: true },
				source: { type: 'string' }
			});
			return operation_reply(app.config_save_draft(profile(arguments),
				content(arguments), source(arguments)));
		}),
		config_validate: method(config_policy, (arguments) => {
			exact(arguments, {
				profile: { type: 'string' }, content: { type: 'string', required: true },
				source: { type: 'string' }
			});
			return operation_reply(app.config_validate(profile(arguments),
				content(arguments), source(arguments)));
		}),
		config_apply: method(config_policy, (arguments) => {
			exact(arguments, {
				profile: { type: 'string' }, content: { type: 'string', required: true },
				source: { type: 'string' }
			});
			return operation_reply(app.config_apply(profile(arguments),
				content(arguments), source(arguments)));
		}),
		operational_settings_apply: method({ profile: '', content: '', settings: {}, source: '' },
			(arguments) => {
				exact(arguments, {
					profile: { type: 'string' }, content: { type: 'string', required: true },
					settings: { type: 'object', required: true }, source: { type: 'string' }
				});
				return operation_reply(app.operational_settings_apply(profile(arguments),
					content(arguments), arguments.settings, source(arguments)));
			}),
		config_swap: method(service_policy, (arguments) => {
			exact(arguments, { profile: { type: 'string' }, source: { type: 'string' } });
			let selected = profile(arguments);
			if (selected == 'config.yaml') errors.fail('INVALID_ARGUMENT');
			return operation_reply(app.config_swap(selected, source(arguments)));
		}),
		config_external_adopt: method(service_policy, (arguments) => {
			exact(arguments, { profile: { type: 'string' }, source: { type: 'string' } });
			return domain_operation('config_external_adopt', {
				profile: profile(arguments), source: source(arguments) });
		}),
		settings_get: method(empty, (arguments) => {
			exact(arguments, {});
			return redact.value('settings', app.settings_get());
		}),
		settings_set: method({ settings: {}, source: '' }, (arguments) => {
			exact(arguments, {
				settings: { type: 'object', required: true }, source: { type: 'string' }
			});
			return operation_reply(app.settings_set(arguments.settings, source(arguments)));
		}),
		guard_transition: method({ enabled: false, source: '' }, (arguments) => {
			exact(arguments, {
				enabled: { type: 'bool', required: true }, source: { type: 'string' }
			});
			return operation_reply(app.guard_transition(arguments.enabled, source(arguments)));
		}),
		history_list: method({ profile: '', limit: 0 }, (arguments) => {
			exact(arguments, { profile: { type: 'string' }, limit: { type: 'int' } });
			let limit = arguments.limit ?? 10;
			if (limit < 1 || limit > 100) errors.fail('INVALID_ARGUMENT');
			return domain_read('history_list', { profile: profile(arguments), limit });
		}),
		history_diff: method({ profile: '', from_revision: '', to_revision: '' }, (arguments) => {
			exact(arguments, { profile: { type: 'string' },
				from_revision: { type: 'string', required: true },
				to_revision: { type: 'string', required: true } });
			return domain_read('history_diff', { profile: profile(arguments),
				from_revision: safe_id(arguments.from_revision),
				to_revision: safe_id(arguments.to_revision) });
		}),
		history_open_draft: method({ profile: '', revision: '', source: '' }, (arguments) => {
			exact(arguments, { profile: { type: 'string' },
				revision: { type: 'string', required: true }, source: { type: 'string' } });
			return domain_operation('history_open_draft', { profile: profile(arguments),
				revision: safe_id(arguments.revision), source: source(arguments) });
		}),
		history_restore: method({ profile: '', revision: '', source: '' }, (arguments) => {
			exact(arguments, { profile: { type: 'string' },
				revision: { type: 'string', required: true }, source: { type: 'string' } });
			return domain_operation('history_restore', { profile: profile(arguments),
				revision: safe_id(arguments.revision), source: source(arguments) });
		}),
		subscription_get: method({ profile: '' }, (arguments) => {
			exact(arguments, { profile: { type: 'string' } });
			return domain_read('subscription_get', { profile: profile(arguments) });
		}),
		subscription_set: method({ profile: '', url: '', source: '' }, (arguments) => {
			exact(arguments, { profile: { type: 'string' },
				url: { type: 'string', required: true }, source: { type: 'string' } });
			let url = length(arguments.url) ? schema.url(arguments.url) : '';
			return domain_operation('subscription_set', { profile: profile(arguments),
				url, source: source(arguments) });
		}),
		subscription_update: method(service_policy, (arguments) => {
			exact(arguments, { profile: { type: 'string' }, source: { type: 'string' } });
			return domain_operation('subscription_update', {
				profile: profile(arguments), source: source(arguments) });
		}),
		update_release: method({ kind: '', channel: '' }, (arguments) => {
			exact(arguments, { kind: { type: 'string', required: true },
				channel: { type: 'string', required: true } });
			let kind = schema.enum_value(arguments.kind, [ 'miclash', 'mihomo' ]);
			let channel = safe_id(arguments.channel);
			return domain_read('update_release', { kind, channel });
		}),
		update_miclash: method({ channel: '', source: '' }, (arguments) => {
			exact(arguments, { channel: { type: 'string', required: true },
				source: { type: 'string' } });
			return domain_operation('update_miclash', {
				channel: safe_id(arguments.channel), source: source(arguments) });
		}),
		update_mihomo: method({ channel: '', source: '' }, (arguments) => {
			exact(arguments, { channel: { type: 'string', required: true },
				source: { type: 'string' } });
			return domain_operation('update_mihomo', {
				channel: safe_id(arguments.channel), source: source(arguments) });
		}),
		update_rollback_mihomo: method({ source: '' }, (arguments) => {
			exact(arguments, { source: { type: 'string' } });
			return domain_operation('update_rollback_mihomo', { source: source(arguments) });
		}),
		memory_status: method(empty, (arguments) => {
			exact(arguments, {});
			return domain_read('memory_status', {});
		}),
		memory_reset_baseline: method({ source: '' }, (arguments) => {
			exact(arguments, { source: { type: 'string' } });
			return domain_operation('memory_reset_baseline', { source: source(arguments) });
		}),
		memory_settings: method(empty, (arguments) => {
			exact(arguments, {});
			return domain_read('memory_settings', {});
		}),
		diagnostics_summary: method(empty, (arguments) => {
			exact(arguments, {});
			return domain_read('diagnostics_summary', {});
		}),
		diagnostics_create_report: method(empty, (arguments) => {
			exact(arguments, {});
			return domain_read('diagnostics_create_report', {});
		}),
		diagnostics_route_test: method({ target: '', device: '', interface: '' }, (arguments) => {
			exact(arguments, { target: { type: 'string', required: true },
				device: { type: 'string' }, interface: { type: 'string' } });
			return domain_read('diagnostics_route_test', {
				target: safe_text(arguments.target, 512),
				device: arguments.device == null || !length(arguments.device) ? null :
					safe_text(arguments.device, 128),
				interface: arguments.interface == null || !length(arguments.interface) ? null :
					safe_text(arguments.interface, 128)
			});
		}),
		backup_list: method(empty, (arguments) => {
			exact(arguments, {});
			return domain_read('backup_list', {});
		}),
		backup_create: method({ options: {}, source: '' }, (arguments) => {
			exact(arguments, { options: { type: 'object', required: true },
				source: { type: 'string' } });
			return domain_operation('backup_create', {
				options: transfer_metadata(arguments.options), source: source(arguments) });
		}),
		backup_inspect: method({ backup_id: '', options: {} }, (arguments) => {
			exact(arguments, { backup_id: { type: 'string', required: true },
				options: { type: 'object' } });
			return domain_read('backup_inspect', { backup_id: safe_id(arguments.backup_id),
				options: transfer_metadata(arguments.options) });
		}),
		backup_restore: method({ inspection_id: '', source: '' }, (arguments) => {
			exact(arguments, { inspection_id: { type: 'string', required: true },
				source: { type: 'string' } });
			return domain_operation('backup_restore', {
				inspection_id: safe_id(arguments.inspection_id), source: source(arguments) });
		}),
		telegram_status: method(empty, (arguments) => {
			exact(arguments, {});
			return telegram_status_value(app);
		}),
		telegram_settings: method(empty, (arguments) => {
			exact(arguments, {});
			return telegram_settings_value(app);
		}),
		telegram_test: method(empty, (arguments) => {
			exact(arguments, {});
			return { sent: type(app.telegram_test) == 'function' &&
				app.telegram_test() === true };
		}),
		devices_list: method(empty, (arguments) => {
			exact(arguments, {});
			return domain_read('devices_list', {});
		}),
		devices_timezones: method(empty, (arguments) => {
			exact(arguments, {});
			return domain_read('devices_timezones', {});
		}),
		devices_policy_list: method(empty, (arguments) => {
			exact(arguments, {});
			return domain_read('devices_policy_list', {});
		}),
		devices_policy_set: method({ policy: {}, source: '' }, (arguments) => {
			exact(arguments, { policy: { type: 'object', required: true },
				source: { type: 'string' } });
			return domain_operation('devices_policy_set', {
				policy: transfer_metadata(arguments.policy), source: source(arguments) });
		}),
		devices_policy_delete: method({ policy_id: '', expected_revision: 0, source: '' }, (arguments) => {
			exact(arguments, { policy_id: { type: 'string', required: true },
				expected_revision: { type: 'int', required: true }, source: { type: 'string' } });
			if (!match(arguments.policy_id, /^dp_[0-9]+_[0-9a-f]{16}$/) ||
			    arguments.expected_revision < 1 || arguments.expected_revision > 2147483647)
				errors.fail('INVALID_ARGUMENT');
			return domain_operation('devices_policy_delete', {
				policy_id: arguments.policy_id, expected_revision: arguments.expected_revision,
				source: source(arguments) });
		}),
		notifications_settings: method(empty, (arguments) => {
			exact(arguments, {});
			return domain_read('notifications_settings', {});
		}),
		notifications_test: method({ channel: '' }, (arguments) => {
			exact(arguments, { channel: { type: 'string', required: true } });
			return domain_read('notifications_test', { channel: safe_id(arguments.channel) });
		}),
		notifications_list: method({ generation: '', cursor: 0, limit: 0 }, (arguments) => {
			exact(arguments, {
				generation: { type: 'string', nullable: true },
				cursor: { type: 'int' }, limit: { type: 'int' }
			});
			let generation = arguments.generation;
			if (generation != null && !match(generation, /^ng_[0-9a-f]{32}$/))
				errors.fail('INVALID_ARGUMENT');
			let cursor = arguments.cursor ?? 0, limit = arguments.limit ?? 32;
			if (cursor < 0 || limit < 1 || limit > 200)
				errors.fail('INVALID_ARGUMENT');
			return domain_read('notifications_list', { generation, cursor, limit });
		}),
		logs_read: method({ generation: '', cursor: 0, limit: 0 }, (arguments) => {
			exact(arguments, { generation: { type: 'string', nullable: true },
				cursor: { type: 'int' }, limit: { type: 'int' } });
			let generation = arguments.generation;
			if (generation != null && !match(generation, /^log_[0-9a-f]{16}$/))
				errors.fail('INVALID_ARGUMENT');
			let cursor = arguments.cursor ?? 0, limit = arguments.limit ?? 100;
			if (cursor < 0 || limit < 1 || limit > 200)
				errors.fail('INVALID_ARGUMENT');
			let reply = domain_read('logs_read', { generation, cursor, limit });
			if (type(reply?.lines) != 'array') errors.fail('INVALID_RESPONSE');
			let safe_lines = [];
			for (let line in reply.lines) {
				if (type(line) != 'string' || length(line) > 4096) errors.fail('INVALID_RESPONSE');
				push(safe_lines, redact.sanitize(line));
			}
			reply.lines = safe_lines;
			return reply;
		}),
		system_info: method(empty, (arguments) => {
			exact(arguments, {});
			return domain_read('system_info', {});
		}),
		network_interfaces: method(empty, (arguments) => {
			exact(arguments, {});
			return domain_read('network_interfaces', {});
		}),
		ruleset_list: method(empty, (arguments) => {
			exact(arguments, {});
			return domain_read('ruleset_list', {});
		}),
		ruleset_read: method({ name: '' }, (arguments) => {
			exact(arguments, { name: { type: 'string', required: true } });
			return domain_read('ruleset_read', { name: safe_ruleset_name(arguments.name) });
		}),
		ruleset_write: method({ name: '', content: '', source: '' }, (arguments) => {
			exact(arguments, { name: { type: 'string', required: true },
				content: { type: 'string', required: true }, source: { type: 'string' } });
			return domain_operation('ruleset_write', { name: safe_ruleset_name(arguments.name),
				content: ruleset_content(arguments.content), source: source(arguments) });
		}),
		ruleset_delete: method({ name: '', source: '' }, (arguments) => {
			exact(arguments, { name: { type: 'string', required: true }, source: { type: 'string' } });
			return domain_operation('ruleset_delete', { name: safe_ruleset_name(arguments.name),
				source: source(arguments) });
		}),
		ruleset_apply_whitelist: method({ content: '', source: '' }, (arguments) => {
			exact(arguments, { content: { type: 'string', required: true }, source: { type: 'string' } });
			return domain_operation('ruleset_apply_whitelist', {
				content: ruleset_content(arguments.content), source: source(arguments) });
		}),
		transfer_begin: method({ direction: '', kind: '', object_id: '', size: 0,
			sha256: '', metadata: {} }, (arguments) => {
			exact(arguments, {
				direction: { type: 'string', required: true }, kind: { type: 'string', required: true },
				object_id: { type: 'string' }, size: { type: 'int', required: true },
				sha256: { type: 'string', required: true }, metadata: { type: 'object' }
			});
			return transfer('begin', arguments);
		}),
		transfer_write: method({ transfer_id: '', seq: 0, data: '' }, (arguments) => {
			exact(arguments, { transfer_id: { type: 'string', required: true },
				seq: { type: 'int', required: true }, data: { type: 'string', required: true } });
			return transfer('write', arguments);
		}),
		transfer_read: method({ transfer_id: '', seq: 0 }, (arguments) => {
			exact(arguments, { transfer_id: { type: 'string', required: true },
				seq: { type: 'int', required: true } });
			return transfer('read', arguments);
		}),
		transfer_finish: method({ transfer_id: '' }, (arguments) => {
			exact(arguments, { transfer_id: { type: 'string', required: true } });
			return transfer('finish', arguments);
		}),
		transfer_abort: method({ transfer_id: '' }, (arguments) => {
			exact(arguments, { transfer_id: { type: 'string', required: true } });
			return transfer('abort', arguments);
		})
	};
};

export function set_draining(app, draining) {
	if (type(app) != 'object' || type(draining) != 'bool')
		errors.fail('INVALID_ARGUMENT');
	return app.set_draining(draining);
};

export function register(connection, app, transfers) {
	if (type(connection?.publish) != 'function')
		errors.fail('INVALID_ARGUMENT');
	let object = connection.publish('miclash', method_table(app, transfers));
	if (object == null)
		errors.fail('INTERNAL');
	return object;
};
