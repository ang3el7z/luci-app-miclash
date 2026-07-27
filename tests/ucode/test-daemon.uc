import { assert_equal, assert_throws, assert_true } from 'testlib';
import * as daemon from 'miclash.daemon';
import * as platform from 'miclash.platform';
import * as fakes from './fakes.uc';

assert_equal(daemon.parse_openwrt_version("DISTRIB_RELEASE='24.10.2'\n", ''), '24.10.2');
assert_equal(daemon.parse_openwrt_version("DISTRIB_RELEASE='SNAPSHOT'\n",
	'VERSION_ID="25.12"\n'), '25.12');
assert_equal(daemon.parse_openwrt_version('',
	'PRETTY_NAME="OpenWrt 26.01.1 development"\n'), '26.01.1');

let manager_probe_calls = 0;
assert_equal(platform.detect_package_manager({
	fs: { stat: (path) => path == '/bin/opkg' ? { type: 'file', mode: 0o755 } : null },
	process: { run: () => { manager_probe_calls++; return { code: 0 }; } }
}), 'opkg');
assert_equal(manager_probe_calls, 0);

let binary_output = 'Mihomo Meta v1.19.10 linux arm64 with go1.24.6\n';
let binary_reads = 0;
let binary_runtime = { fs: {
	realpath: (path) => path,
	popen: (command, mode) => {
		assert_equal(command, '/opt/clash/bin/clash -v 2>&1');
		assert_equal(mode, 'r');
		return {
			read: (amount) => binary_reads++ == 0 ? binary_output : '',
			close: () => 0
		};
	}
} };
assert_equal(daemon.mihomo_version(binary_runtime,
	{ type: 'file', nlink: 1, uid: 0 }), '1.19.10',
	'API is unavailable but the fixed installed binary reports version 1.19.10');

let log_source = '';
for (let i = 0; i < 250; i++)
	log_source += sprintf('Mon Jul 20 02:00:%02d 2026 daemon.info miclash: event-%d\n', i % 60, i);
log_source += 'Mon Jul 20 02:05:00 2026 daemon.info clash-rules: routing ready\n';
log_source += 'Mon Jul 20 02:05:01 2026 daemon.info clash-hotplug: wan ready\n';
log_source += 'Mon Jul 20 02:05:02 2026 daemon.info clash: core ready\n';
log_source += 'Mon Jul 20 02:05:03 2026 daemon.info mihomo: api ready\n';
let log_reads = 0;
let log_runtime = { fs: { popen: (command, mode) => {
	assert_equal(command,
		"/sbin/logread 2>/dev/null | /bin/grep -E '(^|[[:space:]])(miclash|mihomo|clash)(\\[[0-9]+\\])?:[[:space:]]'");
	assert_equal(mode, 'r');
	return {
		read: (amount) => log_reads++ == 0 ? log_source : '',
		close: () => 0
	};
} } };
let selected_logs = daemon.bounded_logs(log_runtime);
assert_equal(length(split(selected_logs, '\n')), 252);
assert_true(index(selected_logs, 'event-0') >= 0, 'older MiClash log was dropped');
assert_true(index(selected_logs, 'clash-rules: routing ready') < 0);
assert_true(index(selected_logs, 'clash-hotplug: wan ready') < 0);
assert_true(index(selected_logs, 'clash: core ready') >= 0);
assert_true(index(selected_logs, 'mihomo: api ready') >= 0);

function component_status(service, network_state, guard_enabled, guard_document) {
	let filesystem = fakes.fs(guard_document == null ? {} : {
		'/var/run/miclash/guard-bootstrap.json': sprintf('%J', guard_document)
	});
	return daemon.observed_component_status({ fs: filesystem }, {
		observe_components: () => network_state
	}, service, { guard: { enabled: guard_enabled } });
};
let system_network = {
	dns: { state: 'system' }, firewall: { state: 'system' }, routing: { state: 'system' }
};
assert_equal(sprintf('%J', component_status({ state: 'stopped', running: false },
	system_network, false, { schema_version: 1, enabled: false, installed: false })),
	sprintf('%J', { guard: { state: 'disabled' }, dns: { state: 'system' },
		firewall: { state: 'system' }, routing: { state: 'system' } }),
	'clean stopped mode was not exposed as verified OpenWrt ownership');
assert_equal(component_status({ state: 'stopped', running: false }, system_network, true,
	{ schema_version: 1, enabled: true, installed: true }).firewall.state, 'guard',
	'verified fail-closed firewall was not exposed as Guard-owned');
let active_network = {
	dns: { state: 'active' }, firewall: { state: 'active' }, routing: { state: 'active' }
};
let running_components = component_status({ state: 'running', running: true }, active_network,
	false, { schema_version: 1, enabled: false, installed: false });
for (let name in [ 'dns', 'firewall', 'routing' ])
	assert_equal(running_components[name].state, 'ready');
let stale_components = component_status({ state: 'stopped', running: false }, active_network,
	false, { schema_version: 1, enabled: false, installed: false });
for (let name in [ 'dns', 'firewall', 'routing' ])
	assert_equal(stale_components[name].state, 'failed',
		'stale active ' + name + ' ownership was hidden after service stop');

let page_source = 'Mon Jul 20 02:00:00 2026 daemon.info miclash: first\n' +
	'Mon Jul 20 02:00:01 2026 daemon.info miclash: second\n';
let page_runtime = {
	digest: fakes.digest(fakes.fs()),
	fs: { popen: (command, mode) => {
		let read = false;
		return { read: (amount) => { if (read) return ''; read = true; return page_source; },
			close: () => 0 };
	} }
};
let log_reader = daemon.create_log_reader(page_runtime);
let first_page = log_reader.read({ generation: null, cursor: 0, limit: 200 });
assert_equal(length(first_page.lines), 2);
assert_equal(first_page.next_cursor, 2);
page_source += 'Mon Jul 20 02:00:02 2026 daemon.info miclash: third\n';
let appended_page = log_reader.read({ generation: first_page.generation,
	cursor: first_page.next_cursor, limit: 200 });
assert_equal(appended_page.stale, false);
assert_equal(length(appended_page.lines), 1);
assert_true(index(appended_page.lines[0], 'third') >= 0);
page_source = 'Mon Jul 20 02:01:00 2026 daemon.info miclash: after rotation\n';
let rotated_page = log_reader.read({ generation: first_page.generation,
	cursor: appended_page.next_cursor, limit: 200 });
assert_equal(rotated_page.stale, true);
assert_true(rotated_page.generation != first_page.generation);

assert_throws(() => daemon.compose({}, {}), 'INVALID_ARGUMENT');
assert_throws(() => daemon.compose({
	ubus: { connect: () => null }, clock: { now: () => 0 }, paths: { tmp: '/tmp/miclash' }
}, {
	operations: { create: () => ({ recover_interrupted: () => true }) }
}), 'INTERNAL');

print('daemon boundary tests passed\n');
