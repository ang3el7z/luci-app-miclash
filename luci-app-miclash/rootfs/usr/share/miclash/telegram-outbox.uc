import * as errors from 'miclash.errors';
import * as redact from 'miclash.redact';
import * as storage from 'miclash.storage';

const STATE_PATH = '/etc/miclash/telegram-outbox.json';
const CAPACITY = 64;
const RETRY_DELAYS = [ 15000, 30000, 60000, 120000, 300000, 900000, 1800000, 3600000 ];

function invalid() { errors.fail('INVALID_ARGUMENT'); };
function clone(value) {
	try { return value == null ? null : json(sprintf('%J', value)); }
	catch (error) { invalid(); }
};
function same_file(left, right) {
	return left?.type == 'file' && right?.type == 'file' && left.inode == right.inode &&
		left.dev?.major == right.dev?.major && left.dev?.minor == right.dev?.minor &&
		left.nlink == right.nlink && left.size == right.size && left.mode == right.mode &&
		left.uid == right.uid;
};
function authority(runtime) {
	let value = runtime.fs.lstat(runtime.paths.etc);
	if (runtime.paths.etc != '/etc/miclash' || value?.type != 'directory' ||
	    value.mode != 0o700 || (value.uid != null && value.uid != 0) ||
	    runtime.fs.realpath(runtime.paths.etc) != runtime.paths.etc)
		invalid();
	return value;
};
function state_file(runtime) {
	let value = runtime.fs.lstat(STATE_PATH);
	if (value == null) return null;
	if (value.type != 'file' || value.mode != 0o600 || value.nlink != 1 ||
	    (value.uid != null && value.uid != 0) || runtime.fs.realpath(STATE_PATH) != STATE_PATH)
		errors.fail('CORRUPT_STATE');
	return value;
};
function normalized_id(value) {
	let text = type(value) == 'int' ? sprintf('%d', value) : value;
	if (type(text) != 'string' || !match(text, /^[1-9][0-9]{0,19}$/)) invalid();
	return text;
};
function valid_panel(value) {
	if (value == null) return null;
	if (type(value) != 'object' || type(value) == 'array' || length(keys(value)) != 3 ||
	    type(value.message_id) != 'int' || value.message_id < 1 ||
	    type(value.generation) != 'int' || value.generation < 0 || value.generation > 999999999)
		invalid();
	return { chat_id: normalized_id(value.chat_id), message_id: value.message_id,
		generation: value.generation };
};
function safe_payload(value) {
	if (type(value) != 'object' || type(value) == 'array') invalid();
	let safe;
	try { safe = redact.sanitize(value); }
	catch (error) {
		let code = error?.code ?? error?.message;
		errors.fail(code == 'RESPONSE_TOO_LARGE' ? code : 'INVALID_ARGUMENT');
	}
	if (length(sprintf('%J', safe)) > 8192) errors.fail('RESPONSE_TOO_LARGE');
	return safe;
};
function valid_receipt(value, persisted) {
	if (type(value) != 'object' || type(value) == 'array' ||
	    type(value.id) != 'string' || !match(value.id, /^[A-Za-z0-9][A-Za-z0-9._:-]{0,95}$/) ||
	    (value.audience != 'user' && value.audience != 'automatic') ||
	    type(value.kind) != 'string' || !match(value.kind, /^[a-z0-9][a-z0-9_.-]{0,63}$/) ||
	    (value.locale != 'en' && value.locale != 'ru' && value.locale != 'zh-cn') ||
	    type(value.state) != 'string' || !match(value.state, /^[a-z0-9][a-z0-9_.-]{0,31}$/) ||
	    type(value.created_at) != 'int' || value.created_at < 0)
		invalid();
	let message = value.message_id;
	if (message != null && (type(message) != 'int' || message < 1)) invalid();
	let operation = value.operation_id;
	if (operation != null && (type(operation) != 'string' ||
	    !match(operation, /^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/))) invalid();
	if (value.audience == 'user' && operation == null) invalid();
	let result = {
		id: value.id, audience: value.audience, kind: value.kind, locale: value.locale,
		chat_id: normalized_id(value.chat_id), message_id: message,
		operation_id: operation, state: value.state, created_at: value.created_at,
		next_attempt_at: persisted ? value.next_attempt_at : null,
		attempts: persisted ? value.attempts : 0,
		payload: persisted ? clone(value.payload) : safe_payload(value.payload)
	};
	if (persisted) {
		if (type(result.next_attempt_at) != 'int' || result.next_attempt_at < 0 ||
		    type(result.attempts) != 'int' || result.attempts < 0 || result.attempts > 1000000)
			errors.fail('CORRUPT_STATE');
		try { result.payload = safe_payload(result.payload); }
		catch (error) { errors.fail('CORRUPT_STATE'); }
	}
	return result;
};
function initial_state() { return { schema_version: 1, panel: null, entries: [] }; };
function validate_state(value) {
	if (type(value) != 'object' || type(value) == 'array' || length(keys(value)) != 3 ||
	    value.schema_version != 1 || type(value.entries) != 'array' ||
	    length(value.entries) > CAPACITY)
		errors.fail('CORRUPT_STATE');
	let result = initial_state(), ids = {};
	try { result.panel = valid_panel(value.panel); }
	catch (error) { errors.fail('CORRUPT_STATE'); }
	for (let entry in value.entries) {
		let checked;
		try { checked = valid_receipt(entry, true); }
		catch (error) { errors.fail('CORRUPT_STATE'); }
		if (ids[checked.id] === true) errors.fail('CORRUPT_STATE');
		ids[checked.id] = true;
		push(result.entries, checked);
	}
	return result;
};
function read_state(runtime) {
	let root = authority(runtime), before = state_file(runtime);
	if (before == null) return initial_state();
	let source = runtime.fs.readfile(STATE_PATH), after = state_file(runtime), current = authority(runtime);
	if (type(source) != 'string' || length(source) > 1048576 || !same_file(before, after) ||
	    root.inode != current.inode || root.dev?.major != current.dev?.major ||
	    root.dev?.minor != current.dev?.minor)
		errors.fail('CORRUPT_STATE');
	let decoded;
	try { decoded = json(source); }
	catch (error) { errors.fail('CORRUPT_STATE'); }
	return validate_state(decoded);
};
function persist(runtime, value) {
	authority(runtime);
	storage.write_json(runtime, STATE_PATH, value, 0o600);
	state_file(runtime);
	return true;
};

