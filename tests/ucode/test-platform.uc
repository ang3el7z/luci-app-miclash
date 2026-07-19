import { assert_equal, assert_throws } from 'testlib';
import * as platform from 'miclash.platform';

let probes = 0;
let filesystem = {
	stat: (path) => path == '/bin/opkg'
		? { type: 'file', mode: 0o755 }
		: (path == '/usr/bin/apk' ? { type: 'file', mode: 0o644 } : null)
};
assert_equal(platform.detect_package_manager({ fs: filesystem,
	process: { run: () => { probes++; return { code: 0 }; } } }), 'opkg');
assert_equal(probes, 0, 'package manager detection executed a noisy version probe');
assert_equal(platform.detect_package_manager({ fs: {
	stat: (path) => path == '/usr/bin/apk' ? { type: 'file', mode: 0o755 } : null
} }), 'apk');

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
