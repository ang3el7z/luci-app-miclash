import { assert_equal, assert_throws, assert_true } from './testlib.uc';
import * as fakes from './fakes.uc';
import * as devices from 'miclash.devices';

const BOOT = '12345678-1234-1234-1234-123456789abc';
const JOURNAL = '/etc/miclash/device-policies.json';
let native = require('uci');
let config_dir = getenv('MICLASH_UCI_CONFIG_DIR');
let delta_dir = getenv('MICLASH_UCI_DELTA_DIR');
assert_true(type(config_dir) == 'string' && type(delta_dir) == 'string');

let filesystem = fakes.fs({
	'/proc/sys/kernel/random/boot_id': BOOT + '\n',
	'/proc/8200/stat': '8200 (native uci test) S ' +
		join(' ', [ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 333 ]) + '\n'
});
for (let path in [ '/etc', '/etc/miclash', '/var', '/var/run', '/var/run/miclash' ])
	filesystem.mkdir(path);
filesystem.set_mode('/etc', 0o755);
filesystem.set_mode('/etc/miclash', 0o700);
filesystem.set_mode('/var/run/miclash', 0o700);

let state = { commits: 0, fail_after_commit: false };
function cursor() {
	let raw = native.cursor(config_dir, delta_dir, '');
	assert_true(raw != null, 'native UCI cursor unavailable');
	return {
		_raw: raw,
		get: function(config, section, option) { return this._raw.get(config, section, option); },
		get_all: function(config, section) { return section == null
			? this._raw.get_all(config) : this._raw.get_all(config, section); },
		set: function(config, section, option, value) { return value == null
			? this._raw.set(config, section, option) : this._raw.set(config, section, option, value); },
		delete: function(config, section, option) { return option == null
			? this._raw.delete(config, section) : this._raw.delete(config, section, option); },
		changes: function(config) { return this._raw.changes(config); },
		revert: function(config) { return this._raw.revert(config); },
		commit: function(config) {
			let result = this._raw.commit(config);
			if (result === true) {
				state.commits++;
				if (state.fail_after_commit) {
					state.fail_after_commit = false;
					filesystem.fail_rename_once_to = JOURNAL;
				}
			}
			return result;
		}
	};
};
function app() {
	return {
		fs: filesystem, digest: fakes.digest(filesystem), clock: fakes.clock(1710000000000),
		random: fakes.entropy(), uci: { cursor }, core_available: true,
		mutation_lock_self: { boot: BOOT, pid: 8200, start: 333 }, device_cache: {}
	};
};

let first_app = app(), before = state.commits;
let created = devices.policy_set(first_app, { scope: 'device', mac: 'ac:bb:cc:dd:ee:80',
	action: 'proxy', schedule: null });
assert_equal(state.commits, before + 1, 'native create performs exactly one UCI commit');
assert_equal(length(devices.policy_list(app())), 1, 'fresh cursor/restart lists native-created section');

before = state.commits;
let updated = devices.policy_set(app(), { id: created.id, expected_revision: 1, scope: 'device',
	mac: created.mac, action: 'block', schedule: null });
assert_equal(updated.revision, 2);
assert_equal(state.commits, before + 1, 'native update performs exactly one UCI commit');
assert_equal(devices.policy_list(app())[0].action, 'block', 'native update survives restart');

state.fail_after_commit = true;
before = state.commits;
assert_throws(() => devices.policy_set(app(), { scope: 'device', mac: 'ac:bb:cc:dd:ee:81',
	action: 'proxy', schedule: null }), 'INTERNAL');
assert_equal(state.commits, before + 1, 'post-commit journal failure still has exactly one UCI commit');
assert_equal(length(devices.policy_list(app())), 2,
	'prepared journal recognizes committed native UCI state after restart');

for (let policy in devices.policy_list(app())) {
	before = state.commits;
	assert_true(devices.policy_delete(app(), policy.id, policy.revision));
	assert_equal(state.commits, before + 1, 'native delete performs exactly one UCI commit');
}
assert_equal(length(devices.policy_list(app())), 0, 'native whole-section delete survives restart');
print('native UCI device policy integration passed\n');
