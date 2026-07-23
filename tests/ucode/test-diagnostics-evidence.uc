import * as evidence_module from 'miclash.diagnostics-evidence';
import { assert_equal, assert_true } from './testlib.uc';

function find_section(sections, name) {
	for (let section in sections) if (section.name == name) return section.value;
	return null;
};

let commands = [];
let log_lines = [
	'Thu Jul 23 01:00:00 2026 daemon.info dnsmasq[1234]: query[A] example.test from 192.0.2.1\n',
	'Thu Jul 23 01:00:01 2026 daemon.notice netifd: Interface wan is now up\n',
	'Thu Jul 23 01:00:02 2026 user.notice firewall: Reloading firewall\n',
	'Thu Jul 23 01:00:03 2026 kern.warn kernel: TUN device entered promiscuous mode\n',
	'Thu Jul 23 01:00:04 2026 kern.warn kernel: tproxy rule matched local socket\n',
	'Thu Jul 23 01:00:05 2026 kern.warn kernel: IPv4: routing cache flush\n',
	'Thu Jul 23 01:00:06 2026 kern.err kernel: Out of memory: Killed process 123 (mihomo)\n',
	'Thu Jul 23 01:00:07 2026 kern.err kernel: mihomo[456]: segfault at 0 ip 00000000\n',
	'Thu Jul 23 01:00:08 2026 kern.emerg kernel: Kernel panic - not syncing: Fatal exception\n',
	'Thu Jul 23 01:00:09 2026 kern.err kernel: Oops: 0000 [#1] SMP\n',
	'Thu Jul 23 01:00:10 2026 kern.err kernel: crash signature: general protection fault\n',
	'Thu Jul 23 01:00:11 2026 kern.info kernel: unrelated periodic housekeeping\n'
];
for (let i = 0; i < 1500; i++)
	push(log_lines, sprintf(
		'Thu Jul 23 01:01:%02d 2026 authpriv.info dropbear[%d]: irrelevant\n', i % 60, i));
for (let i = 0; i < 1200; i++)
	push(log_lines, sprintf(
		'Thu Jul 23 01:20:%02d 2026 daemon.info miclash: retained-%d\n', i % 60, i));
push(log_lines,
	'Thu Jul 23 01:30:00 2026 daemon.info miclash: final relevant record\n');
let log_read_index = 0, log_read_modes = [];
let runtime = { fs: { popen: (command, mode) => {
	push(commands, { command, mode });
	return {
		read: (amount) => {
			push(log_read_modes, amount);
			if (log_read_index >= length(log_lines)) return '';
			return log_lines[log_read_index++];
		},
		close: () => 0
	};
} } };
let evidence = evidence_module.create(runtime, {
	procd: () => ({ state: 'ready' }),
	interfaces: () => null
});

let section_evidence = evidence_module.create({ fs: { popen: () => ({
	read: () => '', close: () => 1
}) } }, {
	procd: () => ({ state: 'ready' }),
	interfaces: () => null
});
let section_reader = section_evidence.open_sections();
let pulled_sections = [];
while (true) {
	let batch = section_reader.read(1);
	assert_true(length(batch.records) <= 1,
		'evidence sections expose one bounded scheduled work unit');
	for (let section in batch.records) push(pulled_sections, section);
	if (batch.done) break;
}
assert_equal(length(pulled_sections), 13,
	'the pull reader preserves every schema-v4 evidence section');

let logs = [], log_reader = evidence.logs(), log_batches = 0;
assert_equal(type(log_reader.read), 'function',
	'log collection exposes a bounded pull reader instead of a complete record array');
