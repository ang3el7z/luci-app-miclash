import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const makefile = readFileSync('luci-app-miclash/Makefile', 'utf8');
const installer = readFileSync('install-miclash.sh', 'utf8');
const recover = readFileSync(
	'luci-app-miclash/rootfs/usr/share/miclash/package-upgrade-recover', 'utf8');
const initd = readFileSync('luci-app-miclash/rootfs/etc/init.d/miclashd', 'utf8');
const installMiclash = installer.match(/install_miclash\(\) \{([\s\S]*?)\n\}/)?.[1] || '';
const repairPrerm = installer.match(
	/repair_installed_prerm_upgrade_classification\(\) \{([\s\S]*?)\n\}/)?.[1] || '';
const repairMiclashd = installer.match(
	/repair_installed_miclashd_self_update_stop\(\) \{([\s\S]*?)\n\}/)?.[1] || '';
const backendReload = installer.match(/schedule_backend_reload\(\) \{([\s\S]*?)\n\}/)?.[1] || '';
const upgradeRecoverInstance = initd.match(/procd_open_instance upgrade-recover\n([\s\S]*?)\n\tprocd_close_instance/)?.[1] || '';
const packagePrerm = makefile.match(
	/define Package\/\$\(PKG_NAME\)\/prerm\n([\s\S]*?)\nendef/)?.[1] || '';
const packagePostrm = makefile.match(
	/define Package\/\$\(PKG_NAME\)\/postrm\n([\s\S]*?)\nendef/)?.[1] || '';
const packagePostinst = makefile.match(
	/define Package\/\$\(PKG_NAME\)\/postinst\n([\s\S]*?)\nendef/)?.[1] || '';

assert.match(makefile, /MICLASH_UPGRADE_STATE=.*package-upgrade-state/,
	'package upgrades must retain a durable MiClash upgrade-state marker');
assert.match(makefile, /write_upgrade_state\(\)/,
	'preinst must record the Guard and service intent before package replacement');
assert.match(makefile, /recover_upgrade_state\(\)/,
	'postinst must reconcile an interrupted package upgrade before declaring installation complete');
assert.match(makefile, /\/etc\/init\.d\/miclash-guard start[\s\S]*recover_upgrade_state/s,
	'postinst must recover preserved Guard state after the new Guard runtime is installed');
assert.match(makefile, /miclash-package-no-autostart-autoupdate/,
	'app-driven package updates must have a distinct postinst ownership marker');
assert.match(packagePrerm, /PACKAGE_ACTION="\$\${2:-\$\${1:-}}"/,
	'generated prerm wrappers must read the package-manager action from their second argument');
assert.match(packagePrerm, /PKG_UPGRADE:-0/,
	'generated prerm wrappers must prefer the package-manager upgrade environment');
assert.match(packagePostrm, /PKG_UPGRADE:-0/,
	'postrm must classify upgrades from the package-manager environment');
assert.match(repairPrerm,
	/case "\$\{2:-\$\{1:-\}\}" in[\s\S]*case "\$1" in[\s\S]*upgrade-compat/s,
	'the installer must atomically repair vulnerable installed opkg prerm hooks');
assert.match(repairPrerm,
	/PACKAGE_ACTION="\$\{2:-\$\{1:-\}\}"[\s\S]*case "\$PACKAGE_ACTION" in/,
	'the installer must accept the current generated opkg prerm hook idempotently');
assert.match(installMiclash,
	/repair_installed_prerm_upgrade_classification[\s\S]*create_marker "\$NO_AUTOSTART_CLASH_MARKER"/,
	'the vulnerable installed hook must be repaired before package lifecycle markers are armed');
assert.match(installMiclash,
	/repair_installed_miclashd_self_update_stop[\s\S]*create_app_update_marker/,
	'the installed backend stop hook must preserve the owning self-update daemon');
assert.match(repairMiclashd,
	/USE_PROCD=1[\s\S]*app_update_handoff_active[\s\S]*operation_journal[\s\S]*start\|stop[\s\S]*USE_PROCD=/s,
	'the compatibility repair must make only authenticated app-update stops inert');
assert.match(installMiclash,
	/if \[ -n "\$STATUS_FILE" \]; then[\s\S]*create_app_update_marker/,
	'only app-driven updates may bypass synchronous postinst recovery');
assert.match(installer,
	/create_app_update_marker\(\)[\s\S]*printf '%s\\n' "\$STATUS_FILE"[\s\S]*marker_owned/s,
	'the app-update marker must be bound to its authenticated handoff path');
