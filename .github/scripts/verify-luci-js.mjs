import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

const viewDir = path.join(
	process.cwd(),
	'luci-app-miclash',
	'rootfs',
	'www',
	'luci-static',
	'resources',
	'view',
	'miclash'
);
const menuPath = path.join(
	process.cwd(),
	'luci-app-miclash',
	'rootfs',
	'usr',
	'share',
	'luci',
	'menu.d',
	'luci-app-miclash.json'
);
const aclPath = path.join(
	process.cwd(),
	'luci-app-miclash',
	'rootfs',
	'usr',
	'share',
	'rpcd',
	'acl.d',
	'luci-app-miclash.json'
);
const servicePath = path.join(viewDir, 'service.js');
const configPath = path.join(viewDir, 'config.js');
const guardPath = path.join(viewDir, 'guard.js');

function walk(dir) {
	const out = [];
	for (const item of fs.readdirSync(dir, { withFileTypes: true })) {
		const full = path.join(dir, item.name);
		if (item.isDirectory()) out.push(...walk(full));
		else if (item.isFile() && item.name.endsWith('.js')) out.push(full);
	}
	return out;
}

const files = walk(viewDir);
const missing = [];
const serviceSource = fs.readFileSync(servicePath, 'utf8');
const configSource = fs.readFileSync(configPath, 'utf8');
const guardSource = fs.readFileSync(guardPath, 'utf8');

for (const [name, minValue] of [
	['START_SERVICE_TIMEOUT_MS', 120000],
	['RESTART_SERVICE_TIMEOUT_MS', 120000],
	['STOP_SERVICE_TIMEOUT_MS', 60000]
]) {
	const match = serviceSource.match(new RegExp(`const\\s+${name}\\s*=\\s*(\\d+)`));
	if (!match || Number(match[1]) < minValue) {
		missing.push(`service.js -> ${name} must be at least ${minValue}ms`);
	}
}

if (!/getActionTimeout\([\s\S]+START_SERVICE_TIMEOUT_MS/.test(serviceSource)) {
	missing.push('service.js -> start/restart actions must use long action timeout defaults');
}

if (!/function\s+isNetworkUpdateBlocked\(\)[\s\S]+view_miclash_guard\.isNetworkUpdateBlocked/.test(configSource)) {
	missing.push('config.js -> subscription/update guard block helper is missing');
}

if (!/async function\s+fetchSubscriptionAsYaml\([^)]*\)\s*{[\s\S]*?await prepareNetworkUpdate\(\);/.test(configSource)) {
	missing.push('config.js -> subscription downloads must prepare guarded network path first');
}

for (const fn of ['installMiClashFromSettings', 'installKernelFromSettings']) {
	const pattern = new RegExp(`async function\\s+${fn}\\([^)]*\\)\\s*{[\\s\\S]*?await prepareNetworkUpdate\\(\\);`);
	if (!pattern.test(configSource)) {
		missing.push(`config.js -> ${fn} must prepare guarded network path first`);
	}
}

if (!/function\s+isNetworkUpdateBlocked\([^)]*\)[\s\S]+isInternetOnlyEnabled\(settings\)\s*&&\s*!serviceRunning/.test(guardSource)) {
	missing.push('guard.js -> guard must block network updates when service is stopped');
}

if (!/async function\s+prepareNetworkUpdate\([^)]*\)[\s\S]+assertNetworkUpdateAllowed\([^)]*\)[\s\S]+repair_network_path/.test(guardSource)) {
	missing.push('guard.js -> running guard updates must repair network path before network access');
}

for (const file of files) {
	const check = spawnSync(process.execPath, ['--check', file], { encoding: 'utf8' });
	if (check.status !== 0) {
		process.stderr.write(check.stderr || check.stdout || `Syntax check failed: ${file}\n`);
		process.exit(check.status || 1);
	}

	const source = fs.readFileSync(file, 'utf8');
	const requiredGlobals = new Set();
	const mojibake = source.match(/(?:Р |РІР|вЂ|Р‚|Сњ)/);
	if (mojibake) {
		missing.push(`${path.relative(process.cwd(), file)} -> mojibake text ${mojibake[0]}`);
	}

	for (const match of source.matchAll(/'require view\.miclash\.([^']+)'/g)) {
		const rel = match[1].replace(/\./g, path.sep) + '.js';
		const target = path.join(viewDir, rel);
		requiredGlobals.add(`view_miclash_${match[1].replace(/[.-]/g, '_')}`);
		if (!fs.existsSync(target)) {
			missing.push(`${path.relative(process.cwd(), file)} -> ${rel}`);
		}
	}

	for (const match of source.matchAll(/\bview_miclash_[A-Za-z0-9_]+\b/g)) {
		const identifier = match[0];
		if (!requiredGlobals.has(identifier)) {
			missing.push(`${path.relative(process.cwd(), file)} -> missing require for ${identifier}`);
		}
	}
}

