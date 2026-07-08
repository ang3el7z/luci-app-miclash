import { existsSync, readFileSync } from 'node:fs';

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
check(helper.includes('raw_github_fallback="$(raw_github_cdn_fallback_url "$URL"') &&
	helper.includes('download_subscription "$raw_github_fallback" "$TMP_DOWNLOAD" "github-raw-cdn"'),
	'Router-side helper must try the raw GitHub CDN fallback when the primary raw.githubusercontent.com download fails.');
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

check(makefile.includes('rootfs/opt/clash/bin/miclash-subscription'),
	'Package install must include the router-side subscription helper.');
check(acl.includes('"/opt/clash/bin/miclash-subscription": [ "read", "stat", "exec" ]'),
	'LuCI ACL read permissions must allow executing the router-side subscription helper.');
check(acl.includes('"/opt/clash/bin/miclash-subscription": [ "exec" ]'),
	'LuCI ACL write permissions must allow executing the router-side subscription helper.');

if (failed) process.exit(1);
console.log('subscription helper flow check passed');
