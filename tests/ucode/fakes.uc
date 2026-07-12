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
	return {
		files,
		readfile: (path) => files[path],
		writefile: (path, data) => files[path] = data,
		exists: (path) => exists(files, path),
		unlink: (path) => delete files[path],
		rename: (from, to) => {
			files[to] = files[from];
			delete files[from];
			return true;
		},
		mkdir: (path) => true,
		stat: (path) => exists(files, path) ? { type: 'file', size: length(files[path]) } : null
	};
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
