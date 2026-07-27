import { fail } from 'miclash.errors';
import { profile_name } from 'miclash.schema';

const MAX_CONFIG = 1048576;
const MAX_RESPONSE = 65536;
const MAX_DEPTH = 16;
const HTTPS_HELPER = '/usr/libexec/miclash/mihomo-https.uc';
const METHODS = { GET: true, PUT: true, POST: true };
const PATHS = {
	'/version': { GET: true },
	'/rules': { GET: true },
	'/configs': { GET: true },
	'/configs?force=true': { PUT: true },
	'/restart': { POST: true }
};

function domain(value) {
	if (type(value) != 'string' || !length(value) || length(value) > 253 ||
	    match(value, /[[:cntrl:]]/) || substr(value, 0, 1) == '.' ||
	    substr(value, -1) == '.')
		return false;
	for (let label in split(value, '.'))
		if (!length(label) || length(label) > 63 ||
		    !match(label, /^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$/))
			return false;
	return true;
};

function scalar(value) {
	value = trim(value);
	if (!length(value))
		return '';
	if (substr(value, 0, 1) == '"') {
		let parsed;
		try { parsed = json(value); } catch (error) { fail('INVALID_ARGUMENT'); }
		if (type(parsed) != 'string')
			fail('INVALID_ARGUMENT');
		return parsed;
	}
	if (substr(value, 0, 1) == "'") {
		if (length(value) < 2 || substr(value, -1) != "'")
			fail('INVALID_ARGUMENT');
		return replace(substr(value, 1, length(value) - 2), "''", "'");
	}
	let comment = index(value, ' #');
	if (comment >= 0)
		value = trim(substr(value, 0, comment));
	if (match(value, /[[:cntrl:]]/))
		fail('INVALID_ARGUMENT');
	return value;
};

