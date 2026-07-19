import fs from 'node:fs';

const source = fs.readFileSync(
	new URL('../luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/config.js', import.meta.url),
	'utf8'
);

function requirePattern(pattern, message) {
	if (!pattern.test(source)) throw new Error(message);
}

const loadBody = source.match(/load:\s*function\(\)\s*\{([\s\S]*?)\n\t\},\n\n\trender:/)?.[1] || '';
if (!loadBody) throw new Error('Unable to locate the LuCI load() block.');
if (/readConfigFileByName|readSubscriptionUrl/.test(loadBody))
	throw new Error('YAML and subscription reads must not block the initial LuCI page load.');
if (/getVersions|getMihomoStatus|detectCurrentProxyMode/.test(loadBody))
	throw new Error('Initial runtime hydration must not duplicate system or settings RPC calls.');

requirePattern(/render:\s*function\(data\)/, 'render() must return the page synchronously.');
requirePattern(/async function hydrateConfigWorkspace\(/, 'Missing progressive config hydration.');
requirePattern(/beginPageHydration\(/, 'Missing page hydration scheduler.');
requirePattern(/function beginPageHydration\(generation\)\s*\{\s*return Promise\.resolve\(\)/,
	'Page hydration must return its readiness promise.');
const renderBody = source.match(/render:\s*function\(data\)\s*\{([\s\S]*?)\n\t\treturn pageRoot;/)?.[1] || '';
if (!renderBody) throw new Error('Unable to locate the LuCI render() body.');
const hydrationStart = renderBody.indexOf('beginPageHydration(generation).finally');
const forcedReleaseCalls = [ ...renderBody.matchAll(/refreshReleaseMeta\(\{ force: true \}\)/g) ];
if (forcedReleaseCalls.length !== 1 || forcedReleaseCalls[0].index < hydrationStart)
	throw new Error('Forced release checks must not compete with initial config hydration.');
if (!/beginPageHydration\(generation\)\.finally\(\(\) => \{[\s\S]*?generation === pageGeneration[\s\S]*?!document\.hidden[\s\S]*?refreshReleaseMeta\(\{ force: true \}\)/.test(renderBody))
	throw new Error('Forced release checks must start only after config hydration settles.');
requirePattern(/loadingHtml\(\{\s*kind:\s*'editor'/, 'The config editor must start with a shimmer.');
requirePattern(/function setConfigWorkspaceReady\(/, 'Missing config-control readiness gate.');
requirePattern(/configReady:\s*false/, 'The config workspace must be unavailable before hydration succeeds.');
requirePattern(/desired:\s*snapshot\?\.desired\s*\|\|\s*null/, 'The service adapter must preserve desired state for Guard rendering.');
requirePattern(/state\.desired\?\.guard/, 'Service polling must keep the Guard header synchronized.');

console.log('Progressive MiClash UI checks passed.');
