'use strict';
'require fs';

async function getOpenWrtReleaseVersion() {
	try {
		const release = await fs.read('/etc/openwrt_release');
		const line = String(release || '').split('\n').find((item) => item.indexOf('DISTRIB_RELEASE=') === 0);
		return line ? line.split('=')[1].replace(/["']/g, '').trim() : '';
	} catch (e) {
		return '';
	}
}

async function detectPackageManager() {
	const checks = [
		{ type: 'apk', bin: '/usr/bin/apk' },
		{ type: 'apk', bin: '/bin/apk' },
		{ type: 'opkg', bin: '/bin/opkg' },
		{ type: 'opkg', bin: '/usr/bin/opkg' }
	];

	for (let i = 0; i < checks.length; i++) {
		try {
			const probe = await fs.exec(checks[i].bin, ['--version']);
			if (probe && typeof probe.code === 'number') return checks[i];
		} catch (e) {}
	}

	return null;
}

async function execOrThrow(bin, args, fallbackMessage) {
	const result = await fs.exec(bin, args);
	if (result.code === 0) return result;
	throw new Error(String(result.stderr || result.stdout || fallbackMessage || _('Command failed')).trim());
}

async function installMiClashDependencies(manager) {
	await execOrThrow(manager.bin, ['update'], _('Failed to update package index.'));

	if (manager.type === 'apk') {
		await execOrThrow(
			manager.bin,
			['add', 'zlib', 'libcurl4', 'curl', 'kmod-nft-tproxy', 'kmod-tun', 'coreutils-base64'],
			_('Failed to install MiClash dependencies.')
		);
		return;
	}

	const release = await getOpenWrtReleaseVersion();
	const majorMatch = String(release || '').match(/^(\d+)/);
	const major = majorMatch ? parseInt(majorMatch[1], 10) : 0;
	const tproxyPkg = major > 0 && major < 23 ? 'iptables-mod-tproxy' : 'kmod-nft-tproxy';

	await execOrThrow(
		manager.bin,
		['install', 'zlib', 'libcurl4', 'curl', tproxyPkg, 'kmod-tun', 'coreutils-base64'],
		_('Failed to install MiClash dependencies.')
	);
}

async function reinstallCurlDependencies(manager) {
	await execOrThrow(manager.bin, ['update'], _('Failed to update package index.'));

	if (manager.type === 'apk') {
		await execOrThrow(
			manager.bin,
			['fix', 'zlib', 'libcurl4', 'curl'],
			_('Failed to install MiClash dependencies.')
		);
		return;
	}

	await execOrThrow(
		manager.bin,
		['--force-reinstall', 'install', 'zlib', 'libcurl4', 'curl'],
		_('Failed to install MiClash dependencies.')
	);
}

async function ensureCurlAvailable() {
	const probe = await fs.exec('/usr/bin/curl', ['--version']);
	if (probe.code === 0) return;

	const manager = await detectPackageManager();
	if (!manager) throw new Error(_('No supported package manager found (apk/opkg).'));

	await installMiClashDependencies(manager);

	const retry = await fs.exec('/usr/bin/curl', ['--version']);
	if (retry.code !== 0) {
		await reinstallCurlDependencies(manager);
		const forcedRetry = await fs.exec('/usr/bin/curl', ['--version']);
		if (forcedRetry.code !== 0) {
			throw new Error(String(forcedRetry.stderr || forcedRetry.stdout || retry.stderr || retry.stdout || _('Failed to install MiClash dependencies.')).trim());
		}
	}
}

return L.Class.extend({
	getOpenWrtReleaseVersion: getOpenWrtReleaseVersion,
	detectPackageManager: detectPackageManager,
	execOrThrow: execOrThrow,
	installMiClashDependencies: installMiClashDependencies,
	ensureCurlAvailable: ensureCurlAvailable
});
