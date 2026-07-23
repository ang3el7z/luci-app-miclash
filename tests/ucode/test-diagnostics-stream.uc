import { assert_equal, assert_throws, assert_true } from 'testlib';
import * as diagnostics_json from 'miclash.diagnostics-json';
import * as diagnostics from 'miclash.diagnostics';
import * as fakes from 'fakes';

let filesystem = fakes.fs({});
for (let directory in [ '/tmp', '/tmp/miclash' ])
	if (filesystem.lstat(directory) == null) filesystem.mkdir(directory);
filesystem.chmod('/tmp/miclash', 0o700);

let runtime = {
	fs: filesystem,
	clock: fakes.clock(1700000000000),
	random: fakes.entropy(),
	digest: fakes.digest(filesystem),
	paths: { tmp: '/tmp/miclash' }
};

let path = '/tmp/miclash/stream.json';
let handle = filesystem.open(path, 'wx', 0o600);
let writer = diagnostics_json.create(runtime, handle);
writer.begin_object();
writer.field('schema_version', 4);
writer.begin_array_field('logs');
for (let line in [ 'one', 'two', 'three' ]) writer.item(line);
writer.end_array();
writer.end_object();
let result = writer.finish();
assert_equal(json(filesystem.readfile(result.path)).logs[2], 'three');
assert_equal(result.sha256, runtime.digest.sha256_file(result.path));
assert_equal(result.size, length(filesystem.readfile(result.path)));

let no_space = diagnostics.create_store({ ...runtime,
	storage: { free_blocks: () => 0 }
});
assert_throws(() => no_space.begin({ mode: 'lite', required_bytes: 4096 }),
	'INSUFFICIENT_STORAGE');
assert_equal(length(filesystem.lsdir('/tmp/miclash/diagnostics')), 0,
	'failed staging must be removed');

let store = diagnostics.create_store({ ...runtime,
	storage: { free_blocks: () => 1024 } });
let report = store.begin({ mode: 'lite', required_bytes: 4096 });
assert_true(match(report.id, /^rpt_[0-9a-f]{32}$/));
assert_equal(report.mode, 'lite');
assert_equal(report.downloaded, false);
let output = diagnostics_json.create(runtime, report.handle);
output.begin_object(); output.field('ok', true); output.end_object();
let completed = store.finish(report.id, output.finish());
assert_equal(completed.sha256, runtime.digest.sha256_file(completed.path));
let reader = store.open_report(completed.id);
assert_equal(reader.read(64), '{"ok":true}');
assert_equal(reader.close(), true);
assert_throws(() => store.open_report(completed.id), 'NOT_FOUND');
assert_equal(length(filesystem.lsdir('/tmp/miclash/diagnostics')), 0,
	'a downloaded report is removed');

// Writes may be short, but the writer must never truncate a JSON token.
let short_path = '/tmp/miclash/short.json';
filesystem.write_results = [ 1, 2, 1, 3, 2, 8 ];
let short_writer = diagnostics_json.create(runtime, filesystem.open(short_path, 'wx', 0o600));
short_writer.begin_object(); short_writer.field('value', 'short writes'); short_writer.end_object();
let short_result = short_writer.finish();
assert_equal(json(filesystem.readfile(short_result.path)).value, 'short writes');

let broken_path = '/tmp/miclash/broken.json';
filesystem.fail_on = 'flush';
let broken_writer = diagnostics_json.create(runtime, filesystem.open(broken_path, 'wx', 0o600));
broken_writer.begin_object(); broken_writer.end_object();
assert_throws(() => broken_writer.finish(), 'INTERNAL');
filesystem.fail_on = null;

let abandoned = store.begin({ mode: 'full', required_bytes: 4096 });
assert_equal(length(filesystem.lsdir('/tmp/miclash/diagnostics')), 1);
let restarted = diagnostics.create_store({ ...runtime,
	storage: { free_blocks: () => 1024 } });
assert_equal(length(filesystem.lsdir('/tmp/miclash/diagnostics')), 0,
	'restart removes interrupted staging');

let expiring = restarted.begin({ mode: 'lite', required_bytes: 4096 });
let expiring_writer = diagnostics_json.create(runtime, expiring.handle);
expiring_writer.begin_object(); expiring_writer.end_object();
let expiring_report = restarted.finish(expiring.id, expiring_writer.finish());
runtime.clock.advance(900000);
assert_throws(() => restarted.open_report(expiring_report.id), 'NOT_FOUND');
assert_equal(length(filesystem.lsdir('/tmp/miclash/diagnostics')), 0,
	'expired report is removed');

// Production df uses POSIX pclose() semantics: 0 is success.
let df_filesystem = fakes.fs({});
for (let directory in [ '/tmp', '/tmp/miclash' ]) df_filesystem.mkdir(directory);
df_filesystem.chmod('/tmp/miclash', 0o700);
let df_calls = [];
df_filesystem.popen = (command, mode) => {
	push(df_calls, { command, mode });
	let offset = 0, content = 'Filesystem 1024-blocks Used Available Capacity Mounted on\n' +
		'tmpfs 65536 1 65535 1% /tmp\n';
	return { read: (amount) => {
		let chunk = substr(content, offset, amount); offset += length(chunk); return chunk;
	}, close: () => 0 };
};
let df_runtime = { fs: df_filesystem, clock: fakes.clock(1), random: fakes.entropy(),
	digest: fakes.digest(df_filesystem), paths: { tmp: '/tmp/miclash' } };
let df_store = diagnostics.create_store(df_runtime);
let df_report = df_store.begin({ mode: 'lite', required_bytes: 4096 });
assert_equal(df_calls[0].command, '/bin/df -Pk /tmp');
assert_equal(df_calls[0].mode, 'r');
assert_true(match(df_report.id, /^rpt_[0-9a-f]{32}$/));

// Single-use capability is consumed before a second reader can be issued.
let concurrent_stage = store.begin({ mode: 'lite', required_bytes: 4096 });
let concurrent_output = diagnostics_json.create(runtime, concurrent_stage.handle);
concurrent_output.begin_object(); concurrent_output.field('reader', true); concurrent_output.end_object();
let concurrent = store.finish(concurrent_stage.id, concurrent_output.finish());
let first_reader = store.open_report(concurrent.id);
assert_throws(() => store.open_report(concurrent.id), 'NOT_FOUND');
assert_equal(first_reader.read(64), '{"reader":true}');
assert_equal(first_reader.close(), true);

let failing_stage = store.begin({ mode: 'lite', required_bytes: 4096 });
filesystem.fail_on = 'flush';
let failing_output = diagnostics_json.create(runtime, failing_stage.handle);
failing_output.begin_object(); failing_output.end_object();
assert_throws(() => failing_output.finish(), 'INTERNAL');
filesystem.fail_on = null;
assert_equal(length(filesystem.lsdir('/tmp/miclash/diagnostics')), 0,
	'writer finalization failure removes its staging directory');

let invalid_stage = store.begin({ mode: 'lite', required_bytes: 4096 });
filesystem.write(invalid_stage.handle, '{');
filesystem.close(invalid_stage.handle);
assert_throws(() => store.finish(invalid_stage.id, {
	path: invalid_stage.handle.path, size: 1,
	sha256: runtime.digest.sha256_file(invalid_stage.handle.path)
}), 'INVALID_RESPONSE');
assert_equal(length(filesystem.lsdir('/tmp/miclash/diagnostics')), 0,
	'invalid JSON removes staging');