while (true) {
	let batch = log_reader.read(64);
	log_batches++;
	assert_true(length(batch.records) <= 64, 'each log pull is bounded');
	for (let entry in batch.records) push(logs, entry);
	if (batch.done) break;
}
assert_equal(length(logs), 1212, 'all available relevant log lines are yielded');
assert_true(log_batches > 40, 'large log sources require multiple bounded pulls');
assert_equal(logs[0].timestamp, 'Thu Jul 23 01:00:00 2026');
assert_equal(logs[0].facility, 'daemon');
assert_equal(logs[0].severity, 'info');
assert_equal(logs[0].component, 'dnsmasq');
assert_equal(logs[0].message, 'query[A] example.test from 192.0.2.1');
assert_equal(logs[1].facility, 'daemon');
assert_equal(logs[1].severity, 'notice');
assert_equal(logs[1].component, 'netifd');
assert_equal(logs[2].facility, 'user');
assert_equal(logs[2].severity, 'notice');
assert_equal(logs[3].facility, 'kern');
assert_equal(logs[3].severity, 'warn');
assert_equal(logs[3].component, 'kernel');
assert_equal(logs[4].message, 'tproxy rule matched local socket');
assert_equal(logs[5].message, 'IPv4: routing cache flush');
assert_equal(logs[6].message, 'Out of memory: Killed process 123 (mihomo)');
assert_equal(logs[7].message, 'mihomo[456]: segfault at 0 ip 00000000');
assert_equal(logs[8].message, 'Kernel panic - not syncing: Fatal exception');
assert_equal(logs[9].message, 'Oops: 0000 [#1] SMP');
assert_equal(logs[10].message, 'crash signature: general protection fault');
assert_true(index(sprintf('%J', logs), 'unrelated periodic housekeeping') < 0,
	'irrelevant native kernel records remain excluded');
assert_equal(logs[length(logs) - 1].message, 'final relevant record',
	'relevant records are not subject to a second count truncation');
assert_equal(evidence.logs_status().state, 'present');
assert_equal(evidence.logs_status().records, 1212);
assert_true(length(filter(log_read_modes, (mode) => mode != 'line')) == 0,
	'logread is consumed as a direct record stream, never as a full output buffer');
let log_command = commands[length(commands) - 1];
assert_equal(log_command.command, '/sbin/logread');
assert_equal(log_command.mode, 'r');

let sections = [];
for (let section in evidence.sections()) push(sections, section);
assert_equal(sections[0].name, 'procd');
assert_equal(sections[0].value.state, 'ready');
assert_equal(find_section(sections, 'interfaces').state, 'unavailable');
assert_equal(find_section(sections, 'interfaces').code, 'COLLECTION_UNAVAILABLE');

let nested_failures = evidence_module.create(runtime, {
	procd: () => ({
		state: 'present', source: 'procd',
		service: { state: 'unknown', running: false, registered: false, instances: [] }
	}),
	interfaces: () => ({
		state: 'present', source: 'interface-scope',
		interfaces: { available: false, interfaces: [], detected_lan: '', detected_wan: '' }
	})
}).sections();
let unavailable_procd = find_section(nested_failures, 'procd');
assert_equal(unavailable_procd.state, 'unavailable');
assert_equal(unavailable_procd.code, 'COLLECTION_UNAVAILABLE');
assert_equal(unavailable_procd.message, 'procd service status is unavailable');
let unavailable_interfaces = find_section(nested_failures, 'interfaces');
assert_equal(unavailable_interfaces.state, 'unavailable');
assert_equal(unavailable_interfaces.code, 'COLLECTION_UNAVAILABLE');
assert_equal(unavailable_interfaces.message, 'interface topology is unavailable');

let failed_log_commands = [];
let failed_logs = evidence_module.create({ fs: { popen: (command, mode) => {
	push(failed_log_commands, command);
	let read = false;
	return {
		read: () => {
			if (read) return '';
			read = true;
			return 'partial record without successful collection\n';
		},
		close: () => 1
	};
} } }, {});
let failed_batch = failed_logs.logs().read(64);
assert_equal(length(failed_batch.records), 0);
assert_equal(failed_batch.done, true);
let failed_status = failed_logs.logs_status();
assert_equal(failed_status.state, 'unavailable');
assert_equal(failed_status.code, 'COLLECTION_UNAVAILABLE');
assert_equal(failed_status.exit_code, 1);
let failed_sections = failed_logs.sections();
assert_equal(find_section(failed_sections, 'logs').state, 'unavailable',
	'failed logread is represented as collection evidence for issue generation');

