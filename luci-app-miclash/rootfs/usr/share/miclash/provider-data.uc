import * as errors from 'miclash.errors';
import * as route_test from 'miclash.route-test';
import * as firewall_common from 'miclash.firewall.common';

const ROOT = '/opt/clash';
const MAX_CONFIG = 1024 * 1024;
const MAX_PROVIDER_FILE = 1024 * 1024;
const MAX_PROVIDERS = 64;
const MAX_VALUES = 256;
const MANUAL_FAKEIP = '/opt/clash/lst/fakeip-whitelist-ipcidr.txt';

function invalid() { errors.fail('INVALID_ARGUMENT'); };

function clean_scalar(value) {
	value = trim(value ?? '');
	let comment = index(value, ' #');
	if (comment >= 0) value = trim(substr(value, 0, comment));
	if (length(value) >= 2 && ((substr(value, 0, 1) == "'" && substr(value, -1) == "'") ||
	    (substr(value, 0, 1) == '"' && substr(value, -1) == '"')))
		value = substr(value, 1, length(value) - 2);
	return value;
};

function section(content, name) {
	let output = [], active = false;
	for (let line in split(content, '\n')) {
		if (match(line, /^[^[:space:]#][^:]*:[[:space:]]*$/)) {
			active = trim(line) == name + ':';
			continue;
		}
		if (active) push(output, line);
	}
	return output;
};

function provider_entries(content, section_name) {
	let entries = [], current = null;
	for (let line in section(content, section_name)) {
		let header = match(line, /^  ([A-Za-z0-9_.-]{1,128}):[[:space:]]*$/);
		if (header) {
			if (length(entries) >= MAX_PROVIDERS) errors.fail('RESPONSE_TOO_LARGE');
			current = { name: header[1], path: null, behavior: null };
			push(entries, current);
			continue;
		}
		if (current == null) continue;
		let field = match(line, /^    (path|behavior):[[:space:]]*(.+)$/);
		if (field) current[field[1]] = clean_scalar(field[2]);
	}
	return entries;
};

function provider_path(value) {
	if (type(value) != 'string' || !length(value) || length(value) > 512 ||
	    index(value, '\\') >= 0 || index(value, sprintf('%c', 0)) >= 0)
		invalid();
	let path = substr(value, 0, 2) == './' ? ROOT + '/' + substr(value, 2) : value;
	if (substr(path, 0, 1) != '/') path = ROOT + '/' + path;
	if (path == ROOT || substr(path, 0, length(ROOT) + 1) != ROOT + '/' ||
	    index(path, '//') >= 0)
		invalid();
	for (let part in split(path, '/'))
		if (part == '.' || part == '..' || !match(part, /^[A-Za-z0-9._ -]*$/)) invalid();
	return path;
};

function same_file(left, right) {
	return left?.type == 'file' && right?.type == 'file' && left.inode == right.inode &&
		left.dev?.major == right.dev?.major && left.dev?.minor == right.dev?.minor &&
		left.uid == right.uid && left.nlink == right.nlink && left.size == right.size;
};

function read_provider(runtime, value) {
	let path = provider_path(value), before = runtime.fs.lstat(path);
	if (before == null)
		errors.fail('NOT_FOUND');
	if (before?.type != 'file' || before.nlink != 1 ||
	    (before.uid != null && before.uid != 0) || before.size > MAX_PROVIDER_FILE ||
	    runtime.fs.realpath(path) != path)
		invalid();
	let content = runtime.fs.readfile(path), after = runtime.fs.lstat(path);
	if (type(content) != 'string' || length(content) != before.size ||
	    !same_file(before, after) || runtime.fs.realpath(path) != path)
		errors.fail('BUSY');
	return content;
};

function append_unique(output, seen, value) {
	if (seen[value]) return;
	if (length(output) >= MAX_VALUES) errors.fail('RESPONSE_TOO_LARGE');
	seen[value] = true;
	push(output, value);
};

function used_ip_rules(content) {
	let used = {};
	for (let line in split(content, '\n')) {
		let rule = match(line, /RULE-SET,([^,[:space:]]+),([^,[:space:]#]+)/);
		if (!rule) continue;
		let action = uc(rule[2]);
		if (action != 'DIRECT' && action != 'REJECT' && action != 'REJECT-DROP' &&
		    action != 'PASS')
			used[rule[1]] = true;
	}
	return used;
};

function fakeip_mode(content) {
	let enabled = false, enhanced = null, mode = 'blacklist';
	for (let line in section(content, 'dns')) {
		let field = match(line,
			/^[[:space:]]+(enable|enhanced-mode|fake-ip-filter-mode):[[:space:]]*(.+)$/);
		if (!field) continue;
		let value = lc(clean_scalar(field[2]));
		if (field[1] == 'enable') enabled = value == 'true';
		else if (field[1] == 'enhanced-mode') enhanced = value;
		else mode = value;
	}
	return enabled && enhanced == 'fake-ip' && (mode == 'whitelist' || mode == 'rule')
		? mode : null;
};

function add_filter_rules(content, mode, used) {
	if (mode == 'whitelist') {
		for (let line in split(content, '\n')) {
			let found = match(line, /RULE-SET:([A-Za-z0-9_.-]{1,128})/);
			if (found) used[found[1]] = true;
		}
	}
	else if (mode == 'rule') {
		for (let line in split(content, '\n')) {
			let found = match(line,
				/RULE-SET,([A-Za-z0-9_.-]{1,128}),[[:space:]]*fake-ip/);
			if (found) used[found[1]] = true;
		}
	}
};

function cidrs(content, behavior, output, seen) {
	if (behavior != 'ipcidr' && behavior != 'classical') return;
	for (let line in split(content, '\n')) {
		line = clean_scalar(replace(trim(line), /^-[[:space:]]*/, ''));
		if (!length(line) || substr(line, 0, 1) == '#') continue;
		if (behavior == 'classical') {
			let item = match(line, /^(IP-CIDR6?|SRC-IP-CIDR),([^,[:space:]]+)/);
			if (!item) continue;
			line = item[2];
		}
		if (firewall_common.valid_cidr(line)) append_unique(output, seen, line);
	}
};

export function collect(runtime, config_content, options) {
	if (type(runtime?.fs?.lstat) != 'function' || type(runtime?.fs?.readfile) != 'function' ||
	    type(runtime?.fs?.realpath) != 'function' || type(config_content) != 'string' ||
	    length(config_content) > MAX_CONFIG || type(options?.resolve) != 'function' ||
	    type(options?.auto_fakeip_whitelist) != 'bool')
		invalid();

	let endpoints = route_test.proxy_servers(config_content);
	for (let provider in provider_entries(config_content, 'proxy-providers')) {
		if (provider.path == null) continue;
		let content = read_provider(runtime, provider.path);
		for (let endpoint in route_test.proxy_servers(content)) {
			if (length(endpoints) >= MAX_VALUES) errors.fail('RESPONSE_TOO_LARGE');
			push(endpoints, endpoint);
		}
	}
	let server_ips = [], server_seen = {};
	for (let endpoint in endpoints) {
		if (firewall_common.valid_ip(endpoint)) {
			append_unique(server_ips, server_seen, endpoint);
			continue;
		}
		let resolved = options.resolve(endpoint);
		if (type(resolved) != 'array') errors.fail('INVALID_RESPONSE');
		if (!length(resolved)) continue;
		for (let address in resolved) {
			if (!firewall_common.valid_ip(address)) errors.fail('INVALID_RESPONSE');
			append_unique(server_ips, server_seen, address);
		}
	}

	let fakeip_cidrs = [], cidr_seen = {}, mode = fakeip_mode(config_content);
	if (mode != null && runtime.fs.lstat(MANUAL_FAKEIP) != null)
		cidrs(read_provider(runtime, MANUAL_FAKEIP), 'ipcidr', fakeip_cidrs, cidr_seen);
	if (mode != null && options.auto_fakeip_whitelist) {
		let used = used_ip_rules(config_content);
		add_filter_rules(config_content, mode, used);
		for (let provider in provider_entries(config_content, 'rule-providers')) {
			if (!used[provider.name] || provider.path == null) continue;
			let content = read_provider(runtime, provider.path);
			if (match(provider.path, /\.mrs$/)) {
				if (type(options.convert_mrs) != 'function') errors.fail('HEALTH_FAILED');
				content = options.convert_mrs(provider_path(provider.path), provider.behavior);
				if (type(content) != 'string' || length(content) > MAX_PROVIDER_FILE)
					errors.fail('INVALID_RESPONSE');
			}
			cidrs(content, provider.behavior,
				fakeip_cidrs, cidr_seen);
		}
	}
	return { server_ips: sort(server_ips), fakeip_cidrs: sort(fakeip_cidrs) };
};
