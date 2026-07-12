import { assert_equal, assert_true } from 'testlib';

let fs = require('fs');
let ucode = getenv('UCODE_BIN');
let helper = getenv('PWD') + '/luci-app-miclash/rootfs/usr/libexec/miclash/capture.uc';
let output = '/tmp/miclash-capture-task6';

assert_true(type(ucode) == 'string' && length(ucode) > 0, 'UCODE_BIN must be exported');

function capture(limit, timeout, command) {
	let handle = fs.open(output, 'w+x', 0o600);
	assert_true(handle != null, 'capture file must be exclusively created');
	let code = system([ ucode, '--', helper, sprintf('%d', handle.fileno()),
		sprintf('%d', limit), sprintf('%d', timeout), ...command ], timeout + 1000);
	assert_equal(handle.close(), true);
	let content = fs.readfile(output);
	fs.unlink(output);
	return { code, content };
};

// The helper receives only an inherited owned fd, never a pathname, and
// persists no more than limit+1 bytes after a normal verbose child exit.
let truncated = capture(8192, 1000, [ '/usr/bin/head', '-c', '9000', '/dev/zero' ]);
assert_equal(truncated.code, 0);
assert_equal(length(truncated.content), 8193);

// Output beyond pipe capacity cannot grow the file and is bounded by timeout.
let verbose = capture(8192, 100, [ '/usr/bin/head', '-c', '131072', '/dev/zero' ]);
assert_equal(verbose.code, 255);
assert_equal(length(verbose.content), 8193);

// Normal child exit status is preserved, while a bounded timeout is explicit.
let failed = capture(8192, 1000, [ '/bin/false' ]);
assert_equal(failed.code, 1);
assert_equal(length(failed.content), 0);

let timed_out = capture(8192, 25, [ '/bin/sleep', '1' ]);
assert_equal(timed_out.code, 255);
assert_equal(length(timed_out.content), 0);
