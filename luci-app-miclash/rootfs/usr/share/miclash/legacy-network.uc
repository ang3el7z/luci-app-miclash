import { fail } from 'miclash.errors';
import { with_lock } from 'miclash.mutation_lock';
import * as routing from 'miclash.routing';
import * as dns from 'miclash.dns';

const LEGACY_FILES = [
	'/var/etc/miclash.include',
	'/etc/hotplug.d/iface/40-clash',
	'/etc/hotplug.d/net/99-clash-tun',
	'/tmp/clash/bridge_nf_call_iptables_flag',
	'/tmp/clash/bridge_nf_call_ip6tables_flag'
];
const DNS_FILES = [ '/etc/miclash/dns-ownership.json', '/opt/clash/.dns_backup' ];
const ROUTING_MANIFEST = '/var/run/miclash/routing-ownership.json';

function ok(runtime, command, args) {
	return runtime.process.run({ command, args })?.code == 0;
};

function captured(runtime, command) {
	let popen = runtime.fs?.popen ?? require('fs').popen;
	let pipe = popen('/usr/bin/timeout -s KILL 2 ' + command + ' 2>/dev/null', 'r');
	if (pipe == null) return null;
	let output = '', failed = false;
	while (length(output) <= 262144) {
		let chunk;
		try { chunk = pipe.read(4096); } catch (error) { failed = true; break; }
		if (type(chunk) != 'string') { failed = true; break; }
		if (!length(chunk)) break;
		output += chunk;
	}
	let closed = null;
	try { closed = pipe.close(); } catch (error) { failed = true; }
	if (failed || length(output) > 262144 || (closed !== 0 && closed !== true)) return null;
	return output;
};

function legacy_routes_present(runtime) {
	for (let command in [ 'ip -4 rule show', 'ip -6 rule show' ]) {
		let value = captured(runtime, command);
		if (value == null ||
		    match(value, /fwmark (0x)?(1|3)(\/0xffffffff)? .*lookup (100|101)/) != null)
			return true;
	}
	for (let command in [ 'ip -4 route show table 100', 'ip -6 route show table 100',
	    'ip -4 route show table 101', 'ip -6 route show table 101' ]) {
		let value = captured(runtime, command);
		// iproute2 reports a missing table with a non-zero status and no stdout.
		// That is the canonical clean-install absence, not ambiguous ownership.
		if (value != null && length(trim(value))) return true;
	}
	return false;
};

function firewall_section(runtime) {
	try { return runtime.uci.cursor().get_all('firewall', 'miclash') != null; }
	catch (error) { return true; }
};

export function present(runtime) {
	for (let path in [ ...LEGACY_FILES, ...DNS_FILES, ROUTING_MANIFEST ])
		if (runtime.fs.lstat(path) != null) return true;
	if (firewall_section(runtime) || legacy_routes_present(runtime)) return true;
	for (let table in [ 'clash', 'miclash_guard' ])
		if (ok(runtime, 'nft', [ 'list', 'table', 'inet', table ])) return true;
	if (ok(runtime, 'ipset', [ 'list', 'clash_fakeip_whitelist' ])) return true;
	for (let command in [ 'iptables', 'ip6tables' ])
		for (let item in [ [ 'mangle', 'CLASH' ], [ 'mangle', 'CLASH_PROCESS' ],
		    [ 'mangle', 'CLASH_LOCAL' ], [ 'nat', 'CLASH_OUTPUT_REDIRECT' ],
		    [ 'filter', 'MICLASH_GUARD_FORWARD' ], [ 'filter', 'MICLASH_GUARD_OUTPUT' ] ])
			if (ok(runtime, command, [ '-t', item[0], '-S', item[1] ])) return true;
	return false;
};

function delete_repeated(runtime, command, args) {
	for (let attempt = 0; attempt < 64; attempt++)
		if (!ok(runtime, command, args)) return true;
	fail('RESOURCE_EXHAUSTED');
};

