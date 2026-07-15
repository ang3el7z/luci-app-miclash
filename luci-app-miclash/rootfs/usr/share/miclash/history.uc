import * as errors from 'miclash.errors';
import * as redact from 'miclash.redact';
import * as schema from 'miclash.schema';
import * as storage from 'miclash.storage';

const DEFAULT_RETENTION = 10;
const MAX_CONTENT_BYTES = 1048576;
const MAX_METADATA_BYTES = 65536;
const SOURCE_MAP = {
	manual: 'manual', luci: 'luci', subscription: 'subscription', auto: 'auto',
	Telegram: 'telegram', telegram: 'telegram', system: 'system', external: 'external',
	restore: 'restore', 'restore-before': 'restore-before'
};
const RECORD_FIELDS = {
	revision: true, filename: true, profile: true, source: true, timestamp: true,
	hash: true, size: true, validation_result: true, activation_result: true,
	mihomo_version: true, operation_id: true, parent_revision: true,
	restored_revision: true, content_revision: true, duplicate_of: true
};
const LEGACY_FIELDS = {
	revision: true, filename: true, profile: true, source: true, timestamp: true,
	hash: true, validation_result: true, activation_result: true,
	mihomo_version: true, operation_id: true, parent_revision: true,
	restored_revision: true, attempt_result: true
};

function same_node(left, right) {
	return left?.type != null && left.type == right?.type && left.inode == right?.inode &&
	       left.dev?.major == right.dev?.major && left.dev?.minor == right.dev?.minor;
};

function owned_file(stat, mode) {
	return stat?.type == 'file' && stat.nlink == 1 &&
	       (stat.uid == null || stat.uid == 0) &&
	       (stat.mode == null || (stat.mode & 0o777) == mode);
};

function ensure_directory(runtime, path, mode) {
	let before = runtime.fs.lstat(path);
	if (before == null && runtime.fs.mkdir(path) != true)
		errors.fail('INTERNAL');
	before = runtime.fs.lstat(path);
	if (before?.type != 'directory' || runtime.fs.realpath(path) != path ||
	    (before.uid != null && before.uid != 0) || runtime.fs.chmod(path, mode) != true)
		errors.fail('INTERNAL');
	let after = runtime.fs.lstat(path);
	if (!same_node(before, after) || after?.type != 'directory' ||
	    runtime.fs.realpath(path) != path ||
	    (after.uid != null && after.uid != 0) ||
	    (after.mode != null && (after.mode & 0o777) != mode))
		errors.fail('INTERNAL');
};

function revision_id(value) {
	if (type(value) != 'string' || length(value) > 64 ||
	    !match(value, /^([0-9]{13}-[0-9a-f]{16}|[0-9]{13}-[0-9a-f]{12}-[0-9a-f]{16})$/))
		errors.fail('INVALID_ARGUMENT');
	return value;
};

function normalized_source(value) {
	if (type(value) != 'string' || !exists(SOURCE_MAP, value))
		errors.fail('INVALID_ARGUMENT');
	return SOURCE_MAP[value];
};

function compare_revision(left, right) {
	if (left.revision == right.revision)
		return 0;
	return left.revision < right.revision ? -1 : 1;
};

function exact_fields(value, allowed) {
	if (type(value) != 'object')
		return false;
	let count = 0;
	for (let name in value) {
		if (!exists(allowed, name))
			return false;
		count++;
	}
	return count == 15;
};

function safe_optional(value, maximum) {
	return value == null || type(value) == 'string' && length(value) <= maximum &&
	       !match(value, /[[:cntrl:]]/);
};

