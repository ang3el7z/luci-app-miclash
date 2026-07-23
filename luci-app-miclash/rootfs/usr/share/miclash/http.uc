import * as errors from 'miclash.errors';
import * as schema from 'miclash.schema';

const HTTP_PARENT = '/tmp/miclash';
const HTTP_ROOT = '/tmp/miclash/http';
const HEADER_LIMIT = 65536;
const BODY_FILE_LIMIT = 1048576;
const OPTION_FIELDS = {
	url: true, headers: true, connect_timeout_ms: true, timeout_ms: true,
	max_redirects: true, max_bytes: true, managed: true, allow_insecure_http: true,
	accept_statuses: true, method: true, body: true, body_file: true
};
const GITHUB_PROXY = 'https://gh-proxy.com/';
const RETRYABLE_CURL_CODES = { '5': true, '6': true, '7': true, '28': true,
	'35': true, '52': true, '55': true, '56': true };

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
	       left.dev?.minor == right.dev?.minor && left.nlink == 1 && right.nlink == 1 &&
	       left.mode == 0o600 && right.mode == 0o600 &&
	       (left.uid == null || left.uid == 0) && (right.uid == null || right.uid == 0);
};

function same_object(left, right) {
	return left?.type != null && left.type == right?.type && left.inode == right?.inode &&
	       left.dev?.major == right.dev?.major && left.dev?.minor == right.dev?.minor;
};

function verify_directory(runtime, path, identity) {
	let current = runtime.fs.lstat(path);
	if (!same_object(identity, current) || current?.type != 'directory' ||
	    runtime.fs.realpath(path) != path || current.mode != 0o700 ||
	    (current.uid != null && current.uid != 0))
		errors.fail('INTERNAL');
	return current;
};

function secure_directory(runtime, path) {
	let identity = runtime.fs.lstat(path);
	if (identity == null) {
		if (runtime.fs.mkdir(path) != true)
			errors.fail('INTERNAL');
		identity = runtime.fs.lstat(path);
	}
	if (identity?.type != 'directory' || runtime.fs.realpath(path) != path ||
	    (identity.uid != null && identity.uid != 0) ||
	    runtime.fs.chmod(path, 0o700) != true)
		errors.fail('INTERNAL');
	return verify_directory(runtime, path, identity);
};

function ensure_root(runtime) {
	let authority = {
		parent: secure_directory(runtime, HTTP_PARENT),
		root: secure_directory(runtime, HTTP_ROOT)
	};
	verify_directory(runtime, HTTP_PARENT, authority.parent);
	verify_directory(runtime, HTTP_ROOT, authority.root);
	return authority;
};

function verify_authority(runtime, authority) {
	verify_directory(runtime, HTTP_PARENT, authority.parent);
	verify_directory(runtime, HTTP_ROOT, authority.root);
};

function verify_candidate(runtime, owned) {
	let current = runtime.fs.lstat(owned.path);
	if (!same_node(owned.identity, current) || runtime.fs.realpath(owned.path) != owned.path)
		errors.fail('INTERNAL');
};

function write_all(runtime, handle, content) {
	let offset = 0;
	while (offset < length(content)) {
		let amount = runtime.fs.write(handle, substr(content, offset));
		if (type(amount) != 'int' || amount < 1)
			errors.fail('INTERNAL');
		offset += amount;
	}
};

function write_owned(runtime, owned, writer) {
	verify_candidate(runtime, owned);
	let handle = runtime.fs.open(owned.path, 'r+');
	if (handle == null)
		errors.fail('INTERNAL');
	let opened = runtime.fs.fstat(handle), failure = null;
	try {
		if (!same_node(owned.identity, opened))
			errors.fail('INTERNAL');
		writer(handle);
		if (runtime.fs.flush(handle) !== true)
			errors.fail('INTERNAL');
	}
	catch (error) { failure = errors.normalize(error).code; }
	if (runtime.fs.close(handle) !== true)
		failure = 'INTERNAL';
	try { verify_candidate(runtime, owned); }
	catch (error) { failure = 'INTERNAL'; }
	if (failure != null)
		errors.fail(failure);
};

