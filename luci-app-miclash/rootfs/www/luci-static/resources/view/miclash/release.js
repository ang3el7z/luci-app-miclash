'use strict';
'require view.miclash.api';

function parseVersion(raw, fallback) {
	const str = String(raw || '').trim();
	if (!str) return fallback;
	const matched = str.match(/(\d+\.\d+\.\d+(?:[-+][\w.-]+)?)/);
	return matched ? matched[1] : str.split('\n')[0];
}

function parsePackageVersion(raw, packageName) {
	const text = String(raw || '').trim();
	if (!text) return '';

	const escaped = String(packageName || '').replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
	const patterns = [
		new RegExp('(^|\\n)\\s*Package\\s*:\\s*' + escaped + '\\s*[\\s\\S]*?\\n\\s*Version\\s*:\\s*([^\\s\\n]+)', 'i'),
		new RegExp('^\\s*' + escaped + '\\s*-\\s*([^\\s]+)', 'im'),
		new RegExp('^\\s*' + escaped + '-([\\w.+~:-]+)', 'im')
	];

	for (let i = 0; i < patterns.length; i++) {
		const match = text.match(patterns[i]);
		const value = patterns[i].source.indexOf('Package') !== -1 ? match && match[2] : match && match[1];
		if (value) return value.trim();
	}

	return '';
}

function parseVersionFromOpkgStatus(raw, packageNames) {
	const text = String(raw || '');
	if (!text) return '';

	for (let i = 0; i < packageNames.length; i++) {
		const escaped = String(packageNames[i] || '').replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
		const pattern = new RegExp(
			'(^|\\n)\\s*Package\\s*:\\s*' + escaped + '\\s*[\\s\\S]*?\\n\\s*Version\\s*:\\s*([^\\s\\n]+)',
			'i'
		);
		const match = text.match(pattern);
		if (match && match[2]) return match[2].trim();
	}

	return '';
}

function normalizeAppVersion(version) {
	const str = String(version || '').trim();
	if (!str) return '';
	const numeric = str.match(/^\d+(?:\.\d+)+/);
	if (numeric && numeric[0]) return numeric[0];
	return str.replace(/-r\d+$/i, '').replace(/-\d+$/, '');
}

function normalizeVersion(str) {
	if (!str) return '';
	const match = String(str).match(/v?(\d+\.\d+\.\d+)/i);
	return match ? match[1] : String(str).trim();
}

function normalizeReleaseChannel(value) {
	const normalized = String(value || '').toLowerCase().trim();
	return normalized === 'prerelease' ? 'prerelease' : 'release';
}

function normalizeGithubRelease(data) {
	if (!data || data.draft || !data.tag_name || !Array.isArray(data.assets)) return null;
	return { version: data.tag_name, assets: data.assets, prerelease: !!data.prerelease };
}

async function fetchGithubRelease(kind, includePrereleases) {
	const api = view_miclash_api.create();
	try {
		const channel = includePrereleases ? 'prerelease' : 'release';
		const data = await api.update_release(kind, channel);
		if (!data || typeof data.version !== 'string') return null;
		const assets = data.asset_name ? [ {
			name: String(data.asset_name), browser_download_url: 'managed-by-miclash'
		} ] : [];
		return { version: data.version, assets, prerelease: channel === 'prerelease',
			architecture: data.architecture || '' };
	} catch (e) {
		return null;
	} finally { api.destroy(); }
}

function getLatestMihomoRelease(includePrereleases) {
	return fetchGithubRelease('mihomo', includePrereleases);
}

function getLatestMiClashRelease(includePrereleases) {
	return fetchGithubRelease('miclash', includePrereleases);
}

function compareNumericVersions(left, right) {
	const normalize = (value) => {
		const matched = String(value || '').trim().match(/\d+(?:\.\d+)+/);
		if (!matched || !matched[0]) return null;
		return matched[0].split('.').map((item) => parseInt(item, 10));
	};

	const l = normalize(left);
	const r = normalize(right);
	if (!l || !r) return null;

	const len = Math.max(l.length, r.length);
	for (let i = 0; i < len; i++) {
		const a = i < l.length ? l[i] : 0;
		const b = i < r.length ? r[i] : 0;
		if (a < b) return -1;
		if (a > b) return 1;
	}

	return 0;
}

function findKernelAsset(release, arch) {
	if (!release || !Array.isArray(release.assets)) return null;

	const tag = String(release.version || '');
	const cleanTag = tag.replace(/^v/i, '');
	const exactNames = [
		'mihomo-linux-' + arch + '-' + tag + '.gz',
		'mihomo-linux-' + arch + '-' + cleanTag + '.gz'
	];

	for (let i = 0; i < exactNames.length; i++) {
		const asset = release.assets.find((item) => item.name === exactNames[i]);
		if (asset) return asset;
	}

	return release.assets.find((item) =>
		item.name && item.name.indexOf('mihomo-linux-' + arch + '-') === 0 && item.name.endsWith('.gz')) || null;
}

function findMiClashAsset(release, managerType) {
	if (!release || !Array.isArray(release.assets)) return null;

	const rawTag = String(release.version || '');
	const cleanTag = rawTag.replace(/^v/i, '');
	const normalized = normalizeAppVersion(cleanTag);
	const ext = managerType === 'apk' ? '.apk' : '.ipk';
	const expectedNames = managerType === 'apk'
		? [
			'luci-app-miclash-' + cleanTag + '.apk',
			'luci-app-miclash-' + normalized + '.apk'
		]
		: [
			'luci-app-miclash_' + cleanTag + '_all.ipk',
			'luci-app-miclash_' + normalized + '_all.ipk'
		];

	for (let i = 0; i < expectedNames.length; i++) {
		const asset = release.assets.find((item) => item.name === expectedNames[i]);
		if (asset) return asset;
	}

	return release.assets.find((item) =>
		item &&
		item.name &&
		item.name.indexOf('luci-app-miclash') !== -1 &&
		item.name.endsWith(ext)
	) || null;
}

return L.Class.extend({
	parseVersion: parseVersion,
	parsePackageVersion: parsePackageVersion,
	parseVersionFromOpkgStatus: parseVersionFromOpkgStatus,
	normalizeAppVersion: normalizeAppVersion,
	normalizeVersion: normalizeVersion,
	normalizeReleaseChannel: normalizeReleaseChannel,
	getLatestMihomoRelease: getLatestMihomoRelease,
	getLatestMiClashRelease: getLatestMiClashRelease,
	compareNumericVersions: compareNumericVersions,
	findKernelAsset: findKernelAsset,
	findMiClashAsset: findMiClashAsset
});
