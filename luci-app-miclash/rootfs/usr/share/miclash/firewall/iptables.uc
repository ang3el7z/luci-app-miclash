import { fail } from 'miclash.errors';
import { validate, generation, LOCAL4, LOCAL6 } from 'miclash.firewall.common';

const CHAINS = {
	prerouting: 'MCL_AN_PR', output: 'MCL_AN_OU',
	tun_input: 'MCL_AN_TI', tun_forward: 'MCL_AN_TF'
};

const INPUT_LIMITS = { interfaces: 64, servers: 256, fakeip: 256, policies: 128, families: 2 };
const MAX_ESTIMATED_COMMANDS = 1024;
const MAX_COMPILED_ARGV_BYTES = 262144;

function request(command, args, properties) {
	return { command, args: [ ...args ], ...(properties ?? {}) };
};

function validate_bounds(desired) {
	if (type(desired) != 'object') fail('INVALID_ARGUMENT');
	for (let key in [ 'lan', 'wan', 'server_ips', 'fakeip_cidrs', 'device_policies', 'ip_families' ])
		if (type(desired[key]) != 'array') fail('INVALID_ARGUMENT');
	if (length(desired.lan) > INPUT_LIMITS.interfaces || length(desired.wan) > INPUT_LIMITS.interfaces ||
	    length(desired.server_ips) > INPUT_LIMITS.servers || length(desired.fakeip_cidrs) > INPUT_LIMITS.fakeip ||
	    length(desired.device_policies) > INPUT_LIMITS.policies || length(desired.ip_families) > INPUT_LIMITS.families)
		fail('INVALID_ARGUMENT');
	if (desired.previous_ip_families != null &&
	    (type(desired.previous_ip_families) != 'array' || length(desired.previous_ip_families) > INPUT_LIMITS.families))
		fail('INVALID_ARGUMENT');
	for (let families in [ desired.ip_families, desired.previous_ip_families ?? [] ]) {
		let seen = {};
		for (let family in families) {
			if (seen[family]) fail('INVALID_ARGUMENT');
			seen[family] = true;
		}
	}
	for (let policy in desired.device_policies)
		if (type(policy) != 'object' || type(policy.id) != 'string' || length(policy.id) > 64)
			fail('INVALID_ARGUMENT');
	let estimate = 200 + length(desired.ip_families) * (length(desired.lan) + length(desired.wan) +
		2 * length(desired.server_ips) + 3 * length(desired.fakeip_cidrs) + 2 * length(desired.device_policies));
	if (estimate > MAX_ESTIMATED_COMMANDS) fail('INVALID_ARGUMENT');
};

function validate_compiled_volume(compiled) {
	let bytes = 0;
	for (let item in [ ...compiled.inventory, ...compiled.rollback, ...compiled.stages.anchors,
		...compiled.stages.prepare, ...compiled.stages.verify_prepared, ...compiled.stages.switch,
		...compiled.stages.verify_active, ...compiled.stages.retire ]) {
		bytes += length(item.command);
		for (let arg in item.args) bytes += length(arg);
		for (let arg in item.on_success ?? []) bytes += length(arg);
		for (let arg in item.on_failure ?? []) bytes += length(arg);
		if (bytes > MAX_COMPILED_ARGV_BYTES) fail('INVALID_ARGUMENT');
	}
};

function add(commands, command, args, properties) {
	push(commands, request(command, args, properties));
};

function selected(desired, family) {
	for (let item in desired.ip_families) if (item == family) return true;
	return false;
};

function in_either(desired, family) {
	if (selected(desired, family)) return true;
	for (let item in desired.previous_ip_families ?? []) if (item == family) return true;
	return false;
};

function same_families(actual, expected) {
	if (length(actual) != length(expected)) return false;
	for (let family in expected) if (index(actual, family) < 0) return false;
	return true;
};

function family_values(values, ipv6) {
	let result = [];
	for (let value in values)
		if ((index(value, ':') >= 0) == ipv6) push(result, value);
	return result;
};

function local_values(ipv6) {
	let values = split(ipv6 ? LOCAL6 : LOCAL4, ', ');
	if (!ipv6) push(values, '255.255.255.255/32');
	return values;
};

function mark(commands, executable, chain, mode, ipv6, prefix) {
	let base = [ '-t', 'mangle', '-A', chain, ...(prefix ?? []) ];
	let local = ipv6 ? '::1' : '127.0.0.1';
	if (mode == 'mixed') {
		add(commands, executable, [ ...base, '-p', 'tcp', '-j', 'TPROXY', '--on-ip', local,
			'--on-port', '7894', '--tproxy-mark', '0x1' ]);
		add(commands, executable, [ ...base, '-p', 'udp', '-j', 'MARK', '--set-mark', '0x3' ]);
	}
	else if (mode == 'tproxy') {
		for (let protocol in [ 'tcp', 'udp' ])
			add(commands, executable, [ ...base, '-p', protocol, '-j', 'TPROXY', '--on-ip', local,
				'--on-port', '7894', '--tproxy-mark', '0x1' ]);
	}
	else {
		for (let protocol in [ 'tcp', 'udp' ])
			add(commands, executable, [ ...base, '-p', protocol, '-j', 'MARK', '--set-mark', '0x1' ]);
	}
};

function initialize_sets(commands, desired, ipv6) {
	let local_set = ipv6 ? 'miclash_local6' : 'miclash_local4';
	let fake_set = ipv6 ? 'clash_fakeip_whitelist6' : 'clash_fakeip_whitelist';
	let fake = family_values(desired.fakeip_cidrs, ipv6);
	add(commands, 'ipset', [ 'create', local_set, 'hash:net', 'family', ipv6 ? 'inet6' : 'inet', '-exist' ]);
	add(commands, 'ipset', [ 'flush', local_set ]);
	if (length(fake)) {
		add(commands, 'ipset', [ 'create', fake_set, 'hash:net', 'family', ipv6 ? 'inet6' : 'inet', '-exist' ]);
		add(commands, 'ipset', [ 'flush', fake_set ]);
		for (let cidr in fake) add(commands, 'ipset', [ 'add', fake_set, cidr, '-exist' ]);
	}
	for (let cidr in local_values(ipv6)) add(commands, 'ipset', [ 'add', local_set, cidr, '-exist' ]);
};

