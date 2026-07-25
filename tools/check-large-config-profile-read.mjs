import { readFileSync } from 'node:fs';

const storePath = 'luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/store.js';
const aclPath = 'luci-app-miclash/rootfs/usr/share/rpcd/acl.d/luci-app-miclash.json';

const store = readFileSync(storePath, 'utf8');
const acl = readFileSync(aclPath, 'utf8');

function check(condition, message) {
	if (!condition) {
		console.error(message);
		process.exit(1);
	}
}

function blockBetween(startNeedle, endNeedle, source = store) {
	const start = source.indexOf(startNeedle);
	if (start < 0) return '';
	const end = source.indexOf(endNeedle, start + startNeedle.length);
	return end >= 0 ? source.slice(start, end) : source.slice(start);
}

const readConfigBlock = blockBetween('async function readConfigFileByName', 'async function writeConfigFileByName');
const ensureProfilesBlock = blockBetween('async function ensureConfigProfilesReady', 'async function readSubscriptionUrl');

check(store.includes('async function readLargeTextFile(') &&
	store.includes('api.config_read(profile)') && !store.includes("'require fs'"),
	'Store must delegate bounded config reads to the typed backend.');

check(readConfigBlock.includes('api.config_read(') && !readConfigBlock.includes('fs.'),
	'readConfigFileByName must use the typed config reader.');

check(store.includes('async function pathExists(') && store.includes('api.config_list()'),
	'Store must check profile existence through the typed config inventory.');

check(!ensureProfilesBlock.includes('fs.') && ensureProfilesBlock.includes('api.config_list()') &&
	ensureProfilesBlock.includes('api.config_read(profile.name)') &&
	ensureProfilesBlock.includes("error?.code !== 'NOT_FOUND'"),
	'ensureConfigProfilesReady must verify listed profiles exist and seed only missing files.');

check(!acl.includes('"file"') && acl.includes('"config_read"') && acl.includes('"config_apply"'),
	'ACL must grant typed config methods without filesystem or shell authority.');

console.log('large config profile read check passed');
