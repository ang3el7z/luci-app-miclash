import { fail } from 'miclash.errors';

const GENERATION = '.miclash-generation';

function invalid() { fail('INVALID_ARGUMENT'); };
function internal() { fail('INTERNAL'); };

function leaf(value) {
	if (type(value) != 'string' || !length(value) || value == '.' || value == '..' ||
	    index(value, '/') >= 0 || index(value, '\\') >= 0 ||
	    index(value, sprintf('%c', 0)) >= 0)
		invalid();
	return value;
};

function absolute(path) {
	if (type(path) != 'string' || !match(path, /^\/[A-Za-z0-9._\/-]+$/) ||
	    index(path, '//') >= 0)
		invalid();
	for (let part in split(path, '/'))
		if (part == '..' || part == '.') invalid();
	return length(path) > 1 && substr(path, -1) == '/' ? substr(path, 0, -1) : path;
};

function same_file(left, right) {
	return left?.type == 'file' && right?.type == 'file' &&
		left.inode == right.inode && left.dev?.major == right.dev?.major &&
		left.dev?.minor == right.dev?.minor && left.uid == right.uid &&
		left.mode == right.mode && left.nlink == right.nlink && left.size == right.size;
};

function same_directory(left, right) {
	return left?.type == 'directory' && right?.type == 'directory' &&
		left.inode == right.inode && left.dev?.major == right.dev?.major &&
		left.dev?.minor == right.dev?.minor && left.uid == right.uid &&
		left.mode == right.mode && left.generation == right.generation;
};

