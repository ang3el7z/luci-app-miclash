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
const MAX_LINES = 512;
const MAX_LINE = 512;
const MAX_DEVICES = 256;
const MAX_ADDRESSES = 32;
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
function add_unique(values, value) { if (value != null && !has(values, value)) push(values, value); };
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
	if (type(value) != 'string' || !match(value, /^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$/))
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
		return { mac: null, reason: 'invalid_mac' };
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
	let groups = ipv6_groups(value);
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
function address(value, code) {
	let v4 = ipv4(value); if (v4 != null) return { address: v4, family: 'ipv4' };
	let v6 = ipv6(value); if (v6 != null) return { address: v6, family: 'ipv6' };
	invalid(code);
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
			sources: [], interfaces: [], conflicts: []
		};
	}
	if (host != null && item.hostname == null) item.hostname = host;
	else if (host != null && item.hostname != host)
		push(item.conflicts, { reason: 'hostname_changed', evidence: [ item.hostname, host ] });
	return item;
};
function add_observation(cache, normalized_mac, ip, host, source, iface, seen, current, identity_reason) {
	let parsed = address(ip, 'INVALID_RESPONSE');
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
			last_seen: seen, source, interface: iface };
		push(item.addresses, existing);
	}
	existing.last_seen = max(existing.last_seen, seen);
	existing.current = existing.current || current;
	if (source == 'neighbor' || existing.source != 'neighbor') existing.source = source;
	if (iface != null) existing.interface = iface;
	item.last_seen = max(item.last_seen, seen);
	add_unique(item.sources, source); add_unique(item.interfaces, iface);
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
		let parsed = address(value.dst, 'INVALID_RESPONSE');
		if (parsed.family != family) invalid('INVALID_RESPONSE');
		let iface = interface_name(value.dev, 'INVALID_RESPONSE');
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
	for (let host, identities in hosts) if (length(identities) > 1)
		for (let identity in identities)
			push(devices[identity].conflicts, { reason: 'duplicate_hostname', evidence: [ host, ...identities ] });
	for (let ip, identities in addresses) if (length(identities) > 1)
		for (let identity in identities)
			push(devices[identity].conflicts, { reason: 'shared_address', evidence: [ ip, ...identities ] });
};

