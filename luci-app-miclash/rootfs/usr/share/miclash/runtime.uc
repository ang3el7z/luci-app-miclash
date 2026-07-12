import { fail } from 'miclash.errors';
import { sha256 as digest_sha256, sha256_file as digest_sha256_file } from 'digest';

const PROCESS_FIELDS = {
	command: true,
	args: true,
	env: true,
	timeout_ms: true,
	capture_limit: true
};

const CAPTURE_HELPER = '/usr/libexec/miclash/capture.uc';

function contains_nul(value) {
	return index(value, sprintf('%c', 0)) >= 0;
};

function same_identity(left, right) {
	return left?.type == 'file' && right?.type == 'file' && left.nlink == 1 &&
	       right.nlink == 1 && left.inode == right.inode &&
	       left.dev?.major == right.dev?.major && left.dev?.minor == right.dev?.minor;
};

export function validate_process_request(request) {
	if (type(request) != 'object')
		fail('INVALID_ARGUMENT');

	for (let name in request)
		if (!exists(PROCESS_FIELDS, name))
			fail('INVALID_ARGUMENT');

	if (type(request.command) != 'string' || !length(request.command) || contains_nul(request.command))
		fail('INVALID_ARGUMENT');
	if (request.args != null && type(request.args) != 'array')
		fail('INVALID_ARGUMENT');
	for (let arg in request.args ?? [])
		if (type(arg) != 'string' || contains_nul(arg))
			fail('INVALID_ARGUMENT');
	if (request.env != null && type(request.env) != 'object')
		fail('INVALID_ARGUMENT');
	for (let name, value in request.env ?? {})
		if (!match(name, /^[A-Za-z_][A-Za-z0-9_]*$/) ||
		    type(value) != 'string' || contains_nul(value))
			fail('INVALID_ARGUMENT');
	if (request.timeout_ms != null &&
	    (type(request.timeout_ms) != 'int' || request.timeout_ms < 0))
		fail('INVALID_ARGUMENT');
	if (request.capture_limit != null &&
	    (type(request.capture_limit) != 'int' || request.capture_limit < 1 ||
	     request.capture_limit > 8192))
		fail('INVALID_ARGUMENT');
	if (request.capture_limit != null &&
	    (request.timeout_ms == null || request.timeout_ms < 1 || request.timeout_ms > 300000))
		fail('INVALID_ARGUMENT');

	return request;
};

export function process_result(code, stdout, stderr, truncated) {
	let result = {
		code,
		stdout: stdout ?? null,
		stderr: stderr ?? null
	};
	if (truncated != null)
		result.truncated = truncated;
	return result;
};

function process_adapter(fs, random, paths) {
	function plain_command(request) {
		let command = [ request.command, ...(request.args ?? []) ];
		if (request.env != null) {
			let environment = [ '/usr/bin/env' ];
			for (let name, value in request.env)
				push(environment, name + '=' + value);
			command = [ ...environment, ...command ];
		}
		return command;
	};

	function secure_capture_root() {
		let stat = fs.lstat(paths.tmp);
		if (stat == null)
			fs.mkdir(paths.tmp);
		if (fs.lstat(paths.tmp)?.type != 'directory' || fs.realpath(paths.tmp) != paths.tmp ||
		    fs.chmod(paths.tmp, 0o700) != true)
			fail('INTERNAL');
	};

	return {
		run: (request) => {
			validate_process_request(request);
			let command = plain_command(request);
			if (request.capture_limit == null)
				return process_result(system(command, request.timeout_ms ?? 0), null, null);

			secure_capture_root();
			let output = null;
			let created = null;
			let handle = null;
			let identity = null;
			let result = null;
			let failure = null;
			try {
				for (let attempt = 0; attempt < 16; attempt++) {
					output = paths.tmp + '/.capture-' + random.hex(8);
					handle = fs.open(output, 'w+x', 0o600);
					if (handle != null) {
						created = output;
						break;
					}
				}
				if (handle == null)
					fail('INTERNAL');
				identity = fs.lstat(created);
				if (identity?.type != 'file' || identity.nlink != 1 ||
				    fs.realpath(created) != created)
					fail('INTERNAL');

				let helper = [ '/usr/bin/ucode', '--', CAPTURE_HELPER,
					sprintf('%d', handle.fileno()), sprintf('%d', request.capture_limit),
					sprintf('%d', request.timeout_ms), ...command ];
				let code = system(helper, request.timeout_ms + 1000);
				let current = fs.lstat(created);
				if (!same_identity(identity, current) || fs.realpath(created) != created ||
				    fs.seek(handle, 0, 0) != true)
					fail('INTERNAL');
				let captured = fs.read(handle, request.capture_limit + 1);
				if (type(captured) != 'string' || fs.close(handle) != true)
					fail('INTERNAL');
				handle = null;
				let truncated = length(captured) > request.capture_limit;
				if (truncated)
					captured = substr(captured, 0, request.capture_limit);
				result = process_result(code, captured, null, truncated);
			}
			catch (error) {
				failure = error?.code ?? error?.message;
			}
			if (handle != null) {
				try {
					if (fs.close(handle) != true)
						failure = 'INTERNAL';
				}
				catch (close_error) { failure = 'INTERNAL'; }
			}
			if (created != null) {
				try {
					let owned = fs.lstat(created);
					if (!same_identity(identity, owned) || fs.realpath(created) != created ||
					    fs.unlink(created) != true)
						failure = 'INTERNAL';
				}
				catch (unlink_error) { failure = 'INTERNAL'; }
			}
			if (failure != null)
				fail(failure == 'INVALID_ARGUMENT' ? 'INVALID_ARGUMENT' : 'INTERNAL');
			return result;
		}
	};
};

