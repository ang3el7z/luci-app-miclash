import { fail } from 'miclash.errors';

const EVENTS = {
	boot: true,
	daemon_crash: true,
	rules_rebuild: true,
	mihomo_restart: true,
	explicit_disable: true,
	explicit_enable: true,
	package_upgrade: true,
	wan_change: true
};

const BOOTSTRAP_TABLES = [ 'miclash_guard_bootstrap_v1', 'miclash_guard_emergency_v1' ];
const BOOTSTRAP_CHAIN = 'protected_direct_drop_v1';

function includes(values, wanted) {
	for (let value in values)
		if (value == wanted)
			return true;
	return false;
};

function normalize_mac(value) {
	if (type(value) != 'string') return null;
	value = lc(value);
	return match(value, /^[0-9a-f]{2}(:[0-9a-f]{2}){5}$/) ? value : null;
};

function direct_macs(values) {
	if (values == null) return [];
	if (type(values) != 'array' || length(values) > 512) fail('INVALID_ARGUMENT');
	let result = [], seen = {};
	for (let value in values) {
		let normalized = normalize_mac(value);
		if (normalized == null) fail('INVALID_ARGUMENT');
		if (!seen[normalized]) { seen[normalized] = true; push(result, normalized); }
	}
	return sort(result);
};

function reserved_table(table) {
	return type(table) == 'string' && includes(BOOTSTRAP_TABLES, table);
};

function parse_json(text) {
	if (type(text) != 'string')
		return null;
	try { return json(text); }
	catch (error) { return null; }
};

function exact_member(value, name) {
	return type(value) == 'object' && length(keys(value)) == 1 && exists(value, name);
};

function verdict(value, name) {
	return exact_member(value, name) && value[name] == null;
};

function match_expression(value) {
	if (!exact_member(value, 'match') || type(value.match) != 'object')
		return null;
	return value.match;
};

function meta_match(value, key, right) {
	let matched = match_expression(value);
	return matched?.op == '==' && matched.right == right &&
		matched.left?.meta?.key == key && length(keys(matched.left)) == 1 &&
		length(keys(matched.left.meta)) == 1;
};

function payload_match(value, protocol, field, right) {
	let matched = match_expression(value);
	return matched?.op == '==' && matched.right == right &&
		matched.left?.payload?.protocol == protocol &&
		matched.left.payload.field == field && length(keys(matched.left)) == 1 &&
		length(keys(matched.left.payload)) == 2;
};

function prefix_key(value) {
	let prefix = value?.prefix;
	if (!exact_member(value, 'prefix') || type(prefix?.addr) != 'string' ||
	    type(prefix?.len) != 'int' || length(keys(prefix)) != 2)
		return null;
	return prefix.addr + '/' + prefix.len;
};

function exact_prefix_set(values, expected) {
	if (type(values) != 'array' || length(values) != length(keys(expected)))
		return false;
	let seen = {};
	for (let value in values) {
		let key = prefix_key(value);
		if (key == null || !expected[key] || seen[key])
			return false;
		seen[key] = true;
	}
	return length(keys(seen)) == length(keys(expected));
};

function local_destination_match(value, family) {
	let matched = match_expression(value);
	let protocol = family == 'ipv4' ? 'ip' : 'ip6';
	if (matched?.op != '==' || matched.left?.payload?.protocol != protocol ||
	    matched.left.payload.field != 'daddr' || length(keys(matched.left)) != 1 ||
	    length(keys(matched.left.payload)) != 2)
		return false;
	let values = matched.right?.set;
	if (family == 'ipv4')
		return exact_prefix_set(values, {
			'0.0.0.0/8': true, '10.0.0.0/8': true, '100.64.0.0/10': true,
			'127.0.0.0/8': true, '169.254.0.0/16': true, '172.16.0.0/12': true,
			'192.168.0.0/16': true, '224.0.0.0/3': true
		}) || exact_prefix_set(values, {
			'0.0.0.0/8': true, '10.0.0.0/8': true, '100.64.0.0/10': true,
			'127.0.0.0/8': true, '169.254.0.0/16': true, '172.16.0.0/12': true,
			'192.168.0.0/16': true, '224.0.0.0/4': true, '240.0.0.0/4': true
		});
	return exact_prefix_set(values, {
		'::/127': true, 'fc00::/7': true, 'fe80::/10': true, 'ff00::/8': true
	}) || exact_prefix_set(values, {
		'::/128': true, '::1/128': true, 'fc00::/7': true,
		'fe80::/10': true, 'ff00::/8': true
	});
};

