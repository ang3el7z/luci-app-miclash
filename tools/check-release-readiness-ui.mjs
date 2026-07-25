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
assert.match(actionSource, /appState\.releaseMeta\?\.appVersion/);
assert.doesNotMatch(actionSource, /update_release|update_miclash/,
	'toolbar comparison must consume normalized release state only');

if (!String.prototype.format) Object.defineProperty(String.prototype, 'format', {
	configurable: true,
	value(...values) { let index = 0; return this.replace(/%s/g, () => String(values[index++])); }
});
function evaluatedAction(local, latest, autoMajorMiclash, channel = 'release') {
	const state = { versions: { app: local }, releaseMeta: { appVersion: latest },
		settings: { autoMajorMiclash, miclashReleaseChannel: channel } };
	return Function('appState', 'normalizeAppVersion', 'compareNumericVersions',
		'normalizeReleaseChannel', '_', `${actionSource}; return resolveAppActionState();`)(
		state, (value) => String(value || '').replace(/^v/, ''),
		(left, right) => {
			const a = String(left).split('.').map(Number), b = String(right).split('.').map(Number);
			for (let i = 0; i < Math.max(a.length, b.length); i++) {
				if ((a[i] || 0) < (b[i] || 0)) return -1;
				if ((a[i] || 0) > (b[i] || 0)) return 1;
			}
			return 0;
		}, (value) => value === 'prerelease' ? 'prerelease' : 'release', (value) => value);
}
assert.deepEqual(evaluatedAction('1.0.0', '2.0.0', true), {
	kind: 'update', scheduled: true, targetVersion: '2.0.0', iconName: 'clock',
	className: 'cbi-button-positive',
	title: 'Major update 2.0.0 is scheduled for the night. Click to update now.'
});
assert.equal(evaluatedAction('1.0.0', '2.0.0', false).scheduled, undefined);
assert.equal(evaluatedAction('1.0.0', '1.1.0', true).scheduled, undefined);
assert.equal(evaluatedAction('1.0.0', '2.0.0', true, 'prerelease').scheduled, undefined);
assert.match(configSource, /data-target-version/,
	'scheduled-night indicator must expose its target version');

console.log('release readiness UI contract passed');
