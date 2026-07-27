import { fail } from 'miclash.errors';
import * as mihomo from 'miclash.mihomo-api';
import * as redact from 'miclash.redact';

const DECISIONS = { DIRECT: true, PROXY: true, BLOCK: true };
const RULE_TYPES = {
	DOMAIN: true, 'DOMAIN-SUFFIX': true, 'DOMAIN-KEYWORD': true,
	'IP-CIDR': true, 'IP-CIDR6': true, MATCH: true
};
const MAX_STEPS = 16;
const MAX_CONFIG = 1048576;

function invalid() { fail('INVALID_ARGUMENT'); };
function ipv4(value) {
	if (type(value) != 'string') return false;
	let parts = split(value, '.');
	if (length(parts) != 4) return false;
	for (let part in parts)
		if (!match(part, /^(0|[1-9][0-9]{0,2})$/) || int(part) > 255)
			return false;
	return true;
};
function ipv6_side(value, ipv4_allowed) {
	let groups = [];
	if (!length(value)) return groups;
	let fields = split(value, ':');
	for (let at, field in fields) {
		if (index(field, '.') >= 0) {
			if (!ipv4_allowed || at != length(fields) - 1 || !ipv4(field)) return null;
			let octets = split(field, '.');
			push(groups, int(octets[0]) * 256 + int(octets[1]));
			push(groups, int(octets[2]) * 256 + int(octets[3]));
		}
		else {
			if (!match(field, /^[0-9A-Fa-f]{1,4}$/)) return null;
			push(groups, int(field, 16));
		}
	}
	return groups;
};
function parse_ipv6(value) {
	if (type(value) != 'string' || !match(value, /^[0-9A-Fa-f:.]+$/) ||
		index(value, ':') < 0 || length(value) > 45)
		return null;
	let halves = split(value, '::');
	if (length(halves) > 2) return null;
	let left = ipv6_side(halves[0], length(halves) == 1);
	let right = length(halves) == 2 ? ipv6_side(halves[1], true) : [];
	if (left == null || right == null) return null;
	let used = length(left) + length(right), groups = [];
	if ((length(halves) == 1 && used != 8) ||
		(length(halves) == 2 && used >= 8))
		return null;
	for (let group in left) push(groups, group);
	if (length(halves) == 2)
		for (let count = used; count < 8; count++) push(groups, 0);
	for (let group in right) push(groups, group);
	return groups;
};
function normalize_ipv6(value) {
	let groups = type(value) == 'array' ? value : parse_ipv6(value);
	if (groups == null) return null;
	let best_at = -1, best_length = 0;
	for (let at = 0; at < 8;) {
		if (groups[at] != 0) { at++; continue; }
		let end = at;
		while (end < 8 && groups[end] == 0) end++;
		if (end - at > best_length) {
			best_at = at;
			best_length = end - at;
		}
		at = end;
	}
	if (best_length < 2) best_at = -1;
	let fields = [];
	if (best_at < 0) {
		for (let group in groups) push(fields, sprintf('%x', group));
		return join(':', fields);
	}
	let left = [], right = [];
	for (let at = 0; at < best_at; at++) push(left, sprintf('%x', groups[at]));
	for (let at = best_at + best_length; at < 8; at++)
		push(right, sprintf('%x', groups[at]));
	return join(':', left) + '::' + join(':', right);
};
function ipv6(value) {
	return parse_ipv6(value) != null;
};
function domain(value) {
	if (type(value) != 'string' || !length(value) || length(value) > 253 ||
		match(value, /[[:cntrl:]]/) || substr(value, 0, 1) == '.' || substr(value, -1) == '.')
		return false;
	for (let label in split(value, '.'))
		if (!length(label) || length(label) > 63 ||
			!match(label, /^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$/))
			return false;
	return true;
};
function classify(value) {
	if (ipv4(value)) return 'ipv4';
	if (ipv6(value)) return 'ipv6';
	if (type(value) == 'string' && match(value, /^[0-9.]+$/)) invalid();
	if (domain(value)) return 'domain';
	invalid();
};
function yaml_scalar(value) {
	value = trim(value);
	if (!length(value)) invalid();
	if (substr(value, 0, 1) == '"') {
		let parsed;
		try { parsed = json(value); } catch (error) { invalid(); }
		if (type(parsed) != 'string') invalid();
		return parsed;
	}
	if (substr(value, 0, 1) == "'") {
		if (length(value) < 2 || substr(value, -1) != "'") invalid();
		return replace(substr(value, 1, length(value) - 2), "''", "'");
	}
	let comment = index(value, ' #');
	if (comment >= 0) value = trim(substr(value, 0, comment));
	if (!length(value) || match(value, /[[:cntrl:]]/)) invalid();
	return value;
};

