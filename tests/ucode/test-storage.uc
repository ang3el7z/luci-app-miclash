import { assert_equal, assert_match, assert_throws, assert_true } from './testlib.uc';
import * as fakes from './fakes.uc';
import * as storage from 'miclash.storage';

function runtime(initial) {
	let fake_fs = fakes.fs(initial);
	return {
		fs: fake_fs,
		digest: fakes.digest(fake_fs),
		clock: fakes.clock(1700000000000),
		paths: {
			run: '/var/run/miclash',
			tmp: '/tmp/miclash'
		}
	};
};

let rt = runtime({ '/opt/clash/config.yaml': 'old' });
assert_equal(storage.atomic_write(rt, '/opt/clash/config.yaml', 'new', 0o600), true);
assert_equal(rt.fs.readfile('/opt/clash/config.yaml'), 'new');
assert_equal(rt.fs.mode('/opt/clash/config.yaml'), 0o600);
assert_equal(length(rt.fs.temp_paths()), 1);
assert_match(rt.fs.temp_paths()[0],
	/^\/opt\/clash\/\.config\.yaml\.miclash\.[A-Za-z0-9_-]+\.[A-Za-z0-9]+$/);
assert_equal(rt.fs.calls.open[0].mode, 'wx');

// Privileged authority directories are accepted only when canonical,
// root-owned and not group/world writable. They are never silently chmodded.
for (let mode in [ 0o0777, 0o0775, 0o0752 ]) {
	let insecure = runtime({ '/etc/miclash/.keep': '' });
	insecure.fs.set_mode('/etc/miclash', mode);
	assert_throws(() => storage.atomic_write(insecure,
		'/etc/miclash/state.json', '{}', 0o600), 'INVALID_ARGUMENT');
	assert_equal(insecure.fs.exists('/etc/miclash/state.json'), false);
	assert_equal(length(insecure.fs.calls.chmod), 0,
		'insecure authority directory was silently repaired');
}
for (let owner in [ { uid: 1000, gid: 0 }, { uid: 0, gid: 1000 } ]) {
	let foreign = runtime({ '/etc/miclash/.keep': '' });
	foreign.fs.set_uid('/etc/miclash', owner.uid);
	foreign.fs.set_gid('/etc/miclash', owner.gid);
	assert_throws(() => storage.atomic_write(foreign,
		'/etc/miclash/state.json', '{}', 0o600), 'INVALID_ARGUMENT');
}
for (let mode in [ 0o0700, 0o0755 ]) {
	let secure = runtime({ '/etc/miclash/.keep': '' });
	secure.fs.set_mode('/etc/miclash', mode);
	assert_equal(storage.atomic_write(secure,
		'/etc/miclash/state.json', '{}', 0o600), true);
}

// OpenWrt 25 overlayfs may report the merged directory and a newly-created
// upper-layer file with different st_dev values. The pathname is still an
// exclusive member of the same trusted directory and rename is authoritative.
let overlay_write = runtime({ '/etc/miclash/.keep': '' });
overlay_write.fs.set_device('/etc/miclash', 20);
overlay_write.fs.on_lstat = (path) => {
	if (index(path, '/etc/miclash/.state.json.miclash.') == 0)
		overlay_write.fs.set_device(path, 21);
};
assert_equal(storage.atomic_write(overlay_write,
	'/etc/miclash/state.json', '{}', 0o600), true);
assert_equal(overlay_write.fs.readfile('/etc/miclash/state.json'), '{}');

let corrupt_authority = runtime({ '/etc/miclash': 'attacker' });
assert_throws(() => storage.atomic_write(corrupt_authority,
	'/etc/miclash/state.json', '{}', 0o600), 'INVALID_ARGUMENT');
let linked_authority = runtime({ '/tmp/miclash/.keep': '' });
linked_authority.fs.set_symlink('/etc/miclash', '/tmp/miclash');
assert_throws(() => storage.atomic_write(linked_authority,
	'/etc/miclash/state.json', '{}', 0o600), 'INVALID_ARGUMENT');

let authority_race = runtime({ '/etc/miclash/.keep': '' });
authority_race.fs.on_lstat = (path, count) => {
	if (path == '/etc/miclash' && count == 2)
		authority_race.fs.bump_inode(path);
};
assert_throws(() => storage.atomic_write(authority_race,
	'/etc/miclash/state.json', '{}', 0o600), 'INVALID_ARGUMENT');
assert_equal(authority_race.fs.exists('/etc/miclash/state.json'), false);

