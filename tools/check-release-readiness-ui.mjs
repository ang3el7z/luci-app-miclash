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
const refreshStart = configSource.indexOf('async function refreshReleaseMeta(options)');
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

console.log('release readiness UI contract passed');