const menu = JSON.parse(fs.readFileSync(menuPath, 'utf8'));
const acl = JSON.parse(fs.readFileSync(aclPath, 'utf8'));
const miclashAcl = acl['luci-app-miclash'];
const menuEntries = Object.keys(menu);
const rootMenuEntry = menu['admin/services/miclash'];

if (!miclashAcl) {
	missing.push('ACL object luci-app-miclash');
}

if (!rootMenuEntry) {
	missing.push('menu -> missing admin/services/miclash root entry');
}

if (menuEntries.length !== 1) {
	missing.push(`menu -> expected exactly one LuCI entry, found ${menuEntries.length}`);
}

if (rootMenuEntry?.action?.type !== 'view' || rootMenuEntry?.action?.path !== 'miclash/config') {
	missing.push('menu -> admin/services/miclash must point directly to miclash/config');
}

for (const entry of menuEntries) {
	if (/^admin\/services\/miclash\//.test(entry)) {
		missing.push(`${entry} -> child LuCI menu entries would restore unwanted top tab groups`);
	}
}

function aclFileEntries() {
	const entries = [];
	for (const section of ['read', 'write']) {
		const files = miclashAcl?.[section]?.file || {};
		for (const [pattern, perms] of Object.entries(files)) {
			entries.push({ section, pattern, perms: new Set(perms) });
		}
	}
	return entries;
}

function patternMatches(pattern, candidate) {
	if (pattern === candidate) return true;
	const escaped = pattern
		.replace(/[.+?^${}()|[\]\\]/g, '\\$&')
		.replace(/\*/g, '.*');
	return new RegExp(`^${escaped}$`).test(candidate);
}

function hasAclPermission(candidate, permission) {
	return aclFileEntries().some((entry) => (
		entry.perms.has(permission) && patternMatches(entry.pattern, candidate)
	));
}

const fsOperationPermissions = {
	exec: 'exec',
	read: 'read',
	write: 'write',
	remove: 'remove',
	stat: 'stat',
	list: 'list'
};

const knownCommandPaths = {
	ls: ['/bin/ls'],
	ip: ['/sbin/ip', '/bin/ip', '/usr/sbin/ip', '/usr/bin/ip'],
	opkg: ['/bin/opkg', '/usr/bin/opkg'],
	apk: ['/bin/apk', '/usr/bin/apk']
};

for (const file of files) {
	const source = fs.readFileSync(file, 'utf8');
	for (const match of source.matchAll(/fs\.(exec|read|write|remove|stat|list)\(\s*(['"])(\/[^'"]+)\2/g)) {
		const operation = match[1];
		const target = match[3];
		const permission = fsOperationPermissions[operation];
		if (permission && !hasAclPermission(target, permission)) {
			missing.push(`${path.relative(process.cwd(), file)} -> ACL ${permission} ${target}`);
		}
	}

	for (const match of source.matchAll(/fs\.exec\(\s*(['"])([^\/'"][^'"]*)\1/g)) {
		const command = match[2];
		const candidates = knownCommandPaths[command];
		if (!candidates) continue;

		if (!candidates.some((target) => hasAclPermission(target, 'exec'))) {
			missing.push(`${path.relative(process.cwd(), file)} -> ACL exec ${command} (${candidates.join(' or ')})`);
		}
	}
}

for (const [entry, node] of Object.entries(menu)) {
	const action = node && node.action;
	if (!action || action.type !== 'view') continue;

	const viewPath = String(action.path || '');
	if (!viewPath.startsWith('miclash/')) {
		missing.push(`${entry} -> invalid view path ${viewPath}`);
		continue;
	}

	const rel = viewPath.replace(/^miclash\//, '') + '.js';
	const target = path.join(viewDir, rel);
	if (!fs.existsSync(target)) {
		missing.push(`${entry} -> ${rel}`);
	}
}

if (missing.length) {
	console.error('LuCI verification failed:');
	for (const item of missing) console.error(`- ${item}`);
	process.exit(1);
}

console.log(`LuCI JS verified: ${files.length} files`);