let partial = runtime({ '/opt/clash/config.yaml': 'old' });
partial.fs.write_results = [ 2, 1, 3 ];
assert_equal(storage.atomic_write(partial, '/opt/clash/config.yaml', 'abcdef', 0o640), true);
assert_equal(partial.fs.readfile('/opt/clash/config.yaml'), 'abcdef');
assert_equal(length(partial.fs.calls.write), 3);

let write_failure = runtime({
	'/opt/clash/config.yaml': 'old',
	'/opt/clash/.config.yaml.miclash.foreign.owned': 'foreign'
});
write_failure.fs.write_results = [ 2, null ];
assert_throws(() => storage.atomic_write(
	write_failure, '/opt/clash/config.yaml', 'new-data', 0o600), 'INTERNAL');
assert_equal(write_failure.fs.readfile('/opt/clash/config.yaml'), 'old');
assert_equal(write_failure.fs.readfile(
	'/opt/clash/.config.yaml.miclash.foreign.owned'), 'foreign');
assert_equal(write_failure.fs.exists(write_failure.fs.temp_paths()[0]), false);

for (let failure in [ 'flush', 'close', 'chmod', 'rename' ]) {
	let interrupted = runtime({ '/opt/clash/config.yaml': 'old' });
	interrupted.fs.fail_on = failure;
	assert_throws(() => storage.atomic_write(
		interrupted, '/opt/clash/config.yaml', 'new', 0o600), 'INTERNAL');
	assert_equal(interrupted.fs.readfile('/opt/clash/config.yaml'), 'old');
	assert_equal(length(interrupted.fs.temp_paths()), 1);
	assert_equal(interrupted.fs.exists(interrupted.fs.temp_paths()[0]), false);
}

let silent_close_failure = runtime({ '/opt/clash/config.yaml': 'old' });
silent_close_failure.fs.corrupt_on_close = true;
assert_throws(() => storage.atomic_write(
	silent_close_failure, '/opt/clash/config.yaml', 'new', 0o600), 'INTERNAL');
assert_equal(silent_close_failure.fs.readfile('/opt/clash/config.yaml'), 'old');
assert_equal(silent_close_failure.fs.exists(silent_close_failure.fs.temp_paths()[0]), false);

let writers = runtime({ '/opt/clash/config.yaml': 'old' });
assert_equal(storage.atomic_write(writers, '/opt/clash/config.yaml', 'first', 0o600), true);
assert_equal(storage.atomic_write(writers, '/opt/clash/config.yaml', 'second', 0o600), true);
assert_equal(length(writers.fs.temp_paths()), 2);
assert_true(writers.fs.temp_paths()[0] != writers.fs.temp_paths()[1]);
assert_equal(writers.fs.readfile('/opt/clash/config.yaml'), 'second');

let collided = runtime({ '/opt/clash/config.yaml': 'old' });
collided.fs.collide_next_open = true;
assert_equal(storage.atomic_write(collided,
	'/opt/clash/config.yaml', 'after-collision', 0o600), true);
assert_equal(collided.fs.readfile('/opt/clash/config.yaml'), 'after-collision');

let large_data = sprintf('%020000d', 0);
let digest_write = runtime({ '/opt/clash/config.yaml': 'old' });
assert_equal(storage.atomic_write(
	digest_write, '/opt/clash/config.yaml', large_data, 0o600), true);
assert_equal(length(digest_write.digest.calls.data), 1);
assert_equal(length(digest_write.digest.calls.file), 1);
assert_equal(index(digest_write.fs.calls.readfile,
	digest_write.fs.temp_paths()[0]), -1);

let overlay_source = '/opt/clash/.config.yaml.miclash.1700000000000-1.abcdef01';
let overlay_replace = runtime({ [overlay_source]: 'new', '/opt/clash/config.yaml': 'old' });
overlay_replace.fs.set_device('/opt/clash', 20);
overlay_replace.fs.set_device(overlay_source, 21);
assert_equal(storage.atomic_replace(
	overlay_replace, overlay_source, '/opt/clash/config.yaml'), true);
assert_equal(overlay_replace.fs.readfile('/opt/clash/config.yaml'), 'new');

let owned_source = '/opt/clash/.config.yaml.miclash.1700000000000-2.abcdef02';
let replace = runtime({ [owned_source]: 'new', '/opt/clash/config.yaml': 'old' });
assert_equal(storage.atomic_replace(
	replace, owned_source, '/opt/clash/config.yaml'), true);
assert_equal(replace.fs.readfile('/opt/clash/config.yaml'), 'new');
assert_equal(replace.fs.exists(owned_source), false);

