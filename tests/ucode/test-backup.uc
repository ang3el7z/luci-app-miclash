import { assert_equal, assert_match, assert_throws, assert_true } from 'testlib';
import * as backup from 'miclash.backup';
import * as fakes from 'fakes';
import * as mutation_lock_module from 'miclash.mutation_lock';
import * as operations_module from 'miclash.operations';
import * as settings from 'miclash.settings';
import { rand } from 'math';

for (let method in [ 'list', 'create', 'inspect', 'restore', 'prune' ])
	assert_equal(type(backup[method]), 'function', method + ' is exported');

function clone(value) {
	return json(sprintf('%J', value));
};

function mkdirs(filesystem, paths) {
	for (let path in paths) {
		if (filesystem.lstat(path) == null)
			assert_equal(filesystem.mkdir(path), true);
		filesystem.chmod(path, 0o700);
		filesystem.set_uid(path, 0);
	}
};

function archive_adapter(filesystem) {
	let adapter = {
		calls: [], fail_on: null, override_entries: null,
		on_list: null, on_extract: null
	};
	adapter.create = (request) => {
		push(adapter.calls, { operation: 'create', request: clone(request) });
		if (adapter.fail_on == 'create') die('INTERNAL');
		let entries = [];
		for (let name in request.members) {
			let content = filesystem.readfile(request.root + '/' + name);
			push(entries, {
				name, type: 'file', size: length(content), linkname: null,
				sparse: false, pax: false, content
			});
		}
		filesystem.files[request.archive] = sprintf('%J', { entries });
		filesystem.chmod(request.archive, 0o600);
		filesystem.set_uid(request.archive, 0);
		if (adapter.fail_on == 'create_after_write') die('INTERNAL');
		return true;
	};
	adapter.list = (request) => {
		push(adapter.calls, { operation: 'list', request: clone(request) });
		if (adapter.fail_on == 'list') die('INTERNAL');
		let decoded = json(filesystem.readfile(request.archive));
		let entries = adapter.override_entries ?? decoded.entries;
		let output = [];
		for (let entry in entries) {
			let item = clone(entry);
			delete item.content;
			push(output, item);
		}
		if (type(adapter.on_list) == 'function') adapter.on_list(request);
		return output;
	};
	adapter.extract = (request) => {
		push(adapter.calls, { operation: 'extract', request: clone(request) });
		if (adapter.fail_on == 'extract') die('INTERNAL');
		let decoded = json(filesystem.readfile(request.archive));
		for (let name in request.members) {
			let found = null;
			for (let entry in decoded.entries)
				if (entry.name == name) found = entry;
			if (found == null) die('INTERNAL');
			let parts = split(name, '/'), directory = request.destination;
			pop(parts);
			for (let part in parts) {
				directory += '/' + part;
				if (filesystem.lstat(directory) == null) filesystem.mkdir(directory);
				filesystem.chmod(directory, 0o700);
				filesystem.set_uid(directory, 0);
			}
			let path = request.destination + '/' + name;
			filesystem.files[path] = found.content;
			filesystem.chmod(path, 0o400);
			filesystem.set_uid(path, 0);
		}
		if (adapter.fail_on == 'extract_after_write_manifest' &&
		    request.members[0] == 'manifest.json') {
			filesystem.files[request.destination + '/adapter-junk'] = 'junk';
			die('INTERNAL');
		}
		if (adapter.fail_on == 'extract_after_write_files' &&
		    request.members[0] != 'manifest.json') {
			filesystem.files[request.destination + '/adapter-junk'] = 'junk';
			die('INTERNAL');
		}
		if (type(adapter.on_extract) == 'function') adapter.on_extract(request);
		return true;
	};
	return adapter;
};

function make_app() {
	let filesystem = fakes.fs({
		'/opt/clash/config.yaml': 'port: 7890\nsecret: controller-password\n',
		'/opt/clash/config2.yaml': 'port: 7891\n',
		'/opt/clash/lst/local.txt': 'DOMAIN-SUFFIX,example.test\n'
	});
	mkdirs(filesystem, [
		'/etc', '/etc/miclash', '/opt', '/opt/clash', '/opt/clash/lst',
		'/tmp', '/tmp/miclash', '/var', '/var/run', '/var/run/miclash'
	]);
	for (let path in [ '/opt/clash/config.yaml', '/opt/clash/config2.yaml',
		'/opt/clash/lst/local.txt' ]) {
		filesystem.chmod(path, 0o600);
		filesystem.set_uid(path, 0);
	}
	let runtime = {
		fs: filesystem,
		clock: fakes.clock(1700000000000),
		random: fakes.entropy(),
		digest: fakes.digest(filesystem),
		uci: fakes.uci({ miclash: {
			core: { '.type': 'core', subscription_url: 'https://user:pass@example.test/sub' },
			guard: { '.type': 'guard', enabled: '1' },
			telegram: { '.type': 'telegram', enabled: '1', token: 'telegram-secret', user_id: '42' },
			meta: { '.type': 'meta', schema_version: '1' }
		} }),
		paths: { etc: '/etc/miclash', tmp: '/tmp/miclash', run: '/var/run/miclash' }
	};
	let archive = archive_adapter(filesystem);
	let config_validator = {
		calls: [], fail: false,
		validate_in_operation: function(ctx, profile, content) {
			push(this.calls, { profile, content });
			return this.fail ? { ok: false } : { ok: true };
		}
	};
	let ruleset_validator = {
		calls: [], fail: false,
		validate: function(name, content) {
			push(this.calls, { name, content });
			return !this.fail;
		}
	};
	let operations = { calls: [], fail: false };
	operations.submit = function(kind, source, context, worker) {
		push(this.calls, { kind, source, context: clone(context) });
		if (this.fail) die('INTERNAL');
		let completed = null, ctx = {
			id: '1700000000000-00000001-0000000000000001',
			stage: () => true,
			complete: (error) => completed = error
		};
		let result = worker(ctx);
		return { kind, source, context, result, error: completed };
	};
	let lock = { calls: [], fail: false };
	lock.with_lock = function(runtime, options, callback) {
		push(this.calls, clone(options));
		if (this.fail) die('BUSY');
		return callback();
	};
	let reconcile = { calls: [], fail: false };
	reconcile.run = function(reason) {
		push(this.calls, reason);
		if (this.fail) die('INTERNAL');
		return { state: 'queued' };
	};
	let app = {
		runtime, archive, app_version: '0.9.2', settings,
		config: config_validator, rulesets: ruleset_validator,
		operations, lock, reconcile
	};
	return { app, filesystem, archive, runtime };
};

