import { assert_equal, assert_throws, assert_true } from './testlib.uc';
import * as runtime from 'miclash.runtime';
import * as settings from 'miclash.settings';
import * as redact from 'miclash.redact';
import * as fakes from './fakes.uc';
import { with_lock } from 'miclash.mutation_lock';

const BOOT = '12345678-1234-1234-1234-123456789abc';
const ALL_EVENTS = [ 'guard_outage', 'failure', 'recovery', 'fail_closed',
	'direct_fallback', 'memory_action', 'memory_outcome', 'subscription_outcome',
	'update_outcome', 'internet_restored' ];
let next_pid = 6000;

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
		'notifications', 'meta' ]) seeded.miclash[section] ??= { '.type': section };
	let cursor = fakes.uci(seeded), identity = { pid: next_pid++, start: 400 };
	return { rt: runtime_for(cursor, lock_filesystem([ identity ]), identity), cursor };
};

function assert_json_equal(actual, expected) {
	assert_equal(sprintf('%J', actual), sprintf('%J', expected));
};

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
assert_equal(defaults.memory.enabled, true);
assert_equal(defaults.memory.sample_interval_ms, 60000);
assert_equal(defaults.memory.failure_cooldown_ms, 86400000);
assert_equal(defaults.updates.auto_subscription, true);
assert_equal(defaults.updates.interval_hours, 4);
assert_equal(defaults.updates.interval_source, 'manual');
assert_equal(defaults.updates.miclash_release_channel, 'release');
assert_equal(defaults.updates.mihomo_release_channel, 'release');
assert_equal(defaults.updates.auto_major_miclash, true);
assert_equal(defaults.notifications.auto_hide, true);
assert_equal(defaults.notifications.syslog_enabled, true);
assert_json_equal(defaults.notifications.syslog_events, ALL_EVENTS);
assert_equal(defaults.notifications.luci_enabled, true);
assert_json_equal(defaults.notifications.luci_events, [ 'miclash_event' ]);
assert_equal(defaults.notifications.telegram_enabled, false);
assert_json_equal(defaults.notifications.telegram_events,
	[ 'guard_outage', 'failure', 'recovery', 'fail_closed', 'direct_fallback',
		'memory_outcome', 'subscription_outcome', 'update_outcome', 'internet_restored' ]);
assert_equal(defaults.telegram.enabled, false);
assert_equal(defaults.telegram.poll_timeout_seconds, 25);
assert_equal(defaults.meta.schema_version, 1);

let cached_env = fake_runtime({ miclash: {
	core: { '.type': 'core', proxy_mode: 'tproxy' }
} });
cached_env.rt.fs.writefile('/etc/config/miclash', 'config miclash\n');
cached_env.rt.fs.set_mtime('/etc/config/miclash', 1);
let cached_cursor_calls = 0;
cached_env.rt.uci.cursor = () => { cached_cursor_calls++; return cached_env.cursor.cursor(); };
let cached_settings = settings.create(cached_env.rt);
assert_equal(cached_settings.get().core.proxy_mode, 'tproxy');
assert_equal(cached_settings.get().core.proxy_mode, 'tproxy');
assert_equal(cached_cursor_calls, 1);
let external_cursor = cached_env.cursor.cursor();
external_cursor.set('miclash', 'core', 'proxy_mode', 'tun');
external_cursor.commit('miclash');
cached_env.rt.fs.set_mtime('/etc/config/miclash', 2);
assert_equal(cached_settings.get().core.proxy_mode, 'tun');
assert_equal(cached_cursor_calls, 2);
cached_settings.set({ core: { proxy_mode: 'mixed' } });
assert_equal(cached_settings.get().core.proxy_mode, 'mixed');
assert_equal(cached_cursor_calls, 3);

let legacy = settings.load(fake_runtime({ miclash: {
	notifications: { '.type': 'notifications', auto_hide: '0',
		channels: 'telegram,syslog', events: 'failure,recovery' }
} }).rt);
assert_equal(legacy.notifications.auto_hide, false);
assert_equal(legacy.notifications.syslog_enabled, true);
assert_json_equal(legacy.notifications.syslog_events, [ 'failure', 'recovery' ]);
assert_equal(legacy.notifications.luci_enabled, false);
assert_json_equal(legacy.notifications.luci_events, [ 'failure', 'recovery' ]);
assert_equal(legacy.notifications.telegram_enabled, true);
assert_json_equal(legacy.notifications.telegram_events, [ 'failure', 'recovery' ]);

