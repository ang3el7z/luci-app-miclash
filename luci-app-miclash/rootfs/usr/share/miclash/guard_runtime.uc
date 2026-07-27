import { fail } from 'miclash.errors';

const TABLE = 'miclash_guard';
const CHAIN = 'forward';
const IPT_CHAIN = 'MICLASH_GUARD_FORWARD';
const RESERVED4 = [ '0.0.0.0/8', '10.0.0.0/8', '100.64.0.0/10', '127.0.0.0/8',
	'169.254.0.0/16', '172.16.0.0/12', '192.0.2.0/24', '192.88.99.0/24',
	'192.168.0.0/16', '198.51.100.0/24', '203.0.113.0/24', '224.0.0.0/4',
	'240.0.0.0/4', '255.255.255.255/32' ];
const RESERVED6 = [ '::/128', '::1/128', 'fc00::/7', 'fe80::/10', 'ff00::/8' ];

function same(a, b) { return sprintf('%J', a) == sprintf('%J', b); };
function exact_member(value, name) {
	return type(value) == 'object' && length(keys(value)) == 1 && exists(value, name);
};
function parse(text) {
	if (type(text) != 'string') return null;
	try { return json(text); } catch (error) { return null; }
};
function valid_ifaces(values) {
	if (type(values) != 'array') return false;
	let previous = null;
	for (let value in values) {
		if (type(value) != 'string' || !match(value, /^[A-Za-z0-9_.:@-]{1,15}$/) ||
		    (previous != null && value <= previous)) return false;
		previous = value;
	}
	return true;
};
export function interfaces(text) {
	if (type(text) != 'string' || match(text, /[\n\r]/)) fail('INVALID_ARGUMENT');
	let values = length(text) ? split(text, ',') : [];
	if (!valid_ifaces(values)) fail('INVALID_ARGUMENT');
	return values;
};
function verdict(value, name) { return exact_member(value, name) && value[name] == null; };
function matched(value) { return exact_member(value, 'match') ? value.match : null; };
function left(value, kind, key, field) {
	let candidate = matched(value)?.left;
	if (type(candidate) != 'object' || length(keys(candidate)) != 1 ||
	    type(candidate[kind]) != 'object') return false;
	if (field == null)
		return length(keys(candidate[kind])) == 1 && candidate[kind].key == key;
	return length(keys(candidate[kind])) == 2 && candidate[kind].protocol == key &&
		candidate[kind].field == field;
};
function expression(value, kind, key, field, op, right) {
	let item = matched(value);
	return item?.op == op && same(item.right, right) && left(value, kind, key, field);
};
function rule(expr, expected) { return same(expr, expected); };
function prefix(value) {
	let item = value?.prefix;
	if (!exact_member(value, 'prefix') || type(item?.addr) != 'string' ||
	    type(item?.len) != 'int' || length(keys(item)) != 2) return null;
	return item.addr + '/' + item.len;
};
function range(value) {
	let item = value?.range;
	if (!exact_member(value, 'range') || type(item) != 'array' || length(item) != 2 ||
	    type(item[0]) != 'string' || type(item[1]) != 'string') return null;
	return item[0] + '-' + item[1];
};
function exact_elements(values, wanted) {
	if (type(values) != 'array' || length(values) != length(wanted)) return false;
	let seen = {};
	for (let value in values) {
		let key = prefix(value) ?? range(value);
		if (key == null || seen[key]) return false;
		seen[key] = true;
	}
	for (let key in wanted) if (!seen[key]) return false;
	return true;
};
function exact_reserved4(values) {
	return exact_elements(values, RESERVED4) || exact_elements(values, [
		'0.0.0.0/8', '10.0.0.0/8', '100.64.0.0/10', '127.0.0.0/8',
		'169.254.0.0/16', '172.16.0.0/12', '192.0.2.0/24', '192.88.99.0/24',
		'192.168.0.0/16', '198.51.100.0/24', '203.0.113.0/24',
		'224.0.0.0-255.255.255.255'
	]);
};
function exact_reserved6(values) {
	return exact_elements(values, RESERVED6) || exact_elements(values, [
		'::/127', 'fc00::/7', 'fe80::/10',
		'ff00::-ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff'
	]);
};
function accept(expr) { return type(expr) == 'array' && verdict(expr[length(expr) - 1], 'accept'); };
function return_or_drop(expr, name) {
	return type(expr) == 'array' && verdict(expr[length(expr) - 1], name);
};
function exact_safe_rule(expr, index) {
	if (!accept(expr)) return false;
	switch (index) {
	case 0:
		return length(expr) == 2 &&
			(expression(expr[0], 'ct', 'state', null, 'in', [ 'established', 'related' ]) ||
			 expression(expr[0], 'ct', 'state', null, 'in', { set: [ 'established', 'related' ] }));
	case 1: return length(expr) == 2 && expression(expr[0], 'meta', 'iifname', null, '==', 'clash-tun');
	case 2: return length(expr) == 2 && expression(expr[0], 'meta', 'oifname', null, '==', 'clash-tun');
	case 3: return length(expr) == 2 && expression(expr[0], 'ct', 'status', null, 'in', 'dnat');
	case 4: return length(expr) == 3 && expression(expr[0], 'payload', 'udp', 'sport', '==', 67) &&
		expression(expr[1], 'payload', 'udp', 'dport', '==', 68);
	case 5: return length(expr) == 3 && expression(expr[0], 'payload', 'udp', 'sport', '==', 68) &&
		expression(expr[1], 'payload', 'udp', 'dport', '==', 67);
	case 6: return length(expr) == 2 &&
		(expression(expr[0], 'payload', 'ip', 'daddr', '==', '@local4') ||
		 expression(expr[0], 'payload', 'ip', 'daddr', '==', { set: 'local4' }));
	case 7: return length(expr) == 2 &&
		(expression(expr[0], 'payload', 'ip6', 'daddr', '==', '@local6') ||
		 expression(expr[0], 'payload', 'ip6', 'daddr', '==', { set: 'local6' }));
	}
	return false;
};
function exact_drop(expr, iface, family) {
	if (!return_or_drop(expr, 'drop') || length(expr) != 2) return false;
	return iface != null
		? expression(expr[0], 'meta', 'oifname', null, '==', iface)
		: expression(expr[0], 'meta', 'nfproto', null, '==', family);
};

