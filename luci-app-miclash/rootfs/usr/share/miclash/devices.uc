import { fail } from 'miclash.errors';
import * as redact from 'miclash.redact';
import * as settings from 'miclash.settings';
import * as storage from 'miclash.storage';
import { with_lock } from 'miclash.mutation_lock';
import * as schedule from 'miclash.schedule';

const CONFIG = 'miclash';
const POLICY_TYPE = 'device_policy';
const JOURNAL = '/etc/miclash/device-policies.json';
const MAX_TIMESTAMP = 4102444799;
const MAX_OBSERVATION = 262144;
const MAX_PROVENANCE = 512;
const MAX_LINES = MAX_PROVENANCE;
const MAX_LINE = 512;
const MAX_DEVICES = 256;
const MAX_ADDRESSES = 32;
const MAX_INTERFACES = 16;
const MAX_EVIDENCE = 16;
const MAX_CONFLICTS = MAX_ADDRESSES * 2 + 2;
const MAX_POLICIES = 256;
const MAX_POLICY_OPTIONS = 10;
const MAX_POLICY_OPTION_BYTES = 512;
const MAX_POLICY_SECTION_BYTES = 1024;
const MAX_JOURNAL_BYTES = 524288;
const MAX_REVISION = 2147483647;
const MAX_REASONING = 1024;
const HISTORY_SECONDS = 7 * 86400;

