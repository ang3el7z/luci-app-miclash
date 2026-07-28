import { assert_equal, assert_true } from 'testlib';
import * as runtime_metrics from 'miclash.runtime-metrics';

let running = false, now = 1000, calls = [], queued_replies = [];
let replies = {
	'/connections': { ok: true, data: {
		uploadTotal: 10485760, downloadTotal: 55155098,
		memory: 55889100, connections: [ {}, {}, {} ]
	} }
};

let metrics = runtime_metrics.create({
	service_state: () => ({ running }),
	now: () => now,
	request: (path) => {
		push(calls, path);
		if (path == '/connections' && length(queued_replies)) return shift(queued_replies);
		if (path == '/connections') return replies['/connections'];
		return { ok: false, data: null };
	}
});

let stopped = metrics.status();
assert_equal(stopped.running, false);
assert_equal(stopped.available, false);
assert_equal(length(calls), 0);

running = true;
let snapshot = metrics.status();
assert_equal(snapshot.running, true);
assert_equal(snapshot.available, true);
assert_equal(snapshot.upload_rate, 0);
assert_equal(snapshot.download_rate, 0);
assert_equal(snapshot.upload_total, 10485760);
assert_equal(snapshot.download_total, 55155098);
assert_equal(snapshot.connections, 3);
assert_equal(snapshot.memory_bytes, 55889100);
assert_equal(join(',', calls), '/connections');

now = 3000;
replies['/connections'] = { ok: true, data: {
	uploadTotal: 10501120, downloadTotal: 55188686,
	memory: 55889100, connections: [ {}, {}, {} ]
} };
snapshot = metrics.status();
assert_equal(snapshot.upload_rate, 7680);
assert_equal(snapshot.download_rate, 16794);

let calls_before_retry = length(calls);
queued_replies = [
	{ ok: false, data: null },
	{ ok: true, data: {
		uploadTotal: 10501120, downloadTotal: 55188686,
		memory: 55889100, connections: [ {}, {}, {} ]
	} }
];
let recovered = metrics.status();
assert_equal(recovered.running, true);
assert_equal(recovered.available, true,
	'a transient Mihomo connections failure must be retried before hiding live metrics');
assert_equal(length(calls), calls_before_retry + 2);

queued_replies = [
	{ ok: true, data: { memory: -1, connections: [] } },
	{ ok: false, data: null }
];
let unavailable = metrics.status();
assert_equal(unavailable.running, true);
assert_equal(unavailable.available, false);

assert_true(runtime_metrics.create != null);
print('runtime metrics tests passed\n');
