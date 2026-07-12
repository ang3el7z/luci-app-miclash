import * as errors from 'miclash.errors';
import * as redact from 'miclash.redact';
import * as schema from 'miclash.schema';
import * as storage from 'miclash.storage';

const JOURNAL_LIMIT = 100;
const READ_ONLY_KINDS = {
	status: true,
	health: true,
	'operation.get': true,
	'operation.list': true,
	'config.list': true,
	'config.read': true,
	'history.list': true,
	'history.diff': true,
	'settings.get': true,
	'diagnostics.summary': true,
	'diagnostics.route_test': true,
	'backup.list': true,
	'devices.list': true,
	'devices.policy_list': true
};
const SOURCES = { luci: true, telegram: true, auto: true, system: true };
const STATES = {
	queued: true, running: true, success: true, failure: true, interrupted: true
};
const FILTERS = { state: true, kind: true, source: true };

let last_millis = -1;
let id_sequence = 0;

function invalid() {
	errors.fail('INVALID_ARGUMENT');
};

function clone(value) {
	try { return json(sprintf('%J', value)); }
	catch (error) { errors.fail('INTERNAL'); }
};

function safe_kind(value) {
	if (type(value) != 'string' || !length(value) || length(value) > 128 ||
	    !match(value, /^[A-Za-z0-9][A-Za-z0-9._-]*$/))
		invalid();
	return value;
};

function safe_source(value) {
	if (type(value) != 'string' || !exists(SOURCES, value))
		invalid();
	return value;
};

function safe_stage(value) {
	if (type(value) != 'string' || !length(value) || length(value) > 64 ||
	    !match(value, /^[A-Za-z0-9][A-Za-z0-9._-]*$/))
		invalid();
	return value;
};

function safe_message(value) {
	if (type(value) != 'string' || length(value) > 512 ||
	    match(value, /[[:cntrl:]]/))
		invalid();
	return redact.text(value);
};

function completed(record) {
	return record.state == 'success' || record.state == 'failure' ||
	       record.state == 'interrupted';
};

function compare_records(left, right) {
	if (left.id == right.id)
		return 0;
	return left.id < right.id ? -1 : 1;
};

function compare_completed(left, right) {
	if (left.finished_at != right.finished_at)
		return left.finished_at < right.finished_at ? -1 : 1;
	return compare_records(left, right);
};

function operation_id(runtime, records) {
	let now = runtime.clock.now();
	if (type(now) != 'int' || now < 0)
		errors.fail('INTERNAL');
	if (now < last_millis)
		now = last_millis;
	if (now == last_millis)
		id_sequence++;
	else {
		last_millis = now;
		id_sequence = 1;
	}

	for (let attempt = 0; attempt < 16; attempt++) {
		let suffix = runtime.random.hex(8);
		if (type(suffix) != 'string' || !match(suffix, /^[0-9a-f]{16}$/))
			errors.fail('INTERNAL');
		let id = sprintf('%013d-%08d-%s', now, id_sequence, suffix);
		if (!exists(records, id))
			return id;
	}
	errors.fail('INTERNAL');
};

function observe_id(id) {
	let fields = split(id, '-');
	if (length(fields) != 3 || !match(fields[0], /^[0-9]+$/) ||
	    !match(fields[1], /^[0-9]+$/))
		return;
	let millis = +fields[0];
	let sequence = +fields[1];
	if (millis > last_millis) {
		last_millis = millis;
		id_sequence = sequence;
	}
	else if (millis == last_millis && sequence > id_sequence)
		id_sequence = sequence;
};

function ensure_directory(runtime, path) {
	let current = runtime.fs.lstat(path);
	if (current == null)
		runtime.fs.mkdir(path);
	if (runtime.fs.lstat(path)?.type != 'directory')
		errors.fail('INTERNAL');
};

