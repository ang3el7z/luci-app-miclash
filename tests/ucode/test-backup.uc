import { assert_equal, assert_match, assert_throws, assert_true } from 'testlib';
import * as backup from 'miclash.backup';
import * as fakes from 'fakes';
import * as settings from 'miclash.settings';
import { rand } from 'math';

for (let method in [ 'list', 'create', 'inspect', 'restore', 'prune' ])
	assert_equal(type(backup[method]), 'function', method + ' is exported');
assert_equal(length(keys(backup)), 5, 'backup module must expose exactly five methods');

function clone(value) { return json(sprintf('%J', value)); };

function mkdirs(filesystem, paths) {
	for (let path in paths) {
		if (filesystem.lstat(path) == null) assert_equal(filesystem.mkdir(path), true);
		filesystem.chmod(path, 0o700);
		filesystem.set_uid(path, 0);
		filesystem.set_nlink(path, 1);
	}
};

function same_identity(left, right) {
	return left?.type == right?.type && left?.inode == right?.inode &&
		left?.dev?.major == right?.dev?.major && left?.dev?.minor == right?.dev?.minor &&
		left?.uid == right?.uid && left?.mode == right?.mode && left?.nlink == right?.nlink;
};

function secure_fs(filesystem) {
	let capability = { before: null, after: null, calls: [], replacement_nonce: 0,
		admission_held: false };
	function hook(which, operation, directory, name, extra) {
		push(capability.calls, { which, operation, name });
		let callback = capability[which];
		if (type(callback) == 'function') callback(operation, directory, name, extra);
	};
	function directory(path, expected) {
		let current = filesystem.lstat(path);
		if (current?.type != 'directory' || current.uid != 0 || current.mode != 0o700 ||
		    current.nlink != 1 || (expected != null && !same_identity(current, expected)))
			die('INTERNAL');
		return current;
	};
	function file(path, expected, options) {
		let current = filesystem.lstat(path);
		if (current?.type != 'file' || current.uid != (options?.uid ?? 0) ||
		    current.mode != options?.mode || current.nlink != (options?.nlink ?? 1) ||
		    (expected != null && !same_identity(current, expected))) die('INTERNAL');
		return current;
	};
	capability.open = (path, options) => {
		hook('before', 'open', null, path, options);
		if (filesystem.lstat(path) == null) {
			if (options?.create !== true || filesystem.mkdir(path) !== true) die('INTERNAL');
			filesystem.chmod(path, options.mode); filesystem.set_uid(path, options.uid);
			filesystem.set_nlink(path, 1);
		}
		let identity = directory(path, options?.expected);
		hook('after', 'open', null, path, options);
		identity = directory(path, identity);
		return { opaque: path, identity: clone(identity) };
	};
	capability.open_at = (parent, name, options) => {
		directory(parent.opaque, parent.identity);
		if (!match(name, /^[A-Za-z0-9._-]+$/)) die('INTERNAL');
		let path = parent.opaque + '/' + name;
		hook('before', 'open_at', parent, name, options);
		if (filesystem.lstat(path) == null) {
			if (options?.create !== true || filesystem.mkdir(path) !== true) die('INTERNAL');
			filesystem.chmod(path, options.mode); filesystem.set_uid(path, options.uid);
			filesystem.set_nlink(path, 1);
		}
		let identity = directory(path, options?.expected);
		hook('after', 'open_at', parent, name, options);
		identity = directory(path, identity);
		return { opaque: path, identity: clone(identity) };
	};
	capability.stat = (parent, name) => {
		directory(parent.opaque, parent.identity);
		hook('before', 'stat', parent, name, null);
		let identity = clone(filesystem.lstat(parent.opaque + '/' + name));
		hook('after', 'stat', parent, name, identity);
		return identity;
	};
	capability.list = (parent) => {
		directory(parent.opaque, parent.identity);
		hook('before', 'list', parent, null, null);
		let names = clone(filesystem.lsdir(parent.opaque));
		hook('after', 'list', parent, null, null);
		directory(parent.opaque, parent.identity);
		return names;
	};
	capability.read = (parent, name, options) => {
		directory(parent.opaque, parent.identity);
		let path = parent.opaque + '/' + name;
		hook('before', 'read', parent, name, options);
		let before = file(path, options?.expected, options);
		if (before.size > options.maximum) die('INTERNAL');
		let content = filesystem.readfile(path);
		hook('after', 'read', parent, name, options);
		let after = file(path, before, options);
		if (type(content) != 'string' || length(content) != after.size) die('INTERNAL');
		return { content, identity: clone(after) };
	};
	capability.create_exclusive = (parent, name, content, options) => {
		directory(parent.opaque, parent.identity);
		let path = parent.opaque + '/' + name;
		hook('before', 'create_exclusive', parent, name, options);
		if (filesystem.lstat(path) != null) die('INTERNAL');
		filesystem.files[path] = content; filesystem.bump_inode(path);
		filesystem.set_mode(path, options.mode); filesystem.set_uid(path, options.uid);
		filesystem.set_nlink(path, 1);
		hook('after', 'create_file_fsync', parent, name, options);
		hook('after', 'create_parent_fsync', parent, name, options);
		hook('after', 'create_exclusive', parent, name, options);
		return clone(file(path, null, { ...options, nlink: 1 }));
	};
	capability.replace_atomic = (parent, name, expected, content, options) => {
		directory(parent.opaque, parent.identity);
		let path = parent.opaque + '/' + name;
		hook('before', 'replace_atomic', parent, name, { expected, options });
		let current = filesystem.lstat(path);
		if (expected == null ? current != null : !same_identity(current, expected)) die('INTERNAL');
		let replacement = {
			content, inode: 1000000 + capability.replacement_nonce++, mode: options.mode,
			uid: options.uid, nlink: 1
		};
		hook('after', 'replace_temp_fsync', parent, name, { expected, options });
		hook('before', 'replace_rename', parent, name, { expected, options });
		current = filesystem.lstat(path);
		if (expected == null ? current != null : !same_identity(current, expected)) die('INTERNAL');
		filesystem.files[path] = replacement.content;
		filesystem.bump_inode(path);
		filesystem.set_mode(path, replacement.mode); filesystem.set_uid(path, replacement.uid);
		filesystem.set_nlink(path, replacement.nlink);
		let identity = clone(file(path, null, { ...options, nlink: 1 }));
		hook('after', 'replace_rename', parent, name, { expected, options, identity });
		hook('after', 'replace_parent_fsync', parent, name, { expected, options, identity });
		hook('after', 'replace_atomic', parent, name, { expected, options, identity });
		return identity;
	};
	capability.with_admission_lock = (worker) => {
		if (capability.admission_held) die('BUSY');
		capability.admission_held = true;
		let result;
		try { result = worker(); }
		catch (error) { capability.admission_held = false; die(error); }
		capability.admission_held = false;
		return result;
	};
	capability.rename = (parent, from, to, expected, options) => {
		directory(parent.opaque, parent.identity);
		let from_path = parent.opaque + '/' + from, to_path = parent.opaque + '/' + to;
		hook('before', 'rename', parent, from, { to, expected, options });
		file(from_path, expected, options);
		if (filesystem.lstat(to_path) != null || filesystem.rename(from_path, to_path) !== true)
			die('INTERNAL');
		hook('after', 'rename', parent, to, { from, expected, options });
		return clone(file(to_path, expected, options));
	};
	capability.unlink = (parent, name, expected) => {
		directory(parent.opaque, parent.identity);
		let path = parent.opaque + '/' + name;
		hook('before', 'unlink', parent, name, expected);
		if (!same_identity(filesystem.lstat(path), expected)) die('INTERNAL');
		if (filesystem.unlink(path) !== true) die('INTERNAL');
		hook('after', 'unlink', parent, name, expected);
		return true;
	};
	capability.rmdir = (parent, name, expected) => {
		directory(parent.opaque, parent.identity);
		let path = parent.opaque + '/' + name;
		hook('before', 'rmdir', parent, name, expected);
		if (!same_identity(filesystem.lstat(path), expected)) die('INTERNAL');
		if (filesystem.rmdir(path) !== true) die('INTERNAL');
		hook('after', 'rmdir', parent, name, expected);
		return true;
	};
	return capability;
};

