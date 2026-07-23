import fs from 'node:fs';
import path from 'node:path';

const root = path.resolve(import.meta.dirname, '..');
const pkg = path.join(root, 'luci-app-miclash');
const makefile = fs.readFileSync(path.join(pkg, 'Makefile'), 'utf8');
const runtime = fs.readFileSync(path.join(pkg, 'rootfs/usr/share/miclash/runtime.uc'), 'utf8');
const clash = fs.readFileSync(path.join(pkg, 'rootfs/etc/init.d/clash'), 'utf8');
const network = fs.readFileSync(path.join(pkg, 'rootfs/usr/share/miclash/network.uc'), 'utf8');
const reconcile = fs.readFileSync(path.join(pkg, 'rootfs/usr/share/miclash/reconcile-adapter.uc'), 'utf8');
const dns = fs.readFileSync(path.join(pkg, 'rootfs/usr/share/miclash/dns.uc'), 'utf8');
const settings = fs.readFileSync(path.join(pkg, 'rootfs/usr/share/miclash/settings.uc'), 'utf8');
const packageRemove = fs.readFileSync(path.join(pkg, 'rootfs/usr/share/miclash/package-remove'), 'utf8');
const subscription = fs.readFileSync(path.join(pkg, 'rootfs/usr/share/miclash/subscription.uc'), 'utf8');
const miclashd = fs.readFileSync(path.join(pkg, 'rootfs/usr/sbin/miclashd'), 'utf8');
const daemon = fs.readFileSync(path.join(pkg, 'rootfs/usr/share/miclash/daemon.uc'), 'utf8');
const nft = fs.readFileSync(path.join(pkg, 'rootfs/usr/share/miclash/firewall/nft.uc'), 'utf8');
const installer = fs.readFileSync(path.join(root, 'install-miclash.sh'), 'utf8');

function requireMatch(value, expression, message) {
	if (!expression.test(value)) throw new Error(message);
}
function forbid(value, expression, message) {
	if (expression.test(value)) throw new Error(message);
}

const clashGuardGate = clash.indexOf('/etc/init.d/miclash-guard start');
const clashProcdOpen = clash.indexOf('procd_open_instance');
if (clashGuardGate < 0 || clashProcdOpen < 0 || clashGuardGate > clashProcdOpen)
	throw new Error('Mihomo startup must synchronously verify the early Guard owner first');
const startService = clash.slice(clash.indexOf('start_service()'));
const packageMarkerGate = startService.indexOf('consume_package_install_marker');
const missingKernelGate = startService.indexOf('reason=missing-kernel');
if (packageMarkerGate < 0 || missingKernelGate < 0 || packageMarkerGate > missingKernelGate)
	throw new Error('package-install autostart marker must be consumed before Mihomo prerequisites are checked');
requireMatch(clash,
	/stat -c '%u:%a:%h'[\s\S]*0:600:1[\s\S]*rm -f "\$NO_AUTOSTART_MARKER"/,
	'package-install autostart marker must be authenticated and consumed atomically');
requireMatch(makefile, /LUCI_DEPENDS:=[\s\S]*\+ip-full/,
	'full iproute2 is required for owned route proto and rule protocol syntax');
requireMatch(makefile, /LUCI_DEPENDS:=[^\n]*\+kmod-nft-tproxy/,
	'TPROXY kernel support must be a package-manager runtime dependency');

forbid(makefile, /MICLASH_UNSHIPPED_UCODE/, 'all production ucode modules must be shipped');
for (const dependency of [ 'ucode', 'ucode-mod-fs', 'ucode-mod-ubus', 'ucode-mod-uci', 'ucode-mod-uloop' ])
	requireMatch(makefile, new RegExp('\\+' + dependency.replaceAll('-', '\\-') + '(?:\\s|$)'), `missing dependency ${dependency}`);
for (const asset of [
	'rootfs/etc/init.d/miclashd', 'rootfs/usr/sbin/miclashd', 'rootfs/etc/config/miclash',
	'rootfs/usr/libexec/miclash/decompress-gzip'
]) requireMatch(makefile, new RegExp(asset.replaceAll('/', '\\/').replaceAll('.', '\\.')), `not installed: ${asset}`);

