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
	fake.set_timeout = (milliseconds, callback) => {
		let timer = { due: current + milliseconds, callback, active: true };
		timer.cancel = () => timer.active = false;
		push(fake.timers, timer);
		return timer;
	};

	return fake;
};

export function entropy() {
	let counter = 0;
	let fake = { calls: [] };
	fake.hex = (bytes) => {
		push(fake.calls, bytes);
		counter++;
		return sprintf('%016x', counter);
	};
	return fake;
};

export function fs(initial) {
	let files = initial ?? {};
	let directories = { '/': true };
	let modes = {};
	let devices = {};
	let inodes = {};
	let links = {};
	let symlinks = {};
	let next_inode = 100;
	let next_fd = 10;
	let created = [];
	let fake = {
		files,
		fail_on: null,
		corrupt_on_close: false,
		collide_next_open: false,
		fail_unlink_once: false,
		on_lstat: null,
		write_results: [],
		calls: {
			open: [], write: [], flush: [], close: [], chmod: [], rename: [], unlink: [],
			readfile: [], rmdir: []
		},
		writefile: (path, data) => files[path] = data,
		exists: (path) => exists(files, path) || exists(symlinks, path),
		mkdir: (path) => directories[path] = true
	};
	fake.readfile = (path) => {
		push(fake.calls.readfile, path);
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
			current = parent(current);
		}
	};

	for (let path in files)
		remember_directories(path);
	for (let path in files)
		inodes[path] = next_inode++;

	function resolve(path) {
		for (let link, target in symlinks)
			if (path == link || substr(path, 0, length(link) + 1) == link + '/')
				return target + substr(path, length(link));
		return path;
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
			dev: { major: 0, minor: device }
		};
	};

	fake.open = (path, mode, perm) => {
		if (fake.collide_next_open) {
			fake.collide_next_open = false;
			return null;
		}
		if (fake.fail_on == 'open' || (index(mode, 'x') >= 0 && fake.exists(path)))
			return null;

		files[path] = '';
		inodes[path] = next_inode++;
		modes[path] = perm;
		remember_directories(path);
		push(created, path);
		push(fake.calls.open, { path, mode, perm });
		let offset = 0;
		let fd = next_fd++;
		let handle = { path, closed: false, last_error: null };
		handle.fileno = () => fd;
		handle.read = (amount) => {
			if (handle.closed)
				return null;
			let data = substr(files[path], offset, amount);
			offset += length(data);
			return data;
		};
		handle.write = (data) => {
			if (handle.closed || fake.fail_on == 'write')
				return null;
			let amount = length(fake.write_results) ? shift(fake.write_results) : length(data);
			if (amount == null)
				return null;
			amount = amount > length(data) ? length(data) : amount;
			files[path] = substr(files[path], 0, offset) + substr(data, 0, amount);
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
			if (fake.corrupt_on_close && length(files[path]))
				files[path] = '!' + substr(files[path], 1);
			return fake.fail_on == 'close' ? null : true;
		};
		return handle;
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
		modes[path] = mode;
		return true;
	};
	fake.unlink = (path) => {
		push(fake.calls.unlink, path);
		if (fake.fail_unlink_once) {
			fake.fail_unlink_once = false;
			return null;
		}
		let actual = exists(symlinks, path) ? path : resolve(path);
		let present = exists(files, actual) || exists(symlinks, actual);
		delete modes[path];
		delete inodes[actual];
		delete files[actual];
		delete symlinks[actual];
		return present;
	};
	fake.rmdir = (path) => {
		push(fake.calls.rmdir, path);
		if (!exists(directories, path) || length(fake.lsdir(path)))
			return null;
		delete directories[path];
		delete inodes[path];
		return true;
	};
	fake.rename = (from, to) => {
		push(fake.calls.rename, { from, to });
		if (fake.fail_on == 'rename')
			return null;
		let actual_from = resolve(from);
		let actual_to = resolve(to);
		files[actual_to] = files[actual_from];
		modes[actual_to] = modes[actual_from];
		inodes[actual_to] = inodes[actual_from];
		delete files[actual_from];
		delete modes[actual_from];
		delete inodes[actual_from];
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
	fake.set_device = (path, device) => devices[path] = device;
	fake.set_nlink = (path, count) => links[path] = count;
	fake.bump_inode = (path) => inodes[resolve(path)] = next_inode++;
	fake.set_symlink = (path, target) => {
		delete files[path];
		symlinks[path] = target;
		inodes[path] = next_inode++;
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
	let values = initial ?? {};
	let fake = {
		values,
		set_calls: 0,
		commit_calls: 0
	};
	fake.get = (config, section, option) => values[config]?.[section]?.[option];
	fake.set = (config, section, option, value) => {
		fake.set_calls++;
		values[config] ??= {};
		values[config][section] ??= {};
		values[config][section][option] = value;
		return true;
	};
	fake.delete = (config, section, option) => delete values[config]?.[section]?.[option];
	fake.commit = (config) => {
		fake.commit_calls++;
		return true;
	};
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
