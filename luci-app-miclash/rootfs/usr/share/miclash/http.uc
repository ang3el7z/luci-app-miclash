import * as errors from 'miclash.errors';
import * as schema from 'miclash.schema';

const HTTP_ROOT = '/tmp/miclash/http';
const HEADER_LIMIT = 65536;
const OPTION_FIELDS = {
	url: true, headers: true, connect_timeout_ms: true, timeout_ms: true,
	max_redirects: true, max_bytes: true, managed: true, allow_insecure_http: true
};

function invalid() { errors.fail('INVALID_ARGUMENT'); };

function adapter_reply(reply) {
	if (type(reply) != 'object')
		return false;
	let count = 0;
	for (let name in reply) {
		if (name != 'code' && name != 'stdout' && name != 'stderr')
			return false;
		count++;
	}
	return count == 3 && type(reply.code) == 'int' &&
	       reply.stdout == null && reply.stderr == null;
};

function same_node(left, right) {
	return left?.type == 'file' && right?.type == 'file' &&
	       left.inode == right.inode && left.dev?.major == right.dev?.major &&
	       left.dev?.minor == right.dev?.minor && left.nlink == 1 && right.nlink == 1;
};

function ensure_root(runtime) {
	let stat = runtime.fs.lstat(HTTP_ROOT);
	if (stat == null && runtime.fs.mkdir(HTTP_ROOT) != true)
		errors.fail('INTERNAL');
	stat = runtime.fs.lstat(HTTP_ROOT);
	if (stat?.type != 'directory' || runtime.fs.realpath(HTTP_ROOT) != HTTP_ROOT ||
	    runtime.fs.chmod(HTTP_ROOT, 0o700) != true)
		errors.fail('INTERNAL');
};

function candidate(runtime, suffix) {
	for (let attempt = 0; attempt < 16; attempt++) {
		let entropy = runtime.random.hex(8);
		if (type(entropy) != 'string' || !match(entropy, /^[0-9a-f]{16}$/))
			errors.fail('INTERNAL');
		let path = sprintf('%s/%d-%s-%s', HTTP_ROOT, runtime.clock.now(), entropy, suffix);
		let handle = runtime.fs.open(path, 'wx', 0o600);
		if (handle == null)
			continue;
		if (runtime.fs.close(handle) != true) {
			try { runtime.fs.unlink(path); } catch (error) {}
			errors.fail('INTERNAL');
		}
		let identity = runtime.fs.lstat(path);
		if (identity?.type != 'file' || identity.nlink != 1 ||
		    runtime.fs.realpath(path) != path)
			errors.fail('INTERNAL');
		return { path, identity };
	}
	errors.fail('INTERNAL');
};

function read_bounded(runtime, owned, maximum) {
	let before = runtime.fs.lstat(owned.path);
	if (!same_node(owned.identity, before) || runtime.fs.realpath(owned.path) != owned.path)
		errors.fail('INTERNAL');
	let handle = runtime.fs.open(owned.path, 'r');
	if (handle == null)
		errors.fail('INTERNAL');
	let output = '';
	let failure = null;
	try {
		while (true) {
			let remaining = maximum + 1 - length(output);
			let amount = remaining < 4096 ? remaining : 4096;
			let chunk = runtime.fs.read(handle, amount);
			if (type(chunk) != 'string')
				errors.fail('INTERNAL');
			if (!length(chunk))
				break;
			output += chunk;
			if (length(output) > maximum)
				errors.fail('RESPONSE_TOO_LARGE');
		}
	}
	catch (error) { failure = errors.normalize(error).code; }
	if (runtime.fs.close(handle) != true)
		failure = 'INTERNAL';
	let after = runtime.fs.lstat(owned.path);
	if (!same_node(owned.identity, after) || runtime.fs.realpath(owned.path) != owned.path)
		failure = 'INTERNAL';
	if (failure != null)
		errors.fail(failure);
	return output;
};

function response_block(block) {
	let lines = split(block, '\r\n');
	let status_line = shift(lines);
	let found = match(status_line, /^HTTP\/[^ ]+ ([0-9]{3})( |$)/);
	if (found == null)
		errors.fail('INVALID_RESPONSE');
	let version = split(status_line, ' ')[0];
	if (!match(version, /^HTTP\/[0-9]+(\.[0-9]+)?$/))
		errors.fail('INVALID_RESPONSE');
	let headers = {};
	for (let line in lines) {
		let separator = index(line, ':');
		if (separator < 1)
			errors.fail('INVALID_RESPONSE');
		let name = lc(trim(substr(line, 0, separator)));
		let value = trim(substr(line, separator + 1));
		if (!match(name, /^[a-z0-9-]+$/) || match(value, /[[:cntrl:]]/) ||
		    exists(headers, name))
			errors.fail('INVALID_RESPONSE');
		headers[name] = value;
	}
	return { status: int(found[1]), headers };
};