let normalized_env = fake_runtime();
assert_json_equal(settings.validate_patch({
	interfaces: { included: [ ' br-lan ', '', 'wlan0', 'br-lan' ] },
	updates: { interval_hours: '24', interval_source: 'provider' },
	telegram: { poll_timeout_seconds: '25' },
	memory: { sample_interval_ms: 10000, reserve_min_kb: 4096, reserve_max_kb: 8192 },
	notifications: { syslog_enabled: true,
		syslog_events: [ 'failure', 'internet_restored', 'failure' ],
		luci_enabled: false, luci_events: [ 'recovery', 'miclash_event' ],
		telegram_enabled: true, telegram_events: [ 'internet_restored' ] }
}), {
	interfaces: { included: [ 'br-lan', 'wlan0' ] },
	updates: { interval_hours: 24, interval_source: 'provider' },
	telegram: { poll_timeout_seconds: 25 },
	memory: { sample_interval_ms: 10000, reserve_min_kb: 4096, reserve_max_kb: 8192 },
	notifications: { syslog_enabled: true,
		syslog_events: [ 'failure', 'internet_restored' ],
		luci_enabled: false, luci_events: [ 'recovery', 'miclash_event' ],
		telegram_enabled: true, telegram_events: [ 'internet_restored' ] }
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

let multi_admin_env = fake_runtime();
let multi_admin = settings.save(multi_admin_env.rt, { telegram: {
	enabled: true, token: '123456:secret-token', user_id: '12345, 67890'
} });
assert_equal(multi_admin.telegram.user_id, '12345, 67890');
assert_throws(() => settings.save(fake_runtime().rt, { telegram: {
	enabled: true, token: '123456:secret-token', user_id: '12345, invalid'
} }), 'INVALID_ARGUMENT');

let empty_lists_env = fake_runtime({ miclash: {
	interfaces: { '.type': 'interfaces', included: [ 'br-lan' ], excluded: [ 'wan' ] },
	notifications: { '.type': 'notifications', syslog_events: 'failure' }
} });
empty_lists_env.cursor.reject_empty_lists = true;
let empty_lists = settings.save(empty_lists_env.rt, {
	interfaces: { included: [], excluded: [] },
	notifications: { syslog_events: [] }
});
assert_json_equal(empty_lists.interfaces.included, []);
assert_json_equal(empty_lists.interfaces.excluded, []);
assert_json_equal(empty_lists.notifications.syslog_events, []);
assert_equal(length(filter(empty_lists_env.cursor.calls,
	(call) => call.operation == 'set' && type(call.value) == 'array' && !length(call.value))), 0,
	'empty UCI lists must be represented by absent options');
assert_equal(length(filter(empty_lists_env.cursor.calls,
	(call) => call.operation == 'delete')), 2,
	'existing interface options must be deleted when their effective value becomes empty');
assert_equal(length(filter(empty_lists_env.cursor.calls,
	(call) => call.operation == 'set' && call.section == 'notifications' &&
		call.option == 'syslog_events' && call.value == '')), 1,
	'an empty notification event selection must remain an explicit empty value');

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
assert_throws(() => settings.validate_patch(
	{ updates: { auto_major_miclash: '1' } }), 'INVALID_ARGUMENT');
assert_throws(() => settings.save(fake_runtime().rt,
	{ memory: { sample_interval_ms: 9999 } }), 'INVALID_ARGUMENT');
assert_throws(() => settings.save(fake_runtime().rt,
	{ notifications: { syslog_events: [ 'shell' ] } }), 'INVALID_ARGUMENT');
assert_throws(() => settings.save(fake_runtime().rt,
	{ notifications: { luci_events: [ 'unknown_event' ] } }), 'INVALID_ARGUMENT');
assert_throws(() => settings.save(fake_runtime().rt,
	{ notifications: { telegram_events: [ 'unknown_event' ] } }), 'INVALID_ARGUMENT');
assert_throws(() => settings.save(fake_runtime().rt,
	{ notifications: { syslog_events: [ 'miclash_event' ] } }), 'INVALID_ARGUMENT');
assert_throws(() => settings.save(fake_runtime().rt,
	{ notifications: { telegram_events: [ 'miclash_event' ] } }), 'INVALID_ARGUMENT');
assert_throws(() => settings.save(fake_runtime().rt,
	{ memory: { reserve_min_kb: 131072, reserve_max_kb: 65536 } }), 'INVALID_ARGUMENT');
assert_throws(() => settings.save(fake_runtime().rt,
	{ memory: { success_cooldown_ms: 172800000, failure_cooldown_ms: 86400000 } }), 'INVALID_ARGUMENT');
assert_throws(() => settings.save(fake_runtime().rt,
	{ telegram: { enabled: true, token: '', user_id: '' } }), 'INVALID_ARGUMENT');
assert_throws(() => settings.save(fake_runtime().rt,
	{ telegram: { poll_timeout_seconds: 4 } }), 'INVALID_ARGUMENT');
assert_throws(() => settings.save(fake_runtime().rt,
	{ telegram: { poll_timeout_seconds: 51 } }), 'INVALID_ARGUMENT');
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
// same already-held lease remains non-deadlocking for settings updates.
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
