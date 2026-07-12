import { assert_equal, assert_match, assert_throws, assert_true } from './testlib.uc';
import * as fakes from './fakes.uc';
import * as storage from 'miclash.storage';

function runtime(initial) {
	return {
		fs: fakes.fs(initial),
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

let cross_device = runtime({ '/opt/clash/source': 'new', '/opt/clash/config.yaml': 'old' });
cross_device.fs.set_device('/opt/clash/source', 2);
assert_throws(() => storage.atomic_replace(
	 cross_device, '/opt/clash/source', '/opt/clash/config.yaml'), 'INVALID_ARGUMENT');
assert_equal(cross_device.fs.readfile('/opt/clash/source'), 'new');
assert_equal(cross_device.fs.readfile('/opt/clash/config.yaml'), 'old');

let replace = runtime({ '/opt/clash/source': 'new', '/opt/clash/config.yaml': 'old' });
assert_equal(storage.atomic_replace(
	replace, '/opt/clash/source', '/opt/clash/config.yaml'), true);
assert_equal(replace.fs.readfile('/opt/clash/config.yaml'), 'new');
assert_equal(replace.fs.exists('/opt/clash/source'), false);

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
assert_match(storage.sha256('tests/fixtures/settings/legacy-full', true), /^[0-9a-f]{64}$/);

assert_equal(storage.safe_name('backup-1.json'), 'backup-1.json');
for (let unsafe in [ '', '.', '..', '../state', 'a/b', 'a\\b', '.hidden' ])
	assert_throws(() => storage.safe_name(unsafe), 'INVALID_ARGUMENT');
for (let unsafe_path in [ 'relative/state', '/tmp/../etc/state', '/tmp//state', '/tmp/state/' ])
	assert_throws(() => storage.atomic_write(rt, unsafe_path, 'x', 0o600), 'INVALID_ARGUMENT');

let cleanup = runtime({
	'/var/run/miclash/operation.json': 'run',
	'/tmp/miclash/download': 'tmp',
	'/tmp/not-miclash/keep': 'outside',
	'/opt/clash/config.yaml': 'config'
});
assert_equal(storage.cleanup_runtime(cleanup), 2);
assert_equal(cleanup.fs.exists('/var/run/miclash/operation.json'), false);
assert_equal(cleanup.fs.exists('/tmp/miclash/download'), false);
assert_equal(cleanup.fs.readfile('/tmp/not-miclash/keep'), 'outside');
assert_equal(cleanup.fs.readfile('/opt/clash/config.yaml'), 'config');
