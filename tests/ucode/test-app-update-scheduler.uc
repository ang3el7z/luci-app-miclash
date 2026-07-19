import * as scheduler from 'miclash.app-update-scheduler';
import * as fakes from 'fakes';
import { assert_equal, assert_true } from './testlib.uc';

const MINUTE = 60000;
const START = 1784253600000;

for (let row in [
	[ '0.9.9', '1.0.0', true ], [ '1.9.9', '2.0.0', true ],
	[ '1.0.0', '3.0.0', true ], [ '1.0.0', '1.1.0', false ],
	[ '1.0.0', '1.0.1', false ], [ '2.0.0', '1.9.9', false ],
	[ '1.0.0', '1.0.0', false ], [ '', '2.0.0', false ],
	[ 'unknown', '2.0.0', false ], [ '1.0.0', '2.0.0-rc.1', false ],
	[ '1.0.0-rc.1', '2.0.0', false ]
]) assert_equal(scheduler.automatic_major(row[0], row[1], true, 'release'), row[2]);
assert_equal(scheduler.automatic_major('1.0.0', '2.0.0', false, 'release'), false);
assert_equal(scheduler.automatic_major('1.0.0', '2.0.0', true, 'prerelease'), false);
let retry_delays = [];
for (let count in [ 1, 2, 3, 4, 9 ])
	push(retry_delays, scheduler.publication_retry_delay_ms(count));
assert_equal(sprintf('%J', retry_delays),
	'[ 1800000, 3600000, 7200000, 7200000, 7200000 ]');

function environment(releases, options) {
	options ??= {};
	let filesystem = options.filesystem ?? fakes.fs({ '/opt/clash/config.yaml': 'active\n' });
	let clock = fakes.clock(options.now ?? START);
	let runtime = { fs: filesystem, clock, digest: fakes.digest(filesystem),
		app_version: options.app_version ?? '1.4.0' };
	let listener = null, submissions = [], release_calls = 0,
		active_record = options.active_record ?? null;
	let operations = {
		get: (id) => active_record?.id == id ? active_record : null,
		list: (filter) => options.busy ? [ { id: 'busy', state: filter.state } ] : [],
		subscribe: (callback) => { listener = callback; return () => { listener = null; return true; }; }
	};
	let updates = {
		release_info: (request) => {
			release_calls++;
			let index = min(release_calls - 1, length(releases) - 1);
			let selected = releases[index];
			if (type(selected) == 'string') die(selected);
			return selected;
		},
		update_miclash_scheduled: (request, source, before_run) => {
			let record = { id: '1784253600000-00000001-0123456789abcdef',
				kind: 'updates.miclash', source, state: 'queued', created_at: clock.now(),
				updated_at: clock.now(), finished_at: null };
			before_run(record);
			active_record = record;
			push(submissions, { request, source });
			return record;
		}
	};
	let local_time = options.local_time ?? { observe: (now) => {
		let minute = 120 + int((now - START) / MINUTE);
		return { valid: true, local_date: '2026-07-17', minute,
			in_window: minute >= 120 && minute < 360, before_cutoff: minute < 330,
			next_window: 1784340000000 };
	} };
	let wan_activity = options.wan_activity ?? { sample: (now) => ({ valid: true, quiet: true, samples: 10,
		bytes_per_second: 1000, packets_per_second: 2, reason: null }) };
	let settings_value = { updates: { auto_major_miclash: true },
		interfaces: { detected_wan: 'wan' } };
	let machine = scheduler.create({ runtime, operations, updates,
		settings: { get: () => settings_value }, local_time, wan_activity });
	return { machine, clock, filesystem, submissions, release_calls: () => release_calls,
		emit: (record) => listener(record), settings_value };
};