export function discover(app) {
	if (type(app?.clock?.now) != 'function' || type(app?.observers?.dhcp_leases) != 'function' ||
	    type(app?.observers?.neighbors) != 'function') invalid();
	let now_ms = app.clock.now();
	if (type(now_ms) != 'int' || now_ms < 0) invalid('CORRUPT_STATE');
	let now = int(now_ms / 1000), cache = app.device_cache;
	if (now > MAX_TIMESTAMP) invalid('CORRUPT_STATE');
	if (type(cache) != 'object' || type(cache) == 'array') invalid();
	if (cache.last_now != null && now < cache.last_now) invalid('CORRUPT_STATE');
	cache.last_now = now; cache.devices ??= {}; cache.ephemeral_sequence = 0;
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
	let output = []; for (let key, item in cache.devices) push(output, clone(item));
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
	    !match(value.timezone, /^[A-Za-z][A-Za-z0-9_+.-]*(\/[A-Za-z0-9_+.-]+)+$/)) invalid();
	let seen = {};
	for (let day in value.days) { integer(day, 1, 7); if (seen[day]) invalid(); seen[day] = true; }
	return clone(value);
};
function policy_id(value) {
	if (type(value) != 'string' || length(value) > 64 || !match(value, /^dp-[0-9]+-[0-9a-f]{16}$/)) invalid();
	return value;
};
function normalized_policy(value) {
	let allowed = { id: true, expected_revision: true, scope: true, mac: true,
		interface: true, action: true, schedule: true };
	exact(value, allowed, { scope: true, action: true });
	if (value.id != null) policy_id(value.id);
	if ((value.id == null) != (value.expected_revision == null)) invalid();
	if (value.expected_revision != null) integer(value.expected_revision, 1, 2147483647);
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
	for (let name in section) if (!exists(allowed, name)) invalid('CORRUPT_STATE');
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
	for (let id, section in config) {
		if (section?.['.type'] != POLICY_TYPE) continue;
		try { policy_id(id); } catch (error) { invalid('CORRUPT_STATE'); }
		let item = persisted(id, section);
		if (item.scope == 'device') { if (macs[item.mac]) invalid('CORRUPT_STATE'); macs[item.mac] = true; }
		if (item.scope == 'interface') { if (interfaces[item.interface]) invalid('CORRUPT_STATE'); interfaces[item.interface] = true; }
		if (item.scope == 'global') { if (global != null) invalid('CORRUPT_STATE'); global = item.id; }
		push(result, item);
	}
	return sort(result, (a, b) => a.id < b.id ? -1 : (a.id > b.id ? 1 : 0));
};
function journal(app, document) { storage.write_json(app, JOURNAL, document, 0o600); };
function journal_state(app, current, recover) {
	let value;
	try { value = storage.read_json(app, JOURNAL); }
	catch (error) {
		if ((error?.code ?? error?.message) == 'NOT_FOUND') return;
		invalid('CORRUPT_STATE');
	}
	if (type(value) != 'object' || type(value) == 'array' || value.version != 1 ||
	    value.owner != 'miclash-device-policies' ||
	    (value.state != 'stable' && value.state != 'prepared'))
		invalid('CORRUPT_STATE');
	let allowed = value.state == 'stable'
		? { version: true, owner: true, state: true, policies: true }
		: { version: true, owner: true, state: true, before: true, after: true };
	for (let name in value) if (!exists(allowed, name)) invalid('CORRUPT_STATE');
	for (let name in allowed) if (!exists(value, name)) invalid('CORRUPT_STATE');
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
	let values = { '.type': POLICY_TYPE, revision: sprintf('%d', item.revision), scope: item.scope,
		action: item.action, schedule: item.schedule == null ? '' : sprintf('%J', item.schedule) };
	if (item.mac != null) values.mac = item.mac;
	if (item.interface != null) values.interface = item.interface;
	for (let name, value in values) if (uci.set(CONFIG, item.id, name, value) !== true) invalid('INTERNAL');
};
function delete_section(uci, id) {
	for (let name in [ 'mac', 'interface', 'schedule', 'action', 'scope', 'revision', '.type' ])
		if (uci.get(CONFIG, id, name) != null && uci.delete(CONFIG, id, name) !== true) invalid('INTERNAL');
};

