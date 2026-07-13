import { fail } from 'miclash.errors';
import * as storage from 'miclash.storage';

// Reserved by /etc/iproute2/rt_protos.d/miclash.conf. The tag is only a
// collision detector: exact ownership still requires the durable manifest.
const OWNER_PROTOCOL = 242;
const MANIFEST_PATH = '/var/run/miclash/routing-ownership.json';
const MANIFEST_CANONICAL_PATH = '/tmp/run/miclash/routing-ownership.json';
const MANIFEST_OWNER = 'miclash';
const MANIFEST_VERSION = 1;
const MAX_MANIFEST = 32768;
const MAX_CAPTURE = 65536;
const CAPTURE_PREFIX = '/usr/bin/timeout -s KILL 2 ';
const FAMILIES = { ipv4: '-4', ipv6: '-6' };
const FIXED_CAPTURE = {
	'ip -j -4 rule show': true,
	'ip -j -6 rule show': true,
	'ip -j -4 route show table 100': true,
	'ip -j -4 route show table 101': true,
	'ip -j -6 route show table 100': true,
	'ip -j -6 route show table 101': true,
	'ip -j link show dev clash-tun': true,
	'ip -4 rule show': true,
	'ip -6 rule show': true,
	'ip -4 route show table 100': true,
	'ip -4 route show table 101': true,
	'ip -6 route show table 100': true,
	'ip -6 route show table 101': true,
	'ip link show dev clash-tun': true
};

function has(values, wanted) {
	for (let value in values ?? []) if (value == wanted) return true;
	return false;
};

function exact_fields(value, allowed) {
	if (type(value) != 'object') return false;
	let count = 0;
	for (let name in value) {
		if (!allowed[name]) return false;
		count++;
	}
	return count == length(keys(allowed));
};

function allowed_fields(value, allowed) {
	if (type(value) != 'object') return false;
	for (let name in value) if (!allowed[name]) return false;
	return true;
};

function valid_family(family) { return exists(FAMILIES, family); };
function validate_families(families) {
	if (type(families) != 'array' || !length(families) || length(families) > 2)
		fail('INVALID_ARGUMENT');
	let seen = {};
	for (let family in families) {
		if (!valid_family(family) || seen[family]) fail('INVALID_ARGUMENT');
		seen[family] = true;
	}
};

function route(family, table, kind, device, metric) {
	let value = { family, table, kind, destination: 'default', device: device ?? null, owned: true };
	if (kind == 'unreachable') {
		value.unreachable = true;
		value.metric = metric;
	}
	return value;
};

function rule(family, table, priority, mark) {
	return { family, priority, mark, mask: '0xffffffff', table, owned: true };
};

function route_matrix(item) {
	if (type(item) != 'object' || !valid_family(item.family) || item.destination != 'default') return false;
	if (item.table == 100 && item.kind == 'local') return item.device == 'lo' && item.metric == null;
	if (item.table == 100 && item.kind == 'unicast') return item.device == 'clash-tun' && item.metric == null;
	if (item.table == 101 && item.kind == 'unicast') return item.device == 'clash-tun' && item.metric == null;
	if (item.table == 101 && item.kind == 'unreachable')
		return item.device == null && item.unreachable === true && item.metric == 42760;
	return false;
};

function canonical_route(item) {
	if (!route_matrix(item)) return null;
	let value = { family: item.family, table: item.table, kind: item.kind,
		destination: 'default', device: item.device ?? null };
	if (item.kind == 'unreachable') { value.unreachable = true; value.metric = 42760; }
	return value;
};

function rule_matrix(item) {
	return type(item) == 'object' && valid_family(item.family) &&
		((item.table == 100 && item.priority == 1000 && item.mark == '0x1' && item.mask == '0xffffffff') ||
		 (item.table == 101 && item.priority == 1001 && item.mark == '0x3' && item.mask == '0xffffffff'));
};

function canonical_rule(item) {
	if (!rule_matrix(item)) return null;
	return { family: item.family, priority: item.priority, mark: item.mark,
		mask: item.mask, table: item.table };
};

function route_action(item) {
	let value = canonical_route(item);
	if (value == null) return null;
	value.owned = true;
	return value;
};

function rule_action(item) {
	let value = canonical_rule(item);
	if (value == null) return null;
	value.owned = true;
	return value;
};

function entry_key(item) { return sprintf('%J', item); };
function contains_entry(values, wanted) {
	let key = entry_key(wanted);
	for (let item in values ?? []) if (entry_key(item) == key) return true;
	return false;
};