function make_app() {
	let filesystem = fakes.fs({
		'/opt/clash/config.yaml': 'port: 7890\nsecret: controller-password\n',
		'/opt/clash/config2.yaml': 'port: 7891\n',
		'/opt/clash/lst/local.txt': 'DOMAIN-SUFFIX,example.test\n'
	});
	mkdirs(filesystem, [ '/etc', '/etc/miclash', '/opt', '/opt/clash', '/opt/clash/lst',
		'/tmp', '/tmp/miclash', '/var', '/var/run', '/var/run/miclash' ]);
	for (let path in [ '/opt/clash/config.yaml', '/opt/clash/config2.yaml',
		'/opt/clash/lst/local.txt' ]) {
		filesystem.set_mode(path, 0o600); filesystem.set_uid(path, 0);
		filesystem.set_nlink(path, 1);
	}
	let runtime = {
		fs: filesystem, clock: fakes.clock(1700000000000), random: fakes.entropy(),
		digest: fakes.digest(filesystem),
		uci: fakes.uci({ miclash: {
			core: { '.type': 'core', subscription_url: 'https://user:pass@example.test/sub' },
			guard: { '.type': 'guard', enabled: '1' },
			telegram: { '.type': 'telegram', enabled: '1', token: 'telegram-secret', user_id: '42' },
			meta: { '.type': 'meta', schema_version: '1' }
		} }),
		paths: { etc: '/etc/miclash', tmp: '/tmp/miclash', run: '/var/run/miclash' }
	};
	let config = { fail: false, calls: [], validate_in_operation: function(ctx, profile, content) {
		push(this.calls, { profile, content }); return this.fail ? { ok: false } : { ok: true };
	} };
	let rulesets = { fail: false, calls: [], validate: function(name, content) {
		push(this.calls, { name, content }); return !this.fail;
	} };
	let operations = { calls: [], submit: function(kind, source, context, worker) {
		push(this.calls, { kind, source, context: clone(context) });
		let ctx = { id: '1700000000000-00000001-0000000000000001', stage: () => true };
		return { kind, source, context, result: worker(ctx) };
	} };
	let lock = { calls: [], with_lock: function(runtime, options, worker) {
		push(this.calls, clone(options)); return worker();
	} };
	let reconcile = { calls: [], run: function(reason) {
		push(this.calls, reason); return { state: 'queued' };
	} };
	let app = { runtime, secure_fs: secure_fs(filesystem), app_version: '0.9.2', settings,
		config, rulesets, operations, lock, reconcile,
		archive: { create: () => die('adapter-used'), list: () => die('adapter-used'),
			extract: () => die('adapter-used') } };
	return { app, filesystem, runtime };
};

const NUL = sprintf('%c', 0);
function zeroes(count) { let out = ''; for (let i = 0; i < count; i++) out += NUL; return out; };
function field(text, width) { return text + zeroes(width - length(text)); };
function test_header(name, size, typeflag, linkname) {
	let header = field(name, 100) + sprintf('%07o', 0o600) + NUL +
		sprintf('%07o', 0) + NUL + sprintf('%07o', 0) + NUL +
		sprintf('%011o', size) + NUL + sprintf('%011o', 0) + NUL + '        ' +
		(typeflag ?? '0') + field(linkname ?? '', 100) + 'ustar' + NUL + '00' +
		zeroes(32) + zeroes(32) + sprintf('%07o', 0) + NUL +
		sprintf('%07o', 0) + NUL + zeroes(155) + zeroes(12);
	let checksum = 0; for (let i = 0; i < 512; i++) checksum += ord(header, i);
	return substr(header, 0, 148) + sprintf('%06o', checksum) + NUL + ' ' + substr(header, 156);
};
function test_tar(entries) {
	let out = '';
	for (let entry in entries) {
		out += test_header(entry.name, length(entry.content ?? ''), entry.typeflag, entry.linkname) +
			(entry.content ?? '');
		out += zeroes((512 - (length(entry.content ?? '') % 512)) % 512);
	}
	return out + zeroes(1024);
};

function sorted(values) { let out = [ ...values ]; sort(out); return out; };
function manifest_for(box, contents, secrets) {
	let files = [], includes = [];
	for (let path in sorted(keys(contents))) {
		let include = split(path, '/')[0]; if (index(includes, include) < 0) push(includes, include);
		push(files, { path, size: length(contents[path]),
			sha256: box.runtime.digest.sha256(contents[path]), secret: secrets?.[path] === true });
	}
	return { schema: 1, created_at: box.runtime.clock.now(), app_version: '0.9.2',
		includes: sorted(includes), files };
};
function seed_import(box, suffix, contents, options) {
	let id = 'i-1700000000000-' + suffix;
	let manifest = options?.manifest ?? manifest_for(box, contents, options?.secrets);
	let manifest_text = sprintf('%J\n', manifest), entries = [];
	for (let file in manifest.files)
		push(entries, { name: file.path, content: contents[file.path] ?? '' });
	push(entries, { name: 'manifest.json', content: manifest_text });
	let bytes = options?.bytes ?? test_tar(entries);
	mkdirs(box.filesystem, [ '/tmp/miclash/imports' ]);
	let archive_path = '/tmp/miclash/imports/' + id + '.tar';
	box.filesystem.files[archive_path] = bytes; box.filesystem.bump_inode(archive_path);
	box.filesystem.set_mode(archive_path, 0o600); box.filesystem.set_uid(archive_path, 0);
	box.filesystem.set_nlink(archive_path, 1);
	let sidecar = { schema: 1, id, created_at: manifest.created_at, app_version: manifest.app_version,
		includes: manifest.includes, file_count: length(manifest.files), size: length(bytes),
		sha256: box.runtime.digest.sha256(bytes) };
	let side_path = '/tmp/miclash/imports/' + id + '.json';
	box.filesystem.files[side_path] = sprintf('%J\n', sidecar); box.filesystem.bump_inode(side_path);
	box.filesystem.set_mode(side_path, 0o600); box.filesystem.set_uid(side_path, 0);
	box.filesystem.set_nlink(side_path, 1);
	return { id, manifest, bytes };
};

