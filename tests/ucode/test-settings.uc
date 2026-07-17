import { assert_equal, assert_match, assert_throws, assert_true } from './testlib.uc';
import * as runtime from 'miclash.runtime';
import * as settings from 'miclash.settings';
import * as redact from 'miclash.redact';
import * as fakes from './fakes.uc';
import { with_lock } from 'miclash.mutation_lock';

const BOOT = '12345678-1234-1234-1234-123456789abc';
let next_pid = 6000;

function fixture(name) {
	return require('fs').readfile('tests/fixtures/settings/' + name);
};

function process_stat(pid, started) {
	return pid + ' (settings test) S ' +
		join(' ', [ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, started ]) + '\n';
};
function lock_filesystem(identities) {
	let initial = { '/proc/sys/kernel/random/boot_id': BOOT + '\n' };
	for (let identity in identities) initial['/proc/' + identity.pid + '/stat'] =
		process_stat(identity.pid, identity.start);
	let filesystem = fakes.fs(initial);
	for (let path in [ '/var', '/var/run', '/var/run/miclash' ]) filesystem.mkdir(path);
	filesystem.set_mode('/var/run/miclash', 0o700);
	return filesystem;
};
function runtime_for(cursor, filesystem, identity) {
	let rt = runtime.create({ uci: { cursor: () => cursor }, fs: filesystem,
		digest: fakes.digest(filesystem), clock: fakes.clock(1000), random: fakes.entropy() });
	rt.mutation_lock_self = { boot: BOOT, pid: identity.pid, start: identity.start };
	return rt;
};
function fake_runtime(initial) {
	let seeded = initial ?? { miclash: {} };
	seeded.miclash ??= {};
	for (let section in [ 'core', 'interfaces', 'guard', 'memory', 'updates', 'telegram',
		'notifications', 'backup', 'meta' ]) seeded.miclash[section] ??= { '.type': section };
	let cursor = fakes.uci(seeded), identity = { pid: next_pid++, start: 400 };
	return { rt: runtime_for(cursor, lock_filesystem([ identity ]), identity), cursor };
};

function assert_json_equal(actual, expected) {
	assert_equal(sprintf('%J', actual), sprintf('%J', expected));
};

let migrated_env = fake_runtime();
let migrated = settings.migrate_legacy(migrated_env.rt, fixture('legacy-full'));

assert_equal(migrated.core.proxy_mode, 'tproxy');
assert_equal(migrated.core.tun_stack, 'gvisor');
assert_equal(migrated.core.block_quic, false);
assert_equal(migrated.core.use_tmpfs_rules, false);
assert_equal(migrated.core.hwid_enabled, true);
assert_equal(migrated.core.hwid_user_agent, 'MiClash Router');
assert_equal(migrated.core.hwid_device_os, 'OpenWrt 24.10');
assert_match(migrated.core.subscription_url, /main-secret/);
assert_equal(migrated.core.subscription_url_config_yaml, 'https://profile-one.example/sub');
assert_equal(migrated.core.subscription_url_config2_yaml, 'https://profile-two.example/sub');
assert_equal(migrated.core.subscription_url_config3_yaml, 'https://profile-three.example/sub');

assert_equal(migrated.interfaces.mode, 'explicit');
assert_equal(migrated.interfaces.auto_detect_lan, false);
assert_equal(migrated.interfaces.auto_detect_wan, true);
assert_equal(migrated.interfaces.detected_lan, 'br-lan');
assert_equal(migrated.interfaces.detected_wan, 'pppoe-wan');
assert_json_equal(migrated.interfaces.included, [ 'br-lan', 'wlan0' ]);
assert_json_equal(migrated.interfaces.excluded, [ 'wan', 'wwan' ]);

