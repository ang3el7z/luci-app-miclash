import { fail } from 'miclash.errors';
import { sha256 as digest_sha256, sha256_file as digest_sha256_file } from 'digest';
import { rand } from 'math';

let operation_sequence = 0;
const ALLOWED_ROOTS = [
	'/opt/clash',
	'/etc/miclash',
	'/var/run/miclash',
	'/tmp/miclash'
];

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

function same_identity(left, right) {
	return same_device(left, right) && left?.inode != null && left.inode == right?.inode &&
		left.nlink == right?.nlink && left.size == right?.size && left.type == right?.type;
};

function same_file_object(left, right) {
	return same_device(left, right) && left?.type == 'file' && right?.type == 'file' &&
		left.inode != null && left.inode == right?.inode &&
		left.nlink == 1 && right.nlink == 1;
};

function trusted_directory(stat) {
	return stat?.type == 'directory' && stat.uid === 0 && stat.gid === 0 &&
		type(stat.mode) == 'int' && (stat.mode & 0o022) == 0;
};

function same_directory_authority(left, right) {
	return trusted_directory(left) && trusted_directory(right) &&
		same_device(left, right) && left.inode != null && left.inode == right.inode &&
		left.uid == right.uid && left.gid == right.gid && left.mode == right.mode;
};

function canonical_root(root) {
	return root == '/var/run/miclash' ? '/tmp/run/miclash' : root;
};

function trusted_root_path(root, resolved) {
	return resolved == root ||
		(root == '/var/run/miclash' &&
			(resolved == canonical_root(root) || resolved == '/run/miclash'));
};

function allowed_root(path) {
	for (let root in ALLOWED_ROOTS)
		if (path == root || substr(path, 0, length(root) + 1) == root + '/')
			return root;
	return null;
};

function secure_directory(runtime, path) {
	let root = allowed_root(path);
	let directory = dirname(path);
	if (root == null || (directory != root &&
	    substr(directory, 0, length(root) + 1) != root + '/'))
		fail('INVALID_ARGUMENT');

	let current = root;
	let root_stat = runtime.fs.lstat(current);
	let canonical = runtime.fs.realpath(current);
	if (!trusted_directory(root_stat) || !trusted_root_path(root, canonical))
		fail('INVALID_ARGUMENT');

	let current_stat = root_stat;
	let relative = directory == root ? '' : substr(directory, length(root) + 1);
	for (let part in length(relative) ? split(relative, '/') : []) {
		current += '/' + part;
		canonical += '/' + part;
		current_stat = runtime.fs.lstat(current);
		if (!trusted_directory(current_stat) || runtime.fs.realpath(current) != canonical)
			fail('INVALID_ARGUMENT');
	}

	return { path: directory, canonical, stat: current_stat };
};

function owned_temp_name(source, destination) {
	if (dirname(source) != dirname(destination))
		return false;

	let prefix = '.' + basename(destination) + '.miclash.';
	let source_name = basename(source);
	if (substr(source_name, 0, length(prefix)) != prefix)
		return false;

	let fields = split(substr(source_name, length(prefix)), '.');
	return length(fields) == 2 &&
		match(fields[0], /^[0-9]+-[0-9]+$/) && match(fields[1], /^[0-9A-Fa-f]{8}$/);
};

function owned_runtime_name(name) {
	let staging = split(name, '.miclash.');
	if (length(staging) == 2 && substr(staging[0], 0, 1) == '.' &&
	    match(substr(staging[0], 1), /^[A-Za-z0-9][A-Za-z0-9._-]*$/)) {
		let fields = split(staging[1], '.');
		if (length(fields) == 2 && match(fields[0], /^[0-9]+-[0-9]+$/) &&
		    match(fields[1], /^[0-9A-Fa-f]{8}$/))
			return true;
	}
	return length(name) <= 128 && match(name, /^[A-Za-z0-9][A-Za-z0-9._-]*$/);
};

function operation_id(runtime) {
	operation_sequence++;
	return sprintf('%d-%d', runtime.clock.now(), operation_sequence);
};

function temp_path(runtime, destination, id) {
	return sprintf('%s/.%s.miclash.%s.%08x',
		dirname(destination), basename(destination), id, rand());
};

function canonical_member(directory, path) {
	return directory.canonical + '/' + basename(path);
};