function parse_headers(input, original_url, maximum_redirects) {
	let chunks = split(input, '\r\n\r\n'), blocks = [];
	for (let chunk in chunks)
		if (length(chunk))
			push(blocks, response_block(chunk));
	if (!length(blocks))
		errors.fail('INVALID_RESPONSE');
	let redirects = 0, seen = {};
	seen[original_url] = true;
	for (let index = 0; index < length(blocks); index++) {
		let block = blocks[index];
		if (block.status >= 100 && block.status < 200)
			continue;
		if (block.status >= 300 && block.status < 400) {
			let location = block.headers.location;
			if (type(location) != 'string' || !length(location) ||
			    match(location, /[[:cntrl:]]/) || substr(location, 0, 2) == '//')
				errors.fail('INVALID_RESPONSE');
			if (match(location, /^https?:\/\//)) {
				try { schema.url(location); }
				catch (error) { errors.fail('INVALID_RESPONSE'); }
				if (match(original_url, /^https:\/\//) && match(location, /^http:\/\//))
					errors.fail('INVALID_RESPONSE');
			}
			if (exists(seen, location))
				errors.fail('INVALID_RESPONSE');
			seen[location] = true;
			redirects++;
			if (redirects > maximum_redirects)
				errors.fail('INVALID_RESPONSE');
			continue;
		}
		if (index != length(blocks) - 1)
			errors.fail('INVALID_RESPONSE');
	}
	let final = blocks[length(blocks) - 1];
	if (final.status < 200 || final.status >= 300)
		errors.fail('DOWNLOAD_FAILED');
	return final;
};

function clean_options(runtime, options) {
	if (type(runtime?.fs) != 'object' || type(runtime?.process?.run) != 'function' ||
	    type(runtime?.clock?.now) != 'function' || type(runtime?.random?.hex) != 'function' ||
	    runtime?.paths?.tmp != '/tmp/miclash' || type(options) != 'object')
		invalid();
	for (let name in options)
		if (!exists(OPTION_FIELDS, name))
			invalid();
	let url = schema.url(options.url);
	let insecure = match(url, /^http:\/\//) != null;
	if (options.managed != null && type(options.managed) != 'bool' ||
	    options.allow_insecure_http != null && type(options.allow_insecure_http) != 'bool' ||
	    insecure && (options.managed === true || options.allow_insecure_http !== true))
		invalid();
	let connect = options.connect_timeout_ms ?? 8000;
	let total = options.timeout_ms ?? 120000;
	let redirects = options.max_redirects ?? 3;
	let maximum = options.max_bytes ?? 1048576;
	if (type(connect) != 'int' || connect < 1 || connect > 60000 ||
	    type(total) != 'int' || total < connect || total > 600000 ||
	    type(redirects) != 'int' || redirects < 0 || redirects > 10 ||
	    type(maximum) != 'int' || maximum < 1 || maximum > 16777216)
		invalid();
	let headers = options.headers ?? {};
	if (type(headers) != 'object')
		invalid();
	let seen_headers = {};
	for (let name, value in headers) {
		if (!match(name, /^[A-Za-z0-9-]+$/) || type(value) != 'string' ||
		    !length(value) || length(value) > 4096 || match(value, /[[:cntrl:]]/))
			invalid();
		let normalized = lc(name);
		if (exists(seen_headers, normalized))
			invalid();
		seen_headers[normalized] = true;
	}
	return { url, connect, total, redirects, maximum, headers, insecure };
};

export function request(runtime, options) {
	let clean = clean_options(runtime, options);
	ensure_root(runtime);
	let output = null, header = null;
	let result = null;
	let failure = null;
	try {
		output = candidate(runtime, 'body');
		header = candidate(runtime, 'headers');
		let args = [ '--silent', '--show-error', '--location', '--proto', '=http,https',
			'--proto-redir', clean.insecure ? '=http,https' : '=https',
			'--connect-timeout', sprintf('%.3f', clean.connect / 1000.0),
			'--max-time', sprintf('%.3f', clean.total / 1000.0),
			'--max-redirs', sprintf('%d', clean.redirects),
			'--max-filesize', sprintf('%d', clean.maximum), '--dump-header', header.path,
			'--output', output.path ];
		for (let name, value in clean.headers)
			push(args, '--header', name + ': ' + value);
		push(args, '--', clean.url);
		let reply = runtime.process.run({
			command: '/usr/bin/curl', args, timeout_ms: clean.total
		});
		if (!adapter_reply(reply))
			errors.fail('INTERNAL');
		if (reply.code != 0)
			errors.fail('DOWNLOAD_FAILED');
		let parsed = parse_headers(read_bounded(runtime, header, HEADER_LIMIT),
			clean.url, clean.redirects);
		let body = read_bounded(runtime, output, clean.maximum);
		result = { status: parsed.status, headers: parsed.headers, body,
			url: clean.url, insecure: clean.insecure };
	}
	catch (error) { failure = errors.normalize(error).code; }
	for (let owned in [ header, output ]) {
		if (owned == null)
			continue;
		try {
			let current = runtime.fs.lstat(owned.path);
			if (!same_node(owned.identity, current) || runtime.fs.realpath(owned.path) != owned.path ||
			    runtime.fs.unlink(owned.path) != true)
				failure = 'INTERNAL';
		}
		catch (error) { failure = 'INTERNAL'; }
	}
	if (failure != null)
		errors.fail(failure);
	return result;
};

export function download(runtime, options) {
	return request(runtime, options);
};
