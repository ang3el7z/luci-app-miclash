'use strict';
'require fs';
'require view.miclash.package';
'require view.miclash.store';
'require view.miclash.utils';

const TMP_SUBSCRIPTION_PATH = '/tmp/miclash-subscription.yaml';
const SUBSCRIPTION_CURL_CONNECT_TIMEOUT_SEC = 8;
const SUBSCRIPTION_CURL_MAX_TIME_SEC = 18;

function looksLikeBase64Text(value) {
	const cleaned = String(value || '').replace(/\s+/g, '');
	if (cleaned.length < 64 || cleaned.length % 4 !== 0) return false;
	return /^[A-Za-z0-9+/=]+$/.test(cleaned);
}

function tryDecodeBase64(value) {
	try {
		if (typeof atob !== 'function') return null;
		const cleaned = String(value || '').replace(/\s+/g, '');
		return atob(cleaned);
	} catch (e) {
		return null;
	}
}

function looksLikeUriSubscription(value) {
	const content = String(value || '');
	return /(?:^|\n)\s*(vmess|vless|trojan|ss|ssr|hysteria|hysteria2|tuic):\/\/[^\s]+/i.test(content);
}

function looksLikeBase64Blob(text) {
	const compact = String(text || '').replace(/\s+/g, '');
	if (compact.length < 48) return false;
	if (String(text || '').indexOf(':') !== -1) return false;
	return /^[A-Za-z0-9+/=]+$/.test(compact);
}

function looksLikeYamlConfig(content) {
	const text = String(content || '');
	return /(^|\n)\s*(proxies|proxy-providers|mixed-port|port|mode|rules):\s*/m.test(text);
}

function buildClientProfile(settings, appVersion) {
	const safeVersion = /^\d+\.\d+\.\d+/.test(String(appVersion || '')) ? String(appVersion) : '1.0.0';
	const settingsUa = String(settings.HWID_USER_AGENT || '').trim();
	return { ua: settingsUa || ('MiClash/' + safeVersion) };
}

function normalizeDownloadUrl(rawUrl) {
	let parsed = null;
	try {
		parsed = new URL(rawUrl);
	} catch (e) {
		return { url: rawUrl, mode: 'direct', remnawaveCandidateUrl: null, fallbackOnError: false };
	}

	const segments = parsed.pathname.split('/').filter(Boolean);
	const lastSegment = String(segments[segments.length - 1] || '').toLowerCase();
	if (lastSegment === 'mihomo') {
		return {
			url: parsed.toString(),
			mode: 'remnawave-client-path',
			remnawaveCandidateUrl: null,
			fallbackOnError: false
		};
	}

	const subIndex = segments.indexOf('sub');
	if (subIndex < 0 || !segments[subIndex + 1]) {
		const genericCandidate = new URL(parsed.toString());
		genericCandidate.pathname = '/' + segments.concat('mihomo').join('/');
		return {
			url: parsed.toString(),
			mode: 'direct',
			remnawaveCandidateUrl: genericCandidate.toString(),
			fallbackOnError: false
		};
	}

	const clientType = String(segments[subIndex + 2] || '').toLowerCase();

	if (clientType === 'mihomo') {
		return {
			url: parsed.toString(),
			mode: 'remnawave-client-path',
			remnawaveCandidateUrl: null,
			fallbackOnError: false
		};
	}

	if (clientType) {
		const candidateSegments = segments.slice();
		candidateSegments[subIndex + 2] = 'mihomo';

		const candidate = new URL(parsed.toString());
		candidate.pathname = '/' + candidateSegments.join('/');

		return {
			url: parsed.toString(),
			mode: 'direct',
			remnawaveCandidateUrl: candidate.toString(),
			fallbackOnError: true
		};
	}

	const candidateSegments = segments.slice();
	candidateSegments.push('mihomo');

	const candidate = new URL(parsed.toString());
	candidate.pathname = '/' + candidateSegments.join('/');

	return {
		url: parsed.toString(),
		mode: 'direct',
		remnawaveCandidateUrl: candidate.toString(),
		fallbackOnError: true
	};
}

async function getSystemModel() {
	try {
		return String(await fs.read('/tmp/sysinfo/model') || '').trim();
	} catch (e) {
		return '';
	}
}

async function getHwidHash() {
	const probes = [
		"cat /sys/class/net/eth0/address 2>/dev/null | tr -d ':' | md5sum | cut -c1-14",
		"for i in /sys/class/net/*/address; do n=\"${i%/address}\"; n=\"${n##*/}\"; [ \"$n\" = \"lo\" ] && continue; cat \"$i\" 2>/dev/null | tr -d ':' | md5sum | cut -c1-14 && break; done"
	];

	for (let i = 0; i < probes.length; i++) {
		try {
			const r = await fs.exec('/bin/sh', ['-c', probes[i]]);
			if (r.code === 0) {
				const hwid = String(r.stdout || '').trim();
				if (hwid && hwid !== 'unknown') return hwid;
			}
		} catch (e) {}
	}

	return '';
}

