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

function process_adapter() {
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

	return {
		run: (request) => {
			validate_process_request(request);
			let command = plain_command(request);
			return process_result(system(command, request.timeout_ms ?? 0), null, null);
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
		sleep: (milliseconds) => require('uloop').run(milliseconds),
		set_timeout: (milliseconds, callback) => require('uloop').timer(milliseconds, callback)
	};
};

export function create_http_adapter(clock, socket) {
	const MAX_HEADER = 16384;
	const MAX_BODY = 65536;
	const TIMEOUT_MS = 2000;
	if (type(clock?.now) != 'function' || type(socket?.connect) != 'function' ||
	    type(socket?.poll) != 'function')
		fail('INVALID_ARGUMENT');

	function invalid_response() { fail('INVALID_RESPONSE'); };
	function remaining(deadline) {
		let value = deadline - clock.now();
		return value > 0 ? value : 0;
	};
	function send_all(conn, data, deadline) {
		let offset = 0;
		while (offset < length(data)) {
			let events = socket.poll(remaining(deadline),
				[ conn, socket.POLLOUT | socket.POLLERR | socket.POLLHUP ]);
			if (!length(events) || !(events[0][1] & socket.POLLOUT))
				fail('HEALTH_FAILED');
			let written = conn.send(substr(data, offset));
			if (type(written) != 'int' || written < 1)
				fail('HEALTH_FAILED');
			offset += written;
		}
	};
	function header_value(headers, name) {
		for (let key, value in headers)
			if (lc(key) == name)
				return value;
		return null;
	};
	function parse_chunked(data, complete) {
		let output = '', offset = 0;
		while (true) {
			let relative = index(substr(data, offset), '\r\n');
			if (relative < 0)
				return complete ? invalid_response() : null;
			let boundary = offset + relative;
			let size_text = substr(data, offset, boundary - offset);
			if (!match(size_text, /^[0-9A-Fa-f]+$/))
				invalid_response();
			let size = int(size_text, 16);
			if (size == null || size < 0)
				invalid_response();
			offset = boundary + 2;
			if (size == 0) {
				let trailer_start = offset;
				while (true) {
					let trailer_relative = index(substr(data, offset), '\r\n');
					if (trailer_relative < 0)
						return complete ? invalid_response() : null;
					let trailer_end = offset + trailer_relative;
					if (trailer_end - trailer_start > MAX_HEADER)
						fail('RESPONSE_TOO_LARGE');
					let line = substr(data, offset, trailer_end - offset);
					offset = trailer_end + 2;
					if (!length(line)) {
						if (length(data) != offset)
							invalid_response();
						return output;
					}
					let colon = index(line, ':');
					if (colon < 1)
						invalid_response();
					let name = substr(line, 0, colon);
					let value = trim(substr(line, colon + 1));
					if (!match(name, /^[!#$%&'*+.^_`|~0-9A-Za-z-]+$/) ||
					    match(value, /[[:cntrl:]]/) || lc(name) == 'content-length' ||
					    lc(name) == 'transfer-encoding')
						invalid_response();
				}
			}
			if (length(output) + size > MAX_BODY)
				fail('RESPONSE_TOO_LARGE');
			if (length(data) < offset + size + 2)
				return complete ? invalid_response() : null;
			output += substr(data, offset, size);
			offset += size;
			if (substr(data, offset, 2) != '\r\n')
				invalid_response();
			offset += 2;
		}
	};
	function parse_response(raw, complete) {
		let boundary = index(raw, '\r\n\r\n');
		if (boundary < 0) {
			if (length(raw) > MAX_HEADER)
				fail('RESPONSE_TOO_LARGE');
			return complete ? invalid_response() : null;
		}
		if (boundary > MAX_HEADER)
			fail('RESPONSE_TOO_LARGE');
		let lines = split(substr(raw, 0, boundary), '\r\n');
		let status_line = shift(lines);
		let matched = match(status_line, /^HTTP\/1\.[01] ([0-9]{3})( |$)/);
		if (!matched)
			invalid_response();
		let status = int(matched[1]), headers = {};
		for (let line in lines) {
			let colon = index(line, ':');
			if (colon < 1)
				invalid_response();
			let name = trim(substr(line, 0, colon));
			let value = trim(substr(line, colon + 1));
			if (!match(name, /^[!#$%&'*+.^_`|~0-9A-Za-z-]+$/) || exists(headers, lc(name)))
				invalid_response();
			headers[lc(name)] = value;
		}
		let body = substr(raw, boundary + 4);
		let transfer = header_value(headers, 'transfer-encoding');
		let content_length = header_value(headers, 'content-length');
		if (transfer != null) {
			if (lc(transfer) != 'chunked' || content_length != null)
				invalid_response();
			if (!complete)
				return null;
			let decoded = parse_chunked(body, complete);
			return decoded == null ? null : { status, body: decoded };
		}
		if (content_length != null) {
			if (!match(content_length, /^(0|[1-9][0-9]*)$/))
				invalid_response();
			let expected = int(content_length);
			if (expected > MAX_BODY)
				fail('RESPONSE_TOO_LARGE');
			if (!complete)
				return null;
			if (length(body) < expected)
				return complete ? invalid_response() : null;
			if (length(body) != expected)
				invalid_response();
			return { status, body };
		}
		if (length(body) > MAX_BODY)
			fail('RESPONSE_TOO_LARGE');
		return complete ? { status, body } : null;
	};

	return {
		request: (request) => {
			if (type(request) != 'object' ||
			    (request.host != '127.0.0.1' && request.host != '::1') ||
			    type(request.port) != 'int' || request.port < 1 || request.port > 65535 ||
			    type(request.method) != 'string' || type(request.path) != 'string' ||
			    type(request.headers) != 'object')
				fail('INVALID_ARGUMENT');
			let body = request.body == null ? '' : sprintf('%J', request.body);
			if (length(body) > MAX_BODY)
				fail('INVALID_ARGUMENT');
			let deadline = clock.now() + TIMEOUT_MS;
			let conn = socket.connect({ address: request.host, port: request.port }, null,
				{ socktype: socket.SOCK_STREAM }, TIMEOUT_MS);
			if (conn == null)
				fail('HEALTH_FAILED');
			let request_text = request.method + ' ' + request.path + ' HTTP/1.1\r\n' +
				'Host: ' + (request.host == '::1' ? '[::1]' : request.host) + ':' + request.port + '\r\n' +
				'Connection: close\r\nContent-Type: application/json\r\n';
			for (let name, value in request.headers) {
				if (!match(name, /^[A-Za-z0-9-]+$/) || type(value) != 'string' || match(value, /[\r\n]/)) {
					conn.close();
					fail('INVALID_ARGUMENT');
				}
				request_text += name + ': ' + value + '\r\n';
			}
			request_text += 'Content-Length: ' + length(body) + '\r\n\r\n' + body;
			let raw = '', parsed = null;
			try {
				send_all(conn, request_text, deadline);
				while (parsed == null) {
					let wait = remaining(deadline);
					if (wait <= 0)
						fail('HEALTH_FAILED');
					let events = socket.poll(wait, [ conn, socket.POLLIN | socket.POLLERR | socket.POLLHUP ]);
					if (!length(events))
						fail('HEALTH_FAILED');
					let flags = events[0][1];
					if (flags & socket.POLLIN) {
						let chunk = conn.recv(4096);
						if (chunk == null)
							fail('HEALTH_FAILED');
						if (!length(chunk)) {
							parsed = parse_response(raw, true);
							break;
						}
						raw += chunk;
						if (length(raw) > MAX_HEADER + MAX_BODY + MAX_HEADER)
							fail('RESPONSE_TOO_LARGE');
						parsed = parse_response(raw, false);
					}
					else if (flags & (socket.POLLERR | socket.POLLHUP)) {
						parsed = parse_response(raw, true);
						break;
					}
				}
			}
			catch (error) {
				try { conn.close(); } catch (close_error) {}
				let code = error?.code ?? error?.message;
				if (code == 'RESPONSE_TOO_LARGE' || code == 'INVALID_RESPONSE' ||
				    code == 'INVALID_ARGUMENT')
					fail(code);
				fail('HEALTH_FAILED');
			}
			conn.close();
			return parsed;
		}
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
		http: null,
		process: null,
		ubus: ubus_adapter(),
		uci: uci_adapter(),
		observers: {},
		service_options: {},
		logger: logger_adapter(),
		paths
	};

	for (let name, adapter in overrides ?? {}) {
		if (!exists(runtime, name))
			fail('INVALID_ARGUMENT');
		runtime[name] = adapter;
	}
	if (runtime.process == null)
		runtime.process = process_adapter();
	if (runtime.http == null)
		runtime.http = create_http_adapter(runtime.clock, require('socket'));

	return runtime;
};
