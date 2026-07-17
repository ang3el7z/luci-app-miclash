import fs from 'node:fs';
import path from 'node:path';

const root = path.resolve(import.meta.dirname, '..');
const pkg = path.join(root, 'luci-app-miclash');
const makefile = fs.readFileSync(path.join(pkg, 'Makefile'), 'utf8');
const runtime = fs.readFileSync(path.join(pkg, 'rootfs/usr/share/miclash/runtime.uc'), 'utf8');
const clash = fs.readFileSync(path.join(pkg, 'rootfs/etc/init.d/clash'), 'utf8');
const network = fs.readFileSync(path.join(pkg, 'rootfs/usr/share/miclash/network.uc'), 'utf8');
const reconcile = fs.readFileSync(path.join(pkg, 'rootfs/usr/share/miclash/reconcile-adapter.uc'), 'utf8');
const legacyNetwork = fs.readFileSync(path.join(pkg, 'rootfs/usr/share/miclash/legacy-network.uc'), 'utf8');
const migrate = fs.readFileSync(path.join(pkg, 'rootfs/usr/share/miclash/migrate.uc'), 'utf8');
const subscription = fs.readFileSync(path.join(pkg, 'rootfs/usr/share/miclash/subscription.uc'), 'utf8');

function requireMatch(value, expression, message) {
	if (!expression.test(value)) throw new Error(message);
}
function forbid(value, expression, message) {
	if (expression.test(value)) throw new Error(message);
}

forbid(makefile, /MICLASH_UNSHIPPED_UCODE/, 'all production ucode modules must be shipped');
for (const dependency of [ 'ucode', 'ucode-mod-fs', 'ucode-mod-ubus', 'ucode-mod-uci', 'ucode-mod-uloop' ])
	requireMatch(makefile, new RegExp('\\+' + dependency.replaceAll('-', '\\-') + '(?:\\s|$)'), `missing dependency ${dependency}`);
for (const asset of [
	'rootfs/etc/init.d/miclashd', 'rootfs/usr/sbin/miclashd', 'rootfs/etc/config/miclash',
	'rootfs/usr/libexec/miclash/migrate.uc'
]) requireMatch(makefile, new RegExp(asset.replaceAll('/', '\\/').replaceAll('.', '\\.')), `not installed: ${asset}`);

for (const legacy of [
	'miclash-autoupdate', 'miclash-memory-guard', '40-clash', '99-clash-tun',
	'clash-rules', 'miclash-subscription', 'miclash-update', 'miclash-service'
]) forbid(makefile, new RegExp(`rootfs/[^\\n]*${legacy}`), `legacy backend still packaged: ${legacy}`);

requireMatch(makefile, /\/etc\/config\/miclash/, 'canonical UCI config must be a conffile');
requireMatch(makefile, /chmod 0600 .*\/etc\/config\/miclash/, 'canonical config must be secret-safe');
for (const phase of [ 'prepare', 'apply', 'verify', 'cleanup' ])
	requireMatch(makefile, new RegExp(`migrate\\.uc ${phase}`), `missing migration phase ${phase}`);
requireMatch(makefile, /miclash-guard start[\s\S]*miclashd start/, 'Guard must start before miclashd');
requireMatch(makefile, /miclash-guard start[\s\S]*legacy-firewall-cleanup\.uc[\s\S]*miclashd start/,
	'legacy firewall ownership must be retired under native Guard before daemon start');
requireMatch(makefile, /guard_latch_set[\s\S]*guard_start[\s\S]*guard_verify_protected[\s\S]*migrate\.uc prepare/,
	'legacy Guard ON must be latched and physically verified before cutover');

forbid(runtime, /\/opt\/clash\/bin\/clash-rules/, 'runtime Guard must not call legacy clash-rules');
forbid(clash, /clash-rules|dnsmasq|iptables|nft|ip rule|ip route|cron/, 'clash init must only supervise Mihomo');
requireMatch(clash, /procd_set_param command .*\/opt\/clash\/bin\/clash/, 'clash init must supervise Mihomo');

for (const nativeModule of [ 'miclash.firewall.nft', 'miclash.routing', 'miclash.dns' ])
	requireMatch(network, new RegExp(nativeModule.replaceAll('.', '\\.')), `network lifecycle missing ${nativeModule}`);
requireMatch(reconcile, /app\.network\.apply\(desired\)[\s\S]*app\.service\.restart_service/,
	'native network state must be verified before Mihomo restart');
requireMatch(reconcile, /app\.network\.apply\(desired\)[\s\S]*app\.guard\.disable\(\)/,
	'canonical OFF may release handoff Guard only after native network apply');
for (const legacyOwner of [ 'clash', 'miclash_guard', 'CLASH_PROCESS', 'CLASH_LOCAL',
	'CLASH_OUTPUT_REDIRECT', 'routing-ownership.json', '.dns_backup', 'miclash.include',
	'40-clash', '99-clash-tun' ])
	requireMatch(legacyNetwork, new RegExp(legacyOwner.replaceAll('.', '\\.')), `legacy handoff misses ${legacyOwner}`);
forbid(legacyNetwork, /guard_control\.disable/, 'legacy teardown must retain temporary Guard until native handoff');
requireMatch(migrate, /with_lock[\s\S]*CANONICAL_MARKER[\s\S]*same\(settings\.load\(runtime\), expected\)/,
	'migration commit must recheck marker and canonical bytes under the writer lease');
requireMatch(subscription, /apply_transaction_in_operation[\s\S]*prepare:[\s\S]*settings\.set\(next_patch\)[\s\S]*rollback:/,
	'subscription replacement must use the coupled durable transaction');

const installed = [ ...makefile.matchAll(/\.\/rootfs\/usr\/share\/miclash\/([^\s)]+)/g) ].map(m => m[1]);
if (!makefile.includes('$(wildcard ./rootfs/usr/share/miclash/*.uc)'))
	throw new Error('all top-level ucode modules must be selected');
if (!makefile.includes('$(wildcard ./rootfs/usr/share/miclash/firewall/*.uc)'))
	throw new Error('all firewall ucode modules must be selected');

console.log('package cutover contract passed');
