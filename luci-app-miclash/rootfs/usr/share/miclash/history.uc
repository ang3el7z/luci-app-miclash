import * as errors from 'miclash.errors';
import * as redact from 'miclash.redact';
import * as schema from 'miclash.schema';
import * as storage from 'miclash.storage';

const SOURCES = {
	luci: true, telegram: true, auto: true, system: true, external: true, restore: true
};

function ensure_directory(runtime, path, mode) {
	let stat = runtime.fs.lstat(path);
	if (stat == null && runtime.fs.mkdir(path) != true)
		errors.fail('INTERNAL');
	stat = runtime.fs.lstat(path);
	if (stat?.type != 'directory' || runtime.fs.realpath(path) != path ||
	    runtime.fs.chmod(path, mode) != true)
		errors.fail('INTERNAL');
};

function compare_revision(left, right) {
	if (left.revision == right.revision)
		return 0;
	return left.revision < right.revision ? -1 : 1;
};

export function create(runtime) {
	if (type(runtime?.fs) != 'object' || type(runtime?.digest?.sha256) != 'function' ||
	    type(runtime?.clock?.now) != 'function' || type(runtime?.random?.hex) != 'function')
		errors.fail('INVALID_ARGUMENT');

	ensure_directory(runtime, '/opt/clash/history', 0o700);

	function directory(profile) {
		profile = schema.profile_name(profile);
		let path = '/opt/clash/history/' + profile;
		ensure_directory(runtime, path, 0o700);
		return path;
	};

	function paths(profile, revision) {
		revision = schema.operation_id(revision);
		let base = directory(profile) + '/' + revision;
		return { yaml: base + '.yaml', json: base + '.json', lock: base + '.lock' };
	};

	function snapshot_content(profile, source, content, metadata) {
		profile = schema.profile_name(profile);
		if (type(source) != 'string' || !exists(SOURCES, source) ||
		    type(content) != 'string' ||
		    (metadata != null && type(metadata) != 'object'))
			errors.fail('INVALID_ARGUMENT');

		let revision;
		let destination;
		let reservation = null;
		for (let attempt = 0; attempt < 16; attempt++) {
			let now = runtime.clock.now();
			let suffix = runtime.random.hex(8);
			if (type(now) != 'int' || now < 0 || type(suffix) != 'string' ||
			    !match(suffix, /^[0-9a-f]{16}$/))
				errors.fail('INTERNAL');
			revision = sprintf('%013d-%s', now, suffix);
			destination = paths(profile, revision);
			reservation = runtime.fs.open(destination.lock, 'wx', 0o600);
			if (reservation != null && runtime.fs.lstat(destination.yaml) == null &&
			    runtime.fs.lstat(destination.json) == null) {
				if (runtime.fs.close(reservation) != true)
					errors.fail('INTERNAL');
				reservation = null;
				break;
			}
			if (reservation != null) {
				try { runtime.fs.close(reservation); } catch (close_error) {}
				reservation = null;
				try { runtime.fs.unlink(destination.lock); } catch (unlink_error) {}
			}
			revision = null;
		}
		if (revision == null)
			errors.fail('INTERNAL');

		let record = {
			revision,
			filename: revision + '.yaml',
			profile,
			source,
			timestamp: runtime.clock.now(),
			hash: runtime.digest.sha256(content),
			validation_result: metadata?.validation_result ?? null,
			activation_result: metadata?.activation_result ?? null,
			mihomo_version: metadata?.mihomo_version ?? null,
			operation_id: metadata?.operation_id ?? null
		};
		for (let name, value in metadata ?? {})
			if (!exists(record, name))
				record[name] = value;
		record = redact.value('history', record);
		let failure = null;
		try {
			storage.atomic_write(runtime, destination.yaml, content, 0o600);
			storage.write_json(runtime, destination.json, record, 0o600);
		}
		catch (error) {
			failure = errors.normalize(error).code;
		}
		try { runtime.fs.unlink(destination.lock); } catch (unlink_error) {}
		if (failure != null) {
			try { runtime.fs.unlink(destination.yaml); } catch (unlink_error) {}
			try { runtime.fs.unlink(destination.json); } catch (unlink_error) {}
			errors.fail(failure);
		}
		return record;
	};

	let api = {};
	api.snapshot_bytes = (profile, source, content, metadata) =>
		snapshot_content(profile, source, content, metadata);
	api.snapshot = (profile, source, metadata) => {
		profile = schema.profile_name(profile);
		let active = '/opt/clash/' + profile;
		let active_stat = runtime.fs.lstat(active);
		let content = runtime.fs.readfile(active);
		if (active_stat?.type != 'file' || active_stat.nlink != 1 ||
		    runtime.fs.realpath(active) != active || type(content) != 'string')
			errors.fail('NOT_FOUND');
		return snapshot_content(profile, source, content, metadata);
	};
	api.list = (profile) => {
		profile = schema.profile_name(profile);
		let output = [];
		for (let name in runtime.fs.lsdir(directory(profile)) ?? []) {
			if (!match(name, /^[0-9]{13}-[0-9a-f]{16}\.json$/))
				continue;
			let record = storage.read_json(runtime, directory(profile) + '/' + name);
			let expected = record?.revision + '.json';
			if (type(record?.revision) != 'string' ||
			    !match(record.revision, /^[0-9]{13}-[0-9a-f]{16}$/) ||
			    record?.filename != record?.revision + '.yaml' ||
			    record?.profile != profile || !exists(SOURCES, record?.source) ||
			    type(record?.hash) != 'string' || !match(record.hash, /^[0-9a-f]{64}$/) ||
			    expected != name ||
			    runtime.fs.lstat(directory(profile) + '/' + record.filename)?.type != 'file')
				errors.fail('CORRUPT_STATE');
			push(output, redact.value('history', record));
		}
		sort(output, compare_revision);
		return output;
	};
	api.read = (profile, revision) => {
		profile = schema.profile_name(profile);
		let destination = paths(profile, revision);
		let record = storage.read_json(runtime, destination.json);
		let stat = runtime.fs.lstat(destination.yaml);
		let content = runtime.fs.readfile(destination.yaml);
		if (record?.profile != profile || record?.revision != revision ||
		    record?.filename != revision + '.yaml' || stat?.type != 'file' || stat.nlink != 1 ||
		    runtime.fs.realpath(destination.yaml) != destination.yaml ||
		    type(content) != 'string' || runtime.digest.sha256(content) != record.hash)
			errors.fail('CORRUPT_STATE');
		return content;
	};
	api.mark_activation = (profile, revision, result) => {
		if (type(result) != 'string' ||
		    (result != 'success' && result != 'health_failed'))
			errors.fail('INVALID_ARGUMENT');
		let destination = paths(profile, revision);
		let record = storage.read_json(runtime, destination.json);
		if (record?.profile != profile || record?.revision != revision)
			errors.fail('CORRUPT_STATE');
		record.activation_result = result;
		storage.write_json(runtime, destination.json, redact.value('history', record), 0o600);
		return record;
	};

	return api;
};