function normalized(desired) {
	let commands = [], ipv6_sets_initialized = false;
	for (let family in [ 'ipv4', 'ipv6' ]) {
		if (!selected(desired, family)) continue;
		let ipv6 = family == 'ipv6';
		let executable = ipv6 ? 'ip6tables' : 'iptables';
		let local_set = ipv6 ? 'miclash_local6' : 'miclash_local4';
		let fake_set = ipv6 ? 'clash_fakeip_whitelist6' : 'clash_fakeip_whitelist';
		let servers = family_values(desired.server_ips, ipv6);
		let fake = family_values(desired.fakeip_cidrs, ipv6);

		if (!ipv6 || !ipv6_sets_initialized) initialize_sets(commands, desired, ipv6);

		for (let chain in [ 'MICLASH_PREROUTING', 'MICLASH_PROXY', 'MICLASH_OUTPUT' ])
			add(commands, executable, [ '-t', 'mangle', '-N', chain ]);
		add(commands, executable, [ '-t', 'mangle', '-A', 'PREROUTING', '-j', 'MICLASH_PREROUTING' ]);
		add(commands, executable, [ '-t', 'mangle', '-A', 'OUTPUT', '-j', 'MICLASH_OUTPUT' ]);

		let interfaces = desired.interface_mode == 'explicit' ? desired.lan : desired.wan;
		for (let interface in interfaces)
			add(commands, executable, [ '-t', 'mangle', '-A', 'MICLASH_PREROUTING', '-i', interface,
				'-j', desired.interface_mode == 'explicit' ? 'MICLASH_PROXY' : 'RETURN' ]);
		if (desired.interface_mode == 'exclude')
			add(commands, executable, [ '-t', 'mangle', '-A', 'MICLASH_PREROUTING', '-j', 'MICLASH_PROXY' ]);

		for (let policy in desired.device_policies) {
			if (policy.action == 'inherit') continue;
			let prefix = [ '-m', 'mac', '--mac-source', policy.mac ];
			if (policy.action == 'block' || policy.action == 'direct')
				add(commands, executable, [ '-t', 'mangle', '-A', 'MICLASH_PROXY', ...prefix,
					'-j', policy.action == 'block' ? 'DROP' : 'RETURN' ]);
			else mark(commands, executable, 'MICLASH_PROXY', desired.proxy_mode, ipv6, prefix);
		}

		add(commands, executable, [ '-t', 'mangle', '-A', 'MICLASH_PROXY', '-m', 'set',
			'--match-set', local_set, 'dst', '-j', 'RETURN' ]);
		if (!desired.guard)
			for (let ip in servers)
				add(commands, executable, [ '-t', 'mangle', '-A', 'MICLASH_PROXY', '-d', ip, '-j', 'RETURN' ]);

		if (length(fake))
			mark(commands, executable, 'MICLASH_PROXY', desired.proxy_mode, ipv6,
				[ '-m', 'set', '--match-set', fake_set, 'dst' ]);
		else {
			if (desired.quic)
				add(commands, executable, [ '-t', 'mangle', '-A', 'MICLASH_PROXY', '-p', 'udp',
					'--dport', '443', '-j', 'DROP' ]);
			mark(commands, executable, 'MICLASH_PROXY', desired.proxy_mode, ipv6, []);
		}

		add(commands, executable, [ '-t', 'mangle', '-A', 'MICLASH_OUTPUT', '-m', 'mark',
			'--mark', '0x0002', '-j', 'RETURN' ]);
		add(commands, executable, [ '-t', 'mangle', '-A', 'MICLASH_OUTPUT', '-m', 'mark',
			'--mark', '0xff00/0xff00', '-j', 'RETURN' ]);
		for (let ip in servers)
			add(commands, executable, [ '-t', 'mangle', '-A', 'MICLASH_OUTPUT', '-d', ip, '-j', 'RETURN' ]);
		if (desired.proxy_mode == 'mixed') {
			add(commands, executable, [ '-t', 'mangle', '-A', 'MICLASH_OUTPUT', '-m', 'mark', '--mark',
				'0x0', '-p', 'tcp', '-j', 'MARK', '--set-mark', '0x1' ]);
			add(commands, executable, [ '-t', 'mangle', '-A', 'MICLASH_OUTPUT', '-m', 'mark', '--mark',
				'0x0', '-p', 'udp', '-j', 'MARK', '--set-mark', '0x3' ]);
		}
		else for (let protocol in [ 'tcp', 'udp' ])
			add(commands, executable, [ '-t', 'mangle', '-A', 'MICLASH_OUTPUT', '-m', 'mark', '--mark',
				'0x0', '-p', protocol, '-j', 'MARK', '--set-mark', '0x1' ]);

		if (!ipv6 && selected(desired, 'ipv6')) {
			initialize_sets(commands, desired, true);
			ipv6_sets_initialized = true;
		}
		if (desired.proxy_mode != 'tproxy') {
			add(commands, executable, [ '-t', 'filter', '-I', 'INPUT', '1', '-i', 'clash-tun', '-j', 'ACCEPT' ]);
			add(commands, executable, [ '-t', 'filter', '-I', 'FORWARD', '1', '-i', 'clash-tun', '-j', 'ACCEPT' ]);
			add(commands, executable, [ '-t', 'filter', '-I', 'FORWARD', '1', '-o', 'clash-tun', '-j', 'ACCEPT' ]);
		}
	}
	return commands;
};

function names(id, ipv6) {
	let digit = ipv6 ? '6' : '4';
	return {
		prerouting: 'MCL_PR_' + id, proxy: 'MCL_PX_' + id, output: 'MCL_OU_' + id,
		tun_input: 'MCL_TI_' + id, tun_forward: 'MCL_TF_' + id,
		local: 'MCL_L' + digit + '_' + id, fake: 'MCL_F' + digit + '_' + id
	};
};

function replace_arg(value, map) { return map[value] ?? value; };

function inventory_commands(id, family, action) {
	let ipv6 = family == 'ipv6', executable = ipv6 ? 'ip6tables' : 'iptables', n = names(id, ipv6), commands = [];
	if (action == 'create') {
		for (let item in [ [ 'mangle', n.prerouting ], [ 'mangle', n.proxy ], [ 'mangle', n.output ],
			[ 'filter', n.tun_input ], [ 'filter', n.tun_forward ] ])
			add(commands, executable, [ '-t', item[0], '-N', item[1] ]);
		add(commands, 'ipset', [ 'create', n.local, 'hash:net', 'family', ipv6 ? 'inet6' : 'inet', '-exist' ]);
		add(commands, 'ipset', [ 'create', n.fake, 'hash:net', 'family', ipv6 ? 'inet6' : 'inet', '-exist' ]);
	}
	else {
		for (let item in [ [ 'mangle', n.prerouting ], [ 'mangle', n.proxy ], [ 'mangle', n.output ],
			[ 'filter', n.tun_input ], [ 'filter', n.tun_forward ] ]) {
			if (action == 'retire' || action == 'rollback') {
				add(commands, executable, [ '-t', item[0], '-L', item[1] ], {
					on_success: [ '-t', item[0], '-F', item[1] ], tolerate_failure: true
				});
				add(commands, executable, [ '-t', item[0], '-L', item[1] ], {
					on_success: [ '-t', item[0], '-X', item[1] ], tolerate_failure: true
				});
			}
			else {
				add(commands, executable, [ '-t', item[0], '-F', item[1] ], { tolerate_failure: true });
				add(commands, executable, [ '-t', item[0], '-X', item[1] ], { tolerate_failure: true });
			}
		}
		for (let set in [ n.local, n.fake ])
			if (action == 'retire' || action == 'rollback')
				add(commands, 'ipset', [ 'list', set ], { on_success: [ 'destroy', set ], tolerate_failure: true });
			else add(commands, 'ipset', [ 'destroy', set ], { tolerate_failure: true });
	}
	return commands;
};