let base = make_app();
assert_throws(() => backup.create({}, null, 'luci'), 'INVALID_ARGUMENT');
let created = backup.create(base.app, null, 'luci');
assert_match(created.id, /^b-[0-9]{13}-[0-9a-f]{32}$/);
assert_equal(length(backup.list(base.app)), 1);
assert_equal(backup.list(base.app)[0].id, created.id);
let create_call = null;
for (let call in base.archive.calls)
	if (call.operation == 'create') create_call = call;
assert_true(create_call != null);
assert_equal(create_call.request.members[length(create_call.request.members) - 1], 'manifest.json',
	'manifest must be archived last');
let archive_bytes = base.filesystem.readfile('/etc/miclash/backups/' + created.id + '.tar');
assert_true(index(archive_bytes, 'telegram-secret') < 0, 'default backup leaked token');
assert_true(index(archive_bytes, 'controller-password') < 0, 'default backup leaked config secret');
assert_true(index(archive_bytes, 'user:pass') < 0, 'default backup leaked subscription secret');
assert_true(index(archive_bytes, '"token"') < 0, 'default backup retained secret token field');
assert_true(index(archive_bytes, 'subscription_url') < 0,
	'default backup retained secret subscription field');
assert_equal(sprintf('%J', created.includes), sprintf('%J', [ 'rulesets', 'settings' ]));

let preserve_secrets = make_app();
let public_backup = backup.create(preserve_secrets.app, null, 'luci');
let public_preview = backup.inspect(preserve_secrets.app, public_backup.id);
preserve_secrets.app.settings.save(preserve_secrets.runtime,
	{ telegram: { token: 'new-current-secret' } });
backup.restore(preserve_secrets.app, public_preview.id, null, 'luci');
assert_equal(preserve_secrets.app.settings.load(preserve_secrets.runtime).telegram.token,
	'new-current-secret', 'default restore must preserve current secret values');

let secret_base = make_app();
let secret_created = backup.create(secret_base.app, { include_secrets: true }, 'luci');
let secret_bytes = secret_base.filesystem.readfile(
	'/etc/miclash/backups/' + secret_created.id + '.tar');
assert_true(index(secret_bytes, 'telegram-secret') >= 0);
assert_true(index(secret_bytes, 'controller-password') >= 0);
assert_equal(sprintf('%J', secret_created.includes),
	sprintf('%J', [ 'configs', 'rulesets', 'settings' ]));
let secret_preview = backup.inspect(secret_base.app, secret_created.id);
let secret_paths = 0;
for (let file in secret_preview.files)
	if (file.secret) secret_paths++;
assert_true(secret_paths >= 2, 'inspection must visibly identify secret members');

let failed_create = make_app();
failed_create.archive.fail_on = 'create';
assert_throws(() => backup.create(failed_create.app, null, 'luci'), 'INTERNAL');
assert_equal(length(backup.list(failed_create.app)), 0);

let partial_create = make_app();
partial_create.archive.fail_on = 'create_after_write';
assert_throws(() => backup.create(partial_create.app, null, 'luci'), 'INTERNAL');
for (let name in partial_create.filesystem.lsdir('/etc/miclash/backups'))
	assert_true(index(name, '.miclash.') < 0, 'recognizable partial archive survived cleanup');

let post_publish_cleanup = make_app();
post_publish_cleanup.filesystem.fail_rmdir_once = true;
assert_throws(() => backup.create(post_publish_cleanup.app, null, 'luci'), 'INTERNAL');
assert_equal(length(backup.list(post_publish_cleanup.app)), 1,
	'a fully published backup must survive staging cleanup failure');

