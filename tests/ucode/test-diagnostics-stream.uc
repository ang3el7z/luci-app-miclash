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

// A stage is owned as soon as mkdir succeeds, including before report.json
// exists. Chmod/open failures must remove that exact empty stage.
for (let failure in [ 'chmod', 'open' ]) {
	let begin_fs = fakes.fs({});
	for (let directory in [ '/tmp', '/tmp/miclash' ]) begin_fs.mkdir(directory);
	begin_fs.chmod('/tmp/miclash', 0o700);
	let begin_runtime = { fs: begin_fs, clock: fakes.clock(1), random: fakes.entropy(),
		digest: fakes.digest(begin_fs), paths: { tmp: '/tmp/miclash' } };
	let begin_store = diagnostics.create_store({ ...begin_runtime,
		storage: { free_blocks: () => 1024 } });
	if (failure == 'chmod') begin_fs.fail_on = 'chmod';
	else begin_fs.fail_open_once_matching = 'report.json';
	assert_throws(() => begin_store.begin({ mode: 'lite', required_bytes: 4096 }), 'INTERNAL');
	begin_fs.fail_on = null;
	assert_equal(length(begin_fs.lsdir('/tmp/miclash/diagnostics')), 0,
		failure + ' failure removes its empty stream stage');
	diagnostics.create_store({ ...begin_runtime, storage: { free_blocks: () => 1024 } });
	assert_equal(length(begin_fs.lsdir('/tmp/miclash/diagnostics')), 0,
		failure + ' failure remains restart recoverable');
}

let report = store.begin({ mode: 'lite', required_bytes: 4096 });
assert_true(match(report.id, /^rpt_[0-9a-f]{32}$/));
assert_true(match(report.path, /\/\.stream-stage-[0-9a-f]{32}$/),
	'stream stages use a namespace distinct from legacy staging');
assert_equal(report.mode, 'lite');
assert_equal(report.downloaded, false);
let output = diagnostics_json.create(runtime, report.handle);
output.begin_object(); output.field('ok', true); output.end_object();
let completed = store.finish(report.id, output.finish());
assert_equal(completed.sha256, runtime.digest.sha256_file(completed.path));
report.handle.abort();
assert_throws(() => output.field('after_publication', true), 'INTERNAL');
let retained_abort_reader = store.open_report(completed.id);
assert_equal(retained_abort_reader.read(64), '{"ok":true}',
	'post-publication writer misuse cannot remove the published report');
assert_equal(retained_abort_reader.close(), true);
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

// Every integrity failure consumes the published capability, including checks
// that fail before a reader descriptor can be opened.
let mutated_stage = store.begin({ mode: 'lite', required_bytes: 4096 });
let mutated_writer = diagnostics_json.create(runtime, mutated_stage.handle);
mutated_writer.begin_object(); mutated_writer.field('safe', true); mutated_writer.end_object();
let mutated_report = store.finish(mutated_stage.id, mutated_writer.finish());
filesystem.writefile(mutated_report.path, '{"evil":true}');
assert_throws(() => store.open_report(mutated_report.id), 'INTERNAL');
assert_equal(filesystem.lstat(mutated_report.path), null,
	'pre-open mutation discards the published report');
assert_throws(() => store.open_report(mutated_report.id), 'NOT_FOUND');

let substituted_stage = store.begin({ mode: 'lite', required_bytes: 4096 });
let substituted_writer = diagnostics_json.create(runtime, substituted_stage.handle);
substituted_writer.begin_object(); substituted_writer.end_object();
let substituted_report = store.finish(substituted_stage.id, substituted_writer.finish());
filesystem.bump_inode(substituted_report.path);
assert_throws(() => store.open_report(substituted_report.id), 'INTERNAL');
assert_true(filesystem.lstat(substituted_report.path) != null,
	'pre-open cleanup never deletes a substituted regular-file target');
assert_throws(() => store.open_report(substituted_report.id), 'NOT_FOUND');

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

// Interrupted legacy and stream stages have durable, unambiguous ownership.
let ownership_fs = fakes.fs({});
for (let directory in [ '/tmp', '/tmp/miclash' ]) ownership_fs.mkdir(directory);
ownership_fs.chmod('/tmp/miclash', 0o700);
let ownership_runtime = { fs: ownership_fs, clock: fakes.clock(1), random: fakes.entropy(),
	digest: fakes.digest(ownership_fs), paths: { tmp: '/tmp/miclash' } };
let ownership_root = '/tmp/miclash/diagnostics';
ownership_fs.mkdir(ownership_root); ownership_fs.chmod(ownership_root, 0o700);
let legacy_stage = ownership_root + '/.stage-11111111111111111111111111111111';
ownership_fs.mkdir(legacy_stage); ownership_fs.chmod(legacy_stage, 0o700);
let legacy_partial = ownership_fs.open(legacy_stage + '/report.json', 'wx', 0o600);
ownership_fs.write(legacy_partial, '{}'); ownership_fs.close(legacy_partial);
diagnostics.create_store({ ...ownership_runtime, storage: { free_blocks: () => 1024 } });
assert_true(ownership_fs.lstat(legacy_stage) != null,
	'stream-first recovery preserves a legacy partial report.json stage');