function anchors(desired) {
	let commands = [];
	for (let family in [ 'ipv4', 'ipv6' ]) {
		if (!in_either(desired, family)) continue;
		let executable = family == 'ipv6' ? 'ip6tables' : 'iptables';
		for (let item in [ [ 'mangle', CHAINS.prerouting, 'PREROUTING' ], [ 'mangle', CHAINS.output, 'OUTPUT' ],
			[ 'filter', CHAINS.tun_input, 'INPUT' ], [ 'filter', CHAINS.tun_forward, 'FORWARD' ] ]) {
			add(commands, executable, [ '-t', item[0], '-N', item[1] ], { tolerate_failure: true });
			add(commands, executable, [ '-t', item[0], '-C', item[2], '-j', item[1] ], {
				on_failure: [ '-t', item[0], '-A', item[2], '-j', item[1] ]
			});
		}
	}
	return commands;
};

function staged(desired, model, id) {
	let stages = { anchors: anchors(desired), prepare: [], verify_prepared: [], switch: [],
		verify_active: [], retire: [] }, rollback = [];
	if (desired.previous_generation == id) {
		for (let family in [ 'ipv4', 'ipv6' ]) {
			if (!selected(desired, family)) continue;
			let ipv6 = family == 'ipv6', executable = ipv6 ? 'ip6tables' : 'iptables', n = names(id, ipv6);
			for (let item in [ [ 'mangle', CHAINS.prerouting, n.prerouting ], [ 'mangle', CHAINS.output, n.output ],
				[ 'filter', CHAINS.tun_input, n.tun_input ], [ 'filter', CHAINS.tun_forward, n.tun_forward ] ])
				add(stages.verify_active, executable, [ '-t', item[0], '-C', item[1], '-j', item[2] ]);
		}
		return { stages, rollback };
	}
	for (let family in [ 'ipv4', 'ipv6' ]) {
		if (!in_either(desired, family)) continue;
		let ipv6 = family == 'ipv6', executable = ipv6 ? 'ip6tables' : 'iptables', n = names(id, ipv6);
		if (!selected(desired, family)) {
			for (let item in [ [ 'mangle', CHAINS.prerouting ], [ 'mangle', CHAINS.output ],
				[ 'filter', CHAINS.tun_input ], [ 'filter', CHAINS.tun_forward ] ]) {
				add(stages.switch, executable, [ '-t', item[0], '-F', item[1] ]);
				add(stages.verify_active, executable, [ '-t', item[0], '-L', item[1] ], { expect_empty: true });
			}
			if (desired.previous_generation != null)
				for (let old in inventory_commands(desired.previous_generation, family, 'retire')) push(stages.retire, old);
			continue;
		}
		let old_local = ipv6 ? 'miclash_local6' : 'miclash_local4';
		let old_fake = ipv6 ? 'clash_fakeip_whitelist6' : 'clash_fakeip_whitelist';
		let map = { MICLASH_PREROUTING: n.prerouting, MICLASH_PROXY: n.proxy,
			MICLASH_OUTPUT: n.output };
		map[old_local] = n.local; map[old_fake] = n.fake;
		for (let item in inventory_commands(id, family, 'create')) push(stages.prepare, item);
		for (let item in inventory_commands(id, family, 'rollback')) push(rollback, item);
		for (let item in [ [ 'mangle', n.prerouting ], [ 'mangle', n.proxy ], [ 'mangle', n.output ],
			[ 'filter', n.tun_input ], [ 'filter', n.tun_forward ] ])
			add(stages.verify_prepared, executable, [ '-t', item[0], '-L', item[1] ]);
		for (let set in [ n.local, n.fake ]) add(stages.verify_prepared, 'ipset', [ 'list', set ]);

		for (let item in model) {
			if (item.command == 'ipset') {
				if (item.args[0] != 'add') continue;
				let set = map[item.args[1]];
				if (set == null) continue;
				add(stages.prepare, 'ipset', [ 'add', set, item.args[2], '-exist' ]);
				add(stages.verify_prepared, 'ipset', [ 'test', set, item.args[2] ]);
				continue;
			}
			if (item.command != executable) continue;
			let table = item.args[1], operation = item.args[2], chain = item.args[3];
			if (operation == '-N' || (operation == '-A' && (chain == 'PREROUTING' || chain == 'OUTPUT'))) continue;
			let args = [ ...item.args ];
			if (operation == '-I' && (chain == 'INPUT' || chain == 'FORWARD')) {
				args[2] = '-A';
				args[3] = chain == 'INPUT' ? n.tun_input : n.tun_forward;
				splice(args, 4, 1);
			}
			else {
				if (map[chain] == null) continue;
				args[3] = map[chain];
			}
			for (let i = 0; i < length(args); i++) args[i] = replace_arg(args[i], map);
			add(stages.prepare, executable, args);
			let check = [ ...args ]; check[2] = '-C';
			add(stages.verify_prepared, executable, check);
		}

		for (let item in [ [ 'mangle', CHAINS.prerouting, n.prerouting ], [ 'mangle', CHAINS.output, n.output ],
			[ 'filter', CHAINS.tun_input, n.tun_input ], [ 'filter', CHAINS.tun_forward, n.tun_forward ] ]) {
			if (desired.previous_generation != null && desired.previous_generation != id) {
				let old = names(desired.previous_generation, ipv6);
				let old_target = item[1] == CHAINS.prerouting ? old.prerouting : item[1] == CHAINS.output ? old.output :
					item[1] == CHAINS.tun_input ? old.tun_input : old.tun_forward;
				add(stages.switch, executable, [ '-t', item[0], '-C', item[1], '-j', old_target ], {
					on_success: [ '-t', item[0], '-R', item[1], '1', '-j', item[2] ],
					on_failure: [ '-t', item[0], '-A', item[1], '-j', item[2] ]
				});
			}
			else add(stages.switch, executable, [ '-t', item[0], '-A', item[1], '-j', item[2] ]);
			add(stages.verify_active, executable, [ '-t', item[0], '-C', item[1], '-j', item[2] ]);
		}
		if (desired.previous_generation != null && desired.previous_generation != id)
			for (let item in inventory_commands(desired.previous_generation, family, 'retire')) push(stages.retire, item);
		if (desired.previous_generation == null) {
			for (let legacy in [ [ 'PREROUTING', 'MICLASH_PREROUTING' ], [ 'OUTPUT', 'MICLASH_OUTPUT' ] ])
				add(stages.switch, executable, [ '-t', 'mangle', '-C', legacy[0], '-j', legacy[1] ], {
					on_success: [ '-t', 'mangle', '-D', legacy[0], '-j', legacy[1] ], tolerate_failure: true
				});
		}
	}
	return { stages, rollback };
};

