'use strict';
'require fs';

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
			if (probe && probe.code === 0) return checks[i];
		} catch (e) {}
	}

	return null;
}

async function getOpenWrtReleaseVersion() {
	try {
		const release = await fs.read('/etc/openwrt_release');
		const releaseVersion = parseOpenWrtReleaseVersion(release);
		if (releaseVersion) return releaseVersion;
	} catch (e) {
	}

	try {
		const osRelease = await fs.read('/etc/os-release');
		return parseOpenWrtReleaseVersion(osRelease);
	} catch (e) {
	}

	return '';
}

function parseReleaseValue(raw, key) {
	const prefix = key + '=';
	const line = String(raw || '').split('\n').find((item) => item.indexOf(prefix) === 0);
	return line ? line.slice(prefix.length).replace(/^['"]|['"]$/g, '').trim() : '';
}

function parseOpenWrtReleaseVersion(raw) {
	const release = String(raw || '');
	const distribRelease = parseReleaseValue(release, 'DISTRIB_RELEASE');
	if (distribRelease && distribRelease !== 'SNAPSHOT') return distribRelease;

	const versionId = parseReleaseValue(release, 'VERSION_ID');
	if (versionId) return versionId;

	const prettyName = parseReleaseValue(release, 'PRETTY_NAME');
	const prettyVersion = prettyName.match(/\b(\d+(?:\.\d+)+(?:[-.][0-9A-Za-z]+)?)\b/);
	if (prettyVersion) return prettyVersion[1];

	return distribRelease || '';
}

async function execOrThrow(bin, args, fallbackMessage) {
	const result = await fs.exec(bin, args);
	if (result.code === 0) return result;
	throw new Error(String(result.stderr || result.stdout || fallbackMessage || _('Command failed')).trim());
}

async function installCurlDependencies(manager) {
	await execOrThrow(manager.bin, ['update'], _('Failed to update package index.'));

	if (manager.type === 'apk') {
		await execOrThrow(manager.bin, ['add', 'zlib', 'libcurl4', 'curl'], _('Failed to install curl.'));
		return;
	}

	await execOrThrow(manager.bin, ['install', 'zlib', 'libcurl4', 'curl'], _('Failed to install curl.'));
}

async function reinstallCurlDependencies(manager) {
	await execOrThrow(manager.bin, ['update'], _('Failed to update package index.'));

	if (manager.type === 'apk') {
		await execOrThrow(manager.bin, ['fix', 'zlib', 'libcurl4', 'curl'], _('Failed to install curl.'));
		return;
	}

	await execOrThrow(manager.bin, ['--force-reinstall', 'install', 'zlib', 'libcurl4', 'curl'], _('Failed to install curl.'));
}

async function ensureCurlAvailable() {
	const probe = await fs.exec('/usr/bin/curl', ['--version']);
	if (probe.code === 0) return;

	const manager = await detectPackageManager();
	if (!manager) throw new Error(_('No supported package manager found (apk/opkg).'));

	await installCurlDependencies(manager);

	const retry = await fs.exec('/usr/bin/curl', ['--version']);
	if (retry.code === 0) return;

	await reinstallCurlDependencies(manager);
	const forcedRetry = await fs.exec('/usr/bin/curl', ['--version']);
	if (forcedRetry.code !== 0) {
		throw new Error(String(forcedRetry.stderr || forcedRetry.stdout || retry.stderr || retry.stdout || _('Failed to install curl.')).trim());
	}
}

return L.Class.extend({
	detectPackageManager: detectPackageManager,
	ensureCurlAvailable: ensureCurlAvailable,
	getOpenWrtReleaseVersion: getOpenWrtReleaseVersion,
	parseOpenWrtReleaseVersion: parseOpenWrtReleaseVersion
});