diagnostics.create({ runtime: ownership_runtime, sources: minimal_sources() });
assert_equal(ownership_fs.lstat(legacy_stage), null,
	'legacy recovery removes its partial report.json stage');

let stream_stage = ownership_root + '/.stream-stage-22222222222222222222222222222222';
ownership_fs.mkdir(stream_stage);
diagnostics.create({ runtime: ownership_runtime, sources: minimal_sources() });
assert_true(ownership_fs.lstat(stream_stage) != null,
	'legacy-first recovery preserves an empty stream stage');
diagnostics.create_store({ ...ownership_runtime, storage: { free_blocks: () => 1024 } });
assert_equal(ownership_fs.lstat(stream_stage), null,
	'stream recovery removes its owned empty stage');

// Versions before the stream namespace split published one-file reports under
// report-<token>. Either initializer must safely retire that obsolete shape.
for (let initializer in [ 'legacy', 'stream' ]) {
	let token = initializer == 'legacy' ?
		'33333333333333333333333333333333' : '44444444444444444444444444444444';
	let old_stream = ownership_root + '/report-' + token;
	ownership_fs.mkdir(old_stream); ownership_fs.chmod(old_stream, 0o700);
	let old_leaf = ownership_fs.open(old_stream + '/report.json', 'wx', 0o600);
	ownership_fs.write(old_leaf, '{}'); ownership_fs.close(old_leaf);
	if (initializer == 'legacy')
		diagnostics.create({ runtime: ownership_runtime, sources: minimal_sources() });
	else
		diagnostics.create_store({ ...ownership_runtime, storage: { free_blocks: () => 1024 } });
	assert_equal(ownership_fs.lstat(old_stream), null,
		initializer + ' initialization retires old one-file stream reports');
}

// Reverse initialization order with complete reports: legacy initializes
// first, then stream recovery removes only its own completed restart debris.
let reverse_stream = ownership_root + '/stream-report-55555555555555555555555555555555';
ownership_fs.mkdir(reverse_stream); ownership_fs.chmod(reverse_stream, 0o700);
let reverse_stream_leaf = ownership_fs.open(reverse_stream + '/report.json', 'wx', 0o600);
ownership_fs.write(reverse_stream_leaf, '{}'); ownership_fs.close(reverse_stream_leaf);
diagnostics.create({ runtime: ownership_runtime, sources: minimal_sources() });
assert_true(ownership_fs.lstat(reverse_stream) != null,
	'legacy-first initialization preserves a complete stream report');
let reverse_legacy = ownership_root + '/report-66666666666666666666666666666666';
ownership_fs.mkdir(reverse_legacy); ownership_fs.chmod(reverse_legacy, 0o700);
for (let leaf in [ 'report.json', 'report.txt' ]) {
	let reverse_legacy_leaf = ownership_fs.open(reverse_legacy + '/' + leaf, 'wx', 0o600);
	ownership_fs.write(reverse_legacy_leaf, '{}'); ownership_fs.close(reverse_legacy_leaf);
}
diagnostics.create_store({ ...ownership_runtime, storage: { free_blocks: () => 1024 } });
assert_equal(ownership_fs.lstat(reverse_stream), null,
	'stream recovery removes its own complete restart debris');
assert_true(ownership_fs.lstat(reverse_legacy) != null,
	'stream initialization preserves a complete legacy report');

// Simulate a process stop immediately after mkdir, before begin() can enter its
// guarded chmod/open block. A fresh initializer must recover the empty stage.
let crash_fs = fakes.fs({});
for (let directory in [ '/tmp', '/tmp/miclash' ]) crash_fs.mkdir(directory);
crash_fs.chmod('/tmp/miclash', 0o700);
let crash_runtime = { fs: crash_fs, clock: fakes.clock(1), random: fakes.entropy(),
	digest: fakes.digest(crash_fs), paths: { tmp: '/tmp/miclash' } };
let crash_store = diagnostics.create_store({ ...crash_runtime,
	storage: { free_blocks: () => 1024 } });
crash_fs.on_mkdir = (path) => {
	if (match(path, /\/\.stream-stage-/)) die('INTERNAL');
};
assert_throws(() => crash_store.begin({ mode: 'lite', required_bytes: 4096 }), 'INTERNAL');
crash_fs.on_mkdir = null;
assert_equal(length(crash_fs.lsdir('/tmp/miclash/diagnostics')), 1,
	'process-stop injection leaves the empty stage for restart recovery');
diagnostics.create_store({ ...crash_runtime, storage: { free_blocks: () => 1024 } });
assert_equal(length(crash_fs.lsdir('/tmp/miclash/diagnostics')), 0,
	'restart removes the injected empty stream stage');
