import { assert_equal, assert_throws } from './testlib.uc';
import * as runtime from 'miclash.runtime';

function flush_probe(marker, error_sequence) {
	return {
		open: (path, mode) => {
			assert_equal(path, '/dev/null');
			assert_equal(mode, 'w');
			let error_index = 0;
			return {
				flush: () => marker,
				error: () => error_sequence?.[error_index++] ?? null,
				close: () => true
			};
		}
	};
};

// ucode before afe4be60628aee70c26896d346a8c102aac38f16 has an
// inverted fflush() result check: success returns null and records the
// current errno. OpenWrt 24 can therefore report EINVAL for a successful
// /dev/null flush. The calibrated null marker remains the reliable signal.
let legacy_flush = runtime.create_flush_adapter(flush_probe(null,
	[ 'No such file or directory', 'Invalid argument' ]));
assert_equal(legacy_flush({ flush: () => null }), true);
assert_equal(legacy_flush({ flush: () => true }), false);

let current_flush = runtime.create_flush_adapter(flush_probe(true));
assert_equal(current_flush({ flush: () => true }), true);
assert_equal(current_flush({ flush: () => null }), false);
assert_throws(() => runtime.create_flush_adapter(flush_probe(true,
	[ null, 'flush failed' ])), 'INTERNAL');