function invalid(code) { fail(code ?? 'INVALID_ARGUMENT'); };
function clone(value) { return value == null ? value : json(sprintf('%J', value)); };
function same(left, right) { return sprintf('%J', left) == sprintf('%J', right); };
function exact(value, allowed, required) {
	if (type(value) != 'object' || type(value) == 'array') invalid();
	for (let name in value) if (!exists(allowed, name)) invalid();
	for (let name in required ?? allowed) if (!exists(value, name)) invalid();
};
function has(values, wanted) { for (let value in values ?? []) if (value == wanted) return true; return false; };
function same_strings(left, right) {
	if (length(left) != length(right)) return false;
	for (let at = 0; at < length(left); at++) if (left[at] != right[at]) return false;
	return true;
};
function add_unique(values, value) { if (value != null && !has(values, value)) push(values, value); };
function canonical_strings(values) {
	let seen = {}, output = [];
	for (let value in values) if (!seen[value]) { seen[value] = true; push(output, value); }
	return sort(output);
};
function conflict(reason, subject, evidence) {
	let all = canonical_strings(evidence), bounded = [];
	for (let i = 0; i < min(length(all), MAX_EVIDENCE); i++) push(bounded, all[i]);
	return { reason, subject, evidence: bounded, total: length(all), truncated: length(all) > MAX_EVIDENCE };
};
function add_conflict(item, reason, subject, evidence) {
	for (let existing in item.conflicts)
		if (existing.reason == reason && existing.subject == subject) {
			existing.evidence = canonical_strings([ ...existing.evidence, ...evidence ]);
			existing.total = length(existing.evidence); existing.truncated = false;
			return;
		}
	if (length(item.conflicts) < MAX_CONFLICTS) push(item.conflicts, {
		reason, subject, evidence: canonical_strings(evidence),
		total: length(canonical_strings(evidence)), truncated: false
	});
};
function integer(value, minimum, maximum, code) {
	if (type(value) != 'int' || value < minimum || value > maximum) invalid(code);
	return value;
};
function interface_name(value, code) {
	if (type(value) != 'string' || length(value) < 1 || length(value) > 15 ||
	    !match(value, /^[A-Za-z0-9][A-Za-z0-9_.:-]*$/)) invalid(code);
	return value;
};
function mac(value, code) {
	if (type(value) != 'string' || length(value) != 17 ||
	    !match(value, /^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$/))
		invalid(code);
	let normalized = lc(value), fields = split(normalized, ':');
	let first = int(fields[0], 16);
	if ((first & 1) != 0 || normalized == '00:00:00:00:00:00' ||
	    normalized == 'ff:ff:ff:ff:ff:ff') invalid(code);
	return normalized;
};
function local_mac(value) { return (int(substr(value, 0, 2), 16) & 2) != 0; };
function observed_mac(value) {
	if (value == null) return { mac: null, reason: 'mac_unavailable' };
	if (type(value) != 'string' || !match(value, /^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$/))
		invalid('INVALID_RESPONSE');
	return { mac: mac(value, 'INVALID_RESPONSE'), reason: null };
};
function ipv4(value) {
	if (type(value) != 'string') return null;
	let parts = split(value, '.');
	if (length(parts) != 4) return null;
	let output = [];
	for (let part in parts) {
		if (!match(part, /^(0|[1-9][0-9]{0,2})$/) || int(part) > 255) return null;
		push(output, sprintf('%d', int(part)));
	}
	return join('.', output);
};
function ipv6_side(value, ipv4_allowed) {
	let groups = [];
	if (!length(value)) return groups;
	let fields = split(value, ':');
	for (let at, field in fields) {
		if (index(field, '.') >= 0) {
			let v4 = ipv4(field);
			if (!ipv4_allowed || at != length(fields) - 1 || v4 == null) return null;
			let octets = split(v4, '.');
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
function ipv6_groups(value) {
	if (type(value) != 'string' || length(value) > 45 || index(value, ':') < 0 ||
	    !match(value, /^[0-9A-Fa-f:.]+$/)) return null;
	let halves = split(value, '::');
	if (length(halves) > 2) return null;
	let left = ipv6_side(halves[0], length(halves) == 1);
	let right = length(halves) == 2 ? ipv6_side(halves[1], true) : [];
	if (left == null || right == null) return null;
	let used = length(left) + length(right), groups = [];
	if ((length(halves) == 1 && used != 8) || (length(halves) == 2 && used >= 8)) return null;
	for (let group in left) push(groups, group);
	if (length(halves) == 2) for (let count = used; count < 8; count++) push(groups, 0);
	for (let group in right) push(groups, group);
	return groups;
};
function ipv6(value) {
	let groups = type(value) == 'array' ? value : ipv6_groups(value);
	if (groups == null) return null;
	let best_at = -1, best_length = 0;
	for (let at = 0; at < 8;) {
		if (groups[at] != 0) { at++; continue; }
		let end = at; while (end < 8 && groups[end] == 0) end++;
		if (end - at > best_length) { best_at = at; best_length = end - at; }
		at = end;
	}
	if (best_length < 2) {
		let fields = []; for (let group in groups) push(fields, sprintf('%x', group));
		return join(':', fields);
	}
	let left = [], right = [];
	for (let at = 0; at < best_at; at++) push(left, sprintf('%x', groups[at]));
	for (let at = best_at + best_length; at < 8; at++) push(right, sprintf('%x', groups[at]));
	return join(':', left) + '::' + join(':', right);
};
function validate_ipv4_host(value, code, iface) {
	let octets = split(value, '.'), first = int(octets[0]);
	if (first == 0 || first == 127 || first >= 224 ||
	    (first == 169 && int(octets[1]) == 254 && iface == null)) invalid(code);
	return value;
};
function address(value, code, iface) {
	let v4 = ipv4(value);
	if (v4 != null) {
		// Private RFC1918 hosts are valid. Link-local requires interface evidence.
		validate_ipv4_host(v4, code, iface);
		return { address: v4, family: 'ipv4' };
	}
	let groups = ipv6_groups(value), v6 = groups == null ? null : ipv6(groups);
	if (v6 != null) {
		let all_zero = true; for (let group in groups) if (group != 0) all_zero = false;
		let mapped = true;
		for (let at = 0; at < 5; at++) if (groups[at] != 0) mapped = false;
		if (groups[5] != 0xffff) mapped = false;
		let compatible = true;
		for (let at = 0; at < 6; at++) if (groups[at] != 0) compatible = false;
		if (mapped) {
			let embedded = sprintf('%d.%d.%d.%d', groups[6] >> 8, groups[6] & 0xff,
				groups[7] >> 8, groups[7] & 0xff);
			validate_ipv4_host(embedded, code, iface);
		}
		// Global/private/link-local unicast are valid; link-local is interface scoped.
		if (all_zero || compatible || (groups[0] & 0xff00) == 0xff00 ||
		    ((groups[0] & 0xffc0) == 0xfe80 && iface == null)) invalid(code);
		return { address: v6, family: 'ipv6' };
	}
	invalid(code);
};
function strict_sorted_strings(values, maximum, validator) {
	if (type(values) != 'array' || length(values) > maximum) invalid();
	let previous = null;
	for (let value in values) {
		validator(value);
		if (previous != null && value <= previous) invalid();
		previous = value;
	}
	return values;
};
function bounded_counter(values, total, truncated, maximum, total_maximum) {
	integer(total, length(values), total_maximum);
	if (type(truncated) != 'bool') invalid();
	if (truncated) {
		if (length(values) != maximum || total <= maximum) invalid();
	}
	else if (total != length(values)) invalid();
};
function validate_address_record(value, timestamp) {
	exact(value, { address: true, family: true, current: true, last_seen: true, source: true,
		interfaces: true, interface_total: true, interfaces_truncated: true });
	if (type(value.current) != 'bool' || !has([ 'dhcp', 'neighbor' ], value.source)) invalid();
	let last_seen = integer(value.last_seen, 0, timestamp);
	strict_sorted_strings(value.interfaces, MAX_INTERFACES, interface_name);
	bounded_counter(value.interfaces, value.interface_total, value.interfaces_truncated,
		MAX_INTERFACES, MAX_PROVENANCE);
	if (value.source == 'dhcp' && (length(value.interfaces) || value.interface_total ||
	    value.interfaces_truncated)) invalid();
	if (value.source == 'neighbor' && !length(value.interfaces)) invalid();
	if (type(value.address) != 'string' || length(value.address) > 45) invalid();
	let interface_evidence = value.interfaces[0] ?? (value.interface_total > 0 ? 'truncated' : null);
	let parsed = address(value.address, null, interface_evidence);
	if (parsed.family != value.family || parsed.address != value.address) invalid();
	let interfaces = []; for (let iface in value.interfaces) push(interfaces, iface);
	return { address: parsed.address, family: parsed.family, current: value.current,
		last_seen, source: value.source, interfaces, interface_total: value.interface_total,
		interfaces_truncated: value.interfaces_truncated };
};
function hostname(value, code) {
	if (value == '*') return null;
	if (type(value) != 'string' || !length(value) || length(value) > 64 ||
	    !match(value, /^[A-Za-z0-9][A-Za-z0-9_.-]*$/)) invalid(code);
	return value;
};
function response(value, now) {
	exact(value, { observed_at: true, data: true });
	integer(value.observed_at, 0, MAX_TIMESTAMP, 'INVALID_RESPONSE');
	if (value.observed_at > now || now - value.observed_at > HISTORY_SECONDS || type(value.data) != 'string')
		invalid('INVALID_RESPONSE');
	if (length(value.data) > MAX_OBSERVATION) invalid('RESPONSE_TOO_LARGE');
	return value;
};
function cache_device(cache, identity, normalized_mac, host, identity_reason) {
	let item = cache.devices[identity];
	if (item == null) {
		if (length(keys(cache.devices)) >= MAX_DEVICES) invalid('RESPONSE_TOO_LARGE');
		let low = normalized_mac != null && local_mac(normalized_mac);
		item = cache.devices[identity] = {
			identity: { kind: normalized_mac == null ? 'ip' : 'mac', value: normalized_mac ?? identity,
				confidence: normalized_mac == null ? 'ephemeral' : (low ? 'low' : 'high'),
				persistent_policy_eligible: normalized_mac != null && !low,
				reason: normalized_mac == null ? (identity_reason ?? 'mac_unavailable') :
					(low ? 'locally_administered_mac' : 'stable_mac') },
			mac: normalized_mac, hostname: host, addresses: [], last_seen: 0,
			sources: [], interfaces: [], interface_total: 0, interfaces_truncated: false,
			conflicts: []
		};
	}
	if (host != null && item.hostname == null) item.hostname = host;
	else if (host != null && item.hostname != host) {
		add_conflict(item, 'hostname_changed', identity, [ item.hostname, host ]);
		if (host < item.hostname) item.hostname = host;
	}
	return item;
};
function add_observation(cache, normalized_mac, ip, host, source, iface, seen, current, identity_reason) {
	let parsed = address(ip, 'INVALID_RESPONSE', iface);
	let identity;
	if (normalized_mac == null) {
		cache.ephemeral_sequence++;
		identity = 'ephemeral:' + seen + ':' + cache.ephemeral_sequence + ':' + source;
	}
	else identity = 'mac:' + normalized_mac;
	let item = cache_device(cache, identity, normalized_mac, host, identity_reason), existing = null;
	for (let candidate in item.addresses)
		if (candidate.address == parsed.address) { existing = candidate; break; }
	if (existing == null) {
		if (length(item.addresses) >= MAX_ADDRESSES) invalid('RESPONSE_TOO_LARGE');
		existing = { address: parsed.address, family: parsed.family, current: false,
			last_seen: seen, source, interfaces: [], interface_total: 0,
			interfaces_truncated: false };
		push(item.addresses, existing);
	}
	existing.last_seen = max(existing.last_seen, seen);
	existing.current = existing.current || current;
	if (source == 'neighbor' || existing.source != 'neighbor') existing.source = source;
	add_unique(existing.interfaces, iface);
	existing.interfaces = sort(existing.interfaces);
	item.last_seen = max(item.last_seen, seen);
	add_unique(item.sources, source); add_unique(item.interfaces, iface);
	item.sources = sort(item.sources); item.interfaces = sort(item.interfaces);
};
function parse_dhcp(cache, observed, now) {
	let lines = split(observed.data, '\n');
	if (length(lines) > MAX_LINES + 1) invalid('RESPONSE_TOO_LARGE');
	for (let raw in lines) {
		if (!length(raw)) continue;
		if (length(raw) > MAX_LINE) invalid('RESPONSE_TOO_LARGE');
		let fields = split(trim(raw), /[ \t]+/);
		if (length(fields) != 5 || !match(fields[0], /^(0|[1-9][0-9]*)$/) ||
		    length(fields[4]) > 128 || match(fields[4], /[[:cntrl:]]/)) invalid('INVALID_RESPONSE');
		let expiry = int(fields[0]); integer(expiry, 0, MAX_TIMESTAMP, 'INVALID_RESPONSE');
		let observed_mac_value = observed_mac(fields[1]);
		add_observation(cache, observed_mac_value.mac, fields[2],
			hostname(fields[3], 'INVALID_RESPONSE'), 'dhcp', null, observed.observed_at,
			expiry == 0 || expiry >= now, observed_mac_value.reason);
	}
};
function parse_neighbors(cache, observed, family) {
	let values;
	try { values = json(observed.data); } catch (error) { invalid('INVALID_RESPONSE'); }
	if (type(values) != 'array') invalid('INVALID_RESPONSE');
	if (length(values) > MAX_LINES) invalid('RESPONSE_TOO_LARGE');
	for (let value in values) {
		exact(value, { dst: true, dev: true, lladdr: true, state: true }, { dst: true, dev: true, state: true });
		let iface = interface_name(value.dev, 'INVALID_RESPONSE');
		let parsed = address(value.dst, 'INVALID_RESPONSE', iface);
		if (parsed.family != family) invalid('INVALID_RESPONSE');
		if (type(value.state) != 'array' || !length(value.state) || length(value.state) > 8)
			invalid('INVALID_RESPONSE');
		for (let state in value.state)
			if (type(state) != 'string' || !match(state, /^[A-Z_]{2,16}$/)) invalid('INVALID_RESPONSE');
		let observed_mac_value = observed_mac(value.lladdr);
		add_observation(cache, observed_mac_value.mac, parsed.address, null, 'neighbor', iface,
			observed.observed_at, !has(value.state, 'FAILED') && !has(value.state, 'INCOMPLETE'),
			observed_mac_value.reason);
	}
};
function conflict_pass(devices) {
	let hosts = {}, addresses = {};
	for (let key, item in devices) {
		if (item.hostname != null) { hosts[item.hostname] ??= []; push(hosts[item.hostname], key); }
		for (let address in item.addresses) if (address.current) {
			addresses[address.family + ':' + address.address] ??= [];
			push(addresses[address.family + ':' + address.address], key);
		}
	}
	for (let host, identities in hosts) if (length(identities) > 1) {
		identities = sort(identities);
		for (let identity in identities)
			add_conflict(devices[identity], 'duplicate_hostname', host, identities);
	}
	for (let ip, identities in addresses) if (length(identities) > 1) {
		identities = sort(identities);
		for (let identity in identities)
			add_conflict(devices[identity], 'shared_address', ip, identities);
	}
	for (let identity, item in devices) {
		let all_device_interfaces = canonical_strings(item.interfaces), bounded_device_interfaces = [];
		item.interface_total = length(all_device_interfaces);
		item.interfaces_truncated = item.interface_total > MAX_INTERFACES;
		for (let i = 0; i < min(item.interface_total, MAX_INTERFACES); i++)
			push(bounded_device_interfaces, all_device_interfaces[i]);
		item.interfaces = bounded_device_interfaces;
		for (let item_address in item.addresses) {
			let all_interfaces = canonical_strings(item_address.interfaces), bounded_interfaces = [];
			if (length(all_interfaces) > 1)
				add_conflict(item, 'address_interfaces', item_address.address, all_interfaces);
			item_address.interface_total = length(all_interfaces);
			item_address.interfaces_truncated = item_address.interface_total > MAX_INTERFACES;
			for (let i = 0; i < min(item_address.interface_total, MAX_INTERFACES); i++)
				push(bounded_interfaces, all_interfaces[i]);
			item_address.interfaces = bounded_interfaces;
		}
		let normalized_conflicts = [];
		for (let item_conflict in item.conflicts)
			push(normalized_conflicts, conflict(item_conflict.reason, item_conflict.subject,
				item_conflict.evidence));
		item.conflicts = sort(normalized_conflicts, (a, b) =>
			a.reason + ':' + (a.subject ?? '') < b.reason + ':' + (b.subject ?? '') ? -1 : 1);
	}
};

let compile_device;
function validate_device_map(value, now) {
	let devices = {};
	for (let key, item in value) {
		let normalized = compile_device(item, now);
		let expected = normalized.identity.kind == 'mac' ?
			'mac:' + normalized.mac : normalized.identity.value;
		if (key != expected) invalid();
		devices[key] = normalized;
	}
	return devices;
};
function validate_cache_state(value, now) {
	if (type(value) != 'object' || type(value) == 'array') invalid('CORRUPT_STATE');
	let names = keys(value);
	if (!length(names)) return { last_now: null, ephemeral_sequence: 0, devices: {} };
	let allowed = { last_now: true, ephemeral_sequence: true, devices: true };
	for (let name in value) if (!exists(allowed, name)) invalid('CORRUPT_STATE');
	for (let name in allowed) if (!exists(value, name)) invalid('CORRUPT_STATE');
	if (type(value.last_now) != 'int' || value.last_now < 0 || value.last_now > MAX_TIMESTAMP ||
	    type(value.ephemeral_sequence) != 'int' || value.ephemeral_sequence < 0 ||
	    value.ephemeral_sequence > MAX_DEVICES || type(value.devices) != 'object' ||
	    type(value.devices) == 'array' || length(keys(value.devices)) > MAX_DEVICES)
		invalid('CORRUPT_STATE');
	let devices;
	try { devices = validate_device_map(value.devices, now); }
	catch (error) { invalid('CORRUPT_STATE'); }
	return { last_now: value.last_now, ephemeral_sequence: value.ephemeral_sequence, devices };
};

export function discover(app) {
	if (type(app?.clock?.now) != 'function' || type(app?.observers?.dhcp_leases) != 'function' ||
	    type(app?.observers?.neighbors) != 'function') invalid();
	let now_ms = app.clock.now();
	if (type(now_ms) != 'int' || now_ms < 0) invalid('CORRUPT_STATE');
	let now = int(now_ms / 1000), original = app.device_cache;
	if (now > MAX_TIMESTAMP) invalid('CORRUPT_STATE');
	let cache = validate_cache_state(original, now);
	if (cache.last_now != null && now < cache.last_now) invalid('CORRUPT_STATE');
	cache.last_now = now; cache.ephemeral_sequence = 0;
	for (let key, item in cache.devices) {
		if (item.identity?.kind == 'ip') { delete cache.devices[key]; continue; }
		item.conflicts = [];
		for (let item_address in item.addresses) item_address.current = false;
	}
	parse_dhcp(cache, response(app.observers.dhcp_leases(), now), now);
	parse_neighbors(cache, response(app.observers.neighbors('ipv4'), now), 'ipv4');
	parse_neighbors(cache, response(app.observers.neighbors('ipv6'), now), 'ipv6');
	for (let key, item in cache.devices) {
		let retained = [];
		for (let item_address in item.addresses)
			if (now - item_address.last_seen <= HISTORY_SECONDS) push(retained, item_address);
		item.addresses = retained;
		if (!length(retained) || now - item.last_seen > HISTORY_SECONDS) delete cache.devices[key];
	}
	conflict_pass(cache.devices);
	cache.devices = validate_device_map(cache.devices, now);
	let output = []; for (let key, item in cache.devices) push(output, clone(item));
	app.device_cache = cache;
	return output;
};

function schedule_spec(value) {
	if (value == null) return null;
	exact(value, { days: true, start: true, end: true, timezone: true });
	if (type(value.days) != 'array' || !length(value.days) || length(value.days) > 7 ||
	    type(value.start) != 'string' || type(value.end) != 'string' ||
	    !match(value.start, /^(0[0-9]|1[0-9]|2[0-3]):[0-5][0-9]$/) ||
	    !match(value.end, /^(0[0-9]|1[0-9]|2[0-3]):[0-5][0-9]$/) || value.start == value.end ||
	    type(value.timezone) != 'string' || length(value.timezone) > 64 ||
	    (value.timezone != 'UTC' &&
	     !match(value.timezone, /^[A-Za-z][A-Za-z0-9_+.-]*(\/[A-Za-z0-9_+.-]+)+$/))) invalid();
	let seen = {};
	for (let day in value.days) { integer(day, 1, 7); if (seen[day]) invalid(); seen[day] = true; }
	return clone(value);
};
function policy_id(value) {
	if (type(value) != 'string' || length(value) > 64 || !match(value, /^dp_[0-9]+_[0-9a-f]{16}$/)) invalid();
	return value;
};
function normalized_policy(value) {
	let allowed = { id: true, expected_revision: true, scope: true, mac: true,
		interface: true, action: true, schedule: true };
	exact(value, allowed, { scope: true, action: true });
	if (value.id != null) policy_id(value.id);
	if ((value.id == null) != (value.expected_revision == null)) invalid();
	if (value.expected_revision != null) integer(value.expected_revision, 1, MAX_REVISION);
	if (!has([ 'device', 'interface', 'global' ], value.scope) ||
	    !has([ 'block', 'proxy', 'direct', 'inherit' ], value.action)) invalid();
	let normalized = { id: value.id ?? null, expected_revision: value.expected_revision ?? null,
		scope: value.scope, mac: null, interface: null, action: value.action,
		schedule: schedule_spec(value.schedule ?? null) };
	if (value.scope == 'device') {
		if (value.mac == null || value.interface != null) invalid();
		normalized.mac = mac(value.mac);
	}
	else if (value.scope == 'interface') {
		if (value.interface == null || value.mac != null) invalid();
		normalized.interface = interface_name(value.interface);
	}
	else if (value.mac != null || value.interface != null) invalid();
	return normalized;
};
function cursor(app) {
	if (type(app?.uci?.cursor) != 'function') invalid();
	return app.uci.cursor();
};
function persisted(id, section) {
	let allowed = { '.type': true, '.name': true, '.anonymous': true, '.index': true,
		revision: true, scope: true, mac: true, interface: true, action: true, schedule: true };
	let option_count = 0, option_bytes = length(id);
	for (let name, value in section) {
		option_count++;
		if (option_count > MAX_POLICY_OPTIONS) invalid('RESPONSE_TOO_LARGE');
		option_bytes += length(name);
		if (type(value) == 'string') {
			if (length(value) > MAX_POLICY_OPTION_BYTES) invalid('RESPONSE_TOO_LARGE');
			option_bytes += length(value);
		}
		if (option_bytes > MAX_POLICY_SECTION_BYTES) invalid('RESPONSE_TOO_LARGE');
		if (!exists(allowed, name)) invalid('CORRUPT_STATE');
	}
	if (section['.name'] != null && section['.name'] != id) invalid('CORRUPT_STATE');
	if (section['.anonymous'] != null && type(section['.anonymous']) != 'bool') invalid('CORRUPT_STATE');
	if (section['.index'] != null && type(section['.index']) != 'int') invalid('CORRUPT_STATE');
	let revision = section?.revision;
	if (section?.['.type'] != POLICY_TYPE || !match(revision, /^[1-9][0-9]*$/)) invalid('CORRUPT_STATE');
	let raw = { id, expected_revision: int(revision), scope: section.scope,
		action: section.action, schedule: null };
	if (section.mac != null) raw.mac = section.mac;
	if (section.interface != null) raw.interface = section.interface;
	if (section.schedule != null && length(section.schedule)) {
		try { raw.schedule = json(section.schedule); } catch (error) { invalid('CORRUPT_STATE'); }
	}
	let normalized;
	try { normalized = normalized_policy(raw); }
	catch (error) { invalid('CORRUPT_STATE'); }
	return { id, revision: normalized.expected_revision, scope: normalized.scope,
		mac: normalized.mac, interface: normalized.interface, action: normalized.action,
		schedule: normalized.schedule };
};
function list_from(uci) {
	let config = uci.get_all(CONFIG) ?? {}, result = [], macs = {}, interfaces = {}, global = null;
	let policy_count = 0;
	for (let id, section in config) {
		if (section?.['.type'] != POLICY_TYPE) continue;
		policy_count++;
		if (policy_count > MAX_POLICIES) invalid('RESPONSE_TOO_LARGE');
		try { policy_id(id); } catch (error) { invalid('CORRUPT_STATE'); }
		let item = persisted(id, section);
		if (item.scope == 'device') { if (macs[item.mac]) invalid('CORRUPT_STATE'); macs[item.mac] = true; }
		if (item.scope == 'interface') { if (interfaces[item.interface]) invalid('CORRUPT_STATE'); interfaces[item.interface] = true; }
		if (item.scope == 'global') { if (global != null) invalid('CORRUPT_STATE'); global = item.id; }
		push(result, item);
	}
	return sort(result, (a, b) => a.id < b.id ? -1 : (a.id > b.id ? 1 : 0));
};
function journal_size(document) {
	let encoded;
	try { encoded = sprintf('%J\n', document); }
	catch (error) { invalid('INTERNAL'); }
	if (length(encoded) > MAX_JOURNAL_BYTES) invalid('RESOURCE_EXHAUSTED');
	return length(encoded);
};
function journal(app, document) {
	journal_size(document);
	storage.write_json(app, JOURNAL, document, 0o600);
};
function mutation_documents(before, after) {
	if (type(after) != 'array' || length(after) > MAX_POLICIES)
		invalid('RESOURCE_EXHAUSTED');
	for (let item in after)
		if (type(item.revision) != 'int' || item.revision < 1 || item.revision > MAX_REVISION)
			invalid('RESOURCE_EXHAUSTED');
	let prepared = { version: 1, owner: 'miclash-device-policies', state: 'prepared', before, after };
	let stable = { version: 1, owner: 'miclash-device-policies', state: 'stable', policies: after };
	journal_size(prepared); journal_size(stable);
	return { prepared, stable };
};
function read_journal(app) {
	let info = app?.fs?.lstat(JOURNAL);
	if (info == null) return null;
	if (info.type != 'file' || type(info.size) != 'int' || info.size < 1)
		invalid('CORRUPT_STATE');
	if (info.size > MAX_JOURNAL_BYTES) invalid('RESPONSE_TOO_LARGE');
	let source = app.fs.readfile(JOURNAL);
	if (type(source) != 'string' || length(source) != info.size) invalid('CORRUPT_STATE');
	if (length(source) > MAX_JOURNAL_BYTES) invalid('RESPONSE_TOO_LARGE');
	try { return json(source); }
	catch (error) { invalid('CORRUPT_STATE'); }
};
function journal_state(app, current, recover) {
	let value = read_journal(app);
	if (value == null) return;
	if (type(value) != 'object' || type(value) == 'array' || value.version != 1 ||
	    value.owner != 'miclash-device-policies' ||
	    (value.state != 'stable' && value.state != 'prepared'))
		invalid('CORRUPT_STATE');
	let allowed = value.state == 'stable'
		? { version: true, owner: true, state: true, policies: true }
		: { version: true, owner: true, state: true, before: true, after: true };
	for (let name in value) if (!exists(allowed, name)) invalid('CORRUPT_STATE');
	for (let name in allowed) if (!exists(value, name)) invalid('CORRUPT_STATE');
	for (let policies in value.state == 'stable' ? [ value.policies ] : [ value.before, value.after ])
		if (type(policies) != 'array' || length(policies) > MAX_POLICIES)
			invalid(type(policies) == 'array' ? 'RESPONSE_TOO_LARGE' : 'CORRUPT_STATE');
	if (value.state == 'stable' && same(value.policies, current)) return;
	if (value.state == 'prepared' && (same(value.before, current) || same(value.after, current))) {
		if (recover) journal(app, { version: 1, owner: 'miclash-device-policies', state: 'stable', policies: current });
		return;
	}
	invalid('CORRUPT_STATE');
};
function guard(app) {
	try {
		let value = settings.load(app).guard.enabled;
		return type(value) == 'bool' ? value : null;
	}
	catch (error) { return null; }
};
function guard_cursor(uci) {
	let value = uci.get(CONFIG, 'guard', 'enabled');
	if (value == null || value == '0' || value == 'false' || value == 'no' || value == 'off') return false;
	if (value == '1' || value == 'true' || value == 'yes' || value == 'on') return true;
	return null;
};
function write_section(uci, item) {
	if (uci.set(CONFIG, item.id, POLICY_TYPE) !== true) invalid('INTERNAL');
	let values = { revision: sprintf('%d', item.revision), scope: item.scope,
		action: item.action, schedule: item.schedule == null ? '' : sprintf('%J', item.schedule) };
	if (item.mac != null) values.mac = item.mac;
	if (item.interface != null) values.interface = item.interface;
	for (let name, value in values) if (uci.set(CONFIG, item.id, name, value) !== true) invalid('INTERNAL');
};
function delete_section(uci, id) {
	if (uci.delete(CONFIG, id) !== true) invalid('INTERNAL');
};

export function policy_list(app) {
	let result = list_from(cursor(app));
	journal_state(app, result, false);
	return clone(result);
};
export function timezones(app) {
	if (type(app?.timezones?.list) != 'function' || type(app?.timezones?.resolve) != 'function')
		invalid('INTERNAL');
	let provided = app.timezones.list();
	if (type(provided) != 'array' || !length(provided) || length(provided) > 512)
		invalid('INTERNAL');
	let seen = {}, rest = [], has_utc = false;
	for (let name in provided) {
		if (type(name) != 'string' || length(name) > 64 ||
		    (name != 'UTC' && !match(name, /^[A-Za-z][A-Za-z0-9_+.-]*(\/[A-Za-z0-9_+.-]+)+$/)) ||
		    seen[name]) invalid('INTERNAL');
		seen[name] = true;
		if (name == 'UTC') has_utc = true; else push(rest, name);
	}
	if (!has_utc) invalid('INTERNAL');
	sort(rest);
	return [ 'UTC', ...rest ];
};
function validate_policy_timezone(app, policy) {
	if (policy.schedule == null) return true;
	if (index(timezones(app), policy.schedule.timezone) < 0)
		invalid('VALIDATION_FAILED');
	let now = app?.clock?.now();
	if (type(now) != 'int' || now < 0) invalid('INTERNAL');
	let timestamp = int(now / 1000), resolved;
	try { resolved = app.timezones.resolve(policy.schedule.timezone, timestamp); }
	catch (error) { invalid('VALIDATION_FAILED'); }
	if (resolved == null) invalid('VALIDATION_FAILED');
	try { schedule.active(policy.schedule, timestamp, resolved); }
	catch (error) { invalid('VALIDATION_FAILED'); }
	return true;
};
export function policy_set(app, policy) {
	let wanted = normalized_policy(policy);
	validate_policy_timezone(app, wanted);
	if (wanted.action == 'direct' && guard(app) !== false) invalid('VALIDATION_FAILED');
	return with_lock(app, { barrier: 'normal', wait_ms: 0 }, () => {
		let uci = cursor(app);
		for (let name in uci.changes(CONFIG) ?? {}) invalid('BUSY');
		if (wanted.action == 'direct' && guard_cursor(uci) !== false) invalid('VALIDATION_FAILED');
		let before = list_from(uci); journal_state(app, before, true);
		let existing = null;
		for (let item in before) if (item.id == wanted.id) existing = item;
		if (wanted.id != null && (existing == null || existing.revision != wanted.expected_revision)) invalid('BUSY');
		if (wanted.id == null && length(before) >= MAX_POLICIES) invalid('RESOURCE_EXHAUSTED');
		if (existing != null && existing.revision >= MAX_REVISION) invalid('RESOURCE_EXHAUSTED');
		if (wanted.id == null) {
			let now = app.clock.now(), occupied = {};
			if (type(now) != 'int' || now < 0 || now > 9007199254740991) invalid('INTERNAL');
			for (let item in before) occupied[item.id] = true;
			for (let attempt = 0; attempt < 16; attempt++) {
				let suffix = app.random.hex(8);
				if (!match(suffix, /^[0-9a-f]{16}$/)) invalid('INTERNAL');
				let candidate = 'dp_' + now + '_' + suffix;
				if (!occupied[candidate]) { wanted.id = candidate; break; }
			}
			if (wanted.id == null) invalid('INTERNAL');
		}
		for (let item in before) if (item.id != wanted.id &&
		    ((wanted.scope == 'device' && item.scope == 'device' && item.mac == wanted.mac) ||
		     (wanted.scope == 'interface' && item.scope == 'interface' && item.interface == wanted.interface) ||
		     (wanted.scope == 'global' && item.scope == 'global'))) invalid('VALIDATION_FAILED');
		let result = { id: wanted.id, revision: existing == null ? 1 : existing.revision + 1,
			scope: wanted.scope, mac: wanted.mac, interface: wanted.interface,
			action: wanted.action, schedule: wanted.schedule };
		let after = []; for (let item in before) if (item.id != result.id) push(after, item); push(after, result);
		after = sort(after, (a, b) => a.id < b.id ? -1 : (a.id > b.id ? 1 : 0));
		let documents = mutation_documents(before, after);
		journal(app, documents.prepared);
		if (existing != null) delete_section(uci, existing.id);
		write_section(uci, result);
		if (uci.commit(CONFIG) !== true) { try { uci.revert(CONFIG); } catch (error) {} invalid('INTERNAL'); }
		journal(app, documents.stable);
		return clone(result);
	});
};
export function policy_delete(app, id, expected_revision) {
	policy_id(id); integer(expected_revision, 1, MAX_REVISION);
	return with_lock(app, { barrier: 'normal', wait_ms: 0 }, () => {
		let uci = cursor(app); for (let name in uci.changes(CONFIG) ?? {}) invalid('BUSY');
		let before = list_from(uci); journal_state(app, before, true);
		let existing = null; for (let item in before) if (item.id == id) existing = item;
		if (existing == null) invalid('NOT_FOUND');
		if (existing.revision != expected_revision) invalid('BUSY');
		let after = []; for (let item in before) if (item.id != id) push(after, item);
		let documents = mutation_documents(before, after);
		journal(app, documents.prepared);
		delete_section(uci, id);
		if (uci.commit(CONFIG) !== true) { try { uci.revert(CONFIG); } catch (error) {} invalid('INTERNAL'); }
		journal(app, documents.stable);
		return true;
	});
};

function subject(value) {
	exact(value, { mac: true, interface: true, interfaces: true, interface_total: true,
		interfaces_truncated: true, timestamp: true }, { timestamp: true });
	if (value.interface != null && value.interfaces != null) invalid();
	let interfaces = value.interfaces ?? (value.interface == null ? [] : [ value.interface ]);
	if (type(interfaces) != 'array' || length(interfaces) > MAX_INTERFACES) invalid();
	let normalized_interfaces = [];
	for (let iface in interfaces) add_unique(normalized_interfaces, interface_name(iface));
	normalized_interfaces = sort(normalized_interfaces);
	let interface_total = value.interface_total ?? length(normalized_interfaces);
	let interfaces_truncated = value.interfaces_truncated ?? false;
	bounded_counter(normalized_interfaces, interface_total, interfaces_truncated,
		MAX_INTERFACES, MAX_PROVENANCE);
	return { mac: value.mac == null ? null : mac(value.mac), interfaces: normalized_interfaces,
		interface_total, interfaces_truncated,
		timestamp: integer(value.timestamp, 0, MAX_TIMESTAMP) };
};
function policy_active(app, policy, timestamp) {
	if (policy.schedule == null) return true;
	if (type(app?.timezones?.resolve) != 'function') invalid('INTERNAL');
	let capability = app.timezones.resolve(policy.schedule.timezone, timestamp);
	return schedule.active(policy.schedule, timestamp, capability);
};
function safe_action(app, action, policy_id) {
	let guarded = guard(app), available = app.core_available === true;
	if (action == 'block') return { action, safety: 'block' };
	if (action == 'direct' && guarded !== false)
		return available ? { action: 'proxy', safety: 'guard_safe_override' } :
			{ action: 'block', safety: 'guard_core_unavailable' };
	if (action == 'proxy' && !available)
		return { action: 'block', safety: 'proxy_unavailable' };
	if (action == 'inherit' && guarded !== false)
		return available ? { action: 'proxy', safety: 'guard_default' } :
			{ action: 'block', safety: 'guard_core_unavailable' };
	return { action, safety: 'ordinary' };
};
export function effective(app, input) {
	let wanted = subject(input);
	if (wanted.interfaces_truncated) return { action: 'block', policy_id: null, scope: null,
		safety: 'interface_evidence_truncated',
		reason: redact.text('interface evidence truncated; conservative block') };
	let policies = policy_list(app), active = [], selected = null;
	for (let scope in [ 'device', 'interface', 'global' ]) {
		for (let policy in policies) {
			if (policy.scope != scope || (scope == 'device' && policy.mac != wanted.mac) ||
			    (scope == 'interface' && !has(wanted.interfaces, policy.interface)) ||
			    !policy_active(app, policy, wanted.timestamp)) continue;
			push(active, policy);
		}
	}
	for (let scope in [ 'device', 'interface', 'global' ]) {
		for (let policy in active)
			if (policy.scope == scope && policy.action == 'block') { selected = policy; break; }
		if (selected != null) break;
	}
	if (selected == null)
		for (let scope in [ 'device', 'interface', 'global' ]) {
			for (let policy in active) {
				if (policy.scope != scope || policy.action == 'inherit') continue;
				if (selected == null || (scope == 'interface' &&
				    ((policy.action == 'proxy' ? 2 : 1) > (selected.action == 'proxy' ? 2 : 1) ||
				     (policy.action == selected.action && policy.id < selected.id)))) selected = policy;
			}
			if (selected != null) break;
		}
	let safety = safe_action(app, selected?.action ?? 'inherit', selected?.id);
	return { action: safety.action, policy_id: selected?.id ?? null,
		scope: selected?.scope ?? null, safety: safety.safety,
		reason: redact.text(selected == null ? 'no active policy' : 'active ' + selected.scope + ' policy') };
};

function identity_id(value) {
	if (type(value) != 'string' || !length(value) || length(value) > 80) invalid();
	if (match(value, /^mac:/)) {
		let normalized = mac(substr(value, 4));
		if (value != 'mac:' + normalized) invalid();
		return value;
	}
	if (!match(value, /^ephemeral:(0|[1-9][0-9]*):[1-9][0-9]*:(dhcp|neighbor)$/)) invalid();
	let fields = split(value, ':');
	integer(int(fields[1]), 0, MAX_TIMESTAMP);
	integer(int(fields[2]), 1, MAX_DEVICES);
	return value;
};
function retained_identity(evidence, total, truncated, identity) {
	if (!truncated && !has(evidence, identity)) invalid();
	if (truncated && identity <= evidence[length(evidence) - 1] && !has(evidence, identity)) invalid();
};
compile_device = function(value, timestamp) {
	exact(value, { identity: true, mac: true, hostname: true, last_seen: true, sources: true,
		interfaces: true, interface_total: true, interfaces_truncated: true,
		conflicts: true, addresses: true });
	exact(value.identity, { kind: true, value: true, confidence: true,
		persistent_policy_eligible: true, reason: true });
	if (type(value.sources) != 'array' || length(value.sources) > 2 ||
	    type(value.interfaces) != 'array' || length(value.interfaces) > MAX_INTERFACES ||
	    type(value.conflicts) != 'array' || length(value.conflicts) > MAX_CONFLICTS ||
	    type(value.addresses) != 'array' || !length(value.addresses) ||
	    length(value.addresses) > MAX_ADDRESSES) invalid();
	if (!has([ 'mac', 'ip' ], value.identity.kind) ||
	    !has([ 'high', 'low', 'ephemeral' ], value.identity.confidence) ||
	    type(value.identity.persistent_policy_eligible) != 'bool' ||
	    !has([ 'stable_mac', 'locally_administered_mac', 'mac_unavailable' ],
		value.identity.reason)) invalid();
	let normalized_mac = null, normalized_identity;
	if (value.identity.kind == 'mac') {
		let normalized = mac(value.mac);
		if (value.identity.value != normalized ||
		    (value.identity.confidence == 'high') != !local_mac(normalized) ||
		    value.identity.persistent_policy_eligible != !local_mac(normalized) ||
		    value.identity.reason != (local_mac(normalized) ?
			'locally_administered_mac' : 'stable_mac')) invalid();
		normalized_mac = normalized;
	}
	else {
		if (value.mac != null || value.identity.confidence != 'ephemeral' ||
		    value.identity.persistent_policy_eligible || value.identity.reason != 'mac_unavailable' ||
		    identity_id(value.identity.value) != value.identity.value) invalid();
	}
	normalized_identity = { kind: value.identity.kind, value: value.identity.value,
		confidence: value.identity.confidence,
		persistent_policy_eligible: value.identity.persistent_policy_eligible,
		reason: value.identity.reason };
	let normalized_hostname = value.hostname == null ? null : hostname(value.hostname);
	if (value.hostname != null && normalized_hostname != value.hostname) invalid();
	let last_seen = integer(value.last_seen, 0, timestamp);
	strict_sorted_strings(value.sources, 2, (source) => {
		if (!has([ 'dhcp', 'neighbor' ], source)) invalid();
	});
	strict_sorted_strings(value.interfaces, MAX_INTERFACES, interface_name);
	bounded_counter(value.interfaces, value.interface_total, value.interfaces_truncated,
		MAX_INTERFACES, MAX_PROVENANCE);
	if (has(value.sources, 'neighbor') != (length(value.interfaces) > 0)) invalid();
	let sources = [], interfaces = [];
	for (let source in value.sources) push(sources, source);
	for (let iface in value.interfaces) push(interfaces, iface);
	let addresses = [], newest_address = null;
	for (let raw_address in value.addresses) {
		let item = validate_address_record(raw_address, timestamp);
		if (!has(sources, item.source) || item.last_seen > last_seen ||
		    item.interface_total > value.interface_total) invalid();
		if (item.source == 'neighbor' && !value.interfaces_truncated)
			for (let iface in item.interfaces) if (!has(interfaces, iface)) invalid();
		if (item.interfaces_truncated && !value.interfaces_truncated) invalid();
		newest_address = newest_address == null ? item.last_seen : max(newest_address, item.last_seen);
		push(addresses, item);
	}
	if (newest_address != last_seen) invalid();
	if (value.identity.kind == 'ip') {
		let fields = split(value.identity.value, ':');
		if (length(addresses) != 1 || length(sources) != 1 || sources[0] != fields[3] ||
		    last_seen != int(fields[1])) invalid();
	}
	let identity_subject = value.identity.kind == 'mac' ? 'mac:' + normalized_mac : value.identity.value;
	let conflicts = [];
	let prior_conflict = null;
	for (let raw_conflict in value.conflicts) {
		exact(raw_conflict, { reason: true, subject: true, evidence: true, total: true, truncated: true });
		if (!has([ 'hostname_changed', 'duplicate_hostname', 'shared_address', 'address_interfaces' ],
		    raw_conflict.reason) || type(raw_conflict.subject) != 'string' ||
		    !length(raw_conflict.subject) || length(raw_conflict.subject) > 128) invalid();
		strict_sorted_strings(raw_conflict.evidence, MAX_EVIDENCE, (evidence) => {
			if (type(evidence) != 'string' || !length(evidence) || length(evidence) > 128) invalid();
		});
		bounded_counter(raw_conflict.evidence, raw_conflict.total, raw_conflict.truncated,
			MAX_EVIDENCE, MAX_PROVENANCE);
		if (raw_conflict.total < 2) invalid();
		if (raw_conflict.reason == 'hostname_changed') {
			if (raw_conflict.subject != identity_subject || normalized_hostname == null ||
			    !has(sources, 'dhcp')) invalid();
			for (let evidence in raw_conflict.evidence) hostname(evidence);
			if (raw_conflict.evidence[0] != normalized_hostname) invalid();
		}
		else if (raw_conflict.reason == 'duplicate_hostname') {
			if (normalized_hostname == null || hostname(raw_conflict.subject) != normalized_hostname ||
			    !has(sources, 'dhcp')) invalid();
			if (raw_conflict.total > MAX_DEVICES) invalid();
			for (let evidence in raw_conflict.evidence) identity_id(evidence);
			retained_identity(raw_conflict.evidence, raw_conflict.total,
				raw_conflict.truncated, identity_subject);
		}
		else if (raw_conflict.reason == 'address_interfaces') {
			for (let evidence in raw_conflict.evidence) interface_name(evidence);
			let matched = null;
			for (let item in addresses) if (item.address == raw_conflict.subject &&
			    item.source == 'neighbor') { matched = item; break; }
			if (matched == null || raw_conflict.total != matched.interface_total ||
			    raw_conflict.truncated != matched.interfaces_truncated ||
			    !same_strings(raw_conflict.evidence, matched.interfaces)) invalid();
		}
		else {
			let at = index(raw_conflict.subject, ':'), family = substr(raw_conflict.subject, 0, at);
			let parsed = at < 1 ? null : address(substr(raw_conflict.subject, at + 1), null, 'shared');
			if (parsed == null || family != parsed.family ||
			    raw_conflict.subject != parsed.family + ':' + parsed.address) invalid();
			let matched = false;
			for (let item in addresses) if (item.current && item.family == parsed.family &&
			    item.address == parsed.address) matched = true;
			if (!matched) invalid();
			if (raw_conflict.total > MAX_DEVICES) invalid();
			for (let evidence in raw_conflict.evidence) identity_id(evidence);
			retained_identity(raw_conflict.evidence, raw_conflict.total,
				raw_conflict.truncated, identity_subject);
		}
		let conflict_key = raw_conflict.reason + ':' + raw_conflict.subject;
		if (prior_conflict != null && conflict_key <= prior_conflict) invalid();
		prior_conflict = conflict_key;
		let evidence = []; for (let item in raw_conflict.evidence) push(evidence, item);
		push(conflicts, { reason: raw_conflict.reason, subject: raw_conflict.subject,
			evidence, total: raw_conflict.total, truncated: raw_conflict.truncated });
	}
	for (let item in addresses) if (item.source == 'neighbor' && item.interface_total > 1) {
		let found = false;
		for (let item_conflict in conflicts) if (item_conflict.reason == 'address_interfaces' &&
		    item_conflict.subject == item.address) found = true;
		if (!found) invalid();
	}
	return { identity: normalized_identity, mac: normalized_mac, hostname: normalized_hostname,
		last_seen, sources, interfaces, interface_total: value.interface_total,
		interfaces_truncated: value.interfaces_truncated, conflicts, addresses };
};
function rank(decision) {
	if (decision.action == 'block') return 4;
	if (decision.safety == 'guard_safe_override' || decision.safety == 'guard_default') return 3;
	if (decision.action == 'proxy') return 2;
	if (decision.action == 'direct') return 1;
	return 0;
};
function scope_rank(scope) {
	return scope == 'device' ? 3 : (scope == 'interface' ? 2 : (scope == 'global' ? 1 : 0));
};
function candidate_before(left, right) {
	let left_rank = rank(left.decision), right_rank = rank(right.decision);
	if (left_rank != right_rank) return left_rank > right_rank;
	let left_scope = scope_rank(left.decision.scope), right_scope = scope_rank(right.decision.scope);
	if (left_scope != right_scope) return left_scope > right_scope;
	let left_policy = left.decision.policy_id ?? '~', right_policy = right.decision.policy_id ?? '~';
	if (left_policy != right_policy) return left_policy < right_policy;
	return left.identity < right.identity;
};
function safety_conflict(summary) {
	return summary.conflict || !has([ 'ordinary', 'block' ], summary.safety);
};
export function compile_sets(app, input) {
	exact(input, { timestamp: true, devices: true });
	let timestamp = integer(input.timestamp, 0, MAX_TIMESTAMP);
	if (type(input.devices) != 'array' || length(input.devices) > MAX_DEVICES) invalid();
	let observations = {};
	for (let raw in input.devices) {
		let device = compile_device(raw, timestamp);
		for (let item in device.addresses) {
			validate_address_record(item, timestamp);
			if (!item.current) continue;
			let key = item.family + ':' + item.address;
			observations[key] ??= {};
			let identity = device.identity.value;
			observations[key][identity] ??= { identity, mac: device.mac, interfaces: [],
				interface_total: 0, interfaces_truncated: false };
			let observation = observations[key][identity];
			for (let iface in item.interfaces)
				add_unique(observation.interfaces, iface);
			for (let iface in device.interfaces)
				add_unique(observation.interfaces, iface);
			observation.interface_total = max(observation.interface_total,
				max(item.interface_total, device.interface_total));
			observation.interfaces_truncated = observation.interfaces_truncated ||
				item.interfaces_truncated || device.interfaces_truncated;
		}
	}
	let result = { ipv4: { block: [], proxy: [], direct: [] },
		ipv6: { block: [], proxy: [], direct: [] }, reasoning: [],
		reasoning_total: 0, reasoning_truncated: false,
		safety_conflicts_total: 0, safety_conflicts_truncated: false };
	let summaries = [];
	let observation_keys = sort(keys(observations));
	for (let key in observation_keys) {
		let identity_keys = sort(keys(observations[key])), values = [];
		for (let identity in identity_keys) {
			let observation = observations[key][identity];
			observation.interfaces = sort(observation.interfaces);
			if (length(observation.interfaces) > MAX_INTERFACES) {
				observation.interface_total = max(observation.interface_total,
					length(observation.interfaces));
				observation.interfaces_truncated = true;
				let bounded = [];
				for (let at = 0; at < MAX_INTERFACES; at++) push(bounded, observation.interfaces[at]);
				observation.interfaces = bounded;
			}
			if (observation.interfaces_truncated)
				observation.interface_total = max(observation.interface_total, MAX_INTERFACES + 1);
			else observation.interface_total = length(observation.interfaces);
			push(values, { identity, decision: effective(app, { mac: observation.mac,
				interfaces: observation.interfaces, interface_total: observation.interface_total,
				interfaces_truncated: observation.interfaces_truncated, timestamp }) });
		}
		let winner = values[0];
		for (let candidate in values) if (candidate_before(candidate, winner)) winner = candidate;
		let at = index(key, ':'), family = substr(key, 0, at), ip = substr(key, at + 1);
		if (winner.decision.action != 'inherit') push(result[family][winner.decision.action], ip);
		push(summaries, {
			address: ip, family, action: winner.decision.action, policy_id: winner.decision.policy_id,
			safety: winner.decision.safety, conflict: length(values) > 1,
			identities: identity_keys
		});
	}
	for (let family in [ 'ipv4', 'ipv6' ])
		for (let action in [ 'block', 'proxy', 'direct' ]) result[family][action] = sort(result[family][action]);
	summaries = sort(summaries, (a, b) => {
		let a_safety = safety_conflict(a), b_safety = safety_conflict(b);
		if (a_safety != b_safety) return a_safety ? -1 : 1;
		let a_key = a.family + ':' + a.address, b_key = b.family + ':' + b.address;
		return a_key < b_key ? -1 : (a_key > b_key ? 1 : 0);
	});
	result.reasoning_total = length(summaries);
	result.reasoning_truncated = result.reasoning_total > MAX_REASONING;
	for (let summary in summaries) if (safety_conflict(summary)) result.safety_conflicts_total++;
	let retained_safety = 0;
	for (let at = 0; at < min(length(summaries), MAX_REASONING); at++) {
		push(result.reasoning, summaries[at]);
		if (safety_conflict(summaries[at])) retained_safety++;
	}
	result.safety_conflicts_truncated = retained_safety < result.safety_conflicts_total;
	return result;
};