function delete_fw4_comments(runtime) {
	for (let chain in [ 'input', 'forward' ]) {
		let value = captured(runtime, 'nft -a list chain inet fw4 ' + chain);
		if (value == null) continue;
		let handles = [];
		for (let line in split(value, '\n')) {
			if (index(line, 'miclash-fwd') < 0) continue;
			let found = match(line, /# handle ([1-9][0-9]*)$/);
			if (found == null || index(handles, found[1]) >= 0) fail('CORRUPT_STATE');
			push(handles, found[1]);
		}
		for (let handle in handles)
			if (!ok(runtime, 'nft', [ 'delete', 'rule', 'inet', 'fw4', chain, 'handle', handle ]))
				fail('INTERNAL');
	}
};

function cleanup_iptables(runtime, command) {
	for (let args in [
		[ '-t', 'filter', '-D', 'INPUT', '-i', 'clash-tun', '-j', 'ACCEPT' ],
		[ '-t', 'filter', '-D', 'FORWARD', '-i', 'clash-tun', '-j', 'ACCEPT' ],
		[ '-t', 'filter', '-D', 'FORWARD', '-o', 'clash-tun', '-j', 'ACCEPT' ],
		[ '-t', 'filter', '-D', 'INPUT', '-p', 'udp', '--dport', '443', '-j', 'REJECT' ],
		[ '-t', 'filter', '-D', 'FORWARD', '-p', 'udp', '--dport', '443', '-j', 'REJECT' ],
		[ '-t', 'mangle', '-D', 'PREROUTING', '-j', 'CLASH' ],
		[ '-t', 'mangle', '-D', 'OUTPUT', '-j', 'CLASH_LOCAL' ],
		[ '-t', 'nat', '-D', 'OUTPUT', '-j', 'CLASH_OUTPUT_REDIRECT' ],
		[ '-t', 'filter', '-D', 'FORWARD', '-j', 'MICLASH_GUARD_FORWARD' ],
		[ '-t', 'filter', '-D', 'OUTPUT', '-j', 'MICLASH_GUARD_OUTPUT' ]
	]) delete_repeated(runtime, command, args);
	for (let item in [ [ 'mangle', 'CLASH_PROCESS' ], [ 'mangle', 'CLASH_LOCAL' ],
	    [ 'mangle', 'CLASH' ], [ 'nat', 'CLASH_OUTPUT_REDIRECT' ],
	    [ 'filter', 'MICLASH_GUARD_FORWARD' ], [ 'filter', 'MICLASH_GUARD_OUTPUT' ] ]) {
		if (!ok(runtime, command, [ '-t', item[0], '-S', item[1] ])) continue;
		if (!ok(runtime, command, [ '-t', item[0], '-F', item[1] ]) ||
		    !ok(runtime, command, [ '-t', item[0], '-X', item[1] ])) fail('INTERNAL');
	}
};

function cleanup_firewall(runtime) {
	delete_fw4_comments(runtime);
	for (let table in [ 'clash', 'miclash_guard' ])
		if (ok(runtime, 'nft', [ 'list', 'table', 'inet', table ]) &&
		    !ok(runtime, 'nft', [ 'delete', 'table', 'inet', table ])) fail('INTERNAL');
	cleanup_iptables(runtime, 'iptables');
	cleanup_iptables(runtime, 'ip6tables');
	if (ok(runtime, 'ipset', [ 'list', 'clash_fakeip_whitelist' ]) &&
	    !ok(runtime, 'ipset', [ 'destroy', 'clash_fakeip_whitelist' ]))
		fail('INTERNAL');
	return true;
};

function cleanup_routes(runtime) {
	if (runtime.fs.lstat(ROUTING_MANIFEST) != null)
		routing.cleanup(runtime, routing.observe(runtime));
	for (let family in [ '-4', '-6' ]) {
		for (let item in [ [ 'local', 'default', 'dev', 'lo', 'table', '100' ],
		    [ 'default', 'dev', 'clash-tun', 'table', '100' ],
		    [ 'unreachable', 'default', 'metric', '42760', 'table', '100' ],
		    [ 'default', 'dev', 'clash-tun', 'table', '101' ],
		    [ 'unreachable', 'default', 'metric', '42760', 'table', '101' ] ])
			delete_repeated(runtime, 'ip', [ family, 'route', 'del', ...item ]);
		for (let item in [ [ 'fwmark', '0x1', 'table', '100' ],
		    [ 'fwmark', '0x3', 'table', '101' ] ])
			delete_repeated(runtime, 'ip', [ family, 'rule', 'del', ...item ]);
	}
	return true;
};

function cleanup_dns(runtime) {
	let owned = false;
	for (let path in DNS_FILES) owned = owned || runtime.fs.lstat(path) != null;
	if (owned) dns.cleanup(runtime);
	return true;
};

function cleanup_artifacts(runtime) {
	let cursor = runtime.uci.cursor();
	if (cursor.get_all('firewall', 'miclash') != null) {
		if (cursor.delete('firewall', 'miclash') !== true || cursor.commit('firewall') !== true)
			fail('INTERNAL');
		if (length(keys(cursor.changes('firewall') ?? {}))) fail('INTERNAL');
	}
	for (let path in LEGACY_FILES) {
		let stat = runtime.fs.lstat(path);
		if (stat == null) continue;
		if ((path == LEGACY_FILES[3] || path == LEGACY_FILES[4]) && stat.type != 'file')
			fail('CORRUPT_STATE');
		if (path == LEGACY_FILES[3] && !ok(runtime, 'sysctl', [ '-q', '-w', 'net.bridge.bridge-nf-call-iptables=1' ]))
			fail('INTERNAL');
		if (path == LEGACY_FILES[4] && !ok(runtime, 'sysctl', [ '-q', '-w', 'net.bridge.bridge-nf-call-ip6tables=1' ]))
			fail('INTERNAL');
		if (runtime.fs.unlink(path) !== true || runtime.fs.lstat(path) != null) fail('INTERNAL');
	}
	return true;
};

export function handoff(runtime, injected) {
	if (type(runtime?.guard_control?.protect) != 'function' ||
	    type(runtime?.guard_control?.verify_protected) != 'function') fail('INVALID_ARGUMENT');
	if (injected != null && type(injected) != 'object') fail('INVALID_ARGUMENT');
	let app = { present, cleanup_firewall, cleanup_routes, cleanup_dns,
		cleanup_artifacts, verify: (rt) => !present(rt), with_lock, ...(injected ?? {}) };
	for (let name in [ 'present', 'cleanup_firewall', 'cleanup_routes', 'cleanup_dns',
	    'cleanup_artifacts', 'verify', 'with_lock' ])
		if (type(app[name]) != 'function') fail('INVALID_ARGUMENT');
	if (app.present(runtime) !== true) return { changed: false, guard_retained: false };
	return app.with_lock(runtime, { barrier: 'normal', wait_ms: 0 }, () => {
		// Temporary native Guard is the sole bridge between legacy teardown and
		// the first verified native network generation. It is intentionally not
		// released here, including canonical OFF upgrades.
		if (runtime.guard_control.protect() !== true ||
		    runtime.guard_control.verify_protected() !== true) fail('HEALTH_FAILED');
		for (let name in [ 'cleanup_firewall', 'cleanup_routes', 'cleanup_dns', 'cleanup_artifacts' ])
			if (app[name](runtime) !== true) fail('INTERNAL');
		if (app.verify(runtime) !== true) fail('HEALTH_FAILED');
		return { changed: true, guard_retained: true };
	});
};
