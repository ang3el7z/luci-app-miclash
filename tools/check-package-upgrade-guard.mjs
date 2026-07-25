import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const makefile = readFileSync('luci-app-miclash/Makefile', 'utf8');

assert.match(makefile, /MICLASH_UPGRADE_STATE=.*package-upgrade-state/,
	'package upgrades must retain a durable MiClash upgrade-state marker');
assert.match(makefile, /write_upgrade_state\(\)/,
	'preinst must record the Guard and service intent before package replacement');
assert.match(makefile, /recover_upgrade_state\(\)/,
	'postinst must reconcile an interrupted package upgrade before declaring installation complete');
assert.match(makefile, /restore_service_intent\(\)/,
	'postinst must restore a previously stopped MiClash service after Guard verification');
assert.match(makefile, /\/etc\/init\.d\/miclash-guard start[\s\S]*recover_upgrade_state/s,
	'postinst must recover preserved Guard state after the new Guard runtime is installed');
assert.match(makefile, /recover_upgrade_state \|\| exit 1[\s\S]*restore_service_intent \|\| exit 1/s,
	'Guard must be verified before restoring the previous stopped-service intent');
assert.match(makefile, /rm -f "\$\$MICLASH_UPGRADE_STATE"/,
	'upgrade-state marker must be removed only after successful recovery');

console.log('package upgrade Guard recovery contract passed');
