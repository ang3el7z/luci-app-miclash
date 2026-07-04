import fs from 'node:fs';
import path from 'node:path';

const root = process.cwd();
const required = [
	'luci-app-miclash/Makefile',
	'luci-app-miclash/rootfs/etc/init.d/clash',
	'luci-app-miclash/rootfs/etc/hotplug.d/iface/40-clash',
	'luci-app-miclash/rootfs/etc/hotplug.d/net/99-clash-tun',
	'luci-app-miclash/rootfs/opt/clash/bin/clash-rules',
	'luci-app-miclash/rootfs/opt/clash/bin/miclash-update',
	'luci-app-miclash/rootfs/opt/clash/config.yaml',
	'luci-app-miclash/rootfs/po/ru/miclash.po',
	'luci-app-miclash/rootfs/po/zh-cn/miclash.po',
	'luci-app-miclash/rootfs/usr/share/luci/menu.d/luci-app-miclash.json',
	'luci-app-miclash/rootfs/usr/share/rpcd/acl.d/luci-app-miclash.json',
	'luci-app-miclash/rootfs/etc/apk/protected_paths.d/miclash.list',
	'luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/config.js',
	'luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/settings.js',
	'luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/rulesets.js',
	'luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/log.js'
];

const missing = required.filter((rel) => !fs.existsSync(path.join(root, rel)));

const makefile = fs.readFileSync(path.join(root, 'luci-app-miclash/Makefile'), 'utf8');
const runtimeDependencyFiles = [
	'install-miclash.sh',
	'luci-app-miclash/rootfs/opt/clash/bin/miclash-update',
	'luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/package.js',
	'README.md'
];
const expectedInstallSnippets = [
	'./rootfs/etc/init.d/clash',
	'./rootfs/etc/hotplug.d/iface/40-clash',
	'./rootfs/etc/hotplug.d/net/99-clash-tun',
	'./rootfs/opt/clash/bin/clash-rules',
	'./rootfs/opt/clash/bin/miclash-update',
	'./rootfs/opt/clash/config.yaml',
	'./rootfs/opt/clash/ui/*',
	'./rootfs/usr/share/luci/menu.d/luci-app-miclash.json',
	'./rootfs/usr/share/rpcd/acl.d/luci-app-miclash.json',
	'./rootfs/www/luci-static/resources/view/miclash/*',
	'./rootfs/etc/apk/protected_paths.d/miclash.list'
];

for (const snippet of expectedInstallSnippets) {
	if (!makefile.includes(snippet)) missing.push(`Makefile install snippet ${snippet}`);
}

if (!/^LUCI_DEPENDS:=.*\+zlib\b.*\+libcurl\b.*\+curl\b/m.test(makefile)) {
	missing.push('Makefile LUCI_DEPENDS must use OpenWrt SDK package names +zlib +libcurl +curl');
}

if (/^LUCI_DEPENDS:=.*\+libcurl4\b/m.test(makefile)) {
	missing.push('Makefile LUCI_DEPENDS must not use runtime package name +libcurl4');
}

for (const rel of runtimeDependencyFiles) {
	const content = fs.readFileSync(path.join(root, rel), 'utf8');
	if (!content.includes('zlib') || !content.includes('libcurl4') || !content.includes('curl')) {
		missing.push(`${rel} must keep runtime dependency names zlib libcurl4 curl`);
	}
}

const expectedLocaleSnippets = [
	'./rootfs/po/ru/miclash.po',
	'$(PKG_BUILD_DIR)/po/ru/miclash.lmo',
	'miclash.ru.lmo',
	'./rootfs/po/zh-cn/miclash.po',
	'$(PKG_BUILD_DIR)/po/zh-cn/miclash.lmo',
	'miclash.zh-cn.lmo'
];

for (const snippet of expectedLocaleSnippets) {
	if (!makefile.includes(snippet)) missing.push(`Makefile locale snippet ${snippet}`);
}

const zhCnPo = fs.readFileSync(path.join(root, 'luci-app-miclash/rootfs/po/zh-cn/miclash.po'), 'utf8');
if (!zhCnPo.includes('Language: zh-cn\\n')) {
	missing.push('zh-cn locale must declare Language: zh-cn');
}
if (/\bSSClash\b/.test(zhCnPo) || /\bssclash\b/.test(zhCnPo)) {
	missing.push('zh-cn locale must use MiClash naming');
}

const protectedPaths = fs
	.readFileSync(path.join(root, 'luci-app-miclash/rootfs/etc/apk/protected_paths.d/miclash.list'), 'utf8')
	.split(/\r?\n/)
	.map((line) => line.trim())
	.filter(Boolean);

const expectedProtectedPaths = [
	'+opt/clash/config.yaml',
	'+opt/clash/lst',
	'+opt/clash/lst/*'
];

for (const entry of expectedProtectedPaths) {
	if (!protectedPaths.includes(entry)) missing.push(`protected_paths ${entry}`);
}

const viewDir = path.join(root, 'luci-app-miclash/rootfs/www/luci-static/resources/view/miclash');
const viewFiles = fs.readdirSync(viewDir).filter((name) => name.endsWith('.js'));
if (viewFiles.length < 4) {
	missing.push(`view modules count ${viewFiles.length}`);
}

if (missing.length) {
	console.error('Package layout verification failed:');
	for (const item of missing) console.error(`- ${item}`);
	process.exit(1);
}

console.log(`Package layout verified: ${required.length} required paths, ${viewFiles.length} view modules`);
