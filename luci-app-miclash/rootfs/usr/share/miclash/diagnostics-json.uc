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

export function create(runtime, handle) {
	if (type(runtime?.fs?.write) != 'function' || type(runtime?.fs?.flush) != 'function' ||
		type(runtime?.fs?.close) != 'function' || type(runtime?.fs?.fstat) != 'function' ||
		type(runtime?.fs?.lstat) != 'function' || type(runtime?.fs?.realpath) != 'function' ||
		type(runtime?.digest?.sha256_file) != 'function' || type(handle) != 'object' ||
		type(handle.path) != 'string' || !length(handle.path))
		errors.fail('INVALID_ARGUMENT');

	let path = handle.path, stack = [], closed = false, bytes = 0;
	function write(value) {
		if (closed || type(value) != 'string' || bytes + length(value) > MAX_JSON_BYTES) fail();
		write_all(runtime, handle, value);
		bytes += length(value);
	};
	function separator(container) {
		if (container.count++) write(',');
	};
	function object_member(name) {
		let container = stack[length(stack) - 1];
		if (container?.kind != 'object' || type(name) != 'string') fail();
		separator(container);
		write(sprintf('%J', name) + ':');
	};
	function array_value() {
		let container = stack[length(stack) - 1];
		if (container?.kind != 'array') fail();
		separator(container);
	};
	function close(kind, token) {
		let container = pop(stack);
		if (container?.kind != kind) fail();
		write(token);
	};
	return {
		begin_object: () => {
			if (length(stack)) array_value();
			write('{'); push(stack, { kind: 'object', count: 0 });
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
			if (closed || length(stack)) fail();
			let before = runtime.fs.fstat(handle), failure = null;
			try {
				if (runtime.fs.flush(handle) !== true) fail();
			}
			catch (error) { failure = 'INTERNAL'; }
			if (runtime.fs.close(handle) !== true) failure = 'INTERNAL';
			closed = true;
			let after = runtime.fs.lstat(path);
			if (failure != null || before?.type != 'file' || after?.type != 'file' ||
				before.inode != after.inode || after.size != bytes || runtime.fs.realpath(path) != path)
				fail();
			let sha256 = runtime.digest.sha256_file(path);
			if (type(sha256) != 'string' || !match(sha256, /^[0-9a-f]{64}$/)) fail();
			return { path, size: bytes, sha256 };
		}
	};
};