async function buildDeviceHeaders(settings) {
	const headers = {};
	const deviceOs = String(settings.HWID_DEVICE_OS || 'OpenWrt').trim() || 'OpenWrt';
	headers['x-device-os'] = deviceOs;

	const release = await view_miclash_package.getOpenWrtReleaseVersion();
	if (release) headers['x-ver-os'] = release;

	const model = await getSystemModel();
	if (model) headers['x-device-model'] = model;

	if (String(settings.ENABLE_HWID || '').toLowerCase() === 'true') {
		const hwid = await getHwidHash();
		if (hwid) headers['x-hwid'] = hwid;
	}

	return headers;
}

async function downloadWithProfile(url, profile, deviceHeaders, mode) {
	const args = [
		'-L', '-fsS',
		'--connect-timeout', String(SUBSCRIPTION_CURL_CONNECT_TIMEOUT_SEC),
		'--max-time', String(SUBSCRIPTION_CURL_MAX_TIME_SEC),
		'-A', profile.ua,
		'-H', 'Accept: application/yaml, text/yaml, text/plain, */*',
		'-H', 'Cache-Control: no-cache',
		'-H', 'Pragma: no-cache'
	];

	Object.keys(deviceHeaders || {}).forEach((key) => {
		const value = String(deviceHeaders[key] || '').trim();
		if (!value) return;
		args.push('-H');
		args.push(key + ': ' + value);
	});

	args.push(url);
	args.push('-o');
	args.push(TMP_SUBSCRIPTION_PATH);

	await view_miclash_package.ensureCurlAvailable();
	const dl = await fs.exec('/usr/bin/curl', args);
	if (dl.code !== 0) {
		const msg = String(dl.stderr || dl.stdout || _('Download failed')).trim();
		if (mode === 'remnawave-client-path' && /403/.test(msg)) {
			throw new Error(_('Remnawave blocked /mihomo path (HTTP 403). Disable "Disable Subscription Access by Path" in Remnawave response-rules settings.'));
		}
		throw new Error(msg);
	}

	const catResult = await fs.exec('/bin/cat', [TMP_SUBSCRIPTION_PATH]);
	if (catResult.code !== 0) {
		throw new Error(String(catResult.stderr || catResult.stdout || _('Unable to read downloaded file')).trim());
	}

	return String(catResult.stdout || '');
}

async function cleanupTemp() {
	try {
		await fs.remove(TMP_SUBSCRIPTION_PATH);
	} catch (e) {}
}

function extractTestError(testResult) {
	return view_miclash_utils.formatClashTestError(testResult?.stdout, testResult?.stderr) || 'unknown error';
}

async function testConfigContent(content, keepOnSuccess, targetPath, options) {
	const opts = options || {};
	const normalized = String(content || '').trimEnd() + '\n';
	const configPath = String(targetPath || view_miclash_store.CONFIG_PATH);
	let original = '';

	try {
		if (opts.ensureKernelInstalled) {
			await opts.ensureKernelInstalled();
		}
	} catch (e) {
		return { ok: false, message: e.message || _('Mihomo kernel is not installed.') };
	}

	try {
		original = await fs.read(configPath);
	} catch (e) {
		original = '';
	}

	try {
		await view_miclash_store.writeTextFile(configPath, normalized);
		await view_miclash_store.setFileMode(configPath);
		let testResult = await fs.exec('/opt/clash/bin/clash', ['-d', '/opt/clash', '-f', configPath, '-t']);
		if (testResult.code !== 0 && configPath === view_miclash_store.CONFIG_PATH) {
			testResult = await fs.exec('/opt/clash/bin/clash', ['-d', '/opt/clash', '-t']);
		}

		if (testResult.code !== 0) {
			await view_miclash_store.writeTextFile(configPath, original);
			await view_miclash_store.setFileMode(configPath);
			return { ok: false, message: extractTestError(testResult) };
		}

		if (!keepOnSuccess) {
			await view_miclash_store.writeTextFile(configPath, original);
			await view_miclash_store.setFileMode(configPath);
		}
		return { ok: true, message: '' };
	} catch (e) {
		try {
			await view_miclash_store.writeTextFile(configPath, original);
			await view_miclash_store.setFileMode(configPath);
		} catch (restoreError) {}
		return { ok: false, message: e.message || 'test failed' };
	}
}

return L.Class.extend({
	TMP_SUBSCRIPTION_PATH: TMP_SUBSCRIPTION_PATH,
	looksLikeBase64Text: looksLikeBase64Text,
	tryDecodeBase64: tryDecodeBase64,
	looksLikeUriSubscription: looksLikeUriSubscription,
	looksLikeBase64Blob: looksLikeBase64Blob,
	looksLikeYamlConfig: looksLikeYamlConfig,
	buildClientProfile: buildClientProfile,
	normalizeDownloadUrl: normalizeDownloadUrl,
	buildDeviceHeaders: buildDeviceHeaders,
	downloadWithProfile: downloadWithProfile,
	cleanupTemp: cleanupTemp,
	testConfigContent: testConfigContent
});
