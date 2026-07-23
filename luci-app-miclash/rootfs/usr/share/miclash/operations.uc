import * as errors from 'miclash.errors';
import * as redact from 'miclash.redact';
import * as schema from 'miclash.schema';
import * as storage from 'miclash.storage';

const JOURNAL_LIMIT = 100;
const SOURCES = { luci: true, telegram: true, auto: true, system: true };
const STATES = {
	queued: true, running: true, success: true, failure: true, interrupted: true
};
const FILTERS = { state: true, kind: true, source: true };
const RECORD_FIELDS = {
	id: true, kind: true, source: true, state: true, stage: true, progress: true,
	message: true, error: true, created_at: true, updated_at: true, finished_at: true,
	timeline: true, result: true
};
const LEGACY_RECORD_FIELDS = {
	id: true, kind: true, source: true, state: true, stage: true, progress: true,
	message: true, error: true, created_at: true, updated_at: true, finished_at: true
};
const ERROR_FIELDS = { code: true, message: true, detail: true };
const TIMELINE_FIELDS = { stage: true, at: true };
const RESULT_FIELDS = { interval_hours: true, insecure: true };
const LEGACY_RESULT_FIELDS = { interval_hours: true };
const ERROR_CODES = {};
for (let code in errors.CODES)
	ERROR_CODES[code] = true;

let last_millis = -1;
let id_sequence = 0;

function invalid() {
	errors.fail('INVALID_ARGUMENT');
};

function corrupt() {
	errors.fail('CORRUPT_STATE');
};

function clone(value) {
	try { return json(sprintf('%J', value)); }
	catch (error) { errors.fail('INTERNAL'); }
};

function unsafe_text(value) {
	return index(value, sprintf('%c', 0)) >= 0 || match(value, /[[:cntrl:]]/);
};

function safe_kind(value) {
	if (type(value) != 'string' || !length(value) || length(value) > 128 ||
	    unsafe_text(value) || !match(value, /^[A-Za-z0-9][A-Za-z0-9._-]*$/))
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
	    unsafe_text(value) || !match(value, /^[A-Za-z0-9][A-Za-z0-9._-]*$/))
		invalid();
	return value;
};

function safe_message(value) {
	if (type(value) != 'string' || length(value) > 512 ||
	    unsafe_text(value))
		invalid();
	return redact.text(value);
};

function completed(record) {
	return record.state == 'success' || record.state == 'failure' ||
	       record.state == 'interrupted';
};

function exact_fields(value, allowed, required_count) {
	if (type(value) != 'object')
		return false;
	let count = 0;
	for (let name in value) {
		if (!exists(allowed, name))
			return false;
		count++;
	}
	return count == required_count;
};