function valid_digest(digest) {
	return type(digest) == 'string' && length(digest) == 64 && match(digest, /^[0-9a-f]+$/);
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
	    type(runtime?.fs) != 'object' || type(runtime?.digest) != 'object' ||
	    type(runtime?.clock?.now) != 'function')
		fail('INVALID_ARGUMENT');

	let directory = secure_directory(runtime, path);
	let directory_stat = directory.stat;

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

		let temp_stat = runtime.fs.lstat(owned);
		if (temp_stat?.type != 'file' || temp_stat.nlink != 1 ||
		    temp_stat.size != length(data))
			fail('INTERNAL');
		if (runtime.fs.realpath(owned) != canonical_member(directory, owned))
			fail('INVALID_ARGUMENT');

		let data_digest = runtime.digest.sha256(data);
		let file_digest = runtime.digest.sha256_file(owned);
		if (data_digest == null || file_digest == null || data_digest != file_digest)
			fail('INTERNAL');
		let verified_stat = runtime.fs.lstat(owned);
		if (!same_identity(temp_stat, verified_stat) || verified_stat.size != length(data) ||
		    runtime.fs.realpath(owned) != canonical_member(directory, owned))
			fail('INVALID_ARGUMENT');
		let current_directory = secure_directory(runtime, path);
		if (directory.canonical != current_directory.canonical ||
		    !same_directory_authority(directory_stat, current_directory.stat))
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

export function atomic_copy(runtime, source, destination, mode, expected_digest) {
	valid_path(source);
	valid_path(destination);
	if (source == destination || type(mode) != 'int' || mode < 0 || mode > 0o7777 ||
	    !valid_digest(expected_digest) || type(runtime?.fs) != 'object' ||
	    type(runtime?.digest) != 'object' || type(runtime?.clock?.now) != 'function')
		fail('INVALID_ARGUMENT');

	let source_directory = secure_directory(runtime, source);
	let destination_directory = secure_directory(runtime, destination);
	let source_stat = runtime.fs.lstat(source);
	if (source_stat?.type != 'file' || source_stat.nlink != 1 ||
	    source_stat.uid !== 0 || source_stat.gid !== 0 ||
	    type(source_stat.mode) != 'int' || (source_stat.mode & 0o022) != 0 ||
	    runtime.fs.realpath(source) != canonical_member(source_directory, source) ||
	    runtime.digest.sha256_file(source) != expected_digest)
		fail('INVALID_ARGUMENT');

	let source_handle = null;
	let destination_handle = null;
	let source_closed = false;
	let destination_closed = false;
	let owned = null;
	let opened_destination = null;
	let id = operation_id(runtime);

	try {
		source_handle = runtime.fs.open(source, 'r', 0);
		let opened_source = source_handle == null ? null : runtime.fs.fstat(source_handle);
		if (!same_identity(source_stat, opened_source))
			fail('INVALID_ARGUMENT');

		for (let attempt = 0; attempt < 16; attempt++) {
			let candidate = temp_path(runtime, destination, id);
			destination_handle = runtime.fs.open(candidate, 'wx', 0o600);
			if (destination_handle != null) {
				owned = candidate;
				opened_destination = runtime.fs.fstat(destination_handle);
				let created = runtime.fs.lstat(owned);
				if (!same_file_object(opened_destination, created) ||
				    created.uid !== 0 || created.gid !== 0 || created.mode != 0o600 ||
				    runtime.fs.realpath(owned) !=
				      canonical_member(destination_directory, owned))
					fail('INTERNAL');
				break;
			}
		}
		if (destination_handle == null)
			fail('INTERNAL');

		let total = 0;
		while (true) {
			let chunk = runtime.fs.read(source_handle, 65536);
			if (type(chunk) != 'string' || length(chunk) > 65536)
				fail('INTERNAL');
			if (!length(chunk))
				break;
			if (total + length(chunk) > source_stat.size)
				fail('INVALID_ARGUMENT');
			let offset = 0;
			while (offset < length(chunk)) {
				let written = runtime.fs.write(destination_handle, substr(chunk, offset));
				if (type(written) != 'int' || written <= 0 ||
				    written > length(chunk) - offset)
					fail('INTERNAL');
				offset += written;
			}
			total += length(chunk);
		}
		if (total != source_stat.size || runtime.fs.flush(destination_handle) != true)
			fail('INTERNAL');
		if (runtime.fs.close(destination_handle) != true)
			fail('INTERNAL');
		destination_closed = true;
		if (runtime.fs.close(source_handle) != true)
			fail('INTERNAL');
		source_closed = true;
		if (runtime.fs.chmod(owned, mode) != true)
			fail('INTERNAL');

		let copied_stat = runtime.fs.lstat(owned);
		if (copied_stat?.type != 'file' || copied_stat.nlink != 1 ||
		    copied_stat.uid !== 0 || copied_stat.gid !== 0 ||
		    copied_stat.size != source_stat.size || copied_stat.mode != mode ||
		    runtime.fs.realpath(owned) != canonical_member(destination_directory, owned) ||
		    runtime.digest.sha256_file(owned) != expected_digest)
			fail('INTERNAL');

		let current_source = runtime.fs.lstat(source);
		let current_source_directory = secure_directory(runtime, source);
		let current_destination_directory = secure_directory(runtime, destination);
		if (!same_identity(source_stat, current_source) ||
		    runtime.fs.realpath(source) != canonical_member(current_source_directory, source) ||
		    runtime.digest.sha256_file(source) != expected_digest ||
		    source_directory.canonical != current_source_directory.canonical ||
		    !same_directory_authority(source_directory.stat, current_source_directory.stat) ||
		    destination_directory.canonical != current_destination_directory.canonical ||
		    !same_directory_authority(destination_directory.stat,
			    current_destination_directory.stat))
			fail('INVALID_ARGUMENT');

		let verified_copy = runtime.fs.lstat(owned);
		if (!same_identity(copied_stat, verified_copy) ||
		    runtime.fs.realpath(owned) != canonical_member(current_destination_directory, owned) ||
		    runtime.digest.sha256_file(owned) != expected_digest)
			fail('INVALID_ARGUMENT');
		if (runtime.fs.rename(owned, destination) != true)
			fail('INTERNAL');

		owned = null;
		return true;
	}
	catch (error) {
		if (destination_handle != null && !destination_closed) {
			try { runtime.fs.close(destination_handle); } catch (close_error) {}
			destination_closed = true;
		}
		if (source_handle != null && !source_closed) {
			try { runtime.fs.close(source_handle); } catch (close_error) {}
			source_closed = true;
		}
		if (owned != null) {
			try {
				let current = runtime.fs.lstat(owned);
				if (same_file_object(opened_destination, current) &&
				    runtime.fs.realpath(owned) ==
				      canonical_member(destination_directory, owned))
					runtime.fs.unlink(owned);
			}
			catch (unlink_error) {}
		}
		let code = error?.code ?? error?.message;
		fail(code == 'INVALID_ARGUMENT' ? 'INVALID_ARGUMENT' : 'INTERNAL');
	}
};