let stage_failure = make_app();
stage_failure.filesystem.throw_after_rename_once_matching = '/backup-create/';
assert_throws(() => backup.create(stage_failure.app, null, 'luci'), 'INTERNAL');
assert_equal(length(stage_failure.filesystem.lsdir('/tmp/miclash/backup-create')), 0,
	'stage write-then-fail must remove the authenticated destination');
assert_equal(length(backup.list(stage_failure.app)), 0);

function entry(name, content) {
	return {
		name, type: 'file', size: length(content), linkname: null,
		sparse: false, pax: false, content
	};
};

function seed_import(box, id, manifest, files, overrides) {
	mkdirs(box.filesystem, [ '/tmp/miclash/imports' ]);
	let entries = [];
	for (let path, content in files)
		push(entries, entry(path, content));
	push(entries, entry('manifest.json', sprintf('%J\n', manifest)));
	if (overrides?.entries != null) entries = overrides.entries;
	let archive_path = '/tmp/miclash/imports/' + id + '.tar';
	box.filesystem.files[archive_path] = overrides?.archive_bytes ?? sprintf('%J', { entries });
	box.filesystem.chmod(archive_path, 0o600);
	box.filesystem.set_uid(archive_path, 0);
	let bytes = box.filesystem.readfile(archive_path);
	let sidecar = {
		schema: 1, id, created_at: manifest.created_at,
		app_version: manifest.app_version, includes: manifest.includes,
		file_count: length(manifest.files), size: length(bytes),
		sha256: box.runtime.digest.sha256(bytes)
	};
	let sidecar_path = '/tmp/miclash/imports/' + id + '.json';
	box.filesystem.files[sidecar_path] = sprintf('%J\n', sidecar);
	box.filesystem.chmod(sidecar_path, 0o600);
	box.filesystem.set_uid(sidecar_path, 0);
	return { archive_path, sidecar_path, entries };
};

function valid_import(box, suffix) {
	let fixture = json(require('fs').readfile('tests/fixtures/backup/manifest-v1.json'));
	let id = 'i-1700000000000-' + (suffix ?? '00000000000000000000000000000001');
	seed_import(box, id, fixture, { 'settings/settings.json': '{ }\n' });
	return { id, manifest: fixture };
};

let preview_box = make_app();
let imported = valid_import(preview_box);
let preview = backup.inspect(preview_box.app, imported.id);
assert_match(preview.id, /^x-[0-9]{13}-[0-9a-f]{32}$/);
assert_equal(preview.source_id, imported.id);
assert_equal(preview.files[0].path, 'settings/settings.json');
assert_equal(preview.files[0].secret, false);
assert_true(preview.expires_at > preview.created_at);
assert_throws(() => backup.inspect(preview_box.app,
	'/tmp/miclash/imports/' + imported.id + '.tar'), 'INVALID_ARGUMENT');

function mismatched_sidecar(field, value, suffix) {
	let box = make_app(), imported = valid_import(box, suffix);
	let path = '/tmp/miclash/imports/' + imported.id + '.json';
	let sidecar = json(box.filesystem.readfile(path));
	sidecar[field] = value;
	box.filesystem.files[path] = sprintf('%J\n', sidecar);
	assert_throws(() => backup.inspect(box.app, imported.id), 'VALIDATION_FAILED');
};
mismatched_sidecar('created_at', 1700000000001,
	'00000000000000000000000000000011');
mismatched_sidecar('app_version', '0.9.3',
	'00000000000000000000000000000012');
mismatched_sidecar('includes', [ 'configs' ],
	'00000000000000000000000000000013');
mismatched_sidecar('file_count', 2,
	'00000000000000000000000000000014');

function rejected_entries(mutator, code, manifest_only) {
	let box = make_app(), imported = valid_import(box);
	let original = clone(box.archive.list({
		archive: '/tmp/miclash/imports/' + imported.id + '.tar'
	}));
	box.archive.calls = [];
	mutator(original, imported.manifest, box);
	box.archive.override_entries = original;
	assert_throws(() => backup.inspect(box.app, imported.id), code ?? 'VALIDATION_FAILED');
	let extracted = false, extracted_members = [];
	for (let call in box.archive.calls)
		if (call.operation == 'extract') {
			extracted = true;
			extracted_members = call.request.members;
		}
	if (manifest_only)
		assert_equal(sprintf('%J', extracted_members), sprintf('%J', [ 'manifest.json' ]));
	else
		assert_equal(extracted, false, 'hostile archive reached extraction');
};

for (let hostile in [
	'/absolute', '../escape', 'settings/../escape', 'settings//settings.json',
	'C:/drive', 'settings\\settings.json', 'settings/\u0430ettings.json',
	'./manifest.json', 'settings/settings.json/'
])
	rejected_entries((entries) => entries[0].name = hostile);

for (let hostile_type in [ 'symlink', 'hardlink', 'char', 'block', 'fifo', 'socket',
	'pax', 'unknown' ])
	rejected_entries((entries) => entries[0].type = hostile_type);

