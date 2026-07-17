import * as wan_activity from 'miclash.wan-activity';
import * as fakes from 'fakes';
import { assert_equal, assert_true } from './testlib.uc';

const MINUTE = 60000;
const ROOT = '/sys/class/net/wan/statistics/';

let filesystem = fakes.fs({});
let counters = { rx_bytes: 1000, tx_bytes: 2000, rx_packets: 10, tx_packets: 20 };
function write_counters() {
	for (let name, value in counters)
		filesystem.writefile(ROOT + name, sprintf('%d\n', value));
};
write_counters();
let interface_name = 'wan';
let meter = wan_activity.create({ runtime: { fs: filesystem },
	interface: () => interface_name });

let first = meter.sample(1784253600000);
assert_equal(first.valid, false);
assert_equal(first.quiet, false);
assert_equal(first.samples, 0);

let result = null;
for (let sample = 1; sample <= 10; sample++) {
	counters.rx_bytes += 60000;
	counters.tx_bytes += 60000;
	counters.rx_packets += 120;
	counters.tx_packets += 120;
	write_counters();
	result = meter.sample(1784253600000 + sample * MINUTE);
	if (sample < 10) assert_equal(result.valid, false);
}
assert_true(result.valid);
assert_true(result.quiet);
assert_equal(result.samples, 10);
assert_equal(result.bytes_per_second, 2000);
assert_equal(result.packets_per_second, 4);

// A high aggregate rate is valid evidence, but never quiet evidence.
counters.rx_bytes += 60 * 400000;
counters.tx_bytes += 60 * 400000;
counters.rx_packets += 60 * 200;
counters.tx_packets += 60 * 200;
write_counters();
result = meter.sample(1784253600000 + 11 * MINUTE);
assert_true(result.valid);
assert_equal(result.quiet, false);

// Identity/counter/time faults reset the proof and fail closed.
interface_name = 'wan2';
assert_equal(meter.sample(1784253600000 + 12 * MINUTE).valid, false);
interface_name = 'wan';
write_counters();
meter.sample(1784253600000 + 13 * MINUTE);
counters.rx_bytes = 1;
write_counters();
assert_equal(meter.sample(1784253600000 + 14 * MINUTE).reason, 'counter_reset');
counters.rx_bytes = 100;
write_counters();
meter.sample(1784253600000 + 15 * MINUTE);
assert_equal(meter.sample(1784253600000 + 15 * MINUTE + 1000).reason, 'elapsed_time');
filesystem.writefile(ROOT + 'tx_packets', 'broken\n');
assert_equal(meter.sample(1784253600000 + 16 * MINUTE).reason, 'counters_unavailable');
