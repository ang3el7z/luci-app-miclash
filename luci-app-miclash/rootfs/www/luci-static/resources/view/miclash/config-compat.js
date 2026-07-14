'use strict';
'require fs';
'require view.miclash.config';
'require view.miclash.package';
'require view.miclash.release';

const PACKAGE_NAME = 'luci-app-miclash';

async function getInstalledAppVersion() {
	const manager = await view_miclash_package.detectPackageManager();
	if (!manager) return '';

	const args = manager.type === 'apk'
		? ['info', '-v', PACKAGE_NAME]
		: ['list-installed', PACKAGE_NAME];

	try {
		const result = await fs.exec(manager.bin, args);
		if (!result || result.code !== 0) return '';

		const raw = String(result.stdout || '') + '\n' + String(result.stderr || '');
		const parsed = view_miclash_release.parsePackageVersion(raw, PACKAGE_NAME);
		return parsed ? view_miclash_release.normalizeAppVersion(parsed) : '';
	} catch (e) {
		return '';
	}
}

const baseLoad = view_miclash_config.load;

view_miclash_config.load = async function() {
	const data = await baseLoad.apply(this, arguments);
	const installedVersion = await getInstalledAppVersion();

	if (installedVersion) {
		data[4] = data[4] || { app: 'unknown', clash: 'unknown' };
		data[4].app = installedVersion;
	}

	return data;
};

return view_miclash_config;
