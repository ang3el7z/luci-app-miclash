'use strict';
'require fs';
'require network';
'require view.miclash.store';
'require view.miclash.release';

const CONFIG_PATH = view_miclash_store.CONFIG_PATH;
const SETTINGS_PATH = view_miclash_store.SETTINGS_PATH;

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

async function getNetworkInterfaces() {
	const result = [];
	const seen = new Set();

	const pushIface = (name) => {
		const clean = String(name || '').trim();
		if (!clean || clean === 'lo' || clean === 'clash-tun' || seen.has(clean)) return;
		seen.add(clean);
		result.push(createInterfaceEntry(clean));
	};

	try {
		const r = await fs.exec('/bin/ls', ['/sys/class/net/']);
		if (r.code === 0 && r.stdout) {
			String(r.stdout).split('\n').forEach(pushIface);
		}
	} catch (e) {}

	try {
		const r = await fs.exec('/sbin/ip', ['link', 'show']);
		if (r.code === 0 && r.stdout) {
			String(r.stdout).split('\n').forEach((line) => {
				const m = line.match(/^\d+:\s+([^:@]+)/);
				if (m && m[1]) pushIface(m[1]);
			});
		}
	} catch (e) {}

	try {
		const devices = await network.getDevices();
		devices.forEach((dev) => {
			const n = dev.getName && dev.getName();
			if (n) pushIface(n);
		});
	} catch (e) {}

	try {
		const nets = await network.getNetworks();
		nets.forEach((net) => {
			const dev = net.getL3Device && net.getL3Device();
			const n = dev && dev.getName && dev.getName();
			if (n) pushIface(n);
		});
	} catch (e) {}

	const order = ['wan', 'ethernet', 'wifi', 'vpn', 'virtual', 'other'];
	return result.sort((a, b) => {
		const ca = order.indexOf(a.category);
		const cb = order.indexOf(b.category);
		if (ca !== cb) return ca - cb;
		return a.name.localeCompare(b.name);
	});
}

