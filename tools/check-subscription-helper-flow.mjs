import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';

const files = {
	config: 'luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/config.js',
	subscription: 'luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/subscription.js',
	helper: 'luci-app-miclash/rootfs/opt/clash/bin/miclash-subscription',
	acl: 'luci-app-miclash/rootfs/usr/share/rpcd/acl.d/luci-app-miclash.json',
	makefile: 'luci-app-miclash/Makefile'
};

const config = readFileSync(files.config, 'utf8');
const subscription = readFileSync(files.subscription, 'utf8');
const acl = readFileSync(files.acl, 'utf8');
const makefile = readFileSync(files.makefile, 'utf8');
const helper = existsSync(files.helper) ? readFileSync(files.helper, 'utf8') : '';

let failed = false;

function check(condition, message) {
	if (!condition) {
		console.error(message);
		failed = true;
	}
}

function shellPath(path) {
	const normalized = String(path).replace(/\\/g, '/');
	if (process.platform !== 'win32') return normalized;
	return normalized.replace(/^([A-Za-z]):/, (_, drive) => '/' + drive.toLowerCase());
}

function writeExecutable(path, content) {
	writeFileSync(path, content);
	chmodSync(path, 0o755);
}

function runSavedSettingsFixture() {
	const shellCandidates = process.platform === 'win32'
		? ['C:/Program Files/Git/bin/sh.exe', 'C:/Program Files/Git/usr/bin/sh.exe']
		: ['/bin/sh'];
	const shell = shellCandidates.find((candidate) => existsSync(candidate));
	if (!shell) return { code: 127, stderr: 'No POSIX shell found' };

	const dir = mkdtempSync(join(tmpdir(), 'miclash-subscription-test-'));
	try {
		const base = join(dir, 'clash');
		const bin = join(base, 'bin');
		const settings = join(base, 'settings');
		const curl = join(bin, 'curl');
		const clash = join(bin, 'clash');
		const curlLog = join(dir, 'curl.log');
		const clashLog = join(dir, 'clash.log');
		mkdirSync(bin, { recursive: true });
		writeFileSync(settings, [
			'SUBSCRIPTION_URL_CONFIG_YAML=https://provider.test/api/sub/token',
			'PROXY_MODE=tproxy',
			'TUN_STACK=system',
			'HWID_USER_AGENT=MiClash-Test',
			'HWID_DEVICE_OS=OpenWrt',
			'ENABLE_HWID=false',
			''
		].join('\n'));
		writeExecutable(curl, `#!/bin/sh
headers=""
out=""
url=""
while [ "$#" -gt 0 ]; do
	case "$1" in
		-D) headers="$2"; shift 2 ;;
		-o) out="$2"; shift 2 ;;
		http://*|https://*) url="$1"; shift ;;
		*) shift ;;
	esac
done
printf '%s\\n' "$url" >> "${shellPath(curlLog)}"
printf 'HTTP/2 200\\n' > "$headers"
case "$url" in
	*/mihomo)
		printf 'mode: rule\\nproxies:\\n  - name: test\\n    type: direct\\nrules:\\n  - MATCH,DIRECT\\n' > "$out"
		;;
	*)
		printf 'Profile-Update-Interval: 3\\n' >> "$headers"
		printf 'QUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFB\\n' > "$out"
		;;
esac
`);
		writeExecutable(clash, `#!/bin/sh
printf '%s\\n' "$*" >> "${shellPath(clashLog)}"
candidate=""
while [ "$#" -gt 0 ]; do
	case "$1" in -f) candidate="$2"; shift 2 ;; *) shift ;; esac
done
grep -q '^proxies:' "$candidate"
`);

		const script = `MICLASH_BASE_DIR="${shellPath(base)}" \\
MICLASH_CLASH_DATA_DIR="${shellPath(base)}" \\
MICLASH_CLASH_BIN="${shellPath(clash)}" \\
MICLASH_SETTINGS_FILE="${shellPath(settings)}" \\
MICLASH_CURL_BIN="${shellPath(curl)}" \\
sh "${shellPath(files.helper)}" apply-saved-main
`;
		const result = spawnSync(shell, ['-s'], { input: script, encoding: 'utf8' });
		return {
			code: result.status,
			stdout: result.stdout || '',
			stderr: result.stderr || result.error?.message || '',
			config: existsSync(join(base, 'config.yaml')) ? readFileSync(join(base, 'config.yaml'), 'utf8') : '',
			curlLog: existsSync(curlLog) ? readFileSync(curlLog, 'utf8') : '',
			clashLog: existsSync(clashLog) ? readFileSync(clashLog, 'utf8') : ''
		};
	} finally {
		rmSync(dir, { recursive: true, force: true });
	}
}