function indentation(line) {
	let amount = 0;
	while (amount < length(line) && substr(line, amount, 1) == ' ') amount++;
	if (amount < length(line) && substr(line, amount, 1) == '\t') invalid();
	return amount;
};

function strip_yaml_comment(value) {
	let quote = null, escaped = false;
	for (let offset = 0; offset < length(value); offset++) {
		let character = substr(value, offset, 1);
		if (quote != null) {
			if (quote == '"' && character == '\\' && !escaped) {
				escaped = true; continue;
			}
			if (character == quote && !escaped) {
				if (quote == "'" && substr(value, offset + 1, 1) == "'") {
					offset++; continue;
				}
				quote = null;
			}
			escaped = false;
			continue;
		}
		if (character == '"' || character == "'") { quote = character; continue; }
		if (character == '#' && (offset == 0 || match(substr(value, offset - 1, 1), /^\s$/)))
			return replace(substr(value, 0, offset), /\s+$/, '');
	}
	return value;
};

function flow_fields(value) {
	if (substr(value, 0, 1) != '{' || substr(value, -1) != '}') invalid();
	value = substr(value, 1, length(value) - 2);
	let fields = [], start = 0, quote = null, depth = 0, escaped = false;
	for (let offset = 0; offset < length(value); offset++) {
		let character = substr(value, offset, 1);
		if (quote != null) {
			if (quote == '"' && character == '\\' && !escaped) {
				escaped = true; continue;
			}
			if (character == quote && !escaped) {
				if (quote == "'" && substr(value, offset + 1, 1) == "'") {
					offset++; continue;
				}
				quote = null;
			}
			escaped = false;
			continue;
		}
		if (character == '"' || character == "'") { quote = character; continue; }
		if (character == '{' || character == '[') { depth++; continue; }
		if (character == '}' || character == ']') {
			if (depth < 1) invalid();
			depth--; continue;
		}
		if (character == ',' && depth == 0) {
			push(fields, trim(substr(value, start, offset - start)));
			start = offset + 1;
		}
	}
	if (quote != null || depth != 0) invalid();
	push(fields, trim(substr(value, start)));
	return fields;
};

function mapping_server(value, flow) {
	let fields = flow ? flow_fields(value) : [ trim(value) ], server = null;
	for (let field in fields) {
		if (!length(field)) continue;
		let colon = index(field, ':');
		if (colon < 1) {
			if (!flow) return null;
			invalid();
		}
		let key = trim(substr(field, 0, colon));
		if (key == '<<') continue;
		if (!match(key, /^[A-Za-z0-9_-]+$/)) invalid();
		if (key != 'server') continue;
		if (server != null) invalid();
		server = yaml_scalar(substr(field, colon + 1));
	}
	return server;
};