function manifest_document(routes, rules) {
	return { version: MANIFEST_VERSION, owner: MANIFEST_OWNER, protocol: OWNER_PROTOCOL,
		routes: routes, rules: rules };
};

function validate_manifest_entries(values, kind) {
	if (type(values) != 'array' || length(values) > 4) return null;
	let result = [], seen = {};
	for (let item in values) {
		let allowed = kind == 'route'
			? (item?.kind == 'unreachable'
				? { family: true, table: true, kind: true, destination: true, device: true,
					unreachable: true, metric: true }
				: { family: true, table: true, kind: true, destination: true, device: true })
			: { family: true, priority: true, mark: true, mask: true, table: true };
		if (!exact_fields(item, allowed)) return null;
		let canonical = kind == 'route' ? canonical_route(item) : canonical_rule(item);
		if (canonical == null) return null;
		let key = entry_key(canonical);
		if (seen[key]) return null;
		seen[key] = true;
		push(result, canonical);
	}
	return result;
};

function load_manifest(runtime) {
	let absent = { trusted: false, routes: [], rules: [] };
	if (runtime?.paths?.run != '/var/run/miclash' || type(runtime?.fs?.readfile) != 'function') return absent;
	let source = runtime.fs.readfile(MANIFEST_PATH);
	if (source == null) return absent;
	try {
		if (type(source) != 'string' || !length(source) || length(source) > MAX_MANIFEST) return absent;
		let stat = runtime.fs.lstat(MANIFEST_PATH);
		let resolved = runtime.fs.realpath(MANIFEST_PATH);
		if (stat?.type != 'file' || stat.nlink != 1 || stat.uid != 0 || (stat.mode & 0o022) != 0 ||
		    (resolved != MANIFEST_PATH && resolved != MANIFEST_CANONICAL_PATH)) return absent;
		let document = json(source);
		if (!exact_fields(document, { version: true, owner: true, protocol: true, routes: true, rules: true }) ||
		    document.version != MANIFEST_VERSION || document.owner != MANIFEST_OWNER ||
		    document.protocol != OWNER_PROTOCOL) return absent;
		let routes = validate_manifest_entries(document.routes, 'route');
		let rules = validate_manifest_entries(document.rules, 'rule');
		if (routes == null || rules == null) return absent;
		return { trusted: true, routes, rules };
	}
	catch (error) { return absent; }
};

function canonical_list(values, kind) {
	let result = [];
	for (let item in values ?? []) {
		let canonical = kind == 'route' ? canonical_route(item) : canonical_rule(item);
		if (canonical == null || contains_entry(result, canonical)) fail('INVALID_ARGUMENT');
		push(result, canonical);
	}
	if (length(result) > 4) fail('INVALID_ARGUMENT');
	return result;
};

function union_entries(left, right) {
	let result = [ ...(left ?? []) ];
	for (let item in right ?? []) if (!contains_entry(result, item)) push(result, item);
	return result;
};

function same_entries(left, right) {
	if (length(left ?? []) != length(right ?? [])) return false;
	for (let item in left ?? []) if (!contains_entry(right, item)) return false;
	return true;
};

export function desired(settings, interfaces) {
	let mode = settings?.proxy_mode;
	if (!has([ 'tproxy', 'tun', 'mixed' ], mode)) fail('INVALID_ARGUMENT');
	validate_families(settings.ip_families);
	if (interfaces != null && type(interfaces) != 'object') fail('INVALID_ARGUMENT');
	let tun_present = interfaces?.['clash-tun'] === true || settings?.existing_clash_tun === true;
	let routes = [], rules = [];
	for (let family in settings.ip_families) {
		if (mode == 'tun' && tun_present)
			push(routes, route(family, 100, 'unicast', 'clash-tun'));
		else
			push(routes, route(family, 100, 'local', 'lo'));
		push(rules, rule(family, 100, 1000, '0x1'));
		if (mode == 'mixed') {
			push(routes, tun_present ? route(family, 101, 'unicast', 'clash-tun') :
				route(family, 101, 'unreachable', null, 42760));
			push(rules, rule(family, 101, 1001, '0x3'));
		}
	}
	return { routes, rules, tun_mode: mode != 'tproxy', tun_present };
};