const updateHandlerStart = config.indexOf("const updateUrlBtn = pageRoot.querySelector('#sbox-update-sub')");
const updateHandlerEnd = config.indexOf("const clearUrlBtn = pageRoot.querySelector('#sbox-clear-sub-url')", updateHandlerStart);
const updateHandler = updateHandlerStart >= 0 && updateHandlerEnd > updateHandlerStart
	? config.slice(updateHandlerStart, updateHandlerEnd)
	: '';
const intervalProbeStart = config.indexOf('async function probeAutoUpdateIntervalFromSubscription()');
const intervalProbeEnd = config.indexOf('async function testConfigContent', intervalProbeStart);
const intervalProbe = intervalProbeStart >= 0 && intervalProbeEnd > intervalProbeStart
	? config.slice(intervalProbeStart, intervalProbeEnd)
	: '';

check(updateHandler, 'Config view must keep the subscription update handler.');
check(updateHandler.includes('applySubscriptionOnRouter('),
	'Subscription update handler must apply subscriptions through the router-side helper.');
check(!updateHandler.includes('fetchSubscriptionAsYaml('),
	'Subscription update handler must not read downloaded YAML back into LuCI JS.');
check(!updateHandler.includes('testConfigContent(downloaded, true'),
	'Subscription update handler must not write large subscription content through LuCI/RPC.');
check(!updateHandler.includes('editor.setValue(downloaded'),
	'Subscription update handler must not push large downloaded YAML into the browser editor.');
check(updateHandler.includes('const freshConfig = await readConfigFileByName(selectedConfig)') &&
	updateHandler.includes("appState.configContent = String(freshConfig || '')") &&
	updateHandler.includes('editor.setValue(appState.configContent, -1)'),
	'Subscription update handler must refresh Ace from the selected config after the router-side apply.');
check(updateHandler.includes('applySubscriptionProfileUpdateInterval(appliedInfo.profileUpdateIntervalHours)'),
	'Subscription update handler must preserve Profile-Update-Interval from the router-side helper.');
check(intervalProbe.includes('probeSubscriptionUpdateIntervalOnRouter('),
	'Auto-update interval probe must read subscription headers through the router-side helper.');
check(!intervalProbe.includes('downloadSubscriptionWithProfile('),
	'Auto-update interval probe must not read subscription payload back into LuCI JS.');

check(subscription.includes('async function applySubscriptionOnRouter('),
	'Subscription module must expose a router-side apply wrapper.');
check(subscription.includes('async function probeSubscriptionUpdateIntervalOnRouter('),
	'Subscription module must expose a router-side interval probe wrapper.');
check(subscription.includes("fs.exec('/opt/clash/bin/miclash-subscription'"),
	'Subscription module must execute /opt/clash/bin/miclash-subscription.');
check(subscription.includes('parseKeyValueStatus('),
	'Subscription module must parse helper key=value status output.');

check(existsSync(files.helper), 'Router-side subscription helper must be installed in rootfs.');
check(helper.includes('download_subscription()'),
	'Router-side helper must own the subscription download step.');
check(helper.includes('raw_github_cdn_fallback_url()') &&
	helper.includes('raw.githubusercontent.com') &&
	helper.includes('cdn.jsdelivr.net/gh/'),
	'Router-side helper must derive a jsDelivr fallback for raw.githubusercontent.com subscriptions.');
check(helper.includes('raw_github_cdn_purge_url()') &&
	helper.includes('purge.jsdelivr.net/gh/'),
	'Router-side helper must derive a jsDelivr purge URL for raw.githubusercontent.com subscriptions.');
check(helper.includes('raw_github_fallback="$(raw_github_cdn_fallback_url "$URL"') &&
	helper.includes('purge_raw_github_cdn_fallback "$URL"') &&
	helper.includes('download_subscription "$raw_github_fallback" "$TMP_DOWNLOAD" "github-raw-cdn"'),
	'Router-side helper must purge and then try the raw GitHub CDN fallback when the primary raw.githubusercontent.com download fails.');
