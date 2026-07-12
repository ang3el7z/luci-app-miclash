import { fail } from 'miclash.errors';
import { sha256 as digest_sha256, sha256_file as digest_sha256_file } from 'digest';

const PROCESS_FIELDS = {
	command: true,
	args: true,
	env: true,
	timeout_ms: true
};

function contains_nul(value) {
	return index(value, sprintf('%c', 0)) >= 0;
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

	return request;
};

export function process_result(code, stdout, stderr) {
	return {
		code,
		stdout: stdout ?? null,
		stderr: stderr ?? null
	};
};

function process_run(request) {
	validate_process_request(request);

	let command = [ request.command, ...(request.args ?? []) ];
	if (request.env != null) {
		let environment = [ '/usr/bin/env' ];
		for (let name, value in request.env)
			push(environment, name + '=' + value);
		command = [ ...environment, ...command ];
	}

	return process_result(system(command, request.timeout_ms ?? 0), null, null);
};

function fs_adapter() {
	let fs = require('fs');
	return {
		readfile: (path) => fs.readfile(path),
		writefile: (path, data) => fs.writefile(path, data),
		open: (path, mode, perm) => fs.open(path, mode, perm),
		write: (handle, data) => handle.write(data),
		flush: (handle) => {
			let flushed = handle.flush();
			// Pinned OpenWrt 24.10 returns null on success and true on failure.
			return flushed == null && handle.error() == null;
		},
		close: (handle) => handle.close(),
		stat: (path) => fs.stat(path),
		lstat: (path) => fs.lstat(path),
		realpath: (path) => fs.realpath(path),
		mkdir: (path) => fs.mkdir(path),
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
	let runtime = {
		fs: fs_adapter(),
		digest: digest_adapter(),
		clock: clock_adapter(),
		process: { run: process_run },
		ubus: ubus_adapter(),
		uci: uci_adapter(),
		logger: logger_adapter(),
		paths: {
			etc: '/etc/miclash',
			run: '/var/run/miclash',
			tmp: '/tmp/miclash'
		}
	};

	for (let name, adapter in overrides ?? {}) {
		if (!exists(runtime, name))
			fail('INVALID_ARGUMENT');
		runtime[name] = adapter;
	}

	return runtime;
};