function fixed_capture(runtime, command, allow_command_failure) {
	if (!FIXED_CAPTURE[command]) fail('INVALID_ARGUMENT');
	let popen = runtime.fs?.popen ?? require('fs').popen;
	if (type(popen) != 'function') fail('INTERNAL');
	let pipe = popen(CAPTURE_PREFIX + command + ' 2>/dev/null', 'r');
	if (pipe == null) fail('INTERNAL');
	let output = '', failed = false, oversized = false;
	while (true) {
		let chunk;
		try { chunk = pipe.read(4096); } catch (error) { failed = true; break; }
		if (type(chunk) != 'string') { failed = true; break; }
		if (!length(chunk)) break;
		if (oversized) continue;
		if (length(output) + length(chunk) > MAX_CAPTURE) { oversized = true; continue; }
		output += chunk;
	}
	let closed = null;
	try { closed = pipe.close(); } catch (error) { failed = true; }
	// `ip -j route show table N` emits valid `[]` while returning non-zero when
	// a table does not exist. Treat capture integrity as authoritative here;
	// parsers still reject malformed or ambiguous output before any mutation.
	let succeeded = closed === 0 || closed === true;
	let route_output = trim(output);
	let route_absence = index(command, ' route show ') >= 0 &&
		(route_output == '[]' || (closed === 2 && (route_output == '' || route_output == '[')));
	let link_absence = (command == 'ip -j link show dev clash-tun' ||
		command == 'ip link show dev clash-tun') && closed === 1 && !length(trim(output));
	let expected_absence = route_absence || link_absence;
	if (failed || oversized) fail('INTERNAL');
	if (!succeeded && !expected_absence) {
		if (allow_command_failure) return null;
		fail('INTERNAL');
	}
	if (link_absence || route_absence)
		return index(command, 'ip -j ') == 0 ? '[]' : '';
	return output;
};

function number(value) {
	if (type(value) == 'int') return value;
	if (type(value) == 'string' && match(value, /^[0-9]+$/)) return int(value);
	return null;
};

function normalize_table(value) {
	let numeric = number(value);
	if (numeric != null) return numeric;
	if (value == 'miclash_tproxy') return 100;
	if (value == 'miclash_mixed') return 101;
	return null;
};

function normalize_protocol(value) {
	let numeric = number(value);
	if (numeric != null) return numeric;
	return value == 'miclash' ? OWNER_PROTOCOL : null;
};

function normalize_mark(value) {
	if (type(value) == 'int') return sprintf('0x%x', value);
	if (type(value) != 'string') return null;
	let found = match(value, /^(0x[0-9a-fA-F]+)(\/0x[0-9a-fA-F]+)?$/);
	return found ? lc(found[1]) : null;
};

function normalize_mask(value) {
	if (value == null) return '0xffffffff';
	return normalize_mark(value);
};

function json_rules(text, family) {
	let document = json(text);
	if (type(document) != 'array') fail('INVALID_ARGUMENT');
	let values = [];
	for (let item in document) {
		if (type(item) != 'object') continue;
		let priority = number(item.priority), table = normalize_table(item.table), mark = normalize_mark(item.fwmark);
		if (!has([ 1000, 1001 ], priority) && !has([ 100, 101 ], table)) continue;
		if (!allowed_fields(item, { priority: true, src: true, fwmark: true, fwmask: true,
		    table: true, protocol: true }) || (item.src != null && item.src != 'all') ||
		    (item.protocol != null && normalize_protocol(item.protocol) == null)) {
			push(values, { family, ambiguous: true, owned: false }); continue;
		}
		if (priority == null || table == null || mark == null) {
			push(values, { family, ambiguous: true, owned: false }); continue;
		}
		let mask = normalize_mask(item.fwmask);
		if (mask == null) { push(values, { family, ambiguous: true, owned: false }); continue; }
		push(values, { family, priority, mark, mask, table,
			protocol: normalize_protocol(item.protocol), owned: false });
	}
	return values;
};

