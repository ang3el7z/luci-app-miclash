import * as errors from 'miclash.errors';

function invalid() { errors.fail('INVALID_ARGUMENT'); };

export function detect_package_manager(runtime) {
	for (let candidate in [ [ 'apk', '/usr/bin/apk' ], [ 'apk', '/bin/apk' ],
	    [ 'opkg', '/bin/opkg' ], [ 'opkg', '/usr/bin/opkg' ] ]) {
		let result = null;
		try {
			result = runtime?.process?.run({ command: candidate[1], args: [ '--version' ],
				timeout_ms: 5000 });
		}
		catch (error) { result = null; }
		if (result?.code === 0) return candidate[0];
	}
	return '';
};

export function miclash_assets(manager, version) {
	if ((manager != 'apk' && manager != 'opkg') || type(version) != 'string' ||
	    !match(version, /^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z][0-9A-Za-z.-]*)?$/))
		invalid();
	let package_name = manager == 'apk'
		? 'luci-app-miclash-' + version + '.apk'
		: 'luci-app-miclash_' + version + '_all.ipk';
	return {
		package_name,
		checksum_name: package_name + '.sha256',
		installer_checksum_name: 'install-miclash.sh.sha256',
		manifest_name: 'miclash-release-manifest.json'
	};
};
