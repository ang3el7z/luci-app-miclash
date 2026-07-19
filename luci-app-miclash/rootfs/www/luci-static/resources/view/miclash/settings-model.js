'use strict';
'require view.miclash.api';
'require view.miclash.release';

async function withApi(callback) {
	const api = view_miclash_api.create();
	try { return await callback(api); }
	finally { api.destroy(); }
}

function operationError(record) {
	const error = new Error(record?.error?.message || 'Operation failed');
	error.code = record?.error?.code || 'HEALTH_FAILED';
	return error;
}

function waitOperation(api, reply) {
	const id = reply?.operation_id;
	if (typeof id !== 'string' || !id.length) return Promise.reject(new Error('Invalid operation response'));
	return new Promise((resolve, reject) => {
		let cancel = null;
		const finish = (callback, value) => {
			if (typeof cancel === 'function') cancel();
			callback(value);
		};
		cancel = api.watchOperation(id, (record, error) => {
			if (error) return finish(reject, error);
			if (record?.state === 'success') return finish(resolve, record);
			if (record?.state === 'failure' || record?.state === 'interrupted')
				return finish(reject, operationError(record));
		});
	});
}

function configContent(reply) {
	return typeof reply === 'string' ? reply : String(reply?.content || '');
}

function createInterfaceEntry(name) {
	let category = 'other';

	if (/\.\d+$/.test(name) || /^(br-|bridge|eth|lan|switch|bond|team)/.test(name)) {
		category = 'ethernet';
	} else if (/^(wlan|wifi|ath|phy|ra|mt|rtl|iwl)/.test(name)) {
		category = 'wifi';
	} else if (/^(wan|ppp|modem|3g|4g|5g|lte|gsm|cdma|hsdpa|hsupa|umts)/.test(name)) {
		category = 'wan';
	} else if (/^(tun|tap|vpn|wg|ovpn|openvpn|l2tp|pptp|sstp|ikev2|ipsec)/.test(name)) {
		category = 'vpn';
	} else if (/^(veth|macvlan|ipvlan|dummy|vrf|vcan|vxcan)/.test(name)) {
		category = 'virtual';
	}

	return {
		name: name,
		category: category,
		description: name
	};
}

async function getNetworkSnapshot() {
	const reply = await withApi((api) => api.network_interfaces());
	const result = Array.isArray(reply?.interfaces)
		? reply.interfaces.filter((name) => typeof name === 'string').map(createInterfaceEntry) : [];
	const order = ['wan', 'ethernet', 'wifi', 'vpn', 'virtual', 'other'];
	const interfaces = result.sort((a, b) => {
		const ca = order.indexOf(a.category);
		const cb = order.indexOf(b.category);
		if (ca !== cb) return ca - cb;
		return a.name.localeCompare(b.name);
	});
	return {
		interfaces,
		detectedLan: typeof reply?.detected_lan === 'string' ? reply.detected_lan : '',
		detectedWan: typeof reply?.detected_wan === 'string' ? reply.detected_wan : ''
	};
}

async function getNetworkInterfaces() {
	return (await getNetworkSnapshot()).interfaces;
}

async function getHwidValues() {
	const info = await withApi((api) => api.system_info());
	return {
		hwid: String(info?.hwid || 'unknown'),
		verOs: String(info?.openwrt_version || 'unknown'),
		deviceModel: String(info?.model || 'Router')
	};
}

function addHwidToYaml(yamlContent, userAgent, deviceOS, hwid, verOs, deviceModel) {
	const lines = String(yamlContent || '').split('\n');
	const result = [];
	let inProxyProviders = false;
	let inProvider = false;
	let currentProvider = [];
	let hasHeader = false;

	function flushProvider() {
		result.push(...currentProvider);
		if (!hasHeader) {
			while (result.length > 0 && result[result.length - 1].trim() === '') result.pop();
			result.push('    header:');
			result.push('      User-Agent: [' + userAgent + ']');
			result.push('      x-hwid: [' + hwid + ']');
			result.push('      x-device-os: [' + deviceOS + ']');
			result.push('      x-ver-os: [' + verOs + ']');
			result.push('      x-device-model: [' + deviceModel + ']');
			result.push('');
		}
	}

	for (let i = 0; i < lines.length; i++) {
		const line = lines[i];

		if (/^proxy-providers:\s*$/.test(line)) {
			inProxyProviders = true;
			result.push(line);
			continue;
		}

		if (inProxyProviders) {
			if (/^[a-zA-Z]/.test(line)) {
				if (inProvider) flushProvider();
				inProxyProviders = false;
				inProvider = false;
				result.push(line);
				continue;
			}

			const providerMatch = line.match(/^  ([a-zA-Z0-9_-]+):\s*$/);
			if (providerMatch) {
				if (inProvider) flushProvider();
				currentProvider = [line];
				inProvider = true;
				hasHeader = false;
				continue;
			}

			if (inProvider && /^    header:\s*$/.test(line)) hasHeader = true;

			if (inProvider) {
				currentProvider.push(line);
			} else {
				result.push(line);
			}
		} else {
			result.push(line);
		}
	}

	if (inProvider) flushProvider();
	return result.join('\n');
}

