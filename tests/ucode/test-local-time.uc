import * as local_time from 'miclash.local-time';
import * as fakes from 'fakes';
import { assert_equal, assert_true } from './testlib.uc';

const DAY = 24 * 60 * 60 * 1000;

function utc_runtime() {
	return {
		uci: fakes.uci({ system: { main: { '.type': 'system', zonename: 'UTC' } } }),
		timezones: {
			resolve: (name, timestamp) => name == 'UTC' ? {
				name: 'UTC', from: 0, until: 4102444800,
				initial_offset: 0, transitions: []
			} : null
		}
	};
};

let observer = local_time.create(utc_runtime());
let before = observer.observe(1784253540000); // 2026-07-17 01:59 UTC
assert_true(before.valid);
assert_equal(before.local_date, '2026-07-17');
assert_equal(before.minute, 119);
assert_equal(before.in_window, false);
assert_equal(before.before_cutoff, true);
assert_equal(before.next_window, 1784253600000);

let start = observer.observe(1784253600000);
assert_equal(start.minute, 120);
assert_equal(start.in_window, true);
assert_equal(start.before_cutoff, true);
assert_equal(start.next_window, 1784253600000 + DAY);

assert_equal(observer.observe(1784266140000).before_cutoff, true);
assert_equal(observer.observe(1784266200000).before_cutoff, false);
assert_equal(observer.observe(1784267940000).in_window, true);
assert_equal(observer.observe(1784268000000).in_window, false);
assert_equal(observer.observe(1784268000000).next_window, 1784340000000);

assert_equal(observer.observe(1).valid, false, 'unsynchronized clocks fail closed');

// A resolver-supplied offset transition is applied without changing process TZ.
let transition = local_time.create({
	uci: fakes.uci({ system: { main: { '.type': 'system', zonename: 'Europe/Test' } } }),
	timezones: { resolve: (name, timestamp) => ({
		name, from: 1774656000, until: 1775001600, initial_offset: 3600,
		transitions: [ { at: 1774746000, offset: 7200 } ]
	}) }
});
assert_equal(transition.observe(1774744200000).minute, 90);
assert_equal(transition.observe(1774747800000).minute, 210);