function json_routes(text, family, requested_table) {
	let document = json(text);
	if (type(document) != 'array') fail('INVALID_ARGUMENT');
	let values = [];
	for (let item in document) {
		if (type(item) != 'object' || !allowed_fields(item, { type: true, dst: true, dev: true,
		    table: true, protocol: true, scope: true, metric: true, flags: true, pref: true })) {
			push(values, { family, table: requested_table, ambiguous: true, owned: false }); continue;
		}
		let table = item.table == null ? requested_table : normalize_table(item.table);
		if (table != requested_table) { push(values, { family, table, ambiguous: true, owned: false }); continue; }
		if ((item.protocol != null && normalize_protocol(item.protocol) == null) ||
		    (item.flags != null && (type(item.flags) != 'array' || length(item.flags)))) {
			push(values, { family, table, ambiguous: true, owned: false }); continue;
		}
		let kind;
		if (item.type == null || item.type == 'unicast') kind = 'unicast';
		else if (item.type == 'local') kind = 'local';
		else if (item.type == 'unreachable') kind = 'unreachable';
		else { push(values, { family, table, ambiguous: true, owned: false }); continue; }
		let destination = item.dst ?? 'default';
		if (destination != 'default') { push(values, { family, table, ambiguous: true, owned: false }); continue; }
		let valid_scope = item.scope == null ||
			(kind == 'local' && item.scope == 'host') ||
			(kind == 'unicast' && item.scope == 'link') ||
			(kind == 'unreachable' && item.scope == 'global');
		let ipv6_defaults = family == 'ipv6' && item.pref == 'medium' &&
			(kind == 'unreachable' || item.metric == 1024);
		let no_defaults = item.pref == null && (kind == 'unreachable' || item.metric == null);
		let ipv6_unreachable_device = family == 'ipv6' && kind == 'unreachable' &&
			item.dev == 'lo' && item.pref == 'medium' && number(item.metric) == 42760;
		if (!valid_scope || (!ipv6_defaults && !no_defaults) ||
		    (kind == 'unreachable' && item.dev != null && !ipv6_unreachable_device)) {
			push(values, { family, table, ambiguous: true, owned: false }); continue;
		}
		let value = { family, table, kind, destination,
			device: ipv6_unreachable_device ? null : item.dev ?? null,
			protocol: normalize_protocol(item.protocol), owned: false };
		if (kind == 'unreachable') { value.unreachable = true; value.metric = number(item.metric); }
		if (!route_matrix(value)) value.ambiguous = true;
		push(values, value);
	}
	return values;
};

function text_rules(text, family) {
	let values = [];
	for (let line in split(text, '\n')) {
		if (!length(trim(line))) continue;
		let found = match(trim(line), /^([0-9]+):[ \t]+from all fwmark (0x[0-9a-fA-F]+)(\/0x[0-9a-fA-F]+)? (lookup|table) ([A-Za-z0-9_.-]+)( (proto|protocol) ([A-Za-z0-9_.-]+))?$/);
		if (!found) {
			if (match(line, /^(1000|1001):/) || match(line, /(lookup|table) (100|101)([ \t]|$)/))
				push(values, { family, ambiguous: true, owned: false });
			continue;
		}
		let mask = found[3] == null ? '0xffffffff' : normalize_mask(substr(found[3], 1));
		let table = normalize_table(found[5]);
		let protocol = found[8] == null ? null : normalize_protocol(found[8]);
		if (table == null || (found[8] != null && protocol == null)) {
			push(values, { family, ambiguous: true, owned: false }); continue;
		}
		push(values, { family, priority: int(found[1]), mark: lc(found[2]), mask, table,
			protocol, owned: false });
	}
	return values;
};

function text_routes(text, family, table) {
	let values = [];
	for (let line in split(text, '\n')) {
		line = trim(line);
		if (!length(line)) continue;
		let local = match(line, /^local default dev ([A-Za-z0-9_.:-]+)( proto ([A-Za-z0-9_.-]+))?( scope host)?( metric ([0-9]+) pref ([A-Za-z]+))?$/);
		let unreachable = match(line, /^unreachable default( dev ([A-Za-z0-9_.:-]+))?( proto ([A-Za-z0-9_.-]+))? metric ([0-9]+)( scope global)?( pref ([A-Za-z]+))?$/);
		let unicast = match(line, /^default dev ([A-Za-z0-9_.:-]+)( proto ([A-Za-z0-9_.-]+))?( scope link)?( metric ([0-9]+) pref ([A-Za-z]+))?$/);
		let value = null, token = null, implicit_metric = null, preference = null;
		if (local) {
			token = local[3];
			implicit_metric = local[6]; preference = local[7];
			value = { family, table, kind: 'local', destination: 'default', device: local[1] };
		}
		else if (unreachable) {
			token = unreachable[4];
			preference = unreachable[8];
			let kernel_device = unreachable[2];
			value = { family, table, kind: 'unreachable', destination: 'default', device: null,
				unreachable: true, metric: int(unreachable[5]) };
			if (kernel_device != null && !(family == 'ipv6' && kernel_device == 'lo' && preference == 'medium'))
				value.ambiguous = true;
		}
		else if (unicast) {
			token = unicast[3];
			implicit_metric = unicast[6]; preference = unicast[7];
			value = { family, table, kind: 'unicast', destination: 'default', device: unicast[1] };
		}
		if (value != null) {
			value.protocol = token == null ? null : normalize_protocol(token);
			value.owned = false;
			let canonical_defaults = implicit_metric == null && preference == null ||
				(family == 'ipv6' && implicit_metric == '1024' && preference == 'medium') ||
				(value.kind == 'unreachable' && family == 'ipv6' && preference == 'medium');
			if ((token != null && value.protocol == null) || !canonical_defaults || !route_matrix(value))
				value.ambiguous = true;
			push(values, value);
		}
		else push(values, { family, table, ambiguous: true, owned: false });
	}
	return values;
};

