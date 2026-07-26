import { process_result, validate_process_request } from 'miclash.runtime';
import { sha256 } from 'digest';

function process_key(request) {
	return request.command + ':' + join(' ', request.args ?? []);
};

export function process(replies) {
	let fake = { calls: [], replies: replies ?? {}, on_run: null };

	fake.run = (request) => {
		validate_process_request(request);

		push(fake.calls, request);
		if (type(fake.on_run) == 'function')
			fake.on_run(request);
		let reply = fake.replies[process_key(request)];
		return process_result(reply?.code ?? 0, null, null);
	};

	return fake;
};

export function clock(start) {
	let current = start ?? 0;
	let fake = { timers: [] };

	fake.now = () => current;
	fake.advance = (milliseconds) => {
		current += milliseconds;
		for (let timer in fake.timers) {
			if (timer.active && timer.due <= current) {
				timer.active = false;
				timer.callback();
			}
		}
		return current;
	};
	fake.sleep = fake.advance;
	function arm(milliseconds, callback) {
		let timer = { due: current + milliseconds, callback, active: true };
		timer.cancel = () => timer.active = false;
		push(fake.timers, timer);
		return timer;
	};
	fake.set_timeout = arm;
	// Production exposes a separately bound uloop timer as a bounded scheduler
	// fallback. Tests may fault only the primary binding and prove rearming.
	fake.set_fallback_timeout = arm;

	return fake;
};

export function entropy() {
	let counter = 0;
	let fake = { calls: [] };
	fake.hex = (bytes) => {
		push(fake.calls, bytes);
		counter++;
		let value = sprintf('%064x', counter);
		return substr(value, length(value) - bytes * 2);
	};
	return fake;
};

