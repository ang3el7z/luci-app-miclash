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

check(store.includes('CONFIG_READ_CHUNK_LINES') &&
	store.includes('async function readLargeTextFile(') &&
	store.includes('sed -n "${2},${3}p" "$1"'),
	'Store must read large config files in bounded line chunks instead of one rpcd file.read response.');

check(readConfigBlock.includes('readLargeTextFile(path)') &&
	!readConfigBlock.includes('fs.read(path)'),
	'readConfigFileByName must use chunked reads so large backup configs can be shown in the editor.');

check(store.includes('async function pathExists(') &&
	store.includes('fs.stat(path)'),
	'Store must check profile existence with stat, not by reading full file content.');

check(!ensureProfilesBlock.includes('fs.read(path)') &&
	ensureProfilesBlock.includes('pathExists(path)'),
	'ensureConfigProfilesReady must not overwrite large backup configs when file.read hits rpcd response limits.');

check(acl.includes('"/bin/sh": [ "exec" ]'),
	'ACL must allow /bin/sh exec for chunked large config reads.');

[
	'/opt/clash/config.yaml',
	'/opt/clash/config2.yaml',
	'/opt/clash/config3.yaml'
].forEach((path) => {
	check(acl.includes(`"${path}": [ "read", "stat" ]`),
		`ACL must allow file.stat for ${path} so large existing configs are not treated as missing.`);
});

[
	'/opt/clash/config.yaml',
	'/opt/clash/config2.yaml',
	'/opt/clash/config3.yaml'
].forEach((path) => {
	check(acl.includes(`"${path}": [ "write", "stat" ]`),
		`Write ACL must also allow file.stat for ${path} because LuCI sessions can check writable paths through the write scope.`);
});

console.log('large config profile read check passed');