function valid_disk_record(record, filename) {
	let legacy = exact_fields(record, LEGACY_RECORD_FIELDS, 11);
	if ((!legacy && !exact_fields(record, RECORD_FIELDS, 13)) ||
	    type(record.id) != 'string' ||
	    !match(record.id, /^[0-9]{13}-[0-9]{8}-[0-9a-f]{16}$/) ||
	    filename != record.id + '.json' ||
	    type(record.kind) != 'string' || !length(record.kind) || length(record.kind) > 128 ||
	    unsafe_text(record.kind) || !match(record.kind, /^[A-Za-z0-9][A-Za-z0-9._-]*$/) ||
	    type(record.source) != 'string' || !exists(SOURCES, record.source) ||
	    type(record.state) != 'string' || !exists(STATES, record.state) ||
	    type(record.stage) != 'string' || !length(record.stage) || length(record.stage) > 64 ||
	    unsafe_text(record.stage) || !match(record.stage, /^[A-Za-z0-9][A-Za-z0-9._-]*$/) ||
	    type(record.progress) != 'int' || record.progress < 0 || record.progress > 100 ||
	    type(record.message) != 'string' || length(record.message) > 512 ||
	    unsafe_text(record.message) ||
	    type(record.created_at) != 'int' || record.created_at < 0 ||
	    type(record.updated_at) != 'int' || record.updated_at < record.created_at)
		return false;
	if (!legacy) {
		if (type(record.timeline) != 'array' || length(record.timeline) < 1 ||
		    length(record.timeline) > 32 || record.result != null &&
		    (record.kind != 'subscription.update' ||
		     (!exact_fields(record.result, RESULT_FIELDS, 2) &&
		      !exact_fields(record.result, LEGACY_RESULT_FIELDS, 1)) ||
		     (record.result.interval_hours != null &&
		      (type(record.result.interval_hours) != 'int' ||
		       record.result.interval_hours < 1 || record.result.interval_hours > 8760)) ||
		     (record.result.insecure != null && type(record.result.insecure) != 'bool')))
			return false;
		let previous = record.created_at;
		for (let index, item in record.timeline) {
			if (!exact_fields(item, TIMELINE_FIELDS, 2) ||
			    type(item.stage) != 'string' || !length(item.stage) ||
			    length(item.stage) > 64 || unsafe_text(item.stage) ||
			    !match(item.stage, /^[A-Za-z0-9][A-Za-z0-9._-]*$/) ||
			    type(item.at) != 'int' || item.at < previous || item.at > record.updated_at ||
			    (index == 0 && (item.stage != 'queued' || item.at != record.created_at)))
				return false;
			previous = item.at;
		}
		if (record.timeline[length(record.timeline) - 1].stage != record.stage ||
		    (record.state == 'success' && record.kind == 'subscription.update' &&
		     record.result == null))
			return false;
	}

	let error_valid = record.error == null;
	if (record.error != null) {
		let fields = 0;
		if (type(record.error) == 'object')
			for (let name in record.error)
				fields++;
		error_valid = (fields == 2 || fields == 3) &&
			exact_fields(record.error, ERROR_FIELDS, fields) &&
			type(record.error.code) == 'string' && exists(ERROR_CODES, record.error.code) &&
			type(record.error.message) == 'string' && length(record.error.message) > 0 &&
			length(record.error.message) <= 512 && !unsafe_text(record.error.message) &&
			record.error.message == (record.error.code == 'INTERNAL' ?
				'Internal error' : record.error.code) &&
			(fields == 2 || exists(record.error, 'detail'));
	}
	if (!error_valid)
		return false;
	if (sprintf('%J', redact.value('operation', record)) != sprintf('%J', record))
		return false;

	if (record.state == 'queued')
		return record.stage == 'queued' && record.progress == 0 && record.message == '' &&
		       record.error == null && record.finished_at == null &&
		       record.updated_at == record.created_at;
	if (record.state == 'running')
		return record.error == null && record.finished_at == null;
	if (type(record.finished_at) != 'int' || record.finished_at != record.updated_at)
		return false;
	if (record.state == 'success')
		return record.progress == 100 && record.error == null;
	if (record.state == 'interrupted')
		return record.stage == 'interrupted' && record.error?.code == 'INTERRUPTED';
	return record.state == 'failure' && record.error != null;
};

function owned_journal_temp(name) {
	return match(name,
		/^\.[0-9]{13}-[0-9]{8}-[0-9a-f]{16}\.json\.miclash\.[0-9]+-[0-9]+\.[0-9A-Fa-f]{8}$/);
};

function same_node(left, right) {
	return left?.type != null && left.type == right?.type && left.inode == right?.inode &&
	       left.dev?.major == right.dev?.major && left.dev?.minor == right.dev?.minor;
};