function capture_parsed(runtime, json_command, text_command, parser_json, parser_text) {
	let captured = fixed_capture(runtime, json_command, true);
	if (captured != null) try { return parser_json(captured); } catch (error) {}
	return parser_text(fixed_capture(runtime, text_command, false));
};

function authorize_ownership(values, kind, ownership) {
	for (let item in values) {
		item.owned = false;
		if (item.protocol != OWNER_PROTOCOL) continue;
		let canonical = kind == 'route' ? canonical_route(item) : canonical_rule(item);
		let covered = canonical != null && ownership.trusted &&
			contains_entry(kind == 'route' ? ownership.routes : ownership.rules, canonical);
		if (!item.ambiguous && covered) item.owned = true;
		else item.ambiguous = true;
	}
};

export function observe(runtime) {
	if (type(runtime) != 'object') fail('INVALID_ARGUMENT');
	let rules = [], routes = [];
	for (let family in [ 'ipv4', 'ipv6' ]) {
		let flag = FAMILIES[family];
		for (let value in capture_parsed(runtime, 'ip -j ' + flag + ' rule show', 'ip ' + flag + ' rule show',
			(text) => json_rules(text, family), (text) => text_rules(text, family))) push(rules, value);
		for (let table in [ 100, 101 ])
			for (let value in capture_parsed(runtime, 'ip -j ' + flag + ' route show table ' + table,
				'ip ' + flag + ' route show table ' + table,
				(text) => json_routes(text, family, table), (text) => text_routes(text, family, table))) push(routes, value);
	}
	let links = capture_parsed(runtime, 'ip -j link show dev clash-tun', 'ip link show dev clash-tun',
		(text) => { let document = json(text); if (type(document) != 'array') fail('INVALID_ARGUMENT'); return document; },
		(text) => length(trim(text)) ? [ true ] : []);
	let ownership = load_manifest(runtime);
	authorize_ownership(routes, 'route', ownership);
	authorize_ownership(rules, 'rule', ownership);
	return { routes, rules, interfaces: { 'clash-tun': length(links) > 0 }, ownership };
};

function same_route(a, b) {
	return a.family == b.family && a.table == b.table && a.kind == b.kind &&
		a.destination == b.destination && a.device == b.device &&
		(a.kind != 'unreachable' || a.metric == b.metric);
};
function same_rule(a, b) {
	return a.family == b.family && a.priority == b.priority && a.mark == b.mark &&
		a.mask == b.mask && a.table == b.table;
};

export function diff(wanted, observed) {
	if (type(wanted?.routes) != 'array' || type(wanted?.rules) != 'array' ||
	    type(observed?.routes) != 'array' || type(observed?.rules) != 'array') fail('INVALID_ARGUMENT');
	let after_routes = canonical_list(wanted.routes, 'route');
	let after_rules = canonical_list(wanted.rules, 'rule');
	let before_routes = observed.ownership?.trusted === true
		? validate_manifest_entries(observed.ownership.routes, 'route') : [];
	let before_rules = observed.ownership?.trusted === true
		? validate_manifest_entries(observed.ownership.rules, 'rule') : [];
	if (before_routes == null || before_rules == null) fail('INVALID_ARGUMENT');
	let result = { remove_rules: [], remove_routes: [], add_routes: [], add_rules: [], conflicts: [],
		monitor: { enabled: wanted.tun_mode === true, present: wanted.tun_present === true },
		ownership: {
			before: { routes: before_routes, rules: before_rules },
			after: { routes: after_routes, rules: after_rules }
		}
	};
	for (let existing in [ ...observed.routes, ...observed.rules ])
		if (existing.ambiguous) push(result.conflicts, { kind: 'ambiguous', entry: existing });
	for (let item in wanted.routes) {
		let exact = false, reserved = [], conflicting_foreign = false;
		for (let existing in observed.routes) if (existing.family == item.family && existing.table == item.table) {
			push(reserved, existing);
			if (same_route(item, existing)) exact = true;
			if (!existing.owned) conflicting_foreign = true;
		}
		if (conflicting_foreign) push(result.conflicts, { kind: 'foreign-route', entry: item });
		else if (!exact) {
			let foreign = false;
			for (let existing in reserved) foreign = foreign || !existing.owned;
			if (foreign) push(result.conflicts, { kind: 'foreign-route', entry: item });
			else push(result.add_routes, item);
		}
	}
	for (let item in wanted.rules) {
		let exact = false, reserved = [], conflicting_foreign = false;
		for (let existing in observed.rules) if (existing.family == item.family &&
			(existing.priority == item.priority || existing.table == item.table)) {
			push(reserved, existing);
			if (same_rule(item, existing)) exact = true;
			if (!existing.owned) conflicting_foreign = true;
		}
		if (conflicting_foreign) push(result.conflicts, { kind: 'foreign-rule', entry: item });
		else if (!exact) {
			let foreign = false; for (let existing in reserved) foreign = foreign || !existing.owned;
			if (foreign) push(result.conflicts, { kind: 'foreign-rule', entry: item });
			else push(result.add_rules, item);
		}
	}
	for (let existing in observed.rules) if (existing.owned) {
		let keep = false; for (let item in wanted.rules) keep = keep || same_rule(item, existing);
		if (!keep) push(result.remove_rules, rule_action(existing));
	}
	for (let existing in observed.routes) if (existing.owned) {
		let keep = false;
		for (let item in wanted.routes) {
			keep = keep || same_route(item, existing);
		}
		if (!keep) push(result.remove_routes, route_action(existing));
	}
	return result;
};