async function getHwidValues() {
	try {
		let hwid = 'unknown';
		try {
			const macResult = await fs.exec('/bin/sh', ['-c',
				"cat /sys/class/net/eth0/address 2>/dev/null | tr -d ':' | md5sum | cut -c1-14"
			]);
			if (macResult.code === 0 && macResult.stdout) hwid = macResult.stdout.trim();
		} catch (e) {}

		let verOs = 'unknown';
		try {
			const verResult = await fs.exec('/bin/sh', ['-c',
				'. /etc/openwrt_release && echo $DISTRIB_RELEASE'
			]);
			if (verResult.code === 0 && verResult.stdout) verOs = verResult.stdout.trim();
		} catch (e) {}

		let deviceModel = 'Router';
		try {
			const modelResult = await fs.exec('/bin/sh', ['-c', 'cat /tmp/sysinfo/model 2>/dev/null']);
			if (modelResult.code === 0 && modelResult.stdout) deviceModel = modelResult.stdout.trim();
		} catch (e) {}

		return { hwid, verOs, deviceModel };
	} catch (e) {
		return { hwid: 'unknown', verOs: 'unknown', deviceModel: 'Router' };
	}
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
		const configContent = await L.resolveDefault(fs.read(CONFIG_PATH), '');
		if (!configContent) return 'tproxy';

		const lines = configContent.split('\n');
		let hasTproxy = false;
		let hasTun = false;

		for (let i = 0; i < lines.length; i++) {
			const line = lines[i];
			const trimmed = line.trim();

			if (/^tproxy-port:/.test(trimmed) && !trimmed.startsWith('#')) hasTproxy = true;
			if (/^tun:/.test(trimmed)) {
				for (let j = i + 1; j < Math.min(i + 10, lines.length); j++) {
					const next = lines[j].trim();
					if (/^enable:\s*true/.test(next)) {
						hasTun = true;
						break;
					}
					if (/^[a-zA-Z]/.test(next) && !next.startsWith('#')) break;
				}
			}
		}

		if (hasTproxy && hasTun) return 'mixed';
		if (hasTun) return 'tun';
		if (hasTproxy) return 'tproxy';
		return 'tproxy';
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
		internetOnlyMiclash: false,
		useTmpfsRules: true,
		autoHideNotifications: true,
		autoUpdateConfig: true,
		autoUpdateIntervalHours: '4',
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

async function loadOperationalSettings() {
	try {
		const content = await L.resolveDefault(fs.read(SETTINGS_PATH), '');
		const settings = defaultOperationalSettings();

		String(content || '').split('\n').forEach((line) => {
			const idx = line.indexOf('=');
			if (idx === -1) return;
			const key = line.slice(0, idx).trim();
			const value = line.slice(idx + 1).trim();

			switch (key) {
				case 'INTERFACE_MODE': settings.mode = value; break;
				case 'PROXY_MODE': settings.proxyMode = value; break;
				case 'TUN_STACK': settings.tunStack = value || 'system'; break;
				case 'AUTO_DETECT_LAN': settings.autoDetectLan = value === 'true'; break;
				case 'AUTO_DETECT_WAN': settings.autoDetectWan = value === 'true'; break;
				case 'BLOCK_QUIC': settings.blockQuic = value === 'true'; break;
				case 'INTERNET_ONLY_MICLASH': settings.internetOnlyMiclash = value === 'true'; break;
				case 'USE_TMPFS_RULES': settings.useTmpfsRules = value === 'true'; break;
				case 'AUTO_HIDE_NOTIFICATIONS': settings.autoHideNotifications = value !== 'false'; break;
				case 'AUTO_UPDATE_CONFIG': settings.autoUpdateConfig = value !== 'false'; break;
				case 'AUTO_UPDATE_INTERVAL_HOURS': settings.autoUpdateIntervalHours = normalizeAutoUpdateIntervalHours(value); break;
				case 'MICLASH_RELEASE_CHANNEL': settings.miclashReleaseChannel = view_miclash_release.normalizeReleaseChannel(value); break;
				case 'MIHOMO_RELEASE_CHANNEL': settings.mihomoReleaseChannel = view_miclash_release.normalizeReleaseChannel(value); break;
				case 'DETECTED_LAN': settings.detectedLan = value; break;
				case 'DETECTED_WAN': settings.detectedWan = value; break;
				case 'INCLUDED_INTERFACES':
					settings.includedInterfaces = value ? value.split(',').map((i) => i.trim()).filter(Boolean) : [];
					break;
				case 'EXCLUDED_INTERFACES':
					settings.excludedInterfaces = value ? value.split(',').map((i) => i.trim()).filter(Boolean) : [];
					break;
				case 'ENABLE_HWID': settings.enableHwid = value === 'true'; break;
				case 'HWID_USER_AGENT': settings.hwidUserAgent = value || 'MiClash'; break;
				case 'HWID_DEVICE_OS': settings.hwidDeviceOS = value || 'OpenWrt'; break;
			}
		});

		return settings;
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
		try {
			const nets = await network.getNetworks();
			for (let i = 0; i < nets.length; i++) {
				const net = nets[i];
				if (net.getName && net.getName() === 'lan') {
					const dev = net.getL3Device && net.getL3Device();
					if (dev && dev.getName && dev.getName()) return dev.getName();
				}
			}
		} catch (e) {}

		const ipResult = await fs.exec('/sbin/ip', ['addr', 'show']);
		if (ipResult.code === 0 && ipResult.stdout) {
			const lines = String(ipResult.stdout).split('\n');
			let currentIface = '';

			for (let i = 0; i < lines.length; i++) {
				const line = lines[i];
				const ifaceMatch = line.match(/^\d+:\s+([^:@]+):/);
				if (ifaceMatch) {
					currentIface = ifaceMatch[1];
					continue;
				}

				const ipMatch = line.match(/inet\s+(\d+\.\d+\.\d+\.\d+)/);
				if (ipMatch && currentIface && currentIface !== 'lo') {
					const ip = ipMatch[1];
					if (/^192\.168\.|^10\.|^172\.(1[6-9]|2[0-9]|3[01])\./.test(ip)) {
						if (/^(br-|bridge)/.test(currentIface) || currentIface === 'lan') return currentIface;
					}
				}
			}
		}

		return null;
	} catch (e) {
		return null;
	}
}

async function detectWanInterface() {
	try {
		try {
			const nets = await network.getNetworks();
			for (let i = 0; i < nets.length; i++) {
				const net = nets[i];
				if ((net.getName && net.getName() === 'wan') || (net.getName && net.getName() === 'wan6')) {
					const dev = net.getL3Device && net.getL3Device();
					if (dev && dev.getName && dev.getName()) return dev.getName();
				}
			}
		} catch (e) {}

		const routeContent = await L.resolveDefault(fs.read('/proc/net/route'), '');
		const lines = String(routeContent).split('\n');
		for (let i = 0; i < lines.length; i++) {
			const fields = lines[i].split('\t');
			if (fields[1] === '00000000' && fields[0] !== 'Iface') return fields[0];
		}

		return null;
	} catch (e) {
		return null;
	}
}

async function saveOperationalSettings(mode, proxyMode, tunStack, autoDetectLan, autoDetectWan, blockQuic, internetOnlyMiclash, useTmpfsRules, interfaces, enableHwid, hwidUserAgent, hwidDeviceOS, autoHideNotifications, miclashReleaseChannel, mihomoReleaseChannel, autoUpdateConfig, autoUpdateIntervalHours) {
	let detectedLan = '';
	let detectedWan = '';
	const cleanAutoUpdateIntervalHours = normalizeAutoUpdateIntervalHours(autoUpdateIntervalHours);

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

	const settings = await view_miclash_store.readSettingsMap();
	settings.INTERFACE_MODE = mode;
	settings.PROXY_MODE = proxyMode;
	settings.TUN_STACK = tunStack;
	settings.AUTO_DETECT_LAN = autoDetectLan;
	settings.AUTO_DETECT_WAN = autoDetectWan;
	settings.BLOCK_QUIC = blockQuic;
	settings.INTERNET_ONLY_MICLASH = internetOnlyMiclash;
	settings.USE_TMPFS_RULES = useTmpfsRules;
	settings.AUTO_HIDE_NOTIFICATIONS = autoHideNotifications !== false;
	settings.AUTO_UPDATE_CONFIG = autoUpdateConfig !== false;
	settings.AUTO_UPDATE_INTERVAL_HOURS = cleanAutoUpdateIntervalHours;
	settings.MICLASH_RELEASE_CHANNEL = view_miclash_release.normalizeReleaseChannel(miclashReleaseChannel);
	settings.MIHOMO_RELEASE_CHANNEL = view_miclash_release.normalizeReleaseChannel(mihomoReleaseChannel);
	settings.DETECTED_LAN = detectedLan;
	settings.DETECTED_WAN = detectedWan;
	settings.INCLUDED_INTERFACES = includedInterfaces.join(',');
	settings.EXCLUDED_INTERFACES = excludedInterfaces.join(',');
	settings.ENABLE_HWID = enableHwid;
	settings.HWID_USER_AGENT = hwidUserAgent;
	settings.HWID_DEVICE_OS = hwidDeviceOS;

	await view_miclash_store.writeSettingsMap(settings);

	const configContent = await L.resolveDefault(fs.read(CONFIG_PATH), '');
	if (configContent) {
		let updatedConfig = transformProxyMode(configContent, proxyMode, tunStack);
		if (enableHwid) {
			const hwidValues = await getHwidValues();
			updatedConfig = addHwidToYaml(
				updatedConfig,
				hwidUserAgent,
				hwidDeviceOS,
				hwidValues.hwid,
				hwidValues.verOs,
				hwidValues.deviceModel
			);
		}
		await view_miclash_store.writeTextFile(CONFIG_PATH, updatedConfig);
	}
}

return L.Class.extend({
	getNetworkInterfaces: getNetworkInterfaces,
	transformProxyMode: transformProxyMode,
	detectCurrentProxyMode: detectCurrentProxyMode,
	loadOperationalSettings: loadOperationalSettings,
	loadInterfacesByMode: loadInterfacesByMode,
	detectLanBridge: detectLanBridge,
	detectWanInterface: detectWanInterface,
	saveOperationalSettings: saveOperationalSettings,
	normalizeProxyMode: normalizeProxyMode
});
