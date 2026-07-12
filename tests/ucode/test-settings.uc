import { assert_equal, assert_match, assert_throws, assert_true } from './testlib.uc';
import * as runtime from 'miclash.runtime';
import * as settings from 'miclash.settings';
import * as redact from 'miclash.redact';
import * as fakes from './fakes.uc';

function fixture(name) {
	return require('fs').readfile('tests/fixtures/settings/' + name);
};

function fake_runtime(initial) {
	let cursor = fakes.uci(initial);
	return { rt: runtime.create({ uci: { cursor: () => cursor } }), cursor };
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
assert_equal(migrated.notifications.auto_hide, false);
assert_json_equal(migrated.telegram, { enabled: false, token: '', user_id: '' });
assert_json_equal(migrated.backup, { enabled: false, retention: 5, include_secrets: false });
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
assert_equal(defaults.updates.auto_subscription, true);
assert_equal(defaults.updates.interval_hours, 4);
assert_equal(defaults.updates.miclash_release_channel, 'release');
assert_equal(defaults.updates.mihomo_release_channel, 'release');
assert_equal(defaults.notifications.auto_hide, true);
assert_equal(defaults.telegram.enabled, false);
assert_equal(defaults.backup.enabled, false);
assert_equal(defaults.backup.retention, 5);
assert_equal(defaults.backup.include_secrets, false);
assert_equal(defaults.meta.schema_version, 1);

let normalized_env = fake_runtime();
assert_json_equal(settings.validate_patch({
	interfaces: { included: [ ' br-lan ', '', 'wlan0', 'br-lan' ] },
	updates: { interval_hours: '24' }
}), {
	interfaces: { included: [ 'br-lan', 'wlan0' ] },
	updates: { interval_hours: 24 }
});
let normalized = settings.save(normalized_env.rt, {
	interfaces: { included: [ ' br-lan ', '', 'wlan0', 'br-lan' ] },
	updates: { interval_hours: '24' },
	telegram: { enabled: true, token: 'secret-token', user_id: '12345' }
});
assert_json_equal(normalized.interfaces.included, [ 'br-lan', 'wlan0' ]);
assert_equal(normalized.updates.interval_hours, 24);
assert_equal(normalized.telegram.enabled, true);
assert_equal(normalized_env.cursor.commit_calls, 1);
assert_true(normalized_env.cursor.set_calls > 0);

assert_throws(() => settings.save(fake_runtime().rt, { unknown: { enabled: true } }), 'INVALID_ARGUMENT');
assert_throws(() => settings.save(fake_runtime().rt, { core: { unknown: true } }), 'INVALID_ARGUMENT');
assert_throws(() => settings.save(fake_runtime().rt, { core: { proxy_mode: 'shell' } }), 'INVALID_ARGUMENT');
assert_throws(() => settings.save(fake_runtime().rt, { telegram: { token: 'bad\nvalue' } }), 'INVALID_ARGUMENT');
let atomic_env = fake_runtime();
assert_throws(() => settings.save(atomic_env.rt, {
	core: { proxy_mode: 'tun' },
	unknown: { enabled: true }
}), 'INVALID_ARGUMENT');
assert_equal(atomic_env.cursor.set_calls, 0);
assert_equal(atomic_env.cursor.commit_calls, 0);
assert_throws(() => settings.migrate_legacy(fake_runtime().rt, fixture('legacy-malformed')), 'INVALID_ARGUMENT');
assert_throws(() => settings.migrate_legacy(fake_runtime().rt,
	'SUBSCRIPTION_URL=https://safe.example/sub\nnot-an-assignment'), 'INVALID_ARGUMENT');
assert_throws(() => settings.migrate_legacy(fake_runtime().rt,
	'SUBSCRIPTION_URL=https://safe.example/' + sprintf('%c', 1)), 'INVALID_ARGUMENT');

let process_fake = fakes.process();
let hostile_cursor = fakes.uci();
let hostile_rt = runtime.create({
	process: process_fake,
	uci: { cursor: () => hostile_cursor }
});
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