rejected_entries((entries) => push(entries, clone(entries[0])));
rejected_entries((entries) => entries[0].sparse = true);
rejected_entries((entries) => entries[0].pax = true);
rejected_entries((entries) => entries[0].linkname = '../escape');
rejected_entries((entries) => entries[0].size = 4194305, 'RESPONSE_TOO_LARGE');
rejected_entries((entries) => entries[0].unexpected = true);
rejected_entries((entries) => entries[0].size++, 'VALIDATION_FAILED', true);
rejected_entries((entries) => pop(entries));
rejected_entries((entries) => push(entries, entry('rulesets/extra.txt', 'extra\n')),
	'VALIDATION_FAILED', true);
rejected_entries((entries) => entries[1].size = 65537, 'RESPONSE_TOO_LARGE');
rejected_entries((entries) => {
	for (let index = 0; index < 1024; index++)
		push(entries, {
			name: sprintf('rulesets/x%d.txt', index), type: 'file', size: 0,
			linkname: null, sparse: false, pax: false
		});
}, 'RESPONSE_TOO_LARGE');
rejected_entries((entries) => {
	for (let index = 0; index < 5; index++)
		push(entries, {
			name: sprintf('rulesets/large%d.txt', index), type: 'file', size: 4194304,
			linkname: null, sparse: false, pax: false
		});
}, 'RESPONSE_TOO_LARGE');

function rejected_manifest(mutator, code) {
	let box = make_app(), imported = valid_import(box);
	let decoded = json(box.filesystem.readfile(imported.id ?
		'/tmp/miclash/imports/' + imported.id + '.tar' : ''));
	let manifest_entry = null;
	for (let item in decoded.entries)
		if (item.name == 'manifest.json') manifest_entry = item;
	let manifest = json(manifest_entry.content);
	mutator(manifest);
	manifest_entry.content = sprintf('%J\n', manifest);
	manifest_entry.size = length(manifest_entry.content);
	let path = '/tmp/miclash/imports/' + imported.id + '.tar';
	box.filesystem.files[path] = sprintf('%J', decoded);
	let sidecar = json(box.filesystem.readfile('/tmp/miclash/imports/' + imported.id + '.json'));
	sidecar.size = length(box.filesystem.files[path]);
	sidecar.sha256 = box.runtime.digest.sha256(box.filesystem.files[path]);
	box.filesystem.files['/tmp/miclash/imports/' + imported.id + '.json'] = sprintf('%J\n', sidecar);
	assert_throws(() => backup.inspect(box.app, imported.id), code ?? 'VALIDATION_FAILED');
};

rejected_manifest((manifest) => manifest.schema = 2);
rejected_manifest((manifest) => manifest.extra = true);
rejected_manifest((manifest) => manifest.files[0].extra = true);
rejected_manifest((manifest) => manifest.files[0].sha256 =
	'0000000000000000000000000000000000000000000000000000000000000000');
rejected_manifest((manifest) => manifest.files[0].size++);
rejected_manifest((manifest) => push(manifest.files, clone(manifest.files[0])));
rejected_manifest((manifest) => push(manifest.includes, manifest.includes[0]));
rejected_manifest((manifest) => manifest.includes = [ 'future' ]);

let duplicate_json = make_app(), duplicate_import = valid_import(duplicate_json);
let duplicate_path = '/tmp/miclash/imports/' + duplicate_import.id + '.tar';
let duplicate_archive = json(duplicate_json.filesystem.readfile(duplicate_path));
for (let item in duplicate_archive.entries)
	if (item.name == 'manifest.json') {
		item.content = '{"schema":1,"schema":1,"created_at":1700000000000,' +
			'"app_version":"0.9.2","includes":["settings"],"files":[' +
			'{"path":"settings/settings.json","size":4,' +
			'"sha256":"1d6faa9e1a76d13f3ab8558a3640158b1f0a54f624a4e37ddc3ef41ed4191058",' +
			'"secret":false}]}\n';
		item.size = length(item.content);
	}
duplicate_json.filesystem.files[duplicate_path] = sprintf('%J', duplicate_archive);
let duplicate_sidecar = json(duplicate_json.filesystem.readfile(
	'/tmp/miclash/imports/' + duplicate_import.id + '.json'));
duplicate_sidecar.size = length(duplicate_json.filesystem.files[duplicate_path]);
duplicate_sidecar.sha256 = duplicate_json.runtime.digest.sha256(
	duplicate_json.filesystem.files[duplicate_path]);
duplicate_json.filesystem.files['/tmp/miclash/imports/' + duplicate_import.id + '.json'] =
	sprintf('%J\n', duplicate_sidecar);
assert_throws(() => backup.inspect(duplicate_json.app, duplicate_import.id), 'VALIDATION_FAILED');

let corrupt_tar = make_app(), corrupt_import = valid_import(corrupt_tar);
corrupt_tar.archive.fail_on = 'list';
assert_throws(() => backup.inspect(corrupt_tar.app, corrupt_import.id), 'CORRUPT_STATE');

let extract_failure = make_app(), extract_import = valid_import(extract_failure);
extract_failure.archive.fail_on = 'extract';
assert_throws(() => backup.inspect(extract_failure.app, extract_import.id), 'CORRUPT_STATE');

