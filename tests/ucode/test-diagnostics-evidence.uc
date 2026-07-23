import * as evidence_module from 'miclash.diagnostics-evidence';
import { assert_equal, assert_true } from './testlib.uc';

function find_section(sections, name) {
	for (let section in sections) if (section.name == name) return section.value;
	return null;
};

let commands = [];
let log_source = '';
log_source += 'Thu Jul 23 01:00:00 2026 daemon.info dnsmasq[1234]: query[A] example.test from 192.0.2.1\n';
log_source += 'Thu Jul 23 01:00:01 2026 daemon.notice netifd: Interface wan is now up\n';
log_source += 'Thu Jul 23 01:00:02 2026 user.notice firewall: Reloading firewall\n';
log_source += 'Thu Jul 23 01:00:03 2026 kern.warn kernel: TUN device entered promiscuous mode\n';
log_source += 'Thu Jul 23 01:00:04 2026 authpriv.info dropbear[1]: unrelated\n';
let runtime = { fs: { popen: (command, mode) => {
	push(commands, { command, mode });
	let read = false;
	return {
		read: (amount) => { if (read) return ''; read = true; return log_source; },
		close: () => 0
	};
} } };
let evidence = evidence_module.create(runtime, {
	procd: () => ({ state: 'ready' }),
	interfaces: () => null
});

let logs = [];
for (let entry in evidence.logs()) push(logs, entry);
assert_equal(length(logs), 4, 'all available relevant log lines are yielded');
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
assert_equal(evidence.logs_status().state, 'present');
assert_equal(evidence.logs_status().records, 4);
let log_command = commands[length(commands) - 1];
assert_equal(log_command.command, '/sbin/logread');
assert_equal(log_command.mode, 'r');

let sections = [];
for (let section in evidence.sections()) push(sections, section);
assert_equal(sections[0].name, 'procd');
assert_equal(sections[0].value.state, 'ready');
assert_equal(find_section(sections, 'interfaces').state, 'unavailable');
assert_equal(find_section(sections, 'interfaces').code, 'COLLECTION_UNAVAILABLE');

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
assert_equal(length(failed_logs.logs()), 0);
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
	routes: () => ({ state: 'present', routes: [], rules: [], ownership: { status: 'trusted' } }),
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
assert_equal(find_section(adapter_sections, 'operations').records[0].id, 'op-1');
assert_true(index(adapter_commands, '/usr/sbin/nft list ruleset') < 0,
	'firewall evidence never captures the whole nft ruleset');
assert_equal(length(filter(adapter_commands,
	(command) => command == '/bin/ubus call service list')), 0,
	'unrelated full procd state is never reused for other collectors');

let iptables_commands = [];
let iptables_replies = {
	'/usr/sbin/nft -j list table inet miclash': {
		output: 'Error: No such file or directory\n', close: 1 },
	'/usr/sbin/iptables-save -t mangle': {
		output: '*mangle\n:PREROUTING ACCEPT [0:0]\n:MCL_PR_abcdefabcdef - [0:0]\n' +
			'-A PREROUTING -j unrelated\n-A MCL_PR_abcdefabcdef -j TPROXY\nCOMMIT\n',
		close: 0 },
	'/usr/sbin/iptables-save -t filter': {
		output: '*filter\n:MCL_TI_abcdefabcdef - [0:0]\n-A INPUT -j unrelated\n' +
			'-A MCL_TI_abcdefabcdef -j ACCEPT\nCOMMIT\n',
		close: 0 },
	'/usr/sbin/ip6tables-save -t mangle': { output: '*mangle\nCOMMIT\n', close: 0 },
	'/usr/sbin/ip6tables-save -t filter': { output: '*filter\nCOMMIT\n', close: 0 },
	'/usr/sbin/ipset save': {
		output: 'create unrelated hash:net family inet\n' +
			'create MCL_L4_abcdefabcdef hash:net family inet\n' +
			'add unrelated 192.0.2.1\nadd MCL_L4_abcdefabcdef 198.51.100.0/24\n',
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
	':MCL_PR_abcdefabcdef - [0:0]');
assert_equal(iptables_firewall.documents[0].lines[1],
	'-A MCL_PR_abcdefabcdef -j TPROXY');
assert_equal(length(iptables_firewall.documents[0].lines), 2,
	'unrelated iptables rules are excluded');
assert_equal(iptables_firewall.sets[0],
	'create MCL_L4_abcdefabcdef hash:net family inet');
assert_equal(iptables_firewall.sets[1],
	'add MCL_L4_abcdefabcdef 198.51.100.0/24');
assert_equal(length(iptables_firewall.sets), 2,
	'unrelated ipset objects are excluded');

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