function safe_accept(rule) {
	let expr = rule?.expr;
	if (type(expr) != 'array' || !length(expr) || !verdict(expr[length(expr) - 1], 'accept'))
		return null;
	if (length(expr) == 2 && meta_match(expr[0], 'iifname', 'clash-tun'))
		return 'tun_in';
	if (length(expr) == 2 && meta_match(expr[0], 'oifname', 'clash-tun'))
		return 'tun_out';
	let status = length(expr) == 2 ? match_expression(expr[0]) : null;
	if (status?.op == 'in' && status.right == 'dnat' &&
	    status.left?.ct?.key == 'status' && length(keys(status.left)) == 1 &&
	    length(keys(status.left.ct)) == 1)
		return 'dnat';
	if (length(expr) == 3 && payload_match(expr[0], 'udp', 'sport', 67) &&
	    payload_match(expr[1], 'udp', 'dport', 68))
		return 'dhcp_reply';
	if (length(expr) == 3 && payload_match(expr[0], 'udp', 'sport', 68) &&
	    payload_match(expr[1], 'udp', 'dport', 67))
		return 'dhcp_request';
	if (length(expr) == 2 && local_destination_match(expr[0], 'ipv4'))
		return 'local4';
	if (length(expr) == 2 && local_destination_match(expr[0], 'ipv6'))
		return 'local6';
	return null;
};

function direct_accept(rule) {
	let expr = rule?.expr;
	if (type(expr) != 'array' || length(expr) != 2 || !verdict(expr[1], 'accept'))
		return null;
	let matched = match_expression(expr[0]);
	if (matched?.op != '==' || matched.left?.payload?.protocol != 'ether' ||
	    matched.left.payload.field != 'saddr' || length(keys(matched.left)) != 1 ||
	    length(keys(matched.left.payload)) != 2)
		return null;
	return normalize_mac(matched.right);
};

function terminal_drop(rule, family) {
	let expr = rule?.expr;
	return type(expr) == 'array' && length(expr) == 2 &&
		meta_match(expr[0], 'nfproto', family) && verdict(expr[1], 'drop');
};

export function bootstrap_tables() {
	return [ ...BOOTSTRAP_TABLES ];
};

export function verify_nft_table(text, table, expected_direct_macs) {
	if (!reserved_table(table))
		return false;
	let wanted;
	try { wanted = direct_macs(expected_direct_macs); }
	catch (error) { return false; }
	let document = parse_json(text);
	if (type(document) != 'object' || type(document.nftables) != 'array')
		return false;
	let table_count = 0, chain_count = 0, rules = [];
	for (let entry in document.nftables) {
		if (exact_member(entry, 'metainfo'))
			continue;
		if (exact_member(entry, 'table')) {
			if (entry.table?.family != 'inet' || entry.table.name != table)
				return false;
			table_count++;
		}
		else if (exact_member(entry, 'chain')) {
			let chain = entry.chain;
			if (chain?.family != 'inet' || chain.table != table ||
			    chain.name != BOOTSTRAP_CHAIN || chain.type != 'filter' ||
			    chain.hook != 'forward' || chain.prio !== -310 || chain.policy != 'accept')
				return false;
			chain_count++;
		}
		else if (exact_member(entry, 'rule')) {
			let rule = entry.rule;
			if (rule?.family != 'inet' || rule.table != table || rule.chain != BOOTSTRAP_CHAIN)
				return false;
			push(rules, rule);
		}
		else
			return false;
	}
	if (table_count != 1 || chain_count != 1 || length(rules) != 9 + length(wanted))
		return false;
	let categories = {};
	for (let i = 0; i < 7; i++) {
		let category = safe_accept(rules[i]);
		if (category == null || categories[category])
			return false;
		categories[category] = true;
	}
	if (length(keys(categories)) != 7) return false;
	let accepted = {};
	for (let i = 0; i < length(wanted); i++) {
		let mac = direct_accept(rules[7 + i]);
		if (mac == null || accepted[mac]) return false;
		accepted[mac] = true;
	}
	for (let mac in wanted) if (!accepted[mac]) return false;
	let drop_at = 7 + length(wanted);
	if (!terminal_drop(rules[drop_at], 'ipv4') ||
	    !terminal_drop(rules[drop_at + 1], 'ipv6'))
		return false;
	return true;
};

