import * as updater from 'miclash.device-vendor-update';
import * as errors from 'miclash.errors';
import { clock, digest, fs } from './fakes.uc';
import { assert_equal, assert_true } from 'testlib';

const DAY = 86400 * 1000;
const MONTH = 30 * DAY;
const START = 1784412000000;
const DATABASE_PATH = '/etc/miclash/device-vendors.db';

assert_equal(updater.next_check(START, true), START + MONTH,
	'a successful refresh schedules the next check in 30 days');
assert_equal(updater.next_check(START, false), START + DAY,
	'a failed refresh schedules the next check in one day');

let filesystem = fs({ [DATABASE_PATH]: 'old database\n' });
filesystem.mkdir('/opt');
filesystem.mkdir('/opt/clash');
let timer = clock(START);
let runtime = { fs: filesystem, digest: digest(filesystem), clock: timer };
let replies = [], calls = [];
let http = { request: (rt, options) => {
	push(calls, options);
	let reply = shift(replies);
	if (reply?.error != null) errors.fail(reply.error);
	return { status: 200, headers: {}, body: reply?.body ?? '' };
} };

let controller = updater.create({ runtime, http,
	manifest_url: 'https://raw.githubusercontent.com/example/vendors.manifest.json',
	database_url: 'https://raw.githubusercontent.com/example/vendors.db' });
assert_equal(controller.start(), true);
assert_equal(controller.status().next_check, START + MONTH,
	'a fresh bundled snapshot waits one month before network maintenance');

replies = [ { error: 'DOWNLOAD_FAILED' } ];
timer.advance(MONTH);
assert_equal(controller.status().last_result, 'failure');
assert_equal(controller.status().next_check, START + MONTH + DAY);
assert_equal(filesystem.readfile(DATABASE_PATH), 'old database\n');

replies = [ { error: 'DOWNLOAD_FAILED' } ];
timer.advance(DAY);
assert_equal(controller.status().next_check, START + MONTH + 2 * DAY,
	'repeated failures continue retrying once per day without a cap');

let database = '# miclash-device-vendors-v1\n# snapshot=2026-08-19\n' +
	'V\t0\tVendor\nP\t24\t001122\t0\n';
let manifest = sprintf('%J', { version: 1, snapshot: '2026-08-19',
	size: length(database), sha256: runtime.digest.sha256(database) });
replies = [ { body: manifest }, { body: database } ];
timer.advance(DAY);
assert_equal(controller.status().last_result, 'success');
assert_equal(controller.status().snapshot, '2026-08-19');
assert_equal(controller.status().next_check, START + MONTH + 2 * DAY + MONTH,
	'eventual success restores the 30-day interval');
assert_equal(filesystem.readfile(DATABASE_PATH), database);

let before = filesystem.readfile(DATABASE_PATH);
let now = controller.status().next_check;
let bad_manifest = sprintf('%J', { version: 1, snapshot: '2026-09-19',
	size: length(database), sha256: sprintf('%064x', 1) });
replies = [ { body: bad_manifest }, { body: database } ];
timer.advance(now - timer.now());
assert_equal(controller.status().last_result, 'failure');
assert_equal(filesystem.readfile(DATABASE_PATH), before,
	'a failed digest validation preserves the previous working database');
assert_equal(controller.status().next_check, now + DAY);

assert_true(length(calls) >= 6, 'maintenance performed bounded HTTP requests');
assert_equal(controller.close(), true);
print('device vendor update tests passed\n');
