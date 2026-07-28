import { fail } from 'miclash.errors';
import { sha256 as digest_sha256, sha256_file as digest_sha256_file } from 'digest';
import * as secure_fs from 'miclash.secure-fs';
import * as rulesets from 'miclash.rulesets';
import * as dns from 'miclash.dns';
import * as routing from 'miclash.routing';
import * as nft from 'miclash.firewall.nft';
import * as iptables from 'miclash.firewall.iptables';
import * as guard_latch from 'miclash.guard-latch';
import { with_lock } from 'miclash.mutation_lock';

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

function packaged_app_version(filesystem) {
	let value = '';
	try { value = trim(filesystem.readfile('/usr/share/miclash/version') ?? ''); }
	catch (error) { value = ''; }
	if (type(value) == 'string' && length(value) <= 64 &&
	    match(value,
	      /^[0-9]+(\.[0-9]+)+(([.-][0-9A-Za-z][0-9A-Za-z.-]*)|(_rc[0-9]+))?$/))
		return value;
	return '0.9.3';
};

export function create_flush_adapter(filesystem) {
	let probe = filesystem.open('/dev/null', 'w');
	if (probe == null)
		fail('INTERNAL');

	// Clear registry state before probing the active fs ABI. OpenWrt 24's
	// pinned ucode has an inverted fflush() check: a successful flush returns
	// null and records the current errno, so post-flush error text is only a
	// reliable failure signal for the corrected true-success ABI.
	probe.error();
	let success_marker = probe.flush();
	let probe_error = probe.error();
	let closed = probe.close();
	if ((success_marker !== true && success_marker != null) ||
	    (success_marker === true && probe_error != null) ||
	    closed !== true)
		fail('INTERNAL');

	return (handle) => handle.flush() === success_marker;
};