function canonical_desired(desired, id) {
	let policies = [];
	for (let policy in desired.device_policies)
		push(policies, { id: policy.id, mac: policy.mac, action: policy.action });
	return {
		proxy_mode: desired.proxy_mode, interface_mode: desired.interface_mode,
		lan: [ ...desired.lan ], wan: [ ...desired.wan ], guard: desired.guard, quic: desired.quic,
		server_ips: [ ...desired.server_ips ], fakeip_cidrs: [ ...desired.fakeip_cidrs ],
		device_policies: policies, ip_families: [ ...desired.ip_families ], generation: id,
		previous_generation: desired.previous_generation ?? null,
		previous_ip_families: [ ...(desired.previous_ip_families ??
			(desired.previous_generation != null ? desired.ip_families : [])) ]
	};
};

export function compile(desired) {
	validate_bounds(desired);
	validate(desired);
	if (desired.previous_ip_families != null) {
		if (type(desired.previous_ip_families) != 'array') fail('INVALID_ARGUMENT');
		for (let family in desired.previous_ip_families)
			if (family != 'ipv4' && family != 'ipv6') fail('INVALID_ARGUMENT');
	}
	let model = normalized(desired), id = generation(desired, sprintf('%J', model));
	let canonical = canonical_desired(desired, id);
	if (canonical.previous_generation == id &&
	    !same_families(canonical.previous_ip_families, canonical.ip_families)) fail('INVALID_ARGUMENT');
	let transaction = staged(canonical, model, id);
	let inventory = length(transaction.stages.prepare) ? [ ...transaction.stages.prepare ] :
		[ ...staged({ ...canonical, previous_generation: null, previous_ip_families: [] }, model, id).stages.prepare ];
	let compiled = { generation: id, previous_generation: desired.previous_generation ?? null,
		model: { schema_version: 1, normalized: model }, stages: transaction.stages,
		rollback: transaction.rollback, inventory, desired: canonical };
	validate_compiled_volume(compiled);
	return compiled;
};

function anchor_generation(text, chain, target_prefix) {
	let chain_seen = 0, rule_seen = 0, generation = null;
	let rule_prefix = '-A ' + chain + ' ', jump_prefix = '-j ' + target_prefix;
	for (let raw in split(text ?? '', '\n')) {
		let line = trim(raw);
		if (substr(line, 0, length(':' + chain + ' - [')) == ':' + chain + ' - [' &&
		    match(line, /\[[0-9]+:[0-9]+\]$/)) {
			chain_seen++;
			continue;
		}
		if (substr(line, 0, length(rule_prefix)) == rule_prefix) {
			rule_seen++;
			let body = substr(line, length(rule_prefix));
			if (substr(body, 0, length(jump_prefix)) != jump_prefix) return null;
			let id = substr(body, length(jump_prefix));
			if (!match(id, /^[0-9a-f]{12}$/) || generation != null) return null;
			generation = id;
		}
	}
	if (chain_seen == 0 && rule_seen == 0) return '-';
	if (chain_seen != 1 || rule_seen > 1) return null;
	return rule_seen == 0 ? '' : generation;
};

function count_line(text, wanted) {
	let count = 0;
	for (let raw in split(text ?? '', '\n')) if (trim(raw) == wanted) count++;
	return count;
};

function count_target(text, chain, target) {
	let count = 0, prefix = '-A ' + chain + ' ';
	for (let raw in split(text ?? '', '\n')) {
		let line = trim(raw);
		if (substr(line, 0, length(prefix)) == prefix &&
		    substr(line, -length(' -j ' + target)) == ' -j ' + target) count++;
	}
	return count;
};

function exact_position(text, wanted) {
	let position = 0;
	for (let raw in split(text ?? '', '\n')) {
		let line = trim(raw);
		if (substr(line, 0, 3) == '-A ') position++;
		if (line == wanted) return position;
	}
	return null;
};

function guard_order_valid(text) {
	let guard = '-A FORWARD -j MICLASH_GUARD_FORWARD';
	let owned = '-A FORWARD -j ' + CHAINS.tun_forward;
	let guard_exact = count_line(text, guard), owned_exact = count_line(text, owned);
	if (count_target(text, 'FORWARD', 'MICLASH_GUARD_FORWARD') != guard_exact || guard_exact > 1 ||
	    count_target(text, 'FORWARD', CHAINS.tun_forward) != owned_exact || owned_exact > 1) return false;
	if (guard_exact == 1 && owned_exact == 1)
		return exact_position(text, guard) < exact_position(text, owned);
	return true;
};

function guard_transition_valid(text) {
	let guard = '-A FORWARD -j MICLASH_GUARD_FORWARD', owned = '-A FORWARD -j ' + CHAINS.tun_forward;
	if (count_line(text, guard) != 1 || count_target(text, 'FORWARD', 'MICLASH_GUARD_FORWARD') != 1 ||
	    count_line(text, owned) != 2 || count_target(text, 'FORWARD', CHAINS.tun_forward) != 2) return false;
	let positions = [], position = 0, guard_position = null;
	for (let raw in split(text, '\n')) {
		let line = trim(raw);
		if (substr(line, 0, 3) != '-A ') continue;
		position++;
		if (line == guard) guard_position = position;
		if (line == owned) push(positions, position);
	}
	return guard_position != null && positions[0] < guard_position && guard_position < positions[1];
};

function fixed_capture(runtime, executable, table) {
	const MAX_CAPTURE = 262144;
	let fixed = null;
	if ((executable == 'iptables-save' || executable == 'ip6tables-save') &&
	    (table == 'mangle' || table == 'filter')) fixed = executable + ' -t ' + table;
	else if (executable == 'ipset' && table == 'save') fixed = 'ipset save';
	else fail('INVALID_ARGUMENT');
	let popen = runtime.fs?.popen ?? require('fs').popen;
	if (type(popen) != 'function') fail('INTERNAL');
	let pipe = popen(fixed, 'r');
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
	if (failed || (closed !== 0 && closed !== true)) fail('INTERNAL');
	return output;
};

