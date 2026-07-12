import { fail } from 'miclash.errors';
import { validate, generation, LOCAL4, LOCAL6 } from 'miclash.firewall.common';

const CHAINS = {
	prerouting: 'MCL_AN_PR', output: 'MCL_AN_OU',
	tun_input: 'MCL_AN_TI', tun_forward: 'MCL_AN_TF'
};

function request(command, args, properties) {
	return { command, args: [ ...args ], ...(properties ?? {}) };
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
	return { generation: id, previous_generation: desired.previous_generation ?? null,
		model: { schema_version: 1, normalized: model }, stages: transaction.stages,
		rollback: transaction.rollback, desired: canonical };
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

export function observe(runtime) {
	let found = null, families = [], valid = true, legacy = false;
	for (let item in [ [ 'iptables-save', 'ipv4' ], [ 'ip6tables-save', 'ipv6' ] ]) {
		let mangle = runtime.process.run({ command: item[0], args: [ '-t', 'mangle' ] });
		let filter = runtime.process.run({ command: item[0], args: [ '-t', 'filter' ] });
		if (mangle.code != 0 || filter.code != 0 || type(mangle.stdout) != 'string' || type(filter.stdout) != 'string') {
			valid = false; continue;
		}
		let ids = [ anchor_generation(mangle.stdout, CHAINS.prerouting, 'MCL_PR_'),
			anchor_generation(mangle.stdout, CHAINS.output, 'MCL_OU_'),
			anchor_generation(filter.stdout, CHAINS.tun_input, 'MCL_TI_'),
			anchor_generation(filter.stdout, CHAINS.tun_forward, 'MCL_TF_') ];
		let id = ids[0];
		for (let value in ids) if (value == null || value != id) { valid = false; id = null; }
		let absent = id == '-';
		for (let hook in [ [ mangle.stdout, '-A PREROUTING -j ' + CHAINS.prerouting ],
			[ mangle.stdout, '-A OUTPUT -j ' + CHAINS.output ],
			[ filter.stdout, '-A INPUT -j ' + CHAINS.tun_input ],
			[ filter.stdout, '-A FORWARD -j ' + CHAINS.tun_forward ] ])
			if (count_line(hook[0], hook[1]) != (absent ? 0 : 1)) { valid = false; id = null; }
		for (let hook in [ [ mangle.stdout, 'PREROUTING', CHAINS.prerouting ],
			[ mangle.stdout, 'OUTPUT', CHAINS.output ], [ filter.stdout, 'INPUT', CHAINS.tun_input ],
			[ filter.stdout, 'FORWARD', CHAINS.tun_forward ] ])
			if (count_target(hook[0], hook[1], hook[2]) != (absent ? 0 : 1)) { valid = false; id = null; }
		if (index(mangle.stdout, '-A PREROUTING -j MICLASH_PREROUTING') >= 0 ||
		    index(mangle.stdout, '-A OUTPUT -j MICLASH_OUTPUT') >= 0) legacy = true;
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
			if (result.code != 0 || type(result.stdout) != 'string') return false;
			documents[executable + ':' + table] = result.stdout;
		}
		let n = names(id, family == 'ipv6');
		for (let object in [ [ 'mangle', n.prerouting ], [ 'mangle', n.proxy ], [ 'mangle', n.output ],
			[ 'filter', n.tun_input ], [ 'filter', n.tun_forward ] ])
			if (index(documents[executable + ':' + object[0]], ':' + object[1] + ' ') >= 0) return false;
	}
	let sets = runtime.process.run({ command: 'ipset', args: [ 'list', '-name' ] });
	if (sets.code != 0 || type(sets.stdout) != 'string') return false;
	for (let family in families) {
		let n = names(id, family == 'ipv6');
		for (let set in [ n.local, n.fake ])
			for (let line in split(sets.stdout, '\n')) if (trim(line) == set) return false;
	}
	return true;
};

function rollback_ok(runtime, compiled) {
	return run_all(runtime, compiled.rollback) &&
		generation_absent(runtime, compiled.generation, compiled.desired.ip_families);
};