for (let partial_failure in [ 'extract_after_write_manifest', 'extract_after_write_files' ]) {
	let partial = make_app(), partial_import = valid_import(partial);
	partial.archive.fail_on = partial_failure;
	assert_throws(() => backup.inspect(partial.app, partial_import.id), 'CORRUPT_STATE');
	assert_equal(length(partial.filesystem.lsdir('/tmp/miclash/backup-inspected')), 0,
		'partial extraction must remove known and unknown adapter output');
}

let archive_swap = make_app(), swap_import = valid_import(archive_swap);
archive_swap.archive.on_list = (request) =>
	archive_swap.filesystem.files[request.archive] += 'trailing';
assert_throws(() => backup.inspect(archive_swap.app, swap_import.id), 'CORRUPT_STATE');

let extracted_link = make_app(), link_import = valid_import(extracted_link);
let link_path = null, original_chmod = extracted_link.filesystem.chmod;
extracted_link.filesystem.chmod = (path, mode) => {
	if (path == link_path) original_chmod('/opt/clash/config.yaml', mode);
	return original_chmod(path, mode);
};
extracted_link.archive.on_extract = (request) => {
	if (length(request.members) == 1 && request.members[0] == 'settings/settings.json')
		link_path = request.destination + '/settings/settings.json';
	if (link_path != null)
		extracted_link.filesystem.set_symlink(link_path, '/opt/clash/config.yaml');
};
assert_throws(() => backup.inspect(extracted_link.app, link_import.id), 'CORRUPT_STATE');
assert_equal(extracted_link.filesystem.mode('/opt/clash/config.yaml'), 0o600,
	'inspection must not chmod through an extracted symlink');
assert_equal(length(extracted_link.filesystem.lsdir('/tmp/miclash/backup-inspected')), 0,
	'hostile extraction staging must be removed without following its symlink');

let extracted_hardlink = make_app(), hardlink_import = valid_import(extracted_hardlink);
extracted_hardlink.archive.on_extract = (request) => {
	if (request.members[0] == 'settings/settings.json')
		extracted_hardlink.filesystem.set_nlink(
			request.destination + '/settings/settings.json', 2);
};
assert_throws(() => backup.inspect(extracted_hardlink.app,
	hardlink_import.id), 'CORRUPT_STATE');
assert_equal(length(extracted_hardlink.filesystem.lsdir('/tmp/miclash/backup-inspected')), 0,
	'extracted hardlink must be unlinked without touching aliases');

function custom_manifest(box, files) {
	let records = [], includes = [];
	for (let path in files) {
		let secret = substr(path, 0, 8) == 'configs/' || path == 'settings/settings.json';
		push(records, {
			path, size: length(files[path]), sha256: box.runtime.digest.sha256(files[path]), secret
		});
		let include = split(path, '/')[0], present = false;
		for (let value in includes) if (value == include) present = true;
		if (!present) push(includes, include);
	}
	sort(records, (left, right) => left.path < right.path ? -1 : 1);
	sort(includes, (left, right) => left < right ? -1 : 1);
	return {
		schema: 1, created_at: 1700000000000, app_version: '0.9.2',
		includes, files: records
	};
};

function inspected_restore(files, suffix) {
	let box = make_app(), manifest = custom_manifest(box, files);
	let id = 'i-1700000000000-' + (suffix ?? '00000000000000000000000000000002');
	seed_import(box, id, manifest, files);
	let preview = backup.inspect(box.app, id);
	return { box, preview, manifest };
};

let restored = inspected_restore({
	'configs/config.yaml': 'port: 9999\n',
	'rulesets/restored.txt': 'DOMAIN,restored.test\n',
	'settings/settings.json': '{ "guard": { "enabled": false } }\n'
});
let restore_result = backup.restore(restored.box.app, restored.preview.id, null, 'luci');
assert_equal(restore_result.kind, 'backup.restore');
assert_equal(restored.box.filesystem.readfile('/opt/clash/config.yaml'), 'port: 9999\n');
assert_equal(restored.box.filesystem.readfile('/opt/clash/lst/restored.txt'),
	'DOMAIN,restored.test\n');
assert_equal(restored.box.runtime.uci.commit_calls, 1, 'UCI must commit exactly once');
assert_equal(length(restored.box.app.operations.calls), 1);
assert_equal(length(restored.box.app.lock.calls), 1);
assert_equal(length(restored.box.app.reconcile.calls), 1);
assert_equal(restored.box.app.reconcile.calls[0], 'backup_restore');
assert_equal(length(backup.list(restored.box.app)), 1, 'pre-restore snapshot must remain visible');
assert_true(index(restored.box.filesystem.readfile(
	'/etc/miclash/backups/' + backup.list(restored.box.app)[0].id + '.tar'),
	'controller-password') >= 0, 'pre-restore snapshot must retain recovery data');
assert_throws(() => backup.restore(restored.box.app,
	'/tmp/miclash/backup-inspected/' + restored.preview.id), 'INVALID_ARGUMENT');

let queued_restore = inspected_restore({
	'configs/config.yaml': 'port: 10001\n',
	'settings/settings.json': '{ "guard": { "enabled": false } }\n'
}, '00000000000000000000000000000017');
let real_operations = operations_module.create(queued_restore.box.runtime);
queued_restore.box.app.operations = real_operations;
let integration_boot = '12345678-1234-1234-1234-123456789abc';
let integration_pid = 401, integration_start = 900;
mkdirs(queued_restore.box.filesystem,
	[ '/proc', '/proc/sys', '/proc/sys/kernel', '/proc/sys/kernel/random', '/proc/401' ]);