export function owned_nft_tables(text) {
	let document = parse_json(text);
	if (type(document) != 'object' || type(document.nftables) != 'array')
		return null;
	let found = [];
	for (let entry in document.nftables) {
		if (exact_member(entry, 'metainfo'))
			continue;
		if (!exact_member(entry, 'table') || type(entry.table?.family) != 'string' ||
		    type(entry.table?.name) != 'string')
			return null;
		if (entry.table.family == 'inet' && reserved_table(entry.table.name)) {
			if (includes(found, entry.table.name))
				return null;
			push(found, entry.table.name);
		}
	}
	return found;
};

export function nft_ruleset(table, replace_existing, expected_direct_macs) {
	if (!reserved_table(table) || type(replace_existing) != 'bool')
		fail('INVALID_ARGUMENT');
	let wanted = direct_macs(expected_direct_macs);
	let lines = [];
	if (replace_existing)
		push(lines, 'delete table inet ' + table);
	push(lines,
		'add table inet ' + table,
		'add chain inet ' + table + ' ' + BOOTSTRAP_CHAIN + ' { type filter hook forward priority -310; policy accept; }',
		'add rule inet ' + table + ' ' + BOOTSTRAP_CHAIN + ' iifname "clash-tun" accept',
		'add rule inet ' + table + ' ' + BOOTSTRAP_CHAIN + ' oifname "clash-tun" accept',
		'add rule inet ' + table + ' ' + BOOTSTRAP_CHAIN + ' ct status dnat accept',
		'add rule inet ' + table + ' ' + BOOTSTRAP_CHAIN + ' udp sport 67 udp dport 68 accept',
		'add rule inet ' + table + ' ' + BOOTSTRAP_CHAIN + ' udp sport 68 udp dport 67 accept',
		'add rule inet ' + table + ' ' + BOOTSTRAP_CHAIN + ' ip daddr { 0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16, 224.0.0.0/4, 240.0.0.0/4 } accept',
		'add rule inet ' + table + ' ' + BOOTSTRAP_CHAIN + ' ip6 daddr { ::/128, ::1/128, fc00::/7, fe80::/10, ff00::/8 } accept');
	for (let mac in wanted)
		push(lines, 'add rule inet ' + table + ' ' + BOOTSTRAP_CHAIN + ' ether saddr "' + mac +
			'" accept comment "miclash-guard-direct"');
	push(lines,
		'add rule inet ' + table + ' ' + BOOTSTRAP_CHAIN + ' meta nfproto ipv4 drop comment "miclash-guard-bootstrap"',
		'add rule inet ' + table + ' ' + BOOTSTRAP_CHAIN + ' meta nfproto ipv6 drop comment "miclash-guard-bootstrap"',
		'');
	return join('\n', lines);
};

function removal_ruleset(tables) {
	let lines = [];
	for (let table in tables) {
		if (!reserved_table(table))
			fail('INVALID_ARGUMENT');
		push(lines, 'delete table inet ' + table);
	}
	push(lines, '');
	return join('\n', lines);
};

export function create_nft_backend(io) {
	if (type(io?.list_tables) != 'function' || type(io?.list_table) != 'function' ||
	    type(io?.apply) != 'function' || type(io?.remove) != 'function')
		fail('INVALID_ARGUMENT');

	function snapshot(expected_direct_macs) {
		let wanted;
		try { wanted = direct_macs(expected_direct_macs); }
		catch (error) { return null; }
		let present = owned_nft_tables(io.list_tables());
		if (present == null)
			return null;
		let verified = [];
		for (let table in present)
			if (verify_nft_table(io.list_table(table), table, wanted))
				push(verified, table);
		return { present, verified };
	};

	function installed(expected_direct_macs) {
		let state = snapshot(expected_direct_macs);
		return state != null && length(state.present) > 0 &&
			length(state.verified) == length(state.present);
	};
	function absent() {
		let state = snapshot([]);
		return state != null && length(state.present) == 0;
	};
	function occupied() {
		let state = snapshot([]);
		return state != null && length(state.present) > 0;
	};
	function install(expected_direct_macs) {
		let wanted;
		try { wanted = direct_macs(expected_direct_macs); }
		catch (error) { return false; }
		let state = snapshot(wanted);
		if (state == null)
			return false;
		if (length(state.present) && length(state.verified) == length(state.present))
			return true;
		let targets = length(state.present) ? state.present : [ BOOTSTRAP_TABLES[0] ];
		for (let table in targets)
			if (!includes(state.verified, table) &&
			    io.apply(table, nft_ruleset(table, includes(state.present, table), wanted)) !== true)
				continue;
		return installed(wanted);
	};
	function remove() {
		let state = snapshot();
		if (state == null)
			return false;
		if (!length(state.present))
			return true;
		if (io.remove(state.present, removal_ruleset(state.present)) !== true)
			return false;
		return absent();
	};
	return { installed, absent, occupied, install, remove };
};