export function create(runtime) {
	if (type(runtime?.fs) != 'object' || type(runtime?.clock?.now) != 'function' ||
	    type(runtime?.clock?.set_timeout) != 'function' ||
	    type(runtime?.digest) != 'object' || type(runtime?.random?.hex) != 'function' ||
	    runtime?.paths?.tmp != '/tmp/miclash')
		invalid();

	ensure_directory(runtime, runtime.paths.tmp);
	let journal = runtime.paths.tmp + '/operations';
	ensure_directory(runtime, journal);

	let records = {};
	let mutation_queue = [];
	let active_mutation = null;
	let mutation_timer_pending = false;
	let subscribers = [];
	let start;

	function path_for(id) {
		return journal + '/' + schema.operation_id(id) + '.json';
	};

	function persist(record) {
		let safe = redact.value('operation', record);
		storage.write_json(runtime, path_for(record.id), safe, 0o600);
		records[record.id] = safe;
		return safe;
	};

	function publish(record) {
		let event = clone(redact.value('operation', record));
		for (let callback in subscribers) {
			try { callback(clone(event)); }
			catch (error) {}
		}
	};

	function remove_record(record) {
		if (runtime.fs.unlink(path_for(record.id)) != true)
			errors.fail('INTERNAL');
		delete records[record.id];
	};

	function prune() {
		let finished = [];
		for (let id, record in records)
			if (completed(record))
				push(finished, record);
		sort(finished, compare_completed);
		while (length(finished) > JOURNAL_LIMIT)
			remove_record(shift(finished));
	};

	function public_record(record) {
		return record == null ? null : clone(redact.value('operation', record));
	};

	function schedule_mutation() {
		if (active_mutation != null || mutation_timer_pending || !length(mutation_queue))
			return;
		mutation_timer_pending = true;
		runtime.clock.set_timeout(0, () => {
			mutation_timer_pending = false;
			if (active_mutation == null && length(mutation_queue))
				start(shift(mutation_queue), true);
		});
	};

	function stable_error(error) {
		let normalized = errors.normalize(error);
		return errors.new(normalized.code,
			normalized.code == 'INTERNAL' ? 'Internal error' : normalized.code,
			normalized.detail);
	};

	function finish(entry, state, error) {
		if (entry.finished)
			return false;
		let record = clone(records[entry.id]);
		record.state = state;
		record.updated_at = runtime.clock.now();
		record.finished_at = record.updated_at;
		record.error = error == null ? null : stable_error(error);
		if (state == 'success' && record.progress < 100)
			record.progress = 100;
		persist(record);
		entry.finished = true;
		publish(records[entry.id]);
		prune();
		if (active_mutation == entry.id) {
			active_mutation = null;
			schedule_mutation();
		}
		return true;
	};

	start = (entry, mutation) => {
		let record = records[entry.id];
		if (record == null || record.state != 'queued')
			return;
		if (mutation)
			active_mutation = entry.id;
		let running = clone(record);
		running.state = 'running';
		running.updated_at = runtime.clock.now();
		try { persist(running); }
		catch (error) {
			entry.finished = true;
			let failed = clone(record);
			failed.state = 'failure';
			failed.error = errors.new('INTERNAL', 'Internal error', null);
			failed.updated_at = runtime.clock.now();
			failed.finished_at = failed.updated_at;
			records[entry.id] = redact.value('operation', failed);
			if (mutation && active_mutation == entry.id) {
				active_mutation = null;
				schedule_mutation();
			}
			return;
		}
		publish(records[entry.id]);

		let ctx = {
			id: entry.id,
			runtime,
			stage: (name, progress, message) => {
				let current = records[entry.id];
				if (entry.finished || current.state != 'running' || type(progress) != 'int' ||
				    progress < 0 || progress > 100 || progress < current.progress)
					invalid();
				let staged = clone(current);
				staged.stage = safe_stage(name);
				staged.progress = progress;
				staged.message = safe_message(message);
				staged.updated_at = runtime.clock.now();
				persist(staged);
				publish(records[entry.id]);
				return public_record(records[entry.id]);
			},
			complete: (error) => finish(entry, error == null ? 'success' : 'failure', error)
		};

		try {
			let result = entry.worker(ctx);
			// Returning exactly false is the callback/deferred contract. All other
			// synchronous returns complete immediately; ucode Promises are not used.
			if (result !== false && !entry.finished)
				finish(entry, 'success', null);
		}
		catch (error) {
			if (!entry.finished)
				finish(entry, 'failure', error);
		}
	};

	let manager = {};
	manager.submit = (kind, source, context, worker) => {
		kind = safe_kind(kind);
		source = safe_source(source);
		if (type(context) != 'object' || type(worker) != 'function')
			invalid();
		let id = operation_id(runtime, records);
		let now = runtime.clock.now();
		let record = {
			id,
			kind,
			source,
			state: 'queued',
			stage: 'queued',
			progress: 0,
			message: '',
			error: null,
			created_at: now,
			updated_at: now,
			finished_at: null
		};
		// Persist before making the operation runnable. A failed initial journal
		// write leaves no in-memory operation and never invokes the worker.
		persist(record);
		let entry = { id, worker, finished: false };
		publish(records[id]);
		if (exists(READ_ONLY_KINDS, kind))
			runtime.clock.set_timeout(0, () => start(entry, false));
		else {
			push(mutation_queue, entry);
			schedule_mutation();
		}
		return public_record(records[id]);
	};
	manager.get = (id) => {
		id = schema.operation_id(id);
		return public_record(records[id]);
	};
	manager.list = (filter) => {
		if (filter != null && type(filter) != 'object')
			invalid();
		for (let name in filter ?? {})
			if (!exists(FILTERS, name))
				invalid();
		if (filter?.state != null && !exists(STATES, filter.state))
			invalid();
		if (filter?.kind != null)
			safe_kind(filter.kind);
		if (filter?.source != null)
			safe_source(filter.source);

		let output = [];
		for (let id, record in records)
			if ((filter?.state == null || record.state == filter.state) &&
			    (filter?.kind == null || record.kind == filter.kind) &&
			    (filter?.source == null || record.source == filter.source))
				push(output, public_record(record));
		sort(output, compare_records);
		return output;
	};
	manager.subscribe = (callback) => {
		if (type(callback) != 'function')
			invalid();
		push(subscribers, callback);
		let active = true;
		return () => {
			if (!active)
				return false;
			active = false;
			let remaining = [];
			for (let item in subscribers)
				if (item != callback)
					push(remaining, item);
			subscribers = remaining;
			return true;
		};
	};
	manager.recover_interrupted = () => {
		let recovered = 0;
		let names = runtime.fs.lsdir(journal) ?? [];
		sort(names);
		for (let name in names) {
			if (!match(name, /^[A-Za-z0-9][A-Za-z0-9._-]*\.json$/))
				continue;
			let record = storage.read_json(runtime, journal + '/' + name);
			if (type(record) != 'object' || type(record.id) != 'string' ||
			    name != record.id + '.json')
				errors.fail('CORRUPT_STATE');
			schema.operation_id(record.id);
			observe_id(record.id);
			safe_kind(record.kind);
			safe_source(record.source);
			if (!exists(STATES, record.state))
				errors.fail('CORRUPT_STATE');
			records[record.id] = redact.value('operation', record);
			if (record.state == 'running' || record.state == 'queued') {
				record.state = 'interrupted';
				record.stage = 'interrupted';
				record.message = 'Interrupted by daemon restart';
				record.error = errors.new('INTERRUPTED', 'INTERRUPTED', null);
				record.updated_at = runtime.clock.now();
				record.finished_at = record.updated_at;
				persist(record);
				publish(records[record.id]);
				recovered++;
			}
		}
		prune();
		return recovered;
	};

	return manager;
};