queued_restore.box.filesystem.files['/proc/sys/kernel/random/boot_id'] = integration_boot + '\n';
queued_restore.box.filesystem.files['/proc/401/stat'] = integration_pid +
	' (backup integration) S ' + join(' ', [ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
		0, 0, 0, 0, 0, 0, 0, 0, integration_start ]) + '\n';
queued_restore.box.runtime.mutation_lock_self = {
	boot: integration_boot, pid: integration_pid, start: integration_start
};
queued_restore.box.app.lock = mutation_lock_module;
queued_restore.box.app.config.validate_in_operation = (ctx, profile, content) => {
	assert_true(real_operations.is_context(ctx), 'config validation requires live operation context');
	return { ok: true };
};
let queued_record = backup.restore(queued_restore.box.app,
	queued_restore.preview.id, null, 'system');
assert_equal(queued_record.state, 'queued');
assert_true(index(queued_restore.box.filesystem.readfile('/opt/clash/config.yaml'),
	'controller-password') >= 0, 'queued restore mutated Active before operation start');
queued_restore.box.runtime.clock.advance(0);
let finished_record = real_operations.get(queued_record.id);
assert_equal(finished_record.state, 'success');
assert_equal(queued_restore.box.filesystem.readfile('/opt/clash/config.yaml'), 'port: 10001\n');
assert_equal(queued_restore.box.runtime.uci.commit_calls, 1);
assert_equal(length(queued_restore.box.app.reconcile.calls), 1);
assert_equal(finished_record.timeline[length(finished_record.timeline) - 1].stage, 'complete');
assert_equal(queued_restore.box.filesystem.lstat('/var/run/miclash/mutation.lock'), null,
	'real mutation lock must be released after queued restore');

let invalid_config = inspected_restore({
	'configs/config.yaml': 'invalid: true\n',
	'settings/settings.json': '{ }\n'
}, '00000000000000000000000000000003');
invalid_config.box.app.config.fail = true;
let before_invalid = invalid_config.box.filesystem.readfile('/opt/clash/config.yaml');
assert_throws(() => backup.restore(invalid_config.box.app,
	invalid_config.preview.id, null, 'system'), 'VALIDATION_FAILED');
assert_equal(invalid_config.box.filesystem.readfile('/opt/clash/config.yaml'), before_invalid);
assert_equal(invalid_config.box.runtime.uci.commit_calls, 0);
assert_equal(length(backup.list(invalid_config.box.app)), 0,
	'invalid input must not create a misleading recovery snapshot');

let invalid_settings = inspected_restore({
	'settings/settings.json': '{ "guard": { "enabled": "false" } }\n'
}, '00000000000000000000000000000004');
assert_throws(() => backup.restore(invalid_settings.box.app,
	invalid_settings.preview.id), 'VALIDATION_FAILED');
assert_equal(invalid_settings.box.runtime.uci.commit_calls, 0);

let invalid_ruleset = inspected_restore({
	'rulesets/restored.txt': 'invalid\n',
	'settings/settings.json': '{ }\n'
}, '00000000000000000000000000000005');
invalid_ruleset.box.app.rulesets.fail = true;
assert_throws(() => backup.restore(invalid_ruleset.box.app,
	invalid_ruleset.preview.id), 'VALIDATION_FAILED');
assert_equal(invalid_ruleset.box.filesystem.lstat('/opt/clash/lst/restored.txt'), null);

let tampered_stage = inspected_restore({
	'settings/settings.json': '{ }\n'
}, '00000000000000000000000000000006');
tampered_stage.box.filesystem.files['/tmp/miclash/backup-inspected/' +
	 tampered_stage.preview.id + '/settings/settings.json'] = '{"guard":{"enabled":false}}\n';
assert_throws(() => backup.restore(tampered_stage.box.app,
	tampered_stage.preview.id), 'CORRUPT_STATE');
assert_equal(tampered_stage.box.runtime.uci.commit_calls, 0);

let expired_stage = inspected_restore({
	'settings/settings.json': '{ }\n'
}, '00000000000000000000000000000007');
expired_stage.box.runtime.clock.advance(900001);
assert_throws(() => backup.restore(expired_stage.box.app,
	expired_stage.preview.id), 'NOT_FOUND');

let restart_stage = inspected_restore({
	'settings/settings.json': '{ }\n'
}, '0000000000000000000000000000000e');
restart_stage.box.filesystem.unlink('/tmp/miclash/imports/i-1700000000000-' +
	'0000000000000000000000000000000e.tar');
restart_stage.box.filesystem.unlink('/tmp/miclash/imports/i-1700000000000-' +
	'0000000000000000000000000000000e.json');
let restarted_app = { ...restart_stage.box.app };
assert_equal(backup.restore(restarted_app, restart_stage.preview.id).kind, 'backup.restore',
	'inspected contents must survive module restart and source disappearance');

