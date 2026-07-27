import { assert_equal, assert_true } from 'testlib';

let fs = require('fs');
let ucode = getenv('UCODE_BIN');
let root = getenv('PWD');
let helper = root + '/luci-app-miclash/rootfs/usr/libexec/miclash/validate-config.uc';
let operation = '1700000000000-0000000000000001';
let candidate_dir = '/tmp/miclash/candidates/' + operation;
let candidate = candidate_dir + '/config.yaml';
let validator = '/opt/clash/bin/clash';
let marker = '/tmp/miclash-validate-helper-marker';

function ensure_dir(path) {
	let stat = fs.lstat(path);
	if (stat == null)
		assert_equal(fs.mkdir(path), true);
	else
		assert_equal(stat.type, 'directory');
};

assert_true(type(ucode) == 'string' && length(ucode) > 0);
assert_equal(fs.lstat(validator), null, 'refusing to replace an existing Mihomo binary');
for (let path in [ '/opt', '/opt/clash', '/opt/clash/bin', '/tmp/miclash',
	'/tmp/miclash/candidates', candidate_dir ])
	ensure_dir(path);

let fixture = '#!/bin/sh\n' +
	'printf "%s\\n" "$@" > "' + marker + '"\n' +
	'printf "validator-stdout-secret\\n"\n' +
	'printf "validator-stderr-secret\\n" >&2\n' +
	'content="$(cat "$4")"\n' +
	'if [ "$content" = signal ]; then kill -9 "$$"; fi\n' +
	'if [ "$content" = inner125 ]; then exit 125; fi\n' +
	'exit 7\n';
assert_true(fs.writefile(validator, fixture) > 0);
assert_equal(fs.chmod(validator, 0o700), true);
assert_true(fs.writefile(candidate, 'ordinary\n') > 0);

let code = system([ ucode, '--', helper, candidate ], 31000);
assert_equal(code, 7);
assert_equal(fs.readfile(marker), join('\n', [
	'-d', '/opt/clash', '-f', candidate, '-t', ''
]));

assert_true(fs.writefile(candidate, 'inner125\n') > 0);
assert_equal(system([ ucode, '--', helper, candidate ], 31000), 126);
assert_true(fs.writefile(candidate, 'signal\n') > 0);
assert_equal(system([ ucode, '--', helper, candidate ], 31000), 124);
assert_equal(system([ ucode, '--', helper, '/tmp/not-owned.yaml' ], 1000), 125);

assert_equal(fs.unlink(marker), true);
assert_equal(fs.unlink(candidate), true);
assert_equal(fs.rmdir(candidate_dir), true);
assert_equal(fs.unlink(validator), true);
