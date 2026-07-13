import { readFileSync } from 'node:fs';

function source(path) {
	try { return readFileSync(path, 'utf8'); }
	catch { return ''; }
}

function check(condition, message) {
	if (!condition) throw new Error(message);
}

function blockBetween(text, start, end) {
	const from = text.indexOf(start);
	const to = from < 0 ? -1 : text.indexOf(end, from + start.length);
	return from >= 0 && to > from ? text.slice(from, to) : '';
}

const barrier = '/var/run/miclash/package-removal';
const files = {
	makefile: source('luci-app-miclash/Makefile'),
	remove: source('luci-app-miclash/rootfs/usr/share/miclash/package-remove'),
	routing: source('luci-app-miclash/rootfs/usr/share/miclash/routing.uc'),
	cleanup: source('luci-app-miclash/rootfs/usr/share/miclash/routing-cleanup.uc'),
	rules: source('luci-app-miclash/rootfs/opt/clash/bin/clash-rules'),
	clashInit: source('luci-app-miclash/rootfs/etc/init.d/clash'),
	dInit: source('luci-app-miclash/rootfs/etc/init.d/miclashd'),
	autoInit: source('luci-app-miclash/rootfs/etc/init.d/miclash-autoupdate'),
	netHotplug: source('luci-app-miclash/rootfs/etc/hotplug.d/net/99-clash-tun'),
	wanHotplug: source('luci-app-miclash/rootfs/etc/hotplug.d/iface/40-clash'),
	update: source('luci-app-miclash/rootfs/opt/clash/bin/miclash-update'),
	autoUpdate: source('luci-app-miclash/rootfs/opt/clash/bin/miclash-autoupdate'),
	service: source('luci-app-miclash/rootfs/opt/clash/bin/miclash-service'),
	memoryGuard: source('luci-app-miclash/rootfs/opt/clash/bin/miclash-memory-guard')
};
const workflow = source('.github/workflows/checks.yml');

for (const [name, text] of Object.entries(files))
	check(text.includes(barrier), `${name} must enforce the fixed package-removal barrier`);

check(files.cleanup.includes('package_removal_cleanup = true'),
	'only the fixed routing cleanup entrypoint must carry the internal bypass capability');
check(!files.routing.includes('package_removal_cleanup = true'),
	'the routing module must not synthesize its own package cleanup capability');

const ordinaryPrerm = blockBetween(files.makefile, 'define Package/$(PKG_NAME)/prerm', 'endef');
check(ordinaryPrerm.includes('/usr/share/miclash/package-remove'),
	'ordinary prerm must invoke the packaged removal protocol while all files exist');
check(!ordinaryPrerm.includes('routing-cleanup.uc'),
	'prerm must not bypass process quiescence by calling routing cleanup directly');

for (const token of [ 'establish_barrier', 'quiesce_update_triggers', 'delete_clash_and_wait',
	'run_routing_cleanup', 'run_preserve_cleanup', 'remove_guard_owner' ])
	check(files.remove.includes(token), `package removal protocol is missing ${token}`);
check(files.remove.includes('[ ! -L "$BARRIER" ]'),
	'barrier establishment must explicitly reject a symlink before ownership/mode changes');

const order = [ 'establish_barrier', 'quiesce_update_triggers', 'delete_clash_and_wait',
	'run_routing_cleanup', 'run_preserve_cleanup', 'remove_guard_owner' ]
	.map(token => files.remove.lastIndexOf(token));
check(order.every((value, index) => value >= 0 && (index === 0 || value > order[index - 1])),
	'package removal main path must establish, quiesce, delete/wait, route-clean, preserve-clean, then remove Guard');
check(!/trap[^\n]*package-removal|rm -rf[^\n]*package-removal/.test(files.remove),
	'prerm helper must never remove the barrier on success or failure');
check(files.remove.includes('/etc/init.d/clash package_cleanup') &&
	!files.remove.includes('full_cleanup'),
	'package protocol must use only init-owned preserve-routing/DNS package cleanup');

const postrm = blockBetween(files.makefile, 'define Package/$(PKG_NAME)/postrm', 'endef');
const release = postrm.indexOf('package-removal');
check(release > postrm.indexOf('/etc/hotplug.d/net/99-clash-tun') &&
	release > postrm.indexOf('/opt/clash/bin/clash-rules'),
	'postrm may release the barrier only after routing mutator files and hooks are gone');
check(postrm.includes("stat -c '%u:%a' \"$$BARRIER\"") &&
	postrm.includes("stat -c '%u:%a' \"$$BARRIER/complete\""),
	'postrm must validate the root-owned barrier and completion marker before release');
for (const mutator of [ '/opt/clash/bin/clash-rules', '/opt/clash/bin/miclash-update',
	'/opt/clash/bin/miclash-service', '/opt/clash/bin/miclash-autoupdate',
	'/opt/clash/bin/miclash-memory-guard', '/etc/init.d/clash',
	'/etc/init.d/miclash-autoupdate', '/etc/init.d/miclash-memory-guard',
	'/etc/hotplug.d/iface/40-clash', '/etc/hotplug.d/net/99-clash-tun',
	'/usr/share/miclash/routing.uc', '/usr/share/miclash/routing-cleanup.uc',
	'/usr/share/miclash/package-remove' ])
	check(postrm.includes(`[ ! -e ${mutator} ]`),
		`postrm completion release must prove mutator removal: ${mutator}`);
check(postrm.indexOf('rm -f /etc/miclash/guard-bootstrap.json') >
	postrm.indexOf("stat -c '%u:%a' \"$$BARRIER/complete\""),
	'postrm must preserve Guard ownership state unless valid completion is proven');

check(files.clashInit.includes('remove_firewall_rules true') &&
	files.clashInit.includes('package_removal_active'),
	'Clash init stop/default-prerm path must preserve routing and Guard under the barrier');
check(files.rules.includes('stop true true'),
	'clash-rules package cleanup must preserve both routing and Guard');
check(!ordinaryPrerm.includes('full_cleanup') && !postrm.includes('full_cleanup'),
	'package lifecycle must never call legacy whole-table full cleanup');
check(workflow.includes('sudo tools/check-package-removal.sh'),
	'CI must run the privileged package process and failure-preservation gate');

console.log('package removal barrier check passed');
