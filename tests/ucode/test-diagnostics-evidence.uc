import * as evidence_module from 'miclash.diagnostics-evidence';
import { assert_equal, assert_true } from './testlib.uc';

let commands = [];
let log_source = '';
log_source += 'Jul 23 01:00:00 router dnsmasq[1]: query[A] example.test from 192.0.2.1\n';
log_source += 'Jul 23 01:00:01 router netifd: Interface wan is now up\n';
log_source += 'Jul 23 01:00:02 router firewall: Reloading firewall\n';
log_source += 'Jul 23 01:00:03 router kernel: tun0: entered promiscuous mode\n';
log_source += 'Jul 23 01:00:04 router dropbear[1]: unrelated\n';
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
let sections = [];
for (let section in evidence.sections()) push(sections, section);
assert_equal(sections[0].name, 'procd');
assert_equal(sections[0].value.state, 'ready');
let interfaces = null;
for (let section in sections) if (section.name == 'interfaces') interfaces = section;
assert_equal(interfaces.value.state, 'unavailable');
assert_equal(interfaces.value.code, 'UNAVAILABLE');

let logs = [];
for (let entry in evidence.logs()) push(logs, entry);
assert_true(index(map(logs, (value) => value.component), 'dnsmasq') >= 0);
assert_true(index(map(logs, (value) => value.component), 'netifd') >= 0);
assert_equal(length(logs), 4, 'all available relevant log lines are yielded');
let log_command = commands[length(commands) - 1];
assert_equal(log_command.command, '/sbin/logread');
assert_equal(log_command.mode, 'r');

print('diagnostic evidence tests passed\n');