// Capability and exact confidentiality boundary.
assert_throws(() => backup.create({}, null, 'luci'), 'INVALID_ARGUMENT');
let unsupported = make_app(); delete unsupported.app.secure_fs;
assert_throws(() => backup.list(unsupported.app), 'INTERNAL');
for (let primitive in [ 'create_exclusive', 'replace_atomic', 'with_admission_lock' ]) {
	let missing = make_app(); delete missing.app.secure_fs[primitive];
	assert_throws(() => backup.list(missing.app), 'INTERNAL');
}

let base = make_app(), created = backup.create(base.app, null, 'luci');
assert_match(created.id, /^b-[0-9]{13}-[0-9a-f]{32}$/);
assert_equal(length(backup.list(base.app)), 1);
let archive_path = '/etc/miclash/backups/' + created.id + '.tar';
let sidecar_path = '/etc/miclash/backups/' + created.id + '.json';
assert_equal(base.filesystem.lstat(archive_path).mode, 0o600);
assert_equal(base.filesystem.lstat(sidecar_path).mode, 0o600);
assert_equal(base.filesystem.lstat('/etc/miclash/backups').mode, 0o700);
let public_bytes = base.filesystem.readfile(archive_path);
assert_true(index(public_bytes, 'manifest.json') > index(public_bytes, 'settings/settings.json'),
	'manifest must be the final USTAR member');
for (let secret in [ 'controller-password', 'telegram-secret', 'user:pass', 'subscription_url' ])
	assert_true(index(public_bytes, secret) < 0, 'default archive leaked ' + secret);

let explicit = make_app(), secret_backup = backup.create(explicit.app,
	{ include_secrets: true }, 'system');
let secret_path = '/etc/miclash/backups/' + secret_backup.id + '.tar';
assert_true(index(explicit.filesystem.readfile(secret_path), 'controller-password') >= 0);
assert_equal(explicit.filesystem.lstat(secret_path).mode, 0o600);

let mode_swap = make_app(), mode_created = backup.create(mode_swap.app,
	{ include_secrets: true }, 'system');
mode_swap.filesystem.set_mode('/etc/miclash/backups/' + mode_created.id + '.tar', 0o644);
assert_throws(() => backup.inspect(mode_swap.app, mode_created.id), 'CORRUPT_STATE');

let side_mode = make_app(), side_created = backup.create(side_mode.app);
side_mode.filesystem.set_mode('/etc/miclash/backups/' + side_created.id + '.json', 0o640);
assert_throws(() => backup.list(side_mode.app), 'CORRUPT_STATE');

let publish_swap = make_app();
publish_swap.filesystem.on_rename = (from, to) => {
	if (match(to, /\/backups\/b-[0-9]{13}-[0-9a-f]{32}\.tar$/))
		publish_swap.filesystem.set_mode(to, 0o644);
};
assert_throws(() => backup.create(publish_swap.app,
	{ include_secrets: true }, 'system'), 'INTERNAL');
assert_equal(length(publish_swap.filesystem.lsdir('/etc/miclash/backups')), 0,
	'unsafe publication residue survived cleanup');

// Byte-faithful parser and staging.
let imported_box = make_app();
let imported = seed_import(imported_box, '00000000000000000000000000000001', {
	'rulesets/restored.txt': 'DOMAIN,restored.test\n', 'settings/settings.json': '{ }\n'
});
let preview = backup.inspect(imported_box.app, imported.id);
assert_match(preview.id, /^x-[0-9]{13}-[0-9a-f]{32}$/);
assert_equal(imported_box.filesystem.lstat('/tmp/miclash/backup-inspected/' + preview.id).mode, 0o700);
assert_equal(imported_box.filesystem.lstat('/tmp/miclash/backup-inspected/' + preview.id +
	'/settings/settings.json').mode, 0o400);

function rejected_bytes(label, mutate, code) {
	let box = make_app();
	let seeded = seed_import(box, label, { 'settings/settings.json': '{ }\n' });
	let bytes = mutate(seeded.bytes);
	seeded = seed_import(box, label, { 'settings/settings.json': '{ }\n' }, { bytes });
	assert_throws(() => backup.inspect(box.app, seeded.id), code ?? 'VALIDATION_FAILED');
};
function rewrite_header_byte(bytes, offset, replacement) {
	let header = substr(bytes, 0, 512);
	header = substr(header, 0, offset) + replacement + substr(header, offset + 1);
	header = substr(header, 0, 148) + '        ' + substr(header, 156);
	let checksum = 0; for (let i = 0; i < 512; i++) checksum += ord(header, i);
	header = substr(header, 0, 148) + sprintf('%06o', checksum) + NUL + ' ' +
		substr(header, 156);
	return header + substr(bytes, 512);
};
rejected_bytes('00000000000000000000000000000002', (bytes) => substr(bytes, 0, length(bytes) - 1));
rejected_bytes('00000000000000000000000000000003', (bytes) => bytes + bytes);
rejected_bytes('00000000000000000000000000000004', (bytes) => bytes + 'x');
rejected_bytes('00000000000000000000000000000005', (bytes) =>
	substr(bytes, 0, 148) + '000000' + NUL + ' ' + substr(bytes, 156));
rejected_bytes('00000000000000000000000000000006', (bytes) => bytes + zeroes(512));
rejected_bytes('00000000000000000000000000000007', (bytes) =>
	rewrite_header_byte(bytes, 124, '8'));
rejected_bytes('00000000000000000000000000000008', (bytes) =>
	rewrite_header_byte(bytes, 124, sprintf('%c', 128)));

for (let hostile in [
	{ typeflag: '1', linkname: 'settings/settings.json' },
	{ typeflag: '2', linkname: '/etc/passwd' }, { typeflag: '3' }, { typeflag: 'x' },
	{ typeflag: 'L' }, { typeflag: 'S' }
]) {
	let box = make_app(), content = '{ }\n', manifest = manifest_for(box,
		{ 'settings/settings.json': content });
	let bytes = test_tar([
		{ name: 'settings/settings.json', content, typeflag: hostile.typeflag,
			linkname: hostile.linkname },
		{ name: 'manifest.json', content: sprintf('%J\n', manifest) }
	]);
	let seeded = seed_import(box, sprintf('%032x', 16 + ord(hostile.typeflag)),
		{ 'settings/settings.json': content }, { manifest, bytes });
	assert_throws(() => backup.inspect(box.app, seeded.id), 'VALIDATION_FAILED');
}

for (let bad_name in [ '/absolute', '../escape', 'settings/../escape',
	'settings//settings.json', 'C:/drive', 'settings\\settings.json',
	'./manifest.json', 'settings/settings.json/' ]) {
	let box = make_app(), content = '{ }\n', manifest = manifest_for(box,
		{ 'settings/settings.json': content });
	let bytes = test_tar([ { name: bad_name, content },
		{ name: 'manifest.json', content: sprintf('%J\n', manifest) } ]);
	let seeded = seed_import(box, sprintf('%032x', 200 + length(bad_name)),
		{ 'settings/settings.json': content }, { manifest, bytes });
	assert_throws(() => backup.inspect(box.app, seeded.id), 'VALIDATION_FAILED');
}