function fs_adapter() {
	let fs = require('fs');
	return {
		readfile: (path) => fs.readfile(path),
		writefile: (path, data) => fs.writefile(path, data),
		open: (path, mode, perm) => fs.open(path, mode, perm),
		write: (handle, data) => handle.write(data),
		read: (handle, amount) => handle.read(amount),
		seek: (handle, offset, position) => handle.seek(offset, position),
		flush: (handle) => {
			let flushed = handle.flush();
			// Pinned OpenWrt 24.10 returns null on success and true on failure.
			return flushed == null;
		},
		close: (handle) => handle.close(),
		stat: (path) => fs.stat(path),
		lstat: (path) => fs.lstat(path),
		realpath: (path) => fs.realpath(path),
		mkdir: (path) => fs.mkdir(path),
		rmdir: (path) => fs.rmdir(path),
		lsdir: (path) => fs.lsdir(path),
		chmod: (path, mode) => fs.chmod(path, mode),
		unlink: (path) => fs.unlink(path),
		rename: (from, to) => fs.rename(from, to)
	};
};

function clock_adapter() {
	return {
		now: () => time() * 1000,
		set_timeout: (milliseconds, callback) => require('uloop').timer(milliseconds, callback)
	};
};

function digest_adapter() {
	return {
		sha256: (data) => digest_sha256(data),
		sha256_file: (path) => digest_sha256_file(path)
	};
};

function random_adapter() {
	return {
		hex: (bytes) => {
			if (type(bytes) != 'int' || bytes < 1 || bytes > 32)
				fail('INVALID_ARGUMENT');
			let handle = require('fs').open('/dev/urandom', 'r');
			if (handle == null)
				fail('INTERNAL');
			let data;
			try { data = handle.read(bytes); }
			catch (error) {
				try { handle.close(); } catch (close_error) {}
				fail('INTERNAL');
			}
			if (handle.close() != true || type(data) != 'string' || length(data) != bytes)
				fail('INTERNAL');
			let digest = digest_sha256(data);
			if (type(digest) != 'string' || length(digest) != 64 ||
			    !match(digest, /^[0-9a-f]+$/))
				fail('INTERNAL');
			return substr(digest, 0, bytes * 2);
		}
	};
};

function ubus_adapter() {
	return { connect: () => require('ubus').connect() };
};

function uci_adapter() {
	return { cursor: () => require('uci').cursor() };
};

function logger_adapter() {
	return {
		debug: (message) => warn(message + '\n'),
		info: (message) => warn(message + '\n'),
		warn: (message) => warn(message + '\n'),
		error: (message) => warn(message + '\n')
	};
};

export function create(overrides) {
	let filesystem = fs_adapter();
	let digest = digest_adapter();
	let random = random_adapter();
	let clock = clock_adapter();
	let paths = {
		etc: '/etc/miclash',
		run: '/var/run/miclash',
		tmp: '/tmp/miclash'
	};
	let runtime = {
		fs: filesystem,
		digest,
		random,
		clock,
		process: null,
		ubus: ubus_adapter(),
		uci: uci_adapter(),
		logger: logger_adapter(),
		paths
	};

	for (let name, adapter in overrides ?? {}) {
		if (!exists(runtime, name))
			fail('INVALID_ARGUMENT');
		runtime[name] = adapter;
	}
	if (runtime.process == null)
		runtime.process = process_adapter(runtime.fs, runtime.random, runtime.paths);

	return runtime;
};