export function policy_list(app) {
	let result = list_from(cursor(app));
	journal_state(app, result, false);
	return clone(result);
};
export function policy_set(app, policy) {
	let wanted = normalized_policy(policy);
	if (wanted.action == 'direct' && guard(app) !== false) invalid('VALIDATION_FAILED');
	return with_lock(app, { barrier: 'normal', wait_ms: 0 }, () => {
		let uci = cursor(app);
		for (let name in uci.changes(CONFIG) ?? {}) invalid('BUSY');
		if (wanted.action == 'direct' && guard_cursor(uci) !== false) invalid('VALIDATION_FAILED');
		let before = list_from(uci); journal_state(app, before, true);
		let existing = null;
		for (let item in before) if (item.id == wanted.id) existing = item;
		if (wanted.id != null && (existing == null || existing.revision != wanted.expected_revision)) invalid('BUSY');
		if (wanted.id == null) {
			let now = app.clock.now(), occupied = {};
			if (type(now) != 'int' || now < 0 || now > 9007199254740991) invalid('INTERNAL');
			for (let item in before) occupied[item.id] = true;
			for (let attempt = 0; attempt < 16; attempt++) {
				let suffix = app.random.hex(8);
				if (!match(suffix, /^[0-9a-f]{16}$/)) invalid('INTERNAL');
				let candidate = 'dp-' + now + '-' + suffix;
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
		journal(app, { version: 1, owner: 'miclash-device-policies', state: 'prepared', before, after });
		if (existing != null) delete_section(uci, existing.id);
		write_section(uci, result);
		if (uci.commit(CONFIG) !== true) { try { uci.revert(CONFIG); } catch (error) {} invalid('INTERNAL'); }
		journal(app, { version: 1, owner: 'miclash-device-policies', state: 'stable', policies: after });
		return clone(result);
	});
};
export function policy_delete(app, id, expected_revision) {
	policy_id(id); integer(expected_revision, 1, 2147483647);
	return with_lock(app, { barrier: 'normal', wait_ms: 0 }, () => {
		let uci = cursor(app); for (let name in uci.changes(CONFIG) ?? {}) invalid('BUSY');
		let before = list_from(uci); journal_state(app, before, true);
		let existing = null; for (let item in before) if (item.id == id) existing = item;
		if (existing == null) invalid('NOT_FOUND');
		if (existing.revision != expected_revision) invalid('BUSY');
		let after = []; for (let item in before) if (item.id != id) push(after, item);
		journal(app, { version: 1, owner: 'miclash-device-policies', state: 'prepared', before, after });
		delete_section(uci, id);
		if (uci.commit(CONFIG) !== true) { try { uci.revert(CONFIG); } catch (error) {} invalid('INTERNAL'); }
		journal(app, { version: 1, owner: 'miclash-device-policies', state: 'stable', policies: after });
		return true;
	});
};

function subject(value) {
	exact(value, { mac: true, interface: true, timestamp: true }, { timestamp: true });
	return { mac: value.mac == null ? null : mac(value.mac),
		interface: value.interface == null ? null : interface_name(value.interface),
		timestamp: integer(value.timestamp, 0, MAX_TIMESTAMP) };
};
function policy_active(app, policy, timestamp) {
	if (policy.schedule == null) return true;
	if (type(app?.timezones?.resolve) != 'function') invalid('INTERNAL');
	let capability = app.timezones.resolve(policy.schedule.timezone);
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
	let wanted = subject(input), policies = policy_list(app), selected = null;
	for (let scope in [ 'device', 'interface', 'global' ]) {
		for (let policy in policies) {
			if (policy.scope != scope || (scope == 'device' && policy.mac != wanted.mac) ||
			    (scope == 'interface' && policy.interface != wanted.interface) ||
			    !policy_active(app, policy, wanted.timestamp) || policy.action == 'inherit') continue;
			selected = policy; break;
		}
		if (selected != null) break;
	}
	let safety = safe_action(app, selected?.action ?? 'inherit', selected?.id);
	return { action: safety.action, policy_id: selected?.id ?? null,
		scope: selected?.scope ?? null, safety: safety.safety,
		reason: redact.text(selected == null ? 'no active policy' : 'active ' + selected.scope + ' policy') };
};

function bounded_strings(values, maximum, allowed) {
	if (type(values) != 'array' || length(values) > maximum) invalid();
	let seen = {};
	for (let value in values) {
		if (type(value) != 'string' || !length(value) || length(value) > 128 ||
		    (allowed != null && !has(allowed, value)) || seen[value]) invalid();
		seen[value] = true;
	}
	return values;
};
function compile_device(value, timestamp) {
	exact(value, { identity: true, mac: true, hostname: true, last_seen: true, sources: true,
		interfaces: true, conflicts: true, addresses: true });
	exact(value.identity, { kind: true, value: true, confidence: true,
		persistent_policy_eligible: true, reason: true });
	if (!has([ 'mac', 'ip' ], value.identity.kind) ||
	    !has([ 'high', 'low', 'ephemeral' ], value.identity.confidence) ||
	    type(value.identity.persistent_policy_eligible) != 'bool' ||
	    !has([ 'stable_mac', 'locally_administered_mac', 'mac_unavailable', 'invalid_mac' ],
		value.identity.reason)) invalid();
	if (value.identity.kind == 'mac') {
		let normalized = mac(value.mac);
		if (value.identity.value != normalized ||
		    (value.identity.confidence == 'high') != !local_mac(normalized) ||
		    value.identity.persistent_policy_eligible != !local_mac(normalized)) invalid();
	}
	else {
		if (value.mac != null || value.identity.confidence != 'ephemeral' ||
		    value.identity.persistent_policy_eligible || type(value.identity.value) != 'string' ||
		    !match(value.identity.value, /^ephemeral:[0-9]+:[1-9][0-9]*:(dhcp|neighbor)$/)) invalid();
	}
	if (value.hostname != null) hostname(value.hostname);
	integer(value.last_seen, 0, timestamp);
	bounded_strings(value.sources, 2, [ 'dhcp', 'neighbor' ]);
	if (type(value.interfaces) != 'array' || length(value.interfaces) > 16) invalid();
	let seen_interfaces = {};
	for (let iface in value.interfaces) {
		interface_name(iface); if (seen_interfaces[iface]) invalid(); seen_interfaces[iface] = true;
	}
	if (type(value.conflicts) != 'array' || length(value.conflicts) > 64) invalid();
	for (let conflict in value.conflicts) {
		exact(conflict, { reason: true, evidence: true });
		if (!has([ 'hostname_changed', 'duplicate_hostname', 'shared_address' ], conflict.reason)) invalid();
		bounded_strings(conflict.evidence, 16, null);
	}
	if (type(value.addresses) != 'array' || length(value.addresses) > MAX_ADDRESSES) invalid();
	return value;
};
function rank(decision) {
	if (decision.action == 'block') return 4;
	if (decision.safety == 'guard_safe_override' || decision.safety == 'guard_default') return 3;
	if (decision.action == 'proxy') return 2;
	if (decision.action == 'direct') return 1;
	return 0;
};
export function compile_sets(app, input) {
	exact(input, { timestamp: true, devices: true });
	let timestamp = integer(input.timestamp, 0, MAX_TIMESTAMP);
	if (type(input.devices) != 'array' || length(input.devices) > MAX_DEVICES) invalid();
	let candidates = {}, reasoning = [];
	for (let raw in input.devices) {
		let device = compile_device(raw, timestamp);
		for (let item in device.addresses) {
			exact(item, { address: true, family: true, current: true, last_seen: true, source: true, interface: true });
			if (type(item.current) != 'bool' || !has([ 'dhcp', 'neighbor' ], item.source)) invalid();
			integer(item.last_seen, 0, timestamp);
			if (item.interface != null) interface_name(item.interface);
			let parsed = address(item.address);
			if (parsed.family != item.family) invalid();
			if (!item.current) continue;
			let decision = effective(app, { mac: device.mac, interface: item.interface, timestamp });
			let key = parsed.family + ':' + parsed.address;
			candidates[key] ??= [];
			push(candidates[key], { device: device.identity?.value ?? 'ephemeral', decision });
		}
	}
	let result = { ipv4: { block: [], proxy: [], direct: [] },
		ipv6: { block: [], proxy: [], direct: [] }, reasoning: [] };
	for (let key, values in candidates) {
		let winner = values[0];
		for (let candidate in values) if (rank(candidate.decision) > rank(winner.decision)) winner = candidate;
		let at = index(key, ':'), family = substr(key, 0, at), ip = substr(key, at + 1);
		if (winner.decision.action != 'inherit') push(result[family][winner.decision.action], ip);
		if (length(result.reasoning) < 1024) push(result.reasoning, {
			address: ip, family, action: winner.decision.action, policy_id: winner.decision.policy_id,
			safety: winner.decision.safety, conflict: length(values) > 1,
			identities: map(values, (item) => item.device)
		});
	}
	for (let family in [ 'ipv4', 'ipv6' ])
		for (let action in [ 'block', 'proxy', 'direct' ]) result[family][action] = sort(result[family][action]);
	result.reasoning = sort(result.reasoning, (a, b) => a.family + ':' + a.address < b.family + ':' + b.address ? -1 : 1);
	return result;
};