function fs_adapter() {
	let fs = require('fs');
	let flush = create_flush_adapter(fs);
	return {
		readfile: (path) => fs.readfile(path),
		writefile: (path, data) => fs.writefile(path, data),
		popen: (command, mode) => fs.popen(command, mode),
		open: (path, mode, perm) => fs.open(path, mode, perm),
		read: (handle, amount) => handle.read(amount),
		fstat: (handle) => fs.stat('/proc/self/fd/' + handle.fileno()),
		write: (handle, data) => handle.write(data),
		// OpenWrt 24's pinned ucode and OpenWrt 25 use opposite success
		// markers. The /dev/null probe normalizes the active ABI safely.
		flush,
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
	let arm = (milliseconds, callback) => require('uloop').timer(milliseconds, callback);
	return {
		now: () => time() * 1000,
		sleep: (milliseconds) => require('uloop').run(milliseconds),
		set_timeout: arm,
		// Keep a separately bound production primitive. A wrapped/injected primary
		// scheduler can fail transiently without orphaning enabled daemon domains.
		set_fallback_timeout: arm
	};
};

export function create_http_adapter(clock, socket) {
	const MAX_HEADER = 16384;
	const MAX_BODY = 524288;
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

function reboot_adapter(runtime) {
	return () => {
		let connection = runtime.ubus.connect();
		if (connection == null || type(connection.call) != 'function') fail('INTERNAL');
		try { connection.call('system', 'reboot', {}); }
		catch (error) { fail('HEALTH_FAILED'); }
		return true;
	};
};

function uci_adapter() {
	return { cursor: () => require('uci').cursor() };
};

function logger_adapter() {
	let priorities = { debug: 'debug', info: 'info', warn: 'warning', error: 'err' };
	function emit(level, message) {
		let value = type(message) == 'string' ? message : sprintf('%J', message);
		value = trim(replace(value, /[\r\n]+/g, ' '));
		if (!length(value)) return true;
		if (length(value) > 2048) value = substr(value, 0, 2048);
		return system([ '/usr/bin/logger', '-t', 'miclash', '-p',
			'daemon.' + priorities[level], '--', value ]) === 0;
	};
	return {
		debug: (message) => emit('debug', message),
		info: (message) => emit('info', message),
		warn: (message) => emit('warn', message),
		error: (message) => emit('error', message)
	};
};

function event_adapter() {
	let listeners = [], sequence = 0;
	return {
		emit: (type_name, data) => {
			if (type(type_name) != 'string' || !match(type_name, /^[a-z][a-z0-9_]{0,63}$/) ||
			    type(data) != 'object')
				fail('INVALID_ARGUMENT');
			for (let listener in [ ...listeners ])
				try { listener.callback(type_name, data); } catch (error) {}
			return true;
		},
		subscribe: (callback) => {
			if (type(callback) != 'function') fail('INVALID_ARGUMENT');
			let id = ++sequence, active = true;
			push(listeners, { id, callback });
			return () => {
				if (!active) return false;
				active = false;
				let retained = [];
				for (let listener in listeners) if (listener.id != id) push(retained, listener);
				listeners = retained;
				return true;
			};
		}
	};
};

function installed_timezones(filesystem) {
	let cached = null;
	function offset_record(name, timestamp, timezone) {
		let popen = filesystem.popen ?? require('fs').popen;
		if (type(popen) != 'function') return null;
		let process = popen("/usr/bin/env TZ='" + timezone +
			"' /bin/date -d @" + timestamp + ' +%z', 'r');
		if (process == null) return null;
		let output = '', chunk;
		while ((chunk = process.read(32)) != null && length(chunk)) {
			output += chunk;
			if (length(output) > 16) { process.close(); return null; }
		}
		let status = process.close(), value = trim(output);
		if (status != 0 || !match(value, /^[+-][0-9]{4}$/)) return null;
		let hours = int(substr(value, 1, 2)), minutes = int(substr(value, 3, 2));
		if (hours > 14 || minutes > 59) return null;
		let sign = substr(value, 0, 1) == '-' ? -1 : 1;
		return { name, from: timestamp, until: timestamp + 1,
			initial_offset: sign * (hours * 3600 + minutes * 60), transitions: [] };
	};
	function local_timezone() {
		let value = trim(filesystem.readfile('/etc/TZ') ?? '');
		if (!length(value) || length(value) > 128 ||
		    !match(value, /^[A-Za-z0-9_<>+,:.\/-]+$/) || index(value, '..') >= 0)
			return null;
		return value;
	};
	function list_zones() {
		if (cached != null) return [ ...cached ];
		let zones = [ 'UTC' ], seen = { UTC: true };
		let document = filesystem.readfile('/usr/share/zoneinfo/zone1970.tab') ??
			filesystem.readfile('/usr/share/zoneinfo/zone.tab') ?? '';
		for (let line in split(document, '\n')) {
			if (length(zones) >= 512) break;
			if (!length(line) || substr(line, 0, 1) == '#') continue;
			let fields = split(line, '\t'), name = fields[2];
			if (type(name) != 'string' || !match(name, /^[A-Za-z0-9._+-]+\/[A-Za-z0-9._+\/-]+$/) ||
			    index(name, '..') >= 0 || seen[name] ||
			    filesystem.stat('/usr/share/zoneinfo/' + name)?.type != 'file') continue;
			seen[name] = true; push(zones, name);
		}
		cached = zones;
		return [ ...cached ];
	};
	return {
		list: list_zones,
		resolve: (name, timestamp) => {
			if (type(name) != 'string' || type(timestamp) != 'int' || timestamp < 0 ||
			    index(list_zones(), name) < 0) return null;
			if (name == 'UTC') return { name, from: timestamp, until: timestamp + 1,
				initial_offset: 0, transitions: [] };
			return offset_record(name, timestamp, name);
		},
		resolve_local: (name, timestamp) => {
			if (type(name) != 'string' || type(timestamp) != 'int' || timestamp < 0)
				return null;
			let timezone = local_timezone();
			return timezone == null ? null : offset_record(name, timestamp, timezone);
		}
	};
};

function device_observers(filesystem, clock) {
	function observed(data) {
		return { observed_at: int(clock.now() / 1000), data };
	};
	function capture(command) {
		let process = require('fs').popen(command, 'r');
		if (process == null) return null;
		let output = '', chunk;
		while ((chunk = process.read(4096)) != null && length(chunk)) {
			output += chunk;
			if (length(output) > 1048576) { process.close(); fail('RESPONSE_TOO_LARGE'); }
		}
		return process.close() == 0 ? output : null;
	};
	return {
		dhcp_leases: () => {
			let data = filesystem.readfile('/tmp/dhcp.leases') ?? '';
			if (length(data) > 1048576) fail('RESPONSE_TOO_LARGE');
			return observed(data);
		},
		neighbors: (family) => {
			if (family != 'ipv4' && family != 'ipv6') fail('INVALID_ARGUMENT');
			let data = capture('/sbin/ip -j ' + (family == 'ipv4' ? '-4' : '-6') +
				' neigh show');
			return observed(data ?? '[]');
		}
	};
};

function readiness_observers(runtime) {
	let routing_snapshot = null, routing_observed_at = null;
	function listener_contract() {
		let contract = { tproxy_port: 7894, dns_port: 7874, ipv6: true };
		let content = runtime.fs.readfile('/opt/clash/config.yaml');
		if (type(content) != 'string' || length(content) > 1048576)
			return contract;
		let in_dns = false;
		for (let line in split(content, '\n')) {
			let found = match(line, /^tproxy-port:[ \t]*(0|[1-9][0-9]{0,4})[ \t]*(#.*)?$/);
			if (found != null) {
				let port = int(found[1]);
				if (port >= 1 && port <= 65535) contract.tproxy_port = port;
			}
			found = match(line, /^ipv6:[ \t]*(true|false)[ \t]*(#.*)?$/);
			if (found != null) contract.ipv6 = found[1] == 'true';
			if (match(line, /^dns:[ \t]*(#.*)?$/) != null) {
				in_dns = true;
				continue;
			}
			if (match(line, /^[^ \t#]/) != null) in_dns = false;
			if (!in_dns) continue;
			found = match(line, /^[ \t]+listen:[ \t]*[^#]*:([0-9]{1,5})["']?[ \t]*(#.*)?$/);
			if (found != null) {
				let port = int(found[1]);
				if (port >= 1 && port <= 65535) contract.dns_port = port;
			}
		}
		return contract;
	};
	function port_hex(port) { return sprintf('%04X', port); };
	function routing_observation() {
		let now = runtime.clock.now();
		if (routing_snapshot == null || routing_observed_at != now) {
			routing_snapshot = routing.observe(runtime);
			routing_observed_at = now;
		}
		return routing_snapshot;
	};
	function safe(observer) {
		return (argument) => {
			try { return observer(argument); }
			catch (error) { return { ready: false, state: 'failed' }; }
		};
	};
	function socket_open(protocol, family, port, states) {
		let suffix = family == 'ipv4' ? '' : (family == 'ipv6' ? '6' : null);
		if (suffix == null) return false;
		let data = runtime.fs.readfile('/proc/net/' + protocol + suffix);
		if (type(data) != 'string' || length(data) > 1048576) return false;
		for (let line in split(data, '\n')) {
			let found = match(line,
				/^[ \t]*[0-9]+:[ \t]+([0-9A-Fa-f]+):([0-9A-Fa-f]{4})[ \t]+[0-9A-Fa-f]+:[0-9A-Fa-f]{4}[ \t]+([0-9A-Fa-f]{2})/);
			let address = uc(found?.[1] ?? '');
			let compatible = suffix == ''
				? (address == '00000000' || address == '0100007F')
				: (address == '00000000000000000000000000000000' ||
				   address == '00000000000000000000000001000000');
			if (found != null && compatible && uc(found[2]) == port && states[uc(found[3])])
				return true;
		}
		return false;
	};
	return {
		guard: safe((enabled) => {
			if (type(enabled) != 'bool') return { ready: false, state: 'failed' };
			let ready = runtime.guard_control?.verify(enabled) === true;
			let observed_at = runtime.clock.now();
			return { ready, state: ready ? 'ready' : 'failed', enabled,
				observed_at, generation: observed_at };
		}),
		dns: safe(() => {
			let observed = dns.observe(runtime), current = observed?.current;
			let blocked = false;
			for (let conflict in observed?.conflicts ?? [])
				if (conflict != 'AMBIGUOUS_ACTIVE') blocked = true;
			let target = false;
			for (let server in current?.server?.value ?? [])
				if (server == '127.0.0.1#7874') target = true;
			let ready = !blocked && target &&
				current?.cachesize?.present === true && current.cachesize.value == '0' &&
				current?.noresolv?.present === true && current.noresolv.value == '1';
			return { ready, state: ready ? 'ready' : 'failed' };
		}),
		tun: safe(() => {
			let ready = routing_observation()?.interfaces?.['clash-tun'] === true;
			return { ready, state: ready ? 'ready' : 'failed' };
		}),
		policy: safe(() => {
			let observed = routing_observation(), ready = observed?.ownership?.trusted === true &&
				observed.ownership.transition == null && length(observed.routes ?? []) > 0 &&
				length(observed.rules ?? []) > 0;
			for (let item in [ ...(observed?.routes ?? []), ...(observed?.rules ?? []) ])
				if (item?.ambiguous === true || item?.owned !== true) ready = false;
			return { ready, state: ready ? 'ready' : 'failed' };
		}),
		forward: safe(() => {
			let nft_state = nft.observe(runtime);
			if (nft_state?.installed === true)
				return { ready: true, state: 'ready' };
			let iptables_state = iptables.observe(runtime);
			let ready = iptables_state?.valid === true && iptables_state.installed === true;
			return { ready, state: ready ? 'ready' : 'failed' };
		}),
		dataplane: safe((proxy_mode) => {
			if (proxy_mode != 'tproxy' && proxy_mode != 'mixed' && proxy_mode != 'tun')
				return { ready: false, state: 'failed' };
			let contract = listener_contract();
			let dns_port = port_hex(contract.dns_port),
				tproxy_port = port_hex(contract.tproxy_port);
			let dns_ready = socket_open('tcp', 'ipv4', dns_port, { '0A': true }) &&
				socket_open('udp', 'ipv4', dns_port, { '07': true, '0A': true });
			let tcp_ready = proxy_mode == 'tun' ||
				(socket_open('tcp', 'ipv4', tproxy_port, { '0A': true }) &&
				 (!contract.ipv6 || socket_open('tcp', 'ipv6', tproxy_port, { '0A': true })));
			let udp_ready = proxy_mode != 'tproxy' ||
				(socket_open('udp', 'ipv4', tproxy_port, { '07': true, '0A': true }) &&
				 (!contract.ipv6 || socket_open('udp', 'ipv6', tproxy_port,
					{ '07': true, '0A': true })));
			let ready = dns_ready && tcp_ready && udp_ready;
			return { ready, state: ready ? 'ready' : 'failed' };
		})
	};
};

function guard_control_adapter(runtime) {
	function action(name) {
		return with_lock(runtime, { barrier: 'normal', wait_ms: 0 }, () => {
			let lease = runtime.mutation_lock_lease;
			return runtime.process.run({
				command: '/usr/bin/ucode',
				args: [ '-L', '/usr/share/*.uc', '/usr/share/miclash/guard-runtime.uc', name ],
				env: { MICLASH_MUTATION_LOCK_TOKEN: lease.token },
				timeout_ms: 15000
			}).code === 0;
		});
	};
	return {
		protect: () => action('protect') && action('release') &&
			action('verify-bootstrap-on'),
		protect_strict: () => action('protect-strict'),
		verify_protected: () => action('verify-protected'),
		disable: () => action('disable') && action('latch-clear') &&
			action('verify-bootstrap-off'),
		verify: (enabled) => action(enabled ? 'verify-bootstrap-on' : 'verify-bootstrap-off'),
		latch_set: () => action('latch-set'),
		latch_clear: () => action('latch-clear'),
		is_latched: () => guard_latch.is_set(runtime)
	};
};

function mutation_identity(filesystem) {
	let boot = trim(filesystem.readfile('/proc/sys/kernel/random/boot_id') ?? '');
	let stat = filesystem.readfile('/proc/self/stat') ?? '';
	let close = rindex(stat, ')'), first = index(stat, ' ');
	let pid = first > 0 ? int(substr(stat, 0, first)) : null;
	let fields = close > 0 ? split(trim(substr(stat, close + 1)), /[ \t]+/) : [];
	let start = length(fields) >= 20 ? int(fields[19]) : null;
	if (!match(boot, /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/) ||
	    type(pid) != 'int' || pid < 1 || type(start) != 'int' || start < 1)
		return null;
	return { boot, pid, start };
};

function private_runtime_directories(filesystem) {
	for (let path in [ '/etc/miclash', '/tmp/miclash', '/var/run/miclash' ]) {
		let stat = filesystem.lstat(path);
		if (stat == null) {
			if (filesystem.mkdir(path) !== true) fail('INTERNAL');
			if (filesystem.chmod(path, 0o700) !== true) fail('INTERNAL');
			stat = filesystem.lstat(path);
		}
		let canonical = filesystem.realpath(path);
		if (stat?.type != 'directory' || stat.uid != 0 || stat.gid != 0 ||
		    type(stat.mode) != 'int' || (stat.mode & 0o022) != 0 ||
		    (path == '/var/run/miclash'
			? index([ path, '/run/miclash', '/tmp/run/miclash' ], canonical) < 0
			: canonical != path))
			fail('INTERNAL');
	}
	return true;
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
		secure_fs: null,
		timezones: null,
		reconcile: null,
		reboot: null,
		rulesets: null,
		guard_control: null,
		mutation_lock_self: null,
		core_available: false,
		app_version: null,
		logger: logger_adapter(),
		events: null,
		paths
	};

	for (let name, adapter in overrides ?? {}) {
		if (!exists(runtime, name))
			fail('INVALID_ARGUMENT');
		runtime[name] = adapter;
	}
	if (runtime.app_version == null)
		runtime.app_version = packaged_app_version(runtime.fs);
	if (runtime.process == null)
		runtime.process = process_adapter();
	if (runtime.http == null)
		runtime.http = create_http_adapter(runtime.clock, require('socket'));
	if (runtime.events == null)
		runtime.events = event_adapter();
	if (runtime.reboot == null)
		runtime.reboot = reboot_adapter(runtime);
	private_runtime_directories(runtime.fs);
	if (runtime.secure_fs == null)
		runtime.secure_fs = secure_fs.create(runtime);
	if (runtime.rulesets == null)
		runtime.rulesets = rulesets.create(runtime);
	if (runtime.timezones == null)
		runtime.timezones = installed_timezones(runtime.fs);
	runtime.observers = {
		...device_observers(runtime.fs, runtime.clock),
		...readiness_observers(runtime),
		...(runtime.observers ?? {})
	};
	if (runtime.guard_control == null)
		runtime.guard_control = guard_control_adapter(runtime);
	if (runtime.mutation_lock_self == null)
		runtime.mutation_lock_self = mutation_identity(runtime.fs);
	if (overrides?.core_available == null)
		runtime.core_available = runtime.fs.stat('/opt/clash/bin/clash')?.type == 'file';

	return runtime;
};