function route_args(action, item) {
	let args = [ FAMILIES[item.family], 'route', action ];
	if (item.kind == 'local') push(args, 'local', 'default', 'dev', item.device);
	else if (item.kind == 'unreachable') push(args, 'unreachable', 'default', 'metric', '' + item.metric);
	else push(args, 'default', 'dev', item.device);
	push(args, 'table', '' + item.table, 'proto', '' + OWNER_PROTOCOL);
	return args;
};
function rule_args(action, item) {
	return [ FAMILIES[item.family], 'rule', action, 'pref', '' + item.priority,
		'fwmark', item.mark + '/' + item.mask,
		'table', '' + item.table, 'protocol', '' + OWNER_PROTOCOL ];
};
function run(runtime, args) {
	let result = runtime.process.run({ command: 'ip', args });
	if (result?.code != 0) fail('INTERNAL');
};

function disarm_tun_monitor(runtime) {
	let state = runtime.routing_monitor;
	runtime.routing_monitor_epoch = (runtime.routing_monitor_epoch ?? 0) + 1;
	if (state == null) return;
	state.active = false;
	if (type(state.subscription) == 'function') state.subscription();
	else if (type(state.subscription?.remove) == 'function') state.subscription.remove();
	else if (type(state.subscription?.unsubscribe) == 'function') state.subscription.unsubscribe();
	else if (type(state.subscription?.cancel) == 'function') state.subscription.cancel();
	if (type(state.timer?.cancel) == 'function') state.timer.cancel();
	if (type(state.drain?.cancel) == 'function') state.drain.cancel();
	runtime.routing_monitor = null;
};

function arm_tun_monitor(runtime, monitor) {
	if (!monitor?.enabled) return;
	let observer = runtime.observers?.routing;
	let epoch = (runtime.routing_monitor_epoch ?? 0) + 1;
	runtime.routing_monitor_epoch = epoch;
	let state = { active: true, epoch, subscription: null, timer: null, drain: null,
		pending: null, in_flight: false };
	runtime.routing_monitor = state;
	function current() {
		return state.active && state.epoch == runtime.routing_monitor_epoch &&
			runtime.routing_monitor === state;
	};
	function enqueue(present) {
		if (!current() || type(present) != 'bool') return;
		state.pending = present;
		if (state.in_flight || state.drain != null) return;
		let scheduled_epoch = epoch;
		state.drain = runtime.clock.set_timeout(0, () => {
			state.drain = null;
			if (!current() || scheduled_epoch != runtime.routing_monitor_epoch) return;
			let next = state.pending;
			state.pending = null;
			if (type(next) != 'bool' || next == monitor.present) return;
			state.in_flight = true;
			try { observer.reconcile(next); }
			catch (error) {
				state.in_flight = false;
				disarm_tun_monitor(runtime);
				fail(error?.code ?? error?.message ?? 'INTERNAL');
			}
			state.in_flight = false;
			if (current() && state.pending != null) enqueue(state.pending);
		});
	};
	if (type(observer.subscribe) == 'function')
		state.subscription = observer.subscribe((event) => {
			if (!current()) return;
			if (event?.interface != 'clash-tun') return;
			if (event.action == 'add' || event.action == 'ifup') enqueue(true);
			else if (event.action == 'remove' || event.action == 'ifdown') enqueue(false);
		});
	let cancellable = type(state.subscription) == 'function' ||
		type(state.subscription?.remove) == 'function' || type(state.subscription?.unsubscribe) == 'function' ||
		type(state.subscription?.cancel) == 'function';
	if (!cancellable) {
		disarm_tun_monitor(runtime);
		fail('INVALID_ARGUMENT');
	}
	if (type(observer.condition) != 'function' || type(runtime.clock?.set_timeout) != 'function') return;
	let attempts = 0;
	function poll() {
		if (!current()) return;
		attempts++;
		let present = observer.condition();
		if (type(present) != 'bool') return;
		if (present != monitor.present) { enqueue(present); return; }
		if (attempts < 20) state.timer = runtime.clock.set_timeout(100, poll);
	};
	state.timer = runtime.clock.set_timeout(100, poll);
};

