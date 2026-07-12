import { assert_equal, assert_throws, assert_true } from './testlib.uc';
import * as errors from 'miclash.errors';
import * as schema from 'miclash.schema';

let busy = errors.normalize(errors.new('BUSY', 'busy', null));
assert_equal(busy.code, 'BUSY');
assert_equal(busy.message, 'busy');
assert_true(busy.detail == null);

assert_equal(errors.normalize({ message: 'NOT_FOUND' }).code, 'NOT_FOUND');
assert_equal(errors.normalize({ message: 'unexpected secret' }).code, 'INTERNAL');
assert_equal(errors.new('DOWNLOAD_FAILED', 'failed', {
	url: 'https://example.com',
	token: 'do-not-leak'
}).detail.token, '[REDACTED]');

assert_throws(() => schema.profile_name('config4.yaml'), 'INVALID_ARGUMENT');
assert_equal(schema.profile_name('config2.yaml'), 'config2.yaml');
assert_throws(() => schema.enum_value('bad', [ 'start', 'stop' ]), 'INVALID_ARGUMENT');
assert_throws(() => schema.secret(sprintf('%04097d', 0)), 'INVALID_ARGUMENT');
assert_equal(schema.validate({ type: 'string', max_length: 4 }, 'test'), 'test');
assert_equal(schema.validate({ type: 'boolean' }, true), true);
assert_throws(() => schema.validate({ type: 'boolean' }, 'true'), 'INVALID_ARGUMENT');
assert_equal(schema.mac_address('02:00:5e:10:00:00'), '02:00:5e:10:00:00');
assert_throws(() => schema.mac_address('not-a-mac'), 'INVALID_ARGUMENT');
assert_equal(schema.operation_id('update-123'), 'update-123');
assert_throws(() => schema.operation_id('../update'), 'INVALID_ARGUMENT');
assert_equal(schema.archive_name('backup-1.tar.gz'), 'backup-1.tar.gz');
assert_throws(() => schema.archive_name('../backup.tar.gz'), 'INVALID_ARGUMENT');
assert_throws(() => schema.managed_update_url('http://example.com/update'), 'INVALID_ARGUMENT');
assert_equal(schema.managed_update_url('https://example.com/update'), 'https://example.com/update');
assert_throws(() => schema.object({ action: 'start', extra: true }, {
	action: { type: 'string', enum: [ 'start', 'stop' ] }
}), 'INVALID_ARGUMENT');
assert_equal(schema.object({ action: 'stop' }, {
	action: { type: 'string', enum: [ 'start', 'stop' ] }
}).action, 'stop');
