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
	let capability = { before: null, after: null, calls: [] };
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
		return clone(filesystem.lstat(parent.opaque + '/' + name));
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
	capability.write = (parent, name, content, options) => {
		directory(parent.opaque, parent.identity);
		let path = parent.opaque + '/' + name;
		hook('before', 'write', parent, name, options);
		if (options.exclusive && filesystem.lstat(path) != null) die('INTERNAL');
		filesystem.files[path] = content; filesystem.bump_inode(path);
		filesystem.set_mode(path, options.mode); filesystem.set_uid(path, options.uid);
		filesystem.set_nlink(path, 1);
		hook('after', 'write', parent, name, options);
		return clone(file(path, null, { ...options, nlink: 1 }));
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
		zeroes(32) + zeroes(32) + zeroes(8) + zeroes(8) + zeroes(155) + zeroes(12);
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

let base = make_app(), created = backup.create(base.app, null, 'luci');
assert_match(created.id, /^b-[0-9]{13}-[0-9a-f]{32}$/);
assert_equal(length(backup.list(base.app)), 1);
let archive_path = '/etc/miclash/backups/' + created.id + '.tar';
let sidecar_path = '/etc/miclash/backups/' + created.id + '.json';
assert_equal(base.filesystem.lstat(archive_path).mode, 0o600);
assert_equal(base.filesystem.lstat(sidecar_path).mode, 0o600);
assert_equal(base.filesystem.lstat('/etc/miclash/backups').mode, 0o700);
let public_bytes = base.filesystem.readfile(archive_path);
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
rejected_bytes('00000000000000000000000000000002', (bytes) => substr(bytes, 0, length(bytes) - 1));
rejected_bytes('00000000000000000000000000000003', (bytes) => bytes + bytes);
rejected_bytes('00000000000000000000000000000004', (bytes) => bytes + 'x');
rejected_bytes('00000000000000000000000000000005', (bytes) =>
	substr(bytes, 0, 148) + '000000' + NUL + ' ' + substr(bytes, 156));

for (let hostile in [
	{ typeflag: '1', linkname: 'settings/settings.json' },
	{ typeflag: '2', linkname: '/etc/passwd' }, { typeflag: '3' }, { typeflag: 'x' }
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