assert_equal(migrated.guard.enabled, true);
assert_equal(migrated.guard.auto_fakeip_whitelist, false);
assert_equal(migrated.memory.enabled, true);
assert_equal(migrated.updates.auto_subscription, false);
assert_equal(migrated.updates.interval_hours, 12);
assert_equal(migrated.updates.miclash_release_channel, 'prerelease');
assert_equal(migrated.updates.mihomo_release_channel, 'prerelease');
assert_equal(migrated.updates.auto_major_miclash, true);
assert_equal(migrated.notifications.auto_hide, false);
assert_json_equal(migrated.telegram, { enabled: false, token: '', user_id: '' });
assert_json_equal(migrated.backup, { enabled: false, retention: 5, include_secrets: false,
	interval_hours: 24, schedule_time: '03:00' });
assert_equal(migrated.meta.schema_version, 1);
assert_equal(migrated_env.cursor.commit_calls, 1);

let defaults = settings.load(fake_runtime().rt);
assert_equal(defaults.core.proxy_mode, 'tproxy');
assert_equal(defaults.core.tun_stack, 'system');
assert_equal(defaults.core.block_quic, true);
assert_equal(defaults.core.use_tmpfs_rules, true);
assert_equal(defaults.core.hwid_enabled, false);
assert_equal(defaults.core.hwid_user_agent, 'MiClash');
assert_equal(defaults.core.hwid_device_os, 'OpenWrt');
assert_equal(defaults.interfaces.mode, 'exclude');
assert_equal(defaults.interfaces.auto_detect_lan, true);
assert_equal(defaults.interfaces.auto_detect_wan, true);
assert_equal(defaults.guard.enabled, false);
assert_equal(defaults.guard.auto_fakeip_whitelist, true);
assert_equal(defaults.memory.enabled, false);
assert_equal(defaults.memory.sample_interval_ms, 60000);
assert_equal(defaults.memory.failure_cooldown_ms, 86400000);
assert_equal(defaults.updates.auto_subscription, true);
assert_equal(defaults.updates.interval_hours, 4);
assert_equal(defaults.updates.miclash_release_channel, 'release');
assert_equal(defaults.updates.mihomo_release_channel, 'release');
assert_equal(defaults.updates.auto_major_miclash, true);
assert_equal(defaults.notifications.auto_hide, true);
assert_json_equal(defaults.notifications.channels, [ 'syslog', 'luci', 'telegram' ]);
assert_json_equal(defaults.notifications.events, [ 'guard_outage', 'failure', 'recovery',
	'fail_closed', 'direct_fallback', 'memory_action', 'memory_outcome',
	'subscription_outcome', 'update_outcome', 'backup_outcome', 'internet_restored' ]);
assert_equal(defaults.telegram.enabled, false);
assert_equal(defaults.backup.enabled, false);
assert_equal(defaults.backup.retention, 5);
assert_equal(defaults.backup.include_secrets, false);
assert_equal(defaults.backup.interval_hours, 24);
assert_equal(defaults.backup.schedule_time, '03:00');
assert_equal(defaults.meta.schema_version, 1);

let normalized_env = fake_runtime();
assert_json_equal(settings.validate_patch({
	interfaces: { included: [ ' br-lan ', '', 'wlan0', 'br-lan' ] },
	updates: { interval_hours: '24' },
	memory: { sample_interval_ms: 10000, reserve_min_kb: 4096, reserve_max_kb: 8192 },
	notifications: { channels: [ 'telegram', 'syslog', 'telegram' ],
		events: [ 'failure', 'internet_restored' ] },
	backup: { interval_hours: '48', schedule_time: '04:30' }
}), {
	interfaces: { included: [ 'br-lan', 'wlan0' ] },
	updates: { interval_hours: 24 },
	memory: { sample_interval_ms: 10000, reserve_min_kb: 4096, reserve_max_kb: 8192 },
	notifications: { channels: [ 'telegram', 'syslog' ],
		events: [ 'failure', 'internet_restored' ] },
	backup: { interval_hours: 48, schedule_time: '04:30' }
});
let normalized = settings.save(normalized_env.rt, {
	interfaces: { included: [ ' br-lan ', '', 'wlan0', 'br-lan' ] },
	updates: { interval_hours: '24' },
	telegram: { enabled: true, token: '123456:secret-token', user_id: '12345' }
});
assert_json_equal(normalized.interfaces.included, [ 'br-lan', 'wlan0' ]);
assert_equal(normalized.updates.interval_hours, 24);
assert_equal(normalized.telegram.enabled, true);
assert_equal(normalized_env.cursor.commit_calls, 1);
assert_true(normalized_env.cursor.set_calls > 0);

