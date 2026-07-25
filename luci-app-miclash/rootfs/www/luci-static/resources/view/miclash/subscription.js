'use strict';
'require view.miclash.api';

const TMP_SUBSCRIPTION_PATH = '';

function looksLikeBase64Text(value) {
	const cleaned = String(value || '').replace(/\s+/g, '');
	return cleaned.length >= 64 && cleaned.length % 4 === 0 && /^[A-Za-z0-9+/=]+$/.test(cleaned);
}

function tryDecodeBase64(value) {
	try { return typeof atob === 'function' ? atob(String(value || '').replace(/\s+/g, '')) : null; }
	catch (_) { return null; }
}

function looksLikeUriSubscription(value) {
	return /(?:^|\n)\s*(vmess|vless|trojan|ss|ssr|hysteria|hysteria2|tuic):\/\/[^\s]+/i
		.test(String(value || ''));
}

function looksLikeBase64Blob(value) {
	const text = String(value || ''), compact = text.replace(/\s+/g, '');
	return compact.length >= 48 && !text.includes(':') && /^[A-Za-z0-9+/=]+$/.test(compact);
}

function looksLikeYamlConfig(value) {
	return /(^|\n)\s*(proxies|proxy-providers|mixed-port|port|mode|rules):\s*/m
		.test(String(value || ''));
}

function readProfileUpdateIntervalHours(headers) {
	const match = String(headers || '').match(/^Profile-Update-Interval:\s*([0-9]+)/im);
	const value = match ? parseInt(match[1], 10) : 0;
	return value > 0 ? String(value) : '';
}

function buildClientProfile(settings, appVersion) {
	const safeVersion = /^\d+\.\d+\.\d+/.test(String(appVersion || '')) ? String(appVersion) : '1.0.0';
	const userAgent = String(settings?.HWID_USER_AGENT || settings?.core?.hwid_user_agent || '').trim();
	return { ua: userAgent || ('MiClash/' + safeVersion) };
}

function normalizeDownloadUrl(rawUrl) {
	let parsed;
	try { parsed = new URL(rawUrl); }
	catch (_) { return { url: rawUrl, mode: 'direct', remnawaveCandidateUrl: null, fallbackOnError: false }; }
	const segments = parsed.pathname.split('/').filter(Boolean);
	if (String(segments[segments.length - 1] || '').toLowerCase() === 'mihomo')
		return { url: parsed.toString(), mode: 'remnawave-client-path', remnawaveCandidateUrl: null, fallbackOnError: false };
	const index = segments.indexOf('sub'), candidate = new URL(parsed.toString());
	if (index >= 0 && segments[index + 1]) {
		if (String(segments[index + 2] || '').toLowerCase() === 'mihomo')
			return { url: parsed.toString(), mode: 'remnawave-client-path', remnawaveCandidateUrl: null, fallbackOnError: false };
		const next = segments.slice();
		if (next[index + 2]) next[index + 2] = 'mihomo'; else next.push('mihomo');
		candidate.pathname = '/' + next.join('/');
		return { url: parsed.toString(), mode: 'direct', remnawaveCandidateUrl: candidate.toString(), fallbackOnError: true };
	}
	candidate.pathname = '/' + segments.concat('mihomo').join('/');
	return { url: parsed.toString(), mode: 'direct', remnawaveCandidateUrl: candidate.toString(), fallbackOnError: false };
}

async function withApi(callback) {
	const api = view_miclash_api.create();
	try { return await callback(api); }
	finally { api.destroy(); }
}

function waitOperation(api, reply) {
	return new Promise((resolve, reject) => {
		let cancel = null;
		cancel = api.watchOperation(reply?.operation_id, (record, error) => {
			if (error) { if (cancel) cancel(); return reject(error); }
			if (record?.state === 'success') { if (cancel) cancel(); return resolve(record); }
			if (record?.state === 'failure' || record?.state === 'interrupted') {
				if (cancel) cancel();
				const failure = new Error(record?.error?.message || 'Subscription operation failed');
				failure.code = record?.error?.code || 'HEALTH_FAILED'; reject(failure);
			}
		});
	});
}

function profileName(value) {
	const name = String(value || '').split('/').pop() || 'config.yaml';
	return /^(config|config2|config3)\.yaml$/.test(name) ? name : 'config.yaml';
}

async function buildDeviceHeaders(settings) {
	return withApi(async (api) => {
		const info = await api.system_info(), headers = {};
		headers['x-device-os'] = String(settings?.HWID_DEVICE_OS || settings?.core?.hwid_device_os || 'OpenWrt');
		if (info?.openwrt_version) headers['x-ver-os'] = String(info.openwrt_version);
		if (info?.model) headers['x-device-model'] = String(info.model);
		if (settings?.ENABLE_HWID === true || String(settings?.ENABLE_HWID).toLowerCase() === 'true' ||
		    settings?.core?.hwid_enabled === true) headers['x-hwid'] = String(info?.hwid || '');
		return headers;
	});
}

async function downloadWithProfile(url) {
	throw new Error('Subscription preview is unavailable; apply it through the protected router operation.');
}

async function applySubscriptionOnRouter(options) {
	const opts = options || {}, profile = profileName(opts.targetName);
	return withApi(async (api) => {
		const record = await waitOperation(api, await api.subscription_update(profile, 'luci'));
		return { profileUpdateIntervalHours: String(record?.result?.interval_hours || '') };
	});
}

async function cleanupTemp() { return true; }

async function testConfigContent(content, keepOnSuccess, targetPath, options) {
	try {
		if (options?.ensureKernelInstalled) await options.ensureKernelInstalled();
		return await withApi(async (api) => {
			await waitOperation(api, await api.config_validate(profileName(targetPath),
				String(content || '').trimEnd() + '\n', 'luci'));
			return { ok: true, message: '' };
		});
	} catch (error) { return { ok: false, message: error?.message || 'test failed' }; }
}

return L.Class.extend({
	TMP_SUBSCRIPTION_PATH,
	looksLikeBase64Text, tryDecodeBase64, looksLikeUriSubscription,
	looksLikeBase64Blob, looksLikeYamlConfig, buildClientProfile, normalizeDownloadUrl,
	buildDeviceHeaders, downloadWithProfile, applySubscriptionOnRouter,
	readProfileUpdateIntervalHours,
	cleanupTemp, testConfigContent
});