let adapter_commands = [];
let replies = {
	'/bin/ubus call service list \'{"name":"miclash"}\'': {
		output: '{"miclash":{"instances":{"instance1":{"running":true,"pid":501}}}}', close: 0 },
	'/usr/bin/opkg status luci-app-miclash': {
		output: 'Package: luci-app-miclash\nVersion: 2.0.0\nStatus: install user installed\n', close: 0 },
	'/bin/ubus call network.interface dump': {
		output: '{"interface":[{"interface":"wan","up":true,"dns-server":["1.1.1.1"],"data":{"unrelated":"drop"}}]}',
		close: 0 },
	'/usr/sbin/nft -j list table inet miclash': {
		output: '{"nftables":[{"table":{"family":"inet","name":"miclash"}}]}', close: 0 },
	'/bin/cat /proc/meminfo': {
		output: 'MemTotal: 262144 kB\nMemAvailable: 131072 kB\n', close: 0 }
};
let adapter_runtime = { fs: { popen: (command, mode) => {
	push(adapter_commands, command);
	let reply = replies[command];
	if (reply == null) return null;
	let read = false;
	return {
		read: () => { if (read) return ''; read = true; return reply.output; },
		close: () => reply.close
	};
} } };
let adapters = evidence_module.create(adapter_runtime, {
	routes: () => ({ state: 'present', routes: [
		{ family: 'ipv4', table: 100, protocol: 242, owned: true },
		{ family: 'ipv4', table: 100, protocol: 242, owned: false,
			comment: 'counterfeit reserved-table route' }
	], rules: [
		{ family: 'ipv4', table: 100, fwmark: '0x1', protocol: 242, owned: true },
		{ family: 'ipv4', table: 100, fwmark: '0x1', protocol: 242, owned: false,
			comment: 'counterfeit reserved-table rule' }
	], ownership: { status: 'trusted', trusted: true } }),
	interfaces: () => ({ state: 'present', interfaces: [ { name: 'wan', up: true } ] }),
	tun_tproxy: () => ({ state: 'present', tun: { present: false }, tproxy_rules: [] }),
	guard: () => ({ state: 'disabled', latched: false }),
	schedulers: () => ({ state: 'present', subscription: { running: true } }),
	operations: () => ({ state: 'present', records: [ { id: 'op-1', state: 'success' } ] }),
	recovery: () => ({ state: 'none' })
});
let adapter_sections = adapters.sections();
assert_equal(find_section(adapter_sections, 'procd').source, 'ubus');
assert_equal(find_section(adapter_sections, 'procd').service.instances.instance1.pid, 501);
assert_equal(find_section(adapter_sections, 'packages').manager, 'opkg');
assert_equal(find_section(adapter_sections, 'packages').packages[0].name, 'luci-app-miclash');
assert_equal(find_section(adapter_sections, 'packages').packages[0].version, '2.0.0');
assert_equal(find_section(adapter_sections, 'dns').interfaces[0].name, 'wan');
assert_equal(find_section(adapter_sections, 'dns').interfaces[0].dns_servers[0], '1.1.1.1');
assert_equal(find_section(adapter_sections, 'firewall').backend, 'nft');
assert_equal(find_section(adapter_sections, 'firewall').table.nftables[0].table.name, 'miclash');
assert_equal(find_section(adapter_sections, 'memory').mem_total_kib, 262144);
assert_equal(find_section(adapter_sections, 'memory').mem_available_kib, 131072);
assert_equal(find_section(adapter_sections, 'routes').ownership.status, 'trusted');
assert_equal(length(find_section(adapter_sections, 'routes').routes), 1);
assert_equal(length(find_section(adapter_sections, 'routes').rules), 1);
assert_true(index(sprintf('%J', find_section(adapter_sections, 'routes')),
	'counterfeit reserved-table') < 0,
	'verified routing adapters cannot leak foreign reserved-table state');
assert_equal(find_section(adapter_sections, 'operations').records[0].id, 'op-1');
assert_true(index(adapter_commands, '/usr/sbin/nft list ruleset') < 0,
	'firewall evidence never captures the whole nft ruleset');
assert_equal(length(filter(adapter_commands,
	(command) => command == '/bin/ubus call service list')), 0,
	'unrelated full procd state is never reused for other collectors');

function iptables_mangle(pr_id, ou_id) {
	return '*mangle\n:PREROUTING ACCEPT [0:0]\n:OUTPUT ACCEPT [0:0]\n' +
		':MCL_AN_PR - [0:0]\n:MCL_PR_' + pr_id + ' - [0:0]\n' +
		'-A PREROUTING -j MCL_AN_PR\n-A MCL_AN_PR -j MCL_PR_' + pr_id + '\n' +
		'-A MCL_PR_' + pr_id + ' -j TPROXY\n' +
		':MCL_AN_OU - [0:0]\n:MCL_OU_' + ou_id + ' - [0:0]\n' +
		'-A OUTPUT -j MCL_AN_OU\n-A MCL_AN_OU -j MCL_OU_' + ou_id + '\n' +
		'-A MCL_OU_' + ou_id + ' -j MARK\nCOMMIT\n';
};