let duplicate_member = make_app(), duplicate_content = '{ }\n';
let duplicate_manifest = manifest_for(duplicate_member,
	{ 'settings/settings.json': duplicate_content });
let duplicate_bytes = test_tar([
	{ name: 'settings/settings.json', content: duplicate_content },
	{ name: 'settings/settings.json', content: duplicate_content },
	{ name: 'manifest.json', content: sprintf('%J\n', duplicate_manifest) }
]);
let duplicate_seed = seed_import(duplicate_member,
	'00000000000000000000000000000060',
	{ 'settings/settings.json': duplicate_content },
	{ manifest: duplicate_manifest, bytes: duplicate_bytes });
assert_throws(() => backup.inspect(duplicate_member.app, duplicate_seed.id), 'VALIDATION_FAILED');

let unknown_manifest = make_app(), unknown_contents = { 'settings/settings.json': '{ }\n' };
let unknown_value = manifest_for(unknown_manifest, unknown_contents); unknown_value.extra = true;
let unknown_seed = seed_import(unknown_manifest,
	'00000000000000000000000000000061', unknown_contents, { manifest: unknown_value });
assert_throws(() => backup.inspect(unknown_manifest.app, unknown_seed.id), 'VALIDATION_FAILED');

let physical_oversize = make_app(), huge = 'x';
for (let power = 0; power < 24; power++) huge += huge;
huge += 'x';
let huge_seed = seed_import(physical_oversize,
	'00000000000000000000000000000062', { 'settings/settings.json': '{ }\n' },
	{ bytes: huge });
assert_throws(() => backup.inspect(physical_oversize.app, huge_seed.id), 'CORRUPT_STATE');

// Actual GNU tar streams pass through backup.inspect, not a side gate.
let real_fs = require('fs');
let real_root = sprintf('/tmp/miclash-backup-real-%d-%d', time(), rand());
let real_stage = real_root + '/stage', real_settings = real_stage + '/settings';
assert_equal(real_fs.mkdir(real_root), true); assert_equal(real_fs.mkdir(real_stage), true);
assert_equal(real_fs.mkdir(real_settings), true);
let real_box = make_app(), real_content = '{ }\n';
let real_manifest = manifest_for(real_box, { 'settings/settings.json': real_content });
real_fs.writefile(real_settings + '/settings.json', real_content);
real_fs.writefile(real_stage + '/manifest.json', sprintf('%J\n', real_manifest));
let real_archive = real_root + '/good.tar';
assert_equal(system([ '/usr/bin/tar', '--format=ustar', '--blocking-factor=1',
	'--numeric-owner', '--owner=0', '--group=0', '-cf', real_archive,
	'-C', real_stage, 'settings/settings.json', 'manifest.json' ]), 0);
let real_bytes = real_fs.readfile(real_archive);
let real_seed = seed_import(real_box, '00000000000000000000000000000070',
	{ 'settings/settings.json': real_content }, { manifest: real_manifest, bytes: real_bytes });
assert_match(backup.inspect(real_box.app, real_seed.id).id, /^x-/);
for (let sample in [
	[ '00000000000000000000000000000071', substr(real_bytes, 0, length(real_bytes) - 512) ],
	[ '00000000000000000000000000000072', real_bytes + real_bytes ],
	[ '00000000000000000000000000000073', real_bytes + 'trailing' ]
]) {
	let box = make_app(), seeded = seed_import(box, sample[0],
		{ 'settings/settings.json': real_content }, { manifest: real_manifest, bytes: sample[1] });
	assert_throws(() => backup.inspect(box.app, seeded.id), 'VALIDATION_FAILED');
}
assert_equal(system([ '/bin/ln', '-s', '/etc/passwd', real_stage + '/escape' ]), 0);
assert_equal(system([ '/bin/ln', real_stage + '/manifest.json', real_stage + '/hard' ]), 0);
let real_links = real_root + '/links.tar';
assert_equal(system([ '/usr/bin/tar', '--format=ustar', '--blocking-factor=1', '-cf',
	real_links, '-C', real_stage, 'escape', 'hard' ]), 0);
let link_box = make_app(), link_seed = seed_import(link_box,
	'00000000000000000000000000000074', { 'settings/settings.json': real_content },
	{ manifest: real_manifest, bytes: real_fs.readfile(real_links) });
assert_throws(() => backup.inspect(link_box.app, link_seed.id), 'VALIDATION_FAILED');

// Restore validates first, snapshots secrets, commits settings once, then reconciles.
let restore_box = make_app(), restore_seed = seed_import(restore_box,
	'00000000000000000000000000000080', {
		'configs/config.yaml': 'port: 10001\n',
		'rulesets/restored.txt': 'DOMAIN,restored.test\n',
		'settings/settings.json': '{ }\n'
	}, { secrets: { 'configs/config.yaml': true, 'settings/settings.json': true } });
let restore_preview = backup.inspect(restore_box.app, restore_seed.id);
let restored = backup.restore(restore_box.app, restore_preview.id, null, 'system');
assert_equal(restored.kind, 'backup.restore');
assert_equal(restore_box.filesystem.readfile('/opt/clash/config.yaml'), 'port: 10001\n');
assert_equal(restore_box.runtime.uci.commit_calls, 1);
assert_equal(length(restore_box.app.reconcile.calls), 1);
assert_equal(length(backup.list(restore_box.app)), 1, 'recovery snapshot must remain');

let invalid_box = make_app(), invalid_seed = seed_import(invalid_box,
	'00000000000000000000000000000081', {
		'configs/config.yaml': 'invalid\n', 'settings/settings.json': '{ }\n'
	}, { secrets: { 'configs/config.yaml': true } });
invalid_box.app.config.fail = true;
let invalid_preview = backup.inspect(invalid_box.app, invalid_seed.id);
assert_throws(() => backup.restore(invalid_box.app, invalid_preview.id), 'VALIDATION_FAILED');
assert_equal(length(backup.list(invalid_box.app)), 0, 'snapshot preceded validation failure');

// Identity-bound prune refuses swap-after-auth and leaves the foreign target untouched.
let retention = make_app();
backup.create(retention.app); retention.runtime.clock.advance(1); backup.create(retention.app);
let pruned = backup.prune(retention.app, { retain: 1 });
assert_equal(length(pruned.removed), 1); assert_equal(length(backup.list(retention.app)), 1);

let raced = make_app();
backup.create(raced.app); raced.runtime.clock.advance(1); backup.create(raced.app);
raced.filesystem.files['/opt/clash/foreign'] = 'foreign';
raced.filesystem.set_mode('/opt/clash/foreign', 0o600); raced.filesystem.set_uid('/opt/clash/foreign', 0);
let swapped = false;
raced.app.secure_fs.before = (operation, directory, name, extra) => {
	if (!swapped && operation == 'rename' && match(name, /\.json$/)) {
		swapped = true;
		raced.filesystem.set_symlink(directory.opaque + '/' + name, '/opt/clash/foreign');
	}
};
assert_throws(() => backup.prune(raced.app, { retain: 1 }), 'INTERNAL');
assert_equal(raced.filesystem.readfile('/opt/clash/foreign'), 'foreign');

