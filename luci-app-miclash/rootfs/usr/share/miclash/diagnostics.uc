import * as errors from 'miclash.errors';
import * as redact from 'miclash.redact';

const ROOT = '/tmp/miclash/diagnostics';
const TTL = 900000;
const MAX_REPORT = 131072;
const RETENTION = 5;
const MAX_ROOT_ENTRIES = 32;
const MAX_DEPTH = 16;
const MAX_NODES = 4096;
const MAX_INPUT = 131072;
const MAX_STRING = 16384;
const MAX_RAW_SECRETS = 64;
const MAX_SECRET_VARIANTS = 256;

function invalid() { errors.fail('INVALID_ARGUMENT'); };
function clone(value) {
	try { return json(sprintf('%J', value)); }
	catch (error) { errors.fail('INTERNAL'); }
};
function same_node(left, right) {
	return left?.type == right?.type && left?.inode == right?.inode &&
		left?.dev?.major == right?.dev?.major && left?.dev?.minor == right?.dev?.minor;
};
function add_secret(secrets, value) {
	if (type(value) != 'string' || !length(value) || length(value) > MAX_STRING ||
		value == redact.MASK || value == '***')
		return;
	for (let existing in secrets)
		if (existing == value)
			return;
	if (length(secrets) >= MAX_RAW_SECRETS) errors.fail('RESPONSE_TOO_LARGE');
	push(secrets, value);
};
function discover_marker(secrets, input, marker) {
	let lowered = lc(input), offset = 0;
	while (offset < length(input)) {
		let relative = index(substr(lowered, offset), marker);
		if (relative < 0) return;
		let start = offset + relative + length(marker);
		while (start < length(input) && match(substr(input, start, 1), /[ \t]/)) start++;
		let end = start;
		while (end < length(input) &&
		       !match(substr(input, end, 1), /[[:space:],;'"<>]/)) end++;
		if (end > start) add_secret(secrets, substr(input, start, end - start));
		offset = max(end, offset + relative + length(marker));
	}
};
function discover_text(secrets, input) {
	for (let marker in [ 'bearer ', 'password=', 'password:', 'passwd=', 'passwd:',
		'secret=', 'secret:', 'token=', 'token:', 'api_key=', 'api_key:',
		'api-key=', 'api-key:', 'authorization=', 'authorization:',
		'basic ', 'cookie=', 'cookie:' ])
		discover_marker(secrets, input, marker);
	let lowered = lc(input), offset = 0;
	while (offset < length(input)) {
		let relative = index(substr(lowered, offset), 'cookie:');
		if (relative < 0) break;
		let start = offset + relative + 7, end = start;
		while (end < length(input) && substr(input, end, 1) != '\n' &&
			substr(input, end, 1) != '\r') end++;
		for (let pair in split(substr(input, start, end - start), ';')) {
			let separator = index(pair, '=');
			if (separator >= 0) {
				let value = trim(substr(pair, separator + 1));
				if (length(value) >= 2 &&
					((substr(value, 0, 1) == '"' && substr(value, -1) == '"') ||
					 (substr(value, 0, 1) == "'" && substr(value, -1) == "'")))
					value = substr(value, 1, length(value) - 2);
				add_secret(secrets, value);
			}
		}
		offset = max(end + 1, start);
	}
};
function validate_and_discover(value) {
	let secrets = [], stack = [ { value, key: null, depth: 0, sensitive: false } ];
	let nodes = 0, aggregate = 0;
	while (length(stack)) {
		let item = pop(stack), kind = type(item.value);
		if (item.depth > MAX_DEPTH || ++nodes > MAX_NODES)
			errors.fail('RESPONSE_TOO_LARGE');
		let sensitive = item.sensitive;
		if (type(item.key) == 'string') {
			if (length(item.key) > MAX_STRING) errors.fail('RESPONSE_TOO_LARGE');
			aggregate += length(item.key);
			discover_text(secrets, item.key);
			sensitive = sensitive || redact.secret_name(item.key);
		}
		if (kind == 'string') {
			if (length(item.value) > MAX_STRING) errors.fail('RESPONSE_TOO_LARGE');
			aggregate += length(item.value);
			discover_text(secrets, item.value);
			if (sensitive) add_secret(secrets, item.value);
		}
		else if (kind == 'array')
			for (let child in item.value)
				push(stack, { value: child, key: null, depth: item.depth + 1, sensitive });
		else if (kind == 'object')
			for (let name, child in item.value)
				push(stack, { value: child, key: name, depth: item.depth + 1, sensitive });
		else if (kind != 'null' && kind != 'bool' && kind != 'int' && kind != 'double')
			errors.fail('INVALID_RESPONSE');
		if (aggregate > MAX_INPUT) errors.fail('RESPONSE_TOO_LARGE');
	}
	return secrets;
};
function percent_variant(value, encode_all) {
	let output = '';
	for (let offset = 0; offset < length(value); offset++) {
		let character = substr(value, offset, 1);
		output += !encode_all && match(character, /^[A-Za-z0-9_.~-]$/) ?
			character : sprintf('%%%02X', ord(value, offset));
	}
	return output;
};
function variants(raw) {
	let output = [];
	function add(value) {
		if (type(value) != 'string' || !length(value) || length(value) > MAX_INPUT)
			return;
		for (let existing in output) if (existing == value) return;
		if (length(output) >= MAX_SECRET_VARIANTS) errors.fail('RESPONSE_TOO_LARGE');
		push(output, value);
	};
	for (let secret in raw) {
		add(secret);
		add(percent_variant(secret, false));
		add(lc(percent_variant(secret, false)));
		add(percent_variant(secret, true));
		add(lc(percent_variant(secret, true)));
		try {
			let base64 = b64enc(secret);
			let urlsafe = replace(replace(base64, /\+/g, '-'), /\//g, '_');
			add(base64);
			add(urlsafe);
			add(replace(base64, /=+$/, ''));
			add(replace(urlsafe, /=+$/, ''));
		}
		catch (error) {}
	}
	sort(output, (left, right) => length(right) - length(left));
	return output;
};
function replace_all(input, wanted, replacement) {
	if (!length(wanted)) return input;
	let result = '', rest = input;
	while (true) {
		let position = index(rest, wanted);
		if (position < 0) return result + rest;
		result += substr(rest, 0, position) + replacement;
		rest = substr(rest, position + length(wanted));
	}
};
function scrub_string(value, secrets) {
	let output = redact.text(value);
	for (let secret in secrets)
		output = replace_all(output, secret, redact.MASK);
	return output;
};
function scrub(value, secrets, depth) {
	if (type(value) == 'array') {
		let output = [];
		for (let item in value) push(output, scrub(item, secrets, depth + 1));
		return output;
	}
	if (type(value) == 'object') {
		let output = {};
		for (let name, item in value) {
			let safe_name = scrub_string(name, secrets);
			if (exists(output, safe_name)) errors.fail('INVALID_RESPONSE');
			output[safe_name] = redact.secret_name(name) ? redact.MASK :
				scrub(item, secrets, depth + 1);
		}
		return output;
	}
	if (type(value) != 'string') return value;
	return scrub_string(value, secrets);
};
function sanitize(value) {
	let secrets = variants(validate_and_discover(value));
	let safe = scrub(value, secrets, 0);
	if (length(sprintf('%J', safe)) > MAX_REPORT)
		errors.fail('RESPONSE_TOO_LARGE');
	return safe;
};
function call(source, name) {
	try { return source[name](); }
	catch (error) { return { state: 'unknown', code: 'UNAVAILABLE' }; }
};
function collect(sources) {
	let result = {};
	for (let name in [ 'versions', 'architecture', 'state', 'health', 'memory',
		'updates', 'settings', 'last_repair', 'config', 'process', 'logs', 'uci',
		'operations' ])
		result[name] = call(sources, name);
	let telegram = result.settings?.telegram;
	let url = result.settings?.core?.subscription_url;
	let transport = type(url) == 'string' && match(lc(url), /^https:\/\//) ? 'https' :
		(type(url) == 'string' && match(lc(url), /^http:\/\//) ? 'http' : 'none');
	result.public_status = {
		telegram: {
			enabled: telegram?.enabled === true,
			configured: type(telegram?.token) == 'string' && length(telegram.token) > 0 &&
				type(telegram?.user_id) == 'string' && length(telegram.user_id) > 0
		},
		subscription: {
			configured: type(url) == 'string' && length(url) > 0,
			transport,
			insecure: transport == 'http'
		}
	};
	return sanitize(result);
};
function make_summary(safe, now) {
	return {
		schema_version: 1,
		generated_at: now,
		versions: safe.versions,
		architecture: safe.architecture,
		state: {
			desired: safe.state?.desired ?? {},
			observed: safe.state?.observed ?? {}
		},
		health: safe.health,
		memory: safe.memory,
		updates: safe.updates,
		telegram: safe.public_status.telegram,
		subscription: safe.public_status.subscription,
		last_repair: safe.last_repair
	};
};
function verify_directory(runtime, path, identity) {
	let current = runtime.fs.lstat(path);
	if (current?.type != 'directory' || (identity != null && !same_node(identity, current)) ||
		current.mode != 0o700 || (current.uid != null && current.uid != 0) ||
		runtime.fs.realpath(path) != path)
		errors.fail('INTERNAL');
	return current;
};
function ensure_directory(runtime, path) {
	let current = runtime.fs.lstat(path);
	if (current == null && runtime.fs.mkdir(path) !== true)
		errors.fail('INTERNAL');
	current = runtime.fs.lstat(path);
	if (current?.type != 'directory' || runtime.fs.realpath(path) != path ||
		(current.uid != null && current.uid != 0) || runtime.fs.chmod(path, 0o700) !== true)
		errors.fail('INTERNAL');
	return verify_directory(runtime, path, current);
};
function safe_file(runtime, path, identity) {
	let current = runtime.fs.lstat(path);
	if (current?.type != 'file' || current.nlink != 1 ||
		(identity != null && !same_node(identity, current)) || current.mode != 0o600 ||
		(current.uid != null && current.uid != 0) || runtime.fs.realpath(path) != path)
		errors.fail('CORRUPT_STATE');
	return current;
};
function remove_scanned(runtime, root, name) {
	if (!match(name, /^report-[0-9a-f]{32}$/)) errors.fail('CORRUPT_STATE');
	let path = ROOT + '/' + name, identity = runtime.fs.lstat(path);
	if (identity?.type != 'directory' || identity.mode != 0o700 ||
		(identity.uid != null && identity.uid != 0) || runtime.fs.realpath(path) != path)
		errors.fail('CORRUPT_STATE');
	let entries = runtime.fs.lsdir(path);
	if (type(entries) != 'array' || length(entries) != 2 ||
		index(entries, 'report.json') < 0 || index(entries, 'report.txt') < 0)
		errors.fail('CORRUPT_STATE');
	for (let leaf in [ 'report.json', 'report.txt' ]) {
		let file = path + '/' + leaf, file_identity = safe_file(runtime, file, null);
		verify_directory(runtime, ROOT, root);
		if (!same_node(file_identity, runtime.fs.lstat(file)) || runtime.fs.unlink(file) !== true)
			errors.fail('INTERNAL');
	}
	verify_directory(runtime, path, identity);
	verify_directory(runtime, ROOT, root);
	if (runtime.fs.rmdir(path) !== true) errors.fail('INTERNAL');
	verify_directory(runtime, ROOT, root);
};
function remove_staging(runtime, root, name) {
	if (!match(name, /^\.stage-[0-9a-f]{32}$/)) errors.fail('CORRUPT_STATE');
	let path = ROOT + '/' + name, identity = runtime.fs.lstat(path);
	if (identity?.type != 'directory' || (identity.uid != null && identity.uid != 0) ||
		(identity.mode & 0o022) != 0 || runtime.fs.realpath(path) != path)
		errors.fail('CORRUPT_STATE');
	let entries = runtime.fs.lsdir(path);
	if (type(entries) != 'array' || length(entries) > 2)
		errors.fail('CORRUPT_STATE');
	for (let leaf in entries) {
		if (leaf != 'report.json' && leaf != 'report.txt') errors.fail('CORRUPT_STATE');
		let file = path + '/' + leaf, file_identity = safe_file(runtime, file, null);
		verify_directory(runtime, ROOT, root);
		if (!same_node(file_identity, runtime.fs.lstat(file)) || runtime.fs.unlink(file) !== true)
			errors.fail('INTERNAL');
	}
	let current = runtime.fs.lstat(path);
	if (!same_node(identity, current) || current?.type != 'directory' ||
		(current.uid != null && current.uid != 0) || (current.mode & 0o022) != 0 ||
		runtime.fs.realpath(path) != path)
		errors.fail('INTERNAL');
	verify_directory(runtime, ROOT, root);
	if (runtime.fs.rmdir(path) !== true) errors.fail('INTERNAL');
	verify_directory(runtime, ROOT, root);
};
function recover_reports(runtime, root) {
	let names = runtime.fs.lsdir(ROOT);
	if (type(names) != 'array') errors.fail('INTERNAL');
	if (length(names) > MAX_ROOT_ENTRIES) errors.fail('RESPONSE_TOO_LARGE');
	for (let name in names)
		if (match(name, /^report-[0-9a-f]{32}$/)) remove_scanned(runtime, root, name);
		else if (match(name, /^\.stage-[0-9a-f]{32}$/)) remove_staging(runtime, root, name);
		else errors.fail('CORRUPT_STATE');
};
function cleanup_creation(runtime, root, stage_name, final_name) {
	let failure = null;
	try {
		if (runtime.fs.lstat(ROOT + '/' + stage_name) != null)
			remove_staging(runtime, root, stage_name);
	}
	catch (error) { failure = 'INTERNAL'; }
	try {
		if (runtime.fs.lstat(ROOT + '/' + final_name) != null)
			remove_scanned(runtime, root, final_name);
	}
	catch (error) { failure = 'INTERNAL'; }
	if (failure != null) errors.fail(failure);
	return true;
};
function write_file(runtime, directory, path, content) {
	if (type(content) != 'string' || length(content) > MAX_REPORT)
		errors.fail('RESPONSE_TOO_LARGE');
	verify_directory(runtime, directory.path, directory.identity);
	let handle = runtime.fs.open(path, 'wx', 0o600);
	if (handle == null) errors.fail('INTERNAL');
	let opened = runtime.fs.fstat(handle), offset = 0, failure = null;
	if (opened?.type != 'file' || opened.nlink != 1) failure = 'INTERNAL';
	try {
		while (failure == null && offset < length(content)) {
			let amount = runtime.fs.write(handle, substr(content, offset));
			if (type(amount) != 'int' || amount < 1) errors.fail('INTERNAL');
			offset += amount;
		}
		if (runtime.fs.flush(handle) !== true) errors.fail('INTERNAL');
	}
	catch (error) { failure = errors.normalize(error).code; }
	if (runtime.fs.close(handle) !== true) failure = 'INTERNAL';
	if (failure == null && runtime.fs.chmod(path, 0o600) !== true) failure = 'INTERNAL';
	let current = runtime.fs.lstat(path);
	if (failure != null || !same_node(opened, current) || current?.nlink != 1 || current.mode != 0o600 ||
		(current.uid != null && current.uid != 0) || runtime.fs.realpath(path) != path ||
		current.size != length(content) || runtime.digest.sha256_file(path) != runtime.digest.sha256(content)) {
		if (same_node(opened, current) && current?.type == 'file' && current.nlink == 1 &&
			runtime.fs.realpath(path) == path)
			try { runtime.fs.unlink(path); } catch (cleanup_error) {}
		errors.fail(failure ?? 'INTERNAL');
	}
	verify_directory(runtime, directory.path, directory.identity);
	return { path, identity: current, hash: runtime.digest.sha256(content) };
};
function read_file(runtime, directory, record) {
	verify_directory(runtime, directory.path, directory.identity);
	let leaf = runtime.fs.lstat(record.path);
	if (!same_node(record.identity, leaf) || leaf?.nlink != 1 || leaf?.mode != 0o600 ||
		(leaf.uid != null && leaf.uid != 0) || runtime.fs.realpath(record.path) != record.path)
		errors.fail('INTERNAL');
	let handle = runtime.fs.open(record.path, 're');
	if (handle == null) errors.fail('INTERNAL');
	let before = runtime.fs.fstat(handle), content = '', failure = null;
	try {
		while (length(content) <= MAX_REPORT) {
			let chunk = runtime.fs.read(handle, 4096);
			if (type(chunk) != 'string') errors.fail('INTERNAL');
			if (!length(chunk)) break;
			content += chunk;
		}
	}
	catch (error) { failure = 'INTERNAL'; }
	let after = runtime.fs.fstat(handle);
	if (runtime.fs.close(handle) !== true) failure = 'INTERNAL';
	let final = runtime.fs.lstat(record.path);
	if (failure != null || length(content) > MAX_REPORT || before?.nlink != 1 || after?.nlink != 1 ||
		!same_node(record.identity, before) || !same_node(before, after) ||
		runtime.digest.sha256(content) != record.hash || runtime.digest.sha256_file(record.path) != record.hash ||
		!same_node(record.identity, final) || final?.nlink != 1 || final.mode != 0o600 ||
		(final.uid != null && final.uid != 0) || runtime.fs.realpath(record.path) != record.path)
		errors.fail('INTERNAL');
	verify_directory(runtime, directory.path, directory.identity);
	return content;
};
export function create(dependencies) {
	let runtime = dependencies?.runtime, sources = dependencies?.sources;
	if (type(runtime?.fs) != 'object' || type(runtime?.clock?.now) != 'function' ||
		type(runtime?.random?.hex) != 'function' || type(runtime?.digest?.sha256) != 'function' ||
		type(runtime?.digest?.sha256_file) != 'function' ||
		runtime?.paths?.tmp != '/tmp/miclash' || type(sources) != 'object')
		invalid();
	for (let name in [ 'versions', 'architecture', 'state', 'health', 'memory',
		'updates', 'settings', 'last_repair', 'config', 'process', 'logs', 'uci',
		'operations' ])
		if (type(sources[name]) != 'function') invalid();
	ensure_directory(runtime, runtime.paths.tmp);
	let root = ensure_directory(runtime, ROOT);
	recover_reports(runtime, root);
	let reports = {}, report_order = [];
	function forget(id) {
		let next = [];
		for (let existing in report_order)
			if (existing != id) push(next, existing);
		report_order = next;
		delete reports[id];
	};
	function remove_report(id) {
		let report = reports[id];
		if (report == null) return false;
		verify_directory(runtime, ROOT, root);
		verify_directory(runtime, report.directory.path, report.directory.identity);
		let names = runtime.fs.lsdir(report.directory.path);
		if (type(names) != 'array' || length(names) != 2 ||
			index(names, 'report.json') < 0 || index(names, 'report.txt') < 0)
			errors.fail('INTERNAL');
		for (let format in [ 'json', 'text' ]) {
			let file = report.files[format];
			safe_file(runtime, file.path, file.identity);
			if (!same_node(file.identity, runtime.fs.lstat(file.path)) ||
				runtime.digest.sha256_file(file.path) != file.hash ||
				runtime.fs.unlink(file.path) !== true)
				errors.fail('INTERNAL');
		}
		verify_directory(runtime, report.directory.path, report.directory.identity);
		if (runtime.fs.rmdir(report.directory.path) !== true) errors.fail('INTERNAL');
		verify_directory(runtime, ROOT, root);
		forget(id);
		return true;
	};
	function prune() {
		let now = runtime.clock.now();
		for (let id in [ ...report_order ])
			if (reports[id]?.expires_at <= now) remove_report(id);
		while (length(report_order) >= RETENTION)
			remove_report(report_order[0]);
	};
	return {
		summary: (...args) => {
			if (length(args)) invalid();
			return clone(make_summary(collect(sources), runtime.clock.now()));
		},
		create_report: (...args) => {
			if (length(args)) invalid();
			prune();
			ensure_directory(runtime, runtime.paths.tmp);
			root = verify_directory(runtime, ROOT, root);
			if (runtime.fs.realpath(ROOT) != ROOT || !same_node(root, runtime.fs.lstat(ROOT)))
				errors.fail('INTERNAL');
			let id = null;
			for (let attempt = 0; attempt < 16 && id == null; attempt++) {
				let candidate = 'rpt_' + runtime.random.hex(16);
				if (!match(candidate, /^rpt_[0-9a-f]{32}$/)) errors.fail('INTERNAL');
				if (reports[candidate] == null) id = candidate;
			}
			if (id == null) errors.fail('INTERNAL');
			let stage_name = null, final_name = null, path = null, stage_created = false;
			let creation_failure = null;
			for (let attempt = 0; attempt < 16 && path == null; attempt++) {
				let token = runtime.random.hex(16);
				if (!match(token, /^[0-9a-f]{32}$/)) errors.fail('INTERNAL');
				stage_name = '.stage-' + token;
				final_name = 'report-' + token;
				let candidate = ROOT + '/' + stage_name;
				if (runtime.fs.lstat(candidate) != null ||
				    runtime.fs.lstat(ROOT + '/' + final_name) != null) continue;
				try {
					if (runtime.fs.mkdir(candidate) !== true) {
						if (runtime.fs.lstat(candidate) != null) continue;
						errors.fail('INTERNAL');
					}
					stage_created = true;
					path = candidate;
				}
				catch (error) {
					creation_failure = errors.normalize(error).code;
					try { stage_created = runtime.fs.lstat(candidate) != null; }
					catch (capture_error) { stage_created = false; }
					path = candidate;
					break;
				}
			}
			if (path == null) errors.fail('INTERNAL');
			if (creation_failure != null) {
				if (stage_created)
					try { cleanup_creation(runtime, root, stage_name, final_name); }
					catch (cleanup_error) { creation_failure = 'INTERNAL'; }
				errors.fail(creation_failure);
			}
			let directory = null;
			let now = runtime.clock.now(), files = {}, failure = null;
			try {
				let initial = runtime.fs.lstat(path);
				if (initial?.type != 'directory' || (initial.uid != null && initial.uid != 0) ||
					(initial.mode & 0o022) != 0 || runtime.fs.realpath(path) != path)
					errors.fail('INTERNAL');
				if (runtime.fs.chmod(path, 0o700) !== true) errors.fail('INTERNAL');
				directory = { path, identity: verify_directory(runtime, path, initial) };
				let safe = collect(sources);
				let summary = make_summary(safe, now);
				let report = { schema_version: 1, generated_at: now, summary,
					details: { config: safe.config, process: safe.process, logs: safe.logs,
						uci: safe.uci, operations: safe.operations } };
				let json_text = sprintf('%J\n', report);
				let text = 'MiClash diagnostic report\nGenerated: ' + now + '\n' +
					'Architecture: ' + summary.architecture + '\n' +
					'Mihomo health: ' + (summary.health?.mihomo?.state ?? 'unknown') + '\n';
				if (length(json_text) + length(text) > MAX_REPORT)
					errors.fail('RESPONSE_TOO_LARGE');
				files.json = write_file(runtime, directory, path + '/report.json', json_text);
				files.text = write_file(runtime, directory, path + '/report.txt', text);
				verify_directory(runtime, ROOT, root);
				verify_directory(runtime, directory.path, directory.identity);
				if (runtime.fs.lstat(ROOT + '/' + final_name) != null ||
					runtime.fs.rename(path, ROOT + '/' + final_name) !== true)
					errors.fail('INTERNAL');
				let final_path = ROOT + '/' + final_name;
				let final_identity = runtime.fs.lstat(final_path);
				if (!same_node(directory.identity, final_identity) ||
					runtime.fs.realpath(final_path) != final_path || runtime.fs.lstat(path) != null)
					errors.fail('INTERNAL');
				directory = { path: final_path,
					identity: verify_directory(runtime, final_path, final_identity) };
				for (let format in [ 'json', 'text' ]) {
					let name = format == 'json' ? 'report.json' : 'report.txt';
					let final_file = final_path + '/' + name;
					let identity = safe_file(runtime, final_file, files[format].identity);
					if (runtime.digest.sha256_file(final_file) != files[format].hash)
						errors.fail('INTERNAL');
					files[format].path = final_file;
					files[format].identity = identity;
				}
			}
			catch (error) { failure = errors.normalize(error).code; }
			if (failure != null) {
				try { cleanup_creation(runtime, root, stage_name, final_name); }
				catch (cleanup_error) { failure = 'INTERNAL'; }
				errors.fail(failure);
			}
			reports[id] = { directory, files, created_at: now, expires_at: now + TTL };
			push(report_order, id);
			return { id, created_at: now, expires_at: now + TTL,
				files: [ 'report.json', 'report.txt' ] };
		},
		read_report: (...args) => {
			if (length(args) != 1) invalid();
			let options = args[0];
			if (type(options) != 'object' || length(keys(options)) != 2 ||
				!exists(options, 'id') || !exists(options, 'format') ||
				type(options.id) != 'string' || !match(options.id, /^rpt_[0-9a-f]{32}$/) ||
				(options.format != 'json' && options.format != 'text')) invalid();
			let report = reports[options.id];
			if (report != null && runtime.clock.now() >= report.expires_at) {
				remove_report(options.id);
				report = null;
			}
			if (report == null)
				errors.fail('NOT_FOUND');
			return { id: options.id, format: options.format,
				content: read_file(runtime, report.directory, report.files[options.format]),
				expires_at: report.expires_at };
		}
	};
};