let ready = environment([
	{ version: 'v2.0.0', ready: true, readiness: 'ready' },
	{ version: 'v2.0.0', ready: true, readiness: 'ready' }
]);
ready.machine.tick();
assert_equal(length(ready.submissions), 1);
assert_equal(ready.submissions[0].source, 'auto');
assert_equal(ready.machine.status().pending_target, 'v2.0.0');
assert_true(ready.machine.status().pending_operation_id != null);
ready.machine.tick();
assert_equal(length(ready.submissions), 1, 'queued update is never duplicated');
ready.emit({ id: ready.machine.status().pending_operation_id, kind: 'updates.miclash',
	source: 'auto', state: 'success', updated_at: START, finished_at: START });
assert_equal(ready.machine.status().pending_target, null);
assert_equal(ready.machine.status().next_check, 1784340000000);
assert_equal(ready.filesystem.mode('/opt/clash/app-update-scheduler.json'), 0o600);
let exact_status = ready.machine.status(), status_fields = 0;
for (let name in exact_status) status_fields++;
assert_equal(status_fields, 17, 'diagnostic status has a closed schema');

let pending = environment([
	{ version: 'v2.0.0', ready: false, readiness: 'assets_pending' },
	{ version: 'v2.0.0', ready: false, readiness: 'assets_pending' }
]);
pending.machine.tick();
assert_equal(pending.machine.status().publication_retry_count, 1);
assert_equal(pending.machine.status().next_check, START + 30 * MINUTE);
pending.clock.advance(30 * MINUTE);
pending.machine.tick();
assert_equal(pending.machine.status().publication_retry_count, 2);
assert_equal(pending.machine.status().next_check, START + 90 * MINUTE);
assert_equal(pending.release_calls(), 2, 'every publication retry fetches fresh metadata');
pending.clock.advance(60 * MINUTE);
pending.machine.tick();
assert_equal(pending.machine.status().publication_retry_count, 3);
assert_equal(pending.machine.status().next_check, START + 210 * MINUTE);
pending.clock.advance(120 * MINUTE);
pending.machine.tick();
assert_equal(pending.machine.status().publication_retry_count, 4);
assert_equal(pending.machine.status().next_check, 1784340000000,
	'retry that leaves the night window is carried to the next night');

let changed = environment([
	{ version: 'v2.0.0', ready: false, readiness: 'assets_pending' },
	{ version: 'v3.0.0', ready: false, readiness: 'assets_pending' }
]);
changed.machine.tick();
changed.clock.advance(30 * MINUTE);
changed.machine.tick();
assert_equal(changed.machine.status().publication_retry_tag, 'v3.0.0');
assert_equal(changed.machine.status().publication_retry_count, 1,
	'a different incomplete tag starts a fresh 30-minute series');

let minor = environment([ { version: 'v1.5.0', ready: true, readiness: 'ready' } ]);
minor.machine.tick();
assert_equal(length(minor.submissions), 0);
assert_equal(minor.machine.status().next_check, 1784340000000);

let traffic_busy = environment([
	{ version: 'v2.0.0', ready: true, readiness: 'ready' }
], { wan_activity: { sample: (now) => ({ valid: true, quiet: false, samples: 10,
	bytes_per_second: 50000, packets_per_second: 20, reason: null }) } });
traffic_busy.machine.tick();
assert_equal(length(traffic_busy.submissions), 0);
assert_equal(traffic_busy.machine.status().pending_target, 'v2.0.0');
assert_equal(traffic_busy.machine.status().traffic_deferral_count, 1);
assert_equal(traffic_busy.machine.status().next_check, START + 30 * MINUTE);

let cutoff = environment([
	{ version: 'v2.0.0', ready: true, readiness: 'ready' }
], { now: START + 210 * MINUTE });
cutoff.machine.tick();
assert_equal(length(cutoff.submissions), 0);
assert_equal(cutoff.machine.status().next_check, 1784340000000);