function output_or_capture(runtime, result, executable, table) {
	if (result.code != 0) return null;
	return type(result.stdout) == 'string' ? result.stdout : fixed_capture(runtime, executable, table);
};

function ensure_guard_order(runtime, families) {
	for (let family in families) {
		let executable = family == 'ipv6' ? 'ip6tables' : 'iptables', save = executable + '-save';
		let result = runtime.process.run({ command: save, args: [ '-t', 'filter' ] });
		let output = output_or_capture(runtime, result, save, 'filter');
		if (output == null || !guard_order_valid(output)) {
			let guard = '-A FORWARD -j MICLASH_GUARD_FORWARD';
			let owned = '-A FORWARD -j ' + CHAINS.tun_forward;
			if (output == null || count_line(output, guard) != 1 || count_line(output, owned) != 1 ||
			    count_target(output, 'FORWARD', 'MICLASH_GUARD_FORWARD') != 1 ||
			    count_target(output, 'FORWARD', CHAINS.tun_forward) != 1 ||
			    exact_position(output, owned) > exact_position(output, guard)) fail('INTERNAL');
			if (runtime.process.run({ command: executable,
				args: [ '-t', 'filter', '-A', 'FORWARD', '-j', CHAINS.tun_forward ] }).code != 0) fail('INTERNAL');
			let transitional = runtime.process.run({ command: save, args: [ '-t', 'filter' ] });
			let transitional_output = null;
			try { transitional_output = output_or_capture(runtime, transitional, save, 'filter'); } catch (error) {}
			if (transitional_output == null || !guard_transition_valid(transitional_output)) return false;
			if (runtime.process.run({ command: executable,
				args: [ '-t', 'filter', '-D', 'FORWARD', '-j', CHAINS.tun_forward ] }).code != 0) return false;
			let verified = runtime.process.run({ command: save, args: [ '-t', 'filter' ] });
			let verified_output = null;
			try { verified_output = output_or_capture(runtime, verified, save, 'filter'); } catch (error) {}
			if (verified_output == null || !guard_order_valid(verified_output)) return false;
		}
	}
	return true;
};

function normalized_token(value) {
	if (match(value, /\/32$/) && index(value, '.') >= 0) return substr(value, 0, length(value) - 3);
	if (match(value, /\/128$/) && index(value, ':') >= 0) return substr(value, 0, length(value) - 4);
	if (match(value, /\/0xffffffff$/)) return substr(value, 0, length(value) - 11);
	if (match(value, /^0x0+[0-9A-Fa-f]+$/)) {
		let digits = substr(value, 2);
		while (length(digits) > 1 && substr(digits, 0, 1) == '0') digits = substr(digits, 1);
		return '0x' + lc(digits);
	}
	return value;
};

function normalized_rule(fields) {
	let head = [ fields[0], fields[1] ], matches = [], target = [], i = 2, in_target = false;
	while (i < length(fields)) {
		let field = fields[i] == '--set-xmark' ? '--set-mark' : fields[i];
		if (field == '-j') { in_target = true; push(target, '-j ' + fields[i + 1]); i += 2; continue; }
		if (field == '-m' && (fields[i + 1] == 'udp' || fields[i + 1] == 'tcp')) { i += 2; continue; }
		let width = field == '--match-set' ? 3 : 2;
		let unit = field;
		for (let offset = 1; offset < width && i + offset < length(fields) && fields[i + offset] != '-j'; offset++)
			unit += ' ' + normalized_token(fields[i + offset]);
		push(in_target ? target : matches, unit);
		i += width;
	}
	return join(' ', [ ...head, ...sort(matches), ...sort(target) ]);
};

function sorted_json(values) { return sprintf('%J', sort(values)); };

function verdict(fields) {
	for (let i = 0; i + 1 < length(fields); i++)
		if (fields[i] == '-j' || fields[i] == '--jump' || fields[i] == '-g' || fields[i] == '--goto')
			return { kind: fields[i] == '-g' || fields[i] == '--goto' ? 'goto' : 'jump', target: fields[i + 1] };
	return null;
};