export function proxy_servers(config_content) {
	if (type(config_content) != 'string' || length(config_content) > MAX_CONFIG)
		invalid();
	let active = false, item = false, sequence_indent = null,
		field_indent = null, item_server = null, values = [], seen = {};
	function finish_item() {
		if (item_server == null) return;
		let kind = classify(item_server);
		let normalized = kind == 'ipv6' ? normalize_ipv6(item_server) : lc(item_server);
		if (!seen[normalized]) {
			if (length(values) >= 128) invalid();
			seen[normalized] = true;
			push(values, normalized);
		}
		item_server = null;
	};
	for (let line in split(config_content, '\n')) {
		line = strip_yaml_comment(line);
		if (!length(trim(line))) continue;
		let indent = indentation(line), body = substr(line, indent);
		if (!active) {
			if (indent != 0) continue;
			let colon = index(line, ':');
			active = colon > 0 && trim(substr(line, 0, colon)) == 'proxies' &&
				!length(trim(substr(line, colon + 1)));
			continue;
		}
		let sequence = match(body, /^-\s*(.*)$/);
		if (sequence != null && (sequence_indent == null || indent == sequence_indent)) {
			if (sequence_indent == null) sequence_indent = indent;
			finish_item();
			item = true; field_indent = null;
			let first = trim(sequence[1]);
			if (length(first))
				item_server = mapping_server(first, substr(first, 0, 1) == '{');
			continue;
		}
		if (sequence_indent == null || indent <= sequence_indent) {
			finish_item(); active = false; item = false; continue;
		}
		if (!item) invalid();
		if (field_indent == null) field_indent = indent;
		if (indent != field_indent) continue;
		let server = mapping_server(body, false);
		if (server != null) {
			if (item_server != null) invalid();
			item_server = server;
		}
	}
	finish_item();
	return values;
};
function safe_mac(value) {
	return type(value) == 'string' && match(value,
		/^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$/);
};
function safe_interface(value) {
	return type(value) == 'string' && length(value) >= 1 && length(value) <= 15 &&
		match(value, /^[A-Za-z0-9][A-Za-z0-9_.:-]*$/);
};
function exact_input(value) {
	if (type(value) != 'object' || !exists(value, 'target')) invalid();
	let count = 0;
	for (let name in value) {
		if (name != 'target' && name != 'device' && name != 'interface') invalid();
		count++;
	}
	if (count < 1 || count > 3 || type(value.target) != 'string') invalid();
	let kind = classify(value.target);
	if (value.device != null && !safe_mac(value.device)) invalid();
	if (value.interface != null && !safe_interface(value.interface)) invalid();
	return { target: kind == 'ipv6' ? normalize_ipv6(value.target) : lc(value.target), kind,
		device: value.device == null ? null : uc(value.device),
		interface: value.interface ?? null };
};
function suffix(value, ending) {
	return value == ending ||
		(length(value) > length(ending) &&
		 substr(value, length(value) - length(ending) - 1) == '.' + ending);
};
function ipv4_number(value) {
	let parts = split(value, '.');
	return (((int(parts[0]) * 256 + int(parts[1])) * 256 + int(parts[2])) * 256 + int(parts[3]));
};
function cidr4(target, value) {
	let parts = split(value, '/');
	if (length(parts) != 2 || !ipv4(parts[0]) || !match(parts[1], /^[0-9]+$/)) return false;
	let bits = int(parts[1]);
	if (bits < 0 || bits > 32) return false;
	if (bits == 0) return true;
	let shift = 32 - bits;
	return (ipv4_number(target) >> shift) == (ipv4_number(parts[0]) >> shift);
};
function valid_cidr4(value) {
	let parts = split(value, '/');
	return length(parts) == 2 && ipv4(parts[0]) && match(parts[1], /^[0-9]+$/) &&
		int(parts[1]) >= 0 && int(parts[1]) <= 32;
};
function cidr6(target, value) {
	let parts = split(value, '/');
	if (length(parts) != 2 || !match(parts[1], /^[0-9]+$/)) return null;
	let address = parse_ipv6(parts[0]), candidate = parse_ipv6(target), bits = int(parts[1]);
	if (address == null || candidate == null || bits < 0 || bits > 128) return null;
	let whole = int(bits / 16), partial = bits % 16;
	for (let at = 0; at < whole; at++)
		if (address[at] != candidate[at]) return false;
	if (partial && (address[whole] >> (16 - partial)) !=
		(candidate[whole] >> (16 - partial))) return false;
	return true;
};
function rule_match(rule, input, answers) {
	let type = uc(rule.type), payload = lc(rule.payload);
	if (!RULE_TYPES[type]) return { known: false, matched: false };
	if (type == 'MATCH')
		return { known: !length(payload), matched: !length(payload) };
	if (input.kind == 'domain') {
		if (type == 'DOMAIN')
			return { known: domain(payload), matched: domain(payload) && input.target == payload };
		if (type == 'DOMAIN-SUFFIX')
			return { known: domain(payload), matched: domain(payload) && suffix(input.target, payload) };
		if (type == 'DOMAIN-KEYWORD') {
			let valid = length(payload) > 0 && length(payload) <= 253 &&
				match(payload, /^[A-Za-z0-9_.-]+$/);
			return { known: valid, matched: valid && index(input.target, payload) >= 0 };
		}
	}
	let candidates = input.kind == 'domain' ? answers : [ input.target ];
	if (type == 'IP-CIDR') {
		if (!valid_cidr4(payload)) return { known: false, matched: false };
		for (let candidate in candidates)
			if (ipv4(candidate) && cidr4(candidate, payload))
				return { known: true, matched: true };
		return { known: true, matched: false };
	}
	if (type == 'IP-CIDR6') {
		let valid = cidr6('::', payload);
		if (valid == null) return { known: false, matched: false };
		for (let candidate in candidates) {
			let matched = cidr6(candidate, payload);
			if (matched === true) return { known: true, matched: true };
		}
		return { known: true, matched: false };
	}
	return { known: true, matched: false };
};
function rule_decision(value) {
	if (type(value) != 'string' || !length(value) || length(value) > 128)
		return 'unknown';
	let normalized = uc(value);
	if (normalized == 'DIRECT') return 'DIRECT';
	if (normalized == 'REJECT' || normalized == 'REJECT-DROP' || normalized == 'BLOCK')
		return 'BLOCK';
	return 'PROXY';
};
function mihomo_reason(dependencies, input, answers) {
	try {
		let reply = mihomo.request(dependencies.runtime, 'GET', '/rules', null,
			dependencies.profile, dependencies.config_content);
		if (reply.ok !== true || type(reply.data?.rules) != 'array' ||
			length(reply.data.rules) > 512)
			return { available: false, matched: false, type: null, ordered: false,
				code: type(reply.data?.rules) == 'array' ? 'OVERSIZED' : 'INVALID_RESPONSE',
				decision: 'unknown' };
		for (let rule in reply.data.rules) {
			if (type(rule) != 'object' || type(rule?.type) != 'string' ||
				type(rule?.payload) != 'string' || type(rule?.proxy) != 'string' ||
				length(rule.type) > 32 || length(rule.payload) > 512 ||
				!length(rule.proxy) || length(rule.proxy) > 128)
				return { available: true, matched: false, type: null,
					ordered: false, code: 'MALFORMED_RULE', decision: 'unknown' };
			for (let name in rule)
				if (name != 'type' && name != 'payload' && name != 'proxy' && name != 'size' &&
				    name != 'index' && name != 'extra')
					return { available: true, matched: false, type: null,
						ordered: false, code: 'MALFORMED_RULE', decision: 'unknown' };
			// Mihomo uses -1 when a rule does not expose a finite size.
			if (rule.size != null && (type(rule.size) != 'int' || rule.size < -1))
				return { available: true, matched: false, type: null,
					ordered: false, code: 'MALFORMED_RULE', decision: 'unknown' };
			if (rule.index != null && (type(rule.index) != 'int' || rule.index < 0))
				return { available: true, matched: false, type: null,
					ordered: false, code: 'MALFORMED_RULE', decision: 'unknown' };
			if (rule.extra != null) {
				if (type(rule.extra) != 'object' || type(rule.extra) == 'array')
					return { available: true, matched: false, type: null,
						ordered: false, code: 'MALFORMED_RULE', decision: 'unknown' };
				for (let name in rule.extra) {
					let value = rule.extra[name];
					if ((name == 'disabled' && type(value) == 'bool') ||
					    ((name == 'hitCount' || name == 'missCount') &&
					     type(value) == 'int' && value >= 0) ||
					    ((name == 'hitAt' || name == 'missAt') && type(value) == 'string' &&
					     length(value) <= 64 && !match(value, /[[:cntrl:]]/))) continue;
					return { available: true, matched: false, type: null,
						ordered: false, code: 'MALFORMED_RULE', decision: 'unknown' };
				}
			}
			let outcome = rule_match(rule, input, answers);
			if (!outcome.known)
				return { available: true, matched: false, type: uc(rule.type),
					ordered: false, code: RULE_TYPES[uc(rule.type)] ?
						'MALFORMED_RULE' : 'UNSUPPORTED_RULE', decision: 'unknown' };
			if (outcome.matched)
				return { available: true, matched: true, type: uc(rule.type),
					ordered: true, code: 'MATCHED', decision: rule_decision(rule.proxy) };
		}
		return { available: true, matched: false, type: null,
			ordered: true, code: 'NO_MATCH', decision: 'unknown' };
	}
	catch (error) {
		return { available: false, matched: false, type: null,
			ordered: false, code: 'UNAVAILABLE', decision: 'unknown' };
	}
};