for (let path in [ real_stage + '/escape', real_stage + '/hard',
	real_settings + '/settings.json', real_stage + '/manifest.json', real_archive, real_links ])
	real_fs.unlink(path);
real_fs.rmdir(real_settings); real_fs.rmdir(real_stage); real_fs.rmdir(real_root);

// Shared recursive secret vocabulary: default settings omit classified keys
// and their entire containers, including camel/acronym spellings and arrays.
let hostile_settings = {
	public_key: 'allowed-public',
	outer: {
		clientSecret: 'nested-client-secret', APIKey: 'nested-api-key',
		children: [
			{ accessToken: 'nested-access-token', safe: 'kept' },
			{ subscriptionURLConfigYaml: 'nested-subscription', public_value: 'kept-too' },
			{ credentialBag: { value: 'nested-credential' } }
		]
	}
};
let recursive_public = make_app();
recursive_public.app.settings = {
	load: () => clone(hostile_settings), validate_patch: (value) => clone(value),
	save: (runtime, value) => { runtime.uci.commit_calls++; return value; }
};
let recursive_created = backup.create(recursive_public.app);
let recursive_bytes = recursive_public.filesystem.readfile('/etc/miclash/backups/' +
	recursive_created.id + '.tar');
for (let leaked in [ 'clientSecret', 'APIKey', 'accessToken',
	'subscriptionURLConfigYaml', 'credentialBag', 'nested-client-secret',
	'nested-api-key', 'nested-access-token', 'nested-subscription', 'nested-credential' ])
	assert_true(index(recursive_bytes, leaked) < 0, 'recursive sanitizer leaked ' + leaked);
assert_true(index(recursive_bytes, 'allowed-public') >= 0);

let recursive_secret = make_app();
recursive_secret.app.settings = recursive_public.app.settings;
let recursive_secret_created = backup.create(recursive_secret.app,
	{ include_secrets: true }, 'system');
let recursive_secret_bytes = recursive_secret.filesystem.readfile('/etc/miclash/backups/' +
	recursive_secret_created.id + '.tar');
assert_true(index(recursive_secret_bytes, 'nested-client-secret') >= 0);
assert_equal(recursive_secret.filesystem.lstat('/etc/miclash/backups/' +
	recursive_secret_created.id + '.tar').mode, 0o600);
let recursive_secret_preview = backup.inspect(recursive_secret.app, recursive_secret_created.id);
let settings_secret_flag = null;
for (let file in recursive_secret_preview.files)
	if (file.path == 'settings/settings.json') settings_secret_flag = file.secret;
assert_equal(settings_secret_flag, true);

let hostile_inspect = make_app();
hostile_inspect.app.settings = recursive_public.app.settings;
let hostile_text = sprintf('%J\n', hostile_settings);
let hostile_seed = seed_import(hostile_inspect, '00000000000000000000000000000090',
	{ 'settings/settings.json': hostile_text });
assert_throws(() => backup.inspect(hostile_inspect.app, hostile_seed.id), 'VALIDATION_FAILED');

// Every v1 manifest requires settings/settings.json, even when the patch is empty.
let missing_settings = make_app();
let missing_seed = seed_import(missing_settings, '00000000000000000000000000000091',
	{ 'rulesets/only.txt': 'DOMAIN,only.test\n' });
assert_throws(() => backup.inspect(missing_settings.app, missing_seed.id), 'VALIDATION_FAILED');

// Re-sign an inspected tree to emulate a privileged staged-state substitution;
// restore still re-applies secret:false classification immediately before save.
let revalidate = make_app();
revalidate.app.settings = recursive_public.app.settings;
let safe_seed = seed_import(revalidate, '00000000000000000000000000000092',
	{ 'settings/settings.json': '{ }\n' });
let safe_preview = backup.inspect(revalidate.app, safe_seed.id);
let stage = '/tmp/miclash/backup-inspected/' + safe_preview.id;
let substituted = sprintf('%J\n', { safe: 'ok', nested: { clientSecret: 'late-secret' } });
let staged_settings = stage + '/settings/settings.json';
revalidate.filesystem.files[staged_settings] = substituted;
revalidate.filesystem.bump_inode(staged_settings); revalidate.filesystem.set_mode(staged_settings, 0o400);
let manifest_path = stage + '/manifest.json';
let staged_manifest = json(revalidate.filesystem.readfile(manifest_path));
for (let file in staged_manifest.files)
	if (file.path == 'settings/settings.json') {
		file.size = length(substituted); file.sha256 = revalidate.runtime.digest.sha256(substituted);
	}
revalidate.filesystem.files[manifest_path] = sprintf('%J\n', staged_manifest);
revalidate.filesystem.bump_inode(manifest_path); revalidate.filesystem.set_mode(manifest_path, 0o400);
let report_path = stage + '/.inspection.json';
let report = json(revalidate.filesystem.readfile(report_path));
report.manifest = clone(staged_manifest);
let manifest_stat = revalidate.filesystem.lstat(manifest_path);
report.manifest_inode = manifest_stat.inode;
report.manifest_dev_major = manifest_stat.dev.major; report.manifest_dev_minor = manifest_stat.dev.minor;
let settings_stat = revalidate.filesystem.lstat(staged_settings);
for (let captured in report.files)
	if (captured.path == 'settings/settings.json') {
		captured.size = length(substituted); captured.sha256 = revalidate.runtime.digest.sha256(substituted);
		captured.inode = settings_stat.inode;
		captured.dev_major = settings_stat.dev.major; captured.dev_minor = settings_stat.dev.minor;
	}
revalidate.filesystem.files[report_path] = sprintf('%J\n', report);
revalidate.filesystem.bump_inode(report_path); revalidate.filesystem.set_mode(report_path, 0o600);
let revalidate_journal_name = revalidate.filesystem.lsdir(
	'/tmp/miclash/backup-transactions')[0];
let revalidate_journal_path = '/tmp/miclash/backup-transactions/' + revalidate_journal_name;
let revalidate_journal = json(revalidate.filesystem.readfile(revalidate_journal_path));
let report_stat = revalidate.filesystem.lstat(report_path);
for (let registered in revalidate_journal.files) {
	let changed_path = null;
	if (registered.path == 'settings/settings.json') changed_path = staged_settings;
	else if (registered.path == 'manifest.json') changed_path = manifest_path;
	else if (registered.path == '.inspection.json') changed_path = report_path;
	if (changed_path != null) {
		let changed = revalidate.filesystem.lstat(changed_path);
		registered.size = changed.size;
		registered.sha256 = revalidate.runtime.digest.sha256(
			revalidate.filesystem.readfile(changed_path));
		registered.identity = { type: 'file', inode: changed.inode,
			dev_major: changed.dev.major, dev_minor: changed.dev.minor,
			uid: changed.uid, mode: changed.mode, nlink: changed.nlink, size: changed.size };
	}
}
revalidate.filesystem.files[revalidate_journal_path] = sprintf('%J\n', revalidate_journal);
revalidate.filesystem.bump_inode(revalidate_journal_path);
revalidate.filesystem.set_mode(revalidate_journal_path, 0o600);
assert_throws(() => backup.restore(revalidate.app, safe_preview.id), 'VALIDATION_FAILED');
assert_equal(revalidate.runtime.uci.commit_calls, 0);

