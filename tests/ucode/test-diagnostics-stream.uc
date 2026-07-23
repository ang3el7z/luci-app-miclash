import { assert_equal, assert_throws, assert_true } from 'testlib';
import * as diagnostics_json from 'miclash.diagnostics-json';
import * as diagnostics from 'miclash.diagnostics';
import * as fakes from 'fakes';

function repeated(value, count) {
	let output = '';
	for (let index = 0; index < count; index++) output += value;
	return output;
};

function minimal_sources() {
	let result = {};
	for (let name in [ 'versions', 'architecture', 'state', 'health', 'memory',
		'updates', 'settings', 'telegram', 'last_repair', 'config', 'process', 'logs', 'uci',
		'operations' ])
		result[name] = () => null;
	return result;
};

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

// A JSON document has exactly one syntactically complete root value.
let empty_root = diagnostics_json.create(runtime, filesystem.open(
	'/tmp/miclash/empty-root.json', 'wx', 0o600));
assert_throws(() => empty_root.finish(), 'INTERNAL');
let multiple_root = diagnostics_json.create(runtime, filesystem.open(
	'/tmp/miclash/multiple-root.json', 'wx', 0o600));
multiple_root.begin_object(); multiple_root.end_object();
assert_throws(() => multiple_root.begin_object(), 'INTERNAL');

let balanced_stage = store.begin({ mode: 'lite', required_bytes: 4096 });
filesystem.write(balanced_stage.handle, '{]'); filesystem.close(balanced_stage.handle);
assert_throws(() => store.finish(balanced_stage.id, { path: balanced_stage.handle.path,
	size: 2, sha256: runtime.digest.sha256_file(balanced_stage.handle.path) }), 'INVALID_RESPONSE');

// Balanced delimiters are not sufficient: validate the complete JSON grammar.
for (let malformed in [
	'{ "a" 1 }', '{ "a": }', '{ "a": 1, }', '[ 1 2 ]', '[ 1, ]',
	'"bad\\xescape"', '"control\ncharacter"', 'tru', 'true false',
	'01', '-.1', '1.', '1e', '1e+', '{} trailing'
]) {
	let malformed_stage = store.begin({ mode: 'lite', required_bytes: 4096 });
	filesystem.write(malformed_stage.handle, malformed);
	filesystem.close(malformed_stage.handle);
	assert_throws(() => store.finish(malformed_stage.id, {
		path: malformed_stage.handle.path, size: length(malformed),
		sha256: runtime.digest.sha256_file(malformed_stage.handle.path)
	}), 'INVALID_RESPONSE');
	assert_equal(length(filesystem.lsdir('/tmp/miclash/diagnostics')), 0,
		'malformed JSON removes staging: ' + malformed);
}

// Every terminal writer error immediately and idempotently removes its stage.
for (let failure in [ 'write', 'close' ]) {
	let failed_stage = store.begin({ mode: 'lite', required_bytes: 4096 });
	let failed_writer = diagnostics_json.create(runtime, failed_stage.handle);
	failed_writer.begin_object();
	filesystem.fail_on = failure;
	assert_throws(() => {
		if (failure == 'write') failed_writer.field('failed', true);
		else { failed_writer.end_object(); failed_writer.finish(); }
	}, 'INTERNAL');
	filesystem.fail_on = null;
	assert_equal(length(filesystem.lsdir('/tmp/miclash/diagnostics')), 0,
		failure + ' failure removes staging immediately');
}
let overflow_stage = store.begin({ mode: 'lite', required_bytes: 4096 });
let overflow_writer = diagnostics_json.create(runtime, overflow_stage.handle);
overflow_writer.begin_object();
assert_throws(() => overflow_writer.field('oversized', repeated('x', 786432)), 'INTERNAL');
assert_equal(length(filesystem.lsdir('/tmp/miclash/diagnostics')), 0,
	'overflow removes staging immediately');

// Validation binds the opened descriptor, not only the pathname.
let descriptor_stage = store.begin({ mode: 'lite', required_bytes: 4096 });
filesystem.write(descriptor_stage.handle, '{}'); filesystem.close(descriptor_stage.handle);
let descriptor_open = filesystem.open;
filesystem.open = (path, mode, perm) => {
	let opened = descriptor_open(path, mode, perm);
	if (opened != null && mode == 're') opened.opened_inode++;
	return opened;
};
assert_throws(() => store.finish(descriptor_stage.id, {
	path: descriptor_stage.handle.path, size: 2,
	sha256: runtime.digest.sha256_file(descriptor_stage.handle.path)
}), 'INTERNAL');
filesystem.open = descriptor_open;
assert_equal(length(filesystem.lsdir('/tmp/miclash/diagnostics')), 0,
	'descriptor substitution removes staging');

let symlink_stage = store.begin({ mode: 'lite', required_bytes: 4096 });
let symlink_writer = diagnostics_json.create(runtime, symlink_stage.handle);
symlink_writer.begin_object(); symlink_writer.end_object();
filesystem.writefile('/tmp/miclash/attacker.json', '{"attacker":true}');
filesystem.set_symlink(symlink_stage.handle.path, '/tmp/miclash/attacker.json');
assert_throws(() => symlink_writer.finish(), 'INTERNAL');
assert_equal(filesystem.readfile('/tmp/miclash/attacker.json'), '{"attacker":true}',
	'symlink target is never removed or modified');