export function atomic_replace(runtime, source, destination) {
	valid_path(source);
	valid_path(destination);
	if (source == destination || type(runtime?.fs) != 'object' ||
	    !owned_temp_name(source, destination))
		fail('INVALID_ARGUMENT');

	let directory = secure_directory(runtime, destination);
	let source_stat = runtime.fs.lstat(source);
	if (source_stat?.type != 'file' || source_stat.nlink != 1 ||
	    runtime.fs.realpath(source) != canonical_member(directory, source))
		fail('INVALID_ARGUMENT');
	let current_stat = runtime.fs.lstat(source);
	let current_directory = secure_directory(runtime, destination);
	if (!same_identity(source_stat, current_stat) ||
	    runtime.fs.realpath(source) != canonical_member(current_directory, source) ||
	    !same_directory_authority(directory.stat, current_directory.stat) ||
	    directory.canonical != current_directory.canonical)
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
	if (!valid_digest(digest))
		fail('INTERNAL');

	return digest;
};

export function cleanup_runtime(runtime) {
	if (type(runtime?.fs) != 'object' || runtime?.paths?.run != '/var/run/miclash' ||
	    runtime?.paths?.tmp != '/tmp/miclash')
		fail('INVALID_ARGUMENT');

	let removed = 0;
	for (let directory in [ runtime.paths.run, runtime.paths.tmp ]) {
		let canonical = runtime.fs.realpath(directory);
		if (runtime.fs.lstat(directory)?.type != 'directory' ||
		    !trusted_root_path(directory, canonical))
			continue;
		for (let name in runtime.fs.lsdir(directory) ?? []) {
			if (!owned_runtime_name(name))
				continue;
			let path = directory + '/' + name;
			if (runtime.fs.lstat(path)?.type == 'file' && runtime.fs.unlink(path) == true)
				removed++;
		}
	}

	return removed;
};