function candidate(runtime, suffix, content) {
	for (let attempt = 0; attempt < 16; attempt++) {
		let entropy = runtime.random.hex(8);
		if (type(entropy) != 'string' || !match(entropy, /^[0-9a-f]{16}$/))
			errors.fail('INTERNAL');
		let path = sprintf('%s/%d-%s-%s', HTTP_ROOT, runtime.clock.now(), entropy, suffix);
		let handle = runtime.fs.open(path, 'wx', 0o600);
		if (handle == null)
			continue;
		let opened = runtime.fs.fstat(handle);
		let written = true;
		if (content != null) {
			let offset = 0;
			while (offset < length(content)) {
				let amount = runtime.fs.write(handle, substr(content, offset));
				if (type(amount) != 'int' || amount < 1) { written = false; break; }
				offset += amount;
			}
			if (written && runtime.fs.flush(handle) != true)
				written = false;
		}
		if (runtime.fs.close(handle) != true || !written || opened?.type != 'file' ||
		    opened.nlink != 1 || opened.mode != 0o600 ||
		    (opened.uid != null && opened.uid != 0)) {
			try {
				let current = runtime.fs.lstat(path);
				if (same_node(opened, current) && runtime.fs.realpath(path) == path)
					runtime.fs.unlink(path);
			}
			catch (error) {}
			errors.fail('INTERNAL');
		}
		let identity = runtime.fs.lstat(path);
		if (!same_node(opened, identity) ||
		    runtime.fs.realpath(path) != path)
			errors.fail('INTERNAL');
		return { path, identity };
	}
	errors.fail('INTERNAL');
};

