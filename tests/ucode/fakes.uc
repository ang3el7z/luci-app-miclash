import { process_result, validate_process_request } from 'miclash.runtime';

function process_key(request) {
	return request.command + ':' + join(' ', request.args ?? []);
};

export function process(replies) {
	let fake = { calls: [] };

	fake.run = (request) => {
		validate_process_request(request);

		push(fake.calls, request);
		let reply = (replies ?? {})[process_key(request)];
		return process_result(reply?.code ?? 0, reply?.stdout, reply?.stderr);
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

export function fs(initial) {
	let files = initial ?? {};
	let directories = { '/': true };
	let modes = {};
	let devices = {};
	let created = [];
	let fake = {
		files,
		fail_on: null,
		corrupt_on_close: false,
		write_results: [],
		calls: { open: [], write: [], flush: [], close: [], chmod: [], rename: [], unlink: [] },
		readfile: (path) => files[path],
		writefile: (path, data) => files[path] = data,
		exists: (path) => exists(files, path),
		mkdir: (path) => directories[path] = true
	};

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

	fake.open = (path, mode, perm) => {
		if (fake.fail_on == 'open' || (index(mode, 'x') >= 0 && exists(files, path)))
			return null;

		files[path] = '';
		modes[path] = perm;
		remember_directories(path);
		push(created, path);
		push(fake.calls.open, { path, mode, perm });
		let offset = 0;
		let handle = { path, closed: false };
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
			return fake.fail_on == 'flush' ? null : true;
		};
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
	fake.flush = (handle) => handle.flush();
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
		delete modes[path];
		return delete files[path];
	};
	fake.rename = (from, to) => {
		push(fake.calls.rename, { from, to });
		if (fake.fail_on == 'rename')
			return null;
		files[to] = files[from];
		modes[to] = modes[from];
		delete files[from];
		delete modes[from];
		return true;
	};
	fake.stat = (path) => {
		if (!exists(files, path) && !exists(directories, path))
			return null;
		let device = devices[path] ?? devices[parent(path)] ?? 1;
		return {
			type: exists(files, path) ? 'file' : 'directory',
			size: exists(files, path) ? length(files[path]) : 0,
			dev: { major: 0, minor: device }
		};
	};
	fake.lsdir = (directory) => {
		let names = [];
		let prefix = directory + '/';
		for (let path in files) {
			if (substr(path, 0, length(prefix)) != prefix)
				continue;
			let name = substr(path, length(prefix));
			if (length(name) && index(name, '/') < 0)
				push(names, name);
		}
		return names;
	};
	fake.mode = (path) => modes[path];
	fake.set_device = (path, device) => devices[path] = device;
	fake.temp_paths = () => created;

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
