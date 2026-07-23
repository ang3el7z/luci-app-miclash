import * as errors from 'miclash.errors';

const MAX_JSON_BYTES = 786432;

function fail() { errors.fail('INTERNAL'); };

function write_all(runtime, handle, value) {
	let offset = 0;
	while (offset < length(value)) {
		let written = runtime.fs.write(handle, substr(value, offset));
		if (type(written) != 'int' || written < 1 || written > length(value) - offset)
			fail();
		offset += written;
	}
};

export function create(runtime, target) {
	let handle = target?.resource ?? target;
	let path = target?.path ?? handle?.path;
	let abort_target = target?.resource != null ? target : handle;
	if (type(runtime?.fs?.write) != 'function' || type(runtime?.fs?.flush) != 'function' ||
		type(runtime?.fs?.close) != 'function' || type(runtime?.fs?.fstat) != 'function' ||
		type(runtime?.fs?.lstat) != 'function' || type(runtime?.fs?.realpath) != 'function' ||
		type(runtime?.digest?.sha256_file) != 'function' ||
		(type(handle) != 'object' && type(handle) != 'resource') ||
		type(path) != 'string' || !length(path))
		errors.fail('INVALID_ARGUMENT');

	let stack = [], closed = false, bytes = 0, roots = 0, aborted = false;
	function abort() {
		if (aborted) return;
		aborted = true;
		try {
			if (type(abort_target?.abort) == 'function')
				abort_target.abort();
		}
		catch (error) {}
	};
	function terminal() {
		if (!closed) {
			try { runtime.fs.close(handle); } catch (error) {}
			closed = true;
		}
		abort();
		fail();
	};
	function write(value) {
		if (closed || type(value) != 'string' || bytes + length(value) > MAX_JSON_BYTES) terminal();
		try { write_all(runtime, handle, value); }
		catch (error) { terminal(); }
		bytes += length(value);
	};
	function separator(container) {
		if (container.count++) write(',');
	};
	function object_member(name) {
		let container = stack[length(stack) - 1];
		if (container?.kind != 'object' || type(name) != 'string') terminal();
		separator(container);
		write(sprintf('%J', name) + ':');
	};
	function array_value() {
		let container = stack[length(stack) - 1];
		if (container?.kind != 'array') terminal();
		separator(container);
	};
	function close(kind, token) {
		let container = pop(stack);
		if (container?.kind != kind) terminal();
		write(token);
	};
	return {
		begin_object: () => {
			if (length(stack)) array_value();
			else if (roots++) terminal();
			write('{'); push(stack, { kind: 'object', count: 0 });
		},
		begin_object_field: (name) => {
			object_member(name); write('{'); push(stack, { kind: 'object', count: 0 });
		},
		field: (name, value) => {
			object_member(name); write(sprintf('%J', value));
		},
		begin_array_field: (name) => {
			object_member(name); write('['); push(stack, { kind: 'array', count: 0 });
		},
		item: (value) => { array_value(); write(sprintf('%J', value)); },
		end_array: () => close('array', ']'),
		end_object: () => close('object', '}'),
		finish: () => {
			if (closed || length(stack) || roots != 1) terminal();
			try {
				let before = runtime.fs.fstat(handle);
				if (runtime.fs.flush(handle) !== true) terminal();
				let close_result = runtime.fs.close(handle);
				closed = true;
				if (close_result !== true) { abort(); fail(); }
				let after = runtime.fs.lstat(path);
				if (before?.type != 'file' || after?.type != 'file' ||
					before.inode != after.inode || after.size != bytes ||
					runtime.fs.realpath(path) != path) { abort(); fail(); }
				let sha256 = runtime.digest.sha256_file(path);
				let verified = runtime.fs.lstat(path);
				if (type(sha256) != 'string' || !match(sha256, /^[0-9a-f]{64}$/) ||
					verified?.type != 'file' || verified.inode != after.inode ||
					verified.size != bytes || runtime.fs.realpath(path) != path) { abort(); fail(); }
				return { path, size: bytes, sha256 };
			}
			catch (error) { terminal(); }
		}
	};
};