assert_equal(length(filesystem.lsdir('/tmp/miclash/diagnostics')), 0,
	'symlink substitution removes the owned staging entry');

// A mutation after the accepted hash must be caught before publication.
let mutation_stage = store.begin({ mode: 'lite', required_bytes: 4096 });
filesystem.write(mutation_stage.handle, '{"safe":true}'); filesystem.close(mutation_stage.handle);
let mutation_hash = runtime.digest.sha256_file(mutation_stage.handle.path);
let original_sha256_file = runtime.digest.sha256_file, mutate_after_hash = true;
runtime.digest.sha256_file = (path) => {
	let digest = original_sha256_file(path);
	if (mutate_after_hash && path == mutation_stage.handle.path) {
		mutate_after_hash = false;
		filesystem.writefile(path, '{"evil":true}');
	}
	return digest;
};
assert_throws(() => store.finish(mutation_stage.id, {
	path: mutation_stage.handle.path, size: 13, sha256: mutation_hash
}), 'INTERNAL');
runtime.digest.sha256_file = original_sha256_file;
assert_equal(length(filesystem.lsdir('/tmp/miclash/diagnostics')), 0,
	'post-hash mutation is never published');

// Downloads keep only bounded counters and chunks, and never inspect a closed fd.
let download_stage = store.begin({ mode: 'lite', required_bytes: 4096 });
let download_writer = diagnostics_json.create(runtime, download_stage.handle);
download_writer.begin_object();
download_writer.field('payload', repeated('z', 16384));
download_writer.end_object();
let download_report = store.finish(download_stage.id, download_writer.finish());
let data_digest_calls = length(runtime.digest.calls.data);
let original_fstat = filesystem.fstat;
filesystem.fstat = (fd) => {
	if (fd.closed) die('fstat called on closed fd');
	return original_fstat(fd);
};
let download_reader = store.open_report(download_report.id), downloaded = 0;
while (true) {
	let chunk = download_reader.read(257);
	if (!length(chunk)) break;
	downloaded += length(chunk);
}
assert_equal(downloaded, download_report.size);
assert_equal(download_reader.close(), true);
filesystem.fstat = original_fstat;
assert_equal(length(runtime.digest.calls.data), data_digest_calls,
	'download does not materialize and hash the complete report');

let read_failure_stage = store.begin({ mode: 'lite', required_bytes: 4096 });
let read_failure_writer = diagnostics_json.create(runtime, read_failure_stage.handle);
read_failure_writer.begin_object(); read_failure_writer.end_object();
let read_failure_report = store.finish(read_failure_stage.id, read_failure_writer.finish());
let read_failure_reader = store.open_report(read_failure_report.id);
let original_read = filesystem.read, closes_before_read_failure = length(filesystem.calls.close);
filesystem.read = (fd, amount) => null;
assert_throws(() => read_failure_reader.read(64), 'INTERNAL');
filesystem.read = original_read;
assert_equal(length(filesystem.calls.close), closes_before_read_failure + 1,
	'terminal reader failure closes its descriptor');
assert_equal(length(filesystem.lsdir('/tmp/miclash/diagnostics')), 0,
	'terminal reader failure discards the report');

// Stream and legacy stores share names but never recover or delete each other's reports.
let coexist_fs = fakes.fs({});
for (let directory in [ '/tmp', '/tmp/miclash' ]) coexist_fs.mkdir(directory);
coexist_fs.chmod('/tmp/miclash', 0o700);
let coexist_runtime = { fs: coexist_fs, clock: fakes.clock(1), random: fakes.entropy(),
	digest: fakes.digest(coexist_fs), paths: { tmp: '/tmp/miclash' } };
let root = '/tmp/miclash/diagnostics';
coexist_fs.mkdir(root); coexist_fs.chmod(root, 0o700);
let legacy_path = root + '/report-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
coexist_fs.mkdir(legacy_path); coexist_fs.chmod(legacy_path, 0o700);
for (let leaf in [ 'report.json', 'report.txt' ]) {
	let legacy_handle = coexist_fs.open(legacy_path + '/' + leaf, 'wx', 0o600);
	coexist_fs.write(legacy_handle, '{}'); coexist_fs.close(legacy_handle);
}
let coexist_stream = diagnostics.create_store({ ...coexist_runtime,
	storage: { free_blocks: () => 1024 } });
assert_true(coexist_fs.lstat(legacy_path) != null,
	'stream initialization preserves legacy reports');
let coexist_stage = coexist_stream.begin({ mode: 'lite', required_bytes: 4096 });
let coexist_writer = diagnostics_json.create(coexist_runtime, coexist_stage.handle);
coexist_writer.begin_object(); coexist_writer.end_object();
let coexist_report = coexist_stream.finish(coexist_stage.id, coexist_writer.finish());
diagnostics.create({ runtime: coexist_runtime, sources: minimal_sources() });
assert_true(coexist_fs.lstat(legacy_path) == null,
	'legacy initialization recovers its own report');
assert_true(coexist_fs.lstat(coexist_report.path) != null,
	'legacy initialization preserves stream reports');