let auto_major_env = fake_runtime();
assert_equal(settings.save(auto_major_env.rt,
	{ updates: { auto_major_miclash: false } }).updates.auto_major_miclash, false);

assert_throws(() => settings.save(fake_runtime().rt, { unknown: { enabled: true } }), 'INVALID_ARGUMENT');
assert_throws(() => settings.save(fake_runtime().rt, { core: { unknown: true } }), 'INVALID_ARGUMENT');
assert_throws(() => settings.save(fake_runtime().rt, { core: { proxy_mode: 'shell' } }), 'INVALID_ARGUMENT');
assert_throws(() => settings.save(fake_runtime().rt, { telegram: { token: 'bad\nvalue' } }), 'INVALID_ARGUMENT');
assert_throws(() => settings.save(fake_runtime().rt,
	{ telegram: { token: 'not-a-botfather-token' } }), 'INVALID_ARGUMENT');
assert_throws(() => settings.save(fake_runtime().rt,
	{ telegram: { token: '0:abcdefgh' } }), 'INVALID_ARGUMENT');
assert_throws(() => settings.save(fake_runtime().rt,
	{ backup: { schedule_time: '25:00' } }), 'INVALID_ARGUMENT');
assert_throws(() => settings.save(fake_runtime().rt,
	{ backup: { interval_hours: 169 } }), 'INVALID_ARGUMENT');
assert_throws(() => settings.validate_patch(
	{ updates: { auto_major_miclash: '1' } }), 'INVALID_ARGUMENT');
assert_throws(() => settings.save(fake_runtime().rt,
	{ memory: { sample_interval_ms: 9999 } }), 'INVALID_ARGUMENT');
assert_throws(() => settings.save(fake_runtime().rt,
	{ notifications: { channels: [ 'shell' ] } }), 'INVALID_ARGUMENT');
assert_throws(() => settings.save(fake_runtime().rt,
	{ notifications: { events: [ 'unknown_event' ] } }), 'INVALID_ARGUMENT');
assert_throws(() => settings.save(fake_runtime().rt,
	{ memory: { reserve_min_kb: 131072, reserve_max_kb: 65536 } }), 'INVALID_ARGUMENT');
assert_throws(() => settings.save(fake_runtime().rt,
	{ memory: { success_cooldown_ms: 172800000, failure_cooldown_ms: 86400000 } }), 'INVALID_ARGUMENT');
assert_throws(() => settings.save(fake_runtime().rt,
	{ telegram: { enabled: true, token: '', user_id: '' } }), 'INVALID_ARGUMENT');
assert_throws(() => settings.save(fake_runtime().rt,
	{ telegram: { enabled: true, token: 'token', user_id: '9007199254740993e0' } }), 'INVALID_ARGUMENT');
let telegram_partial_env = fake_runtime({ miclash: {
	telegram: { '.type': 'telegram', enabled: '0', token: '123456:stored-token', user_id: '9007199254740993123456789' }
} });
assert_equal(settings.save(telegram_partial_env.rt, { telegram: { enabled: true } }).telegram.enabled, true);
let atomic_env = fake_runtime();
assert_throws(() => settings.save(atomic_env.rt, {
	core: { proxy_mode: 'tun' },
	unknown: { enabled: true }
}), 'INVALID_ARGUMENT');
assert_equal(atomic_env.cursor.set_calls, 0);
assert_equal(atomic_env.cursor.commit_calls, 0);

let failed_set_env = fake_runtime();
failed_set_env.cursor.fail_set_at = 2;
assert_throws(() => settings.save(failed_set_env.rt, {
	core: { proxy_mode: 'tun', tun_stack: 'gvisor' }
}), 'INTERNAL');
assert_equal(failed_set_env.cursor.set_calls, 2);
assert_equal(failed_set_env.cursor.commit_calls, 0);

