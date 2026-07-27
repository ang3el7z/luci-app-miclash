import { assert_equal, assert_throws, assert_true } from 'testlib';
import * as fakes from 'fakes';
import * as bridge_module from 'miclash.telegram-operations';

function clone(value) { return value == null ? null : json(sprintf('%J', value)); };

function environment() {
	let entries = [], subscriber = null, records = [], postcheck = false,
		boot_id = 'boot-before', daemon_ready = true;
	let outbox = {
		enqueue: (entry) => { push(entries, clone(entry)); return true; },
		update: (id, patch) => {
			for (let entry in entries)
				if (entry.id == id) {
					entry.state = patch.state; entry.payload = clone(patch.payload); return true;
				}
			die('NOT_FOUND');
		},
		pending: () => clone(entries)
	};
	let operations = {
		subscribe: (callback) => { subscriber = callback; return () => { subscriber = null; return true; }; },
		list: () => clone(records),
		get: (id) => {
			for (let record in records) if (record.id == id) return clone(record);
			return null;
		}
	};
	let runtime = { clock: fakes.clock(1700000000000), random: fakes.entropy() };
	let app = {
		runtime, operations,
		operation_postcheck: () => postcheck,
		boot_id: () => boot_id,
		daemon_ready: () => daemon_ready
	};
	let bridge = bridge_module.create(app, outbox, (record, previous) => ({
		kind: record.kind, stage: record.stage, progress: record.progress,
		error: record.error?.code ?? null,
		report_id: record.report_id ?? previous?.report_id ?? null
	}));
	return {
		app, outbox, entries, records, bridge,
		publish: (record) => subscriber(clone(record)),
		postcheck: (value) => postcheck = value,
		boot: (value) => boot_id = value,
		ready: (value) => daemon_ready = value
	};
};

function operation(state, kind) {
	return {
		id: '1700000000000-00000001-0123456789abcdef',
		kind: kind ?? 'service.restart', source: 'telegram', state: state ?? 'queued',
		stage: state ?? 'queued', progress: state == 'success' ? 100 : 0,
		error: null, created_at: 1700000000000
	};
};

assert_throws(() => bridge_module.create({}, {}, () => ({})), 'INVALID_ARGUMENT');

let env = environment(), queued = operation('queued');
assert_equal(env.bridge.track(queued, {
	chat_id: '42', message_id: 10, locale: 'ru'
}), true);
assert_equal(length(env.entries), 1);
assert_equal(env.entries[0].operation_id, queued.id);
assert_equal(env.entries[0].state, 'queued');

env.publish({ ...queued, state: 'running', stage: 'reload', progress: 60 });
assert_equal(env.entries[0].state, 'running');
assert_equal(env.entries[0].payload.progress, 60);
env.publish({ ...queued, state: 'success', stage: 'complete', progress: 100 });
assert_equal(env.entries[0].state, 'verifying',
	'success must wait for a fresh postcondition');
push(env.records, { ...queued, state: 'success', stage: 'complete', progress: 100 });
env.postcheck(true);
assert_equal(env.bridge.recover(), 1);
assert_equal(env.entries[0].state, 'success');

let failed = environment(), failed_record = operation('queued', 'updates.mihomo');
failed.bridge.track(failed_record, { chat_id: '42', message_id: 11, locale: 'en' });
failed.publish({ ...failed_record, state: 'failure', stage: 'install', progress: 80,
	error: { code: 'HEALTH_FAILED', message: 'HEALTH_FAILED' } });
assert_equal(failed.entries[0].state, 'failure');
assert_equal(failed.entries[0].payload.error, 'HEALTH_FAILED');

let diagnostic = environment(), diagnostic_record = operation('queued', 'diagnostics.report');
diagnostic.bridge.track({ ...diagnostic_record, report_id: 'rpt_0123456789abcdef0123456789abcdef' },
	{ chat_id: '42', message_id: 13, locale: 'en' });
diagnostic.publish({ ...diagnostic_record, state: 'interrupted', stage: 'interrupted',
	progress: 30, error: { code: 'INTERRUPTED', message: 'INTERRUPTED' } });
assert_equal(diagnostic.entries[0].payload.report_id,
	'rpt_0123456789abcdef0123456789abcdef',
	'operation updates discarded durable diagnostic delivery identity');

let reboot = environment();
let receipt_id = reboot.bridge.prepare_reboot({
	chat_id: '42', message_id: 12, locale: 'zh-cn'
});
assert_true(type(receipt_id) == 'string');
assert_equal(reboot.entries[0].kind, 'system.reboot');
assert_equal(reboot.entries[0].payload.boot_id_before, 'boot-before');
assert_equal(reboot.bridge.recover(), 0);
reboot.boot('boot-after'); reboot.ready(false);
assert_equal(reboot.bridge.recover(), 0);
reboot.ready(true);
assert_equal(reboot.bridge.recover(), 1);
assert_equal(reboot.entries[0].state, 'success');

assert_equal(reboot.bridge.close(), true);
assert_equal(reboot.bridge.close(), false);

print('telegram operation bridge tests passed\n');