function validate_route_entry(item, adding) {
	let allowed = item?.kind == 'unreachable'
		? { family: true, table: true, kind: true, destination: true, device: true,
			unreachable: true, metric: true, owned: true }
		: { family: true, table: true, kind: true, destination: true, device: true, owned: true };
	if (!exact_fields(item, allowed) || item.owned !== true || !route_matrix(item)) fail('INVALID_ARGUMENT');
};

function validate_rule_entry(item, adding) {
	if (!exact_fields(item, { family: true, priority: true, mark: true, mask: true,
	    table: true, owned: true }) || item.owned !== true || !rule_matrix(item)) fail('INVALID_ARGUMENT');
};

function validate_action_list(values, kind, seen) {
	if (type(values) != 'array' || length(values) > 4) fail('INVALID_ARGUMENT');
	for (let item in values) {
		if (kind == 'route') validate_route_entry(item, true);
		else validate_rule_entry(item, true);
		let canonical = kind == 'route' ? canonical_route(item) : canonical_rule(item);
		let key = kind + ':' + entry_key(canonical);
		let slot = kind == 'route' ? 'route-slot:' + item.family + ':' + item.table :
			'rule-slot:' + item.family + ':' + item.priority + ':' + item.table;
		if (seen[key] || seen[slot]) fail('INVALID_ARGUMENT');
		seen[key] = true;
		seen[slot] = true;
	}
};

function actions_contain(values, wanted, kind) {
	for (let item in values)
		if (contains_entry([ kind == 'route' ? canonical_route(item) : canonical_rule(item) ], wanted))
			return true;
	return false;
};

function validate_plan(runtime, changes) {
	if (!exact_fields(changes, { conflicts: true, add_routes: true, remove_routes: true,
	    add_rules: true, remove_rules: true, monitor: true, ownership: true }) ||
	    type(changes.conflicts) != 'array' || length(changes.conflicts) > 16 ||
	    type(changes.add_routes) != 'array' || type(changes.remove_routes) != 'array' ||
	    type(changes.add_rules) != 'array' || type(changes.remove_rules) != 'array' ||
	    !exact_fields(changes.monitor, { enabled: true, present: true }) ||
	    type(changes.monitor.enabled) != 'bool' || type(changes.monitor.present) != 'bool' ||
	    !exact_fields(changes.ownership, { before: true, after: true }) ||
	    !exact_fields(changes.ownership.before, { routes: true, rules: true }) ||
	    !exact_fields(changes.ownership.after, { routes: true, rules: true }))
		fail('INVALID_ARGUMENT');
	for (let conflict in changes.conflicts) if (type(conflict) != 'object') fail('INVALID_ARGUMENT');
	for (let phase in [ changes.ownership.before, changes.ownership.after ])
		if (validate_manifest_entries(phase.routes, 'route') == null ||
		    validate_manifest_entries(phase.rules, 'rule') == null) fail('INVALID_ARGUMENT');
	let add_routes_seen = {}, remove_routes_seen = {}, add_rules_seen = {}, remove_rules_seen = {};
	validate_action_list(changes.add_routes, 'route', add_routes_seen);
	validate_action_list(changes.remove_routes, 'route', remove_routes_seen);
	validate_action_list(changes.add_rules, 'rule', add_rules_seen);
	validate_action_list(changes.remove_rules, 'rule', remove_rules_seen);
	for (let item in changes.add_routes)
		if (remove_routes_seen['route:' + entry_key(canonical_route(item))]) fail('INVALID_ARGUMENT');
	for (let item in changes.add_rules)
		if (remove_rules_seen['rule:' + entry_key(canonical_rule(item))]) fail('INVALID_ARGUMENT');
	for (let item in changes.add_routes)
		if (!contains_entry(changes.ownership.after.routes, canonical_route(item))) fail('INVALID_ARGUMENT');
	for (let item in changes.add_rules)
		if (!contains_entry(changes.ownership.after.rules, canonical_rule(item))) fail('INVALID_ARGUMENT');
	for (let item in changes.remove_routes)
		if (!contains_entry(changes.ownership.before.routes, canonical_route(item))) fail('INVALID_ARGUMENT');
	for (let item in changes.remove_rules)
		if (!contains_entry(changes.ownership.before.rules, canonical_rule(item))) fail('INVALID_ARGUMENT');
	if (!length(changes.conflicts)) {
		for (let item in changes.ownership.after.routes)
			if (!contains_entry(changes.ownership.before.routes, item) &&
			    !actions_contain(changes.add_routes, item, 'route')) fail('INVALID_ARGUMENT');
		for (let item in changes.ownership.after.rules)
			if (!contains_entry(changes.ownership.before.rules, item) &&
			    !actions_contain(changes.add_rules, item, 'rule')) fail('INVALID_ARGUMENT');
	}
	if (changes.monitor.enabled) {
		let observer = runtime.observers?.routing;
		if (type(observer?.subscribe) != 'function' || type(observer.condition) != 'function' ||
		    type(observer.reconcile) != 'function' || type(runtime.clock?.set_timeout) != 'function')
			fail('INVALID_ARGUMENT');
	}
};

