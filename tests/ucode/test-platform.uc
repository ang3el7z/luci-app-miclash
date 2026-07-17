import { assert_equal, assert_throws } from 'testlib';
import * as platform from 'miclash.platform';
import * as fakes from './fakes.uc';

let process = fakes.process({
	'/usr/bin/apk:--version': { code: 127 },
	'/bin/apk:--version': { code: 1 },
	'/bin/opkg:--version': { code: 0 }
});
assert_equal(platform.detect_package_manager({ process }), 'opkg');
assert_equal(length(process.calls), 3,
	'package manager detection accepted a failed probe');

let opkg = platform.miclash_assets('opkg', '2.0.0');
assert_equal(opkg.package_name, 'luci-app-miclash_2.0.0_all.ipk');
assert_equal(opkg.checksum_name, 'luci-app-miclash_2.0.0_all.ipk.sha256');
assert_equal(opkg.installer_checksum_name, 'install-miclash.sh.sha256');
assert_equal(opkg.manifest_name, 'miclash-release-manifest.json');
assert_equal(platform.miclash_assets('apk', '2.0.0').package_name,
	'luci-app-miclash-2.0.0.apk');
assert_equal(platform.miclash_assets('apk', '2.0.0-rc.1').checksum_name,
	'luci-app-miclash-2.0.0-rc.1.apk.sha256');

for (let invalid in [
	() => platform.miclash_assets('rpm', '2.0.0'),
	() => platform.miclash_assets('apk', 'v2.0.0'),
	() => platform.miclash_assets('apk', '../2.0.0')
]) assert_throws(invalid, 'INVALID_ARGUMENT');