// Default restore preserves the current secrets and commits the empty/sanitized patch once.
let preserve = make_app(), preserve_created = backup.create(preserve.app);
let preserve_preview = backup.inspect(preserve.app, preserve_created.id);
let preserve_cursor = preserve.runtime.uci.cursor();
assert_equal(preserve_cursor.set('miclash', 'telegram', 'token', 'new-current-token'), true);
assert_equal(preserve_cursor.set('miclash', 'core', 'subscription_url',
	'https://new-current.example/sub'), true);
assert_equal(preserve_cursor.commit('miclash'), true);
let commits_before = preserve.runtime.uci.commit_calls;
backup.restore(preserve.app, preserve_preview.id);
let preserved = settings.load(preserve.runtime);
assert_equal(preserved.telegram.token, 'new-current-token');
assert_equal(preserved.core.subscription_url, 'https://new-current.example/sub');
assert_equal(preserve.runtime.uci.commit_calls, commits_before + 1);
assert_equal(invalid_box.runtime.uci.commit_calls, 0, 'failed restore committed UCI');

// Live restore commits are CAS-bound to the identities revalidated immediately
// before the first mutation. A foreign swap is never overwritten.
let live_swap = make_app();
let live_swap_seed = seed_import(live_swap,
	'00000000000000000000000000000101', {
		'configs/config.yaml': 'port: 7999\n',
		'settings/settings.json': '{ }\n'
	}, { secrets: { 'configs/config.yaml': true } });
let live_swap_preview = backup.inspect(live_swap.app, live_swap_seed.id);
let live_swap_fired = false;
live_swap.app.secure_fs.before = (operation, directory, name, extra) => {
	if (!live_swap_fired && operation == 'replace_atomic' && name == 'config.yaml') {
		live_swap_fired = true;
		let path = directory.opaque + '/' + name;
		live_swap.filesystem.files[path] = 'foreign-live';
		live_swap.filesystem.bump_inode(path);
		live_swap.filesystem.set_mode(path, 0o600);
		live_swap.filesystem.set_uid(path, 0);
		live_swap.filesystem.set_nlink(path, 1);
	}
};
assert_throws(() => backup.restore(live_swap.app, live_swap_preview.id), 'INTERNAL');
assert_equal(live_swap_fired, true, 'restore did not reach live CAS boundary');
assert_equal(live_swap.filesystem.readfile('/opt/clash/config.yaml'), 'foreign-live');

let preflight_swap = make_app();
let preflight_seed = seed_import(preflight_swap,
	'00000000000000000000000000000102', {
		'configs/config.yaml': 'port: 7998\n',
		'configs/config2.yaml': 'port: 7997\n',
		'settings/settings.json': '{ }\n'
	}, { secrets: { 'configs/config.yaml': true, 'configs/config2.yaml': true } });
let preflight_preview = backup.inspect(preflight_swap.app, preflight_seed.id);
let preflight_original = preflight_swap.filesystem.readfile('/opt/clash/config.yaml');
let config2_stats = 0;
preflight_swap.app.secure_fs.before = (operation, directory, name, extra) => {
	if (operation == 'stat' && directory.opaque == '/opt/clash' && name == 'config2.yaml' &&
	    ++config2_stats == 2) {
		let path = '/opt/clash/config2.yaml';
		preflight_swap.filesystem.files[path] = 'foreign-preflight';
		preflight_swap.filesystem.bump_inode(path);
		preflight_swap.filesystem.set_mode(path, 0o600);
		preflight_swap.filesystem.set_uid(path, 0);
		preflight_swap.filesystem.set_nlink(path, 1);
	}
};
assert_throws(() => backup.restore(preflight_swap.app, preflight_preview.id), 'INTERNAL');
assert_equal(preflight_swap.filesystem.readfile('/opt/clash/config.yaml'),
	preflight_original, 'first live target mutated before full preflight revalidation');
assert_equal(preflight_swap.filesystem.readfile('/opt/clash/config2.yaml'), 'foreign-preflight');

function transaction_names(box) {
	return box.filesystem.lsdir('/tmp/miclash/backup-transactions') ?? [];
};

// Journal registration is durable before every risky create phase.
let marker_order = make_app(), marker_seen = false;
marker_order.app.secure_fs.before = (operation, directory, name, extra) => {
	if (operation == 'create_exclusive' && match(name, /\.tar\.tmp$/)) {
		let names = transaction_names(marker_order);
		marker_seen = length(names) == 1 &&
			marker_order.filesystem.lstat('/tmp/miclash/backup-transactions/' + names[0]).mode == 0o600;
	}
};
backup.create(marker_order.app);
assert_equal(marker_seen, true, 'archive temp was exposed before durable transaction marker');
assert_equal(length(transaction_names(marker_order)), 0, 'completed create retained journal');

let journal_swap = make_app(), journal_swap_fired = false, journal_foreign = null;
journal_swap.app.secure_fs.before = (operation, directory, name, extra) => {
	if (!journal_swap_fired && operation == 'replace_atomic' && match(name, /^t-.*\.json$/)) {
		journal_swap_fired = true; journal_foreign = directory.opaque + '/' + name;
		journal_swap.filesystem.files[journal_foreign] = 'foreign-journal';
		journal_swap.filesystem.bump_inode(journal_foreign);
		journal_swap.filesystem.set_mode(journal_foreign, 0o600);
		journal_swap.filesystem.set_uid(journal_foreign, 0);
		journal_swap.filesystem.set_nlink(journal_foreign, 1);
	}
};
assert_throws(() => backup.create(journal_swap.app), 'INTERNAL');
assert_equal(journal_swap_fired, true, 'journal did not reach CAS replacement boundary');
assert_equal(journal_swap.filesystem.readfile(journal_foreign), 'foreign-journal');

// Recovery, capacity count, and exclusive journal creation share one mandatory
// admission critical section. Reentrant admission is BUSY, never a second journal.
let admission_race = make_app();
let admission_seed = seed_import(admission_race,
	'00000000000000000000000000000103', { 'settings/settings.json': '{ }\n' });
let admission_probe = false;
admission_race.app.secure_fs.before = (operation, directory, name, extra) => {
	if (!admission_probe && operation == 'create_exclusive' && match(name, /^t-.*\.json$/)) {
		admission_probe = true;
		assert_throws(() => backup.inspect(admission_race.app, admission_seed.id), 'BUSY');
	}
};
backup.inspect(admission_race.app, admission_seed.id);
assert_equal(admission_probe, true, 'admission race did not reach journal reservation');
assert_equal(length(transaction_names(admission_race)), 1,
	'reentrant admission created a second transaction');

let capacity = make_app();
let capacity_seed = seed_import(capacity,
	'00000000000000000000000000000104', { 'settings/settings.json': '{ }\n' });