function iptables_filter(ti_id, tf_id) {
	return '*filter\n:INPUT ACCEPT [0:0]\n:FORWARD ACCEPT [0:0]\n' +
		':MCL_AN_TI - [0:0]\n:MCL_TI_' + ti_id + ' - [0:0]\n' +
		'-A INPUT -j MCL_AN_TI\n-A MCL_AN_TI -j MCL_TI_' + ti_id + '\n' +
		'-A MCL_TI_' + ti_id + ' -j ACCEPT\n' +
		':MCL_AN_TF - [0:0]\n:MCL_TF_' + tf_id + ' - [0:0]\n' +
		'-A FORWARD -j MCL_AN_TF\n-A MCL_AN_TF -j MCL_TF_' + tf_id + '\n' +
		'-A MCL_TF_' + tf_id + ' -j ACCEPT\nCOMMIT\n';
};

let iptables_commands = [];
let iptables_replies = {
	'/usr/sbin/nft -j list table inet miclash': {
		output: 'Error: No such file or directory\n', close: 1 },
	'/usr/sbin/iptables-save -t mangle': {
		output: iptables_mangle('abcdefabcdef', 'abcdefabcdef') +
			':MCL_COUNTERFEIT - [0:0]\n' +
			'-A MCL_COUNTERFEIT -j MCL_PR_abcdefabcdef\n' +
			':MCL_PR_deadbeefdead - [0:0]\n' +
			'-A MCL_PR_deadbeefdead -j TPROXY\n' +
			':MCL_PR_abcdefabcdef_extra - [0:0]\n' +
			'-A MCL_PR_abcdefabcdef_extra -j TPROXY\n' +
			'-A PREROUTING -m comment --comment MCL_PR_abcdefabcdef -j unrelated\n' +
			'-A unrelated -j MCL_PR_abcdefabcdef\nCOMMIT\n',
		close: 0 },
	'/usr/sbin/iptables-save -t filter': {
		output: iptables_filter('abcdefabcdef', 'abcdefabcdef'),
		close: 0 },
	'/usr/sbin/ip6tables-save -t mangle': {
		output: iptables_mangle('123456789abc', '123456789abc'), close: 0 },
	'/usr/sbin/ip6tables-save -t filter': {
		output: iptables_filter('123456789abc', '123456789abc'), close: 0 },
	'/usr/sbin/ipset save': {
		output: 'create unrelated hash:net family inet\n' +
			'create MCL_L4_abcdefabcdef hash:net family inet\n' +
			'add unrelated 192.0.2.1\nadd MCL_L4_abcdefabcdef 198.51.100.0/24\n' +
			'create MCL_L6_123456789abc hash:net family inet6\n' +
			'add MCL_L6_123456789abc 2001:db8::/32\n' +
			'create MCL_F4_123456789abc hash:net family inet\n' +
			'add MCL_F4_123456789abc 203.0.113.0/24\n' +
			'create MCL_F6_abcdefabcdef hash:net family inet6\n' +
			'add MCL_F6_abcdefabcdef 2001:db8:ffff::/48\n',
		close: 0 }
};
let iptables_runtime = { fs: { popen: (command, mode) => {
	push(iptables_commands, command);
	let reply = iptables_replies[command];
	if (reply == null) return null;
	let read = false;
	return {
		read: () => { if (read) return ''; read = true; return reply.output; },
		close: () => reply.close
	};
} } };
let domain_present = () => ({ state: 'present', source: 'domain' });
let iptables_sections = evidence_module.create(iptables_runtime, {
	procd: domain_present, packages: domain_present, dns: domain_present,
	routes: domain_present, interfaces: domain_present, tun_tproxy: domain_present,
	guard: domain_present, schedulers: domain_present, memory: domain_present,
	operations: domain_present, recovery: domain_present
}).sections();
let iptables_firewall = find_section(iptables_sections, 'firewall');
assert_equal(iptables_firewall.backend, 'iptables');
assert_equal(iptables_firewall.documents[0].lines[0],
	':MCL_AN_PR - [0:0]');
assert_equal(iptables_firewall.documents[0].lines[1],
	':MCL_PR_abcdefabcdef - [0:0]');
assert_equal(iptables_firewall.documents[0].lines[2],
	'-A PREROUTING -j MCL_AN_PR');
assert_equal(iptables_firewall.documents[0].lines[3],
	'-A MCL_AN_PR -j MCL_PR_abcdefabcdef');
assert_equal(iptables_firewall.documents[0].lines[4],
	'-A MCL_PR_abcdefabcdef -j TPROXY');
assert_equal(iptables_firewall.documents[0].lines[5],
	':MCL_AN_OU - [0:0]');
