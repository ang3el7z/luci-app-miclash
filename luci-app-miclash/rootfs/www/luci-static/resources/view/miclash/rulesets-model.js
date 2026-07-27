'use strict';
'require view.miclash.api';

const RULESET_PATH = '/opt/clash/lst/';
const FAKEIP_WHITELIST_FILENAME = 'fakeip-whitelist-ipcidr.txt';

function configContent(reply) {
	return typeof reply === 'string' ? reply : String(reply?.content || '');
}

function normalizeName(rawName) {
	const clean = String(rawName || '').trim().replace(/\.txt$/i, '');
	if (!clean || !/^[A-Za-z0-9_-]+$/.test(clean)) return '';
	return clean.toLowerCase();
}

function isEditableFile(fileName) {
	return /\.txt$/i.test(fileName) && fileName !== FAKEIP_WHITELIST_FILENAME;
}

async function detectFakeIpWhitelistMode(configPath) {
	try {
		const profile = String(configPath || '').split('/').pop() || 'config.yaml';
		const activeConfig = configContent(await withApi((api) => api.config_read(profile)));
		if (!activeConfig) return false;

		let inDns = false;
		let dnsEnabled = false;
		let fakeIpMode = false;
		let filterMode = 'blacklist';

		String(activeConfig).split('\n').forEach((line) => {
			const trimmed = line.trim();

			if (/^dns:\s*$/.test(trimmed)) {
				inDns = true;
				return;
			}

			if (inDns && trimmed && !/^\s/.test(line)) {
				inDns = false;
			}
			if (!inDns) return;

			if (/^enable:\s*true/i.test(trimmed)) dnsEnabled = true;
			if (/^enhanced-mode:\s*fake-ip/i.test(trimmed)) fakeIpMode = true;

			const modeMatch = trimmed.match(/^fake-ip-filter-mode:\s*(\S+)/i);
			if (modeMatch) {
				filterMode = String(modeMatch[1] || '').toLowerCase().replace(/['"]/g, '');
			}
		});

		return dnsEnabled && fakeIpMode && filterMode === 'whitelist';
	} catch (e) {
		return false;
	}
}

async function readData(configPath) {
	return withApi(async (api) => {
		const listing = await api.ruleset_list();
		const rulesetNames = (Array.isArray(listing?.names) ? listing.names : [])
			.filter(isEditableFile).sort((a, b) => a.localeCompare(b));
		const contentMap = {};
		if (rulesetNames.length) {
			const first = rulesetNames[0];
			contentMap[first] = String((await api.ruleset_read(first)).content || '');
		}
		const profile = String(configPath || '').split('/').pop() || 'config.yaml';
		const activeConfig = configContent(await api.config_read(profile));
		const whitelistMode = parseFakeIpWhitelistMode(activeConfig);
		let whitelistContent = '';
		if (whitelistMode) {
			try { whitelistContent = String((await api.ruleset_read(FAKEIP_WHITELIST_FILENAME)).content || ''); }
			catch (_) { whitelistContent = ''; }
		}
		return { rulesetNames, contentMap, whitelistMode, whitelistContent };
	});
}

function parseFakeIpWhitelistMode(configContent) {
	let inDns = false, dnsEnabled = false, fakeIpMode = false, filterMode = 'blacklist';
	String(configContent || '').split('\n').forEach((line) => {
		const trimmed = line.trim();
		if (/^dns:\s*$/.test(trimmed)) { inDns = true; return; }
		if (inDns && trimmed && !/^\s/.test(line)) inDns = false;
		if (!inDns) return;
		if (/^enable:\s*true/i.test(trimmed)) dnsEnabled = true;
		if (/^enhanced-mode:\s*fake-ip/i.test(trimmed)) fakeIpMode = true;
		const match = trimmed.match(/^fake-ip-filter-mode:\s*(\S+)/i);
		if (match) filterMode = String(match[1] || '').toLowerCase().replace(/['"]/g, '');
	});
	return dnsEnabled && fakeIpMode && filterMode === 'whitelist';
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
			if (error) { if (cancel) cancel(); reject(error); }
			else if (record?.state === 'success') { if (cancel) cancel(); resolve(record); }
			else if (record?.state === 'failure' || record?.state === 'interrupted') {
				if (cancel) cancel();
				const failure = new Error(record?.error?.message || 'Ruleset operation failed');
				failure.code = record?.error?.code || 'HEALTH_FAILED'; reject(failure);
			}
		});
	});
}

async function readFile(fileName) {
	return withApi(async (api) => String((await api.ruleset_read(fileName)).content || ''));
}

async function createFile(fileName) { return saveFile(fileName, ''); }

async function saveFile(fileName, content) {
	return withApi(async (api) => waitOperation(api,
		await api.ruleset_write(fileName, String(content || ''), 'luci')));
}

async function deleteFile(fileName) {
	return withApi(async (api) => waitOperation(api, await api.ruleset_delete(fileName, 'luci')));
}

async function saveWhitelist(content) {
	return withApi(async (api) => waitOperation(api,
		await api.ruleset_apply_whitelist(String(content || ''), 'luci')));
}

return L.Class.extend({
	RULESET_PATH: RULESET_PATH,
	FAKEIP_WHITELIST_FILENAME: FAKEIP_WHITELIST_FILENAME,
	normalizeName: normalizeName,
	readFile: readFile,
	readData: readData,
	createFile: createFile,
	saveFile: saveFile,
	deleteFile: deleteFile,
	saveWhitelist: saveWhitelist
});