function verify_generation(runtime, compiled, active) {
	let suffix = '_' + compiled.generation, expected_chains = {}, expected_rules = {};
	let expected_sets = [], expected_members = {}, expected_set_schema = {}, expected_edges = {}, owned_targets = {};
	for (let item in compiled.inventory) {
		if (item.command == 'iptables' || item.command == 'ip6tables') {
			let key = item.command + '-save:' + item.args[1];
			expected_chains[key] ??= []; expected_rules[key] ??= {};
			if (item.args[2] == '-N') push(expected_chains[key], item.args[3]);
			else if (item.args[2] == '-A') {
				let fields = [];
				for (let i = 2; i < length(item.args); i++) push(fields, item.args[i]);
				expected_rules[key][item.args[3]] ??= [];
				push(expected_rules[key][item.args[3]], normalized_rule(fields));
				let edge = verdict(item.args);
				if (edge != null && substr(edge.target, -length(suffix)) == suffix) {
					expected_edges[key] ??= [];
					push(expected_edges[key], normalized_rule(fields));
				}
			}
		}
		else if (item.command == 'ipset' && item.args[0] == 'create') {
			push(expected_sets, item.args[1]); expected_members[item.args[1]] = [];
			expected_set_schema[item.args[1]] = item.args[2] + ':family=' + item.args[4];
		}
		else if (item.command == 'ipset' && item.args[0] == 'add')
			push(expected_members[item.args[1]], normalized_token(item.args[2]));
	}
	for (let key, chains in expected_chains) for (let chain in chains) owned_targets[chain] = true;
	if (active) for (let family in compiled.desired.ip_families) {
		let executable = family == 'ipv6' ? 'ip6tables-save' : 'iptables-save', n = names(compiled.generation, family == 'ipv6');
		for (let item in [ [ 'mangle', CHAINS.prerouting, n.prerouting ], [ 'mangle', CHAINS.output, n.output ],
			[ 'filter', CHAINS.tun_input, n.tun_input ], [ 'filter', CHAINS.tun_forward, n.tun_forward ] ]) {
			let key = executable + ':' + item[0]; expected_edges[key] ??= [];
			push(expected_edges[key], '-A ' + item[1] + ' -j ' + item[2]);
		}
	}
	for (let executable in [ 'iptables-save', 'ip6tables-save' ])
		for (let table in [ 'mangle', 'filter' ]) {
			let key = executable + ':' + table;
			let result = runtime.process.run({ command: executable, args: [ '-t', table ] });
			let output = output_or_capture(runtime, result, executable, table);
			if (output == null) return false;
			let chains = [], rules = {}, edges = [];
			for (let raw in split(output, '\n')) {
				let line = trim(raw);
				let declaration = match(line, /^:([^ ]+) /);
				if (declaration && substr(declaration[1], -length(suffix)) == suffix)
					push(chains, declaration[1]);
				let fields = split(line, ' ');
				if (length(fields) >= 3 && fields[0] == '-A' &&
				    substr(fields[1], -length(suffix)) == suffix) {
					rules[fields[1]] ??= [];
					push(rules[fields[1]], normalized_rule(fields));
				}
				let edge = verdict(fields);
				if (length(fields) >= 3 && fields[0] == '-A' && edge != null && owned_targets[edge.target])
					push(edges, normalized_rule(fields));
			}
			if (sorted_json(chains) != sorted_json(expected_chains[key] ?? []) ||
			    length(keys(rules)) != length(keys(expected_rules[key] ?? {}))) return false;
			for (let chain, wanted in expected_rules[key] ?? {})
				if (sprintf('%J', rules[chain] ?? []) != sprintf('%J', wanted)) return false;
			if (sorted_json(edges) != sorted_json(expected_edges[key] ?? [])) return false;
		}
	let set_result = runtime.process.run({ command: 'ipset', args: [ 'save' ] });
	let set_output = output_or_capture(runtime, set_result, 'ipset', 'save');
	if (set_output == null) return false;
	let sets = [], members = {}, set_schema = {};
	for (let raw in split(set_output, '\n')) {
		let fields = split(trim(raw), ' ');
		if (length(fields) >= 2 && fields[0] == 'create' && substr(fields[1], -length(suffix)) == suffix) {
			push(sets, fields[1]); members[fields[1]] = [];
			let family = null;
			for (let i = 3; i + 1 < length(fields); i++) if (fields[i] == 'family') family = fields[i + 1];
			set_schema[fields[1]] = (fields[2] ?? '') + ':family=' + (family ?? '');
		}
		else if (length(fields) >= 3 && fields[0] == 'add' && substr(fields[1], -length(suffix)) == suffix)
			push(members[fields[1]], normalized_token(fields[2]));
	}
	if (sorted_json(sets) != sorted_json(expected_sets)) return false;
	for (let set in expected_sets)
		if (set_schema[set] != expected_set_schema[set] ||
		    sorted_json(members[set] ?? []) != sorted_json(expected_members[set] ?? [])) return false;
	return true;
};

export function observe(runtime) {
	let found = null, families = [], valid = true, legacy = false;
	for (let item in [ [ 'iptables-save', 'ipv4' ], [ 'ip6tables-save', 'ipv6' ] ]) {
		let mangle = runtime.process.run({ command: item[0], args: [ '-t', 'mangle' ] });
		let filter = runtime.process.run({ command: item[0], args: [ '-t', 'filter' ] });
		let mangle_output = output_or_capture(runtime, mangle, item[0], 'mangle');
		let filter_output = output_or_capture(runtime, filter, item[0], 'filter');
		if (mangle_output == null || filter_output == null) {
			valid = false; continue;
		}
		let ids = [ anchor_generation(mangle_output, CHAINS.prerouting, 'MCL_PR_'),
			anchor_generation(mangle_output, CHAINS.output, 'MCL_OU_'),
			anchor_generation(filter_output, CHAINS.tun_input, 'MCL_TI_'),
			anchor_generation(filter_output, CHAINS.tun_forward, 'MCL_TF_') ];
		let id = ids[0];
		for (let value in ids) if (value == null || value != id) { valid = false; id = null; }
		let absent = id == '-';
		for (let hook in [ [ mangle_output, '-A PREROUTING -j ' + CHAINS.prerouting ],
			[ mangle_output, '-A OUTPUT -j ' + CHAINS.output ],
			[ filter_output, '-A INPUT -j ' + CHAINS.tun_input ],
			[ filter_output, '-A FORWARD -j ' + CHAINS.tun_forward ] ])
			if (count_line(hook[0], hook[1]) != (absent ? 0 : 1)) { valid = false; id = null; }
		for (let hook in [ [ mangle_output, 'PREROUTING', CHAINS.prerouting ],
			[ mangle_output, 'OUTPUT', CHAINS.output ], [ filter_output, 'INPUT', CHAINS.tun_input ],
			[ filter_output, 'FORWARD', CHAINS.tun_forward ] ])
			if (count_target(hook[0], hook[1], hook[2]) != (absent ? 0 : 1)) { valid = false; id = null; }
		if (!guard_order_valid(filter_output)) { valid = false; id = null; }
		if (index(mangle_output, '-A PREROUTING -j MICLASH_PREROUTING') >= 0 ||
		    index(mangle_output, '-A OUTPUT -j MICLASH_OUTPUT') >= 0) legacy = true;
		if (id == null || id == '' || id == '-') continue;
		if (found != null && found != id) return { installed: false, generation: null, families: [], source: 'ambiguous' };
		found = id; push(families, item[1]);
	}
	return { valid, legacy, installed: valid && found != null, generation: valid ? found : null,
		families: valid ? families : [], source: 'save-anchors' };
};

function run(runtime, item) {
	let result = runtime.process.run({ command: item.command, args: item.args });
	if (result.code == 0) {
		if (item.on_success != null)
			return runtime.process.run({ command: item.command, args: item.on_success }).code == 0;
		return true;
	}
	if (item.on_failure != null)
		return runtime.process.run({ command: item.command, args: item.on_failure }).code == 0;
	return item.tolerate_failure === true;
};

function run_all(runtime, commands) {
	for (let item in commands) if (!run(runtime, item)) return false;
	return true;
};

function generation_absent(runtime, id, families) {
	let documents = {};
	for (let family in families) {
		let executable = family == 'ipv6' ? 'ip6tables-save' : 'iptables-save';
		for (let table in [ 'mangle', 'filter' ]) {
			let result = runtime.process.run({ command: executable, args: [ '-t', table ] });
			let output = output_or_capture(runtime, result, executable, table);
			if (output == null) return false;
			documents[executable + ':' + table] = output;
		}
		let n = names(id, family == 'ipv6');
		for (let object in [ [ 'mangle', n.prerouting ], [ 'mangle', n.proxy ], [ 'mangle', n.output ],
			[ 'filter', n.tun_input ], [ 'filter', n.tun_forward ] ])
			if (index(documents[executable + ':' + object[0]], ':' + object[1] + ' ') >= 0) return false;
	}
	let sets = runtime.process.run({ command: 'ipset', args: [ 'save' ] });
	let set_output = output_or_capture(runtime, sets, 'ipset', 'save');
	if (set_output == null) return false;
	for (let family in families) {
		let n = names(id, family == 'ipv6');
		for (let set in [ n.local, n.fake ])
			for (let line in split(set_output, '\n')) {
				let fields = split(trim(line), ' ');
				if (length(fields) >= 2 && fields[0] == 'create' && fields[1] == set) return false;
			}
	}
	return true;
};

