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
const checksWorkflow = readFileSync('.github/workflows/checks.yml', 'utf8');

function makeAssignment(name) {
	const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
	const found = makefile.match(new RegExp(
		`^${escaped}\\s*:?=(?:[^\\r\\n]*\\\\\\r?\\n)*[^\\r\\n]*`, 'm'));
	assert.ok(found, `missing make assignment ${name}`);
	return found[0];
}

const packageModules = makeAssignment('MICLASH_PACKAGE_UCODE');
const expanded = spawnSync('make', [ '--no-print-directory', '-f', '-', 'all' ], {
	cwd: 'luci-app-miclash',
	input: `${packageModules}\n` +
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
const allModules = readdirSync('luci-app-miclash/rootfs/usr/share/miclash')
	.filter((name) => name.endsWith('.uc')).sort();
assert.deepEqual(expandedBasenames('PACKAGE'), allModules,
	'the final package must ship every reviewed production ucode module');
assert.match(makefile, /\$\(INSTALL_DATA\)\s+\$\(MICLASH_PACKAGE_UCODE\)\s+\$\(1\)\/usr\/share\/miclash\//,
	'the package install recipe must consume the filtered ucode expansion');
assert.match(makefile, /chmod 0700 \$\(1\)\/etc\/miclash/,
	'the package must stage the privileged MiClash authority directory as root-only');

assert.match(daemon, /^#!\/usr\/bin\/ucode\n/);
assert.match(composition, /recover_interrupted\(\)/);
assert.match(composition, /modules\.api\.register\(connection, app, transfers\)/);
assert.match(composition, /import \* as scheduler from 'miclash\.scheduler';/,
	'the daemon must import the config auto-update scheduler');
assert.match(composition, /modules\.scheduler\.create\(\{[\s\S]*?subscription: subscription_domain[\s\S]*?\}\)/,
	'the daemon must construct the config scheduler with the canonical subscription domain');
assert.match(composition, /automatic_config: subscription_scheduler_domain\.status\(\)/,
	'diagnostics must expose config auto-update scheduler status');
assert.match(composition, /subscription_scheduler: subscription_scheduler_domain/,
	'the composed daemon must expose ownership of the config scheduler domain');
assert.ok(composition.indexOf('let subscription_domain = modules.subscription.create') <
	composition.indexOf('let subscription_scheduler_domain = modules.scheduler.create'),
	'the config scheduler must be created only after its subscription dependency');
assert.match(daemon, /signal\(['"]SIGTERM['"]/);
assert.match(daemon, /\.cancel\(\)/);
assert.match(daemon, /uloop\.done\(\)/);
assert.match(composition, /connection\.disconnect\(\)/);
assert.ok(composition.indexOf('recover_interrupted()') < composition.indexOf('runtime.ubus.connect()'),
	'operation recovery must finish before ubus publication');
assert.ok(composition.indexOf('runtime.ubus.connect()') < composition.indexOf('modules.api.register(connection, app, transfers)'),
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
assert.match(makefile, /rootfs\/usr\/sbin\/miclashd/,
	'miclashd must be installed at final cutover');
assert.doesNotMatch(api, /\.submit\(|\.stage\(|wait_ready|settings\.set/,
	'api.uc must remain transport-only');
assert.match(checksWorkflow,
	/sudo env\s+\\\s+UCODE_BIN="\$RUNNER_TEMP\/ucode-build\/ucode"\s+\\\s+LD_LIBRARY_PATH="\$RUNNER_TEMP\/ucode-build"\s+\\\s+tools\/run-ucode-tests\.sh/,
	'host ucode tests exercise root-owned runtime authority directories and must run as root');

console.log('ucode layout check passed');