export function create(runtime) {
	let fs = runtime?.fs;
	if (type(fs?.open) != 'function' || type(fs?.read) != 'function' ||
	    type(fs?.fstat) != 'function' || type(fs?.write) != 'function' ||
	    type(fs?.flush) != 'function' || type(fs?.close) != 'function' ||
	    type(fs?.readfile) != 'function' || type(fs?.stat) != 'function' ||
	    type(fs?.lstat) != 'function' || type(fs?.realpath) != 'function' ||
	    type(fs?.mkdir) != 'function' || type(fs?.rmdir) != 'function' ||
	    type(fs?.lsdir) != 'function' || type(fs?.chmod) != 'function' ||
	    type(fs?.unlink) != 'function' || type(fs?.rename) != 'function' ||
	    type(runtime?.random?.hex) != 'function' || type(runtime?.digest?.sha256) != 'function')
		invalid();

	let active_lease = null;

	function ensure_lease(lease) {
		if (lease !== active_lease || type(lease) != 'object') invalid();
	};

	function file_identity(stat) {
		if (stat?.type != 'file') return null;
		return { type: 'file', inode: stat.inode, dev: stat.dev, uid: stat.uid,
			mode: stat.mode, nlink: stat.nlink, size: stat.size };
	};

	function generation(path) {
		let generation_path = path + '/' + GENERATION;
		let value = fs.readfile(generation_path);
		if (value == null) {
			value = runtime.random.hex(32);
			if (type(value) != 'string' || !match(value, /^[0-9a-f]{64}$/)) internal();
			let handle = fs.open(generation_path, 'wx', 0o400);
			if (handle == null) {
				value = fs.readfile(generation_path);
			}
			else {
				let failure = false;
				try {
					if (fs.write(handle, value) != length(value) || fs.flush(handle) !== true)
						failure = true;
				}
				catch (error) { failure = true; }
				try { if (fs.close(handle) !== true) failure = true; }
				catch (error) { failure = true; }
				if (failure) { try { fs.unlink(generation_path); } catch (error) {} internal(); }
			}
		}
		let stat = fs.lstat(generation_path);
		if (type(value) != 'string' || !match(value, /^[0-9a-f]{64}$/) ||
		    stat?.type != 'file' || stat.uid != 0 || stat.mode != 0o400 || stat.nlink != 1 ||
		    stat.size != 64)
			internal();
		return value;
	};

	function directory_identity(path) {
		let stat = fs.lstat(path);
		if (stat?.type != 'directory') return null;
		return { type: 'directory', inode: stat.inode, dev: stat.dev, uid: stat.uid,
			mode: stat.mode, generation: generation(path) };
	};

	function verify_directory(handle, lease) {
		ensure_lease(lease);
		if (type(handle) != 'object' || type(handle.path) != 'string') invalid();
		let current = directory_identity(handle.path);
		if (!same_directory(current, handle.identity)) internal();
		return current;
	};

	function ensure_directory(path, options) {
		path = absolute(path);
		if (options?.uid != 0 || options?.mode != 0o700 || type(options?.create) != 'bool') invalid();
		let current = fs.lstat(path);
		if (current == null && options.create) {
			let parent = substr(path, 0, rindex(path, '/')) || '/';
			if (parent != '/' && fs.lstat(parent) == null)
				ensure_directory(parent, { create: true, mode: 0o700, uid: 0 });
			let parent_stat = fs.lstat(parent);
			if (parent_stat?.type != 'directory' || fs.realpath(parent) != parent) internal();
			if (fs.mkdir(path) !== true && fs.lstat(path) == null) internal();
			if (fs.chmod(path, options.mode) !== true) internal();
			current = fs.lstat(path);
		}
		if (current?.type != 'directory' || current.uid != options.uid || current.mode != options.mode)
			internal();
		let canonical = fs.realpath(path);
		if (canonical != path) internal();
		return { path, identity: directory_identity(path) };
	};

	function child_path(directory, name, lease) {
		verify_directory(directory, lease);
		return directory.path + '/' + leaf(name);
	};

	function stat_at(directory, name, lease) {
		let path = child_path(directory, name, lease);
		let stat = fs.lstat(path);
		if (stat == null) return null;
		if (stat.type == 'file') return file_identity(stat);
		if (stat.type == 'directory') return directory_identity(path);
		internal();
	};

	function write_complete(path, content, mode) {
		let handle = fs.open(path, 'wx', mode);
		if (handle == null) internal();
		let failure = false, offset = 0;
		try {
			while (offset < length(content)) {
				let written = fs.write(handle, substr(content, offset));
				if (type(written) != 'int' || written < 1) { failure = true; break; }
				offset += written;
			}
			if (!failure && fs.flush(handle) !== true) failure = true;
		}
		catch (error) { failure = true; }
		try { if (fs.close(handle) !== true) failure = true; }
		catch (error) { failure = true; }
		if (failure) { try { fs.unlink(path); } catch (error) {} internal(); }
		let identity = file_identity(fs.lstat(path));
		if (identity?.uid != 0 || identity.mode != mode || identity.nlink != 1 ||
		    identity.size != length(content)) internal();
		return identity;
	};

	function temp_path(directory, lease) {
		verify_directory(directory, lease);
		for (let attempt = 0; attempt < 16; attempt++) {
			let name = '.tmp-' + runtime.random.hex(16);
			let path = directory.path + '/' + name;
			if (fs.lstat(path) == null) return path;
		}
		internal();
	};

	function create_exclusive(directory, name, content, options, lease) {
		if (type(content) != 'string' || options?.uid != 0 || type(options?.mode) != 'int') invalid();
		let destination = child_path(directory, name, lease);
		if (fs.lstat(destination) != null) fail('BUSY');
		let temporary = temp_path(directory, lease), identity;
		try {
			write_complete(temporary, content, options.mode);
			if (fs.lstat(destination) != null || fs.rename(temporary, destination) !== true) internal();
			identity = file_identity(fs.lstat(destination));
		}
		catch (error) {
			try { if (fs.lstat(temporary) != null) fs.unlink(temporary); } catch (cleanup) {}
			fail(error?.code ?? error?.message ?? 'INTERNAL');
		}
		return identity;
	};

	function replace_atomic(directory, name, expected, content, options, lease) {
		if (type(content) != 'string' || options?.uid != 0 || options?.nlink != 1 ||
		    type(options?.mode) != 'int') invalid();
		let destination = child_path(directory, name, lease);
		let current = file_identity(fs.lstat(destination));
		if (expected == null ? current != null : !same_file(current, expected)) fail('BUSY');
		let temporary = temp_path(directory, lease), identity;
		try {
			write_complete(temporary, content, options.mode);
			current = file_identity(fs.lstat(destination));
			if (expected == null ? current != null : !same_file(current, expected)) fail('BUSY');
			if (fs.rename(temporary, destination) !== true) internal();
			identity = file_identity(fs.lstat(destination));
		}
		catch (error) {
			try { if (fs.lstat(temporary) != null) fs.unlink(temporary); } catch (cleanup) {}
			fail(error?.code ?? error?.message ?? 'INTERNAL');
		}
		return identity;
	};

	let capability = {
		with_transaction_lease: (callback) => {
			if (type(callback) != 'function') invalid();
			if (active_lease != null) fail('BUSY');
			let lease = { nonce: runtime.random.hex(16) };
			active_lease = lease;
			let result, failure = null;
			try { result = callback(lease); }
			catch (error) { failure = error?.code ?? error?.message ?? 'INTERNAL'; }
			active_lease = null;
			if (failure != null) fail(failure);
			return result;
		},
		open: (path, options, lease) => {
			ensure_lease(lease);
			return ensure_directory(path, options);
		},
		open_at: (directory, name, options, lease) => {
			let path = child_path(directory, name, lease);
			let opened = ensure_directory(path, options);
			if (options.expected != null && !same_directory(opened.identity, options.expected)) internal();
			return opened;
		},
		stat: stat_at,
		list: (directory, lease) => {
			verify_directory(directory, lease);
			let result = [];
			for (let name in fs.lsdir(directory.path) ?? [])
				if (name != GENERATION) push(result, name);
			return result;
		},
		read: (directory, name, options, lease) => {
			let path = child_path(directory, name, lease);
			let before = file_identity(fs.lstat(path));
			if (before == null || before.uid != options?.uid || before.mode != options?.mode ||
			    before.nlink != options?.nlink || (options.expected != null &&
			    !same_file(before, options.expected))) internal();
			let content = fs.readfile(path);
			let after = file_identity(fs.lstat(path));
			if (type(content) != 'string' || length(content) > options.maximum ||
			    !same_file(before, after) || after.size != length(content)) internal();
			return { content, identity: after };
		},
		create_exclusive,
		replace_atomic,
		rename_noreplace: (directory, from, to, expected, options, lease) => {
			let source = child_path(directory, from, lease), destination = child_path(directory, to, lease);
			let current = file_identity(fs.lstat(source));
			if (!same_file(current, expected) || current.uid != options?.uid ||
			    current.mode != options?.mode || current.nlink != options?.nlink ||
			    fs.lstat(destination) != null) internal();
			if (fs.rename(source, destination) !== true) internal();
			let moved = file_identity(fs.lstat(destination));
			if (!same_file(moved, current)) internal();
			return moved;
		},
		unlink_durable: (directory, name, expected, lease) => {
			let path = child_path(directory, name, lease);
			if (!same_file(file_identity(fs.lstat(path)), expected) || fs.unlink(path) !== true) internal();
			return true;
		},
		rmdir_durable: (directory, name, expected, lease) => {
			let path = child_path(directory, name, lease);
			let current = directory_identity(path);
			if (!same_directory(current, expected)) internal();
			if (fs.lsdir(path)?.filter((item) => item != GENERATION)?.length) internal();
			if (fs.unlink(path + '/' + GENERATION) !== true || fs.rmdir(path) !== true) internal();
			return true;
		},
		open_reader: (directory, name, options, lease) => {
			let path = child_path(directory, name, lease), expected = stat_at(directory, name, lease);
			if (expected?.type != 'file' || expected.uid != options?.uid ||
			    expected.mode != options?.mode || expected.nlink != options?.nlink ||
			    (options.expected != null && !same_file(expected, options.expected))) internal();
			let handle = fs.open(path, 'r'), closed = false, total = 0;
			if (handle == null || !same_file(file_identity(fs.fstat(handle)), expected)) internal();
			return {
				size: expected.size,
				read: (maximum) => {
					if (closed || type(maximum) != 'int' || maximum < 1) invalid();
					let chunk = fs.read(handle, maximum) ?? '';
					total += length(chunk);
					if (total > options.maximum) internal();
					return chunk;
				},
				finish: () => {
					if (closed || total != expected.size) internal();
					closed = true;
					if (fs.close(handle) !== true || !same_file(stat_at(directory, name, lease), expected)) internal();
					return expected;
				},
				close: () => { if (closed) return false; closed = true; fs.close(handle); return true; }
			};
		}
	};

	return capability;
};