let foreign_source = runtime({
	'/opt/clash/foreign': 'foreign', '/opt/clash/config.yaml': 'old'
});
assert_throws(() => storage.atomic_replace(
	foreign_source, '/opt/clash/foreign', '/opt/clash/config.yaml'), 'INVALID_ARGUMENT');

let other_directory = runtime({
	'/tmp/miclash/.config.yaml.miclash.1700000000000-3.abcdef03': 'foreign',
	'/opt/clash/config.yaml': 'old'
});
assert_throws(() => storage.atomic_replace(other_directory,
	'/tmp/miclash/.config.yaml.miclash.1700000000000-3.abcdef03', '/opt/clash/config.yaml'),
	'INVALID_ARGUMENT');

let outside_root = runtime({
	'/etc/.state.miclash.1700000000000-4.abcdef04': 'foreign', '/etc/state': 'old'
});
assert_throws(() => storage.atomic_replace(
	outside_root, '/etc/.state.miclash.1700000000000-4.abcdef04', '/etc/state'), 'INVALID_ARGUMENT');

let linked_root = runtime({
	'/tmp/miclash/.config.yaml.miclash.1700000000000-5.abcdef05': 'new',
	'/tmp/miclash/config.yaml': 'old'
});
linked_root.fs.set_symlink('/opt/clash', '/tmp/miclash');
assert_throws(() => storage.atomic_replace(linked_root,
	'/opt/clash/.config.yaml.miclash.1700000000000-5.abcdef05', '/opt/clash/config.yaml'),
	'INVALID_ARGUMENT');

let linked_parent = runtime({
	'/tmp/miclash/.config.yaml.miclash.1700000000000-6.abcdef06': 'new',
	'/tmp/miclash/config.yaml': 'old'
});
linked_parent.fs.set_symlink('/opt/clash/profiles', '/tmp/miclash');
assert_throws(() => storage.atomic_replace(linked_parent,
	'/opt/clash/profiles/.config.yaml.miclash.1700000000000-6.abcdef06',
	'/opt/clash/profiles/config.yaml'), 'INVALID_ARGUMENT');

let linked_source = runtime({
	'/opt/clash/target': 'new', '/opt/clash/config.yaml': 'old'
});
linked_source.fs.set_symlink(
	'/opt/clash/.config.yaml.miclash.1700000000000-7.abcdef07', '/opt/clash/target');
assert_throws(() => storage.atomic_replace(linked_source,
	'/opt/clash/.config.yaml.miclash.1700000000000-7.abcdef07', '/opt/clash/config.yaml'),
	'INVALID_ARGUMENT');

let hardlinked_source_path = '/opt/clash/.config.yaml.miclash.1700000000000-8.abcdef08';
let hardlinked_source = runtime({
	[hardlinked_source_path]: 'new', '/opt/clash/config.yaml': 'old'
});
hardlinked_source.fs.set_nlink(hardlinked_source_path, 2);
assert_throws(() => storage.atomic_replace(hardlinked_source,
	hardlinked_source_path, '/opt/clash/config.yaml'), 'INVALID_ARGUMENT');

for (let suffix in [ 'op-9.abcdef09', '1700000000000-9.abc',
	'1700000000000-9.abcdefghi', '1700000000000-9.abcdef012' ]) {
	let invalid_source = '/opt/clash/.config.yaml.miclash.' + suffix;
	let invalid_owner = runtime({ [invalid_source]: 'new', '/opt/clash/config.yaml': 'old' });
	assert_throws(() => storage.atomic_replace(
		invalid_owner, invalid_source, '/opt/clash/config.yaml'), 'INVALID_ARGUMENT');
}

let changing_source_path = '/opt/clash/.config.yaml.miclash.1700000000000-10.abcdef10';
let changing_source = runtime({
	[changing_source_path]: 'new', '/opt/clash/config.yaml': 'old'
});
changing_source.fs.on_lstat = (path, count) => {
	if (path == changing_source_path && count == 2)
		changing_source.fs.files[path] += '-changed';
};
assert_throws(() => storage.atomic_replace(changing_source,
	changing_source_path, '/opt/clash/config.yaml'), 'INVALID_ARGUMENT');

let changing_parent_path = '/opt/clash/.config.yaml.miclash.1700000000000-11.abcdef11';
let changing_parent = runtime({
	[changing_parent_path]: 'new', '/opt/clash/config.yaml': 'old'
});
changing_parent.fs.on_lstat = (path, count) => {
	if (path == '/opt/clash' && count == 2)
		changing_parent.fs.bump_inode(path);
};
assert_throws(() => storage.atomic_replace(changing_parent,
	changing_parent_path, '/opt/clash/config.yaml'), 'INVALID_ARGUMENT');

