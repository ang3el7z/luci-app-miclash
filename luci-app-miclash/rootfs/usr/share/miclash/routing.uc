import { fail } from 'miclash.errors';

// Deliberately outside iproute2's named protocol set so JSON observation
// remains a stable numeric ownership tag on OpenWrt and upstream iproute2.
const OWNER_PROTOCOL = 242;
const MAX_CAPTURE = 65536;
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
	let pipe = popen(command + ' 2>/dev/null', 'r');
	if (pipe == null) fail('INTERNAL');
	let output = '', failed = false;
	while (true) {
		let chunk;
		try { chunk = pipe.read(4096); } catch (error) { failed = true; break; }
		if (type(chunk) != 'string') { failed = true; break; }
		if (!length(chunk)) break;
		if (length(output) + length(chunk) > MAX_CAPTURE) { failed = true; break; }
		output += chunk;
	}
	let closed = null;
	try { closed = pipe.close(); } catch (error) { failed = true; }
	// `ip -j route show table N` emits valid `[]` while returning non-zero when
	// a table does not exist. Treat capture integrity as authoritative here;
	// parsers still reject malformed or ambiguous output before any mutation.
	let succeeded = closed === 0 || closed === true;
	let route_absence = index(command, ' route show ') >= 0 && trim(output) == '[]';
	let link_absence = index(command, 'ip -j link show ') == 0 && closed === 1 && !length(trim(output));
	let expected_absence = route_absence || link_absence;
	if (failed) fail('INTERNAL');
	if (!succeeded && !expected_absence) {
		if (allow_command_failure) return null;
		fail('INTERNAL');
	}
	if (link_absence) return '[]';
	return output;
};

function number(value) {
	if (type(value) == 'int') return value;
	if (type(value) == 'string' && match(value, /^[0-9]+$/)) return int(value);
	return null;
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
		let priority = number(item.priority), table = number(item.table), mark = normalize_mark(item.fwmark);
		if (!has([ 1000, 1001 ], priority) && !has([ 100, 101 ], table)) continue;
		if (priority == null || table == null || mark == null) {
			push(values, { family, ambiguous: true, owned: false }); continue;
		}
		let mask = normalize_mask(item.fwmask);
		if (mask == null) { push(values, { family, ambiguous: true, owned: false }); continue; }
		push(values, { family, priority, mark, mask, table,
			owned: number(item.protocol) == OWNER_PROTOCOL });
	}
	return values;
};

function json_routes(text, family, requested_table) {
	let document = json(text);
	if (type(document) != 'array') fail('INVALID_ARGUMENT');
	let values = [];
	for (let item in document) {
		let table = number(item.table) ?? requested_table;
		if (table != requested_table) { push(values, { family, table, ambiguous: true, owned: false }); continue; }
		let kind = item.type == 'local' ? 'local' : item.type == 'unreachable' ? 'unreachable' : 'unicast';
		let destination = item.dst ?? 'default';
		if (destination != 'default') { push(values, { family, table, ambiguous: true, owned: false }); continue; }
		let value = { family, table, kind, destination, device: item.dev ?? null,
			owned: number(item.protocol) == OWNER_PROTOCOL };
		if (kind == 'unreachable') { value.unreachable = true; value.metric = number(item.metric); }
		push(values, value);
	}
	return values;
};

function text_rules(text, family) {
	let values = [];
	for (let line in split(text, '\n')) {
		if (!length(trim(line))) continue;
		let found = match(trim(line), /^([0-9]+):[ \t]+from all fwmark (0x[0-9a-fA-F]+)(\/0x[0-9a-fA-F]+)? (lookup|table) ([0-9]+)( (proto|protocol) ([0-9]+))?$/);
		if (!found) {
			if (match(line, /^(1000|1001):/) || match(line, /(lookup|table) (100|101)([ \t]|$)/))
				push(values, { family, ambiguous: true, owned: false });
			continue;
		}
		let mask = found[3] == null ? '0xffffffff' : normalize_mask(substr(found[3], 1));
		push(values, { family, priority: int(found[1]), mark: lc(found[2]), mask, table: int(found[5]),
			owned: found[8] != null && int(found[8]) == OWNER_PROTOCOL });
	}
	return values;
};

