import { fail } from 'miclash.errors';
import * as mihomo from 'miclash.mihomo-api';
import * as redact from 'miclash.redact';

const DECISIONS = { DIRECT: true, PROXY: true, BLOCK: true };
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
function rule_matches(rule, input, answers) {
	let type = uc(rule.type), payload = lc(rule.payload);
	if (type == 'MATCH') return true;
	if (input.kind == 'domain') {
		if (type == 'DOMAIN') return input.target == payload;
		if (type == 'DOMAIN-SUFFIX') return suffix(input.target, payload);
		if (type == 'DOMAIN-KEYWORD') return index(input.target, payload) >= 0;
	}
	let candidates = input.kind == 'domain' ? answers : [ input.target ];
	if (type == 'IP-CIDR')
		for (let candidate in candidates)
			if (ipv4(candidate) && cidr4(candidate, payload)) return true;
	if (type == 'IP-CIDR6')
		for (let candidate in candidates)
			if (ipv6(candidate) && candidate == payload) return true;
	return false;
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
			return { available: false, matched: false, type: null, decision: 'unknown' };
		for (let rule in reply.data.rules) {
			if (type(rule?.type) != 'string' || type(rule?.payload) != 'string' ||
				type(rule?.proxy) != 'string' || length(rule.type) > 32 ||
				length(rule.payload) > 512 || length(rule.proxy) > 128)
				continue;
			if (rule_matches(rule, input, answers))
				return { available: true, matched: true, type: uc(rule.type),
					decision: rule_decision(rule.proxy) };
		}
		return { available: true, matched: false, type: null, decision: 'unknown' };
	}
	catch (error) {
		return { available: false, matched: false, type: null, decision: 'unknown' };
	}
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
function bypass(values, input, answers) {
	if (type(values) != 'array' || length(values) > 128)
		return false;
	for (let value in values) {
		if (type(value) != 'string' || length(value) > 253) continue;
		if (lc(value) == input.target) return true;
		for (let answer in answers)
			if (lc(value) == lc(answer)) return true;
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
			let is_bypass = bypass(desired.proxy_servers, input, answers);
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
				matched: rule.matched, type: rule.type }, rule.decision);
			let rules = observed.routing?.rules, routes = observed.routing?.routes;
			step(steps, 'routing', {
				mark_rules: type(rules) == 'array' ? min(length(rules), 64) : 0,
				routes: type(routes) == 'array' ? min(length(routes), 64) : 0
			}, candidate);
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