function valid_desired(value) {
	if (type(value) != 'object' || type(value.enabled) != 'bool')
		fail('INVALID_ARGUMENT');
	return { ...value, direct_macs: direct_macs(value.direct_macs) };
};

function valid_transition_state(value, next) {
	if (type(value) != 'object' || type(value.desired_on) != 'bool' ||
	    type(value.main_rules_present) != 'bool' ||
	    (!next && type(value.bootstrap_installed) != 'bool') ||
	    (next && !EVENTS[value.event]))
		fail('INVALID_ARGUMENT');
	return value;
};

function adapter(runtime) {
	let value = runtime?.observers?.guard;
	if (type(value?.verify) != 'function' || type(value?.install) != 'function' ||
	    type(value?.remove) != 'function' || type(value?.persist) != 'function' ||
	    type(value?.record_status) != 'function')
		fail('INVALID_ARGUMENT');
	return value;
};

export function desired(settings, observations) {
	let setting = settings?.guard?.enabled;
	let exceptions = direct_macs(observations?.direct_macs);

	if (setting === true)
		return {
			enabled: true,
			source: 'settings',
			explicit_disable: false,
			direct_macs: exceptions
		};

	if (setting === false)
		return { enabled: false, source: 'settings', explicit_disable: true, direct_macs: [] };

	// An unreadable canonical source can only fail closed; observed or persisted
	// runtime state is diagnostic evidence, never a competing desired setting.
	return { enabled: true, source: 'fail_closed', explicit_disable: false,
		direct_macs: exceptions };
};

export function verify(runtime, wanted) {
	wanted = valid_desired(wanted);
	return adapter(runtime).verify(wanted) === true;
};

export function install_bootstrap(runtime, wanted) {
	wanted = valid_desired(wanted);
	let guard = adapter(runtime);
	let verified = guard.verify(wanted) === true;

	if (!verified) {
		let changed = wanted.enabled ? guard.install(wanted) : guard.remove(wanted);
		if (changed !== true || guard.verify(wanted) !== true)
			fail('INTERNAL');
	}

	if (guard.persist(wanted) !== true || guard.record_status({
		schema_version: 1,
		enabled: wanted.enabled,
		installed: wanted.enabled
	}) !== true)
		fail('INTERNAL');

	return true;
};

export function transition_plan(old, next) {
	valid_transition_state(old, false);
	valid_transition_state(next, true);
	let plan = [];

	if (!old.desired_on && next.desired_on) {
		push(plan, 'install_bootstrap');
		push(plan, 'persist_on');
	}
	else if (old.desired_on && !next.desired_on) {
		if (next.event != 'explicit_disable')
			fail('INVALID_ARGUMENT');
		push(plan, 'persist_off');
		push(plan, 'remove_main_rules');
		push(plan, 'remove_bootstrap');
		return plan;
	}
	else if (next.desired_on) {
		push(plan, old.bootstrap_installed ? 'verify_bootstrap' : 'install_bootstrap');
	}

	if (next.desired_on && next.event == 'daemon_crash') {
		// A crash is not schedulable: model the loss before reconciliation.
		pop(plan);
		push(plan, 'daemon_exit');
		push(plan, old.bootstrap_installed ? 'verify_bootstrap' : 'install_bootstrap');
	}
	else if (next.desired_on && next.event == 'package_upgrade')
		push(plan, 'replace_package');

	if (next.desired_on && (next.event == 'rules_rebuild' || next.event == 'wan_change')) {
		push(plan, 'remove_main_rules');
		push(plan, 'install_main_rules');
	}

	return plan;
};
