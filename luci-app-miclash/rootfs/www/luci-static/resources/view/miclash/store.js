'use strict';
'require fs';
'require view.miclash.utils';

const CONFIG_PATH = '/opt/clash/config.yaml';
const CONFIG_DIR = '/opt/clash';
const MAIN_CONFIG_NAME = 'config.yaml';
const CONFIG_PROFILES = [
	{ name: 'config.yaml', label: 'Main Config #1' },
	{ name: 'config2.yaml', label: 'Backup Config #2' },
	{ name: 'config3.yaml', label: 'Backup Config #3' }
];
const SETTINGS_PATH = '/opt/clash/settings';

function normalizeConfigProfileName(name) {
	const clean = String(name || '').trim();
	return CONFIG_PROFILES.some((item) => item.name === clean) ? clean : MAIN_CONFIG_NAME;
}

function getConfigProfileByName(name) {
	const normalized = normalizeConfigProfileName(name);
	return CONFIG_PROFILES.find((item) => item.name === normalized) || CONFIG_PROFILES[0];
}

function getConfigLabel(name) {
	return getConfigProfileByName(name).label;
}

function getConfigPathByName(name) {
	return CONFIG_DIR + '/' + normalizeConfigProfileName(name);
}

function getSubscriptionKeyForConfig(name) {
	const normalized = normalizeConfigProfileName(name).replace(/[^A-Za-z0-9]/g, '_').toUpperCase();
	return 'SUBSCRIPTION_URL_' + normalized;
}

function parseSettingsToMap(raw) {
	const map = {};
	String(raw || '').split('\n').forEach((line) => {
		const trimmed = line.trim();
		if (!trimmed || trimmed.charAt(0) === '#') return;
		const idx = trimmed.indexOf('=');
		if (idx <= 0) return;
		const key = trimmed.slice(0, idx).trim();
		const value = trimmed.slice(idx + 1).trim();
		if (key) map[key] = value;
	});
	return map;
}

function mapToSettingsContent(map) {
	return Object.keys(map).map((k) => k + '=' + map[k]).join('\n') + '\n';
}

async function setFileMode(path) {
	await L.resolveDefault(fs.exec('/bin/chmod', ['0644', path]), null);
	await L.resolveDefault(fs.exec('/usr/bin/chmod', ['0644', path]), null);
}

async function writeTextFile(path, content) {
	await view_miclash_utils.writeFile(path, String(content || ''));
}

async function readSettingsMap() {
	try {
		return parseSettingsToMap(await fs.read(SETTINGS_PATH));
	} catch (e) {
		return {};
	}
}

async function writeSettingsMap(map) {
	await writeTextFile(SETTINGS_PATH, mapToSettingsContent(map));
}

async function readConfigFileByName(name) {
	const path = getConfigPathByName(name);
	await setFileMode(path);
	return String(await L.resolveDefault(fs.read(path), ''));
}

async function writeConfigFileByName(name, content) {
	const path = getConfigPathByName(name);
	const normalized = String(content || '').trimEnd() + '\n';
	await writeTextFile(path, normalized);
	await setFileMode(path);
}

async function ensureConfigProfilesReady(seedMainContent) {
	const mainPath = getConfigPathByName(MAIN_CONFIG_NAME);
	let mainContent = await L.resolveDefault(fs.read(mainPath), null);
	if (mainContent == null) {
		mainContent = String(seedMainContent || '');
		await writeTextFile(mainPath, String(mainContent).trimEnd() + '\n');
	}
	await setFileMode(mainPath);

	for (let i = 0; i < CONFIG_PROFILES.length; i++) {
		const profile = CONFIG_PROFILES[i];
		const path = getConfigPathByName(profile.name);
		const existing = await L.resolveDefault(fs.read(path), null);
		if (existing == null) {
			await writeTextFile(path, String(mainContent || '').trimEnd() + '\n');
		}
		await setFileMode(path);
	}
}

async function readSubscriptionUrl(configName) {
	const normalized = normalizeConfigProfileName(configName || MAIN_CONFIG_NAME);
	const key = getSubscriptionKeyForConfig(normalized);
	const settings = await readSettingsMap();

	if (normalized === MAIN_CONFIG_NAME) {
		return String(settings[key] || settings.SUBSCRIPTION_URL || '').trim();
	}

	return String(settings[key] || '').trim();
}

async function saveSubscriptionUrl(url, configName) {
	const normalized = normalizeConfigProfileName(configName || MAIN_CONFIG_NAME);
	const key = getSubscriptionKeyForConfig(normalized);
	const clean = String(url || '').trim().replace(/\r?\n/g, '');
	const settings = await readSettingsMap();
	settings[key] = clean;
	if (normalized === MAIN_CONFIG_NAME) {
		settings.SUBSCRIPTION_URL = clean;
	}
	await writeSettingsMap(settings);
}

return L.Class.extend({
	CONFIG_PATH: CONFIG_PATH,
	CONFIG_DIR: CONFIG_DIR,
	MAIN_CONFIG_NAME: MAIN_CONFIG_NAME,
	CONFIG_PROFILES: CONFIG_PROFILES,
	SETTINGS_PATH: SETTINGS_PATH,
	normalizeConfigProfileName: normalizeConfigProfileName,
	getConfigLabel: getConfigLabel,
	getConfigPathByName: getConfigPathByName,
	setFileMode: setFileMode,
	writeTextFile: writeTextFile,
	readSettingsMap: readSettingsMap,
	writeSettingsMap: writeSettingsMap,
	readConfigFileByName: readConfigFileByName,
	writeConfigFileByName: writeConfigFileByName,
	ensureConfigProfilesReady: ensureConfigProfilesReady,
	readSubscriptionUrl: readSubscriptionUrl,
	saveSubscriptionUrl: saveSubscriptionUrl
});