for (let i = 0; i < 64; i++) backup.inspect(capacity.app, capacity_seed.id);
assert_equal(length(transaction_names(capacity)), 64);
let capacity_stages = length(capacity.filesystem.lsdir('/tmp/miclash/backup-inspected'));
assert_throws(() => backup.inspect(capacity.app, capacity_seed.id), 'BUSY');
assert_equal(length(transaction_names(capacity)), 64, '65th admission added a journal');
assert_equal(length(capacity.filesystem.lsdir('/tmp/miclash/backup-inspected')),
	capacity_stages, '65th admission added a staging artifact');
backup.list(capacity.app);
assert_equal(length(transaction_names(capacity)), 64,
	'bounded active transactions were not recoverable');

function create_crash(operation, predicate, suffix) {
	let box = make_app(), fired = false;
	box.app.secure_fs.after = (seen_operation, directory, name, extra) => {
		if (!fired && seen_operation == operation && predicate(name, extra)) {
			fired = true; die('simulated-process-crash-' + suffix);
		}
	};
	assert_throws(() => backup.create(box.app), 'INTERNAL');
	box.app.secure_fs.after = null;
	backup.list(box.app); // fresh public entry/new domain instance recovery
	assert_equal(length(box.filesystem.lsdir('/etc/miclash/backups')), 0,
		'create crash residue survived ' + suffix);
	assert_equal(length(transaction_names(box)), 0, 'journal survived recovery ' + suffix);
};
create_crash('create_file_fsync', (name) => match(name, /\.tar\.tmp$/), 'temp-write');
create_crash('create_parent_fsync', (name) => match(name, /\.tar\.tmp$/), 'temp-parent-fsync');
create_crash('create_file_fsync', (name) => match(name, /^b-[0-9]{13}-[0-9a-f]{32}\.json$/),
	'sidecar-write');
create_crash('rename', (name) => match(name, /\.tar$/), 'archive-publish');

for (let stage in [ 'replace_temp_fsync', 'replace_rename', 'replace_parent_fsync' ]) {
	let box = make_app(), fired = false;
	box.app.secure_fs.after = (operation, directory, name, extra) => {
		if (!fired && operation == stage && match(name, /^t-.*\.json$/)) {
			fired = true; die('journal-transition-' + stage);
		}
	};
	assert_throws(() => backup.create(box.app), 'INTERNAL');
	assert_equal(fired, true, stage + ' fault did not fire');
	box.app.secure_fs.after = null;
	backup.list(box.app);
	assert_equal(length(transaction_names(box)), 0, stage + ' journal survived recovery');
	assert_equal(length(box.filesystem.lsdir('/etc/miclash/backups')), 0,
		stage + ' artifact survived recovery');
}

// Inspection marker precedes staging writes; partial and never-ready previews
// are recovered on a later public entry, while active previews survive.
let inspect_order = make_app();
let inspect_order_seed = seed_import(inspect_order,
	'00000000000000000000000000000093', { 'settings/settings.json': '{ }\n' });
let inspect_marker_seen = false;
inspect_order.app.secure_fs.before = (operation, directory, name, extra) => {
	if (operation == 'create_exclusive' && name == 'settings.json')
		inspect_marker_seen = length(transaction_names(inspect_order)) == 1;
};
let inspect_order_preview = backup.inspect(inspect_order.app, inspect_order_seed.id);
assert_equal(inspect_marker_seen, true, 'inspection wrote member before transaction marker');
assert_equal(length(transaction_names(inspect_order)), 1,
	'active preview must retain recovery authority');

let partial_inspect = make_app();
let partial_seed = seed_import(partial_inspect,
	'00000000000000000000000000000094', { 'settings/settings.json': '{ }\n' });
let partial_fired = false;
partial_inspect.app.secure_fs.after = (operation, directory, name, extra) => {
	if (!partial_fired && operation == 'create_exclusive' && name == 'settings.json') {
		partial_fired = true; die('simulated-inspect-crash');
	}
};
assert_throws(() => backup.inspect(partial_inspect.app, partial_seed.id), 'CORRUPT_STATE');
partial_inspect.app.secure_fs.after = null;
backup.list(partial_inspect.app);
assert_equal(length(partial_inspect.filesystem.lsdir('/tmp/miclash/backup-inspected')), 0);
assert_equal(length(transaction_names(partial_inspect)), 0);

inspect_order.runtime.clock.advance(900001);
backup.list(inspect_order.app);
assert_equal(inspect_order.filesystem.lstat('/tmp/miclash/backup-inspected/' +
	inspect_order_preview.id), null, 'expired preview was not recovered on list');
assert_equal(length(transaction_names(inspect_order)), 0);

// Prune intent is journaled before the first rename.
let prune_marker = make_app();
backup.create(prune_marker.app); prune_marker.runtime.clock.advance(1);
backup.create(prune_marker.app);
let prune_marker_seen = false;
prune_marker.app.secure_fs.before = (operation, directory, name, extra) => {
	if (operation == 'rename' && match(name, /\.json$/))
		prune_marker_seen = length(transaction_names(prune_marker)) == 1;
};
backup.prune(prune_marker.app, { retain: 1 });
assert_equal(prune_marker_seen, true, 'prune renamed before transaction marker');
assert_equal(length(transaction_names(prune_marker)), 0);

// Unknown or stale journal state is ambiguity: fail closed without mutation.
let foreign_journal = make_app();
mkdirs(foreign_journal.filesystem, [ '/tmp/miclash/backup-transactions' ]);
let foreign_journal_path = '/tmp/miclash/backup-transactions/foreign';
foreign_journal.filesystem.files[foreign_journal_path] = 'foreign';
foreign_journal.filesystem.bump_inode(foreign_journal_path);
foreign_journal.filesystem.set_mode(foreign_journal_path, 0o600);
foreign_journal.filesystem.set_uid(foreign_journal_path, 0);
assert_throws(() => backup.list(foreign_journal.app), 'INTERNAL');
assert_equal(foreign_journal.filesystem.readfile(foreign_journal_path), 'foreign');

let report_crash = make_app();
let report_crash_seed = seed_import(report_crash,
	'00000000000000000000000000000095', { 'settings/settings.json': '{ }\n' });
let report_fired = false;
report_crash.app.secure_fs.after = (operation, directory, name, extra) => {
	if (!report_fired && operation == 'create_exclusive' && name == '.inspection.json') {
		report_fired = true; die('simulated-report-crash');
	}
};
assert_throws(() => backup.inspect(report_crash.app, report_crash_seed.id), 'CORRUPT_STATE');
report_crash.app.secure_fs.after = null;
backup.list(report_crash.app);
assert_equal(length(report_crash.filesystem.lsdir('/tmp/miclash/backup-inspected')), 0);
assert_equal(length(transaction_names(report_crash)), 0);