function text_routes(text, family, table) {
	let values = [];
	for (let line in split(text, '\n')) {
		line = trim(line);
		if (!length(line)) continue;
		let local = match(line, /^local default dev ([A-Za-z0-9_.:-]+)( proto ([0-9]+))?.*$/);
		let unreachable = match(line, /^unreachable default( proto ([0-9]+))?( metric ([0-9]+))?.*$/);
		let unicast = match(line, /^default dev ([A-Za-z0-9_.:-]+)( proto ([0-9]+))?.*$/);
		if (local) push(values, { family, table, kind: 'local', destination: 'default', device: local[1],
			owned: local[3] != null && int(local[3]) == OWNER_PROTOCOL });
		else if (unreachable) push(values, { family, table, kind: 'unreachable', destination: 'default', device: null,
			unreachable: true, metric: unreachable[5] == null ? null : int(unreachable[5]),
			owned: unreachable[3] != null && int(unreachable[3]) == OWNER_PROTOCOL });
		else if (unicast) push(values, { family, table, kind: 'unicast', destination: 'default', device: unicast[1],
			owned: unicast[3] != null && int(unicast[3]) == OWNER_PROTOCOL });
		else push(values, { family, table, ambiguous: true, owned: false });
	}
	return values;
};

function capture_parsed(runtime, json_command, text_command, parser_json, parser_text) {
	let captured = fixed_capture(runtime, json_command, true);
	if (captured != null) try { return parser_json(captured); } catch (error) {}
	return parser_text(fixed_capture(runtime, text_command, false));
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
	return { routes, rules, interfaces: { 'clash-tun': length(links) > 0 } };
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
	let result = { remove_rules: [], remove_routes: [], add_routes: [], add_rules: [], conflicts: [],
		monitor: { enabled: wanted.tun_mode === true, present: wanted.tun_present === true } };
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
		if (!keep) push(result.remove_rules, existing);
	}
	for (let existing in observed.routes) if (existing.owned) {
		let keep = false, replaced = false;
		for (let item in wanted.routes) {
			keep = keep || same_route(item, existing);
			replaced = replaced || (item.family == existing.family && item.table == existing.table);
		}
		if (!keep && !replaced) push(result.remove_routes, existing);
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
	if (state == null) return;
	state.active = false;
	if (type(state.subscription) == 'function') state.subscription();
	else if (type(state.subscription?.remove) == 'function') state.subscription.remove();
	else if (type(state.subscription?.unsubscribe) == 'function') state.subscription.unsubscribe();
	else if (type(state.subscription?.cancel) == 'function') state.subscription.cancel();
	if (type(state.timer?.cancel) == 'function') state.timer.cancel();
	runtime.routing_monitor = null;
};

function arm_tun_monitor(runtime, monitor) {
	disarm_tun_monitor(runtime);
	if (!monitor?.enabled) return;
	let observer = runtime.observers?.routing;
	let state = { active: true, subscription: null, timer: null };
	runtime.routing_monitor = state;
	let reconcile = (present) => {
		if (state.active && type(present) == 'bool' && present != monitor.present)
			observer.reconcile(present);
	};
	if (type(observer.subscribe) == 'function')
		state.subscription = observer.subscribe((event) => {
			if (!state.active) return;
			if (event?.interface != 'clash-tun') return;
			if (event.action == 'add' || event.action == 'ifup') reconcile(true);
			else if (event.action == 'remove' || event.action == 'ifdown') reconcile(false);
		});
	let cancellable = type(state.subscription) == 'function' ||
		type(state.subscription?.remove) == 'function' || type(state.subscription?.unsubscribe) == 'function' ||
		type(state.subscription?.cancel) == 'function';
	if (!cancellable) {
		state.active = false;
		runtime.routing_monitor = null;
		fail('INVALID_ARGUMENT');
	}
	if (type(observer.condition) != 'function' || type(runtime.clock?.set_timeout) != 'function') return;
	let attempts = 0;
	function poll() {
		if (!state.active) return;
		attempts++;
		let present = observer.condition();
		if (type(present) != 'bool') return;
		if (present != monitor.present) { observer.reconcile(present); return; }
		if (attempts < 20) state.timer = runtime.clock.set_timeout(100, poll);
	};
	state.timer = runtime.clock.set_timeout(100, poll);
};