function persist_manifest(runtime, routes, rules) {
	storage.write_json(runtime, MANIFEST_PATH, manifest_document(routes, rules), 0o600);
};

export function apply(runtime, changes) {
	validate_plan(runtime, changes);
	disarm_tun_monitor(runtime);
	if (length(changes.conflicts)) fail('INTERNAL');
	let current_ownership = load_manifest(runtime);
	let current_routes = current_ownership.trusted ? current_ownership.routes : [];
	let current_rules = current_ownership.trusted ? current_ownership.rules : [];
	if (!same_entries(current_routes, changes.ownership.before.routes) ||
	    !same_entries(current_rules, changes.ownership.before.rules)) fail('INVALID_ARGUMENT');
	let journal_routes = union_entries(changes.ownership.before.routes, changes.ownership.after.routes);
	let journal_rules = union_entries(changes.ownership.before.rules, changes.ownership.after.rules);
	persist_manifest(runtime, journal_routes, journal_rules);
	try {
		for (let item in changes.add_routes) run(runtime, route_args('replace', item));
		for (let item in changes.add_rules) run(runtime, rule_args('add', item));
		for (let item in changes.remove_rules) run(runtime, rule_args('del', item));
		for (let item in changes.remove_routes) run(runtime, route_args('del', item));
		persist_manifest(runtime, changes.ownership.after.routes, changes.ownership.after.rules);
		arm_tun_monitor(runtime, changes.monitor);
	}
	catch (error) {
		disarm_tun_monitor(runtime);
		fail(error?.code ?? error?.message ?? 'INTERNAL');
	}
	return { changed: length(changes.add_routes) + length(changes.remove_rules) +
		length(changes.add_rules) + length(changes.remove_routes) > 0 };
};

export function cleanup(runtime, current) {
	current ??= observe(runtime);
	if (type(current?.rules) != 'array' || type(current?.routes) != 'array') fail('INVALID_ARGUMENT');
	disarm_tun_monitor(runtime);
	for (let item in [ ...current.rules, ...current.routes ]) if (item.ambiguous) fail('INTERNAL');
	let ownership = load_manifest(runtime);
	let remove_rules = [], remove_routes = [];
	for (let item in current.rules) if (item.owned) {
		let action = rule_action(item), canonical = canonical_rule(item);
		if (!ownership.trusted || action == null || !contains_entry(ownership.rules, canonical))
			fail('INVALID_ARGUMENT');
		validate_rule_entry(action, false);
		push(remove_rules, action);
	}
	for (let item in current.routes) if (item.owned) {
		let action = route_action(item), canonical = canonical_route(item);
		if (!ownership.trusted || action == null || !contains_entry(ownership.routes, canonical))
			fail('INVALID_ARGUMENT');
		validate_route_entry(action, false);
		push(remove_routes, action);
	}
	if (!ownership.trusted) return { clean: true };
	// Re-persist exact deletion intent before the first rule is removed. On a
	// partial failure the old tuples remain authorized for a safe retry.
	persist_manifest(runtime, ownership.routes, ownership.rules);
	for (let item in remove_rules) run(runtime, rule_args('del', item));
	for (let item in remove_routes) run(runtime, route_args('del', item));
	persist_manifest(runtime, [], []);
	return { clean: true };
};