let daytime = environment([
	{ version: 'v2.0.0', ready: true, readiness: 'ready' }
], { now: START + 5 * 60 * MINUTE });
daytime.machine.tick();
assert_equal(daytime.release_calls(), 0, 'daytime automatic ticks never query GitHub');
assert_equal(daytime.machine.status().next_check, 1784340000000);

let transport = environment([ 'DOWNLOAD_FAILED', 'DOWNLOAD_FAILED' ]);
transport.machine.tick();
assert_equal(transport.machine.status().publication_retry_count, 1);
assert_equal(transport.machine.status().last_error_code, 'DOWNLOAD_FAILED');

let queue_busy = environment([
	{ version: 'v2.0.0', ready: true, readiness: 'ready' }
], { busy: true });
queue_busy.machine.tick();
assert_equal(queue_busy.release_calls(), 0);
assert_equal(queue_busy.machine.status().publication_retry_count, 1);
assert_equal(queue_busy.machine.status().last_error_code, 'BUSY');

// Restart reconciliation preserves a recovered active operation, fails a
// missing journal record as interrupted, and clears a target already installed.
let queued = environment([
	{ version: 'v2.0.0', ready: true, readiness: 'ready' },
	{ version: 'v2.0.0', ready: true, readiness: 'ready' }
]);
queued.machine.tick();
let queued_id = queued.machine.status().pending_operation_id;
let persisted = queued.filesystem.readfile('/opt/clash/app-update-scheduler.json');
function recovered_filesystem() {
	return fakes.fs({ '/opt/clash/config.yaml': 'active\n',
		'/opt/clash/app-update-scheduler.json': persisted });
};
let active = environment([ { version: 'v2.0.0', ready: true, readiness: 'ready' } ], {
	filesystem: recovered_filesystem(), active_record: { id: queued_id,
		kind: 'updates.miclash', source: 'auto', state: 'queued' }
});
assert_equal(active.machine.status().pending_operation_id, queued_id);
assert_equal(length(active.submissions), 0);
let interrupted = environment([ { version: 'v2.0.0', ready: true, readiness: 'ready' } ], {
	filesystem: recovered_filesystem()
});
assert_equal(interrupted.machine.status().pending_operation_id, null);
assert_equal(interrupted.machine.status().pending_target, 'v2.0.0');
assert_equal(interrupted.machine.status().last_error_code, 'INTERRUPTED');
let already_installed = environment([
	{ version: 'v2.0.0', ready: true, readiness: 'ready' }
], { filesystem: recovered_filesystem(), app_version: '2.0.0' });
assert_equal(already_installed.machine.status().pending_operation_id, null);
assert_equal(already_installed.machine.status().pending_target, null);

// A router that gains a usable local timezone after an upgrade must not retain
// the old CLOCK_INVALID state until its former retry deadline.
let invalid_clock = environment([], { local_time: { observe: () => ({
	valid: false, local_date: null, minute: null, in_window: false,
	before_cutoff: false, next_window: null
}) } });
invalid_clock.machine.tick();
assert_equal(invalid_clock.machine.status().last_error_code, 'CLOCK_INVALID');
invalid_clock.machine.stop();
let repaired_clock = environment([], {
	filesystem: invalid_clock.filesystem,
	local_time: { observe: () => ({ valid: true, local_date: '2026-07-17',
		minute: 600, in_window: false, before_cutoff: false,
		next_window: 1784340000000 }) }
});
repaired_clock.machine.start();
repaired_clock.clock.advance(0);
assert_equal(repaired_clock.machine.status().last_error_code, null);
assert_equal(repaired_clock.machine.status().next_check, 1784340000000);

let disabled = environment([ { version: 'v2.0.0', ready: true, readiness: 'ready' } ]);
disabled.settings_value.updates.auto_major_miclash = false;
disabled.machine.tick();
assert_equal(disabled.machine.status().enabled, false);
assert_equal(disabled.machine.status().next_check, null);
assert_equal(length(disabled.submissions), 0);