function rollback_ok(runtime, compiled) {
	return run_all(runtime, compiled.rollback) &&
		generation_absent(runtime, compiled.generation, compiled.desired.ip_families);
};

function safe_bool(fn) { try { return !!fn(); } catch (error) { return false; } };

export function apply(runtime, compiled) {
	if (type(compiled) != 'object' || !match(compiled.generation ?? '', /^[0-9a-f]{12}$/) ||
	    type(compiled.stages) != 'object' || type(compiled.rollback) != 'array') fail('INVALID_ARGUMENT');
	let expected;
	try { expected = compile(compiled.desired); }
	catch (error) { fail('INVALID_ARGUMENT'); }
	if (sprintf('%J', compiled) != sprintf('%J', expected)) fail('INVALID_ARGUMENT');
	let guard_ready = ensure_guard_order(runtime, compiled.desired.previous_ip_families.length ?
		compiled.desired.previous_ip_families : compiled.desired.ip_families);
	if (!guard_ready) return { installed: true, generation: compiled.previous_generation,
		repair_needed: true, error: 'INTERNAL', stage: 'guard-order' };
	if (!run_all(runtime, compiled.stages.anchors)) fail('INTERNAL');
	if (!run_all(runtime, compiled.stages.prepare) || !run_all(runtime, compiled.stages.verify_prepared)) {
		if (!safe_bool(() => rollback_ok(runtime, compiled)))
			return { installed: true, generation: compiled.previous_generation, repair_needed: true,
				error: 'INTERNAL', stage: 'rollback' };
		fail('INTERNAL');
	}
	if (!safe_bool(() => verify_generation(runtime, compiled,
		compiled.previous_generation == compiled.generation))) {
		if (compiled.previous_generation == compiled.generation)
			return { installed: true, generation: compiled.generation, repair_needed: true,
				error: 'INTERNAL', stage: 'verify-generation' };
		if (!safe_bool(() => rollback_ok(runtime, compiled)))
			return { installed: true, generation: compiled.previous_generation, repair_needed: true,
				error: 'INTERNAL', stage: 'rollback' };
		fail('INTERNAL');
	}
	let before = null, previous_families = compiled.desired.previous_ip_families;
	try { before = observe(runtime); } catch (error) {}
	if (before == null || !before.valid || (compiled.previous_generation == null ? before.generation != null :
	    before.generation != compiled.previous_generation || !same_families(before.families, previous_families))) {
		if (!safe_bool(() => rollback_ok(runtime, compiled)))
			return { installed: true, generation: compiled.previous_generation, repair_needed: true,
				error: 'INTERNAL', stage: 'rollback' };
		fail('INTERNAL');
	}
	let switched = false;
	for (let item in compiled.stages.switch) {
		if (!run(runtime, item)) {
			if (!switched) {
				if (!safe_bool(() => rollback_ok(runtime, compiled)))
					return { installed: true, generation: compiled.previous_generation, repair_needed: true,
						error: 'INTERNAL', stage: 'rollback' };
				fail('INTERNAL');
			}
			return { installed: true, generation: compiled.generation, repair_needed: true,
				error: 'INTERNAL', stage: 'switch' };
		}
		switched = true;
	}
	if (!run_all(runtime, compiled.stages.verify_active))
		return { installed: true, generation: compiled.generation, repair_needed: true,
			error: 'INTERNAL', stage: 'verify-active' };
	let active = null;
	try { active = observe(runtime); } catch (error) {}
	if (active == null || !active.valid || active.legacy || active.generation != compiled.generation ||
	    !same_families(active.families, compiled.desired.ip_families))
		return { installed: true, generation: compiled.generation, repair_needed: true,
			error: 'INTERNAL', stage: 'verify-active' };
	if (!safe_bool(() => verify_generation(runtime, compiled, true)))
		return { installed: true, generation: compiled.generation, repair_needed: true,
			error: 'INTERNAL', stage: 'verify-generation' };
	if (!run_all(runtime, compiled.stages.retire))
		return { installed: true, generation: compiled.generation, repair_needed: true,
			error: 'INTERNAL', stage: 'retire' };
	if (compiled.previous_generation != null && compiled.previous_generation != compiled.generation &&
	    !safe_bool(() => generation_absent(runtime, compiled.previous_generation, compiled.desired.previous_ip_families)))
		return { installed: true, generation: compiled.generation, repair_needed: true,
			error: 'INTERNAL', stage: 'retire' };
	return { installed: true, generation: compiled.generation, repair_needed: false };
};