function curl_quote(value) {
	return '"' + replace(replace(value, /\\/g, '\\\\'), /"/g, '\\"') + '"';
};

function curl_config(clean, header_path, output_path, multipart) {
	let lines = [
		'silent', 'show-error', 'location', 'proto = "=http,https"',
		'proto-redir = ' + curl_quote(clean.insecure ? '=http,https' : '=https'),
		'connect-timeout = ' + curl_quote(sprintf('%.3f', clean.connect / 1000.0)),
		'max-time = ' + curl_quote(sprintf('%.3f', clean.total / 1000.0)),
		'max-redirs = ' + curl_quote(sprintf('%d', clean.redirects)),
		'max-filesize = ' + curl_quote(sprintf('%d', clean.maximum)),
		'dump-header = ' + curl_quote(header_path),
		'output = ' + curl_quote(output_path)
	];
	for (let name, value in clean.headers)
		push(lines, 'header = ' + curl_quote(name + ': ' + value));
	if (clean.method == 'POST') {
		push(lines, 'request = "POST"');
		if (multipart != null) {
			push(lines, 'header = ' +
				curl_quote('Content-Type: multipart/form-data; boundary=' + multipart.boundary));
			push(lines, 'data-binary = ' + curl_quote('@' + multipart.path));
		}
		else
			push(lines, 'data = ' + curl_quote(clean.body));
	}
	push(lines, 'url = ' + curl_quote(clean.url));
	return join('\n', lines) + '\n';
};

function descriptor_snapshot(file) {
	return {
		identity: file.identity, size: file.size, sha256: file.sha256,
		read: file.read, finish: file.finish, close: file.close
	};
};

function verify_descriptor(file, snapshot) {
	if (file.identity !== snapshot.identity || file.size != snapshot.size ||
	    file.sha256 != snapshot.sha256 || file.read !== snapshot.read ||
	    file.finish !== snapshot.finish || file.close !== snapshot.close)
		errors.fail('INTERNAL');
};

function release_descriptor(file) {
	try { return file.close() === true; }
	catch (error) { return false; }
};

function discard_candidate(runtime, owned) {
	try {
		verify_candidate(runtime, owned);
		return runtime.fs.unlink(owned.path) === true;
	}
	catch (error) { return false; }
};

function stage_upload(runtime, file, snapshot) {
	let upload = candidate(runtime, 'upload');
	try {
		write_owned(runtime, upload, (handle) => {
			let consumed = 0;
			while (consumed < snapshot.size) {
				let amount = min(49152, snapshot.size - consumed);
				let chunk = file.read(amount);
				if (type(chunk) != 'string' || !length(chunk) ||
				    length(chunk) > amount || consumed + length(chunk) > snapshot.size)
					errors.fail('INTERNAL');
				write_all(runtime, handle, chunk);
				consumed += length(chunk);
			}
			if (file.read(1) != '')
				errors.fail('INTERNAL');
		});
		verify_descriptor(file, snapshot);
		let current = runtime.fs.lstat(upload.path);
		if (!same_node(upload.identity, current) || current?.size != snapshot.size ||
		    runtime.fs.realpath(upload.path) != upload.path ||
		    runtime.digest.sha256_file(upload.path) != snapshot.sha256)
			errors.fail('INTERNAL');
		return upload;
	}
	catch (error) {
		let code = errors.normalize(error).code;
		if (!discard_candidate(runtime, upload))
			code = 'INTERNAL';
		errors.fail(code);
	}
};

function stage_multipart(runtime, clean, upload, boundary) {
	let multipart = candidate(runtime, 'multipart');
	try { write_owned(runtime, multipart, (handle) => {
		for (let name, value in clean.body_file.fields) {
			write_all(runtime, handle, '--' + boundary + '\r\n');
			write_all(runtime, handle,
				'Content-Disposition: form-data; name="' + name + '"\r\n\r\n');
			write_all(runtime, handle, sprintf('%s', value) + '\r\n');
		}
		write_all(runtime, handle, '--' + boundary + '\r\n');
		write_all(runtime, handle, 'Content-Disposition: form-data; name="' +
			clean.body_file.field + '"; filename="' + clean.body_file.filename + '"\r\n');
		write_all(runtime, handle, 'Content-Type: ' + clean.body_file.content_type +
			'\r\n\r\n');
		let source = runtime.fs.open(upload.path, 'r');
		if (source == null)
			errors.fail('INTERNAL');
		let opened = runtime.fs.fstat(source), failure = null;
		try {
			if (!same_node(upload.identity, opened))
				errors.fail('INTERNAL');
			while (true) {
				let chunk = runtime.fs.read(source, 49152);
				if (type(chunk) != 'string')
					errors.fail('INTERNAL');
				if (!length(chunk))
					break;
				write_all(runtime, handle, chunk);
			}
		}
		catch (error) { failure = errors.normalize(error).code; }
		if (runtime.fs.close(source) !== true)
			failure = 'INTERNAL';
		if (failure != null)
			errors.fail(failure);
		write_all(runtime, handle, '\r\n--' + boundary + '--\r\n');
		});
		verify_candidate(runtime, upload);
		if (runtime.digest.sha256_file(upload.path) != clean.body_file.sha256)
			errors.fail('INTERNAL');
		return { ...multipart, boundary };
	}
	catch (error) {
		let code = errors.normalize(error).code;
		if (!discard_candidate(runtime, multipart))
			code = 'INTERNAL';
		errors.fail(code);
	}
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

function parse_headers(input, original_url, maximum_redirects, accepted_statuses) {
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
	if ((final.status < 200 || final.status >= 300) &&
	    index(accepted_statuses, final.status) < 0)
		errors.fail('DOWNLOAD_FAILED');
	return final;
};

function clean_body_file(value) {
	if (type(value) != 'object' || type(value) == 'array' ||
	    length(keys(value)) != 10 ||
	    type(value.identity) != 'object' || type(value.identity) == 'array' ||
	    type(value.size) != 'int' || value.size < 1 || value.size > BODY_FILE_LIMIT ||
	    type(value.sha256) != 'string' || !match(value.sha256, /^[0-9a-f]{64}$/) ||
	    type(value.read) != 'function' || type(value.finish) != 'function' ||
	    type(value.close) != 'function' ||
	    type(value.field) != 'string' || !match(value.field, /^[a-z][a-z0-9_]{0,31}$/) ||
	    type(value.filename) != 'string' ||
	    !match(value.filename, /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/) ||
	    type(value.content_type) != 'string' ||
	    !match(value.content_type, /^[a-z0-9][a-z0-9.+-]{0,63}\/[a-z0-9][a-z0-9.+-]{0,63}$/) ||
	    type(value.fields) != 'object' || type(value.fields) == 'array' ||
	    !length(keys(value.fields)) || length(keys(value.fields)) > 16)
		invalid();
	let fields = {};
	for (let name, field in value.fields) {
		if (!match(name, /^[a-z][a-z0-9_]{0,31}$/) || name == value.field ||
		    (type(field) != 'string' && type(field) != 'int' && type(field) != 'bool'))
			invalid();
		let text = sprintf('%s', field);
		if (!length(text) || length(text) > 4096 || match(text, /[[:cntrl:]]/))
			invalid();
		fields[name] = text;
	}
	return { ...value, fields };
};

function clean_options(runtime, options) {
	if (type(runtime?.fs) != 'object' || type(runtime?.fs?.fstat) != 'function' ||
	    type(runtime?.process?.run) != 'function' ||
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
	let method = options.method ?? 'GET', body = options.body ?? null,
		body_file = options.body_file == null ? null : clean_body_file(options.body_file);
	if (body_file != null && type(runtime?.digest?.sha256_file) != 'function')
		invalid();
	if ((method != 'GET' && method != 'POST') ||
	    (method == 'GET' && (body != null || body_file != null)) ||
	    (method == 'POST' && ((body == null) == (body_file == null))) ||
	    (body != null && (type(body) != 'string' || length(body) > 65536 ||
	     match(body, /[[:cntrl:]]/))) ||
	    (body_file != null && options.managed !== true))
		invalid();
	if (body_file != null)
		for (let name in seen_headers)
			if (name == 'content-type')
				invalid();
	let accepted_statuses = options.accept_statuses ?? [];
	if (type(accepted_statuses) != 'array' || length(accepted_statuses) > 1 ||
	    length(accepted_statuses) && options.managed !== true)
		invalid();
	let seen_statuses = {};
	for (let status in accepted_statuses) {
		if (type(status) != 'int' || status != 429 ||
		    exists(seen_statuses, status))
			invalid();
		seen_statuses[status] = true;
	}
	return { url, connect, total, redirects, maximum, headers, insecure, method, body,
		body_file, accepted_statuses };
};

function github_proxy_url(url) {
	if (match(url,
	    /^https:\/\/(github\.com|api\.github\.com|raw\.githubusercontent\.com)\//))
		return GITHUB_PROXY + url;
	return null;
};

function request_session(runtime, clean, logical_url) {
	let authority = ensure_root(runtime);
	let output = null, header = null, config = null, upload = null, multipart = null,
		file_snapshot = clean.body_file == null ? null : descriptor_snapshot(clean.body_file),
		file_handed_off = false, file_released = false, closed = false;

	function cleanup() {
		if (closed)
			return true;
		closed = true;
		let valid = true;
		for (let owned in [ config, header, output, multipart, upload ]) {
			if (owned == null)
				continue;
			try {
				verify_authority(runtime, authority);
				let current = runtime.fs.lstat(owned.path);
				if (!same_node(owned.identity, current) ||
				    runtime.fs.realpath(owned.path) != owned.path ||
				    runtime.fs.unlink(owned.path) != true)
					valid = false;
			}
			catch (error) { valid = false; }
		}
		if (clean.body_file != null && !file_handed_off && !file_released) {
			file_released = true;
			if (!release_descriptor(clean.body_file))
				valid = false;
		}
		return valid;
	};

	try {
		if (clean.body_file != null) {
			verify_descriptor(clean.body_file, file_snapshot);
			verify_authority(runtime, authority);
			upload = stage_upload(runtime, clean.body_file, file_snapshot);
			let entropy = runtime.random.hex(16);
			if (type(entropy) != 'string' || !match(entropy, /^[0-9a-f]{32}$/))
				errors.fail('INTERNAL');
			let boundary = '----------------miclash-' + entropy;
			verify_authority(runtime, authority);
			multipart = stage_multipart(runtime, clean, upload, boundary);
			verify_descriptor(clean.body_file, file_snapshot);
		}
		verify_authority(runtime, authority);
		output = candidate(runtime, 'body');
		verify_authority(runtime, authority);
		header = candidate(runtime, 'headers');
		verify_authority(runtime, authority);
		config = candidate(runtime, 'curl-config',
			curl_config(clean, header.path, output.path, multipart));
		verify_authority(runtime, authority);
		verify_candidate(runtime, output);
		verify_candidate(runtime, header);
		verify_candidate(runtime, config);
		if (upload != null) {
			verify_candidate(runtime, upload);
			verify_candidate(runtime, multipart);
			if (runtime.digest.sha256_file(upload.path) != file_snapshot.sha256)
				errors.fail('INTERNAL');
		}
	}
	catch (error) {
		let failure = errors.normalize(error).code;
		if (!cleanup())
			failure = 'INTERNAL';
		errors.fail(failure);
	}

	function verify_ready() {
		verify_authority(runtime, authority);
		verify_candidate(runtime, output);
		verify_candidate(runtime, header);
		verify_candidate(runtime, config);
		if (upload != null) {
			verify_descriptor(clean.body_file, file_snapshot);
			verify_candidate(runtime, upload);
			verify_candidate(runtime, multipart);
			let current = runtime.fs.lstat(upload.path);
			if (current?.size != file_snapshot.size ||
			    runtime.digest.sha256_file(upload.path) != file_snapshot.sha256)
				errors.fail('INTERNAL');
		}
		return true;
	};

	function finish(code) {
		let result = null, failure = null, curl_code = null;
		try {
			if (closed || type(code) != 'int')
				errors.fail('INTERNAL');
			verify_ready();
			if (code != 0) {
				failure = 'DOWNLOAD_FAILED';
				curl_code = code;
			}
			else {
				let parsed = parse_headers(read_bounded(runtime, header, HEADER_LIMIT),
					clean.url, clean.redirects, clean.accepted_statuses);
				let body = read_bounded(runtime, output, clean.maximum);
				result = { status: parsed.status, headers: parsed.headers, body,
					url: logical_url, insecure: clean.insecure };
			}
			if (failure == null && clean.body_file != null) {
				verify_ready();
				file_handed_off = true;
			}
		}
		catch (error) {
			failure = errors.normalize(error).code;
			curl_code = null;
		}
		if (!cleanup())
			failure = 'INTERNAL';
		if (failure == 'INTERNAL')
			curl_code = null;
		return { result, failure, curl_code };
	};

	return {
		command: '/usr/bin/curl',
		args: [ '--config', config.path ],
		timeout_ms: clean.total,
		verify: verify_ready,
		finish,
		abort: cleanup
	};
};

function request_attempt(runtime, clean, logical_url) {
	let session;
	try {
		session = request_session(runtime, clean, logical_url);
		// curl only accepts output pathnames. Root-owned 0700 parent/root
		// authorities prevent unprivileged replacement in the remaining open
		// window; exact identities are checked on both sides of process.run().
		session.verify();
		let reply = runtime.process.run({
			command: session.command, args: session.args, timeout_ms: session.timeout_ms
		});
		if (!adapter_reply(reply))
			errors.fail('INTERNAL');
		return session.finish(reply.code);
	}
	catch (error) {
		let failure = errors.normalize(error).code;
		if (session != null && session.abort() !== true)
			failure = 'INTERNAL';
		return { result: null, failure, curl_code: null };
	}
};

export function begin(runtime, options) {
	let clean = clean_options(runtime, options);
	let session = request_session(runtime, clean, clean.url);
	return {
		command: session.command,
		args: session.args,
		timeout_ms: session.timeout_ms,
		complete: (code) => {
			let reply = session.finish(code);
			if (reply.failure != null)
				errors.fail(reply.failure);
			return reply.result;
		},
		abort: () => {
			if (session.abort() !== true)
				errors.fail('INTERNAL');
			return true;
		}
	};
};

export function request(runtime, options) {
	let clean = clean_options(runtime, options);
	let direct = request_attempt(runtime, clean, clean.url);
	if (direct.failure == null)
		return direct.result;
	let proxy_url = options.managed === true && RETRYABLE_CURL_CODES[direct.curl_code] === true
		? github_proxy_url(clean.url) : null;
	if (proxy_url != null) {
		try { runtime.logger?.warn('http: direct GitHub download failed; trying gh-proxy.com'); }
		catch (error) {}
		let proxied = request_attempt(runtime, { ...clean, url: proxy_url }, clean.url);
		if (proxied.failure == null)
			return proxied.result;
		errors.fail(proxied.failure);
	}
	errors.fail(direct.failure);
};

export function download(runtime, options) {
	return request(runtime, options);
};
