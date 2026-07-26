import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const makefile = readFileSync('luci-app-miclash/Makefile', 'utf8');
const installer = readFileSync('install-miclash.sh', 'utf8');
const recover = readFileSync(
	'luci-app-miclash/rootfs/usr/share/miclash/package-upgrade-recover', 'utf8');
const installMiclash = installer.match(/install_miclash\(\) \{([\s\S]*?)\n\}/)?.[1] || '';

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
assert.match(installMiclash,
	/if \[ -n "\$STATUS_FILE" \]; then[\s\S]*create_marker "\$NO_AUTOSTART_AUTOUPDATE_MARKER"/,
	'only app-driven updates may bypass synchronous postinst recovery');
assert.match(makefile,
	/consume_app_update_marker[\s\S]*recover_upgrade_state \|\| exit 1/s,
	'app-driven self-updates must not synchronously call back into the blocked miclashd');
assert.match(installer,
	/\/etc\/init\.d\/miclashd restart[\s\S]*package-upgrade-recover/s,
	'app-driven self-updates must defer durable recovery until the new backend is running');
assert.match(recover, /service_running[\s\S]*\/etc\/init\.d\/clash start/s,
	'deferred recovery must restore a previously running Mihomo service');
assert.match(recover, /service_running[\s\S]*\/etc\/init\.d\/clash stop/s,
	'deferred recovery must preserve a previously stopped Mihomo service');
assert.match(recover, /rm -f "\$state_file"/,
	'durable upgrade state must be removed only by successful deferred recovery');
assert.doesNotMatch(recover, /diagnostics_summary/,
	'package recovery must not call the heavyweight diagnostic aggregator');
assert.match(recover, /\/etc\/init\.d\/miclash-guard start/,
	'package recovery must directly and idempotently apply the captured Guard intent');
assert.match(recover, /ubus -t 2 call miclash health/,
	'package recovery must use the bounded lightweight daemon readiness endpoint');

console.log('package upgrade Guard recovery contract passed');
