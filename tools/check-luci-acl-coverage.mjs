import { readdirSync, readFileSync } from 'node:fs';
import path from 'node:path';

const viewRoot = 'luci-app-miclash/rootfs/www/luci-static/resources/view/miclash';
const aclPath = 'luci-app-miclash/rootfs/usr/share/rpcd/acl.d/luci-app-miclash.json';

const acl = JSON.parse(readFileSync(aclPath, 'utf8'))['luci-app-miclash'];
const aclEntries = [];

for (const scope of ['read', 'write']) {
	for (const [pattern, perms] of Object.entries((acl[scope] && acl[scope].file) || {})) {
		aclEntries.push({ scope, pattern, perms });
	}
}

const knownDynamicExecArgs = new Set([
	'config.js::binPath',
	'package.js::checks[i].bin',
	'package.js::bin'
]);

const knownDynamicCommands = [
	'/opt/clash/bin/clash',
	'/usr/bin/apk',
	'/bin/apk',
	'/bin/opkg',
	'/usr/bin/opkg'
];

let failed = false;

function fail(message) {
	console.error(message);
	failed = true;
}

function escapeRegex(value) {
	return String(value).replace(/[\\^$+?.()|[\]{}]/g, '\\$&');
}

function aclPatternMatches(pattern, filePath) {
	const body = String(pattern)
		.split('*')
		.map(escapeRegex)
		.join('[^/]*');
	return new RegExp('^' + body + '$').test(filePath);
}

function hasExecPermission(commandPath) {
	return aclEntries.some((entry) =>
		entry.perms.includes('exec') && aclPatternMatches(entry.pattern, commandPath)
	);
}

function listJsFiles(dir) {
	const entries = readdirSync(dir, { withFileTypes: true });
	const files = [];

	for (const entry of entries) {
		const fullPath = path.join(dir, entry.name);
		if (entry.isDirectory()) {
			files.push(...listJsFiles(fullPath));
		} else if (entry.isFile() && entry.name.endsWith('.js')) {
			files.push(fullPath);
		}
	}

	return files;
}

function relativeFile(filePath) {
	return filePath.split(path.sep).join('/');
}

for (const filePath of listJsFiles(viewRoot)) {
	const source = readFileSync(filePath, 'utf8');
	const rel = relativeFile(filePath);
	const base = path.basename(filePath);
	const execCall = /fs\.exec\(\s*([^,\n]+)/g;
	let match;

	while ((match = execCall.exec(source)) !== null) {
		const line = source.slice(0, match.index).split(/\r?\n/).length;
		const firstArg = match[1].trim();
		const literal = firstArg.match(/^(['"])(.*?)\1$/);

		if (!literal) {
			const key = base + '::' + firstArg;
			if (!knownDynamicExecArgs.has(key)) {
				fail(`Unknown dynamic fs.exec command argument ${firstArg} at ${rel}:${line}`);
			}
			continue;
		}

		const command = literal[2];
		if (!command.startsWith('/')) {
			fail(`fs.exec command must use an absolute path: ${command} at ${rel}:${line}`);
			continue;
		}
		if (!hasExecPermission(command)) {
			fail(`ACL is missing exec permission for ${command}, used at ${rel}:${line}`);
		}
	}
}

for (const command of knownDynamicCommands) {
	if (!hasExecPermission(command)) {
		fail(`ACL is missing exec permission for known dynamic command ${command}`);
	}
}

if (failed) process.exit(1);
console.log('LuCI ACL coverage check passed');