let failed_commit_env = fake_runtime();
failed_commit_env.cursor.fail_commit = true;
assert_throws(() => settings.save(failed_commit_env.rt, {
	core: { proxy_mode: 'tun' }
}), 'INTERNAL');
assert_equal(failed_commit_env.cursor.set_calls, 1);
assert_equal(failed_commit_env.cursor.commit_calls, 1);

// Guard writes share the central normal mutation domain. A different runtime
// cannot flip Guard while an owner holds the policy/settings lease, while the
// same already-held lease remains non-deadlocking for backup restore.
let shared_cursor = fakes.uci({ miclash: { guard: { '.type': 'guard', enabled: '0' } } });
let owner_identity = { pid: 6101, start: 501 }, contender_identity = { pid: 6102, start: 502 };
let shared_fs = lock_filesystem([ owner_identity, contender_identity ]);
let owner_rt = runtime_for(shared_cursor, shared_fs, owner_identity);
let contender_rt = runtime_for(shared_cursor, shared_fs, contender_identity);
with_lock(owner_rt, { barrier: 'normal', wait_ms: 0 }, () => {
	assert_throws(() => settings.save(contender_rt, { guard: { enabled: true } }), 'BUSY');
	assert_equal(shared_cursor.commit_calls, 0, 'blocked Guard writer cannot commit');
	settings.save(owner_rt, { guard: { enabled: false } });
});
assert_equal(shared_cursor.commit_calls, 1, 'held owner can save without nested-lock deadlock');
settings.save(contender_rt, { guard: { enabled: true } });
assert_equal(shared_cursor.commit_calls, 2, 'Guard writer commits after lease release');

assert_throws(() => settings.migrate_legacy(fake_runtime().rt, fixture('legacy-malformed')), 'INVALID_ARGUMENT');
assert_throws(() => settings.migrate_legacy(fake_runtime().rt,
	'SUBSCRIPTION_URL=https://safe.example/sub\nnot-an-assignment'), 'INVALID_ARGUMENT');
assert_throws(() => settings.migrate_legacy(fake_runtime().rt,
	'SUBSCRIPTION_URL=https://safe.example/' + sprintf('%c', 1)), 'INVALID_ARGUMENT');

let process_fake = fakes.process();
let hostile_env = fake_runtime(), hostile_rt = hostile_env.rt;
hostile_rt.process = process_fake;
let hostile = settings.migrate_legacy(hostile_rt,
	'PROXY_MODE=$(touch /tmp/pwned)\nHWID_USER_AGENT=`id`\n');
assert_equal(hostile.core.proxy_mode, 'tproxy');
assert_equal(hostile.core.hwid_user_agent, '`id`');
assert_equal(length(process_fake.calls), 0);

let interval = settings.migrate_legacy(fake_runtime().rt, 'AUTO_UPDATE_INTERVAL_HOURS=0\n');
assert_equal(interval.updates.interval_hours, 4);

assert_equal(redact.value('TOKEN', 'scalar-secret'), '[REDACTED]');
assert_equal(redact.value('Access-Key', 'scalar-secret'), '[REDACTED]');
assert_equal(redact.value(null, 'scalar-secret'), '[REDACTED]');
assert_equal(redact.value('safe', 'visible'), 'visible');
assert_equal(redact.value('token', '[REDACTED]'), '[REDACTED]');
assert_equal(redact.text('https://user:pass@example/a?token=abc'),
	'https://***:***@example/a?token=***');
assert_equal(redact.text('HTTPS://USER:PASS@example/a?ToKeN=abc&safe=yes&CLIENT_SECRET=def'),
	'HTTPS://***:***@example/a?ToKeN=***&safe=yes&CLIENT_SECRET=***');
assert_equal(redact.text('https://***:***@example/a?token=***'),
	'https://***:***@example/a?token=***');
