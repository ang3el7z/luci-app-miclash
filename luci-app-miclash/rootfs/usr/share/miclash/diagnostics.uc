import * as errors from 'miclash.errors';
import * as telegram_format from 'miclash.telegram-format';
import * as redact from 'miclash.redact';

const ROOT = '/tmp/miclash/diagnostics';
const TTL = 900000;
const MAX_REPORT = 786432;
const RETENTION = 5;
const MAX_ROOT_ENTRIES = 32;
const MAX_DEPTH = 16;
const MAX_NODES = 4096;
const MAX_INPUT = 131072;
const MAX_STRING = 16384;
const MAX_RAW_SECRETS = 64;
const MAX_SECRET_VARIANTS = 256;
const REPORT_MAX_DEPTH = 16;
const REPORT_MAX_NODES = 8192;
const REPORT_MAX_INPUT = 786432;
const REPORT_MAX_STRING = 131072;
const REPORT_SECTION_LIMITS = {
	process: 32768,
	logs: 262144,
	uci: 32768,
	operations: 65536
};

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
	for (let marker in [ 'bearer ', 'basic ', 'auth=', 'auth:',
		'authorization=', 'authorization:', 'cookie=', 'cookie:',
		'credential=', 'credential:', 'password=', 'password:', 'passwd=', 'passwd:',
		'secret=', 'secret:', 'session=', 'session:', 'token=', 'token:',
		'api_key=', 'api_key:', 'api-key=', 'api-key:',
		'private_key=', 'private_key:', 'private-key=', 'private-key:',
		'access_key=', 'access_key:', 'access-key=', 'access-key:',
		'client_secret=', 'client_secret:', 'client-secret=', 'client-secret:' ])
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
function validate_and_discover(value, limits) {
	let max_depth = limits?.max_depth ?? MAX_DEPTH;
	let max_nodes = limits?.max_nodes ?? MAX_NODES;
	let max_input = limits?.max_input ?? MAX_INPUT;
	let max_string = limits?.max_string ?? MAX_STRING;
	let secrets = [], stack = [ { value, key: null, depth: 0, sensitive: false } ];
	let nodes = 0, aggregate = 0;
	while (length(stack)) {
		let item = pop(stack), kind = type(item.value);
		if (item.depth > max_depth || ++nodes > max_nodes)
			errors.fail('RESPONSE_TOO_LARGE');
		let sensitive = item.sensitive;
		if (type(item.key) == 'string') {
			if (length(item.key) > max_string) errors.fail('RESPONSE_TOO_LARGE');
			aggregate += length(item.key);
			discover_text(secrets, item.key);
			sensitive = sensitive || redact.secret_name(item.key);
		}
		if (kind == 'string') {
			if (length(item.value) > max_string) errors.fail('RESPONSE_TOO_LARGE');
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
		else if (kind != null && kind != 'bool' && kind != 'int' && kind != 'double')
			errors.fail('INVALID_RESPONSE');
		if (aggregate > max_input) errors.fail('RESPONSE_TOO_LARGE');
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
function sanitize(value, limits) {
	let secrets = variants(validate_and_discover(value, limits));
	let safe = scrub(value, secrets, 0);
	if (length(sprintf('%J', safe)) > (limits?.max_output ?? MAX_REPORT))
		errors.fail('RESPONSE_TOO_LARGE');
	return safe;
};
function call(source, name) {
	try { return json(sprintf('%J', source[name]())); }
	catch (error) { return { state: 'unknown', code: 'UNAVAILABLE' }; }
};
function public_status(settings) {
	let telegram = settings?.telegram;
	let url = settings?.core?.subscription_url_config_yaml;
	if (type(url) != 'string' || !length(url))
		url = settings?.core?.subscription_url;
	let transport = type(url) == 'string' && match(lc(url), /^https:\/\//) ? 'https' :
		(type(url) == 'string' && match(lc(url), /^http:\/\//) ? 'http' : 'none');
	return {
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
};
function collect_summary(sources) {
	let result = {};
	for (let name in [ 'versions', 'architecture', 'state', 'health', 'memory',
		'updates', 'settings', 'telegram', 'network_components', 'last_repair' ])
		result[name] = call(sources, name);
	result.public_status = public_status(result.settings);
	return sanitize(result);
};
function serialized_size(value) {
	try { return length(sprintf('%J', value)); }
	catch (error) { errors.fail('INVALID_RESPONSE'); }
};
function bound_section(name, value, limit) {
	let original = type(value) == 'string' ? length(value) : serialized_size(value);
	let selected = value;
	if (original > limit) {
		if (type(value) == 'string')
			selected = name == 'logs' ? substr(value, max(0, length(value) - limit)) :
				substr(value, 0, limit);
		else if (type(value) == 'array') {
			selected = [];
			for (let index = length(value) - 1; index >= 0; index--) {
				let candidate = [ value[index], ...selected ];
				if (serialized_size(candidate) > limit) break;
				selected = candidate;
			}
		}
		else if (type(value) == 'object') {
			selected = {};
			for (let key, item in value) {
				selected[key] = item;
				if (serialized_size(selected) > limit) {
					delete selected[key];
					break;
				}
			}
		}
		else selected = { state: 'unknown', code: 'SECTION_TRUNCATED' };
	}
	let included = type(selected) == 'string' ? length(selected) : serialized_size(selected);
	return { value: selected, metadata: {
		truncated: original > included,
		original_bytes: original,
		included_bytes: included
	} };
};
function summarize_config(value, runtime) {
	if (type(value) != 'string')
		return { state: value?.state == 'unknown' ? 'unknown' : 'unavailable',
			code: value?.code ?? 'UNAVAILABLE' };
	let lines = length(value) ? length(split(value, '\n')) : 0;
	return {
		state: length(value) ? 'present' : 'empty',
		bytes: length(value),
		lines,
		sha256: runtime.digest.sha256(value)
	};
};
function log_entries(value) {
	if (type(value) == 'array') return value;
	if (type(value) != 'string') return value;
	let entries = [];
	for (let line in split(value, '\n'))
		if (length(line)) push(entries, line);
	return entries;
};
function collect(sources, runtime) {
	let result = {};
	for (let name in [ 'versions', 'architecture', 'state', 'health', 'memory',
		'updates', 'settings', 'telegram', 'network_components', 'last_repair' ])
		result[name] = call(sources, name);
	let sections = {};
	let raw_config = call(sources, 'config');
	result.config = summarize_config(raw_config, runtime);
	sections.config = {
		truncated: false,
		summarized: true,
		original_bytes: type(raw_config) == 'string' ? length(raw_config) : serialized_size(raw_config),
		included_bytes: serialized_size(result.config)
	};
	for (let name in [ 'process', 'uci', 'operations' ]) {
		let bounded = bound_section(name, call(sources, name), REPORT_SECTION_LIMITS[name]);
		result[name] = bounded.value;
		sections[name] = bounded.metadata;
	}
	let bounded_logs = bound_section('logs', log_entries(call(sources, 'logs')),
		REPORT_SECTION_LIMITS.logs);
	result.logs = bounded_logs.value;
	sections.logs = bounded_logs.metadata;
	result.evidence = type(sources.evidence) == 'function' ? call(sources, 'evidence') : [];
	result.public_status = public_status(result.settings);
	result.collection = { sections, evidence: result.evidence };
	return sanitize(result, {
		max_depth: REPORT_MAX_DEPTH,
		max_nodes: REPORT_MAX_NODES,
		max_input: REPORT_MAX_INPUT,
		max_string: REPORT_MAX_STRING,
		max_output: REPORT_MAX_INPUT
	});
};
function report_issues(safe) {
	let issues = [];
	function add(section, component, state, code, message) {
		if (length(issues) >= 64) return;
		if (state == null) return;
		let normalized = lc(sprintf('%s', state ?? 'unknown'));
		if (normalized == 'ok' || normalized == 'ready' || normalized == 'running' ||
			normalized == 'success' || normalized == 'idle' || normalized == 'completed' ||
			normalized == 'none' || normalized == 'inactive' || normalized == 'disabled' ||
			normalized == 'not_required' || normalized == 'present' ||
			normalized == 'active' || normalized == 'synchronized' ||
			normalized == 'system' || normalized == 'enabled') return;
		push(issues, {
			section,
			component: sprintf('%s', component ?? 'unknown'),
			severity: normalized == 'failed' || normalized == 'failure' || normalized == 'error' ||
				normalized == 'stopped' ?
				'error' : 'warning',
			state: normalized,
			code: code ?? null,
			message: message ?? null
		});
	};
	let components = safe.health?.components ?? safe.health?.observed?.readiness?.components ??
		safe.state?.observed?.readiness?.components ?? safe.health;
	if (type(components) == 'array')
		for (let item in components)
			if (type(item) == 'object') add('components', item.name ?? item.component,
				item.state, item.code, item.message);
	else if (type(components) == 'object')
		for (let name, item in components)
			if (type(item) == 'object') add('components', name, item.state, item.code, item.message);
	if (type(safe.operations) == 'array')
		for (let item in safe.operations)
			if (type(item) == 'object') add('operations', item.kind ?? item.id,
				item.state ?? item.result ?? item.outcome, item.code, item.error ?? item.message);
	if (type(safe.last_repair) == 'object' && length(safe.last_repair))
		add('automatic_recovery', safe.last_repair.component, safe.last_repair.state ??
			safe.last_repair.result ?? safe.last_repair.outcome, safe.last_repair.code,
			safe.last_repair.message ?? safe.last_repair.error);
	if (type(safe.evidence) == 'array')
		for (let entry in safe.evidence)
			if (type(entry) == 'object' && type(entry.value) == 'object')
				add('collection', entry.name, entry.value.state, entry.value.code,
					entry.value.message);
	return issues;
};
function compact_telegram(public_status, live) {
	let status = type(public_status) == 'object' ? public_status : {
		enabled: false, configured: false
	};
	return {
		enabled: status.enabled === true,
		configured: status.configured === true,
		running: live?.running === true,
		last_error: type(live?.last_error) == 'string' ? live.last_error :
			(live?.code == 'UNAVAILABLE' ? 'UNAVAILABLE' : null),
		failures: type(live?.failures) == 'int' && live.failures >= 0 ? live.failures : 0
	};
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
		components: safe.network_components,
		memory: safe.memory,
		updates: safe.updates,
		telegram: compact_telegram(safe.public_status.telegram, safe.telegram),
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
function remove_old_stream_report(runtime, root, path) {
	let directory = verify_directory(runtime, path, null);
	let entries = runtime.fs.lsdir(path);
	if (type(entries) != 'array' || length(entries) != 1 || entries[0] != 'report.json')
		errors.fail('CORRUPT_STATE');
	let file = path + '/report.json', identity = runtime.fs.lstat(file);
	if (identity?.type == 'file') safe_file(runtime, file, identity);
	else if (identity?.type != 'link') errors.fail('CORRUPT_STATE');
	verify_directory(runtime, path, directory);
	verify_directory(runtime, ROOT, root);
	if (!same_node(identity, runtime.fs.lstat(file)) || runtime.fs.unlink(file) !== true)
		errors.fail('INTERNAL');
	verify_directory(runtime, path, directory);
	verify_directory(runtime, ROOT, root);
	if (runtime.fs.rmdir(path) !== true) errors.fail('INTERNAL');
	verify_directory(runtime, ROOT, root);
};
function recover_reports(runtime, root) {
	let names = runtime.fs.lsdir(ROOT);
	if (type(names) != 'array') errors.fail('INTERNAL');
	if (length(names) > MAX_ROOT_ENTRIES) errors.fail('RESPONSE_TOO_LARGE');
	for (let name in names) {
		if (match(name, /^(\.stream-stage-|stream-report-)[0-9a-f]{32}$/))
			continue;
		if (!match(name, /^(\.stage-|report-)[0-9a-f]{32}$/))
			errors.fail('CORRUPT_STATE');
		if (match(name, /^report-/)) {
			let path = ROOT + '/' + name, entries = runtime.fs.lsdir(path);
			// Stream reports published before the namespace split used the
			// legacy report- prefix but always had exactly one JSON leaf.
			if (type(entries) == 'array' && length(entries) == 1 && entries[0] == 'report.json')
				remove_old_stream_report(runtime, root, path);
			else remove_scanned(runtime, root, name);
		}
		else remove_staging(runtime, root, name);
	}
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
function remove_stream_directory(runtime, root, path, expected_directory, expected_file) {
	let directory = verify_directory(runtime, path, expected_directory);
	let entries = runtime.fs.lsdir(path);
	if (type(entries) != 'array' || length(entries) != 1 || entries[0] != 'report.json')
		errors.fail('CORRUPT_STATE');
	let file = path + '/report.json', identity = runtime.fs.lstat(file);
	if (identity?.type == 'file') {
		if (expected_file != null) {
			if (!same_node(expected_file, identity) || identity.nlink != 1 ||
				(identity.uid != null && identity.uid != 0) || runtime.fs.realpath(file) != file)
				errors.fail('INTERNAL');
		}
		else safe_file(runtime, file, identity);
	}
	else if (identity?.type != 'link') errors.fail('CORRUPT_STATE');
	verify_directory(runtime, path, directory);
	verify_directory(runtime, ROOT, root);
	if (!same_node(identity, runtime.fs.lstat(file)) || runtime.fs.unlink(file) !== true)
		errors.fail('INTERNAL');
	verify_directory(runtime, path, directory);
	verify_directory(runtime, ROOT, root);
	if (runtime.fs.rmdir(path) !== true) errors.fail('INTERNAL');
	verify_directory(runtime, ROOT, root);
};
function remove_stream_stage(runtime, root, path, expected_directory, expected_file) {
	let directory = runtime.fs.lstat(path);
	if (directory?.type != 'directory' ||
		(expected_directory != null && !same_node(expected_directory, directory)) ||
		(directory.uid != null && directory.uid != 0) || (directory.mode & 0o022) != 0 ||
		runtime.fs.realpath(path) != path)
		errors.fail('CORRUPT_STATE');
	let entries = runtime.fs.lsdir(path);
	if (type(entries) != 'array' || length(entries) > 1 ||
		(length(entries) == 1 && entries[0] != 'report.json'))
		errors.fail('CORRUPT_STATE');
	if (length(entries)) {
		let file = path + '/report.json', identity = runtime.fs.lstat(file);
		if (identity?.type == 'file') {
			if (expected_file != null) {
				if (!same_node(expected_file, identity) || identity.nlink != 1 ||
					(identity.uid != null && identity.uid != 0) || runtime.fs.realpath(file) != file)
					errors.fail('INTERNAL');
			}
			else safe_file(runtime, file, identity);
		}
		else if (identity?.type != 'link') errors.fail('CORRUPT_STATE');
		let current = runtime.fs.lstat(path);
		if (!same_node(directory, current) || current?.type != 'directory' ||
			(current.uid != null && current.uid != 0) || (current.mode & 0o022) != 0 ||
			runtime.fs.realpath(path) != path)
			errors.fail('INTERNAL');
		verify_directory(runtime, ROOT, root);
		if (!same_node(identity, runtime.fs.lstat(file)) || runtime.fs.unlink(file) !== true)
			errors.fail('INTERNAL');
	}
	let current = runtime.fs.lstat(path);
	if (!same_node(directory, current) || current?.type != 'directory' ||
		(current.uid != null && current.uid != 0) || (current.mode & 0o022) != 0 ||
		runtime.fs.realpath(path) != path)
		errors.fail('INTERNAL');
	verify_directory(runtime, ROOT, root);
	if (runtime.fs.rmdir(path) !== true) errors.fail('INTERNAL');
	verify_directory(runtime, ROOT, root);
};
function recover_stream_store(runtime, root) {
	let names = runtime.fs.lsdir(ROOT);
	if (type(names) != 'array' || length(names) > MAX_ROOT_ENTRIES)
		errors.fail('CORRUPT_STATE');
	for (let name in names) {
		let old_final = match(name, /^report-[0-9a-f]{32}$/);
		if (!old_final && !match(name, /^(\.stream-stage-|stream-report-)[0-9a-f]{32}$/))
			continue;
		let path = ROOT + '/' + name;
		if (old_final) {
			let entries = runtime.fs.lsdir(path);
			if (type(entries) == 'array' && length(entries) == 1 &&
				entries[0] == 'report.json')
				remove_old_stream_report(runtime, root, path);
			continue;
		}
		if (match(name, /^\.stream-stage-/))
			remove_stream_stage(runtime, root, path, null, null);
		else
			remove_stream_directory(runtime, root, path, null, null);
	}
};
function storage_free_blocks(runtime) {
	if (type(runtime?.storage?.free_blocks) == 'function') {
		let blocks = runtime.storage.free_blocks();
		if (type(blocks) != 'int' || blocks < 0) errors.fail('INTERNAL');
		return blocks;
	}
	if (type(runtime?.fs?.popen) != 'function') errors.fail('INTERNAL');
	let handle = runtime.fs.popen('/bin/df -Pk /tmp', 'r');
	if (handle == null) errors.fail('INTERNAL');
	let output = '', failure = null;
	try {
		while (length(output) <= 8192) {
			let chunk = handle.read(1024);
			if (type(chunk) != 'string') errors.fail('INTERNAL');
			if (!length(chunk)) break;
			output += chunk;
		}
	}
	catch (error) { failure = 'INTERNAL'; }
	let close_status = handle.close();
	if (close_status !== true && close_status !== 0) failure = 'INTERNAL';
	if (failure != null || length(output) > 8192) errors.fail('INTERNAL');
	let lines = split(output, '\n');
	if (length(lines) < 2) errors.fail('INTERNAL');
	let fields = split(trim(lines[length(lines) - 2]), /[ \t]+/);
	if (length(fields) < 4 || !match(fields[3], /^[0-9]+$/)) errors.fail('INTERNAL');
	return int(fields[3]);
};
function validate_stream_json(runtime, directory, path, expected_size, expected_identity) {
	verify_directory(runtime, directory.path, directory.identity);
	let identity = safe_file(runtime, path, expected_identity);
	if (identity.size != expected_size || expected_size > REPORT_MAX_INPUT)
		errors.fail('RESPONSE_TOO_LARGE');
	let handle = runtime.fs.open(path, 're');
	if (handle == null) errors.fail('INTERNAL');
	let opened = runtime.fs.fstat(handle);
	if (!same_node(identity, opened)) { runtime.fs.close(handle); errors.fail('INTERNAL'); }
	let consumed = 0, stack = [], root_state = 'value', token = null;
	let nodes = 0, string_bytes = 0, failure = null;
	function context() {
		return length(stack) ? stack[length(stack) - 1] : null;
	};
	function state() {
		let current = context();
		return current == null ? root_state : current.state;
	};
	function set_state(value) {
		let current = context();
		if (current == null) root_state = value;
		else current.state = value;
	};
	function accept_value() {
		let expected = state();
		if (expected != 'value' && expected != 'value_or_end')
			errors.fail('INVALID_RESPONSE');
		if (++nodes > REPORT_MAX_NODES) errors.fail('RESPONSE_TOO_LARGE');
		let current = context();
		if (current == null) root_state = 'end';
		else current.state = 'comma_or_end';
	};
	function begin_container(kind) {
		accept_value();
		if (length(stack) >= REPORT_MAX_DEPTH) errors.fail('RESPONSE_TOO_LARGE');
		push(stack, { kind, state: kind == 'object' ? 'key_or_end' : 'value_or_end' });
	};
	function finish_number() {
		if (token.phase != 'zero' && token.phase != 'int' && token.phase != 'frac' &&
			token.phase != 'exp_digits')
			errors.fail('INVALID_RESPONSE');
		token = null;
	};
	try {
		while (consumed <= REPORT_MAX_INPUT) {
			let chunk = runtime.fs.read(handle, 4096);
			if (type(chunk) != 'string') errors.fail('INTERNAL');
			if (!length(chunk)) break;
			consumed += length(chunk);
			for (let offset = 0; offset < length(chunk); offset++) {
				let character = substr(chunk, offset, 1);
				if (token?.kind == 'string') {
					string_bytes++;
					if (string_bytes > REPORT_MAX_INPUT) errors.fail('RESPONSE_TOO_LARGE');
					if (token.unicode > 0) {
						if (!match(character, /^[0-9a-fA-F]$/)) errors.fail('INVALID_RESPONSE');
						if (!--token.unicode) token.escaped = false;
					}
					else if (token.escaped) {
						if (character == 'u') token.unicode = 4;
						else if (!match(character, /^["\\\/bfnrt]$/))
							errors.fail('INVALID_RESPONSE');
						else token.escaped = false;
					}
					else if (character == '\\') token.escaped = true;
					else if (character == '"') {
						if (token.role == 'key') set_state('colon');
						token = null;
					}
					else if (ord(character) < 0x20) errors.fail('INVALID_RESPONSE');
					continue;
				}
				if (token?.kind == 'literal') {
					if (character != substr(token.text, token.offset++, 1))
						errors.fail('INVALID_RESPONSE');
					if (token.offset == length(token.text)) token = null;
					continue;
				}
				if (token?.kind == 'number') {
					let digit = match(character, /^[0-9]$/);
					if (token.phase == 'minus') {
						if (character == '0') token.phase = 'zero';
						else if (match(character, /^[1-9]$/)) token.phase = 'int';
						else errors.fail('INVALID_RESPONSE');
						continue;
					}
					if (token.phase == 'zero' || token.phase == 'int') {
						if (digit) {
							if (token.phase == 'zero') errors.fail('INVALID_RESPONSE');
							continue;
						}
						if (character == '.') { token.phase = 'dot'; continue; }
						if (character == 'e' || character == 'E') { token.phase = 'exp'; continue; }
					}
					else if (token.phase == 'dot') {
						if (!digit) errors.fail('INVALID_RESPONSE');
						token.phase = 'frac'; continue;
					}
					else if (token.phase == 'frac') {
						if (digit) continue;
						if (character == 'e' || character == 'E') { token.phase = 'exp'; continue; }
					}
					else if (token.phase == 'exp') {
						if (character == '+' || character == '-') { token.phase = 'exp_sign'; continue; }
						if (digit) { token.phase = 'exp_digits'; continue; }
						errors.fail('INVALID_RESPONSE');
					}
					else if (token.phase == 'exp_sign') {
						if (!digit) errors.fail('INVALID_RESPONSE');
						token.phase = 'exp_digits'; continue;
					}
					else if (token.phase == 'exp_digits' && digit) continue;
					finish_number();
					offset--;
					continue;
				}
				if (match(character, /^[ \t\r\n]$/)) continue;
				let expected = state(), current = context();
				if (character == '{') { begin_container('object'); continue; }
				if (character == '[') { begin_container('array'); continue; }
				if (character == '"') {
					let role = 'value';
					if (expected == 'key' || expected == 'key_or_end') role = 'key';
					else accept_value();
					string_bytes = 0;
					token = { kind: 'string', role, escaped: false, unicode: 0 };
					continue;
				}
				if (character == 't' || character == 'f' || character == 'n') {
					accept_value();
					let literal = character == 't' ? 'true' : character == 'f' ? 'false' : 'null';
					token = { kind: 'literal', text: literal, offset: 1 };
					continue;
				}
				if (character == '-' || match(character, /^[0-9]$/)) {
					accept_value();
					token = { kind: 'number', phase: character == '-' ? 'minus' :
						character == '0' ? 'zero' : 'int' };
					continue;
				}
				if (character == ':') {
					if (expected != 'colon') errors.fail('INVALID_RESPONSE');
					set_state('value'); continue;
				}
				if (character == ',') {
					if (expected != 'comma_or_end' || current == null)
						errors.fail('INVALID_RESPONSE');
					current.state = current.kind == 'object' ? 'key' : 'value';
					continue;
				}
				if (character == '}' || character == ']') {
					if (current == null || (character == '}' && current.kind != 'object') ||
						(character == ']' && current.kind != 'array') ||
						(current.state != 'comma_or_end' &&
						 current.state != (current.kind == 'object' ? 'key_or_end' : 'value_or_end')))
						errors.fail('INVALID_RESPONSE');
					pop(stack); continue;
				}
				errors.fail('INVALID_RESPONSE');
			}
		}
		if (token?.kind == 'number') finish_number();
		if (consumed != expected_size || token != null || length(stack) || root_state != 'end')
			errors.fail('INVALID_RESPONSE');
	}
	catch (error) { failure = errors.normalize(error).code; }
	let final_handle = runtime.fs.fstat(handle);
	if (!same_node(opened, final_handle) || runtime.fs.close(handle) !== true) failure = 'INTERNAL';
	let current = runtime.fs.lstat(path);
	if (failure != null || !same_node(identity, current) || current?.size != expected_size ||
		runtime.fs.realpath(path) != path)
		errors.fail(failure ?? 'INTERNAL');
	verify_directory(runtime, directory.path, directory.identity);
	return current;
};

// A deliberately small persistence boundary for streamed JSON reports. The
// existing diagnostics domain continues to own its legacy paired JSON/text
// reports while newer callers use this one-file, capability-scoped store.
export function create_store(runtime) {
	if (type(runtime?.fs) != 'object' || type(runtime?.clock?.now) != 'function' ||
		type(runtime?.random?.hex) != 'function' || type(runtime?.digest?.sha256) != 'function' ||
		type(runtime?.digest?.sha256_file) != 'function' ||
		runtime?.paths?.tmp != '/tmp/miclash') invalid();
	ensure_directory(runtime, runtime.paths.tmp);
	let root = ensure_directory(runtime, ROOT), reports = {}, pending = {};
	recover_stream_store(runtime, root);
	function discard(report) {
		delete reports[report?.id];
		if (report != null && runtime.fs.lstat(report.directory.path) != null)
			remove_stream_directory(runtime, root, report.directory.path, report.directory.identity,
				report.identity);
	};
	function expire() {
		let now = runtime.clock.now();
		for (let id, report in reports)
			if (report.expires_at <= now) discard(report);
	};
	function cleanup_pending(id, stage, final_path) {
		let directory_identity = pending[id]?.directory?.identity;
		let file_identity = pending[id]?.identity;
		delete pending[id];
		let failure = null;
		try {
			if (runtime.fs.lstat(stage) != null)
				remove_stream_stage(runtime, root, stage, directory_identity, file_identity);
		}
		catch (error) { failure = 'INTERNAL'; }
		try {
			if (runtime.fs.lstat(final_path) != null)
				remove_stream_directory(runtime, root, final_path, directory_identity, file_identity);
		}
		catch (error) { failure = 'INTERNAL'; }
		if (failure != null) errors.fail(failure);
	};
	return {
		begin: (options) => {
			if (type(options) != 'object' || length(keys(options)) != 2 ||
				type(options.mode) != 'string' || !match(options.mode, /^[a-z][a-z0-9_-]{0,31}$/) ||
				type(options.required_bytes) != 'int' || options.required_bytes < 1 ||
				options.required_bytes > REPORT_MAX_INPUT) invalid();
			expire();
			// One KiB blocks plus a 64 KiB reserve ensure finalization and cleanup
			// remain possible even when tmpfs is nearly exhausted.
			if (storage_free_blocks(runtime) < int((options.required_bytes + 65535) / 1024) + 64)
				errors.fail('INSUFFICIENT_STORAGE');
			root = verify_directory(runtime, ROOT, root);
			for (let attempt = 0; attempt < 16; attempt++) {
				let token = runtime.random.hex(16);
				if (!match(token, /^[0-9a-f]{32}$/)) errors.fail('INTERNAL');
				let id = 'rpt_' + token, stage = ROOT + '/.stream-stage-' + token;
				if (reports[id] != null || runtime.fs.lstat(stage) != null ||
					runtime.fs.lstat(ROOT + '/stream-report-' + token) != null) continue;
				if (runtime.fs.mkdir(stage) !== true) continue;
				let directory = { path: stage, identity: runtime.fs.lstat(stage) };
				let failure = null, handle = null, opened = null;
				try {
					if (runtime.fs.chmod(stage, 0o700) !== true)
						errors.fail('INTERNAL');
					directory.identity = verify_directory(runtime, stage, directory.identity);
					handle = runtime.fs.open(stage + '/report.json', 'wx', 0o600);
					if (handle == null) errors.fail('INTERNAL');
					handle.path = stage + '/report.json';
					opened = safe_file(runtime, handle.path, null);
					let created_at = runtime.clock.now(), expires_at = created_at + TTL;
					let pending_report = { mode: options.mode, created_at, expires_at,
						directory, identity: opened, handle };
					pending[id] = pending_report;
					handle.abort = () => {
						if (pending[id] === pending_report)
							cleanup_pending(id, stage, ROOT + '/stream-report-' + token);
					};
					return { id, mode: options.mode, path: stage, size: 0, sha256: null,
						created_at, expires_at,
						downloaded: false, handle, directory, identity: opened };
				}
				catch (error) { failure = errors.normalize(error).code; }
				if (handle != null) try { runtime.fs.close(handle); } catch (error) {}
				try { remove_stream_stage(runtime, root, stage, directory.identity, opened); }
				catch (error) { failure = 'INTERNAL'; }
				errors.fail(failure);
			}
			errors.fail('INTERNAL');
		},
		finish: (id, result) => {
			if (type(id) != 'string' || !match(id, /^rpt_[0-9a-f]{32}$/) ||
				type(result) != 'object') invalid();
			let pending_report = pending[id];
			if (pending_report == null) errors.fail('NOT_FOUND');
			let stage = ROOT + '/.stream-stage-' + substr(id, 4),
				final_path = ROOT + '/stream-report-' + substr(id, 4);
			try {
				let directory = { path: stage,
					identity: verify_directory(runtime, stage, pending_report.directory.identity) };
				let expected = stage + '/report.json';
				if (result.path != expected || type(result.size) != 'int' || result.size < 1 ||
					type(result.sha256) != 'string' || !match(result.sha256, /^[0-9a-f]{64}$/)) invalid();
				let file = validate_stream_json(runtime, directory, expected, result.size,
					pending_report.identity);
				if (runtime.digest.sha256_file(expected) != result.sha256) errors.fail('INTERNAL');
				verify_directory(runtime, ROOT, root);
				if (runtime.fs.lstat(final_path) != null || runtime.fs.rename(stage, final_path) !== true)
					errors.fail('INTERNAL');
				let final_directory = { path: final_path,
					identity: verify_directory(runtime, final_path, directory.identity) };
				let final_file = safe_file(runtime, final_path + '/report.json', file);
				if (final_file.size != result.size ||
					runtime.digest.sha256_file(final_path + '/report.json') != result.sha256 ||
					!same_node(final_file, runtime.fs.lstat(final_path + '/report.json')))
					errors.fail('INTERNAL');
				let report = { id, mode: pending_report.mode, path: final_path + '/report.json', size: result.size,
					sha256: result.sha256, created_at: pending_report.created_at,
					expires_at: pending_report.expires_at, downloaded: false,
					directory: final_directory, identity: final_file };
				pending_report.handle.abort = () => {};
				delete pending[id];
				reports[id] = report;
				return { id: report.id, mode: report.mode, path: report.path, size: report.size,
					sha256: report.sha256, created_at: report.created_at, expires_at: report.expires_at,
					downloaded: report.downloaded };
			}
			catch (error) {
				let code = errors.normalize(error).code;
				cleanup_pending(id, stage, final_path);
				errors.fail(code);
			}
		},
		open_report: (id) => {
			expire();
			let report = reports[id];
			if (type(id) != 'string' || report == null || report.downloaded) errors.fail('NOT_FOUND');
			let file = null, handle = null, opened = null;
			try {
				verify_directory(runtime, ROOT, root);
				verify_directory(runtime, report.directory.path, report.directory.identity);
				file = safe_file(runtime, report.path, report.identity);
				if (file.size != report.size ||
					runtime.digest.sha256_file(report.path) != report.sha256)
					errors.fail('INTERNAL');
				report.downloaded = true;
				handle = runtime.fs.open(report.path, 're');
				if (handle == null) errors.fail('INTERNAL');
				opened = runtime.fs.fstat(handle);
				if (!same_node(file, opened)) errors.fail('INTERNAL');
			}
			catch (error) {
				let code = errors.normalize(error).code, cleanup_failure = false;
				if (handle != null)
					try { if (runtime.fs.close(handle) !== true) cleanup_failure = true; }
					catch (close_error) { cleanup_failure = true; }
				try { discard(report); }
				catch (cleanup_error) { cleanup_failure = true; }
				errors.fail(cleanup_failure ? 'INTERNAL' : code);
			}
			let consumed = 0, reader_failure = null, reader_closed = false;
			function reader_terminal(code) {
				if (!reader_closed) {
					try { runtime.fs.close(handle); } catch (error) {}
					reader_closed = true;
				}
				discard(report);
				errors.fail(code);
			};
			return {
				read: (amount) => {
					if (reader_closed) errors.fail('NOT_FOUND');
					if (type(amount) != 'int' || amount < 1 || amount > 4096)
						reader_terminal('INVALID_ARGUMENT');
					let chunk = null;
					try { chunk = runtime.fs.read(handle, amount); }
					catch (error) { reader_failure = 'INTERNAL'; reader_terminal('INTERNAL'); }
					if (type(chunk) != 'string' || consumed + length(chunk) > report.size) {
						reader_failure = 'INTERNAL'; reader_terminal('INTERNAL');
					}
					consumed += length(chunk);
					return chunk;
				},
				close: () => {
					if (reader_closed) errors.fail('NOT_FOUND');
					let after = null, close_result = null;
					try {
						after = runtime.fs.fstat(handle);
						close_result = runtime.fs.close(handle);
						reader_closed = true;
						if (close_result !== true) reader_terminal('INTERNAL');
						let current = safe_file(runtime, report.path, report.identity);
						if (reader_failure != null || !same_node(opened, after) || !same_node(file, current) ||
							consumed != report.size ||
							runtime.digest.sha256_file(report.path) != report.sha256 ||
							!same_node(current, runtime.fs.lstat(report.path)))
							reader_terminal('INTERNAL');
					}
					catch (error) { reader_terminal('INTERNAL'); }
					discard(report);
					return true;
				}
			};
		}
	};
};
export function create(dependencies) {
	let runtime = dependencies?.runtime, sources = dependencies?.sources;
	if (type(runtime?.fs) != 'object' || type(runtime?.clock?.now) != 'function' ||
		type(runtime?.random?.hex) != 'function' || type(runtime?.digest?.sha256) != 'function' ||
		type(runtime?.digest?.sha256_file) != 'function' ||
		runtime?.paths?.tmp != '/tmp/miclash' || type(sources) != 'object')
		invalid();
	for (let name in [ 'versions', 'architecture', 'state', 'health', 'memory',
		'updates', 'settings', 'telegram', 'last_repair', 'config', 'process', 'logs', 'uci',
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
			return clone(make_summary(collect_summary(sources), runtime.clock.now()));
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
				let safe = collect(sources, runtime);
				let summary = make_summary(safe, now);
				let report = { schema_version: 4, generated_at: now, summary,
					issues: report_issues(safe), collection: safe.collection,
					details: { config: safe.config, process: safe.process, logs: safe.logs,
						uci: safe.uci, operations: safe.operations, evidence: safe.evidence } };
				let json_text = telegram_format.pretty_json(report) + '\n';
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