assert.doesNotMatch(installMiclash, /\b(?:enable|disable)\b/,
	'app update installation must not mutate durable service intent directly');
assert.match(makefile,
	/app_update_marker_present[\s\S]*recover_upgrade_state \|\| exit 1/s,
	'app-driven self-updates must not synchronously call back into the blocked miclashd');
assert.match(packagePostinst,
	/if app_update_marker_present; then[\s\S]*else[\s\S]*\/etc\/init\.d\/miclashd start/s,
	'app-driven self-updates must keep the owning backend alive until its operation is terminal');
assert.match(upgradeRecoverInstance,
	/procd_set_param command \/usr\/share\/miclash\/package-upgrade-recover \/etc\/miclash\/package-upgrade-state/,
	'miclashd must own deferred durable recovery after it starts the daemon and poller');
assert.doesNotMatch(upgradeRecoverInstance, /procd_set_param command \/bin\/sh -c/,
	'deferred recovery must give procd the actual helper PID, not a shell wrapper');
assert.doesNotMatch(upgradeRecoverInstance, /procd_set_param respawn/,
	'deferred recovery must be a one-shot procd worker');
assert.doesNotMatch(backendReload, /package-upgrade-recover/,
	'app-driven reloads must not create a second detached recovery owner');
assert.match(recover, /service_running[\s\S]*run_service_operation service_start/s,
	'deferred recovery must restore a previously running Mihomo service');
assert.match(recover, /service_running[\s\S]*run_service_operation service_stop/s,
	'deferred recovery must preserve a previously stopped Mihomo service');
assert.match(recover,
	/run_service_operation\(\)[\s\S]*operation_get[\s\S]*state.*success[\s\S]*run_service_operation service_start/s,
	'enabled service recovery must wait for the typed backend operation that reapplies networking');
assert.match(makefile, /version=2[\s\S]*service_enabled=%s/,
	'preinst must persist the versioned durable service intent journal');
assert.match(makefile, /tmp_file=[\s\S]*\/bin\/mv -f[\s\S]*MICLASH_UPGRADE_STATE/s,
	'preinst must publish the verified journal with a same-directory atomic rename');
assert.match(makefile, /\[ -e "\$\$MICLASH_UPGRADE_STATE" \] \|\| \[ -L "\$\$MICLASH_UPGRADE_STATE" \] \|\| return 0/,
	'postinst must route dangling journal symlinks to strict recovery rejection');
assert.match(recover, /service_running.*\|\|.*service_enabled/s,
	'v2 recovery must migrate either running or enabled service state to durable intent');
assert.match(recover, /\/etc\/init\.d\/clash enable[\s\S]*\/etc\/init\.d\/clash enabled/s,
	'durable on-state recovery must enable and verify the service before it starts');
assert.match(recover, /\/etc\/init\.d\/clash disable[\s\S]*\/etc\/init\.d\/clash enabled/s,
	'durable off-state recovery must disable and verify the service');
assert.match(recover, /wc -c[\s\S]*-le 512/,
	'recovery must bound journal size before parsing untrusted content');
assert.match(recover, /lock_dir=.*package-upgrade-recover\.lock[\s\S]*rmdir "\$lock_dir"/s,
	'recovery callers must serialize through a removable runtime lock');
assert.match(recover,
	/finish\(\) \{[\s\S]*status=\$\?[\s\S]*release_lock[\s\S]*MiClash package upgrade recovery remains pending[\s\S]*exit "\$status"[\s\S]*trap finish EXIT[\s\S]*trap 'exit 1' HUP INT TERM/s,
	'helper failures and termination must release the lock and emit one fixed non-secret line');
assert.match(recover, /waited_for_owner=0[\s\S]*\[ "\$lock_acquired" -eq 1 \] \|\| exit 1/s,
	'waiting callers must fail with a retained journal when the owner does not complete');
assert.match(recover, /while \[ "\$attempt" -lt 30 \][\s\S]*state_absent && exit 0/s,
	'waiting callers may succeed only when neither a journal nor dangling journal link remains');
assert.match(recover, /rm -f "\$state_file"/,
	'durable upgrade state must be removed only by successful deferred recovery');
assert.doesNotMatch(recover, /diagnostics_summary/,
	'package recovery must not call the heavyweight diagnostic aggregator');
assert.match(recover, /\/etc\/init\.d\/miclash-guard start/,
	'package recovery must directly and idempotently apply the captured Guard intent');
assert.match(recover, /ubus -t 2 call miclash health/,
	'package recovery must use the bounded lightweight daemon readiness endpoint');

console.log('package upgrade Guard recovery contract passed');