function valid_record(record, profile, revision) {
	if (!exact_fields(record, RECORD_FIELDS) || record.revision != revision ||
	    record.profile != profile ||
	    (record.filename != 'config.yaml' &&
	     record.filename != record.content_revision + '.yaml') ||
	    type(record.source) != 'string' || !exists(SOURCE_MAP, record.source) ||
	    SOURCE_MAP[record.source] != record.source || type(record.timestamp) != 'int' ||
	    record.timestamp < 0 || type(record.hash) != 'string' ||
	    !match(record.hash, /^[0-9a-f]{64}$/) || type(record.size) != 'int' ||
	    record.size < 0 || record.size > MAX_CONTENT_BYTES ||
	    !safe_optional(record.validation_result, 64) ||
	    !safe_optional(record.activation_result, 64) ||
	    !safe_optional(record.mihomo_version, 128) ||
	    !safe_optional(record.operation_id, 128))
		return false;
	for (let name in [ 'parent_revision', 'restored_revision', 'content_revision',
		'duplicate_of' ]) {
		if (record[name] == null && name != 'content_revision')
			continue;
		try { revision_id(record[name]); }
		catch (error) { return false; }
	}
	if (record.duplicate_of != null && record.duplicate_of != record.content_revision ||
	    record.duplicate_of == null && record.content_revision != revision)
		return false;
	return true;
};

function clone(value) {
	try { return json(sprintf('%J', value)); }
	catch (error) { errors.fail('INTERNAL'); }
};

