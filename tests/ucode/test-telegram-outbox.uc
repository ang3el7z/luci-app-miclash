import { assert_equal, assert_throws, assert_true } from 'testlib';
import * as fakes from 'fakes';
import * as outbox_module from 'miclash.telegram-outbox';

const PATH = '/etc/miclash/telegram-outbox.json';

function environment(options) {
	let changes = options ?? {}, filesystem = changes.filesystem ?? fakes.fs();
	for (let directory in [ '/etc', '/etc/miclash' ])
		if (filesystem.lstat(directory) == null) filesystem.mkdir(directory);
	filesystem.set_mode('/etc/miclash', 0o700);
	let clock = changes.clock ?? fakes.clock(1700000000000);
	let runtime = {
		fs: filesystem, digest: fakes.digest(filesystem), clock,
		paths: { etc: '/etc/miclash' }
	};
	let deliveries = [], results = changes.results ?? [];
	let deliver = changes.deliver ?? ((entry, panel) => {
		push(deliveries, { entry: json(sprintf('%J', entry)),
			panel: panel == null ? null : json(sprintf('%J', panel)) });
		return length(results) ? shift(results) : true;
	});
	return { runtime, filesystem, clock, deliveries, results,
		outbox: outbox_module.create(runtime, deliver) };
};

function receipt(id, audience, kind, state) {
	return {
		id, audience: audience ?? 'user', kind: kind ?? 'service.restart', locale: 'ru',
		chat_id: '42', message_id: 10, operation_id: 'operation-1',
		state: state ?? 'success', created_at: 1700000000000,
		payload: { title: 'MiClash', message: 'Completed', token: 'must-not-persist' }
	};
};

assert_throws(() => outbox_module.create({}, () => true), 'INVALID_ARGUMENT');
assert_throws(() => outbox_module.create({ paths: { etc: '/tmp' } }, () => true),
	'INVALID_ARGUMENT');

let basic = environment({ results: [ false, true ] });
assert_equal(basic.outbox.enqueue(receipt('user-1')), true);
assert_equal(length(basic.outbox.pending()), 1);
assert_equal(basic.filesystem.lstat(PATH).mode, 0o600);
assert_equal(basic.filesystem.lstat(PATH).uid, 0);
assert_equal(basic.filesystem.lstat(PATH).nlink, 1);
assert_equal(index(basic.filesystem.readfile(PATH), 'must-not-persist'), -1);
assert_equal(basic.outbox.attempt(), false);
let delayed = basic.outbox.pending()[0];
assert_equal(delayed.attempts, 1);
assert_equal(delayed.next_attempt_at, 1700000015000);
assert_equal(basic.outbox.attempt(), false, 'not due receipts must not be delivered');
assert_equal(length(basic.deliveries), 1);
basic.clock.advance(14999);
assert_equal(basic.outbox.attempt(), false);
assert_equal(length(basic.deliveries), 1);
basic.clock.advance(1);
assert_equal(basic.outbox.attempt(), true);
assert_equal(length(basic.outbox.pending()), 0);

let restarted = environment({ filesystem: basic.filesystem });
assert_equal(length(restarted.outbox.pending()), 0);
assert_equal(restarted.outbox.enqueue(receipt('user-2')), true);
let resumed = environment({ filesystem: restarted.filesystem });
assert_equal(resumed.outbox.pending()[0].id, 'user-2');
assert_equal(resumed.outbox.enqueue(receipt('user-2')), false,
	'duplicate receipt IDs must be idempotent');

let panel = environment({ results: [ {
	delivered: true, panel: { chat_id: '42', message_id: 99, generation: 3 }
} ] });
assert_equal(panel.outbox.panel(), null);
assert_equal(panel.outbox.panel({ chat_id: '42', message_id: 10, generation: 2 }), true);
assert_equal(panel.outbox.panel().message_id, 10);
panel.outbox.enqueue(receipt('panel-1'));
assert_equal(panel.outbox.attempt(), true);
assert_equal(panel.outbox.panel().message_id, 99);
let panel_restarted = environment({ filesystem: panel.filesystem });
assert_equal(panel_restarted.outbox.panel().generation, 3);

let automatic = environment({ results: [ false ] });
let first = receipt('auto-1', 'automatic', 'internet_restored', 'success');
first.operation_id = null;
first.message_id = null;
first.payload = { message: 'Internet restored' };
assert_equal(automatic.outbox.coalesce(first), true);
let second = receipt('auto-2', 'automatic', 'internet_restored', 'success');
second.operation_id = null;
second.message_id = null;
second.payload = { message: 'Internet restored again' };
assert_equal(automatic.outbox.coalesce(second), false);
assert_equal(length(automatic.outbox.pending()), 1);
assert_equal(automatic.outbox.pending()[0].payload.count, 2);

let capacity = environment();
for (let index = 0; index < 64; index++)
	assert_equal(capacity.outbox.enqueue(receipt('protected-' + index)), true);
assert_throws(() => capacity.outbox.enqueue(receipt('protected-overflow')),
	'RESOURCE_EXHAUSTED');
assert_equal(length(capacity.outbox.pending()), 64);
assert_throws(() => capacity.outbox.coalesce(first), 'RESOURCE_EXHAUSTED');

let mixed = environment();
for (let index = 0; index < 64; index++) {
	let item = receipt('mixed-' + index, index == 0 ? 'automatic' : 'user',
		index == 0 ? 'recovery' : 'operation', 'success');
	item.operation_id = index == 0 ? null : 'operation-' + index;
	assert_equal(mixed.outbox.enqueue(item), true);
}
assert_equal(mixed.outbox.enqueue(receipt('new-user')), true);
assert_equal(length(mixed.outbox.pending()), 64);
assert_equal(mixed.outbox.pending()[0].id, 'mixed-1');

for (let failure in [ 'open', 'write', 'flush', 'close', 'chmod', 'rename' ]) {
	let atomic = environment();
	atomic.filesystem.fail_on = failure;
	assert_throws(() => atomic.outbox.enqueue(receipt('failure-' + failure)), 'INTERNAL');
	assert_equal(length(atomic.outbox.pending()), 0, failure + ' changed memory state');
}

let corrupt = environment();
corrupt.outbox.enqueue(receipt('corrupt-1'));
corrupt.filesystem.set_mode(PATH, 0o640);
assert_throws(() => outbox_module.create(corrupt.runtime, () => true), 'CORRUPT_STATE');
corrupt.filesystem.set_mode(PATH, 0o600);
corrupt.filesystem.set_uid(PATH, 1000);
assert_throws(() => outbox_module.create(corrupt.runtime, () => true), 'CORRUPT_STATE');

assert_throws(() => basic.outbox.enqueue({}), 'INVALID_ARGUMENT');
assert_throws(() => basic.outbox.panel({ chat_id: '42', message_id: 0, generation: 1 }),
	'INVALID_ARGUMENT');
assert_equal(basic.outbox.close(), true);
assert_equal(basic.outbox.close(), false);
assert_throws(() => basic.outbox.enqueue(receipt('after-close')), 'INTERRUPTED');

print('telegram outbox tests passed\n');
