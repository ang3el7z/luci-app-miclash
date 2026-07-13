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
	guardInit: source('luci-app-miclash/rootfs/etc/init.d/miclash-guard'),
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
const releaseHelper = source('luci-app-miclash/rootfs/usr/share/miclash/package-release');
const lockHelper = source('luci-app-miclash/rootfs/usr/share/miclash/mutation-lock.sh');

const sharedLockShell = '/usr/share/miclash/mutation-lock.sh';
const shellWriters = {
	remove: files.remove,
	rules: files.rules,
	clashInit: files.clashInit,
	guardInit: files.guardInit,
	netHotplug: files.netHotplug,
	wanHotplug: files.wanHotplug,
	update: files.update,
	autoUpdate: files.autoUpdate,
	service: files.service,
	memoryGuard: files.memoryGuard
};

for (const [name, text] of Object.entries(shellWriters)) {
	check(text.includes(sharedLockShell), `${name} must source the shared mutation lock helper`);
	check(text.includes('miclash_mutation_lock_enter'), `${name} must acquire the shared mutation lock`);
	check(text.includes('miclash_mutation_lock_leave'), `${name} must release the shared mutation lock`);
	check(!text.includes('MICLASH_MUTATION_LOCK_HELPER:-'),
		`${name} must not accept an environment override for sourced root code`);
}

const packageOwnerApi = 'miclash_mutation_lock_enter_package_owner';
check(lockHelper.includes(`${packageOwnerApi}()`),
	'shared lock must expose a distinct internal package-owner API');
check(files.remove.includes(`${packageOwnerApi} 30000`) &&
	!files.remove.includes('miclash_mutation_lock_enter package 30000'),
	'only package-remove may request creation of the package owner');
for (const [name, text] of Object.entries(shellWriters))
	if (name !== 'remove')
		check(!text.includes(packageOwnerApi),
			`${name} must never request package-owner authority`);
const publicEnter = blockBetween(lockHelper, 'miclash_mutation_lock_enter() {',
	`${packageOwnerApi}() {`);
check(publicEnter.includes('participant-only') &&
	!publicEnter.includes('package-owner-internal'),
	'public package mode must be participant-only regardless of caller environment');

check(files.routing.includes("from 'miclash.mutation_lock'"),
	'routing must use the shared ucode mutation lock');
check(files.routing.includes('with_lock(runtime') &&
	files.routing.includes('assert_held(runtime, runtime.mutation_lock_lease)'),
	'routing apply/cleanup and every kernel action must require an active shared lease');
check(files.cleanup.includes("getenv('MICLASH_MUTATION_LOCK_TOKEN')"),
	'package routing cleanup must join the inherited package lock owner');

for (const [name, text] of Object.entries(files))
	if (name !== 'guardInit')
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

const removeMain = files.remove.lastIndexOf('establish_barrier ||');
const lockMain = files.remove.lastIndexOf(`${packageOwnerApi} 30000`);
const quiesceMain = files.remove.lastIndexOf('quiesce_update_triggers ||');
check(removeMain >= 0 && lockMain > removeMain && quiesceMain > lockMain,
	'package removal must establish the barrier, acquire the shared lock, then quiesce writers');
check(files.remove.includes("trap 'release_mutation_lock") &&
	files.remove.includes('miclash_mutation_lock_leave'),
	'package removal must hold the shared lock through every cleanup exit');
check(files.remove.includes('prepare_release_state') && files.remove.includes('commit_release_state'),
	'prerm must prepare and commit a runtime release proof before package files disappear');
check(releaseHelper.includes('barrier-complete.hold') && releaseHelper.includes('rmdir "$BARRIER"'),
	'runtime release helper must retain recoverable proof around the barrier rmdir');

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
check(postrm.includes('RELEASE_DIR="/var/run/miclash/package-removal-release"') &&
	postrm.includes('"$$RELEASE_DIR/helper" "$$RELEASE_DIR"') &&
	postrm.includes('rmdir "$$RELEASE_DIR"'),
	'postrm must invoke the retained helper and remove release state only after success');

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
