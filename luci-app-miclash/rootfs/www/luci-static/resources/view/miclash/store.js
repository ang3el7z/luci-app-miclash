'use strict';
'require view.miclash.api';

const CONFIG_PATH = '/opt/clash/config.yaml';
const CONFIG_DIR = '/opt/clash';
const MAIN_CONFIG_NAME = 'config.yaml';
const CONFIG_PROFILES = [
	{ name: 'config.yaml', label: 'Config #1' },
	{ name: 'config2.yaml', label: 'Config #2' },
	{ name: 'config3.yaml', label: 'Config #3' }
];
const SETTINGS_PATH = '/opt/clash/settings';

function normalizeConfigProfileName(name) {
	const clean = String(name || '').trim();
	return CONFIG_PROFILES.some((item) => item.name === clean) ? clean : MAIN_CONFIG_NAME;
}
function getConfigProfileByName(name) {
	return CONFIG_PROFILES.find((item) => item.name === normalizeConfigProfileName(name)) || CONFIG_PROFILES[0];
}
function getConfigLabel(name) { return getConfigProfileByName(name).label; }
function getConfigPathByName(name) { return CONFIG_DIR + '/' + normalizeConfigProfileName(name); }
function getSubscriptionKeyForConfig(name) {
	return 'SUBSCRIPTION_URL_' + normalizeConfigProfileName(name)
		.replace(/[^A-Za-z0-9]/g, '_').toUpperCase();
}
function parseSettingsToMap(raw) {
	const map = {};
	String(raw || '').split('\n').forEach((line) => {
		const index = line.indexOf('=');
		if (index > 0) map[line.slice(0, index).trim()] = line.slice(index + 1).trim();
	});
	return map;
}
function mapToSettingsContent(map) {
	return Object.keys(map).map((key) => key + '=' + map[key]).join('\n') + '\n';
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
				const failure = new Error(record?.error?.message || 'Storage operation failed');
				failure.code = record?.error?.code || 'HEALTH_FAILED'; reject(failure);
			}
		});
	});
}
function bool(value, fallback) {
	if (typeof value === 'boolean') return value;
	if (value == null || value === '') return fallback;
	return /^(?:1|true|yes|on)$/i.test(String(value));
}
function list(value) {
	return Array.isArray(value) ? value.slice() : String(value || '').split(',').map((item) => item.trim()).filter(Boolean);
}
function configContent(reply) {
	return typeof reply === 'string' ? reply : String(reply?.content || '');
}
function selectActiveOperation(operations, kindPrefix) {
	const prefix = String(kindPrefix || '');
	if (!Array.isArray(operations) || !prefix) return null;
	return operations.filter((item) => {
		const state = String(item?.state || '');
		return (state === 'queued' || state === 'running') &&
			String(item?.kind || '').startsWith(prefix) && String(item?.id || '');
	}).sort((left, right) => {
		const leftTime = Number(left?.updated_at ?? left?.created_at ?? 0);
		const rightTime = Number(right?.updated_at ?? right?.created_at ?? 0);
		if (leftTime !== rightTime) return rightTime - leftTime;
		return String(right?.id || '').localeCompare(String(left?.id || ''));
	})[0] || null;
}
function settingsMap(value) {
	const core = value?.core || {}, interfaces = value?.interfaces || {};
	const memory = value?.memory || {}, updates = value?.updates || {}, notifications = value?.notifications || {};
	return {
		INTERFACE_MODE: interfaces.mode, PROXY_MODE: core.proxy_mode, TUN_STACK: core.tun_stack,
		AUTO_DETECT_LAN: interfaces.auto_detect_lan, AUTO_DETECT_WAN: interfaces.auto_detect_wan,
		BLOCK_QUIC: core.block_quic, USE_TMPFS_RULES: core.use_tmpfs_rules,
		ENABLE_MEMORY_GUARD: memory.enabled, AUTO_HIDE_NOTIFICATIONS: notifications.auto_hide,
		AUTO_UPDATE_CONFIG: updates.auto_subscription,
		AUTO_UPDATE_INTERVAL_HOURS: String(updates.interval_hours || 4),
		MICLASH_RELEASE_CHANNEL: updates.miclash_release_channel,
		MIHOMO_RELEASE_CHANNEL: updates.mihomo_release_channel,
		DETECTED_LAN: interfaces.detected_lan || '', DETECTED_WAN: interfaces.detected_wan || '',
		INCLUDED_INTERFACES: (interfaces.included || []).join(','),
		EXCLUDED_INTERFACES: (interfaces.excluded || []).join(','),
		ENABLE_HWID: core.hwid_enabled, HWID_USER_AGENT: core.hwid_user_agent,
		HWID_DEVICE_OS: core.hwid_device_os
	};
}
function settingsPatch(map) {
	return {
		core: { proxy_mode: String(map.PROXY_MODE || 'tproxy'), tun_stack: String(map.TUN_STACK || 'system'),
			block_quic: bool(map.BLOCK_QUIC, true), use_tmpfs_rules: bool(map.USE_TMPFS_RULES, true),
			hwid_enabled: bool(map.ENABLE_HWID, false),
			hwid_user_agent: String(map.HWID_USER_AGENT || 'MiClash'),
			hwid_device_os: String(map.HWID_DEVICE_OS || 'OpenWrt') },
		interfaces: { mode: String(map.INTERFACE_MODE || 'exclude'),
			auto_detect_lan: bool(map.AUTO_DETECT_LAN, true), auto_detect_wan: bool(map.AUTO_DETECT_WAN, true),
			detected_lan: String(map.DETECTED_LAN || ''), detected_wan: String(map.DETECTED_WAN || ''),
			included: list(map.INCLUDED_INTERFACES), excluded: list(map.EXCLUDED_INTERFACES) },
		memory: { enabled: bool(map.ENABLE_MEMORY_GUARD, true) },
		updates: { auto_subscription: bool(map.AUTO_UPDATE_CONFIG, true),
			interval_hours: Math.max(1, parseInt(map.AUTO_UPDATE_INTERVAL_HOURS, 10) || 4),
			miclash_release_channel: String(map.MICLASH_RELEASE_CHANNEL || 'release'),
			mihomo_release_channel: String(map.MIHOMO_RELEASE_CHANNEL || 'release') },
		notifications: { auto_hide: bool(map.AUTO_HIDE_NOTIFICATIONS, true) }
	};
}
async function setFileMode() { return true; }
async function pathExists(path) {
	const profile = normalizeConfigProfileName(String(path || '').split('/').pop());
	return withApi(async (api) => (await api.config_list()).profiles
		.some((item) => (typeof item === 'string' ? item : item?.profile) === profile));
}
async function readLargeTextFile(path) {
	const profile = normalizeConfigProfileName(String(path || '').split('/').pop());
	try { return configContent(await withApi((api) => api.config_read(profile))); }
	catch (_) { return null; }
}
async function readSettingsMap() { return withApi(async (api) => settingsMap(await api.settings_get())); }
async function writeSettingsMap(map) {
	return withApi(async (api) => waitOperation(api, await api.settings_set(settingsPatch(map || {}), 'luci')));
}
async function readConfigFileByName(name) {
	return configContent(await withApi((api) => api.config_read(normalizeConfigProfileName(name))));
}
async function writeConfigFileByName(name, content) {
	const profile = normalizeConfigProfileName(name), normalized = String(content || '').trimEnd() + '\n';
	return withApi(async (api) => waitOperation(api,
		await api.config_apply(profile, normalized, 'luci')));
}
async function swapConfigProfiles(name) {
	const profile = normalizeConfigProfileName(name);
	if (profile === MAIN_CONFIG_NAME) return true;
	return withApi(async (api) => waitOperation(api, await api.config_swap(profile, 'luci')));
}
async function listConfigProfiles() {
	return withApi(async (api) => {
		const listed = await api.config_list();
		const names = new Set((Array.isArray(listed?.profiles) ? listed.profiles : [])
			.map((item) => typeof item === 'string' ? item : item?.profile));
		return CONFIG_PROFILES.filter((item) =>
			item.name === MAIN_CONFIG_NAME || names.has(item.name));
	});
}
async function writeTextFile(path, content) {
	return writeConfigFileByName(String(path || '').split('/').pop(), content);
}
async function readSubscriptionUrl(configName) {
	const profile = normalizeConfigProfileName(configName || MAIN_CONFIG_NAME);
	const info = await withApi((api) => api.subscription_get(profile));
	return info?.configured && typeof info.url === 'string' ? info.url : '';
}
async function saveSubscriptionUrl(url, configName) {
	const profile = normalizeConfigProfileName(configName || MAIN_CONFIG_NAME);
	const clean = String(url || '').trim().replace(/\r?\n/g, '');
	return withApi(async (api) => waitOperation(api, await api.subscription_set(profile, clean, 'luci')));
}
return L.Class.extend({
	CONFIG_PATH, CONFIG_DIR, MAIN_CONFIG_NAME, CONFIG_PROFILES, SETTINGS_PATH,
	normalizeConfigProfileName, getConfigLabel, getConfigPathByName,
	setFileMode, pathExists, readLargeTextFile, writeTextFile,
	parseSettingsToMap, mapToSettingsContent, readSettingsMap, writeSettingsMap,
	readConfigFileByName, writeConfigFileByName, swapConfigProfiles,
	listConfigProfiles,
	readSubscriptionUrl, saveSubscriptionUrl, getSubscriptionKeyForConfig,
	selectActiveOperation
});