function parse_config(runtime, profile, config_content) {
	profile = profile_name(profile ?? 'config.yaml');
	if (config_content != null && type(config_content) != 'string')
		fail('INVALID_ARGUMENT');
	let content = config_content ?? runtime.fs.readfile('/opt/clash/' + profile);
	if (type(content) != 'string')
		fail('NOT_FOUND');
	if (length(content) > MAX_CONFIG)
		fail('INVALID_ARGUMENT');
	let values = {};
	for (let line in split(content, '\n')) {
		if (!length(line) || match(line, /^\s*#/) || match(line, /^\s/))
			continue;
		let colon = index(line, ':');
		if (colon < 1)
			continue;
		let key = substr(line, 0, colon);
		if (key != 'external-controller' && key != 'external-controller-tls' && key != 'secret')
			continue;
		if (exists(values, key))
			fail('INVALID_ARGUMENT');
		values[key] = scalar(substr(line, colon + 1));
	}
	let plain = values['external-controller'];
	let tls = values['external-controller-tls'];
	if (length(plain ?? '') && length(tls ?? ''))
		fail('INVALID_ARGUMENT');
	let address = length(tls ?? '') ? tls : plain;
	if (!length(address ?? ''))
		fail('INVALID_ARGUMENT');
	let host, port_text;
	if (substr(address, 0, 1) == '[') {
		let close = index(address, ']:');
		if (close < 2 || index(substr(address, close + 2), ':') >= 0)
			fail('INVALID_ARGUMENT');
		host = substr(address, 1, close - 1);
		port_text = substr(address, close + 2);
	}
	else {
		let parts = split(address, ':');
		if (length(parts) != 2)
			fail('INVALID_ARGUMENT');
		host = parts[0];
		port_text = parts[1];
	}
	if (!match(port_text, /^[0-9]+$/) || match(host, /[@\/\[\]]/))
		fail('INVALID_ARGUMENT');
	let request_host;
	if (host == '127.0.0.1' || host == 'localhost' || host == '0.0.0.0')
		request_host = '127.0.0.1';
	else if (host == '::1' || host == '::')
		request_host = '::1';
	else
		fail('INVALID_ARGUMENT');
	let port = int(port_text);
	if (port == null || port < 1 || port > 65535)
		fail('INVALID_ARGUMENT');
	return {
		scheme: length(tls ?? '') ? 'https' : 'http',
		host: request_host,
		port,
		secret: values.secret ?? ''
	};
};

function check_depth(value, depth, count) {
	if (depth > MAX_DEPTH || count.value++ > 4096)
		fail('INVALID_RESPONSE');
	if (type(value) == 'array')
		for (let item in value)
			check_depth(item, depth + 1, count);
	else if (type(value) == 'object')
		for (let name, item in value)
			check_depth(item, depth + 1, count);
};

function same_node(left, right) {
	return left?.type == 'file' && right?.type == 'file' && left.inode == right.inode &&
	       left.dev?.major == right.dev?.major && left.dev?.minor == right.dev?.minor &&
	       left.nlink == 1 && right.nlink == 1;
};

function ensure_tmp(runtime) {
	let path = runtime.paths.tmp;
	let stat = runtime.fs.lstat(path);
	if (stat == null && runtime.fs.mkdir(path) != true)
		fail('INTERNAL');
	stat = runtime.fs.lstat(path);
	if (stat?.type != 'directory' || runtime.fs.realpath(path) != path ||
	    runtime.fs.chmod(path, 0o700) != true)
		fail('INTERNAL');
};

function curl_quote(value) {
	if (type(value) != 'string' || match(value, /[[:cntrl:]]/))
		fail('INVALID_ARGUMENT');
	return '"' + replace(replace(value, '\\', '\\\\'), '"', '\\"') + '"';
};

function write_all(runtime, handle, data) {
	let offset = 0;
	while (offset < length(data)) {
		let amount = runtime.fs.write(handle, substr(data, offset));
		if (type(amount) != 'int' || amount < 1)
			fail('INTERNAL');
		offset += amount;
	}
	if (runtime.fs.flush(handle) != true)
		fail('INTERNAL');
};

function https_request(runtime, controller, method, path, body) {
	ensure_tmp(runtime);
	let helper = runtime.fs.lstat(HTTPS_HELPER);
	if (helper?.type != 'file' || helper.nlink != 1 || runtime.fs.realpath(HTTPS_HELPER) != HTTPS_HELPER)
		fail('INTERNAL');
	let token = runtime.random.hex(8);
	if (type(token) != 'string' || !match(token, /^[0-9a-f]{16}$/))
		fail('INTERNAL');
	let base = runtime.paths.tmp + '/curl-' + token;
	let paths = [ base + '.config', base + '.request', base + '.status', base + '.response' ];
	let handles = [], owned = [], failure = null, response = null;
	try {
		for (let item in paths) {
			let handle = runtime.fs.open(item, 'wx', 0o600);
			if (handle == null)
				fail('INTERNAL');
			let record = { path: item, handle, identity: null };
			push(owned, record);
			push(handles, handle);
			let identity = runtime.fs.lstat(item);
			record.identity = identity;
			if (identity?.type != 'file' || identity.nlink != 1 || runtime.fs.realpath(item) != item)
				fail('INTERNAL');
		}
		let request_body = body == null ? '' : sprintf('%J', body);
		if (length(request_body) > MAX_RESPONSE)
			fail('INVALID_ARGUMENT');
		let url_host = controller.host == '::1' ? '[::1]' : controller.host;
		let config =
			'silent\nshow-error\nproto = "=https"\nproto-redir = "=https"\n' +
			'max-redirs = 0\nproxy = ""\nnoproxy = "*"\nconnect-timeout = 2\n' +
			'max-time = 3\nmax-filesize = ' + MAX_RESPONSE + '\ninsecure\n' +
			'request = ' + curl_quote(method) + '\nurl = ' +
			curl_quote('https://' + url_host + ':' + controller.port + path) + '\n' +
			'write-out = ' + curl_quote('%output{/proc/self/fd/' + handles[2].fileno() + '}%{http_code}') + '\n';
		if (body != null)
			config += 'data-binary = ' + curl_quote('@/proc/self/fd/' + handles[1].fileno()) + '\n';
		if (length(controller.secret))
			config += 'header = ' + curl_quote('Authorization: Bearer ' + controller.secret) + '\n';
		write_all(runtime, handles[0], config);
		write_all(runtime, handles[1], request_body);
		let result = runtime.process.run({
			command: '/usr/bin/ucode',
			args: [ '--', HTTPS_HELPER, ...map(handles, (handle) => '' + handle.fileno()) ],
			timeout_ms: 0
		});
		if (result?.code == 63)
			fail('RESPONSE_TOO_LARGE');
		if (result?.code != 0)
			fail('HEALTH_FAILED');
		for (let handle in handles)
			if (runtime.fs.close(handle) != true)
				fail('INTERNAL');
		handles = [];
		for (let record in owned) {
			let current = runtime.fs.lstat(record.path);
			if (!same_node(record.identity, current) || runtime.fs.realpath(record.path) != record.path)
				fail('INTERNAL');
		}
		let status_text = runtime.fs.readfile(paths[2]);
		let response_body = runtime.fs.readfile(paths[3]);
		if (type(status_text) != 'string' || type(response_body) != 'string')
			fail('INVALID_RESPONSE');
		if (length(status_text) > 3 || length(response_body) > MAX_RESPONSE)
			fail('RESPONSE_TOO_LARGE');
		if (!match(status_text, /^[0-9]{3}$/))
			fail('INVALID_RESPONSE');
		let status = int(status_text);
		response = { status, body: response_body };
	}
	catch (error) {
		failure = error?.code ?? error?.message;
	}
	for (let handle in handles)
		try { runtime.fs.close(handle); } catch (close_error) {}
	for (let record in owned)
		try {
			let current = runtime.fs.lstat(record.path);
			if (!same_node(record.identity, current) || runtime.fs.realpath(record.path) != record.path)
				failure = 'INTERNAL';
			else if (runtime.fs.unlink(record.path) != true)
				failure = 'INTERNAL';
		} catch (unlink_error) { failure = 'INTERNAL'; }
	if (failure != null)
		fail(failure);
	return response;
};

function perform_request(runtime, method, path, body, profile, config_content) {
	if (type(method) != 'string' || !exists(METHODS, method) || type(path) != 'string')
		fail('INVALID_ARGUMENT');
	if (body != null && type(body) != 'object')
		fail('INVALID_ARGUMENT');
	let controller = parse_config(runtime, profile, config_content);
	let response;
	try {
		response = controller.scheme == 'https' ?
			https_request(runtime, controller, method, path, body) : runtime.http.request({
			host: controller.host,
			port: controller.port,
			method,
			path,
			headers: length(controller.secret) ? {
				Authorization: 'Bearer ' + controller.secret
			} : {},
			body
		});
	}
	catch (error) {
		let code = error?.code ?? error?.message;
		if (code == 'RESPONSE_TOO_LARGE' || code == 'INVALID_RESPONSE' ||
		    code == 'INTERNAL' || code == 'INVALID_ARGUMENT')
			fail(code);
		fail('HEALTH_FAILED');
	}
	if (type(response?.status) != 'int' || type(response?.body) != 'string')
		fail('INVALID_RESPONSE');
	if (length(response.body) > MAX_RESPONSE)
		fail('RESPONSE_TOO_LARGE');
	let data = null;
	if (length(response.body)) {
		try { data = json(response.body); }
		catch (error) { fail('INVALID_RESPONSE'); }
		check_depth(data, 0, { value: 0 });
	}
	return {
		ok: response.status >= 200 && response.status < 300,
		status: response.status,
		data
	};
};

export function request(runtime, method, path, body, profile, config_content) {
	if (type(path) != 'string' || !exists(PATHS, path) || !exists(PATHS[path], method))
		fail('INVALID_ARGUMENT');
	return perform_request(runtime, method, path, body, profile, config_content);
};

export function dns_query(runtime, name, query_type, profile, config_content) {
	if (!domain(name) || (query_type != 'A' && query_type != 'AAAA'))
		fail('INVALID_ARGUMENT');
	return perform_request(runtime, 'GET', '/dns/query?name=' + lc(name) +
		'&type=' + query_type, null, profile, config_content);
};
