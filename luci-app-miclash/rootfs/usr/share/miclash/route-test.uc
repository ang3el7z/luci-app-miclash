import { fail } from 'miclash.errors';
import * as mihomo from 'miclash.mihomo-api';
import * as redact from 'miclash.redact';

const DECISIONS = { DIRECT: true, PROXY: true, BLOCK: true };
const RULE_TYPES = {
	DOMAIN: true, 'DOMAIN-SUFFIX': true, 'DOMAIN-KEYWORD': true,
	'IP-CIDR': true, 'IP-CIDR6': true, MATCH: true
};
const MAX_STEPS = 16;

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
function ipv6(value) {
	if (type(value) != 'string' || !match(value, /^[0-9A-Fa-f:]+$/) ||
		index(value, ':') < 0 || length(value) > 45)
		return false;
	let doubles = split(value, '::');
	if (length(doubles) > 2) return false;
	let groups = 0;
	for (let side in doubles)
		if (length(side))
			for (let group in split(side, ':')) {
				if (!match(group, /^[0-9A-Fa-f]{1,4}$/)) return false;
				groups++;
			}
	return length(doubles) == 2 ? groups < 8 : groups == 8;
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
function safe_mac(value) {
	return type(value) == 'string' && match(value,
		/^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$/);
};
function safe_interface(value) {
	return type(value) == 'string' && length(value) >= 1 && length(value) <= 64 &&
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
	return { target: lc(value.target), kind,
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
		let parts = split(payload, '/');
		if (length(parts) != 2 || !ipv6(parts[0]) || !match(parts[1], /^[0-9]+$/) ||
			int(parts[1]) < 0 || int(parts[1]) > 128)
			return { known: false, matched: false };
		for (let candidate in candidates)
			if (ipv6(candidate) && candidate == parts[0])
				return { known: true, matched: true };
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
				if (name != 'type' && name != 'payload' && name != 'proxy' && name != 'size')
					return { available: true, matched: false, type: null,
						ordered: false, code: 'MALFORMED_RULE', decision: 'unknown' };
			if (rule.size != null && (type(rule.size) != 'int' || rule.size < 0))
				return { available: true, matched: false, type: null,
					ordered: false, code: 'MALFORMED_RULE', decision: 'unknown' };
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
	if (type(values) != 'array' || length(values) > 128 || wanted == null)
		return { matched: false, decision: 'unknown' };
	for (let item in values) {
		let candidate = item?.[field];
		if (type(candidate) != 'string' || type(item?.decision) != 'string') continue;
		if (lc(candidate) == lc(wanted)) {
			let decision = uc(item.decision);
			return { matched: exists(DECISIONS, decision),
				decision: exists(DECISIONS, decision) ? decision : 'unknown' };
		}
	}
	return { matched: false, decision: 'unknown' };
};
function bypass(values, input) {
	if (type(values) != 'array' || length(values) > 128)
		return false;
	for (let value in values) {
		if (type(value) != 'string' || length(value) > 253) continue;
		let normalized = lc(value);
		if (!(ipv4(normalized) || ipv6(normalized) || domain(normalized))) continue;
		if (normalized == input.target) return true;
	}
	return false;
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
			let answers = [];
			if (input.kind == 'domain')
				try {
					let values = dependencies.dns_answers(input.target);
					if (type(values) == 'array' && length(values) <= 16)
						for (let value in values)
							if ((ipv4(value) || ipv6(value)) && length(answers) < 16)
								push(answers, lc(value));
				}
				catch (error) {}
			let steps = [], candidate = 'unknown', candidate_source = null;
			step(steps, 'input', { kind: input.kind, target: input.target,
				device: input.device, interface: input.interface }, 'unknown');
			step(steps, 'dns', { cached: true, answers }, 'unknown');
			let device = policy(desired.devices, 'mac', input.device);
			if (candidate == 'unknown' && device.matched) {
				candidate = device.decision; candidate_source = 'device_policy';
			}
			step(steps, 'device_policy', { matched: device.matched }, device.decision);
			let interface_policy = policy(desired.interfaces, 'name', input.interface);
			if (candidate == 'unknown' && interface_policy.matched) {
				candidate = interface_policy.decision; candidate_source = 'interface_policy';
			}
			step(steps, 'interface_policy', { matched: interface_policy.matched },
				interface_policy.decision);
			let is_bypass = bypass(desired.proxy_servers, input);
			if (candidate == 'unknown' && is_bypass) {
				candidate = 'DIRECT'; candidate_source = 'proxy_server_bypass';
			}
			step(steps, 'proxy_server_bypass', { matched: is_bypass },
				is_bypass ? 'DIRECT' : 'unknown');
			let rule = mihomo_reason(dependencies, input, answers);
			if (candidate == 'unknown' && rule.matched) {
				candidate = rule.decision; candidate_source = 'mihomo_rule';
			}
			step(steps, 'mihomo_rule', { available: rule.available,
				matched: rule.matched, type: rule.type, ordered: rule.ordered,
				code: rule.code }, rule.decision);
			let route = routing_reason(observed, input, answers);
			if (!route.valid && candidate != 'BLOCK' &&
				candidate_source != 'proxy_server_bypass') {
				candidate = 'unknown'; candidate_source = null;
			}
			step(steps, 'routing', route, candidate);
			let guard_on = desired.guard?.enabled === true, overridden = false;
			if (guard_on && candidate_source != 'proxy_server_bypass' &&
				(candidate == 'DIRECT' || candidate == 'unknown')) {
				candidate = 'BLOCK'; overridden = true;
			}
			step(steps, 'guard', { enabled: guard_on, fail_closed: overridden,
				proxy_server_exception: candidate_source == 'proxy_server_bypass' }, candidate);
			let result = redact.value('route_test', { input, decision: candidate, steps });
			if (length(sprintf('%J', result)) > 32768) fail('RESPONSE_TOO_LARGE');
			return result;
		}
	};
};