function validate_route_entry(item, adding) {
	if (type(item) != 'object' || !valid_family(item.family) || item.owned !== true ||
	    item.destination != 'default' || !has([ 100, 101 ], item.table) ||
	    !has([ 'local', 'unicast', 'unreachable' ], item.kind)) fail('INVALID_ARGUMENT');
	if (item.kind == 'local' && item.device != 'lo') fail('INVALID_ARGUMENT');
	if (item.kind == 'unicast' && item.device != 'clash-tun') fail('INVALID_ARGUMENT');
	if (item.kind == 'unreachable' && (item.device != null || item.metric != 42760)) fail('INVALID_ARGUMENT');
	if (adding && item.table == 101 && item.kind == 'local') fail('INVALID_ARGUMENT');
};

function validate_rule_entry(item, adding) {
	if (type(item) != 'object' || !valid_family(item.family) || item.owned !== true ||
	    !match(item.mark ?? '', /^0x[0-9a-f]+$/) || !match(item.mask ?? '', /^0x[0-9a-f]+$/) ||
	    !has([ 100, 101 ], item.table) || !has([ 1000, 1001 ], item.priority)) fail('INVALID_ARGUMENT');
	if (adding && !((item.table == 100 && item.priority == 1000 && item.mark == '0x1' && item.mask == '0xffffffff') ||
	    (item.table == 101 && item.priority == 1001 && item.mark == '0x3' && item.mask == '0xffffffff')))
		fail('INVALID_ARGUMENT');
};

function validate_plan(runtime, changes) {
	if (type(changes) != 'object' || type(changes.conflicts) != 'array' ||
	    type(changes.add_routes) != 'array' || type(changes.remove_routes) != 'array' ||
	    type(changes.add_rules) != 'array' || type(changes.remove_rules) != 'array' ||
	    type(changes.monitor) != 'object' || type(changes.monitor.enabled) != 'bool' ||
	    type(changes.monitor.present) != 'bool') fail('INVALID_ARGUMENT');
	for (let item in changes.add_routes) validate_route_entry(item, true);
	for (let item in changes.remove_routes) validate_route_entry(item, false);
	for (let item in changes.add_rules) validate_rule_entry(item, true);
	for (let item in changes.remove_rules) validate_rule_entry(item, false);
	if (changes.monitor.enabled) {
		let observer = runtime.observers?.routing;
		if (type(observer?.subscribe) != 'function' || type(observer.condition) != 'function' ||
		    type(observer.reconcile) != 'function' || type(runtime.clock?.set_timeout) != 'function')
			fail('INVALID_ARGUMENT');
	}
};

export function apply(runtime, changes) {
	validate_plan(runtime, changes);
	if (length(changes.conflicts)) fail('INTERNAL');
	arm_tun_monitor(runtime, changes.monitor);
	try {
		for (let item in changes.add_routes) run(runtime, route_args('replace', item));
		for (let item in changes.add_rules) run(runtime, rule_args('add', item));
		for (let item in changes.remove_rules) run(runtime, rule_args('del', item));
		for (let item in changes.remove_routes) run(runtime, route_args('del', item));
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
	for (let item in current.rules) if (item.owned) validate_rule_entry(item, false);
	for (let item in current.routes) if (item.owned) validate_route_entry(item, false);
	disarm_tun_monitor(runtime);
	for (let item in current.rules) if (item.owned) run(runtime, rule_args('del', item));
	for (let item in current.routes) if (item.owned) run(runtime, route_args('del', item));
	return { clean: true };
};
