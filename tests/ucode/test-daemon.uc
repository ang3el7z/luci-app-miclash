import { assert_equal, assert_throws } from 'testlib';
import * as daemon from 'miclash.daemon';
import * as platform from 'miclash.platform';
import * as fakes from './fakes.uc';

assert_equal(daemon.parse_openwrt_version("DISTRIB_RELEASE='24.10.2'\n", ''), '24.10.2');
assert_equal(daemon.parse_openwrt_version("DISTRIB_RELEASE='SNAPSHOT'\n",
	'VERSION_ID="25.12"\n'), '25.12');
assert_equal(daemon.parse_openwrt_version('',
	'PRETTY_NAME="OpenWrt 26.01.1 development"\n'), '26.01.1');

let manager_probe = fakes.process({
	'/usr/bin/apk:--version': { code: 127 }, '/bin/apk:--version': { code: 1 },
	'/bin/opkg:--version': { code: 0 }
});
assert_equal(platform.detect_package_manager({ process: manager_probe }), 'opkg');
assert_equal(length(manager_probe.calls), 3);

assert_throws(() => daemon.compose({}, {}), 'INVALID_ARGUMENT');
assert_throws(() => daemon.compose({
	ubus: { connect: () => null }, clock: { now: () => 0 }, paths: { tmp: '/tmp/miclash' }
}, {}), 'INTERNAL');

print('daemon boundary tests passed\n');