assert_equal(iptables_firewall.documents[0].lines[9],
	'-A MCL_OU_abcdefabcdef -j MARK');
assert_equal(length(iptables_firewall.documents[0].lines), 10,
	'only the exact hooked anchors and reachable generations are emitted');
assert_true(index(sprintf('%J', iptables_firewall.documents),
	'MCL_COUNTERFEIT') < 0, 'counterfeit MCL chain declarations are excluded');
assert_true(index(sprintf('%J', iptables_firewall.documents),
	'MCL_PR_deadbeefdead') < 0,
	'an exact-looking but unanchored generation chain is excluded');
assert_true(index(sprintf('%J', iptables_firewall.documents),
	'MCL_PR_abcdefabcdef_extra') < 0,
	'a prefix counterfeit generation chain is excluded');
assert_true(index(sprintf('%J', iptables_firewall.documents),
	'--comment MCL_PR_abcdefabcdef') < 0,
	'counterfeit MCL comment text in a foreign rule is excluded');
assert_true(index(sprintf('%J', iptables_firewall.documents),
	'-A unrelated -j MCL_PR_abcdefabcdef') < 0,
	'foreign rules targeting an owned-looking chain are excluded');
assert_equal(iptables_firewall.sets[0],
	'create MCL_L4_abcdefabcdef hash:net family inet');
assert_equal(iptables_firewall.sets[1],
	'add MCL_L4_abcdefabcdef 198.51.100.0/24');
assert_equal(iptables_firewall.sets[2],
	'create MCL_L6_123456789abc hash:net family inet6');
assert_equal(iptables_firewall.sets[3],
	'add MCL_L6_123456789abc 2001:db8::/32');
assert_equal(length(iptables_firewall.sets), 4,
	'unrelated and cross-family counterfeit ipset objects are excluded');

let mismatch_replies = {
	'/usr/sbin/nft -j list table inet miclash': {
		output: 'Error: No such file or directory\n', close: 1 },
	'/usr/sbin/iptables-save -t mangle': {
		output: iptables_mangle('abcdefabcdef', 'abcdefabcdef'), close: 0 },
	'/usr/sbin/iptables-save -t filter': {
		output: iptables_filter('deadbeefdead', 'abcdefabcdef'), close: 0 },
	'/usr/sbin/ip6tables-save -t mangle': {
		output: iptables_mangle('123456789abc', '123456789abc'), close: 0 },
	'/usr/sbin/ip6tables-save -t filter': {
		output: iptables_filter('123456789abc', '123456789abc'), close: 0 },
	'/usr/sbin/ipset save': {
		output: 'create MCL_L4_abcdefabcdef hash:net family inet\n' +
			'add MCL_L4_abcdefabcdef 198.51.100.0/24\n' +
			'create MCL_F4_deadbeefdead hash:net family inet\n' +
			'add MCL_F4_deadbeefdead 203.0.113.0/24\n' +
			'create MCL_L6_123456789abc hash:net family inet6\n' +
			'add MCL_L6_123456789abc 2001:db8::/32\n',
		close: 0 }
};
let mismatch_firewall = find_section(evidence_module.create({ fs: {
	popen: (command, mode) => {
		let reply = mismatch_replies[command], read = false;
		if (reply == null) return null;
		return {
			read: () => { if (read) return ''; read = true; return reply.output; },
			close: () => reply.close
		};
	}
} }, {
	procd: domain_present, packages: domain_present, dns: domain_present,
	routes: domain_present, interfaces: domain_present, tun_tproxy: domain_present,
	guard: domain_present, schedulers: domain_present, memory: domain_present,
	operations: domain_present, recovery: domain_present
}).sections(), 'firewall');
assert_equal(length(mismatch_firewall.sets), 2,
	'a PR/OU/TI/TF generation mismatch revokes only that family');
assert_equal(mismatch_firewall.sets[0],
	'create MCL_L6_123456789abc hash:net family inet6');