export function apply(runtime, compiled) {
	if (type(compiled) != 'object' || !match(compiled.generation ?? '', /^[0-9a-f]{12}$/) ||
	    type(compiled.stages) != 'object' || type(compiled.rollback) != 'array') fail('INVALID_ARGUMENT');
	let expected;
	try { expected = compile(compiled.desired); }
	catch (error) { fail('INVALID_ARGUMENT'); }
	if (sprintf('%J', compiled) != sprintf('%J', expected)) fail('INVALID_ARGUMENT');
	if (!run_all(runtime, compiled.stages.anchors)) fail('INTERNAL');
	if (!run_all(runtime, compiled.stages.prepare) || !run_all(runtime, compiled.stages.verify_prepared)) {
		if (!rollback_ok(runtime, compiled))
			return { installed: true, generation: compiled.previous_generation, repair_needed: true,
				error: 'INTERNAL', stage: 'rollback' };
		fail('INTERNAL');
	}
	let before = observe(runtime), previous_families = compiled.desired.previous_ip_families;
	if (!before.valid || (compiled.previous_generation == null ? before.generation != null :
	    before.generation != compiled.previous_generation || !same_families(before.families, previous_families))) {
		if (!rollback_ok(runtime, compiled))
			return { installed: true, generation: compiled.previous_generation, repair_needed: true,
				error: 'INTERNAL', stage: 'rollback' };
		fail('INTERNAL');
	}
	let switched = false;
	for (let item in compiled.stages.switch) {
		if (!run(runtime, item)) {
			if (!switched) {
				if (!rollback_ok(runtime, compiled))
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
	let active = observe(runtime);
	if (!active.valid || active.legacy || active.generation != compiled.generation ||
	    !same_families(active.families, compiled.desired.ip_families))
		return { installed: true, generation: compiled.generation, repair_needed: true,
			error: 'INTERNAL', stage: 'verify-active' };
	if (!run_all(runtime, compiled.stages.retire))
		return { installed: true, generation: compiled.generation, repair_needed: true,
			error: 'INTERNAL', stage: 'retire' };
	return { installed: true, generation: compiled.generation, repair_needed: false };
};

export function cleanup(runtime, mode) {
	if (mode?.preserve_guard !== true || type(mode.generations ?? []) != 'array') fail('INVALID_ARGUMENT');
	for (let id in mode.generations) if (!match(id, /^[0-9a-f]{12}$/)) fail('INVALID_ARGUMENT');
	for (let item in [ [ 'iptables', 'mangle', 'PREROUTING', CHAINS.prerouting ],
		[ 'iptables', 'mangle', 'OUTPUT', CHAINS.output ], [ 'iptables', 'filter', 'INPUT', CHAINS.tun_input ],
		[ 'iptables', 'filter', 'FORWARD', CHAINS.tun_forward ], [ 'ip6tables', 'mangle', 'PREROUTING', CHAINS.prerouting ],
		[ 'ip6tables', 'mangle', 'OUTPUT', CHAINS.output ], [ 'ip6tables', 'filter', 'INPUT', CHAINS.tun_input ],
		[ 'ip6tables', 'filter', 'FORWARD', CHAINS.tun_forward ] ]) {
		let hook = [ '-t', item[1], '-C', item[2], '-j', item[3] ];
		if (runtime.process.run({ command: item[0], args: hook }).code == 0 &&
		    runtime.process.run({ command: item[0], args: [ '-t', item[1], '-D', item[2], '-j', item[3] ] }).code != 0)
			fail('INTERNAL');
		if (runtime.process.run({ command: item[0], args: hook }).code == 0) fail('INTERNAL');
		let exists_args = [ '-t', item[1], '-L', item[3] ];
		if (runtime.process.run({ command: item[0], args: exists_args }).code == 0) {
			if (runtime.process.run({ command: item[0], args: [ '-t', item[1], '-F', item[3] ] }).code != 0 ||
			    runtime.process.run({ command: item[0], args: [ '-t', item[1], '-X', item[3] ] }).code != 0)
				fail('INTERNAL');
		}
		if (runtime.process.run({ command: item[0], args: exists_args }).code == 0) fail('INTERNAL');
	}
	for (let id in mode.generations) {
		for (let family in [ 'ipv4', 'ipv6' ]) {
			if (!run_all(runtime, inventory_commands(id, family, 'retire'))) fail('INTERNAL');
			let ipv6 = family == 'ipv6', executable = ipv6 ? 'ip6tables' : 'iptables', n = names(id, ipv6);
			for (let object in [ [ 'mangle', n.prerouting ], [ 'mangle', n.proxy ], [ 'mangle', n.output ],
				[ 'filter', n.tun_input ], [ 'filter', n.tun_forward ] ])
				if (runtime.process.run({ command: executable, args: [ '-t', object[0], '-L', object[1] ] }).code == 0)
					fail('INTERNAL');
			for (let set in [ n.local, n.fake ])
				if (runtime.process.run({ command: 'ipset', args: [ 'list', set ] }).code == 0) fail('INTERNAL');
		}
	}
	let state = observe(runtime);
	if (!state.valid || state.installed) fail('INTERNAL');
	let saves = {};
	for (let executable in [ 'iptables-save', 'ip6tables-save' ])
		for (let table in [ 'mangle', 'filter' ]) {
			let result = runtime.process.run({ command: executable, args: [ '-t', table ] });
			if (result.code != 0 || type(result.stdout) != 'string') fail('INTERNAL');
			saves[executable + ':' + table] = result.stdout;
		}
	let sets = runtime.process.run({ command: 'ipset', args: [ 'list', '-name' ] });
	if (sets.code != 0 || type(sets.stdout) != 'string') fail('INTERNAL');
	for (let id in mode.generations)
		for (let family in [ 'ipv4', 'ipv6' ]) {
			let n = names(id, family == 'ipv6');
			let save = family == 'ipv6' ? 'ip6tables-save' : 'iptables-save';
			for (let object in [ [ 'mangle', n.prerouting ], [ 'mangle', n.proxy ], [ 'mangle', n.output ],
				[ 'filter', n.tun_input ], [ 'filter', n.tun_forward ] ])
				if (index(saves[save + ':' + object[0]], ':' + object[1] + ' ') >= 0) fail('INTERNAL');
			for (let set in [ n.local, n.fake ])
				for (let line in split(sets.stdout, '\n')) if (trim(line) == set) fail('INTERNAL');
		}
	return { clean: true, guard_preserved: true };
};