export function create(runtime, deliver) {
	if (type(runtime) != 'object' || type(runtime.fs) != 'object' ||
	    type(runtime.digest) != 'object' || type(runtime.clock?.now) != 'function' ||
	    runtime.paths?.etc != '/etc/miclash' || type(deliver) != 'function') invalid();
	let state = read_state(runtime), closed = false;
	function active() { if (closed) errors.fail('INTERRUPTED'); };
	function commit(candidate) { persist(runtime, candidate); state = candidate; return true; };
	function evict_automatic(candidate) {
		for (let index = 0; index < length(candidate.entries); index++)
			if (candidate.entries[index].audience == 'automatic') {
				splice(candidate.entries, index, 1);
				return true;
			}
		return false;
	};
	function add(value) {
		active();
		let checked = valid_receipt(value, false);
		for (let entry in state.entries)
			if (entry.id == checked.id) {
				let comparable = { ...checked, next_attempt_at: entry.next_attempt_at };
				if (sprintf('%J', comparable) != sprintf('%J', entry)) invalid();
				return false;
			}
		let candidate = clone(state);
		if (length(candidate.entries) >= CAPACITY && !evict_automatic(candidate))
			errors.fail('RESOURCE_EXHAUSTED');
		checked.next_attempt_at = runtime.clock.now();
		push(candidate.entries, checked);
		return commit(candidate);
	};
	return {
		enqueue: add,
		panel: (identity) => {
			active();
			if (identity == null) return clone(state.panel);
			let candidate = clone(state);
			candidate.panel = identity === false ? null : valid_panel(identity);
			return commit(candidate);
		},
		pending: () => { active(); return clone(state.entries); },
		attempt: () => {
			active();
			let index = -1, now = runtime.clock.now();
			for (let offset = 0; offset < length(state.entries); offset++)
				if (state.entries[offset].next_attempt_at <= now) { index = offset; break; }
			if (index < 0) return false;
			let entry = clone(state.entries[index]), outcome = false;
			try { outcome = deliver(entry, clone(state.panel)); }
			catch (error) { outcome = false; }
			let delivered = outcome === true || outcome?.delivered === true;
			let candidate = clone(state);
			if (delivered) {
				if (outcome?.panel != null) candidate.panel = valid_panel(outcome.panel);
				splice(candidate.entries, index, 1);
				commit(candidate);
				return true;
			}
			candidate.entries[index].attempts++;
			let attempt = candidate.entries[index].attempts;
			let delay = RETRY_DELAYS[min(attempt - 1, length(RETRY_DELAYS) - 1)];
			candidate.entries[index].next_attempt_at = now + delay;
			commit(candidate);
			return false;
		},
		coalesce: (value) => {
			active();
			let checked = valid_receipt(value, false);
			if (checked.audience != 'automatic') invalid();
			let candidate = clone(state);
			for (let index = 0; index < length(candidate.entries); index++) {
				let entry = candidate.entries[index];
				if (entry.audience != 'automatic' || entry.kind != checked.kind ||
				    entry.state != checked.state || entry.chat_id != checked.chat_id) continue;
				entry.payload = checked.payload;
				entry.payload.count = (state.entries[index].payload?.count ?? 1) + 1;
				entry.next_attempt_at = min(entry.next_attempt_at, runtime.clock.now());
				commit(candidate);
				return false;
			}
			return add(checked);
		},
		close: () => { if (closed) return false; closed = true; return true; }
	};
};
