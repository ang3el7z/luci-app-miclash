import { fail } from 'miclash.errors';
import { sha256 } from 'digest';

export const LOCAL4 = '0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.0.2.0/24, 192.88.99.0/24, 192.168.0.0/16, 198.51.100.0/24, 203.0.113.0/24, 224.0.0.0/4, 240.0.0.0/4';
export const LOCAL6 = '::/128, ::1/128, fc00::/7, fe80::/10, ff00::/8';

function valid_interface(value) {
	return type(value) == 'string' && length(value) > 0 && length(value) <= 15 &&
		value != '.' && value != '..' && !!match(value, /^[A-Za-z0-9_.-]+$/);
};

function valid_ipv4(value) {
	let parts = split(value, '.');
	if (length(parts) != 4) return false;
	for (let part in parts)
		if (!match(part, /^(0|[1-9][0-9]{0,2})$/) || int(part) > 255) return false;
	return true;
};

function valid_ipv6(value) {
	if (type(value) != 'string' || !length(value) || match(value, /[^0-9A-Fa-f:.]/) ||
	    match(value, /::.*::/)) return false;
	let compressed = index(value, '::') >= 0;
	let halves = compressed ? split(value, '::') : [ value ];
	if (length(halves) != (compressed ? 2 : 1)) return false;
	if (compressed && index(halves[0], '.') >= 0) return false;
	let units = 0, all = [];
	for (let half in halves) if (length(half)) for (let part in split(half, ':')) push(all, part);
	for (let i = 0; i < length(all); i++) {
		let part = all[i];
		if (!length(part)) return false;
		if (index(part, '.') >= 0) {
			if (i != length(all) - 1 || !valid_ipv4(part)) return false;
			units += 2;
		}
		else {
			if (!match(part, /^[0-9A-Fa-f]{1,4}$/)) return false;
			units++;
		}
	}
	return compressed ? units < 8 : units == 8;
};

function valid_ip(value) { return valid_ipv4(value) || valid_ipv6(value); };
function valid_cidr(value) {
	let at = rindex(value, '/');
	if (at < 1) return false;
	let address = substr(value, 0, at), prefix = substr(value, at + 1);
	if (!match(prefix, /^(0|[1-9][0-9]{0,2})$/)) return false;
	return valid_ipv4(address) ? int(prefix) <= 32 : valid_ipv6(address) && int(prefix) <= 128;
};

export function validate(desired) {
	if (type(desired) != 'object' || index([ 'tproxy', 'tun', 'mixed' ], desired.proxy_mode) < 0 ||
	    index([ 'explicit', 'exclude' ], desired.interface_mode) < 0 ||
	    type(desired.guard) != 'bool' || type(desired.quic) != 'bool' || desired.set_names != null)
		fail('INVALID_ARGUMENT');
	for (let key in [ 'lan', 'wan', 'server_ips', 'fakeip_cidrs', 'device_policies', 'ip_families' ])
		if (type(desired[key]) != 'array') fail('INVALID_ARGUMENT');
	for (let name in [ ...desired.lan, ...desired.wan ]) if (!valid_interface(name)) fail('INVALID_ARGUMENT');
	for (let ip in desired.server_ips) if (!valid_ip(ip)) fail('INVALID_ARGUMENT');
	for (let cidr in desired.fakeip_cidrs) if (!valid_cidr(cidr)) fail('INVALID_ARGUMENT');
	for (let family in desired.ip_families) if (family != 'ipv4' && family != 'ipv6') fail('INVALID_ARGUMENT');
	for (let policy in desired.device_policies) {
		if (type(policy) != 'object' || !match(policy.id, /^[A-Za-z0-9_.-]+$/) ||
		    !match(policy.mac, /^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$/) ||
		    index([ 'block', 'direct', 'proxy', 'inherit' ], policy.action) < 0) fail('INVALID_ARGUMENT');
	}
	if (desired.generation != null && !match(desired.generation, /^[0-9a-f]{12}$/)) fail('INVALID_ARGUMENT');
	if (desired.previous_generation != null && !match(desired.previous_generation, /^[0-9a-f]{12}$/)) fail('INVALID_ARGUMENT');
	return desired;
};

export function generation(desired, canonical_policy) {
	if (desired.generation != null) return desired.generation;
	if (type(canonical_policy) != 'string') fail('INVALID_ARGUMENT');
	return substr(sha256(canonical_policy), 0, 12);
};

export function quoted_set(values) {
	let quoted = [];
	for (let value in values) push(quoted, sprintf('%J', value));
	return '{ ' + join(', ', quoted) + ' }';
};