function same_temp(left, right) {
	return left?.type == 'file' && right?.type == 'file' &&
	       left.nlink == 1 && right.nlink == 1 && left.size == right.size &&
	       same_node(left, right);
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
	if (current == null && runtime.fs.mkdir(path) != true)
		errors.fail('INTERNAL');
	current = runtime.fs.lstat(path);
	if (current?.type != 'directory' || runtime.fs.realpath(path) != path ||
	    (current.uid != null && current.uid != 0) ||
	    runtime.fs.chmod(path, 0o700) != true)
		errors.fail('INTERNAL');
	let secured = runtime.fs.lstat(path);
	if (!same_node(current, secured) || secured?.type != 'directory' ||
	    runtime.fs.realpath(path) != path || secured.mode != 0o700 ||
	    (secured.uid != null && secured.uid != 0))
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
	let live_contexts = {};
	let mutation_queue = [];
	let observation_queue = [];
	let active_mutation = null;
	let active_observation = null;
	let mutation_timer_pending = false;
	let observation_timer_pending = false;
	let scheduler_frozen = false;
	let live_started = false;
	let recovery_done = false;
	let subscribers = [];
	let subscription_sequence = 0;
	let start;

	function operational_log(level, message) {
		try {
			let write = runtime.logger?.[level];
			if (type(write) == 'function') write('operations: ' + message);
		}
		catch (error) {}
	};

	function terminal_log(record) {
		let message = sprintf('completed kind=%s source=%s state=%s',
			record.kind, record.source, record.state);
		if (record.error?.code != null)
			message += ' code=' + record.error.code;
		operational_log(record.state == 'success' ? 'info' : 'error', message);
	};

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
		for (let subscription in subscribers) {
			try { subscription.callback(clone(event)); }
			catch (error) {}
		}
	};

	function remove_record(record) {
		let removed;
		try { removed = runtime.fs.unlink(path_for(record.id)); }
		catch (error) { return false; }
		if (removed != true)
			return false;
		delete records[record.id];
		return true;
	};

	function prune() {
		let finished = [];
		for (let id, record in records)
			if (completed(record))
				push(finished, record);
		sort(finished, compare_completed);
		while (length(finished) > JOURNAL_LIMIT)
			if (!remove_record(finished[0]))
				return false;
			else
				shift(finished);
		return true;
	};

	function public_record(record) {
		return record == null ? null : clone(redact.value('operation', record));
	};

	function schedule_mutation() {
		if (scheduler_frozen || active_mutation != null || mutation_timer_pending ||
		    !length(mutation_queue))
			return;
		mutation_timer_pending = true;
		runtime.clock.set_timeout(0, () => {
			mutation_timer_pending = false;
			if (active_mutation == null && length(mutation_queue))
				start(shift(mutation_queue), true);
		});
	};
	function schedule_observation() {
		if (scheduler_frozen || active_observation != null || observation_timer_pending ||
		    !length(observation_queue))
			return;
		observation_timer_pending = true;
		runtime.clock.set_timeout(0, () => {
			observation_timer_pending = false;
			if (active_observation == null && length(observation_queue))
				start(shift(observation_queue), false);
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
		// Revoke the daemon-issued capability before any fallible terminal write.
		// A failed finish remains fail-closed and cannot replay its old context.
		delete live_contexts[entry.id];
		let record = clone(records[entry.id]);
		if (state == 'success' && record.kind == 'subscription.update' &&
		    record.result == null) {
			state = 'failure';
			error = errors.new('INTERNAL', 'Internal error');
		}
		record.state = state;
		record.updated_at = runtime.clock.now();
		record.finished_at = record.updated_at;
		record.error = error == null ? null : stable_error(error);
		if (state == 'success' && record.progress < 100)
			record.progress = 100;
		persist(record);
		entry.finished = true;
		terminal_log(record);
		publish(records[entry.id]);
		if (active_mutation == entry.id) {
			active_mutation = null;
			schedule_mutation();
		}
		if (active_observation == entry.id) {
			active_observation = null;
			schedule_observation();
		}
		try { prune(); } catch (prune_error) {}
		return true;
	};

	start = (entry, mutation) => {
		let record = records[entry.id];
		if (record == null || record.state != 'queued')
			return;
		if (mutation)
			active_mutation = entry.id;
		else
			active_observation = entry.id;
		let running = clone(record);
		running.state = 'running';
		running.updated_at = runtime.clock.now();
		try { persist(running); }
		catch (error) {
			scheduler_frozen = true;
			return;
		}
		operational_log('info', sprintf('started kind=%s source=%s',
			running.kind, running.source));
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
				if (length(staged.timeline) >= 32)
					invalid();
				push(staged.timeline, { stage: staged.stage, at: staged.updated_at });
				persist(staged);
				publish(records[entry.id]);
				return public_record(records[entry.id]);
			},
			result: (value) => {
				let current = records[entry.id];
				if (entry.finished || current.state != 'running' ||
				    current.kind != 'subscription.update' || current.result != null ||
				    (!exact_fields(value, RESULT_FIELDS, 2) &&
				     !exact_fields(value, LEGACY_RESULT_FIELDS, 1)) ||
				    (value.interval_hours != null &&
				     (type(value.interval_hours) != 'int' ||
				      value.interval_hours < 1 || value.interval_hours > 8760)) ||
				    (value.insecure != null && type(value.insecure) != 'bool'))
					invalid();
				let staged = clone(current);
				staged.result = { interval_hours: value.interval_hours };
				if (value.insecure != null) staged.result.insecure = value.insecure;
				staged.updated_at = runtime.clock.now();
				persist(staged);
				return clone(staged.result);
			},
			complete: (error) => finish(entry, error == null ? 'success' : 'failure', error)
		};
		live_contexts[entry.id] = ctx;

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
	manager.is_context = (ctx) => {
		if (type(ctx) != 'object' || type(ctx?.id) != 'string' ||
		    !match(ctx.id, /^[0-9]{13}-[0-9]{8}-[0-9a-f]{16}$/))
			return false;
		return live_contexts[ctx.id] === ctx && records[ctx.id]?.state == 'running';
	};
	function submit(kind, source, context, worker, observation, pre_enqueue) {
		kind = safe_kind(kind);
		source = safe_source(source);
		if (type(context) != 'object' || type(worker) != 'function' ||
		    (pre_enqueue != null && type(pre_enqueue) != 'function'))
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
			finished_at: null,
			timeline: [ { stage: 'queued', at: now } ],
			result: null
		};
		// Persist before making the operation runnable. A failed initial journal
		// write leaves no in-memory operation and never invokes the worker.
		persist(record);
		live_started = true;
		let entry = { id, worker, finished: false };
		publish(records[id]);
		if (pre_enqueue != null) {
			try { pre_enqueue(public_record(records[id])); }
			catch (error) {
				finish(entry, 'failure', error);
				return public_record(records[id]);
			}
		}
		if (observation) {
			push(observation_queue, entry);
			schedule_observation();
		}
		else {
			push(mutation_queue, entry);
			schedule_mutation();
		}
		return public_record(records[id]);
	};
	manager.submit = (kind, source, context, worker, pre_enqueue) =>
		submit(kind, source, context, worker, false, pre_enqueue);
	manager.submit_observation = (kind, source, context, worker) =>
		submit(kind, source, context, worker, true, null);
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
		let id = ++subscription_sequence;
		push(subscribers, { id, callback });
		let active = true;
		return () => {
			if (!active)
				return false;
			active = false;
			let remaining = [];
			for (let item in subscribers)
				if (item.id != id)
					push(remaining, item);
			subscribers = remaining;
			return true;
		};
	};
	manager.recover_interrupted = () => {
		if (live_started)
			errors.fail('BUSY');
		if (recovery_done)
			return 0;
		let recovered = 0;
		let names = runtime.fs.lsdir(journal);
		if (type(names) != 'array')
			errors.fail('INTERNAL');
		sort(names);
		let staged = [];
		let stale_temps = [];
		for (let name in names) {
			if (owned_journal_temp(name)) {
				let path = journal + '/' + name;
				let identity = runtime.fs.lstat(path);
				if (identity?.type != 'file' || identity.nlink != 1 ||
				    runtime.fs.realpath(path) != path ||
				    (identity.uid != null && identity.uid != 0))
					corrupt();
				push(stale_temps, { path, identity });
				continue;
			}
			if (!match(name, /^[A-Za-z0-9][A-Za-z0-9._-]*\.json$/))
				corrupt();
			let record = storage.read_json(runtime, journal + '/' + name);
			if (!valid_disk_record(record, name))
				corrupt();
			if (record.timeline == null) {
				record.timeline = [
					{ stage: 'queued', at: record.created_at },
					...(record.stage == 'queued' ? [] :
						[ { stage: record.stage, at: record.updated_at } ])
				];
				record.result = null;
			}
			let prepared = clone(redact.value('operation', record));
			if (record.state == 'running' || record.state == 'queued') {
				let finished = runtime.clock.now();
				if (finished < prepared.updated_at)
					finished = prepared.updated_at;
				prepared.state = 'interrupted';
				prepared.stage = 'interrupted';
				prepared.message = 'Interrupted by daemon restart';
				prepared.error = errors.new('INTERRUPTED', 'INTERRUPTED', null);
				prepared.updated_at = finished;
				prepared.finished_at = finished;
				push(prepared.timeline, { stage: 'interrupted', at: finished });
				recovered++;
			}
			push(staged, { record: prepared, changed: record.state == 'running' || record.state == 'queued' });
		}
		// Finish all validation before changing either disk or manager state.
		for (let temp in stale_temps) {
			let current = runtime.fs.lstat(temp.path);
			if (!same_temp(temp.identity, current) || runtime.fs.realpath(temp.path) != temp.path)
				errors.fail('INTERNAL');
			if (runtime.fs.unlink(temp.path) != true)
				errors.fail('INTERNAL');
		}
		for (let item in staged)
			if (item.changed)
				storage.write_json(runtime, path_for(item.record.id), item.record, 0o600);
		for (let item in staged)
			records[item.record.id] = item.record;
		for (let item in staged)
			observe_id(item.record.id);
		for (let item in staged)
			if (item.changed)
				publish(item.record);
		recovery_done = true;
		try { prune(); } catch (prune_error) {}
		return recovered;
	};

	return manager;
};