for (const retiredAsset of [
	'rootfs/usr/libexec/miclash/migrate.uc',
	'rootfs/usr/share/miclash/migrate.uc',
	'rootfs/usr/share/miclash/legacy-network.uc',
	'rootfs/usr/share/miclash/legacy-firewall-cleanup.uc'
]) {
	if (fs.existsSync(path.join(pkg, retiredAsset)))
		throw new Error(`v0.9 transition asset is still shipped: ${retiredAsset}`);
}

for (const legacy of [
	'miclash-autoupdate', 'miclash-memory-guard', '40-clash', '99-clash-tun',
	'clash-rules', 'miclash-subscription', 'miclash-update', 'miclash-service'
]) forbid(makefile, new RegExp(`rootfs/[^\\n]*${legacy}`), `legacy backend still packaged: ${legacy}`);

requireMatch(makefile, /\/etc\/config\/miclash/, 'canonical UCI config must be a conffile');
requireMatch(makefile, /chmod 0600 .*\/etc\/config\/miclash/, 'canonical config must be secret-safe');
forbid(makefile, /migrate\.uc|legacy-firewall-cleanup\.uc|guard_latch_set|guard_verify_protected/,
	'v0.9 transition lifecycle is still invoked by the package');
forbid(makefile, /clash-rules|miclash-autoupdate|miclash-memory-guard|40-clash|99-clash-tun/,
	'v2 package lifecycle still cleans up v0.9 backend state');
forbid(packageRemove, /CRON_FILE|clash-rules update/,
	'v2 package removal still quiesces a v0.9 cron backend');
forbid(dns, /\.dns_backup|migrate_legacy/, 'v2 DNS lifecycle still converts v0.9 state');
forbid(settings, /legacy_patch|migrate_legacy|INTERNET_ONLY_MICLASH/,
	'v2 settings module still parses v0.9 settings');
requireMatch(makefile, /miclash-guard start[\s\S]*miclashd start/, 'Guard must start before miclashd');
requireMatch(runtime, /logger_adapter\(\)[\s\S]*\/usr\/bin\/logger[\s\S]*-t[\s\S]*miclash/,
	'backend logs must use the structured miclash syslog tag');
requireMatch(runtime, /capture\('\/sbin\/ip -j '/,
	'device observation must use the OpenWrt 24/25 ip-full path');
forbid(runtime, /\/usr\/sbin\/ip/, 'device observation still uses a missing OpenWrt 25 path');
requireMatch(daemon, /\/sbin\/logread 2>\/dev\/null[\s\S]*miclash\|mihomo\|clash/,
	'LuCI logs must scan the complete ring through the source allowlist');
const observeStart = nft.indexOf('export function observe(runtime)');
const observeEnd = nft.indexOf('function write_all', observeStart);
forbid(nft.slice(observeStart, observeEnd), /runtime\.process\.run/,
	'nft observation still emits captured JSON into the daemon syslog');

forbid(runtime, /\/opt\/clash\/bin\/clash-rules/, 'runtime Guard must not call legacy clash-rules');
forbid(clash, /clash-rules|dnsmasq|iptables|nft|ip rule|ip route|cron/, 'clash init must only supervise Mihomo');
requireMatch(clash, /procd_set_param command .*\/opt\/clash\/bin\/clash/, 'clash init must supervise Mihomo');

for (const nativeModule of [ 'miclash.firewall.nft', 'miclash.routing', 'miclash.dns' ])
	requireMatch(network, new RegExp(nativeModule.replaceAll('.', '\\.')), `network lifecycle missing ${nativeModule}`);
requireMatch(reconcile, /app\.network\.apply\(desired\)[\s\S]*app\.service\.restart_service/,
	'native network state must be verified before Mihomo restart');
requireMatch(reconcile, /app\.network\.apply\(desired\)[\s\S]*app\.guard\.disable\(\)/,
	'canonical OFF may release handoff Guard only after native network apply');
const daemonReadiness = fs.readFileSync(path.join(pkg,
	'rootfs/usr/share/miclash/daemon-readiness.uc'), 'utf8');
const initialReadyClear = miclashd.indexOf('readiness.clear();');
const daemonCompose = miclashd.indexOf('daemon.compose(environment)');
const startupReconcile = daemonReadiness.indexOf('reconcile.startup(source)');
const readyPublication = daemonReadiness.indexOf('writer.atomic_write(runtime, path');
if (initialReadyClear < 0 || daemonCompose < 0 || initialReadyClear > daemonCompose)
	throw new Error('daemon must remove stale readiness before composing/publishing ubus');
if (startupReconcile < 0 || readyPublication < 0 || readyPublication < startupReconcile)
	throw new Error('daemon readiness must be atomically published after startup reconcile');
requireMatch(miclashd, /function shutdown\(\)[\s\S]*readiness\.revoke\(\)[\s\S]*process\.drain\(\)/,
	'daemon must revoke readiness before normal shutdown drain');
for (const unsafe of [
	'/tmp/luci-app-miclash.apk', '/tmp/luci-app-miclash.ipk',
	'/tmp/miclash-release-$$.json', '/tmp/mihomo-release-$$.json', '/tmp/clash.gz'
]) forbid(installer, new RegExp(unsafe.replaceAll('/', '\\/').replaceAll('$', '\\$')),
	`installer still uses predictable world-writable path: ${unsafe}`);
requireMatch(installer, /mktemp -d \/tmp\/miclash-install\.XXXXXX[\s\S]*validate_work_dir/,
	'interactive installer must use a verified root-private workspace');
requireMatch(installer, /WORK_DIR="\$\{STATUS_FILE%\/\*\}"[\s\S]*validate_work_dir/,
	'app installer must reuse the verified update authority');
const reloadStart = installer.indexOf('schedule_backend_reload()');
const reloadEnd = installer.indexOf('\nrun_app_mode()', reloadStart);
if (reloadStart < 0 || reloadEnd <= reloadStart)
	throw new Error('missing backend reload scheduler');
const reloadScheduler = installer.slice(reloadStart, reloadEnd);
requireMatch(reloadScheduler, /while[^\n]*STATUS_FILE[^\n]*-e/,
	'backend reload must wait while the authenticated update handoff is still active');
requireMatch(reloadScheduler, /MAX_BACKEND_RELOAD_WAIT/,
	'backend reload wait must remain bounded');
requireMatch(reloadScheduler, /\/etc\/init\.d\/miclashd restart[\s\S]*&/,
	'successful in-app package updates must asynchronously reload the backend');
requireMatch(installer,
	/write_status success done[^}]*[\s\S]*schedule_backend_reload/,
	'backend reload must only be scheduled after the final authenticated handoff');