function allowed(value, fields) {
	if (type(value) != 'object') return false;
	for (let name in value) if (!fields[name]) return false;
	return true;
};
function exact_allowed(value, fields) {
	return allowed(value, fields) && length(keys(value)) == length(keys(fields));
};
function routing_rule(value) {
	return allowed(value, { family: true, priority: true, mark: true, mask: true,
		table: true, protocol: true, owned: true, ambiguous: true, reason: true }) &&
		(value.family == 'ipv4' || value.family == 'ipv6') &&
		type(value.priority) == 'int' && type(value.table) == 'int' &&
		type(value.mark) == 'string' && match(value.mark, /^0x[0-9A-Fa-f]+$/) &&
		type(value.mask) == 'string' && match(value.mask, /^0x[0-9A-Fa-f]+$/) &&
		(value.owned == null || type(value.owned) == 'bool') &&
		(value.ambiguous == null || type(value.ambiguous) == 'bool') &&
		(value.protocol == null || type(value.protocol) == 'int' ||
		 type(value.protocol) == 'string') &&
		(value.reason == null || (type(value.reason) == 'string' &&
		 length(value.reason) <= 64 && !match(value.reason, /[[:cntrl:]]/)));
};
function routing_route(value) {
	return allowed(value, { family: true, table: true, kind: true, destination: true,
		device: true, protocol: true, owned: true, ambiguous: true, reason: true,
		unreachable: true, metric: true }) &&
		(value.family == 'ipv4' || value.family == 'ipv6') && type(value.table) == 'int' &&
		(value.kind == 'local' || value.kind == 'unicast' || value.kind == 'unreachable') &&
		value.destination == 'default' &&
		(value.device == null || safe_interface(value.device)) &&
		(value.owned == null || type(value.owned) == 'bool') &&
		(value.ambiguous == null || type(value.ambiguous) == 'bool') &&
		(value.protocol == null || type(value.protocol) == 'int' ||
		 type(value.protocol) == 'string') &&
		(value.reason == null || (type(value.reason) == 'string' &&
		 length(value.reason) <= 64 && !match(value.reason, /[[:cntrl:]]/))) &&
		(value.unreachable == null || type(value.unreachable) == 'bool') &&
		(value.metric == null || (type(value.metric) == 'int' && value.metric >= 0));
};
function manifest_rule(value) {
	return exact_allowed(value, { family: true, priority: true, mark: true,
		mask: true, table: true }) &&
		(value.family == 'ipv4' || value.family == 'ipv6') &&
		type(value.priority) == 'int' && type(value.table) == 'int' &&
		type(value.mark) == 'string' && match(value.mark, /^0x[0-9A-Fa-f]+$/) &&
		type(value.mask) == 'string' && match(value.mask, /^0x[0-9A-Fa-f]+$/);
};
function manifest_route(value) {
	let fields = value?.kind == 'unreachable'
		? { family: true, table: true, kind: true, destination: true, device: true,
			unreachable: true, metric: true }
		: { family: true, table: true, kind: true, destination: true, device: true };
	if (!exact_allowed(value, fields) ||
		(value.family != 'ipv4' && value.family != 'ipv6') ||
		type(value.table) != 'int' || value.destination != 'default') return false;
	if (value.kind == 'local' || value.kind == 'unicast') return safe_interface(value.device);
	return value.kind == 'unreachable' && value.device == null &&
		value.unreachable === true && value.metric == 42760;
};
function same_manifest_entry(left, right, kind) {
	if (kind == 'rule')
		return left.family == right.family && left.priority == right.priority &&
			lc(left.mark) == lc(right.mark) && lc(left.mask) == lc(right.mask) &&
			left.table == right.table;
	return left.family == right.family && left.table == right.table &&
		left.kind == right.kind && left.destination == right.destination &&
		left.device == right.device;
};
function trusted_ownership(routing) {
	let ownership = routing?.ownership, committed = ownership?.committed;
	if (type(ownership) != 'object' || ownership.trusted !== true ||
		ownership.status != 'trusted' || ownership.transition != null ||
		type(committed) != 'object' || type(committed.rules) != 'array' ||
		type(committed.routes) != 'array' || length(committed.rules) > 6 ||
		length(committed.routes) > 6)
		return null;
	for (let item in committed.rules) if (!manifest_rule(item)) return null;
	for (let item in committed.routes) if (!manifest_route(item)) return null;
	return committed;
};
function owned_entry(item, committed, kind) {
	if (item.owned !== true || item.protocol !== 242) return false;
	for (let expected in committed[kind == 'rule' ? 'rules' : 'routes'])
		if (same_manifest_entry(item, expected, kind)) return true;
	return false;
};
function routing_reason(observed, input, answers) {
	let routing = observed?.routing, rules = routing?.rules, routes = routing?.routes;
	if (type(rules) != 'array' || type(routes) != 'array')
		return { available: false, valid: false, code: 'UNAVAILABLE', families: [] };
	if (length(rules) > 64 || length(routes) > 64)
		return { available: true, valid: false, code: 'OVERSIZED', families: [] };
	if (routing.interfaces != null) {
		if (type(routing.interfaces) != 'object' || length(keys(routing.interfaces)) > 64)
			return { available: true, valid: false, code: 'MALFORMED', families: [] };
		for (let name, present in routing.interfaces)
			if (!safe_interface(name) || type(present) != 'bool')
				return { available: true, valid: false, code: 'MALFORMED', families: [] };
	}
	for (let item in rules)
		if (!routing_rule(item))
			return { available: true, valid: false, code: 'MALFORMED', families: [] };
	for (let item in routes)
		if (!routing_route(item))
			return { available: true, valid: false, code: 'MALFORMED', families: [] };
	let committed = trusted_ownership(routing);
	if (committed == null)
		return { available: true, valid: false, code: 'UNTRUSTED_OWNERSHIP', families: [] };
	let families = [];
	function add_family(family) {
		if (index(families, family) < 0) push(families, family);
	};
	if (input.kind == 'ipv4' || input.kind == 'ipv6') add_family(input.kind);
	else
		for (let answer in answers) add_family(ipv4(answer) ? 'ipv4' : 'ipv6');
	if (!length(families))
		return { available: true, valid: false, code: 'NO_ADDRESS', families };
	let interfaces = [];
	for (let family in families) {
		let matched_rules = [], matched_routes = [];
		for (let item in rules)
			if (item.family == family && (item.priority == 1000 || item.table == 100))
				push(matched_rules, item);
		for (let item in routes)
			if (item.family == family && item.table == 100)
				push(matched_routes, item);
		for (let item in matched_rules)
			if (!owned_entry(item, committed, 'rule'))
				return { available: true, valid: false, code: 'FOREIGN_ENTRY', families };
		for (let item in matched_routes)
			if (!owned_entry(item, committed, 'route'))
				return { available: true, valid: false, code: 'FOREIGN_ENTRY', families };
		if (length(matched_rules) != 1 || length(matched_routes) != 1)
			return { available: true, valid: false, code: 'CONTRADICTORY', families };
		let rule = matched_rules[0], route = matched_routes[0];
		if (rule.priority != 1000 || lc(rule.mark) != '0x1' ||
			lc(rule.mask) != '0xffffffff' || rule.table != 100 || rule.ambiguous === true)
			return { available: true, valid: false, code: 'MARK_MISMATCH', families };
		let local = route.kind == 'local' && route.device == 'lo';
		let tun = route.kind == 'unicast' && route.device == 'clash-tun' &&
			routing.interfaces?.['clash-tun'] === true;
		if ((!local && !tun) || route.ambiguous === true)
			return { available: true, valid: false, code: 'ROUTE_MISMATCH', families };
		push(interfaces, route.device);
	}
	return { available: true, valid: true, code: 'VERIFIED', families,
		mark: '0x1', table: 100, interfaces };
};
function policy(values, field, wanted) {
	if (values == null)
		return { available: false, valid: false, code: 'UNAVAILABLE',
			matched: false, decision: 'unknown' };
	if (type(values) != 'array')
		return { available: true, valid: false, code: 'MALFORMED',
			matched: false, decision: 'unknown' };
	if (length(values) > 128)
		return { available: true, valid: false, code: 'OVERSIZED',
			matched: false, decision: 'unknown' };
	let selected = 'unknown', matched = false, seen = {};
	for (let item in values) {
		if (!exact_allowed(item, { [field]: true, decision: true }))
			return { available: true, valid: false, code: 'MALFORMED',
				matched: false, decision: 'unknown' };
		let candidate = item[field];
		if ((field == 'mac' && !safe_mac(candidate)) ||
			(field == 'name' && !safe_interface(candidate)))
			return { available: true, valid: false, code: 'MALFORMED',
				matched: false, decision: 'unknown' };
		if (type(item.decision) != 'string' || !exists(DECISIONS, uc(item.decision)))
			return { available: true, valid: false, code: 'INVALID_DECISION',
				matched: false, decision: 'unknown' };
		let normalized = lc(candidate);
		if (seen[normalized])
			return { available: true, valid: false, code: 'MALFORMED',
				matched: false, decision: 'unknown' };
		seen[normalized] = true;
		if (wanted != null && normalized == lc(wanted)) {
			matched = true;
			selected = uc(item.decision);
		}
	}
	return { available: true, valid: true, code: length(values) ? 'VALID' : 'EMPTY',
		matched, decision: selected };
};
function bypass(values, input) {
	if (values == null)
		return { available: false, valid: false, code: 'UNAVAILABLE', matched: false };
	if (type(values) != 'array')
		return { available: true, valid: false, code: 'MALFORMED', matched: false };
	if (length(values) > 128)
		return { available: true, valid: false, code: 'OVERSIZED', matched: false };
	let matched = false;
	for (let value in values) {
		if (type(value) != 'string' || length(value) > 253)
			return { available: true, valid: false, code: 'MALFORMED', matched: false };
		let normalized = ipv6(value) ? normalize_ipv6(value) : lc(value);
		if (!(ipv4(normalized) || ipv6(normalized) || domain(normalized)))
			return { available: true, valid: false, code: 'MALFORMED', matched: false };
		if (normalized == input.target) matched = true;
	}
	return { available: true, valid: true, code: length(values) ? 'VALID' : 'EMPTY', matched };
};
function step(steps, source, evidence, decision) {
	if (length(steps) >= MAX_STEPS) fail('RESPONSE_TOO_LARGE');
	push(steps, { source, evidence, decision });
};