export function verify_nft(text, expected_ifaces) {
	if (!valid_ifaces(expected_ifaces)) return false;
	let document = parse(text);
	if (type(document) != 'object' || type(document.nftables) != 'array') return false;
	let tables = 0, chains = 0, sets = {}, elements = {}, rules = [];
	for (let entry in document.nftables) {
		if (exact_member(entry, 'metainfo')) continue;
		if (exact_member(entry, 'table')) {
			if (entry.table?.family != 'inet' || entry.table.name != TABLE) return false;
			tables++;
		}
		else if (exact_member(entry, 'chain')) {
			let item = entry.chain;
			if (item?.family != 'inet' || item.table != TABLE || item.name != CHAIN ||
			    item.type != 'filter' || item.hook != 'forward' || item.prio !== 1 ||
			    item.policy != 'accept') return false;
			chains++;
		}
		else if (exact_member(entry, 'set')) {
			let item = entry.set;
			if (item?.family != 'inet' || item.table != TABLE ||
			    (item.name != 'local4' && item.name != 'local6') || sets[item.name] ||
			    item.type != (item.name == 'local4' ? 'ipv4_addr' : 'ipv6_addr') ||
			    !same(item.flags, [ 'interval' ])) return false;
			sets[item.name] = true;
			if (item.elem != null) elements[item.name] = item.elem;
		}
		else if (exact_member(entry, 'element')) {
			let item = entry.element;
			if (item?.family != 'inet' || item.table != TABLE ||
			    (item.name != 'local4' && item.name != 'local6') || elements[item.name] != null)
				return false;
			elements[item.name] = item.elem;
		}
		else if (exact_member(entry, 'rule')) {
			let item = entry.rule;
			if (item?.family != 'inet' || item.table != TABLE || item.chain != CHAIN)
				return false;
			push(rules, item);
		}
		else return false;
	}
	if (tables != 1 || chains != 1 || length(keys(sets)) != 2 ||
	    !exact_reserved4(elements.local4) || !exact_reserved6(elements.local6)) return false;
	for (let i = 0; i < 8; i++)
		if (!exact_safe_rule(rules[i]?.expr, i)) return false;
	let terminal = slice(rules, 8);
	if (length(expected_ifaces)) {
		if (length(terminal) != length(expected_ifaces)) return false;
		for (let i = 0; i < length(expected_ifaces); i++)
			if (terminal[i].comment != 'miclash-guard' ||
			    !exact_drop(terminal[i].expr, expected_ifaces[i], null)) return false;
	}
	else if (length(terminal) != 2 || terminal[0].comment != 'miclash-guard' ||
	         terminal[1].comment != 'miclash-guard' ||
	         !exact_drop(terminal[0].expr, null, 'ipv4') ||
	         !exact_drop(terminal[1].expr, null, 'ipv6')) return false;
	return true;
};