export function fs(initial) {
	let files = initial ?? {};
	let directories = { '/': true };
	let modes = {};
	let owners = {};
	let groups = {};
	let devices = {};
	let inodes = {};
	let mtimes = {};
	let links = {};
	let symlinks = {};
	let object_generations = { '/': 1 };
	let generation_paths = { '1': '/' };
	let directory_owners = {};
	let next_object_generation = 2;
	let next_directory_owner = 1;
	let next_inode = 100;
	let next_fd = 10;
	let created = [];
	let fake = {
		files,
		fail_on: null,
		fail_open_once_matching: null,
		fail_open_matching_count: 0,
		corrupt_on_close: false,
		collide_next_open: false,
		fail_unlink_once: false,
		fail_unlink_once_matching: null,
		fail_rename_once: false,
		fail_rename_once_to: null,
		throw_after_rename_once_to: null,
		throw_after_rename_once_matching: null,
		fail_rmdir_once: false,
		ignore_chmod: false,
		on_readfile: null,
		on_lstat: null,
		on_link: null,
		on_mkdir: null,
		on_rename: null,
		read_results: [],
		write_results: [],
		calls: {
			open: [], write: [], flush: [], close: [], chmod: [], rename: [], unlink: [],
			link: [], read: [], readfile: [], fstat: [], rmdir: []
		},
		writefile: null,
		exists: (path) => exists(files, path) || exists(symlinks, path),
		mkdir: null
	};
	fake.mkdir = (path) => {
		if (exists(files, path) || exists(directories, path) || exists(symlinks, path)) return null;
		directories[path] = true;
		let generation = next_object_generation++;
		object_generations[path] = generation;
		generation_paths[sprintf('%d', generation)] = path;
		inodes[path] = next_inode++;
		mtimes[path] = 0;
		if (type(fake.on_mkdir) == 'function') fake.on_mkdir(path);
		return true;
	};
	fake.readfile = (path) => {
		push(fake.calls.readfile, path);
		if (type(fake.on_readfile) == 'function')
			fake.on_readfile(path);
		return files[path];
	};
	fake.read = (handle, amount) => handle.read(amount);

	function parent(path) {
		let parts = split(path, '/');
		pop(parts);
		let value = join('/', parts);
		return length(value) ? value : '/';
	};

	function remember_directories(path) {
		let current = parent(path);
		while (current != '/') {
			directories[current] = true;
			if (object_generations[current] == null) {
				let generation = next_object_generation++;
				object_generations[current] = generation;
				generation_paths[sprintf('%d', generation)] = current;
			}
			current = parent(current);
		}
	};

	for (let path in files)
		remember_directories(path);
	for (let path in files) {
		inodes[path] = next_inode++;
		let generation = next_object_generation++;
		object_generations[path] = generation;
		generation_paths[sprintf('%d', generation)] = path;
	}

	function resolve(path) {
		for (let link, target in symlinks)
			if (path == link || substr(path, 0, length(link) + 1) == link + '/')
				return target + substr(path, length(link));
		return path;
	};

	function set_inode_value(values, path, value) {
		let resolved = resolve(path), inode = inodes[resolved];
		if (inode == null || !exists(files, resolved)) {
			values[resolved] = value;
			return;
		}
		for (let peer in files)
			if (inodes[peer] == inode)
				values[peer] = value;
	};

	fake.writefile = (path, data) => {
		let resolved = resolve(path), inode = inodes[resolved];
		if (inode == null) {
			files[resolved] = data;
			remember_directories(resolved);
			return;
		}
		for (let peer in files)
			if (inodes[peer] == inode)
				files[peer] = data;
	};

	function info(path, follow) {
		if (!follow && exists(symlinks, path))
			return {
				type: 'link', size: length(symlinks[path]), inode: inodes[path], nlink: 1,
				dev: { major: 0, minor: devices[path] ?? 1 }
			};
		let resolved = resolve(path);
		if (!exists(files, resolved) && !exists(directories, resolved))
			return null;
		let device = devices[path] ?? devices[resolved] ?? devices[parent(resolved)] ?? 1;
		return {
			type: exists(files, resolved) ? 'file' : 'directory',
			size: exists(files, resolved) ? length(files[resolved]) : 0,
			inode: inodes[resolved] ?? (inodes[resolved] = next_inode++),
			nlink: links[path] ?? 1,
			uid: owners[path] ?? owners[resolved] ?? 0,
			gid: groups[path] ?? groups[resolved] ?? 0,
			mode: modes[path] ?? modes[resolved] ?? (exists(files, resolved) ? 0o600 :
				(index([ '/etc/miclash', '/tmp/miclash', '/var/run/miclash' ], resolved) >= 0
					? 0o700 : 0o755)),
			mtime: mtimes[path] ?? mtimes[resolved] ?? 0,
			dev: { major: 0, minor: device }
		};
	};

	fake.open = (path, mode, perm) => {
		if (fake.fail_open_matching_count > 0 &&
		    index(path, fake.fail_open_once_matching) >= 0) {
			fake.fail_open_matching_count--;
			return null;
		}
		if (fake.fail_open_once_matching != null &&
		    index(path, fake.fail_open_once_matching) >= 0) {
			fake.fail_open_once_matching = null;
			return null;
		}
		if (fake.collide_next_open) {
			fake.collide_next_open = false;
			return null;
		}
		if (fake.fail_on == 'open' || (index(mode, 'x') >= 0 && fake.exists(path)) ||
		    (substr(mode, 0, 1) == 'r' && !fake.exists(path)))
			return null;

		let actual_path = resolve(path);
		if (substr(mode, 0, 1) != 'r') {
			if (exists(files, actual_path))
				fake.writefile(actual_path, '');
			else {
				files[actual_path] = '';
				inodes[actual_path] = next_inode++;
				modes[actual_path] = perm;
				remember_directories(actual_path);
				push(created, actual_path);
			}
		}
		push(fake.calls.open, { path, mode, perm });
		let offset = 0;
		let fd = next_fd++;
		let opened_path = actual_path, opened_inode = info(actual_path, true)?.inode;
		let handle = { path, opened_path, opened_inode, closed: false, last_error: null };
		handle.fileno = () => fd;
		handle.read = (amount) => {
			if (handle.closed || fake.fail_on == 'read')
				return null;
			if (length(fake.read_results)) {
				let requested = shift(fake.read_results);
				if (requested == null)
					return null;
				amount = requested;
			}
			let data = substr(files[handle.opened_path], offset, amount);
			offset += length(data);
			push(fake.calls.read, { path, amount: length(data) });
			return data;
		};
		handle.write = (data) => {
			if (handle.closed || fake.fail_on == 'write')
				return null;
			let amount = length(fake.write_results) ? shift(fake.write_results) : length(data);
			if (amount == null)
				return null;
			amount = amount > length(data) ? length(data) : amount;
			fake.writefile(opened_path,
				substr(files[opened_path], 0, offset) + substr(data, 0, amount));
			offset += amount;
			push(fake.calls.write, { path, amount });
			return amount;
		};
		handle.flush = () => {
			push(fake.calls.flush, path);
			if (fake.fail_on == 'flush') {
				handle.last_error = 'I/O error';
				return true;
			}
			handle.last_error = null;
			return null;
		};
		handle.error = () => handle.last_error;
		handle.close = () => {
			push(fake.calls.close, path);
			handle.closed = true;
			if (fake.corrupt_on_close && length(files[opened_path]))
				fake.writefile(opened_path, '!' + substr(files[opened_path], 1));
			return fake.fail_on == 'close' ? null : true;
		};
		return handle;
	};
	fake.fstat = (handle) => {
		push(fake.calls.fstat, handle.path);
		let value = info(handle.opened_path, true);
		if (value != null) value.inode = handle.opened_inode;
		return value;
	};
	fake.write = (handle, data) => handle.write(data);
	fake.flush = (handle) => {
		let flushed = handle.flush();
		return flushed == null;
	};
	fake.close = (handle) => handle.close();
	fake.chmod = (path, mode) => {
		push(fake.calls.chmod, { path, mode });
		if (fake.fail_on == 'chmod')
			return null;
		if (!fake.ignore_chmod)
			set_inode_value(modes, path, mode);
		return true;
	};
	fake.link = (from, to) => {
		push(fake.calls.link, { from, to });
		let source = resolve(from);
		let source_info = info(source, true), parent_info = info(parent(to), true);
		if (!exists(files, source) || fake.exists(to) || fake.fail_on == 'link' ||
		    source_info?.dev?.major != parent_info?.dev?.major ||
		    source_info?.dev?.minor != parent_info?.dev?.minor)
			return null;
		files[to] = files[source];
		modes[to] = modes[source];
		owners[to] = owners[source];
		groups[to] = groups[source];
		devices[to] = source_info.dev.minor;
		inodes[to] = inodes[source];
		let count = (links[source] ?? 1) + 1;
		for (let path in files)
			if (inodes[path] == inodes[source])
				links[path] = count;
		remember_directories(to);
		let generation = next_object_generation++;
		object_generations[to] = generation;
		generation_paths[sprintf('%d', generation)] = to;
		if (type(fake.on_link) == 'function') fake.on_link(from, to);
		return true;
	};
	function drop_file_entry(path) {
		let inode = inodes[path], count = links[path] ?? 1;
		if (count > 1)
			for (let peer in files)
				if (peer != path && inodes[peer] == inode)
					links[peer] = count - 1;
		delete links[path];
		delete modes[path];
		delete owners[path];
		delete groups[path];
		delete devices[path];
		delete inodes[path];
		delete generation_paths[sprintf('%d', object_generations[path])];
		delete object_generations[path];
		delete files[path];
	};
	fake.unlink = (path) => {
		push(fake.calls.unlink, path);
		if (fake.fail_unlink_once_matching != null &&
		    index(path, fake.fail_unlink_once_matching) >= 0) {
			fake.fail_unlink_once_matching = null;
			return null;
		}
		if (fake.fail_unlink_once) {
			fake.fail_unlink_once = false;
			return null;
		}
		let actual = exists(symlinks, path) ? path : resolve(path);
		let present = exists(files, actual) || exists(symlinks, actual);
		if (exists(files, actual))
			drop_file_entry(actual);
		else {
			delete modes[path];
			delete inodes[actual];
			delete generation_paths[sprintf('%d', object_generations[actual])];
			delete object_generations[actual];
			delete symlinks[actual];
		}
		return present;
	};
	fake.rmdir = (path) => {
		push(fake.calls.rmdir, path);
		if (fake.fail_rmdir_once) {
			fake.fail_rmdir_once = false;
			return null;
		}
		if (fake.fail_on == 'rmdir')
			return null;
		if (!exists(directories, path) || length(fake.lsdir(path)))
			return null;
		delete directories[path];
		delete inodes[path];
		delete mtimes[path];
		delete modes[path];
		delete generation_paths[sprintf('%d', object_generations[path])];
		delete object_generations[path];
		delete directory_owners[path];
		return true;
	};
	fake.rename = (from, to) => {
		push(fake.calls.rename, { from, to });
		if (fake.fail_rename_once_to != null && to == fake.fail_rename_once_to) {
			fake.fail_rename_once_to = null;
			return null;
		}
		if (fake.fail_rename_once) {
			fake.fail_rename_once = false;
			return null;
		}
		if (fake.fail_on == 'rename')
			return null;
		if (exists(directories, from)) {
			if (exists(files, to) || exists(directories, to) || exists(symlinks, to)) return null;
			let mappings = [ directories, files, modes, owners, groups, devices, inodes, links, mtimes,
				object_generations, directory_owners ];
			for (let values in mappings) {
				let moved = {};
				for (let path, value in values)
					if (path == from || substr(path, 0, length(from) + 1) == from + '/')
						moved[to + substr(path, length(from))] = value;
				for (let path in values)
					if (path == from || substr(path, 0, length(from) + 1) == from + '/')
						delete values[path];
				for (let path, value in moved) values[path] = value;
			}
			for (let path, generation in object_generations)
				generation_paths[sprintf('%d', generation)] = path;
			if (type(fake.on_rename) == 'function') fake.on_rename(from, to);
			if (fake.throw_after_rename_once_matching != null &&
			    index(to, fake.throw_after_rename_once_matching) >= 0) {
				fake.throw_after_rename_once_matching = null;
				die('INTERNAL');
			}
			return true;
		}
		let actual_from = resolve(from);
		let actual_to = resolve(to);
		if (!exists(files, actual_from))
			return null;
		if (exists(files, actual_to) &&
		    inodes[actual_from] == inodes[actual_to]) {
			if (type(fake.on_rename) == 'function') fake.on_rename(from, to);
			if (fake.throw_after_rename_once_matching != null &&
			    index(to, fake.throw_after_rename_once_matching) >= 0) {
				fake.throw_after_rename_once_matching = null;
				die('INTERNAL');
			}
			if (fake.throw_after_rename_once_to != null &&
			    to == fake.throw_after_rename_once_to) {
				fake.throw_after_rename_once_to = null;
				die('INTERNAL');
			}
			return true;
		}
		if (exists(files, actual_to))
			drop_file_entry(actual_to);
		files[actual_to] = files[actual_from];
		modes[actual_to] = modes[actual_from];
		owners[actual_to] = owners[actual_from];
		groups[actual_to] = groups[actual_from];
		devices[actual_to] = devices[actual_from];
		inodes[actual_to] = inodes[actual_from];
		links[actual_to] = links[actual_from];
		object_generations[actual_to] = object_generations[actual_from];
		generation_paths[sprintf('%d', object_generations[actual_to])] = actual_to;
		delete files[actual_from];
		delete modes[actual_from];
		delete owners[actual_from];
		delete groups[actual_from];
		delete devices[actual_from];
		delete inodes[actual_from];
		delete links[actual_from];
		delete object_generations[actual_from];
		if (type(fake.on_rename) == 'function') fake.on_rename(from, to);
		if (fake.throw_after_rename_once_matching != null &&
		    index(to, fake.throw_after_rename_once_matching) >= 0) {
			fake.throw_after_rename_once_matching = null;
			die('INTERNAL');
		}
		if (fake.throw_after_rename_once_to != null &&
		    to == fake.throw_after_rename_once_to) {
			fake.throw_after_rename_once_to = null;
			die('INTERNAL');
		}
		return true;
	};
	fake.stat = (path) => info(path, true);
	let lstat_counts = {};
	fake.lstat = (path) => {
		lstat_counts[path] = (lstat_counts[path] ?? 0) + 1;
		if (type(fake.on_lstat) == 'function')
			fake.on_lstat(path, lstat_counts[path]);
		return info(path, false);
	};
	fake.realpath = (path) => {
		let resolved = resolve(path);
		return info(path, true) != null ? resolved : null;
	};
	fake.lsdir = (directory) => {
		let names = [];
		let prefix = resolve(directory) + '/';
		for (let path in { ...directories, ...files, ...symlinks }) {
			if (substr(path, 0, length(prefix)) != prefix)
				continue;
			let name = substr(path, length(prefix));
			if (length(name) && index(name, '/') < 0 && index(names, name) < 0)
				push(names, name);
		}
		return names;
	};
	fake.mode = (path) => modes[path];
	fake.set_device = (path, device) => set_inode_value(devices, path, device);
	fake.set_nlink = (path, count) => links[path] = count;
	fake.set_uid = (path, uid) => set_inode_value(owners, path, uid);
	fake.set_gid = (path, gid) => set_inode_value(groups, path, gid);
	fake.set_mode = (path, mode) => set_inode_value(modes, path, mode);
	fake.set_mtime = (path, mtime) => mtimes[path] = mtime;
	fake.bump_inode = (path) => {
		let resolved = resolve(path);
		let old_inode = inodes[resolved], count = links[resolved] ?? 1;
		if (count > 1)
			for (let peer in files)
				if (peer != resolved && inodes[peer] == old_inode)
					links[peer] = count - 1;
		inodes[resolved] = next_inode++;
		links[resolved] = 1;
		if (object_generations[resolved] == null) {
			let generation = next_object_generation++;
			object_generations[resolved] = generation;
			generation_paths[sprintf('%d', generation)] = resolved;
		}
	};
	fake.set_inode = (path, inode) => inodes[resolve(path)] = inode;
	fake.object_generation = (path) => object_generations[resolve(path)];
	fake.path_for_object_generation = (generation) =>
		generation_paths[sprintf('%d', generation)] ?? null;
	fake.claim_directory_owner = (path) => {
		let resolved = resolve(path);
		if (!exists(directories, resolved)) return null;
		if (directory_owners[resolved] == null)
			directory_owners[resolved] = sprintf('%064x', next_directory_owner++);
		return directory_owners[resolved];
	};
	fake.directory_owner = (path) => directory_owners[resolve(path)];
	fake.set_symlink = (path, target) => {
		if (object_generations[path] != null)
			delete generation_paths[sprintf('%d', object_generations[path])];
		delete files[path];
		delete directories[path];
		delete directory_owners[path];
		symlinks[path] = target;
		inodes[path] = next_inode++;
		let generation = next_object_generation++;
		object_generations[path] = generation;
		generation_paths[sprintf('%d', generation)] = path;
		remember_directories(path);
		return true;
	};
	fake.temp_paths = () => created;

	return fake;
};

