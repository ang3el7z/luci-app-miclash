import * as errors from 'miclash.errors';

function invalid() { errors.fail('INVALID_ARGUMENT'); };

export function detect_package_manager(runtime) {
	for (let candidate in [ [ 'apk', '/usr/bin/apk' ], [ 'apk', '/bin/apk' ],
	    [ 'opkg', '/bin/opkg' ], [ 'opkg', '/usr/bin/opkg' ] ]) {
		let metadata = null;
		try {
			metadata = runtime?.fs?.stat(candidate[1]);
		}
		catch (error) { metadata = null; }
		if (metadata?.type == 'file' && type(metadata.mode) == 'int' &&
		    (metadata.mode & 0o111) != 0) return candidate[0];
	}
	return '';
};

export function miclash_assets(manager, version) {
	if ((manager != 'apk' && manager != 'opkg') || type(version) != 'string' ||
	    !match(version,
	      /^[0-9]+\.[0-9]+\.[0-9]+(([.-][0-9A-Za-z][0-9A-Za-z.-]*)|(_rc[0-9]+))?$/))
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
