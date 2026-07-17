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

async function ensureCurlAvailable() { return true; }

return L.Class.extend({
	detectPackageManager: detectPackageManager,
	ensureCurlAvailable: ensureCurlAvailable,
	getOpenWrtReleaseVersion: getOpenWrtReleaseVersion
});
