import { fail } from 'miclash.errors';
import { sha256 as digest_sha256, sha256_file as digest_sha256_file } from 'digest';
import { rand } from 'math';

let operation_sequence = 0;

function valid_path(path) {
	if (type(path) != 'string' || length(path) < 2 || substr(path, 0, 1) != '/' ||
	    substr(path, -1) == '/' || index(path, '//') >= 0 || index(path, '\\') >= 0)
		fail('INVALID_ARGUMENT');

	for (let part in split(path, '/'))
		if (part == '.' || part == '..' || index(part, sprintf('%c', 0)) >= 0)
			fail('INVALID_ARGUMENT');

	return path;
};

function dirname(path) {
	let parts = split(path, '/');
	pop(parts);
	let directory = join('/', parts);
	return length(directory) ? directory : '/';
};

function basename(path) {
	let parts = split(path, '/');
	return parts[length(parts) - 1];
};

function same_device(left, right) {
	return left?.dev != null && right?.dev != null &&
		left.dev.major == right.dev.major && left.dev.minor == right.dev.minor;
};

function operation_id(runtime) {
	operation_sequence++;
	return sprintf('%d-%d', runtime.clock.now(), operation_sequence);
};

function temp_path(runtime, destination, id) {
	return sprintf('%s/.%s.miclash.%s.%08x',
		dirname(destination), basename(destination), id, rand());
};

export function safe_name(name) {
	if (type(name) != 'string' || !match(name, /^[A-Za-z0-9][A-Za-z0-9._-]*$/) ||
	    length(name) > 128 || name == '.' || name == '..')
		fail('INVALID_ARGUMENT');

	return name;
};

export function atomic_write(runtime, path, data, mode) {
	valid_path(path);
	if (type(data) != 'string' || type(mode) != 'int' || mode < 0 || mode > 0o7777 ||
	    type(runtime?.fs) != 'object' || type(runtime?.clock?.now) != 'function')
		fail('INVALID_ARGUMENT');

	let directory = dirname(path);
	let directory_stat = runtime.fs.stat(directory);
	if (directory_stat?.type != 'directory')
		fail('INVALID_ARGUMENT');

	let owned = null;
	let handle = null;
	let closed = false;
	let id = operation_id(runtime);

	try {
		for (let attempt = 0; attempt < 16; attempt++) {
			let candidate = temp_path(runtime, path, id);
			handle = runtime.fs.open(candidate, 'wx', 0o600);
			if (handle != null) {
				owned = candidate;
				break;
			}
		}
		if (handle == null)
			fail('INTERNAL');

		let offset = 0;
		while (offset < length(data)) {
			let written = runtime.fs.write(handle, substr(data, offset));
			if (type(written) != 'int' || written <= 0 || written > length(data) - offset)
				fail('INTERNAL');
			offset += written;
		}

		if (runtime.fs.flush(handle) != true)
			fail('INTERNAL');
		let close_result = runtime.fs.close(handle);
		closed = true;
		if (close_result != true)
			fail('INTERNAL');
		if (runtime.fs.chmod(owned, mode) != true)
			fail('INTERNAL');

		let temp_stat = runtime.fs.stat(owned);
		if (temp_stat?.type != 'file' || temp_stat.size != length(data) ||
		    runtime.fs.readfile(owned) != data)
			fail('INTERNAL');
		if (!same_device(temp_stat, directory_stat))
			fail('INVALID_ARGUMENT');
		if (runtime.fs.rename(owned, path) != true)
			fail('INTERNAL');

		owned = null;
		return true;
	}
	catch (error) {
		if (handle != null && !closed) {
			try { runtime.fs.close(handle); } catch (close_error) {}
			closed = true;
		}
		if (owned != null) {
			try { runtime.fs.unlink(owned); } catch (unlink_error) {}
		}
		let code = error?.code ?? error?.message;
		fail(code == 'INVALID_ARGUMENT' ? 'INVALID_ARGUMENT' : 'INTERNAL');
	}
};

export function atomic_replace(runtime, source, destination) {
	valid_path(source);
	valid_path(destination);
	if (source == destination || type(runtime?.fs) != 'object')
		fail('INVALID_ARGUMENT');

	let source_stat = runtime.fs.stat(source);
	let directory_stat = runtime.fs.stat(dirname(destination));
	if (source_stat?.type != 'file' || directory_stat?.type != 'directory' ||
	    !same_device(source_stat, directory_stat))
		fail('INVALID_ARGUMENT');
	if (runtime.fs.rename(source, destination) != true)
		fail('INTERNAL');

	return true;
};

export function read_json(runtime, path) {
	valid_path(path);
	let source = runtime?.fs?.readfile(path);
	if (type(source) != 'string')
		fail('NOT_FOUND');

	try {
		return json(source);
	}
	catch (error) {
		fail('CORRUPT_STATE');
	}
};

export function write_json(runtime, path, value, mode) {
	let encoded;
	try { encoded = sprintf('%J\n', value); }
	catch (error) { fail('INVALID_ARGUMENT'); }
	return atomic_write(runtime, path, encoded, mode ?? 0o600);
};

export function sha256(value, file) {
	if (type(value) != 'string' || (file != null && type(file) != 'bool'))
		fail('INVALID_ARGUMENT');

	let digest = file ? digest_sha256_file(value) : digest_sha256(value);
	if (type(digest) != 'string' || length(digest) != 64 || !match(digest, /^[0-9a-f]+$/))
		fail('INTERNAL');

	return digest;
};

export function cleanup_runtime(runtime) {
	if (type(runtime?.fs) != 'object' || runtime?.paths?.run != '/var/run/miclash' ||
	    runtime?.paths?.tmp != '/tmp/miclash')
		fail('INVALID_ARGUMENT');

	let removed = 0;
	for (let directory in [ runtime.paths.run, runtime.paths.tmp ]) {
		for (let name in runtime.fs.lsdir(directory) ?? []) {
			try { safe_name(name); } catch (error) { continue; }
			let path = directory + '/' + name;
			if (runtime.fs.stat(path)?.type == 'file' && runtime.fs.unlink(path) == true)
				removed++;
		}
	}

	return removed;
};
