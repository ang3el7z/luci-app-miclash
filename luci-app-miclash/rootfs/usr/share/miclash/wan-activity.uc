import * as errors from 'miclash.errors';

const MINUTE = 60000;
const MIN_ELAPSED = 55000;
const MAX_ELAPSED = 65000;
const REQUIRED_SAMPLES = 10;
const MAX_COUNTER = 9007199254740991;
const BYTE_LIMIT = 32768;
const PACKET_LIMIT = 10;
const COUNTERS = [ 'rx_bytes', 'tx_bytes', 'rx_packets', 'tx_packets' ];

function invalid() { errors.fail('INVALID_ARGUMENT'); };

function interface_name(value) {
	if (type(value) != 'string' || !match(value, /^[A-Za-z0-9_.:@-]{1,64}$/) ||
	    value == 'lo' || value == 'clash-tun')
		return null;
	return value;
};
function counter(runtime, path) {
	let value;
	try { value = trim(runtime.fs.readfile(path) ?? ''); }
	catch (error) { return null; }
	if (!match(value, /^[0-9]{1,16}$/)) return null;
	let parsed = int(value);
	return parsed >= 0 && parsed <= MAX_COUNTER ? parsed : null;
};

function result(valid, quiet, samples, bytes, packets, reason) {
	return { valid, quiet, samples, bytes_per_second: bytes,
		packets_per_second: packets, reason };
};

export function create(app) {
	if (type(app?.runtime?.fs?.readfile) != 'function' ||
	    type(app?.interface) != 'function') invalid();
	let baseline = null, intervals = [];

	function reset(snapshot) {
		baseline = snapshot;
		intervals = [];
	};

	return {
		sample: (now) => {
			if (type(now) != 'int' || now < 0)
				return result(false, false, 0, null, null, 'clock_invalid');
			let iface;
			try { iface = interface_name(app.interface()); }
			catch (error) { iface = null; }
			if (iface == null) {
				reset(null);
				return result(false, false, 0, null, null, 'interface_unavailable');
			}
			let values = {}, root = '/sys/class/net/' + iface + '/statistics/';
			for (let name in COUNTERS) {
				values[name] = counter(app.runtime, root + name);
				if (values[name] == null) {
					reset(null);
					return result(false, false, 0, null, null, 'counters_unavailable');
				}
			}
			let snapshot = { interface: iface, at: now, values };
			if (baseline == null) {
				reset(snapshot);
				return result(false, false, 0, null, null, 'insufficient_samples');
			}
			if (baseline.interface != iface) {
				reset(snapshot);
				return result(false, false, 0, null, null, 'interface_changed');
			}
			let elapsed = now - baseline.at;
			if (elapsed < MIN_ELAPSED || elapsed > MAX_ELAPSED) {
				reset(snapshot);
				return result(false, false, 0, null, null, 'elapsed_time');
			}
			for (let name in COUNTERS)
				if (values[name] < baseline.values[name]) {
					reset(snapshot);
					return result(false, false, 0, null, null, 'counter_reset');
				}
			push(intervals, {
				elapsed,
				bytes: values.rx_bytes - baseline.values.rx_bytes +
					values.tx_bytes - baseline.values.tx_bytes,
				packets: values.rx_packets - baseline.values.rx_packets +
					values.tx_packets - baseline.values.tx_packets
			});
			baseline = snapshot;
			if (length(intervals) > REQUIRED_SAMPLES) shift(intervals);
			if (length(intervals) < REQUIRED_SAMPLES)
				return result(false, false, length(intervals), null, null,
					'insufficient_samples');
			let elapsed_total = 0, bytes_total = 0, packets_total = 0;
			for (let interval in intervals) {
				elapsed_total += interval.elapsed;
				bytes_total += interval.bytes;
				packets_total += interval.packets;
			}
			let bytes_rate = int(bytes_total * 1000 / elapsed_total);
			let packets_rate = int(packets_total * 1000 / elapsed_total);
			return result(true, bytes_rate <= BYTE_LIMIT && packets_rate <= PACKET_LIMIT,
				length(intervals), bytes_rate, packets_rate, null);
		}
	};
};
