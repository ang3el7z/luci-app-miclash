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

const saveHandlerStart = config.indexOf("const saveUpdateBtn = pageRoot.querySelector('#sbox-save-update-sub')");
const saveHandlerEnd = config.indexOf("const validateBtn = pageRoot.querySelector('#sbox-validate')", saveHandlerStart);
const saveHandler = saveHandlerStart >= 0 && saveHandlerEnd > saveHandlerStart
	? config.slice(saveHandlerStart, saveHandlerEnd)
	: '';

check(saveHandler, 'Config view must keep the subscription save/update handler.');
check(saveHandler.includes('applySubscriptionOnRouter('),
	'Subscription save/update handler must apply subscriptions through the router-side helper.');
check(!saveHandler.includes('fetchSubscriptionAsYaml('),
	'Subscription save/update handler must not read the downloaded YAML back into LuCI JS.');
check(!saveHandler.includes('testConfigContent(downloaded, true'),
	'Subscription save/update handler must not write large subscription content through LuCI/RPC.');
check(!saveHandler.includes('editor.setValue(downloaded'),
	'Subscription save/update handler must not push large downloaded YAML into the browser editor.');

check(subscription.includes('async function applySubscriptionOnRouter('),
	'Subscription module must expose a router-side apply wrapper.');
check(subscription.includes("fs.exec('/opt/clash/bin/miclash-subscription'"),
	'Subscription module must execute /opt/clash/bin/miclash-subscription.');

check(existsSync(files.helper), 'Router-side subscription helper must be installed in rootfs.');
check(helper.includes('download_subscription()'),
	'Router-side helper must own the subscription download step.');
check(helper.includes('transform_proxy_mode()'),
	'Router-side helper must transform MiClash proxy-mode fields without LuCI content writes.');
check(helper.includes('validate_config()'),
	'Router-side helper must validate the candidate config before replacing the target.');
check(helper.includes('mv "$APPLY_PATH" "$TARGET_PATH"'),
	'Router-side helper must atomically replace the selected config after validation.');
check(helper.includes('TARGET_NAME=') && helper.includes('config2.yaml') && helper.includes('config3.yaml'),
	'Router-side helper must restrict writes to the supported MiClash config profiles.');

check(makefile.includes('rootfs/opt/clash/bin/miclash-subscription'),
	'Package install must include the router-side subscription helper.');
check(acl.includes('"/opt/clash/bin/miclash-subscription": [ "read", "stat", "exec" ]'),
	'LuCI ACL must allow executing the router-side subscription helper.');

if (failed) process.exit(1);
console.log('subscription helper flow check passed');