check(helper.includes('transform_proxy_mode()'),
	'Router-side helper must transform MiClash proxy-mode fields without LuCI content writes.');
check(helper.includes('validate_config()'),
	'Router-side helper must validate the candidate config before replacing the target.');
check(helper.includes('read_profile_update_interval_hours()') &&
	helper.includes("printf 'profileUpdateIntervalHours=%s\\n'"),
	'Router-side helper must return Profile-Update-Interval without sending YAML to LuCI.');
check(helper.includes('probe_interval()') && helper.includes('probe-interval)'),
	'Router-side helper must support interval probing without replacing config.');
check(helper.includes('mv "$APPLY_PATH" "$TARGET_PATH"'),
	'Router-side helper must replace the selected config only after validation.');
check(helper.includes('TARGET_NAME=') && helper.includes('config2.yaml') && helper.includes('config3.yaml'),
	'Router-side helper must restrict writes to the supported MiClash config profiles.');
check(helper.includes('MICLASH_BASE_DIR') &&
	helper.includes('MICLASH_CLASH_DATA_DIR') &&
	helper.includes('MICLASH_CLASH_BIN') &&
	helper.includes('MICLASH_SETTINGS_FILE'),
	'Router-side helper paths must be overridable for isolated saved-settings tests.');
check(helper.includes('apply-saved-main)') &&
	helper.includes('load_saved_main_options()') &&
	helper.includes('SUBSCRIPTION_URL_CONFIG_YAML'),
	'Router-side helper must apply the saved Main subscription through the shared pipeline.');
check(helper.includes('derive_remnawave_fallback()') &&
	helper.includes('FALLBACK_URL="$(derive_remnawave_fallback "$URL")"'),
	'Saved Main updates must derive and try the Remnawave /mihomo path.');
check(helper.includes('[ -x "$CLASH_BIN" ] || fail "Install the Mihomo kernel first."'),
	'Subscription apply must fail with an actionable kernel preflight before downloading.');
const applyStart = helper.indexOf('\napply_subscription()');
const applyEnd = helper.indexOf('\nprobe_interval()', applyStart);
const applyBlock = applyStart >= 0 && applyEnd > applyStart ? helper.slice(applyStart, applyEnd) : '';
check(applyBlock.indexOf('[ -x "$CLASH_BIN" ]') >= 0 &&
	applyBlock.indexOf('[ -x "$CLASH_BIN" ]') < applyBlock.indexOf('download_primary_or_fallback'),
	'Subscription apply must reject a missing kernel before making any subscription request.');

check(makefile.includes('rootfs/opt/clash/bin/miclash-subscription'),
	'Package install must include the router-side subscription helper.');
check(acl.includes('"/opt/clash/bin/miclash-subscription": [ "read", "stat", "exec" ]'),
	'LuCI ACL read permissions must allow executing the router-side subscription helper.');
check(acl.includes('"/opt/clash/bin/miclash-subscription": [ "exec" ]'),
	'LuCI ACL write permissions must allow executing the router-side subscription helper.');

const savedSettingsResult = runSavedSettingsFixture();
check(savedSettingsResult.code === 0,
	`Saved Main subscription fixture must succeed: ${savedSettingsResult.stderr || savedSettingsResult.stdout}`);
check(savedSettingsResult.curlLog.includes('https://provider.test/api/sub/token\n') &&
	savedSettingsResult.curlLog.includes('https://provider.test/api/sub/token/mihomo\n'),
	'Saved Main subscription must request the original URL and derived /mihomo fallback.');
check(savedSettingsResult.clashLog.includes('-f') &&
	savedSettingsResult.config.includes('proxies:') &&
	savedSettingsResult.config.includes('tproxy-port: 7894'),
	'Saved Main subscription must validate and atomically install the transformed YAML candidate.');
check(savedSettingsResult.stdout.includes('ok=1') &&
	savedSettingsResult.stdout.includes('mode=remnawave-client-path') &&
	savedSettingsResult.stdout.includes('target=config.yaml') &&
	savedSettingsResult.stdout.includes('profileUpdateIntervalHours=3') &&
	savedSettingsResult.stdout.includes('message=Subscription downloaded and applied.'),
	'Saved Main subscription must return neutral key/value result fields and preserve the primary interval header.');

if (failed) process.exit(1);
console.log('subscription helper flow check passed');