let duplicate_settings = inspected_restore({
	'settings/settings.json': '{"guard":{},"guard":{}}\n'
}, '0000000000000000000000000000000f');
assert_throws(() => backup.restore(duplicate_settings.box.app,
	duplicate_settings.preview.id), 'VALIDATION_FAILED');

let snapshot_failure = inspected_restore({
	'configs/config.yaml': 'port: 9999\n',
	'settings/settings.json': '{ }\n'
}, '00000000000000000000000000000008');
snapshot_failure.box.archive.fail_on = 'create';
assert_throws(() => backup.restore(snapshot_failure.box.app,
	snapshot_failure.preview.id), 'INTERNAL');
assert_true(index(snapshot_failure.box.filesystem.readfile('/opt/clash/config.yaml'),
	'controller-password') >= 0);
assert_equal(snapshot_failure.box.runtime.uci.commit_calls, 0);

let commit_failure = inspected_restore({
	'configs/config.yaml': 'port: 9999\n',
	'settings/settings.json': '{ }\n'
}, '00000000000000000000000000000009');
commit_failure.box.filesystem.fail_rename_once_to = '/opt/clash/config.yaml';
assert_throws(() => backup.restore(commit_failure.box.app,
	commit_failure.preview.id), 'INTERNAL');
assert_equal(commit_failure.box.runtime.uci.commit_calls, 0);
assert_equal(length(backup.list(commit_failure.box.app)), 1,
	'failed commit retains pre-restore snapshot');

let reconcile_failure = inspected_restore({
	'configs/config.yaml': 'port: 9999\n',
	'settings/settings.json': '{ }\n'
}, '0000000000000000000000000000000a');
reconcile_failure.box.app.reconcile.fail = true;
assert_throws(() => backup.restore(reconcile_failure.box.app,
	reconcile_failure.preview.id), 'INTERNAL');
assert_equal(reconcile_failure.box.filesystem.readfile('/opt/clash/config.yaml'), 'port: 9999\n');
assert_equal(length(backup.list(reconcile_failure.box.app)), 1,
	'reconcile failure must not roll configuration back automatically');

let operation_failure = inspected_restore({
	'settings/settings.json': '{ }\n'
}, '0000000000000000000000000000000b');
operation_failure.box.app.operations.fail = true;
assert_throws(() => backup.restore(operation_failure.box.app,
	operation_failure.preview.id), 'INTERNAL');
assert_equal(length(backup.list(operation_failure.box.app)), 0);

let lock_failure = inspected_restore({
	'settings/settings.json': '{ }\n'
}, '0000000000000000000000000000000c');
lock_failure.box.app.lock.fail = true;
assert_throws(() => backup.restore(lock_failure.box.app,
	lock_failure.preview.id), 'BUSY');
assert_equal(length(backup.list(lock_failure.box.app)), 0);

let retention = make_app();
for (let index = 0; index < 3; index++) {
	backup.create(retention.app, null, 'auto');
	retention.runtime.clock.advance(1);
}
let retention_before = backup.list(retention.app);
retention.filesystem.files['/etc/miclash/backups/user-notes.txt'] = 'keep';
let pruned = backup.prune(retention.app, { retain: 2 });
assert_equal(length(pruned.removed), 1);
assert_equal(pruned.removed[0], retention_before[0].id);
assert_equal(length(backup.list(retention.app)), 2);
assert_equal(retention.filesystem.readfile('/etc/miclash/backups/user-notes.txt'), 'keep');
assert_throws(() => backup.prune(retention.app, { retain: 0 }), 'INVALID_ARGUMENT');

let prune_failure = make_app();
backup.create(prune_failure.app, null, 'auto');
prune_failure.runtime.clock.advance(1);
backup.create(prune_failure.app, null, 'auto');
prune_failure.filesystem.fail_unlink_once_matching = '.tar';
let recovered_prune = backup.prune(prune_failure.app, { retain: 1 });
assert_equal(length(recovered_prune.removed), 1);
assert_equal(length(backup.list(prune_failure.app)), 1,
	'prune archive-unlink failure must converge through authenticated tombstones');

let prune_second_step = make_app();
backup.create(prune_second_step.app, null, 'auto');
prune_second_step.runtime.clock.advance(1);
backup.create(prune_second_step.app, null, 'auto');
prune_second_step.filesystem.fail_unlink_once_matching = '.json';
let converged_prune = backup.prune(prune_second_step.app, { retain: 1 });
assert_equal(length(converged_prune.removed), 1);
assert_equal(length(backup.list(prune_second_step.app)), 1);
for (let name in prune_second_step.filesystem.lsdir('/etc/miclash/backups'))
	assert_true(index(name, '.prune-') < 0, 'prune tombstone did not converge');

let prune_restart = make_app();
backup.create(prune_restart.app, null, 'auto');
prune_restart.runtime.clock.advance(1);
backup.create(prune_restart.app, null, 'auto');
let prune_oldest = backup.list(prune_restart.app)[0].id;
prune_restart.filesystem.fail_rename_once_to =
	'/etc/miclash/backups/.prune-' + prune_oldest + '.tar';
assert_throws(() => backup.prune(prune_restart.app, { retain: 1 }), 'INTERNAL');
assert_equal(length(backup.list(prune_restart.app)), 1,
	'restart recovery must converge a committed prune tombstone');

