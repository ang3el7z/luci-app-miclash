import { assert_equal, assert_throws } from 'testlib';
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

assert_throws(() => daemon.compose({}, {}), 'INVALID_ARGUMENT');
assert_throws(() => daemon.compose({
	ubus: { connect: () => null }, clock: { now: () => 0 }, paths: { tmp: '/tmp/miclash' }
}, {}), 'INTERNAL');

print('daemon boundary tests passed\n');
