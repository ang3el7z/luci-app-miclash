'use strict';
'require fs';

const RULESET_PATH = '/opt/clash/lst/';
const FAKEIP_WHITELIST_FILENAME = 'fakeip-whitelist-ipcidr.txt';

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
		const configContent = await L.resolveDefault(fs.read(configPath), '');
		if (!configContent) return false;

		let inDns = false;
		let dnsEnabled = false;
		let fakeIpMode = false;
		let filterMode = 'blacklist';

		String(configContent).split('\n').forEach((line) => {
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
	try {
		await fs.exec('/bin/mkdir', ['-p', RULESET_PATH]);
	} catch (e) {}

	const files = await L.resolveDefault(fs.list(RULESET_PATH), []);
	const rulesetNames = (files || [])
		.filter((item) => item && isEditableFile(item.name || ''))
		.map((item) => item.name)
		.sort((a, b) => a.localeCompare(b));

	const contentMap = {};
	for (let i = 0; i < rulesetNames.length; i++) {
		const name = rulesetNames[i];
		contentMap[name] = await L.resolveDefault(fs.read(RULESET_PATH + name), '');
	}

	const whitelistMode = await detectFakeIpWhitelistMode(configPath);
	let whitelistContent = '';

	if (whitelistMode) {
		const filePath = RULESET_PATH + FAKEIP_WHITELIST_FILENAME;
		const existing = await L.resolveDefault(fs.read(filePath), null);
		if (existing == null) {
			await fs.write(filePath, '');
		} else {
			whitelistContent = existing;
		}
	}

	return {
		rulesetNames: rulesetNames,
		contentMap: contentMap,
		whitelistMode: whitelistMode,
		whitelistContent: whitelistContent
	};
}

async function createFile(fileName) {
	await fs.write(RULESET_PATH + fileName, '');
}

async function saveFile(fileName, content) {
	await fs.write(RULESET_PATH + fileName, String(content || ''));
}

async function deleteFile(fileName) {
	await fs.remove(RULESET_PATH + fileName);
}

async function saveWhitelist(content) {
	await fs.write(RULESET_PATH + FAKEIP_WHITELIST_FILENAME, String(content || ''));
	return fs.exec('/opt/clash/bin/clash-rules', ['update-ip-whitelist']);
}

return L.Class.extend({
	RULESET_PATH: RULESET_PATH,
	FAKEIP_WHITELIST_FILENAME: FAKEIP_WHITELIST_FILENAME,
	normalizeName: normalizeName,
	readData: readData,
	createFile: createFile,
	saveFile: saveFile,
	deleteFile: deleteFile,
	saveWhitelist: saveWhitelist
});
