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
const packagePath = path.join(viewDir, 'package.js');
const rulesetsPath = path.join(viewDir, 'rulesets-model.js');
const routePath = path.join(viewDir, 'route.js');

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
const packageSource = fs.readFileSync(packagePath, 'utf8');
const rulesetsSource = fs.readFileSync(rulesetsPath, 'utf8');
const routeSource = fs.existsSync(routePath) ? fs.readFileSync(routePath, 'utf8') : '';

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

if (!/async function\s+dispatchActions\([^)]*\)[\s\S]+view_miclash_utils\.execDetached\([^)]*\)/.test(serviceSource)) {
	missing.push('service.js -> service actions must be dispatched detached from LuCI request timeout');
}

if (!/\.join\(\s*['"];\s*['"]\s*\)/.test(serviceSource)) {
	missing.push('service.js -> multiple init.d actions must run sequentially in one detached script');
}

if (!/async function\s+readDiagnostics\([^)]*\)[\s\S]+view_miclash_logs\.readRaw\(\)/.test(serviceSource)) {
	missing.push('service.js -> service timeouts must include recent MiClash logs');
}

if (!/async function\s+readConfigTestDiagnostics\(\)[\s\S]+fs\.exec\(\s*['"]\/opt\/clash\/bin\/clash['"]\s*,\s*\[[\s\S]*?['"]-d['"][\s\S]*?['"]\/opt\/clash['"][\s\S]*?['"]-t['"][\s\S]*?\]\s*\)/.test(serviceSource)) {
	missing.push('service.js -> running-state timeouts must include clash -t diagnostics');
}

if (!/describeTimeout\([^)]*\)[\s\S]+readDiagnostics\(\s*!!targetStatus\s*\)/.test(serviceSource)) {
	missing.push('service.js -> clash -t diagnostics must only run for start/restart timeouts');
}

if (!/dispatchServiceActionsAndWaitOrThrow\(\s*\[\s*['"]enable['"]\s*,\s*['"]start['"]\s*\]\s*,\s*true\s*\)/.test(configSource)) {
	missing.push('config.js -> start button must enable then start service and wait for running state');
}

if (!/async function\s+validateMainConfigBeforeStart\(\)[\s\S]+readConfigFileByName\(MAIN_CONFIG_NAME\)[\s\S]+testConfigContent\([^)]*CONFIG_PATH[\s\S]+notifyDetailedError/.test(configSource) ||
	!/validateMainConfigBeforeStart\(\)[\s\S]+dispatchServiceActionsAndWaitOrThrow\(\s*\[\s*['"]enable['"]\s*,\s*['"]start['"]/.test(configSource)) {
	missing.push('config.js -> start button must validate main config with clash -t before enabling/starting service');
}

if (!/const\s+restartBtn[\s\S]+addEventListener\(\s*['"]click['"][\s\S]+validateMainConfigBeforeStart\(\)[\s\S]+restartOrReloadServiceOrThrow\(\s*['"]restart['"]\s*\)/.test(configSource)) {
	missing.push('config.js -> restart button must validate main config with clash -t before restarting service');
}

for (const [label, pattern] of [
	['proxy mode switch', /async function\s+switchProxyModeFromHeader\([^)]*\)[\s\S]+validateMainConfigBeforeStart\(\)[\s\S]+restartOrReloadServiceOrThrow\(\s*['"]restart['"]\s*\)/],
	['settings save', /function\s+bindSettingsPaneEvents\(\)[\s\S]+validateMainConfigBeforeStart\(\)[\s\S]+restartOrReloadServiceOrThrow\(\s*['"]restart['"]\s*\)/],
	['set main config', /async function\s+setSelectedConfigAsMain\(\)[\s\S]+validateContentAsMainConfig\(selectedContent\)[\s\S]+restartOrReloadServiceOrThrow\(\s*['"]restart['"]\s*\)/]
]) {
	if (!pattern.test(configSource)) {
		missing.push(`config.js -> ${label} must validate config with clash -t before restarting service`);
	}
}

if (!/dispatchServiceActionsAndWaitOrThrow\(\s*\[\s*['"]stop['"]\s*,\s*['"]disable['"]\s*\]\s*,\s*false\s*\)/.test(configSource)) {
	missing.push('config.js -> stop button must stop then disable service and wait for stopped state');
}

if (!/function\s+isNetworkUpdateBlocked\(\)[\s\S]+view_miclash_guard\.isNetworkUpdateBlocked/.test(configSource)) {
	missing.push('config.js -> subscription/update guard block helper is missing');
}

if (!/function\s+shouldSkipSubscriptionDownload\(\)[\s\S]+view_miclash_guard\.shouldSkipSubscriptionDownload/.test(configSource)) {
	missing.push('config.js -> subscription stopped-service skip policy must be delegated to guard.js');
}

if (!/saveSubscriptionUrl\(url,\s*selectedConfig\)[\s\S]+appState\.serviceRunning\s*=\s*await getServiceStatus\(\)[\s\S]+if\s*\(shouldSkipSubscriptionDownload\(\)\)[\s\S]+return;[\s\S]+ensureMihomoKernelInstalled\(\)[\s\S]+fetchSubscriptionAsYaml\(url,\s*selectedPath\)/.test(configSource)) {
	missing.push('config.js -> subscription URL save must refresh status and skip stopped-service guard before kernel/download work');
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

if (/installMiClashDependencies|ensureCurlAvailable|reinstallCurlDependencies|zlib|libcurl4/.test(packageSource) ||
	!/detectPackageManager/.test(packageSource)) {
	missing.push('package.js -> package helper must only detect manager; install/update work belongs to miclash-update script');
}

if (!/function\s+isNetworkUpdateBlocked\([^)]*\)[\s\S]+isInternetOnlyEnabled\(settings\)\s*&&\s*!serviceRunning/.test(guardSource)) {
	missing.push('guard.js -> guard must block network updates when service is stopped');
}

if (!/function\s+shouldSkipSubscriptionDownload\([^)]*\)[\s\S]+isNetworkUpdateBlocked\(settings,\s*serviceRunning\)/.test(guardSource)) {
	missing.push('guard.js -> subscription URL save must skip downloads through the guard policy while stopped');
}

if (!/async function\s+prepareNetworkUpdate\([^)]*\)[\s\S]+assertNetworkUpdateAllowed\([^)]*\)[\s\S]+repair_network_path/.test(guardSource)) {
	missing.push('guard.js -> running guard updates must repair network path before network access');
}

if (!/result\.code\s*!==\s*0[\s\S]+return\s*{[\s\S]+repaired:\s*false[\s\S]+warning:/.test(guardSource)) {
	missing.push('guard.js -> failed repair_network_path must return a warning instead of throwing while service is running');
}

if (!/function\s+blockedNetworkMessage\(\)[\s\S]+Start the service or disable this option/.test(guardSource)) {
	missing.push('guard.js -> blocked stopped-service guard message must explain the recovery action');
}

if (!/require view\.miclash\.utils/.test(rulesetsSource) ||
	/fs\.write\(/.test(rulesetsSource) ||
	!/view_miclash_utils\.writeFile\(\s*RULESET_PATH \+ fileName/.test(rulesetsSource) ||
	!/view_miclash_utils\.writeFile\(\s*RULESET_PATH \+ FAKEIP_WHITELIST_FILENAME/.test(rulesetsSource)) {
	missing.push('rulesets-model.js -> ruleset and whitelist writes must use chunked utils.writeFile');
}

if (!/async function\s+prepareNetworkUpdate\(\)[\s\S]+result\.warning[\s\S]+continuing update/.test(configSource)) {
	missing.push('config.js -> repair warnings must be shown as non-fatal continuing update notices');
}

if (!/async function\s+prepareNetworkUpdate\(\)[\s\S]+await getServiceStatus\(\)[\s\S]+appState\.serviceRunning\s*=/.test(configSource)) {
	missing.push('config.js -> guarded network updates must refresh live service status before deciding block/repair');
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

if (/view\.miclash\.route|miclash\/(?:settings|rulesets|log)|hash\s*===\s*['"](?:settings|rulesets|logs?)['"]|routeSection|applySection/.test(routeSource + '\n' + configSource)) {
	missing.push('route/config -> settings, logs and rulesets must stay in-page native tabs/actions, not legacy routed top sections');
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

for (const [target, permission] of [
	['/bin/rm', 'exec'],
	['/tmp/mihomo-test', 'remove'],
	['/opt/clash/bin/miclash-update', 'exec']
]) {
	if (!hasAclPermission(target, permission)) {
		missing.push(`ACL regression guard -> ${permission} ${target}`);
	}
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