export function create(dependencies) {
	if (type(dependencies?.runtime) != 'object' ||
		type(dependencies?.desired) != 'function' || type(dependencies?.observed) != 'function' ||
		type(dependencies?.dns_answers) != 'function' ||
		type(dependencies?.profile) != 'string' || type(dependencies?.config_content) != 'string')
		invalid();
	return {
		run: (...args) => {
			if (length(args) != 1) invalid();
			let input = exact_input(args[0]), desired, observed;
			try { desired = dependencies.desired(); observed = dependencies.observed(); }
			catch (error) { fail('HEALTH_FAILED'); }
			if (type(desired) != 'object' || type(observed) != 'object')
				fail('HEALTH_FAILED');
			let answers = [], dns_available = input.kind != 'domain',
				dns_cached = false;
			if (input.kind == 'domain')
				try {
					let values = dependencies.dns_answers(input.target);
					if (type(values) == 'array' && length(values) <= 16) {
						dns_available = true;
						dns_cached = true;
						for (let value in values) {
							if (!(ipv4(value) || ipv6(value))) {
								dns_available = false;
								dns_cached = false;
								answers = [];
								break;
							}
							push(answers, ipv6(value) ? normalize_ipv6(value) : lc(value));
						}
					}
				}
				catch (error) {}
			let steps = [], candidate = 'unknown', candidate_source = null;
			step(steps, 'input', { kind: input.kind, target: input.target,
				device: input.device, interface: input.interface }, 'unknown');
			step(steps, 'dns', { available: dns_available, cached: dns_cached, answers },
				'unknown');
			let interface_policy = policy(desired.interfaces, 'name', input.interface);
			let outside_scope = interface_policy.matched && interface_policy.decision == 'DIRECT';
			if (outside_scope) {
				candidate = 'DIRECT'; candidate_source = 'interface_scope';
			}
			else if (interface_policy.matched && interface_policy.decision == 'BLOCK') {
				candidate = 'BLOCK'; candidate_source = 'interface_policy';
			}
			step(steps, 'interface_policy', { available: interface_policy.available,
				valid: interface_policy.valid, code: interface_policy.code,
				matched: interface_policy.matched, outside_scope },
				interface_policy.decision);
			let device = policy(desired.devices, 'mac', input.device);
			if (!outside_scope && candidate == 'unknown' && device.matched) {
				candidate = device.decision; candidate_source = 'device_policy';
			}
			step(steps, 'device_policy', { available: device.available, valid: device.valid,
				code: device.code, matched: device.matched, applied: !outside_scope && device.matched },
				device.decision);
			let proxy_servers = bypass(desired.proxy_servers, input);
			if (!outside_scope && candidate != 'BLOCK' && proxy_servers.matched) {
				candidate = 'DIRECT'; candidate_source = 'proxy_server_bypass';
			}
			step(steps, 'proxy_server_bypass', { available: proxy_servers.available,
				valid: proxy_servers.valid, code: proxy_servers.code,
				matched: proxy_servers.matched },
				proxy_servers.matched ? 'DIRECT' : 'unknown');
			let rule = mihomo_reason(dependencies, input, answers);
			if (candidate == 'unknown' && rule.matched) {
				candidate = rule.decision; candidate_source = 'mihomo_rule';
			}
			step(steps, 'mihomo_rule', { available: rule.available,
				matched: rule.matched, type: rule.type, ordered: rule.ordered,
				code: rule.code }, rule.decision);
			let route = routing_reason(observed, input, answers);
			if (!route.valid && candidate != 'BLOCK' &&
				candidate_source != 'proxy_server_bypass' &&
				candidate_source != 'interface_scope') {
				candidate = 'unknown'; candidate_source = null;
			}
			let desired_valid = device.valid && interface_policy.valid && proxy_servers.valid;
			if (!desired_valid && candidate != 'BLOCK') {
				candidate = 'unknown'; candidate_source = null;
			}
			step(steps, 'routing', route, candidate);
			let guard_value = desired.guard?.enabled,
				guard_known = type(guard_value) == 'bool',
				guard_on = guard_known && guard_value === true,
				overridden = false;
			if (!guard_known && !outside_scope && candidate != 'BLOCK') {
				candidate = 'BLOCK'; overridden = true;
			}
			else if (guard_on && candidate_source != 'proxy_server_bypass' &&
				candidate_source != 'interface_scope' &&
				!(candidate_source == 'device_policy' && candidate == 'DIRECT') &&
				(candidate == 'DIRECT' || candidate == 'unknown')) {
				candidate = 'BLOCK'; overridden = true;
			}
			step(steps, 'guard', { known: guard_known,
				state: guard_known ? (guard_on ? 'enabled' : 'disabled') : 'unknown',
				enabled: guard_known ? guard_on : null, fail_closed: overridden,
				proxy_server_exception: candidate_source == 'proxy_server_bypass',
				device_direct_exception: candidate_source == 'device_policy' && candidate == 'DIRECT',
				outside_scope }, candidate);
			let result = redact.value('route_test', { input, decision: candidate, steps });
			if (length(sprintf('%J', result)) > 32768) fail('RESPONSE_TOO_LARGE');
			return result;
		}
	};
};