export function digest(fs) {
	let fake = { calls: { data: [], file: [] } };
	fake.sha256 = (data) => {
		push(fake.calls.data, length(data));
		return sha256(data);
	};
	fake.sha256_file = (path) => {
		push(fake.calls.file, path);
		let data = fs.files[path];
		return type(data) == 'string' ? sha256(data) : null;
	};
	return fake;
};

export function uci(initial) {
	function clone(value) {
		return value == null ? value : json(sprintf('%J', value));
	};
	let committed = clone(initial ?? {}), fake = {
		values: committed,
		set_calls: 0,
		commit_calls: 0,
		cursor_calls: 0,
		fail_set_at: null,
		reject_empty_lists: false,
		fail_commit: false,
		on_cursor: null,
		pending_changes: {},
		calls: []
	};

	function make_cursor() {
		let values = clone(committed), dirty = {};
		let cursor = {};
		cursor.get = (config, section, option) => clone(values[config]?.[section]?.[option]);
		cursor.get_first = (config, section_type) => {
			for (let name, section in values[config] ?? {})
				if (section?.['.type'] == section_type)
					return name;
			return null;
		};
		cursor.get_all = (config, section) => {
			if (section == null) return clone(values[config]);
			let value = clone(values[config]?.[section]);
			if (value != null) value['.name'] ??= section;
			return value;
		};
		cursor.set = (config, section, option, value) => {
			fake.set_calls++;
			push(fake.calls, { operation: 'set', config, section, option, value: clone(value) });
			if (fake.fail_set_at == fake.set_calls) return null;
			if (fake.reject_empty_lists && type(value) == 'array' && !length(value)) return null;
			values[config] ??= {};
			if (value == null) {
				if (type(option) != 'string' || !length(option) ||
				    !match(section, /^[A-Za-z0-9_]+$/)) return null;
				values[config][section] = { '.type': option };
				dirty[config] = true;
				return true;
			}
			if (option == '.type' || values[config][section] == null) return null;
			values[config][section][option] = clone(value);
			dirty[config] = true;
			return true;
		};
		cursor.delete = (config, section, option) => {
			push(fake.calls, { operation: 'delete', config, section, option });
			if (values[config]?.[section] == null)
				return false;
			if (option == null) {
				delete values[config][section];
				dirty[config] = true;
				return true;
			}
			if (option == '.type' || !exists(values[config][section], option)) return false;
			delete values[config][section][option];
			dirty[config] = true;
			return true;
		};
		cursor.changes = (config) => {
			if (fake.pending_changes[config] != null) return clone(fake.pending_changes[config]);
			return dirty[config] ? { pending: true } : {};
		};
		cursor.revert = (config) => {
			push(fake.calls, { operation: 'revert', config });
			values[config] = clone(committed[config]);
			delete dirty[config];
			return true;
		};
		cursor.commit = (config) => {
			fake.commit_calls++;
			push(fake.calls, { operation: 'commit', config });
			if (fake.fail_commit) return null;
			committed[config] = clone(values[config]);
			fake.values = committed;
			delete dirty[config];
			return true;
		};
		return cursor;
	};

	fake.cursor = () => {
		fake.cursor_calls++;
		if (type(fake.on_cursor) == 'function') fake.on_cursor(fake.cursor_calls);
		return make_cursor();
	};
	let default_cursor = make_cursor();
	fake.get = (config, section, option) => default_cursor.get(config, section, option);
	fake.get_first = (config, section_type) => default_cursor.get_first(config, section_type);
	fake.get_all = (config, section) => default_cursor.get_all(config, section);
	fake.set = (config, section, option, value) => default_cursor.set(config, section, option, value);
	fake.delete = (config, section, option) => default_cursor.delete(config, section, option);
	fake.changes = (config) => default_cursor.changes(config);
	fake.revert = (config) => default_cursor.revert(config);
	fake.commit = (config) => default_cursor.commit(config);
	return fake;
};

export function events() {
	let collector = { items: [] };
	collector.emit = (type, data) => push(collector.items, { type, data });
	collector.logger = {
		debug: (message) => collector.emit('debug', message),
		info: (message) => collector.emit('info', message),
		warn: (message) => collector.emit('warn', message),
		error: (message) => collector.emit('error', message)
	};
	return collector;
};