requireMatch(installer, /path_metadata\(\)[\s\S]*LC_ALL=C ls -ldn[\s\S]*owned_file_0600\(\)[\s\S]*marker_owned\(\)[\s\S]*create_marker\(\)[\s\S]*set -C/,
	'package markers must be exclusively created and root:0600 verified');
requireMatch(makefile, /LUCI_DEPENDS:=[^\n]*\+coreutils-stat/,
	'package runtime must include stat on OpenWrt builds where BusyBox omits it');
requireMatch(installer, /verify_download_checksum[\s\S]*sha256sum/,
	'installer must verify downloaded artifacts');
requireMatch(installer, /download_artifact "\$MICLASH_APK_URL"[\s\S]*verify_download_checksum "\$PKG_FILE" "\$MICLASH_APK_SHA256_URL"/,
	'APK must be checksum-verified before package-manager execution');
requireMatch(installer, /download_artifact "\$MICLASH_IPK_URL"[\s\S]*verify_download_checksum "\$PKG_FILE" "\$MICLASH_IPK_SHA256_URL"/,
	'IPK must be checksum-verified before package-manager execution');
requireMatch(installer, /resolve_mihomo_release\(\)[\s\S]*asset\.digest[\s\S]*sha256:\[0-9A-Fa-f\]/,
	'installer must resolve the Mihomo asset digest from verified release metadata');
requireMatch(installer,
	/download_artifact "\$MIHOMO_URL"[\s\S]*verify_download_digest "\$mihomo_archive" "\$MIHOMO_DIGEST"/,
	'Mihomo archive must verify the release digest before unpacking');
requireMatch(makefile, /stat -c '%u:%a:%h'[\s\S]*= 0:600:1[\s\S]*Ignoring untrusted MiClash hard-reinstall marker/,
	'postrm must authenticate the root-owned hard-reinstall marker before deleting Mihomo');

const installed = [ ...makefile.matchAll(/\.\/rootfs\/usr\/share\/miclash\/([^\s)]+)/g) ].map(m => m[1]);
if (!makefile.includes('$(wildcard ./rootfs/usr/share/miclash/*.uc)'))
	throw new Error('all top-level ucode modules must be selected');
if (!makefile.includes('$(wildcard ./rootfs/usr/share/miclash/firewall/*.uc)'))
	throw new Error('all firewall ucode modules must be selected');

console.log('package cutover contract passed');
