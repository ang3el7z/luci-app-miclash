import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const root = 'luci-app-miclash/rootfs/www/luci-static/resources/view/miclash';
const releaseSource = readFileSync(`${root}/release.js`, 'utf8')
	.replace(/^'use strict';\s*/m, '')
	.replace(/^'require [^']+';\s*/gm, '');
const configSource = readFileSync(`${root}/config.js`, 'utf8');

function releaseWith(api) {
	return Function('L', 'view_miclash_api', releaseSource)(
		{ Class: { extend: (value) => value } },
		{ create: () => api }
	);
}

let pendingDestroyed = 0;
const pendingApi = {
	async update_release() {
		return { version: 'v2.0.0', ready: false, readiness: 'assets_pending' };
	},
	destroy() { pendingDestroyed++; }
};
assert.equal(await releaseWith(pendingApi).getLatestMiClashRelease(false), null);
assert.equal(pendingDestroyed, 1);

const readyApi = {
	async update_release() {
		return { version: 'v2.0.0', ready: true, readiness: 'ready' };
	},
	destroy() {}
};
assert.equal((await releaseWith(readyApi).getLatestMiClashRelease(false)).version,
	'v2.0.0');

const releaseHelpers = releaseWith(readyApi);
assert.equal(releaseHelpers.parseVersion('MiClash v2.5.2_rc1', ''), '2.5.2_rc1');
assert.equal(releaseHelpers.normalizeAppVersion('v2.5.2_rc1-r1'), '2.5.2_rc1');
assert.equal(releaseHelpers.compareNumericVersions('2.5.2_rc1', '2.5.2'), -1);
assert.equal(releaseHelpers.compareNumericVersions('2.5.2', '2.5.2_rc1'), 1);
assert.equal(releaseHelpers.compareNumericVersions('2.5.2_rc1', '2.5.2_rc2'), -1);

const mihomoApi = {
	async update_release() { return { version: 'v1.2.3' }; },
	destroy() {}
};
assert.equal((await releaseWith(mihomoApi).getLatestMihomoRelease(false)).version,
	'v1.2.3', 'MiClash readiness must not change Mihomo release behavior');

assert.match(configSource,
	/appState\.releaseMeta\.appVersion = appRelease \? normalizeAppVersion\(appRelease\.version \|\| ''\) : '';/,
	'partial publication must clear the cached toolbar candidate');
