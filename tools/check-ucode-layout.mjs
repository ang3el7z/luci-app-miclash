import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';

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
assert.ok(composition.indexOf('state_model.flush()') < composition.lastIndexOf('disconnect()'),
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