function discover_generations(runtime) {
	let state = {}, documents = {};
	for (let executable in [ 'iptables-save', 'ip6tables-save' ])
		for (let table in [ 'mangle', 'filter' ]) {
			let result = runtime.process.run({ command: executable, args: [ '-t', table ] });
			let output = output_or_capture(runtime, result, executable, table);
			if (output == null) fail('INTERNAL');
			documents[executable + ':' + table] = output;
			for (let raw in split(output, '\n')) {
				let declaration = match(trim(raw), /^:([^ ]+) /);
				if (!declaration || !match(declaration[1], /^MCL_(PR|PX|OU|TI|TF)_/)) continue;
				let owned = match(declaration[1], /^MCL_(PR|PX|OU|TI|TF)_([0-9a-f]{12})$/);
				if (!owned) fail('INTERNAL');
				let expected_table = index([ 'PR', 'PX', 'OU' ], owned[1]) >= 0 ? 'mangle' : 'filter';
				if (table != expected_table) fail('INTERNAL');
				let family = executable == 'ip6tables-save' ? 'ipv6' : 'ipv4';
				state[owned[2]] ??= {}; state[owned[2]][family] ??= { chains: {}, sets: {} };
				if (state[owned[2]][family].chains[owned[1]]) fail('INTERNAL');
				state[owned[2]][family].chains[owned[1]] = true;
			}
		}
	let set_result = runtime.process.run({ command: 'ipset', args: [ 'save' ] });
	let set_output = output_or_capture(runtime, set_result, 'ipset', 'save');
	if (set_output == null) fail('INTERNAL');
	for (let raw in split(set_output, '\n')) {
		let fields = split(trim(raw), ' ');
		if (length(fields) < 2 || fields[0] != 'create' || !match(fields[1], /^MCL_(L4|F4|L6|F6)_/)) continue;
		let owned = match(fields[1], /^MCL_(L4|F4|L6|F6)_([0-9a-f]{12})$/);
		if (!owned) fail('INTERNAL');
		let family = substr(owned[1], 1, 1) == '6' ? 'ipv6' : 'ipv4';
		state[owned[2]] ??= {}; state[owned[2]][family] ??= { chains: {}, sets: {} };
		if (state[owned[2]][family].sets[owned[1]]) fail('INTERNAL');
		state[owned[2]][family].sets[owned[1]] = true;
	}
	let ids = [];
	for (let id, families in state) {
		for (let family, inventory in families) {
			let digit = family == 'ipv6' ? '6' : '4';
			if (sorted_json(keys(inventory.chains)) != sorted_json([ 'PR', 'PX', 'OU', 'TI', 'TF' ]) ||
			    sorted_json(keys(inventory.sets)) != sorted_json([ 'L' + digit, 'F' + digit ])) fail('INTERNAL');
		}
		push(ids, id);
	}
	let stable_edges = {};
	for (let key, output in documents) {
		let family = substr(key, 0, length('ip6tables-save')) == 'ip6tables-save' ? 'ipv6' : 'ipv4';
		for (let raw in split(output, '\n')) {
			let fields = split(trim(raw), ' '), edge = verdict(fields);
			if (length(fields) < 3 || fields[0] != '-A' || edge == null ||
			    !match(edge.target, /^MCL_(PR|PX|OU|TI|TF)_/)) continue;
			let target = match(edge.target, /^MCL_(PR|PX|OU|TI|TF)_([0-9a-f]{12})$/);
			if (!target || state[target[2]]?.[family]?.chains[target[1]] !== true || edge.kind != 'jump') fail('INTERNAL');
			let expected_source = target[1] == 'PR' ? CHAINS.prerouting : target[1] == 'OU' ? CHAINS.output :
				target[1] == 'TI' ? CHAINS.tun_input : target[1] == 'TF' ? CHAINS.tun_forward :
				'MCL_PR_' + target[2];
			if (fields[1] != expected_source) fail('INTERNAL');
			if (target[1] != 'PX') {
				let exact = '-A ' + expected_source + ' -j ' + edge.target;
				if (trim(raw) != exact) fail('INTERNAL');
				let edge_key = key + ':' + exact;
				stable_edges[edge_key] = (stable_edges[edge_key] ?? 0) + 1;
				if (stable_edges[edge_key] > 1) fail('INTERNAL');
			}
		}
	}
	return { ids: sort(ids), state, documents, set_output };
};

function chain_count(text, chain) {
	let count = 0, prefix = ':' + chain + ' ';
	for (let raw in split(text, '\n')) {
		let line = trim(raw);
		if (substr(line, 0, length(prefix)) == prefix) count++;
	}
	return count;
};

function cleanup_plan(runtime) {
	let discovery = discover_generations(runtime), commands = [];
	for (let executable in [ 'iptables', 'ip6tables' ]) {
		let save = executable + '-save', mangle = discovery.documents[save + ':mangle'];
		for (let legacy in [ [ 'PREROUTING', 'MICLASH_PREROUTING' ], [ 'OUTPUT', 'MICLASH_OUTPUT' ] ]) {
			let line = '-A ' + legacy[0] + ' -j ' + legacy[1], exact = count_line(mangle, line);
			if (count_target(mangle, legacy[0], legacy[1]) != exact || exact > 1) fail('INTERNAL');
			if (exact == 1) push(commands, request(executable,
				[ '-t', 'mangle', '-D', legacy[0], '-j', legacy[1] ]));
		}
		for (let item in [ [ 'mangle', 'PREROUTING', CHAINS.prerouting ],
			[ 'mangle', 'OUTPUT', CHAINS.output ], [ 'filter', 'INPUT', CHAINS.tun_input ],
			[ 'filter', 'FORWARD', CHAINS.tun_forward ] ]) {
			let output = discovery.documents[save + ':' + item[0]], line = '-A ' + item[1] + ' -j ' + item[2];
			let exact = count_line(output, line), declarations = chain_count(output, item[2]);
			if (count_target(output, item[1], item[2]) != exact || exact > 1 || declarations > 1 ||
			    (declarations == 0 && exact != 0)) fail('INTERNAL');
			if (declarations == 1 && anchor_generation(output, item[2],
				item[2] == CHAINS.prerouting ? 'MCL_PR_' : item[2] == CHAINS.output ? 'MCL_OU_' :
				item[2] == CHAINS.tun_input ? 'MCL_TI_' : 'MCL_TF_') == null) fail('INTERNAL');
			if (exact == 1) push(commands, request(executable,
				[ '-t', item[0], '-D', item[1], '-j', item[2] ]));
			if (declarations == 1) {
				push(commands, request(executable, [ '-t', item[0], '-F', item[2] ]));
				push(commands, request(executable, [ '-t', item[0], '-X', item[2] ]));
			}
		}
	}
	for (let id, families in discovery.state)
		for (let family in families) {
			let executable = family == 'ipv6' ? 'ip6tables' : 'iptables', n = names(id, family == 'ipv6');
			for (let item in [ [ 'mangle', n.prerouting ], [ 'mangle', n.proxy ], [ 'mangle', n.output ],
				[ 'filter', n.tun_input ], [ 'filter', n.tun_forward ] ])
				push(commands, request(executable, [ '-t', item[0], '-F', item[1] ]));
			for (let item in [ [ 'mangle', n.prerouting ], [ 'mangle', n.proxy ], [ 'mangle', n.output ],
				[ 'filter', n.tun_input ], [ 'filter', n.tun_forward ] ])
				push(commands, request(executable, [ '-t', item[0], '-X', item[1] ]));
			for (let set in [ n.local, n.fake ]) push(commands, request('ipset', [ 'destroy', set ]));
		}
	return { commands, ids: discovery.ids };
};

export function cleanup(runtime, mode) {
	if (mode?.preserve_guard !== true || type(mode.generations ?? []) != 'array') fail('INVALID_ARGUMENT');
	for (let id in mode.generations) if (!match(id, /^[0-9a-f]{12}$/)) fail('INVALID_ARGUMENT');
	let plan = cleanup_plan(runtime);
	for (let item in plan.commands)
		if (runtime.process.run({ command: item.command, args: item.args }).code != 0) fail('INTERNAL');
	let remaining = cleanup_plan(runtime);
	if (length(remaining.commands) || length(remaining.ids)) fail('INTERNAL');
	return { clean: true, guard_preserved: true };
};
