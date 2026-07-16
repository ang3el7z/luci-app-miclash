import { assert_equal, assert_true } from './testlib.uc';
import * as latch from 'miclash.guard-latch';
import * as runtime from 'miclash.runtime';
import * as fakes from './fakes.uc';

const PATH = '/etc/miclash/guard-safety-latch';

let filesystem = fakes.fs({});
let clock = fakes.clock(1700000000000);
let options = {
	fs: filesystem, digest: fakes.digest(filesystem), random: fakes.entropy(), clock,
	process: fakes.process(), uci: fakes.uci({}), ubus: { connect: () => null },
	http: { request: () => null }
};
let first = runtime.create(options);
assert_equal(latch.is_set(first), false);
assert_equal(latch.set(first), true);
assert_equal(latch.is_set(first), true);
assert_equal(filesystem.readfile(PATH), 'miclash-guard-safety-latch-v1\n');

// The latch is backend-owned durable state, not daemon memory.
let restarted = runtime.create(options);
assert_equal(latch.is_set(restarted), true);
assert_equal(latch.clear(restarted), true);
assert_equal(latch.is_set(restarted), false);

// Corruption is fail-closed and cannot be cleared as if it were a valid latch.
filesystem.writefile(PATH, 'corrupt\n');
assert_equal(latch.is_set(restarted), true);
assert_equal(latch.clear(restarted), false);
assert_true(filesystem.lstat(PATH) != null);
