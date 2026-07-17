import { assert_equal, assert_throws, assert_true } from './testlib.uc';
import * as fakes from './fakes.uc';
import * as readiness from 'miclash.daemon-readiness';

const PATH = '/tmp/miclash/daemon-ready.json';

function runtime(initial) {
	let filesystem = fakes.fs({ '/tmp/miclash/.keep': '', ...(initial ?? {}) });
	return {
		fs: filesystem,
		digest: fakes.digest(filesystem),
		clock: fakes.clock(1700000000000),
		paths: { tmp: '/tmp/miclash', run: '/var/run/miclash' }
	};
};

let stale = runtime({ [PATH]: '{"stale":true}\n' });
let stale_gate = readiness.create(stale);
assert_equal(stale_gate.clear(), true);
assert_equal(stale.fs.lstat(PATH), null, 'stale readiness survived startup clearing');

let failed = runtime({ [PATH]: '{"stale":true}\n' });
let failed_gate = readiness.create(failed), failed_calls = 0;
assert_equal(failed_gate.clear(), true);
assert_throws(() => failed_gate.activate({ startup: () => { failed_calls++; return false; } },
	'daemon-startup'), 'HEALTH_FAILED');
assert_equal(failed_calls, 1);
assert_equal(failed.fs.lstat(PATH), null,
	'failed startup reconciliation published or retained readiness');

let interrupted = runtime();
let interrupted_gate = readiness.create(interrupted);
interrupted.fs.fail_on = 'rename';
assert_throws(() => interrupted_gate.activate({ startup: () => true }, 'daemon-startup'),
	'INTERNAL');
assert_equal(interrupted.fs.lstat(PATH), null,
	'failed atomic readiness publication left a visible marker');

let active = runtime(), observed_before_publish = false;
let active_gate = readiness.create(active);
assert_equal(active_gate.clear(), true);
assert_equal(active_gate.activate({ startup: () => {
	observed_before_publish = active.fs.lstat(PATH) == null;
	return true;
} }, 'daemon-startup'), true);
assert_true(observed_before_publish, 'readiness was published before startup reconciliation');
let marker = json(active.fs.readfile(PATH));
assert_equal(marker.schema_version, 1);
assert_equal(marker.startup_reconciled, true);
assert_equal(marker.ready_at_ms, 1700000000000);
assert_equal(active.fs.mode(PATH), 0o600, 'readiness marker was not private');
assert_equal(active_gate.revoke(), true);
assert_equal(active.fs.lstat(PATH), null, 'shutdown did not revoke readiness');
assert_equal(active_gate.revoke(), true, 'repeated abort/shutdown revoke was not idempotent');