const refreshStart = configSource.indexOf('function refreshReleaseMeta(options)');
const refreshEnd = configSource.indexOf('function isRpcReconnectLikeError', refreshStart);
assert.ok(refreshStart >= 0 && refreshEnd > refreshStart);
const refreshSource = configSource.slice(refreshStart, refreshEnd);
assert.doesNotMatch(refreshSource, /update_miclash\s*\(/,
	'a daytime release refresh must remain read-only');
const actionStart = configSource.indexOf('function resolveAppActionState()');
const actionEnd = configSource.indexOf('function resolveKernelActionState()', actionStart);
const actionSource = configSource.slice(actionStart, actionEnd);
const kernelActionEnd = configSource.indexOf('function shouldCheckAppRelease(', actionEnd);
const kernelActionSource = configSource.slice(actionEnd, kernelActionEnd);
assert.match(actionSource, /appState\.releaseMeta\?\.appVersion/);
assert.doesNotMatch(actionSource, /update_release|update_miclash/,
	'toolbar comparison must consume normalized release state only');

if (!String.prototype.format) Object.defineProperty(String.prototype, 'format', {
	configurable: true,
	value(...values) { let index = 0; return this.replace(/%s/g, () => String(values[index++])); }
});
function compareFixtureVersions(left, right) {
	const a = String(left).split('.').map(Number), b = String(right).split('.').map(Number);
	for (let i = 0; i < Math.max(a.length, b.length); i++) {
		if ((a[i] || 0) < (b[i] || 0)) return -1;
		if ((a[i] || 0) > (b[i] || 0)) return 1;
	}
	return 0;
}
function evaluatedAction(local, latest, autoMajorMiclash, channel = 'release') {
	const state = { versions: { app: local }, releaseMeta: { appVersion: latest },
		settings: { autoMajorMiclash, miclashReleaseChannel: channel } };
	return Function('appState', 'normalizeAppVersion', 'compareNumericVersions',
		'normalizeReleaseChannel', '_', `${actionSource}; return resolveAppActionState();`)(
		state, releaseHelpers.normalizeAppVersion,
		releaseHelpers.compareNumericVersions,
		(value) => value === 'prerelease' ? 'prerelease' : 'release', (value) => value);
}
function evaluatedKernelAction(installed, local, latest) {
	const state = {
		kernelStatus: { installed, version: local },
		versions: { clash: local },
		releaseMeta: { kernelVersion: latest }
	};
	return Function('appState', 'normalizeVersion', 'compareNumericVersions', '_',
		`${kernelActionSource}; return resolveKernelActionState();`)(
		state, (value) => String(value || '').replace(/^v/, ''),
		compareFixtureVersions, (value) => value);
}
assert.deepEqual(evaluatedAction('1.0.0', '2.0.0', true), {
	kind: 'update', scheduled: true, targetVersion: '2.0.0', iconName: 'clock',
	className: 'cbi-button-positive',
	title: 'Major update 2.0.0 is scheduled for the night. Click to update now.'
});
assert.deepEqual(evaluatedAction('1.0.0', '1.1.0', false), {
	kind: 'update', targetVersion: '1.1.0', iconName: 'download',
	className: 'cbi-button-positive', title: 'Update MiClash to 1.1.0'
});
assert.deepEqual(evaluatedAction('1.1.0', '1.1.0', false), {
	kind: 'reinstall', targetVersion: '1.1.0', iconName: 'refresh',
	className: 'cbi-button-neutral', title: 'Reinstall MiClash 1.1.0'
});
assert.deepEqual(evaluatedAction('1.2.0', '1.1.0', false), {
	kind: 'downgrade', targetVersion: '1.1.0', iconName: 'download',
	className: 'cbi-button-negative', title: 'Downgrade MiClash to 1.1.0'
});
assert.equal(evaluatedAction('1.0.0', '2.0.0', false).scheduled, undefined);
assert.equal(evaluatedAction('1.0.0', '1.1.0', true).scheduled, undefined);
assert.equal(evaluatedAction('1.0.0', '2.0.0', true, 'prerelease').scheduled, undefined);
assert.equal(evaluatedAction('2.5.2_rc1-r1', 'v2.5.2', false).title,
	'Update MiClash to 2.5.2');
assert.deepEqual(evaluatedKernelAction(true, '1.0.0', '1.1.0'), {
	kind: 'update', targetVersion: '1.1.0', iconName: 'download',
	className: 'cbi-button-positive', title: 'Update Mihomo to 1.1.0'
});
assert.deepEqual(evaluatedKernelAction(true, '1.1.0', '1.1.0'), {
	kind: 'reinstall', targetVersion: '1.1.0', iconName: 'refresh',
	className: 'cbi-button-neutral', title: 'Reinstall Mihomo 1.1.0'
});
assert.deepEqual(evaluatedKernelAction(true, '1.2.0', '1.1.0'), {
	kind: 'downgrade', targetVersion: '1.1.0', iconName: 'download',
	className: 'cbi-button-negative', title: 'Downgrade Mihomo to 1.1.0'
});
assert.equal(evaluatedKernelAction(false, '', '1.1.0').targetVersion, undefined);
assert.match(configSource, /data-target-version/,
	'scheduled-night indicator must expose its target version');
assert.match(configSource,
	/configApi\.update_miclash\([^;]+request\.action,\s*request\.version\)/s,
	'LuCI must pass the explicit MiClash action and exact target version');
assert.match(configSource,
	/configApi\.update_mihomo\([^;]+request\.action,\s*request\.version\)/s,
	'LuCI must pass the explicit Mihomo action and exact target version');
const kernelModalStart = configSource.indexOf('async function openKernelModal()');
const kernelModalEnd = configSource.indexOf('async function getMihomoStatus()', kernelModalStart);
const kernelModalSource = configSource.slice(kernelModalStart, kernelModalEnd);
assert.match(kernelModalSource,
	/downloadMihomoKernel\(\s*asset\.browser_download_url, release\.version, arch,\s*actionKind\)/s,
	'the Mihomo modal must preserve its explicit install/update/reinstall/downgrade action');
assert.match(configSource,
	/classList\.remove\('cbi-button-positive', 'cbi-button-neutral', 'cbi-button-negative'\)/,
	'header refresh must replace themed positive, neutral and negative action colors');

console.log('release readiness UI contract passed');