export function create(runtime, options) {
	if (type(runtime?.fs) != 'object' || type(runtime?.digest?.sha256) != 'function' ||
	    type(runtime?.clock?.now) != 'function' || type(runtime?.random?.hex) != 'function' ||
	    (options != null && type(options) != 'object'))
		errors.fail('INVALID_ARGUMENT');
	for (let name in options ?? {})
		if (name != 'diff' && name != 'retention')
			errors.fail('INVALID_ARGUMENT');
	let diff_adapter = options?.diff;
	if (diff_adapter != null && type(diff_adapter?.unified) != 'function')
		errors.fail('INVALID_ARGUMENT');
	let retention = options?.retention ?? DEFAULT_RETENTION;
	if (type(retention) != 'int' || retention < 1 || retention > 100)
		errors.fail('INVALID_ARGUMENT');

	ensure_directory(runtime, '/opt/clash/history', 0o700);
	let bound_operations = null;
	let bound_config = null;

	function directory(profile) {
		profile = schema.profile_name(profile);
		let path = '/opt/clash/history/' + profile;
		ensure_directory(runtime, path, 0o700);
		return path;
	};

	function paths(profile, revision) {
		revision = revision_id(revision);
		let base = directory(profile) + '/' + revision;
		return {
			base,
			yaml: base + '/config.yaml',
			json: base + '/metadata.json',
			legacy_yaml: base + '.yaml',
			legacy_json: base + '.json'
		};
	};

	function revision_files(profile, revision) {
		let destination = paths(profile, revision);
		let stat = runtime.fs.lstat(destination.base);
		if (stat == null)
			return { yaml: destination.legacy_yaml, json: destination.legacy_json,
				base: null, identity: null, legacy: true };
		if (stat?.type != 'directory' || runtime.fs.realpath(destination.base) != destination.base ||
		    (stat.uid != null && stat.uid != 0) ||
		    (stat.mode != null && (stat.mode & 0o777) != 0o700))
			errors.fail('CORRUPT_STATE');
		return { yaml: destination.yaml, json: destination.json,
			base: destination.base, identity: stat, legacy: false };
	};

	function assert_revision_directory(files) {
		if (files.legacy)
			return;
		let current = runtime.fs.lstat(files.base);
		if (!same_node(files.identity, current) || current?.type != 'directory' ||
		    runtime.fs.realpath(files.base) != files.base ||
		    (current.uid != null && current.uid != 0) ||
		    (current.mode != null && (current.mode & 0o777) != 0o700))
			errors.fail('CORRUPT_STATE');
	};

	function assert_revision_layout(files, record) {
		assert_revision_directory(files);
		if (files.legacy)
			return;
		let entries = runtime.fs.lsdir(files.base);
		if (type(entries) != 'array')
			errors.fail('CORRUPT_STATE');
		sort(entries);
		let expected = record.duplicate_of == null ?
			[ 'config.yaml', 'metadata.json' ] : [ 'metadata.json' ];
		if (sprintf('%J', entries) != sprintf('%J', expected))
			errors.fail('CORRUPT_STATE');
		if (record.duplicate_of == null) {
			let stat = runtime.fs.lstat(files.yaml);
			if (!owned_file(stat, 0o600) || runtime.fs.realpath(files.yaml) != files.yaml)
				errors.fail('CORRUPT_STATE');
		}
		assert_revision_directory(files);
	};

	function normalize_legacy(record, profile, revision, files) {
		if (type(record) != 'object')
			errors.fail('CORRUPT_STATE');
		for (let name in record)
			if (!exists(LEGACY_FIELDS, name))
				errors.fail('CORRUPT_STATE');
		let yaml = runtime.fs.lstat(files.yaml);
		if (record.revision != revision || record.profile != profile ||
		    record.filename != revision + '.yaml' ||
		    type(record.source) != 'string' || !exists(SOURCE_MAP, record.source) ||
		    SOURCE_MAP[record.source] != record.source || type(record.timestamp) != 'int' ||
		    record.timestamp < 0 || type(record.hash) != 'string' ||
		    !match(record.hash, /^[0-9a-f]{64}$/) || !owned_file(yaml, 0o600) ||
		    runtime.fs.realpath(files.yaml) != files.yaml ||
		    !safe_optional(record.validation_result, 64) ||
		    !safe_optional(record.activation_result, 64) ||
		    !safe_optional(record.mihomo_version, 128) ||
		    !safe_optional(record.operation_id, 128))
			errors.fail('CORRUPT_STATE');
		let parent_revision = record.parent_revision ?? null;
		let restored_revision = record.restored_revision ?? null;
		if (parent_revision != null)
			parent_revision = revision_id(parent_revision);
		if (restored_revision != null)
			restored_revision = revision_id(restored_revision);
		return {
			revision, filename: revision + '.yaml', profile, source: record.source,
			timestamp: record.timestamp, hash: record.hash, size: yaml.size,
			validation_result: record.validation_result ?? null,
			activation_result: record.activation_result ?? null,
			mihomo_version: record.mihomo_version ?? null,
			operation_id: record.operation_id ?? null,
			parent_revision, restored_revision, content_revision: revision,
			duplicate_of: null
		};
	};

	function secure_read(path, mode, maximum, missing_code) {
		let before = runtime.fs.lstat(path);
		let handle = runtime.fs.open(path, 'r');
		if (handle == null)
			errors.fail(missing_code ?? 'CORRUPT_STATE');
		let opened = runtime.fs.fstat(handle);
		let output = '';
		let failure = null;
		try {
			if (!owned_file(before, mode) || !owned_file(opened, mode) ||
			    !same_node(before, opened) || runtime.fs.realpath(path) != path)
				errors.fail('CORRUPT_STATE');
			while (true) {
				let chunk = runtime.fs.read(handle, 16384);
				if (type(chunk) != 'string')
					errors.fail('CORRUPT_STATE');
				if (!length(chunk))
					break;
				output += chunk;
				if (length(output) > maximum)
					errors.fail('RESPONSE_TOO_LARGE');
			}
			let after = runtime.fs.lstat(path);
			let final = runtime.fs.fstat(handle);
			if (!same_node(before, after) || !same_node(opened, final) ||
			    !owned_file(after, mode) || !owned_file(final, mode) ||
			    runtime.fs.realpath(path) != path || after.size != length(output) ||
			    final.size != length(output))
				errors.fail('CORRUPT_STATE');
		}
		catch (error) { failure = errors.normalize(error).code; }
		if (runtime.fs.close(handle) != true)
			failure = 'CORRUPT_STATE';
		if (failure != null)
			errors.fail(failure);
		return output;
	};

	function read_record(profile, revision) {
		profile = schema.profile_name(profile);
		revision = revision_id(revision);
		let files = revision_files(profile, revision);
		let raw = secure_read(files.json, 0o600,
			MAX_METADATA_BYTES, 'NOT_FOUND');
		assert_revision_directory(files);
		let record;
		try { record = json(raw); }
		catch (error) { errors.fail('CORRUPT_STATE'); }
		if (files.legacy)
			record = normalize_legacy(record, profile, revision, files);
		if (!valid_record(record, profile, revision))
			errors.fail('CORRUPT_STATE');
		assert_revision_layout(files, record);
		return record;
	};

	function public_record(record) {
		return { ...clone(redact.value('history', record)), corrupt: false };
	};

	function all_records(profile) {
		profile = schema.profile_name(profile);
		let output = [];
		let names = runtime.fs.lsdir(directory(profile));
		if (type(names) != 'array')
			errors.fail('INTERNAL');
		for (let name in names) {
			let found = match(name, /^([0-9]{13}-[0-9a-f]{16})\.json$/);
			let revision = found?.[1];
			if (revision == null && match(name,
				/^[0-9]{13}-[0-9a-f]{12}-[0-9a-f]{16}$/))
				revision = name;
			if (revision == null)
				continue;
			try { push(output, public_record(read_record(profile, revision))); }
			catch (error) {
				push(output, { revision, corrupt: true, error: 'CORRUPT_STATE' });
			}
		}
		sort(output, compare_revision);
		return output;
	};

	function read_content(profile, revision) {
		let record = read_record(profile, revision);
		let content_record = record;
		if (record.content_revision != revision) {
			content_record = read_record(profile, record.content_revision);
			if (content_record.content_revision != content_record.revision ||
			    content_record.hash != record.hash || content_record.size != record.size)
				errors.fail('CORRUPT_STATE');
		}
		let files = revision_files(profile, content_record.revision);
		let content = secure_read(files.yaml,
			0o600, MAX_CONTENT_BYTES, 'CORRUPT_STATE');
		assert_revision_directory(files);
		if (length(content) != record.size || runtime.digest.sha256(content) != record.hash)
			errors.fail('CORRUPT_STATE');
		return { record, content };
	};

	function snapshot_content(profile, source, content, metadata) {
		profile = schema.profile_name(profile);
		source = normalized_source(source);
		if (type(content) != 'string' || !length(content) || length(content) > MAX_CONTENT_BYTES ||
		    (metadata != null && type(metadata) != 'object'))
			errors.fail('INVALID_ARGUMENT');
		let hash = runtime.digest.sha256(content);
		if (type(hash) != 'string' || !match(hash, /^[0-9a-f]{64}$/))
			errors.fail('INTERNAL');
		let duplicate = null;
		let existing_records = all_records(profile);
		let latest_timestamp = -1;
		for (let candidate in existing_records) {
			if (candidate.corrupt === false && candidate.timestamp > latest_timestamp)
				latest_timestamp = candidate.timestamp;
			if (candidate.corrupt === false && candidate.hash == hash && candidate.size == length(content))
				try {
					if (read_content(profile, candidate.revision).content == content)
						duplicate = candidate;
				} catch (error) {}
		}

		let revision = null;
		let destination = null;
		let staging = null;
		let revision_time = runtime.clock.now();
		if (type(revision_time) != 'int' || revision_time < 0)
			errors.fail('INTERNAL');
		if (revision_time <= latest_timestamp)
			revision_time = latest_timestamp + 1;
		for (let attempt = 0; attempt < 16; attempt++) {
			let suffix = runtime.random.hex(8);
			if (type(suffix) != 'string' ||
			    !match(suffix, /^[0-9a-f]{16}$/))
				errors.fail('INTERNAL');
			revision = sprintf('%013d-%s-%s', revision_time + attempt,
				substr(hash, 0, 12), suffix);
			destination = paths(profile, revision);
			let stage_suffix = runtime.random.hex(8);
			if (type(stage_suffix) != 'string' || !match(stage_suffix, /^[0-9a-f]{16}$/))
				errors.fail('INTERNAL');
			staging = directory(profile) + '/.' + revision + '.tmp-' + stage_suffix;
			if (runtime.fs.lstat(destination.base) == null &&
			    runtime.fs.lstat(destination.legacy_yaml) == null &&
			    runtime.fs.lstat(destination.legacy_json) == null &&
			    runtime.fs.lstat(staging) == null && runtime.fs.mkdir(staging) == true) {
				ensure_directory(runtime, staging, 0o700);
				break;
			}
			revision = null;
		}
		if (revision == null)
			errors.fail('INTERNAL');
		let content_revision = duplicate?.content_revision ?? revision;
		let restored_revision = metadata?.restored_revision ?? null;
		if (restored_revision != null)
			restored_revision = revision_id(restored_revision);
		let parent_revision = metadata?.parent_revision ?? null;
		if (parent_revision != null)
			parent_revision = revision_id(parent_revision);
		let record = {
			revision,
			filename: 'config.yaml',
			profile,
			source,
			timestamp: int(split(revision, '-')[0]),
			hash,
			size: length(content),
			validation_result: metadata?.validation_result ?? null,
			activation_result: metadata?.activation_result ?? null,
			mihomo_version: metadata?.mihomo_version ?? null,
			operation_id: metadata?.operation_id ?? null,
			parent_revision,
			restored_revision,
			content_revision,
			duplicate_of: duplicate?.content_revision ?? null
		};
		if (!valid_record(record, profile, revision))
			errors.fail('INVALID_ARGUMENT');
		let failure = null;
		try {
			if (duplicate == null)
				storage.atomic_write(runtime, staging + '/config.yaml', content, 0o600);
			storage.write_json(runtime, staging + '/metadata.json',
				redact.value('history', record), 0o600);
			let stage_identity = runtime.fs.lstat(staging);
			let entries = runtime.fs.lsdir(staging);
			if (stage_identity?.type != 'directory' || runtime.fs.realpath(staging) != staging ||
			    type(entries) != 'array' || length(entries) != (duplicate == null ? 2 : 1))
				errors.fail('INTERNAL');
			let written_metadata = secure_read(staging + '/metadata.json', 0o600,
				MAX_METADATA_BYTES, 'INTERNAL');
			if (written_metadata != sprintf('%J\n', redact.value('history', record)))
				errors.fail('INTERNAL');
			if (duplicate == null) {
				let written_content = secure_read(staging + '/config.yaml', 0o600,
					MAX_CONTENT_BYTES, 'INTERNAL');
				if (written_content != content || runtime.digest.sha256(written_content) != hash)
					errors.fail('INTERNAL');
			}
			let current_stage = runtime.fs.lstat(staging);
			if (!same_node(stage_identity, current_stage) || runtime.fs.realpath(staging) != staging ||
			    runtime.fs.rename(staging, destination.base) != true)
				errors.fail('INTERNAL');
			let published = read_content(profile, revision);
			if (published.content != content ||
			    sprintf('%J', published.record) != sprintf('%J', record))
				errors.fail('INTERNAL');
		}
		catch (error) { failure = errors.normalize(error).code; }
		if (failure != null) {
			try { runtime.fs.unlink(staging + '/config.yaml'); } catch (unlink_error) {}
			try { runtime.fs.unlink(staging + '/metadata.json'); } catch (unlink_error) {}
			try { runtime.fs.rmdir(staging); } catch (rmdir_error) {}
			errors.fail(failure);
		}
		return clone(record);
	};

	function complete_result(ctx, result) {
		if (result?.ok === false) {
			ctx.complete(result.error);
			return false;
		}
		return true;
	};

	function unlink_verified(path, mode, maximum, expected, hash_content) {
		let content = secure_read(path, mode, maximum, 'CORRUPT_STATE');
		if ((hash_content && runtime.digest.sha256(content) != expected) ||
		    (!hash_content && content != expected))
			errors.fail('CORRUPT_STATE');
		let before = runtime.fs.lstat(path);
		if (!owned_file(before, mode) || runtime.fs.realpath(path) != path)
			errors.fail('CORRUPT_STATE');
		let after = runtime.fs.lstat(path);
		if (!same_node(before, after) || runtime.fs.realpath(path) != path ||
		    runtime.fs.unlink(path) != true)
			errors.fail('CORRUPT_STATE');
	};

	let api = {};
	api.snapshot_bytes = (profile, source, content, metadata) =>
		snapshot_content(profile, source, content, metadata);
	api.snapshot = (profile, source, metadata) => {
		profile = schema.profile_name(profile);
		let active = '/opt/clash/' + profile;
		let content = secure_read(active, 0o600, MAX_CONTENT_BYTES, 'NOT_FOUND');
		return snapshot_content(profile, source, content, metadata);
	};
	api.list = all_records;
	api.read = (profile, revision) => read_content(profile, revision).content;
	api.get = (profile, revision) => {
		let fetched = read_content(profile, revision);
		return { metadata: public_record(fetched.record), content: fetched.content };
	};
	api.diff = (profile, old_revision, next_revision, limits) => {
		if (diff_adapter == null)
			errors.fail('INVALID_ARGUMENT');
		return diff_adapter.unified(api.read(profile, old_revision),
			api.read(profile, next_revision), limits);
	};
	api.mark_activation = (profile, revision, result) => {
		if (type(result) != 'string' ||
		    (result != 'success' && result != 'health_failed' &&
		     result != 'validation_failed' && result != 'failed'))
			errors.fail('INVALID_ARGUMENT');
		let destination = revision_files(profile, revision);
		let record = read_record(profile, revision);
		record.activation_result = result;
		storage.write_json(runtime, destination.json, redact.value('history', record), 0o600);
		assert_revision_directory(destination);
		if (sprintf('%J', read_record(profile, revision)) != sprintf('%J', record))
			errors.fail('CORRUPT_STATE');
		return clone(record);
	};
	api.bind_config = (operations, configuration) => {
		if (type(operations?.submit) != 'function' || type(operations?.is_context) != 'function' ||
		    type(configuration?.save_draft_in_operation) != 'function' ||
		    type(configuration?.apply_in_operation) != 'function' ||
		    type(configuration?.capture_active_in_operation) != 'function' ||
		    type(configuration?.apply_restore_in_operation) != 'function')
			errors.fail('INVALID_ARGUMENT');
		if (bound_operations != null &&
		    (bound_operations !== operations || bound_config !== configuration))
			errors.fail('BUSY');
		bound_operations = operations;
		bound_config = configuration;
		return true;
	};
	api.open_draft = (profile, revision, source) => {
		profile = schema.profile_name(profile);
		revision = revision_id(revision);
		if (bound_operations == null)
			errors.fail('INVALID_ARGUMENT');
		return bound_operations.submit('history.open_draft', source,
			{ profile, revision }, (ctx) => {
				let content = api.read(profile, revision);
				bound_config.save_draft_in_operation(ctx, profile, content);
			});
	};
	api.restore_in_operation = (ctx, configuration, profile, revision) => {
		if (bound_operations == null || bound_operations.is_context(ctx) !== true ||
		    configuration !== bound_config)
			errors.fail('INVALID_ARGUMENT');
		profile = schema.profile_name(profile);
		revision = revision_id(revision);
		let selected_content = api.read(profile, revision);
		let capture = configuration.capture_active_in_operation(ctx, profile);
		let before = api.snapshot_bytes(profile, 'restore-before', capture.content, {
			validation_result: 'success',
			activation_result: 'pending',
			operation_id: ctx.id,
			restored_revision: revision
		});
		let selected = null;
		let terminal_failure = null;
		function terminalize(result) {
			for (let record in [ selected, before ]) {
				if (record == null)
					continue;
				try { api.mark_activation(profile, record.revision, result); }
				catch (error) { terminal_failure = errors.normalize(error).code; }
			}
			if (terminal_failure != null)
				errors.fail(terminal_failure);
		};
		try {
			let result = configuration.apply_restore_in_operation(
				ctx, profile, selected_content, capture, (candidate, candidate_hash) => {
					if (runtime.digest.sha256(candidate) != candidate_hash)
						errors.fail('INTERNAL');
					selected = api.snapshot_bytes(profile, 'restore', candidate, {
						validation_result: 'success',
						activation_result: 'pending',
						operation_id: ctx.id,
						parent_revision: before.revision,
						restored_revision: revision
					});
				});
			if (result?.ok === false && result?.error?.code == 'VALIDATION_FAILED') {
				terminalize('validation_failed');
				return result;
			}
			if (result?.ok === false && result?.error?.code == 'HEALTH_FAILED') {
				terminalize('health_failed');
				return result;
			}
			if (result?.ok !== true)
				errors.fail('INTERNAL');
			terminalize('success');
			return result;
		}
		catch (error) {
			try { terminalize('failed'); }
			catch (terminal_error) { errors.fail(errors.normalize(terminal_error).code); }
			errors.fail(errors.normalize(error).code);
		}
	};
	api.restore = (profile, revision, source) => {
		profile = schema.profile_name(profile);
		revision = revision_id(revision);
		if (bound_operations == null)
			errors.fail('INVALID_ARGUMENT');
		return bound_operations.submit('history.restore', source,
			{ profile, revision }, (ctx) => complete_result(ctx,
				api.restore_in_operation(ctx, bound_config, profile, revision)));
	};
	api.prune = (profile) => {
		profile = schema.profile_name(profile);
		let records = all_records(profile);
		let valid = [];
		for (let record in records)
			if (record.corrupt === false)
				push(valid, record);
		let protected_ids = {};
		let first_kept = length(valid) - retention;
		if (first_kept < 0)
			first_kept = 0;
		for (let index = first_kept; index < length(valid); index++)
			protected_ids[valid[index].revision] = true;
		let protected_hashes = {};
		try {
			let active = secure_read('/opt/clash/' + profile, 0o600,
				MAX_CONTENT_BYTES, 'NOT_FOUND');
			protected_hashes[runtime.digest.sha256(active)] = true;
		}
		catch (error) {
			if (errors.normalize(error).code != 'NOT_FOUND')
				errors.fail(errors.normalize(error).code);
		}
		let tracker = '/opt/clash/history/active-' + profile + '.json';
		if (runtime.fs.lstat(tracker) != null)
			try {
				let state = json(secure_read(tracker, 0o600, MAX_METADATA_BYTES,
					'CORRUPT_STATE'));
				if (state?.profile != profile || type(state?.hash) != 'string' ||
				    !match(state.hash, /^[0-9a-f]{64}$/))
					errors.fail('CORRUPT_STATE');
				protected_hashes[state.hash] = true;
			}
			catch (error) { errors.fail('CORRUPT_STATE'); }
		let newest_by_hash = {};
		for (let record in valid)
			if (protected_hashes[record.hash])
				newest_by_hash[record.hash] = record.revision;
		for (let hash, revision in newest_by_hash)
			protected_ids[revision] = true;
		let changed = true;
		while (changed) {
			changed = false;
			for (let record in valid) {
				if (!protected_ids[record.revision])
					continue;
				for (let ancestor in [ record.parent_revision, record.restored_revision,
					record.content_revision, record.duplicate_of ])
					if (ancestor != null && !protected_ids[ancestor]) {
						protected_ids[ancestor] = true;
						changed = true;
					}
			}
		}
		let removed = 0;
		for (let record in valid) {
			if (protected_ids[record.revision])
				continue;
			let destination = revision_files(profile, record.revision);
			if (destination.legacy)
				continue;
			let expected_record = { ...record };
			delete expected_record.corrupt;
			let current_record = read_record(profile, record.revision);
			if (sprintf('%J', current_record) != sprintf('%J', expected_record))
				errors.fail('CORRUPT_STATE');
			assert_revision_directory(destination);
			if (record.content_revision == record.revision) {
				unlink_verified(destination.yaml, 0o600, MAX_CONTENT_BYTES,
					record.hash, true);
				assert_revision_directory(destination);
			}
			unlink_verified(destination.json, 0o600, MAX_METADATA_BYTES,
				sprintf('%J\n', current_record), false);
			if (!destination.legacy) {
				assert_revision_directory(destination);
				let entries = runtime.fs.lsdir(destination.base);
				if (type(entries) != 'array' || length(entries) != 0 ||
				    runtime.fs.rmdir(destination.base) != true)
					errors.fail('CORRUPT_STATE');
			}
			removed++;
		}
		return removed;
	};

	return api;
};