function expected_iptables(family, ifaces) {
	let lines = [
		'-A ' + IPT_CHAIN + ' -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN',
		'-A ' + IPT_CHAIN + ' -i clash-tun -j RETURN',
		'-A ' + IPT_CHAIN + ' -o clash-tun -j RETURN'
	];
	if (family == 'ipv4')
		push(lines, '-A ' + IPT_CHAIN + ' -m conntrack --ctstate DNAT -j RETURN');
	push(lines,
		'-A ' + IPT_CHAIN + ' -p udp --sport 67 --dport 68 -j RETURN',
		'-A ' + IPT_CHAIN + ' -p udp --sport 68 --dport 67 -j RETURN');
	for (let network in family == 'ipv4' ? RESERVED4 : RESERVED6)
		push(lines, '-A ' + IPT_CHAIN + ' -d ' + network + ' -j RETURN');
	if (length(ifaces)) for (let iface in ifaces)
		push(lines, '-A ' + IPT_CHAIN + ' -o ' + iface + ' -j DROP');
	else push(lines, '-A ' + IPT_CHAIN + ' -j DROP');
	push(lines, '-A ' + IPT_CHAIN + ' -j RETURN');
	return lines;
};
function normalize_iptables(line) {
	line = replace(line, / -p udp -m udp /, ' -p udp ');
	return replace(line, /--ctstate RELATED,ESTABLISHED/, '--ctstate ESTABLISHED,RELATED');
};
export function verify_iptables(text, family, expected_ifaces) {
	if ((family != 'ipv4' && family != 'ipv6') || !valid_ifaces(expected_ifaces) ||
	    type(text) != 'string') return false;
	let owned = [], forwards = [], declarations = 0;
	for (let line in split(text, '\n')) {
		line = trim(line);
		if (!length(line) || line == '*filter' || line == 'COMMIT' || substr(line, 0, 1) == '#')
			continue;
		if (match(line, /^:MICLASH_GUARD_FORWARD /)) { declarations++; continue; }
		if (match(line, /^:/)) continue;
		if (match(line, /^-A MICLASH_GUARD_FORWARD /)) push(owned, normalize_iptables(line));
		else if (match(line, /^-A FORWARD /)) push(forwards, line);
		else if (index(line, IPT_CHAIN) >= 0) return false;
	}
	return declarations == 1 && length(forwards) >= 1 &&
		forwards[0] == '-A FORWARD -j ' + IPT_CHAIN &&
		length(filter(forwards, (line) => index(line, '-j ' + IPT_CHAIN) >= 0)) == 1 &&
		same(owned, expected_iptables(family, expected_ifaces));
};