function prune_crash(operation, predicate, label) {
	let box = make_app();
	backup.create(box.app); box.runtime.clock.advance(1); backup.create(box.app);
	let fired = false;
	box.app.secure_fs.after = (seen, directory, name, extra) => {
		if (!fired && seen == operation && predicate(name, extra)) {
			fired = true; die('simulated-prune-crash-' + label);
		}
	};
	assert_throws(() => backup.prune(box.app, { retain: 1 }), 'INTERNAL');
	box.app.secure_fs.after = null;
	let visible = backup.list(box.app);
	assert_equal(length(visible), 1, 'prune did not converge after ' + label);
	assert_equal(length(transaction_names(box)), 0, 'prune journal survived ' + label);
};
prune_crash('rename', (name) => match(name, /\.prune-.*\.json$/), 'side-rename');
prune_crash('rename', (name) => match(name, /\.prune-.*\.tar$/), 'archive-rename');
prune_crash('unlink', (name) => match(name, /\.prune-.*\.tar$/), 'archive-unlink');

let stale = make_app(), stale_seed = seed_import(stale,
	'00000000000000000000000000000096', { 'settings/settings.json': '{ }\n' });
let stale_preview = backup.inspect(stale.app, stale_seed.id);
let stale_name = transaction_names(stale)[0];
let stale_path = '/tmp/miclash/backup-transactions/' + stale_name;
let stale_record = json(stale.filesystem.readfile(stale_path));
stale_record.created_at = 0; stale_record.expires_at = 900000;
stale.filesystem.files[stale_path] = sprintf('%J\n', stale_record);
stale.filesystem.bump_inode(stale_path); stale.filesystem.set_mode(stale_path, 0o600);
assert_throws(() => backup.list(stale.app), 'INTERNAL');
assert_true(stale.filesystem.lstat('/tmp/miclash/backup-inspected/' + stale_preview.id) != null,
	'stale ambiguous journal mutated its registered stage');

let too_many = make_app();
mkdirs(too_many.filesystem, [ '/tmp/miclash/backup-transactions' ]);
for (let i = 0; i < 65; i++) {
	let name = sprintf('/tmp/miclash/backup-transactions/t-%013d-%032x.json',
		1700000000000, i + 1);
	too_many.filesystem.files[name] = 'foreign'; too_many.filesystem.bump_inode(name);
	too_many.filesystem.set_mode(name, 0o600); too_many.filesystem.set_uid(name, 0);
}
assert_throws(() => backup.list(too_many.app), 'INTERNAL');
assert_equal(length(transaction_names(too_many)), 65, 'journal count ambiguity mutated files');

// A directory/inode replacement at cleanup is atomically refused; no link is
// followed and the foreign target remains unchanged.
let cleanup_race = make_app(), cleanup_seed = seed_import(cleanup_race,
	'00000000000000000000000000000097', { 'settings/settings.json': '{ }\n' });
cleanup_race.filesystem.files['/opt/clash/cleanup-foreign'] = 'foreign-cleanup';
cleanup_race.filesystem.set_mode('/opt/clash/cleanup-foreign', 0o600);
cleanup_race.filesystem.set_uid('/opt/clash/cleanup-foreign', 0);
let cleanup_failed = false, cleanup_swapped = false;
cleanup_race.app.secure_fs.after = (operation, directory, name, extra) => {
	if (!cleanup_failed && operation == 'create_exclusive' && name == 'settings.json') {
		cleanup_failed = true; die('force-cleanup');
	}
};
cleanup_race.app.secure_fs.before = (operation, directory, name, extra) => {
	if (!cleanup_swapped && operation == 'rmdir' && match(name, /^x-/)) {
		cleanup_swapped = true;
		cleanup_race.filesystem.set_symlink(directory.opaque + '/' + name,
			'/opt/clash/cleanup-foreign');
	}
};
assert_throws(() => backup.inspect(cleanup_race.app, cleanup_seed.id), 'CORRUPT_STATE');
assert_equal(cleanup_race.filesystem.readfile('/opt/clash/cleanup-foreign'), 'foreign-cleanup');

let unsafe_temp = make_app(), unsafe_temp_fired = false;
unsafe_temp.app.secure_fs.after = (operation, directory, name, extra) => {
	if (!unsafe_temp_fired && operation == 'create_exclusive' && match(name, /\.tar\.tmp$/)) {
		unsafe_temp_fired = true;
		unsafe_temp.filesystem.set_mode(directory.opaque + '/' + name, 0o644);
	}
};
assert_throws(() => backup.create(unsafe_temp.app,
	{ include_secrets: true }, 'system'), 'INTERNAL');
unsafe_temp.app.secure_fs.after = null;
backup.list(unsafe_temp.app);
assert_equal(length(unsafe_temp.filesystem.lsdir('/etc/miclash/backups')), 0,
	'0644 secret archive temp survived recovery');
assert_equal(length(transaction_names(unsafe_temp)), 0);

let never_returned = make_app();
let never_seed = seed_import(never_returned,
	'00000000000000000000000000000098', { 'settings/settings.json': '{ }\n' });
let ready_fired = false;
never_returned.app.secure_fs.after = (operation, directory, name, extra) => {
	if (!ready_fired && operation == 'replace_atomic' && match(name, /^t-.*\.json$/)) {
		let record = json(never_returned.filesystem.readfile(directory.opaque + '/' + name));
		if (record.phase == 'ready') { ready_fired = true; die('never-returned-preview'); }
	}
};
assert_throws(() => backup.inspect(never_returned.app, never_seed.id), 'CORRUPT_STATE');
never_returned.app.secure_fs.after = null;
backup.list(never_returned.app);
assert_equal(length(never_returned.filesystem.lsdir('/tmp/miclash/backup-inspected')), 0);
assert_equal(length(transaction_names(never_returned)), 0);

let late_foreign = make_app(), late_seed = seed_import(late_foreign,
	'00000000000000000000000000000099', { 'settings/settings.json': '{ }\n' });
let late_failed = false, late_inserted = false, late_path = null;
late_foreign.app.secure_fs.after = (operation, directory, name, extra) => {
	if (!late_failed && operation == 'create_exclusive' && name == 'settings.json') {
		late_failed = true; die('force-late-cleanup');
	}
};
late_foreign.app.secure_fs.before = (operation, directory, name, extra) => {
	if (!late_inserted && operation == 'unlink' && name == 'settings.json') {
		late_inserted = true;
		let parts = split(directory.opaque, '/'); pop(parts);
		late_path = join('/', parts) + '/unregistered';
		late_foreign.filesystem.files[late_path] = 'foreign-late';
		late_foreign.filesystem.bump_inode(late_path);
		late_foreign.filesystem.set_mode(late_path, 0o400);
		late_foreign.filesystem.set_uid(late_path, 0);
	}
};
assert_throws(() => backup.inspect(late_foreign.app, late_seed.id), 'CORRUPT_STATE');
assert_equal(late_foreign.filesystem.readfile(late_path), 'foreign-late',
	'unregistered late arrival was deleted by cleanup');
late_foreign.app.secure_fs.after = null; late_foreign.app.secure_fs.before = null;
assert_throws(() => backup.list(late_foreign.app), 'INTERNAL');
assert_equal(late_foreign.filesystem.readfile(late_path), 'foreign-late');
cleanup_race.app.secure_fs.after = null; cleanup_race.app.secure_fs.before = null;
assert_throws(() => backup.list(cleanup_race.app), 'INTERNAL');
assert_equal(cleanup_race.filesystem.readfile('/opt/clash/cleanup-foreign'), 'foreign-cleanup');