function normalizeProxyMode(mode) {
	const normalized = String(mode || '').toLowerCase().trim();
	if (normalized === 'tun' || normalized === 'mixed' || normalized === 'tproxy') return normalized;
	return 'tproxy';
}

function transformProxyMode(content, proxyMode, tunStack) {
	const lines = String(content || '').split('\n');
	const newLines = [];
	let inTunSection = false;
	let tunIndentLevel = 0;

	for (let i = 0; i < lines.length; i++) {
		const line = lines[i];
		const trimmed = line.trim();

		if (/^#\s*Proxy\s+Mode:/i.test(trimmed)) continue;

		if (trimmed === '' && i + 1 < lines.length && lines[i + 1].trim() === '') continue;

		if (trimmed === '' && i + 1 < lines.length) {
			const nextLine = lines[i + 1].trim();
			if (/^#\s*Proxy\s+Mode:/i.test(nextLine) || /^redir-port/.test(nextLine) || /^tproxy-port/.test(nextLine) || /^tun:/.test(nextLine)) {
				continue;
			}
		}

		if (/^redir-port:/.test(trimmed)) continue;
		if (/^tproxy-port:/.test(trimmed)) continue;

		if (/^tun:/.test(trimmed)) {
			inTunSection = true;
			tunIndentLevel = line.search(/\S/);
			continue;
		}

		if (inTunSection) {
			const currentIndent = line.search(/\S/);
			if (line.trim() === '' || line.trim().startsWith('#') || (currentIndent > tunIndentLevel && line.trim() !== '')) {
				continue;
			}
			inTunSection = false;
		}

		newLines.push(line);
	}

	let insertIndex = 0;
	for (let i = 0; i < newLines.length; i++) {
		if (/^mode:/.test(newLines[i].trim())) {
			insertIndex = i + 1;
			break;
		}
	}

	const normalizedTunStack = ['system', 'gvisor', 'mixed'].includes(tunStack) ? tunStack : 'system';
	let configToInsert = [];

	switch (normalizeProxyMode(proxyMode)) {
		case 'tproxy':
			configToInsert = ['# Proxy Mode: TPROXY', 'redir-port: 7892', 'tproxy-port: 7894'];
			break;
		case 'tun':
			configToInsert = [
				'# Proxy Mode: TUN',
				'tun:',
				'  enable: true',
				'  device: clash-tun',
				'  stack: ' + normalizedTunStack,
				'  auto-route: false',
				'  auto-redirect: false',
				'  auto-detect-interface: false'
			];
			break;
		case 'mixed':
			configToInsert = [
				'# Proxy Mode: MIXED (TCP via TPROXY, UDP via TUN)',
				'redir-port: 7892',
				'tproxy-port: 7894',
				'tun:',
				'  enable: true',
				'  device: clash-tun',
				'  stack: ' + normalizedTunStack,
				'  auto-route: false',
				'  auto-redirect: false',
				'  auto-detect-interface: false'
			];
			break;
	}

	newLines.splice(insertIndex, 0, ...configToInsert);
	return newLines.join('\n');
}

async function detectCurrentProxyMode() {
	try {
		const settings = await withApi((api) => api.settings_get());
		return normalizeProxyMode(settings?.core?.proxy_mode);
	} catch (e) {
		return 'tproxy';
	}
}

function defaultOperationalSettings() {
	return {
		mode: 'exclude',
		proxyMode: '',
		tunStack: 'system',
		autoDetectLan: true,
		autoDetectWan: true,
		blockQuic: true,
		useTmpfsRules: true,
		internetOnlyMiclash: false,
		enableMemoryGuard: false,
		autoHideNotifications: true,
		autoUpdateConfig: true,
		autoUpdateIntervalHours: '4',
		autoUpdateIntervalStored: false,
		autoMajorMiclash: true,
		miclashReleaseChannel: 'release',
		mihomoReleaseChannel: 'release',
		detectedLan: '',
		detectedWan: '',
		includedInterfaces: [],
		excludedInterfaces: [],
		enableHwid: false,
		hwidUserAgent: 'MiClash',
		hwidDeviceOS: 'OpenWrt'
	};
}

function normalizeAutoUpdateIntervalHours(value) {
	const clean = String(value || '').trim();
	const parsed = parseInt(clean, 10);
	return parsed > 0 ? String(parsed) : '4';
}

function operationalSettingsFromTyped(source) {
		const settings = defaultOperationalSettings();
		const core = source?.core || {}, interfaces = source?.interfaces || {};
		const updates = source?.updates || {}, memory = source?.memory || {};
		const notifications = source?.notifications || {};
		settings.mode = interfaces.mode || settings.mode;
		settings.proxyMode = normalizeProxyMode(core.proxy_mode);
		settings.tunStack = core.tun_stack || settings.tunStack;
		settings.autoDetectLan = interfaces.auto_detect_lan !== false;
		settings.autoDetectWan = interfaces.auto_detect_wan !== false;
		settings.blockQuic = core.block_quic !== false;
		settings.useTmpfsRules = core.use_tmpfs_rules !== false;
		settings.enableMemoryGuard = memory.enabled === true;
		settings.autoHideNotifications = notifications.auto_hide !== false;
		settings.autoUpdateConfig = updates.auto_subscription !== false;
		settings.autoUpdateIntervalHours = normalizeAutoUpdateIntervalHours(updates.interval_hours);
		settings.autoUpdateIntervalStored = true;
		settings.autoMajorMiclash = updates.auto_major_miclash !== false;
		settings.miclashReleaseChannel = view_miclash_release.normalizeReleaseChannel(updates.miclash_release_channel);
		settings.mihomoReleaseChannel = view_miclash_release.normalizeReleaseChannel(updates.mihomo_release_channel);
		settings.detectedLan = String(interfaces.detected_lan || '');
		settings.detectedWan = String(interfaces.detected_wan || '');
		settings.includedInterfaces = Array.isArray(interfaces.included) ? interfaces.included.slice() : [];
		settings.excludedInterfaces = Array.isArray(interfaces.excluded) ? interfaces.excluded.slice() : [];
		settings.enableHwid = core.hwid_enabled === true;
		settings.hwidUserAgent = String(core.hwid_user_agent || 'MiClash');
		settings.hwidDeviceOS = String(core.hwid_device_os || 'OpenWrt');
		settings.internetOnlyMiclash = source?.guard?.enabled === true;
		return settings;
	}

async function loadOperationalSettings() {
	try {
		return operationalSettingsFromTyped(await withApi((api) => api.settings_get()));
	} catch (e) {
		return defaultOperationalSettings();
	}
}

async function loadInterfacesByMode(mode) {
	const settings = await loadOperationalSettings();
	const manualList = mode === 'explicit' ? settings.includedInterfaces : settings.excludedInterfaces;
	const detected = mode === 'explicit' ? settings.detectedLan : settings.detectedWan;
	const all = manualList.slice();
	if (detected && !all.includes(detected)) all.push(detected);
	return all;
}

async function detectLanBridge() {
	try {
		const reply = await withApi((api) => api.network_interfaces());
		return typeof reply?.detected_lan === 'string' && reply.detected_lan ? reply.detected_lan : null;
	} catch (e) {
		return null;
	}
}

async function detectWanInterface() {
	try {
		const reply = await withApi((api) => api.network_interfaces());
		return typeof reply?.detected_wan === 'string' && reply.detected_wan ? reply.detected_wan : null;
	} catch (e) {
		return null;
	}
}

function sameStringSet(left, right) {
	const a = Array.from(new Set((left || []).map(String))).sort();
	const b = Array.from(new Set((right || []).map(String))).sort();
	return a.length === b.length && a.every((value, index) => value === b[index]);
}

function operationalSettingsChanged(current, next, detected) {
	current = current || {};
	next = next || {};
	detected = detected || {};
	const scalarPairs = [
		[ current.mode || 'exclude', next.mode || 'exclude' ],
		[ normalizeProxyMode(current.proxyMode), normalizeProxyMode(next.proxyMode) ],
		[ current.tunStack || 'system', next.tunStack || 'system' ],
		[ current.autoDetectLan !== false, next.autoDetectLan !== false ],
		[ current.autoDetectWan !== false, next.autoDetectWan !== false ],
		[ current.blockQuic !== false, next.blockQuic !== false ],
		[ current.useTmpfsRules !== false, next.useTmpfsRules !== false ],
		[ current.enableHwid === true, next.enableHwid === true ],
		[ String(current.hwidUserAgent || 'MiClash'), String(next.hwidUserAgent || 'MiClash') ],
		[ String(current.hwidDeviceOS || 'OpenWrt'), String(next.hwidDeviceOS || 'OpenWrt') ]
	];
	if (scalarPairs.some(([ before, after ]) => before !== after)) return true;

	const currentMode = current.mode || 'exclude';
	const selected = currentMode === 'explicit'
		? (current.includedInterfaces || []).slice()
		: (current.excludedInterfaces || []).slice();
	const detectedLan = current.detectedLan || detected.detectedLan || '';
	const detectedWan = current.detectedWan || detected.detectedWan || '';
	if (currentMode === 'explicit' && current.autoDetectLan !== false && detectedLan)
		selected.push(detectedLan);
	if (currentMode !== 'explicit' && current.autoDetectWan !== false && detectedWan)
		selected.push(detectedWan);
	return !sameStringSet(selected, next.selected || []);
}

async function saveOperationalSettings(mode, proxyMode, tunStack, autoDetectLan, autoDetectWan, blockQuic, useTmpfsRules, interfaces, enableHwid, hwidUserAgent, hwidDeviceOS, miclashReleaseChannel, mihomoReleaseChannel, autoUpdateConfig, autoUpdateIntervalHours, autoMajorMiclash) {
	let detectedLan = '';
	let detectedWan = '';

	if (autoDetectLan) detectedLan = await detectLanBridge() || '';
	if (autoDetectWan) detectedWan = await detectWanInterface() || '';

	let cleanInterfaces = interfaces.slice();
	if (mode === 'explicit' && autoDetectLan && detectedLan) {
		cleanInterfaces = cleanInterfaces.filter((iface) => iface !== detectedLan);
	} else if (mode === 'exclude' && autoDetectWan && detectedWan) {
		cleanInterfaces = cleanInterfaces.filter((iface) => iface !== detectedWan);
	}

	const includedInterfaces = mode === 'explicit' ? cleanInterfaces : [];
	const excludedInterfaces = mode === 'exclude' ? cleanInterfaces : [];

	return withApi(async (api) => {
		const activeConfig = configContent(await api.config_read('config.yaml'));
		let updatedConfig = transformProxyMode(activeConfig, proxyMode, tunStack);
		if (enableHwid) {
			const info = await api.system_info();
			updatedConfig = addHwidToYaml(updatedConfig, hwidUserAgent, hwidDeviceOS,
				String(info?.hwid || 'unknown'), String(info?.openwrt_version || 'unknown'),
				String(info?.model || 'Router'));
		}
		const settings = {
			core: { proxy_mode: normalizeProxyMode(proxyMode), tun_stack: tunStack,
				block_quic: !!blockQuic, use_tmpfs_rules: !!useTmpfsRules,
				hwid_enabled: !!enableHwid, hwid_user_agent: String(hwidUserAgent || 'MiClash'),
				hwid_device_os: String(hwidDeviceOS || 'OpenWrt') },
			interfaces: { mode, auto_detect_lan: !!autoDetectLan, auto_detect_wan: !!autoDetectWan,
				detected_lan: detectedLan, detected_wan: detectedWan,
				included: includedInterfaces, excluded: excludedInterfaces }
		};
		await waitOperation(api, await api.operational_settings_apply(
			'config.yaml', updatedConfig, settings, 'luci'));
		return true;
	});
}

return L.Class.extend({
	getNetworkSnapshot: getNetworkSnapshot,
	getNetworkInterfaces: getNetworkInterfaces,
	transformProxyMode: transformProxyMode,
	detectCurrentProxyMode: detectCurrentProxyMode,
	operationalSettingsFromTyped: operationalSettingsFromTyped,
	loadOperationalSettings: loadOperationalSettings,
	loadInterfacesByMode: loadInterfacesByMode,
	detectLanBridge: detectLanBridge,
	detectWanInterface: detectWanInterface,
	saveOperationalSettings: saveOperationalSettings,
	operationalSettingsChanged: operationalSettingsChanged,
	normalizeProxyMode: normalizeProxyMode
});
