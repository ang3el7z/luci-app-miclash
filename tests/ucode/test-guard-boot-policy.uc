import * as test from 'testlib';
import * as fakes from 'fakes';
import * as latch from 'miclash.guard-latch';
import * as policy from 'miclash.guard-boot-policy';

let filesystem = fakes.fs({ '/etc/miclash/guard-safety-latch': 'corrupt' });
let runtime = { fs: filesystem };

test.assert_true(latch.is_set(runtime));
let corrupt_wanted = policy.desired({ guard: { enabled: false } }, latch.is_set(runtime), 'install');
test.assert_true(corrupt_wanted.enabled);
test.assert_equal(corrupt_wanted.source, 'safety_latch');
test.assert_true(!corrupt_wanted.explicit_disable);
test.assert_true(policy.desired({ guard: { enabled: false } }, true, 'disable').enabled);
test.assert_true(policy.desired({ guard: { enabled: false } }, true, 'remove').enabled);

filesystem.unlink('/etc/miclash/guard-safety-latch');
filesystem.set_symlink('/etc/miclash/guard-safety-latch', '/tmp/attacker');
test.assert_true(latch.is_set(runtime));
test.assert_true(policy.desired({ guard: { enabled: false } }, latch.is_set(runtime), 'install').enabled);
filesystem.unlink('/etc/miclash/guard-safety-latch');

test.assert_true(!policy.desired({ guard: { enabled: false } }, false, 'install').enabled);
test.assert_true(!policy.desired({ guard: { enabled: false } }, false, 'disable').enabled);
test.assert_true(!policy.desired({ guard: { enabled: false } }, false, 'remove').enabled);
test.assert_true(policy.desired({ guard: { enabled: true } }, false, 'install').enabled);

// Exercise the real bootstrap transaction using the effective boot decision:
// canonical OFF plus a latch installs and exactly verifies, never removes.
let installed = false, records = [];
let boot_runtime = {
	observers: { guard: {
		verify: (wanted) => wanted.enabled ? installed : !installed,
		install: () => { push(records, 'install'); installed = true; return true; },
		remove: () => { push(records, 'remove'); installed = false; return true; },
		persist: (wanted) => { push(records, 'persist:' + wanted.enabled); return true; },
		record_status: (status) => { push(records, 'status:' + status.enabled); return true; }
	} }
};
test.assert_true(policy.apply(boot_runtime, { guard: { enabled: false } }, true, 'install'));
test.assert_true(installed);
test.assert_equal(sprintf('%J', records), sprintf('%J', [ 'install', 'persist:true', 'status:true' ]));

records = [];
test.assert_true(policy.apply(boot_runtime, { guard: { enabled: false } }, true, 'remove'));
test.assert_true(installed);
test.assert_equal(sprintf('%J', records), sprintf('%J', [ 'persist:true', 'status:true' ]));

// Once an explicit OFF transaction has cleared the latch, disable/remove may
// delete the bootstrap and persist OFF exactly.
records = [];
test.assert_true(policy.apply(boot_runtime, { guard: { enabled: false } }, false, 'remove'));
test.assert_true(!installed);
test.assert_equal(sprintf('%J', records), sprintf('%J', [ 'remove', 'persist:false', 'status:false' ]));
