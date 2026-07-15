import * as errors from 'miclash.errors';
import * as redact from 'miclash.redact';
import * as schema from 'miclash.schema';
import * as storage from 'miclash.storage';

const DEFAULT_RETENTION = 10;
const MAX_CONTENT_BYTES = 1048576;
const MAX_METADATA_BYTES = 65536;
const MAX_ROOT_ENTRIES = 64;
const MAX_PROFILE_ENTRIES = 256;
const PROFILES = [ 'config.yaml', 'config2.yaml', 'config3.yaml' ];
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
	let id_fields = split(revision, '-');
	if (int(id_fields[0]) != record.timestamp ||
	    (length(id_fields) == 3 && id_fields[1] != substr(record.hash, 0, 12)) ||
	    (length(id_fields) != 2 && length(id_fields) != 3) ||
	    record.duplicate_of != null && record.duplicate_of != record.content_revision ||
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

	function auxiliary(name) {
		if (type(name) != 'string')
			return null;
		let found = match(name,
			/^[.](stage|prune)-([0-9]{13}-[0-9a-f]{12}-[0-9a-f]{16})-([0-9a-f]{16})$/);
		return found == null ? null : {
			kind: found[1], revision: found[2], suffix: found[3]
		};
	};

	function cleanup_auxiliary(profile, name) {
		if (auxiliary(name) == null)
			errors.fail('INVALID_ARGUMENT');
		let path = directory(profile) + '/' + name;
		let identity = runtime.fs.lstat(path);
		if (identity?.type != 'directory' || runtime.fs.realpath(path) != path ||
		    (identity.uid != null && identity.uid != 0) ||
		    (identity.mode != null && (identity.mode & 0o777) != 0o700))
			errors.fail('CORRUPT_STATE');
		let entries = runtime.fs.lsdir(path);
		if (type(entries) != 'array' || length(entries) > 2)
			errors.fail('CORRUPT_STATE');
		sort(entries);
		let prepared = [];
		for (let entry in entries) {
			if (entry != 'config.yaml' && entry != 'metadata.json')
				errors.fail('CORRUPT_STATE');
			let file = path + '/' + entry;
			let stat = runtime.fs.lstat(file);
			if (!owned_file(stat, 0o600) || runtime.fs.realpath(file) != file)
				errors.fail('CORRUPT_STATE');
			push(prepared, { path: file, identity: stat });
		}
		for (let item in prepared) {
			let current_directory = runtime.fs.lstat(path);
			let current = runtime.fs.lstat(item.path);
			if (!same_node(identity, current_directory) ||
			    runtime.fs.realpath(path) != path || !same_node(item.identity, current) ||
			    runtime.fs.realpath(item.path) != item.path ||
			    runtime.fs.unlink(item.path) != true)
				errors.fail('INTERNAL');
		}
		let current = runtime.fs.lstat(path);
		entries = runtime.fs.lsdir(path);
		if (!same_node(identity, current) || runtime.fs.realpath(path) != path ||
		    type(entries) != 'array' || length(entries) != 0 ||
		    runtime.fs.rmdir(path) != true)
			errors.fail('INTERNAL');
		return true;
	};

	function recover_profile(profile) {
		profile = schema.profile_name(profile);
		let names = runtime.fs.lsdir(directory(profile));
		if (type(names) != 'array')
			errors.fail('INTERNAL');
		if (length(names) > MAX_PROFILE_ENTRIES)
			errors.fail('RESPONSE_TOO_LARGE');
		sort(names);
		for (let name in names)
			if (auxiliary(name) != null)
				cleanup_auxiliary(profile, name);
	};

	function recover_existing() {
		let names = runtime.fs.lsdir('/opt/clash/history');
		if (type(names) != 'array')
			errors.fail('INTERNAL');
		if (length(names) > MAX_ROOT_ENTRIES)
			errors.fail('RESPONSE_TOO_LARGE');
		for (let profile in PROFILES)
			if (runtime.fs.lstat('/opt/clash/history/' + profile) != null)
				recover_profile(profile);
	};

	function revision_files(profile, revision) {
		let destination = paths(profile, revision);
		let stat = runtime.fs.lstat(destination.base);
		let legacy_yaml = runtime.fs.lstat(destination.legacy_yaml);
		let legacy_json = runtime.fs.lstat(destination.legacy_json);
		let directory_layout = length(split(revision, '-')) == 3;
		if (!directory_layout) {
			if (stat != null || (legacy_yaml == null) != (legacy_json == null))
				errors.fail('CORRUPT_STATE');
			return { yaml: destination.legacy_yaml, json: destination.legacy_json,
				base: null, identity: null, legacy: true };
		}
		if (legacy_yaml != null || legacy_json != null)
			errors.fail('CORRUPT_STATE');
		if (stat == null)
			return { yaml: destination.yaml, json: destination.json,
				base: destination.base, identity: null, legacy: false };
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
		if (int(split(revision, '-')[0]) != record.timestamp)
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

	function canonical_record(profile, record) {
		if (record.duplicate_of == null)
			return record;
		let target;
		try { target = read_record(profile, record.content_revision); }
		catch (error) { errors.fail('CORRUPT_STATE'); }
		if (target.profile != profile || target.revision != record.content_revision ||
		    target.content_revision != target.revision || target.duplicate_of != null ||
		    target.hash != record.hash || target.size != record.size)
			errors.fail('CORRUPT_STATE');
		return target;
	};

	function all_records(profile) {
		profile = schema.profile_name(profile);
		recover_profile(profile);
		let output = [];
		let names = runtime.fs.lsdir(directory(profile));
		if (type(names) != 'array')
			errors.fail('INTERNAL');
		let revisions = {};
		for (let name in names) {
			let found = match(name,
				/^([0-9]{13}-([0-9a-f]{16}|[0-9a-f]{12}-[0-9a-f]{16}))(\.(json|yaml))?$/);
			if (found != null)
				revisions[found[1]] = true;
		}
		for (let revision in revisions) {
			try {
				let record = read_record(profile, revision);
				canonical_record(profile, record);
				push(output, public_record(record));
			}
			catch (error) {
				push(output, { revision, corrupt: true, error: 'CORRUPT_STATE' });
			}
		}
		sort(output, compare_revision);
		return output;
	};

	function read_content(profile, revision) {
		recover_profile(profile);
		let record = read_record(profile, revision);
		let content_record = canonical_record(profile, record);
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
			if (candidate.corrupt !== false)
				continue;
			let authenticated;
			try { authenticated = read_content(profile, candidate.revision); }
			catch (error) { continue; }
			if (authenticated.record.timestamp > latest_timestamp)
				latest_timestamp = authenticated.record.timestamp;
			if (authenticated.record.hash == hash &&
			    authenticated.record.size == length(content) &&
			    authenticated.content == content)
				duplicate = authenticated.record;
		}

		let revision = null;
		let destination = null;
		let staging = null;
		let staging_name = null;
		let revision_time = runtime.clock.now();
		if (type(revision_time) != 'int' || revision_time < 0 ||
		    revision_time > 9999999999999)
			errors.fail('INTERNAL');
		if (revision_time <= latest_timestamp)
			revision_time = latest_timestamp + 1;
		if (revision_time > 9999999999999)
			errors.fail('INTERNAL');
		for (let attempt = 0; attempt < 16; attempt++) {
			let suffix = runtime.random.hex(8);
			if (type(suffix) != 'string' ||
			    !match(suffix, /^[0-9a-f]{16}$/))
				errors.fail('INTERNAL');
			if (revision_time + attempt > 9999999999999)
				errors.fail('INTERNAL');
			revision = sprintf('%013d-%s-%s', revision_time + attempt,
				substr(hash, 0, 12), suffix);
			destination = paths(profile, revision);
			let stage_suffix = runtime.random.hex(8);
			if (type(stage_suffix) != 'string' || !match(stage_suffix, /^[0-9a-f]{16}$/))
				errors.fail('INTERNAL');
			staging_name = '.stage-' + revision + '-' + stage_suffix;
			staging = directory(profile) + '/' + staging_name;
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
			if (staging_name != null && runtime.fs.lstat(staging) != null)
				try { cleanup_auxiliary(profile, staging_name); }
				catch (cleanup_error) { failure = errors.normalize(cleanup_error).code; }
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
		recover_profile(profile);
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
		for (let record in records) {
			if (record.corrupt !== false)
				return 0;
			push(valid, record);
		}
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
		let candidates = [];
		for (let record in valid)
			if (protected_ids[record.revision])
				continue;
			else if (!revision_files(profile, record.revision).legacy)
				push(candidates, record);
		sort(candidates, (left, right) => {
			let left_alias = left.duplicate_of != null;
			let right_alias = right.duplicate_of != null;
			if (left_alias != right_alias)
				return left_alias ? -1 : 1;
			return compare_revision(left, right);
		});
		let removed_visible = {};
		let removed = 0;
		for (let record in candidates) {
			if (record.duplicate_of == null)
				for (let dependent in valid)
					if (dependent.duplicate_of == record.revision &&
					    !protected_ids[dependent.revision] &&
					    !removed_visible[dependent.revision])
						errors.fail('CORRUPT_STATE');
			let destination = revision_files(profile, record.revision);
			if (destination.legacy)
				continue;
			let expected_record = { ...record };
			delete expected_record.corrupt;
			let current_record = read_record(profile, record.revision);
			if (sprintf('%J', current_record) != sprintf('%J', expected_record))
				errors.fail('CORRUPT_STATE');
			let verified = read_content(profile, record.revision);
			if (verified.content == null ||
			    sprintf('%J', verified.record) != sprintf('%J', current_record))
				errors.fail('CORRUPT_STATE');
			assert_revision_directory(destination);
			let tombstone_name = null;
			let tombstone = null;
			for (let attempt = 0; attempt < 16; attempt++) {
				let suffix = runtime.random.hex(8);
				if (type(suffix) != 'string' || !match(suffix, /^[0-9a-f]{16}$/))
					errors.fail('INTERNAL');
				tombstone_name = '.prune-' + record.revision + '-' + suffix;
				tombstone = directory(profile) + '/' + tombstone_name;
				if (runtime.fs.lstat(tombstone) == null)
					break;
				tombstone_name = null;
			}
			if (tombstone_name == null ||
			    runtime.fs.rename(destination.base, tombstone) != true)
				errors.fail('INTERNAL');
			let moved = runtime.fs.lstat(tombstone);
			if (!same_node(destination.identity, moved) ||
			    runtime.fs.realpath(tombstone) != tombstone)
				errors.fail('CORRUPT_STATE');
			removed_visible[record.revision] = true;
			cleanup_auxiliary(profile, tombstone_name);
			removed++;
		}
		return removed;
	};

	recover_existing();
	return api;
};