let list_failure = make_app();
backup.create(list_failure.app, null, 'auto');
list_failure.filesystem.on_lstat = (path) => {
	if (path == '/etc/miclash/backups') die('injected-list-failure');
};
assert_throws(() => backup.list(list_failure.app), 'INTERNAL');

let create_setup_failure = make_app();
create_setup_failure.filesystem.on_lstat = (path) => {
	if (path == '/etc/miclash/backups') die('raw-create-setup');
};
assert_throws(() => backup.create(create_setup_failure.app), 'INTERNAL');

let inspect_setup_failure = make_app(), inspect_setup_import = valid_import(
	inspect_setup_failure, '00000000000000000000000000000015');
inspect_setup_failure.filesystem.on_lstat = (path) => {
	if (path == '/tmp/miclash/imports') die('raw-inspect-setup');
};
assert_throws(() => backup.inspect(inspect_setup_failure.app,
	inspect_setup_import.id), 'INTERNAL');

let prune_setup_failure = make_app();
prune_setup_failure.app.settings = {
	...prune_setup_failure.app.settings,
	load: () => die('raw-prune-settings')
};
assert_throws(() => backup.prune(prune_setup_failure.app), 'INTERNAL');

let hash_failure = make_app(), hash_import = valid_import(hash_failure,
	'0000000000000000000000000000000d');
let original_file_hash = hash_failure.runtime.digest.sha256_file;
hash_failure.runtime.digest.sha256_file = (path) =>
	index(path, '/backup-inspected/') >= 0 ? null : original_file_hash(path);
assert_throws(() => backup.inspect(hash_failure.app, hash_import.id), 'CORRUPT_STATE');

let physical_oversize = make_app();
let huge_archive = 'x';
for (let power = 0; power < 24; power++) huge_archive += huge_archive;
huge_archive += 'x';
let huge_manifest = custom_manifest(physical_oversize,
	{ 'settings/settings.json': '{ }\n' });
let huge_id = 'i-1700000000000-00000000000000000000000000000016';
seed_import(physical_oversize, huge_id, huge_manifest,
	{ 'settings/settings.json': '{ }\n' }, { archive_bytes: huge_archive });
assert_throws(() => backup.inspect(physical_oversize.app, huge_id), 'CORRUPT_STATE');

// Real-byte/tool conformance gate for the injected adapter boundary. The
// production module remains unwired; Plan 4 must provide an adapter that
// normalizes these real headers into the closed list() schema tested above.
let real_fs = require('fs');
let real_root = sprintf('/tmp/miclash-backup-real-%d-%d', time(), rand());
let real_stage = real_root + '/stage', real_out = real_root + '/out';
assert_equal(real_fs.mkdir(real_root), true);
assert_equal(real_fs.mkdir(real_stage), true);
assert_equal(real_fs.mkdir(real_out), true);
real_fs.writefile(real_stage + '/settings.json', '{ }\n');
real_fs.writefile(real_stage + '/manifest.json', '{ "schema": 1 }\n');
let real_archive = real_root + '/good.tar';
assert_equal(system([ '/usr/bin/tar', '--format=ustar', '--numeric-owner',
	'--owner=0', '--group=0', '-cf', real_archive, '-C', real_stage,
	'settings.json', 'manifest.json' ]), 0);
assert_equal(system([ '/usr/bin/tar', '--index-file=/dev/null', '-tf', real_archive ]), 0);
assert_equal(system([ '/usr/bin/tar', '-xf', real_archive, '-C', real_out ]), 0);
assert_equal(real_fs.readfile(real_out + '/settings.json'), '{ }\n');
assert_equal(system([ '/bin/ln', '-s', '/etc/passwd', real_stage + '/escape' ]), 0);
assert_equal(system([ '/bin/ln', real_stage + '/manifest.json', real_stage + '/hard' ]), 0);
let hostile_archive = real_root + '/hostile.tar';
assert_equal(system([ '/usr/bin/tar', '--format=ustar', '-cf', hostile_archive,
	'-C', real_stage, 'escape', 'hard' ]), 0);
assert_equal(system([ '/usr/bin/tar', '--index-file=/dev/null', '-tf', hostile_archive ]), 0);
let real_bytes = real_fs.readfile(real_archive);
let corrupt_archive = real_root + '/corrupt.tar';
real_fs.writefile(corrupt_archive, substr(real_bytes, 0, 511));
assert_equal(length(real_fs.readfile(corrupt_archive)), 511);
let trailing_archive = real_root + '/trailing.tar';
real_fs.writefile(trailing_archive, real_bytes + real_bytes);
assert_equal(length(real_fs.readfile(trailing_archive)), length(real_bytes) * 2);
for (let path in [
	real_out + '/settings.json', real_out + '/manifest.json',
	real_stage + '/escape', real_stage + '/hard', real_stage + '/settings.json',
	real_stage + '/manifest.json', real_archive, hostile_archive, corrupt_archive,
	trailing_archive
]) real_fs.unlink(path);
real_fs.rmdir(real_out);
real_fs.rmdir(real_stage);
real_fs.rmdir(real_root);
