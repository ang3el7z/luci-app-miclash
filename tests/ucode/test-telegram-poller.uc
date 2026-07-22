import * as poller from 'miclash.telegram-poller';
import { assert_equal, assert_throws } from 'testlib';

assert_equal(poller.poll_timeout_seconds({}), 25);
assert_equal(poller.poll_timeout_seconds({ poll_timeout_seconds: 5 }), 5);
assert_equal(poller.poll_timeout_seconds({ poll_timeout_seconds: 50 }), 50);
assert_throws(() => poller.poll_timeout_seconds({ poll_timeout_seconds: 4 }), 'INVALID_ARGUMENT');
assert_throws(() => poller.poll_timeout_seconds({ poll_timeout_seconds: 51 }), 'INVALID_ARGUMENT');

assert_equal(poller.retry_delay_ms(1), 1000);
assert_equal(poller.retry_delay_ms(2), 2000);
assert_equal(poller.retry_delay_ms(7), 60000);
assert_equal(poller.retry_delay_ms(8), 60000);
assert_throws(() => poller.retry_delay_ms(0), 'INVALID_ARGUMENT');
