import { assert_equal, assert_throws } from './testlib.uc';
import * as notification_settings from 'miclash.notification-settings';

function assert_json_equal(actual, expected) {
	assert_equal(sprintf('%J', actual), sprintf('%J', expected));
};

let settings = {
	syslog_enabled: true,
	syslog_events: [ 'failure' ],
	luci_enabled: true,
	luci_events: [ 'recovery' ],
	telegram_enabled: true,
	telegram_events: [ 'internet_restored' ]
};

let configured = notification_settings.notifier_config(settings);
assert_equal(configured.dedupe_window_ms, 60000);
assert_equal(configured.syslog.enabled, true);
assert_json_equal(configured.syslog.types, [ 'failure' ]);
assert_equal(configured.luci.enabled, true);
assert_json_equal(configured.luci.types, [ 'recovery' ]);
assert_equal(configured.luci.channel, 'miclash.notification');

let telegram = notification_settings.telegram_config(settings);
assert_equal(telegram.enabled, true);
assert_json_equal(telegram.types, [ 'internet_restored' ]);

configured.syslog.types[0] = 'guard_outage';
assert_json_equal(settings.syslog_events, [ 'failure' ]);
assert_json_equal(configured.luci.types, [ 'recovery' ]);

assert_throws(() => notification_settings.notifier_config({}), 'INVALID_ARGUMENT');
assert_throws(() => notification_settings.notifier_config({ ...settings,
	syslog_events: [ 'unknown_event' ] }), 'INVALID_ARGUMENT');
assert_throws(() => notification_settings.telegram_config({ ...settings,
	telegram_enabled: '1' }), 'INVALID_ARGUMENT');

print('notification settings tests passed\n');