let json_rt = runtime({
	'/etc/miclash/state.json': '{"revision":3}',
	'/etc/miclash/broken.json': '{not json}'
});
assert_equal(storage.read_json(json_rt, '/etc/miclash/state.json').revision, 3);
assert_throws(() => storage.read_json(
	json_rt, '/etc/miclash/broken.json'), 'CORRUPT_STATE');
assert_equal(storage.write_json(
	json_rt, '/etc/miclash/state.json', { revision: 4 }, 0o600), true);
assert_equal(storage.read_json(json_rt, '/etc/miclash/state.json').revision, 4);
assert_equal(json_rt.fs.mode('/etc/miclash/state.json'), 0o600);

assert_equal(storage.sha256('abc'),
	'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');

assert_equal(storage.safe_name('backup-1.json'), 'backup-1.json');
for (let unsafe in [ '', '.', '..', '../state', 'a/b', 'a\\b', '.hidden' ])
	assert_throws(() => storage.safe_name(unsafe), 'INVALID_ARGUMENT');
for (let unsafe_path in [ 'relative/state', '/tmp/../etc/state', '/tmp//state', '/tmp/state/' ])
	assert_throws(() => storage.atomic_write(rt, unsafe_path, 'x', 0o600), 'INVALID_ARGUMENT');

let cleanup = runtime({
	'/var/run/miclash/operation.json': 'run',
	'/tmp/miclash/download': 'tmp',
	'/tmp/miclash/.download.miclash.1700000000000-12.abcdef12': 'staged',
	'/tmp/miclash/.download.miclash.crash-1.abc123': 'foreign-stage',
	'/tmp/miclash/.download.miclash.1700000000000-12.abc': 'short-stage',
	'/tmp/miclash/.foreign': 'foreign',
	'/tmp/not-miclash/keep': 'outside',
	'/opt/clash/config.yaml': 'config'
});
cleanup.fs.set_symlink('/tmp/miclash/config-link', '/opt/clash/config.yaml');
assert_equal(storage.cleanup_runtime(cleanup), 3);
assert_equal(cleanup.fs.exists('/var/run/miclash/operation.json'), false);
assert_equal(cleanup.fs.exists('/tmp/miclash/download'), false);
assert_equal(cleanup.fs.exists(
	'/tmp/miclash/.download.miclash.1700000000000-12.abcdef12'), false);
assert_equal(cleanup.fs.readfile(
	'/tmp/miclash/.download.miclash.crash-1.abc123'), 'foreign-stage');
assert_equal(cleanup.fs.readfile(
	'/tmp/miclash/.download.miclash.1700000000000-12.abc'), 'short-stage');
assert_equal(cleanup.fs.readfile('/tmp/miclash/.foreign'), 'foreign');
assert_equal(cleanup.fs.exists('/tmp/miclash/config-link'), true);
assert_equal(cleanup.fs.readfile('/tmp/not-miclash/keep'), 'outside');
assert_equal(cleanup.fs.readfile('/opt/clash/config.yaml'), 'config');

let linked_cleanup_root = runtime({
	'/opt/clash/operation.json': 'outside',
	'/tmp/miclash/download': 'owned'
});
linked_cleanup_root.fs.set_symlink('/var/run/miclash', '/opt/clash');
assert_equal(storage.cleanup_runtime(linked_cleanup_root), 1);
assert_equal(linked_cleanup_root.fs.readfile('/opt/clash/operation.json'), 'outside');
assert_equal(linked_cleanup_root.fs.exists('/var/run/miclash'), true);

let openwrt_alias = runtime({
	'/tmp/run/miclash/operation.json': 'run', '/tmp/miclash/download': 'tmp'
});
openwrt_alias.fs.set_symlink('/var', '/tmp');
assert_equal(storage.cleanup_runtime(openwrt_alias), 2);
assert_equal(openwrt_alias.fs.exists('/tmp/run/miclash/operation.json'), false);

let alias_source = '/var/run/miclash/.state.miclash.1700000000000-13.abcdef13';
let openwrt_alias_replace = runtime({
	'/tmp/run/miclash/.state.miclash.1700000000000-13.abcdef13': 'new',
	'/tmp/run/miclash/state': 'old'
});
openwrt_alias_replace.fs.set_symlink('/var', '/tmp');
assert_equal(storage.atomic_replace(
	openwrt_alias_replace, alias_source, '/var/run/miclash/state'), true);
assert_equal(openwrt_alias_replace.fs.files['/tmp/run/miclash/state'], 'new');
