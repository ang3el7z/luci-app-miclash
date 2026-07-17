'use strict';
'require view.miclash.api';

async function detectPackageManager() {
	const api = view_miclash_api.create();
	try {
		const info = await api.system_info();
		return /^(apk|opkg)$/.test(String(info?.package_manager || ''))
			? { type: info.package_manager } : null;
	} finally { api.destroy(); }
}

async function getOpenWrtReleaseVersion() {
	const api = view_miclash_api.create();
	try { return String((await api.system_info())?.openwrt_version || ''); }
	catch (_) { return ''; }
	finally { api.destroy(); }
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

async function ensureCurlAvailable() { return true; }

return L.Class.extend({
	detectPackageManager: detectPackageManager,
	ensureCurlAvailable: ensureCurlAvailable,
	getOpenWrtReleaseVersion: getOpenWrtReleaseVersion,
	parseOpenWrtReleaseVersion: parseOpenWrtReleaseVersion
});
