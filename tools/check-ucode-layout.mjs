import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { existsSync, readFileSync, readdirSync } from 'node:fs';
import { basename } from 'node:path';

for (const path of [
	'tools/run-ucode-tests.sh',
	'tests/ucode/testlib.uc',
	'tests/ucode/test-testlib.uc',
	'tests/ucode/test-api.uc',
	'tests/ucode/test-application.uc',
	'tests/ucode/test-daemon.uc',
	'tests/ucode/ubus-registration-smoke.uc',
	'luci-app-miclash/rootfs/usr/share/miclash/application.uc',
	'luci-app-miclash/rootfs/usr/share/miclash/daemon.uc',
	'luci-app-miclash/rootfs/usr/share/miclash/state.uc',
	'luci-app-miclash/rootfs/usr/share/miclash/api.uc',
	'luci-app-miclash/rootfs/usr/sbin/miclashd',
	'luci-app-miclash/rootfs/etc/init.d/miclashd'
]) assert.ok(existsSync(path), `missing ${path}`);

const daemon = readFileSync('luci-app-miclash/rootfs/usr/sbin/miclashd', 'utf8');
const composition = readFileSync('luci-app-miclash/rootfs/usr/share/miclash/daemon.uc', 'utf8');
const api = readFileSync('luci-app-miclash/rootfs/usr/share/miclash/api.uc', 'utf8');
const init = readFileSync('luci-app-miclash/rootfs/etc/init.d/miclashd', 'utf8');
const makefile = readFileSync('luci-app-miclash/Makefile', 'utf8');

function makeAssignment(name) {
	const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
	const found = makefile.match(new RegExp(
		`^${escaped}\\s*:?=(?:[^\\r\\n]*\\\\\\r?\\n)*[^\\r\\n]*`, 'm'));
	assert.ok(found, `missing make assignment ${name}`);
	return found[0];
}

const packageModules = makeAssignment('MICLASH_PACKAGE_UCODE');
const unshippedModules = makeAssignment('MICLASH_UNSHIPPED_UCODE');
const expanded = spawnSync('make', [ '--no-print-directory', '-f', '-', 'all' ], {
	cwd: 'luci-app-miclash',
	input: `${unshippedModules}\n${packageModules}\n` +
		'$(info UNSHIPPED=$(MICLASH_UNSHIPPED_UCODE))\n' +
		'$(info PACKAGE=$(MICLASH_PACKAGE_UCODE))\nall: ;\n',
	encoding: 'utf8'
});
assert.equal(expanded.status, 0, `GNU make expansion failed: ${expanded.stderr}`);
function expandedBasenames(label) {
	const line = expanded.stdout.split(/\r?\n/).find((candidate) => candidate.startsWith(`${label}=`));
	assert.ok(line, `GNU make did not print ${label}`);
	return line.slice(label.length + 1).trim().split(/\s+/).filter(Boolean)
		.map((path) => basename(path)).sort();
}
const experimental = [
	'backup.uc', 'devices.uc', 'diagnostics.uc', 'diff.uc', 'health.uc', 'http.uc',
	'memory.uc', 'notify.uc', 'reconcile.uc', 'route-test.uc', 'schedule.uc',
	'scheduler.uc', 'subscription.uc', 'telegram.uc', 'updates.uc'
].sort();
assert.deepEqual(expandedBasenames('UNSHIPPED'), experimental,
	'the explicit unshipped list must contain every Plan 2/3 module held for final cutover');
const allModules = readdirSync('luci-app-miclash/rootfs/usr/share/miclash')
	.filter((name) => name.endsWith('.uc')).sort();
assert.deepEqual(expandedBasenames('PACKAGE'),
	allModules.filter((name) => !experimental.includes(name)),
	'the package make expression must retain every approved ucode module and exclude held features');
assert.match(makefile, /\$\(INSTALL_DATA\)\s+\$\(MICLASH_PACKAGE_UCODE\)\s+\$\(1\)\/usr\/share\/miclash\//,
	'the package install recipe must consume the filtered ucode expansion');

assert.match(daemon, /^#!\/usr\/bin\/ucode\n/);
assert.match(composition, /recover_interrupted\(\)/);
assert.match(composition, /api\.register\(connection, app\)/);
assert.match(daemon, /signal\(['"]SIGTERM['"]/);
assert.match(daemon, /\.cancel\(\)/);
assert.match(daemon, /uloop\.done\(\)/);
assert.match(composition, /connection\.disconnect\(\)/);
assert.ok(composition.indexOf('recover_interrupted()') < composition.indexOf('runtime.ubus.connect()'),
	'operation recovery must finish before ubus publication');
assert.ok(composition.indexOf('runtime.ubus.connect()') < composition.indexOf('api.register(connection, app)'),
	'one daemon ubus connection must exist before publication');
assert.ok(daemon.indexOf('process.drain()') < daemon.indexOf('observation_timer.cancel()'),
	'shutdown must reject mutations before cancelling observation');
assert.ok(composition.indexOf('state_model.close()') < composition.indexOf('state_model.flush()'),
	'shutdown must detach subscriptions before the final state flush');
const closeStart = composition.indexOf('// NORMAL_CLOSE_BEGIN');
const closeEnd = composition.indexOf('// NORMAL_CLOSE_END');
assert.ok(closeStart >= 0 && closeEnd > closeStart, 'normal close markers must exist');
const normalClose = composition.slice(closeStart, closeEnd);
assert.ok(normalClose.indexOf('state_model.flush()') < normalClose.indexOf('disconnect()'),
	'shutdown must flush defined state before disconnecting ubus');
assert.match(init, /procd_set_param respawn 3600 5 5/);
assert.match(init,
	/procd_set_param command \/usr\/bin\/ucode -L '\/usr\/share\/\*\.uc' \/usr\/sbin\/miclashd/);
assert.match(init, /procd_set_param stdout 1/);
assert.match(init, /procd_set_param stderr 1/);
assert.doesNotMatch(makefile, /miclashd/,
	'miclashd must remain unshipped until the final cutover');
assert.doesNotMatch(api, /\.submit\(|\.stage\(|wait_ready|settings\.set/,
	'api.uc must remain transport-only');

console.log('ucode layout check passed');
