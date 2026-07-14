import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import path from 'node:path';

const root = process.cwd();
const packagePath = path.join(root, 'luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/package.js');
const compatPath = path.join(root, 'luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/config-compat.js');
const menuPath = path.join(root, 'luci-app-miclash/rootfs/usr/share/luci/menu.d/luci-app-miclash.json');

function loadLuciModule(source, globals) {
	const names = Object.keys(globals);
	const values = Object.values(globals);
	return Function(...names, source)(...values);
}

const packageSource = readFileSync(packagePath, 'utf8');

async function detectWith(exitCodes) {
	const packageModule = loadLuciModule(packageSource, {
		L: { Class: { extend: (value) => value } },
		fs: {
			exec: async (bin) => ({ code: exitCodes[bin] ?? 127 }),
			read: async () => ''
		},
		_: (value) => value
	});
	return packageModule.detectPackageManager();
}

assert.deepEqual(
	await detectWith({ '/bin/opkg': 0 }),
	{ type: 'opkg', bin: '/bin/opkg' },
	'detector must skip failed apk probes and select the working opkg binary'
);
assert.deepEqual(
	await detectWith({ '/usr/bin/apk': 0, '/bin/opkg': 0 }),
	{ type: 'apk', bin: '/usr/bin/apk' },
	'detector must prefer a working apk binary on OpenWrt 25'
);

const compatSource = readFileSync(compatPath, 'utf8');

async function loadVersions(manager, result, initialVersion = 'unknown') {
	const calls = [];
	const baseView = {
		load: async () => [null, null, null, null, { app: initialVersion, clash: '1.2.3' }]
	};
	const compatView = loadLuciModule(compatSource, {
		view_miclash_config: baseView,
		view_miclash_package: {
			detectPackageManager: async () => manager
		},
		view_miclash_release: {
			parsePackageVersion: (raw, packageName) => {
				const apk = String(raw).match(new RegExp('^' + packageName + '-(.+)$', 'm'));
				if (apk) return apk[1];
				const opkg = String(raw).match(new RegExp('^' + packageName + '\\s+-\\s+([^\\s]+)', 'm'));
				return opkg ? opkg[1] : '';
			},
			normalizeAppVersion: (value) => String(value).match(/^\d+(?:\.\d+)+/)?.[0] || ''
		},
		fs: {
			exec: async (bin, args) => {
				calls.push([bin, args]);
				return result;
			}
		}
	});
	return { data: await compatView.load(), calls };
}

const apk = await loadVersions(
	{ type: 'apk', bin: '/usr/bin/apk' },
	{ code: 0, stdout: 'luci-app-miclash-0.9.2-r1\n', stderr: '' }
);
assert.equal(apk.data[4].app, '0.9.2');
assert.equal(apk.data[4].clash, '1.2.3');
assert.deepEqual(apk.calls, [['/usr/bin/apk', ['info', '-v', 'luci-app-miclash']]]);

const opkg = await loadVersions(
	{ type: 'opkg', bin: '/bin/opkg' },
	{ code: 0, stdout: 'luci-app-miclash - 0.9.2-r1\n', stderr: '' }
);
assert.equal(opkg.data[4].app, '0.9.2');
assert.deepEqual(opkg.calls, [['/bin/opkg', ['list-installed', 'luci-app-miclash']]]);

const known = await loadVersions(
	{ type: 'apk', bin: '/usr/bin/apk' },
	{ code: 0, stdout: 'luci-app-miclash-9.9.9-r1\n', stderr: '' },
	'0.9.1'
);
assert.equal(known.data[4].app, '0.9.1', 'an already detected version must be preserved');
assert.deepEqual(known.calls, [], 'the compatibility probe must not run when the base view already found a version');

const failed = await loadVersions(
	{ type: 'apk', bin: '/usr/bin/apk' },
	{ code: 1, stdout: '', stderr: 'not installed' }
);
assert.equal(failed.data[4].app, 'unknown', 'a failed compatibility probe must preserve the original result');

const menu = JSON.parse(readFileSync(menuPath, 'utf8'));
assert.equal(menu['admin/services/miclash'].action.path, 'miclash/config-compat');

console.log('package version compatibility checks passed');
