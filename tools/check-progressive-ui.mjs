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
if (/loadOperationalSettings|system_info/.test(loadBody))
	throw new Error('The initial LuCI shell must derive settings from status and defer system metadata.');
if (/readMiClashServiceState|getNetworkSnapshot|operationalSettingsFromTyped/.test(loadBody))
	throw new Error('The LuCI load hook must not block the initial shell on router RPCs.');

requirePattern(/render:\s*function\(data\)/, 'render() must return the page synchronously.');
requirePattern(/async function hydrateConfigWorkspace\(/, 'Missing progressive config hydration.');
const configHydration = source.match(/async function hydrateConfigWorkspace\(generation\)\s*\{([\s\S]*?)\n\}/)?.[1] || '';
if ((configHydration.match(/readConfigFileByName\(MAIN_CONFIG_NAME\)/g) || []).length !== 1)
	throw new Error('Config hydration must read the active YAML only once.');
requirePattern(/async function hydrateInitialState\(generation\)/,
	'Fresh service and network state must hydrate independently after render.');
requirePattern(/api\.overview\(\)/,
	'Initial service hydration must use the compact overview RPC.');
requirePattern(/beginPageHydration\(/, 'Missing page hydration scheduler.');
requirePattern(/hydrateSystemMetadata\(generation\)/,
	'System versions must hydrate after the initial page shell is rendered.');
requirePattern(/systemMetadataReady:\s*false/,
	'Header versions must start in a loading state.');
requirePattern(/sbox-version-loading/,
	'Header versions must render compact shimmers while system metadata loads.');
requirePattern(/appState\.systemMetadataReady\s*=\s*true[\s\S]*updateHeaderAndControlDom\(\)/,
	'Both version shimmers must resolve only after valid system metadata arrives.');
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
requirePattern(/guardObservedState:\s*'unknown'/,
	'The Guard header must start without claiming an unverified state.');
requirePattern(/observedGuard:\s*observed\?\.guard\s*\|\|\s*\{\s*state:\s*'unknown'\s*\}/,
	'The compact overview response must carry the same observed Guard component state used by diagnostics.');
requirePattern(/state\.observedGuard\?\.state/,
	'Service polling must retain the observed Guard component state.');
requirePattern(/sbox-guard-error[\s\S]*sbox-guard-unknown/,
	'The header must distinguish a failed Guard verification from an unknown state.');
requirePattern(/hydrateInitialState\(generation\)/,
	'Initial state hydration must start after the page shell exists.');
requirePattern(/managementOwner\.setActive\(name === 'settings'\)/,
	'Only the visible Settings tab may poll its panels.');
requirePattern(/diagnosticsOwner\.setActive\(name === 'settings'\)/,
	'Diagnostics polling must follow Settings tab visibility.');
requirePattern(/startControlPolling\(\)[\s\S]*if \(document\.hidden \|\| controlPollBusy\) return/,
	'Hidden LuCI pages must not issue recurring service overview polls.');
requirePattern(/name === 'logs'[\s\S]*refreshLogs\(\)/,
	'Returning to Logs must request one immediate silent refresh.');
const serviceResumeBody = source.match(/async function resumeMiClashServiceJobStatus\(\)\s*\{([\s\S]*?)\n\}/)?.[1] || '';
if (!serviceResumeBody) throw new Error('Unable to locate service-operation resume logic.');
if (/readMiClashServiceState\(true\)|api\.status\(\)/.test(serviceResumeBody))
	throw new Error('Ordinary page entry must not scan full operation history to resume a service job.');
requirePattern(/resumeMiClashServiceJobStatus\(\)[\s\S]*getStoredOperationToken\('service'\)/,
	'Only a service operation started by this page session may be resumed.');

console.log('Progressive MiClash UI checks passed.');