let single_anchor_replies = { ...mismatch_replies,
	'/usr/sbin/iptables-save -t mangle': {
		output: '*mangle\n:PREROUTING ACCEPT [0:0]\n' +
			':MCL_AN_PR - [0:0]\n:MCL_PR_abcdefabcdef - [0:0]\n' +
			'-A PREROUTING -j MCL_AN_PR\n' +
			'-A MCL_AN_PR -j MCL_PR_abcdefabcdef\n' +
			'-A MCL_PR_abcdefabcdef -j TPROXY\nCOMMIT\n',
		close: 0 },
	'/usr/sbin/iptables-save -t filter': {
		output: '*filter\nCOMMIT\n', close: 0 }
};
let single_anchor_firewall = find_section(evidence_module.create({ fs: {
	popen: (command, mode) => {
		let reply = single_anchor_replies[command], read = false;
		if (reply == null) return null;
		return {
			read: () => { if (read) return ''; read = true; return reply.output; },
			close: () => reply.close
		};
	}
} }, {
	procd: domain_present, packages: domain_present, dns: domain_present,
	routes: domain_present, interfaces: domain_present, tun_tproxy: domain_present,
	guard: domain_present, schedulers: domain_present, memory: domain_present,
	operations: domain_present, recovery: domain_present
}).sections(), 'firewall');
assert_equal(length(single_anchor_firewall.sets), 2,
	'a single IPv4 anchor cannot authorize IPv4 ipsets');
assert_equal(single_anchor_firewall.sets[0],
	'create MCL_L6_123456789abc hash:net family inet6');

let partial_replies = { ...iptables_replies,
	'/usr/sbin/ip6tables-save -t filter': {
		output: 'ip6tables-save failed\n', close: 1 }
};
let partial_firewall = find_section(evidence_module.create({ fs: {
	popen: (command, mode) => {
		let reply = partial_replies[command], read = false;
		if (reply == null) return null;
		return {
			read: () => { if (read) return ''; read = true; return reply.output; },
			close: () => reply.close
		};
	}
} }, {
	procd: domain_present, packages: domain_present, dns: domain_present,
	routes: domain_present, interfaces: domain_present, tun_tproxy: domain_present,
	guard: domain_present, schedulers: domain_present, memory: domain_present,
	operations: domain_present, recovery: domain_present
}).sections(), 'firewall');
assert_equal(partial_firewall.state, 'unavailable');
assert_equal(partial_firewall.code, 'COLLECTION_UNAVAILABLE');
assert_equal(partial_firewall.message,
	'Complete iptables fallback evidence is unavailable');

let counterfeit_route_commands = [];
let counterfeit_routes = evidence_module.create({ fs: { popen: (command, mode) => {
	push(counterfeit_route_commands, command);
	let read = false;
	return {
		read: () => {
			if (read) return '';
			read = true;
			if (index(command, ' rule show') >= 0)
				return '[{"priority":1000,"fwmark":"0x1","table":100,"protocol":242}]\n';
			if (index(command, ' route show table 100') >= 0)
				return '[{"type":"local","dst":"default","dev":"lo","table":100,"protocol":242}]\n';
			return '[]\n';
		},
		close: () => 0
	};
} } }, {
	procd: domain_present, packages: domain_present, dns: domain_present,
	firewall: domain_present, interfaces: domain_present, tun_tproxy: domain_present,
	guard: domain_present, schedulers: domain_present, memory: domain_present,
	operations: domain_present, recovery: domain_present
}).sections();
let counterfeit_routes_section = find_section(counterfeit_routes, 'routes');
assert_equal(counterfeit_routes_section.state, 'unavailable');
assert_equal(counterfeit_routes_section.code, 'OWNERSHIP_UNVERIFIED');
assert_true(counterfeit_routes_section.routes == null &&
	counterfeit_routes_section.rules == null,
	'foreign reserved table/protocol/mark tuples are never emitted as MiClash evidence');

let bin_opkg_commands = [];
let bin_opkg_runtime = { fs: { popen: (command, mode) => {
	push(bin_opkg_commands, command);
	if (command != '/bin/opkg status luci-app-miclash') return null;
	let read = false;
	return {
		read: () => {
			if (read) return '';
			read = true;
			return 'Package: luci-app-miclash\nVersion: 2.0.1\n' +
				'Status: install user installed\n';
		},
		close: () => 0
	};
} } };
let bin_opkg_sections = evidence_module.create(bin_opkg_runtime, {
	procd: domain_present, dns: domain_present, firewall: domain_present,
	routes: domain_present, interfaces: domain_present, tun_tproxy: domain_present,
	guard: domain_present, schedulers: domain_present, memory: domain_present,
	operations: domain_present, recovery: domain_present
}).sections();
let bin_opkg = find_section(bin_opkg_sections, 'packages');
assert_equal(bin_opkg.manager, 'opkg');
assert_equal(bin_opkg.packages[0].version, '2.0.1');

print('diagnostic evidence tests passed\n');
