import { assert_equal, assert_throws, assert_true } from './testlib.uc';
import * as errors from 'miclash.errors';
import * as redact from 'miclash.redact';
import * as schema from 'miclash.schema';

let busy = errors.normalize(errors.new('BUSY', 'busy', null));
assert_equal(busy.code, 'BUSY');
assert_equal(busy.message, 'busy');
assert_true(busy.detail == null);

assert_equal(errors.normalize({ message: 'NOT_FOUND' }).code, 'NOT_FOUND');
assert_equal(errors.normalize({ message: 'CORRUPT_STATE' }).code, 'CORRUPT_STATE');
assert_equal(errors.normalize({ message: 'unexpected secret' }).code, 'INTERNAL');
assert_equal(errors.new('DOWNLOAD_FAILED', 'failed', {
	url: 'https://example.com',
	token: 'do-not-leak'
}).detail.token, '[REDACTED]');
assert_equal(errors.new('DOWNLOAD_FAILED', 'failed', 'scalar secret').detail, '[REDACTED]');

let redacted = errors.new('INTERNAL', 'failed', {
	api_key: 'one',
	auth: 'two',
	authorization: 'three',
	bearer: 'four',
	cookie: 'five',
	credential: 'six',
	password: 'seven',
	private_key: 'eight',
	secret: 'nine',
	session: 'ten',
	token: 'eleven',
	nested: [ { api_key: 'nested-secret', safe: 'visible' } ]
}).detail;
for (let key in [ 'api_key', 'auth', 'authorization', 'bearer', 'cookie', 'credential',
	'password', 'private_key', 'secret', 'session', 'token' ])
	assert_equal(redacted[key], '[REDACTED]');
assert_equal(redacted.nested[0].api_key, '[REDACTED]');
assert_equal(redacted.nested[0].safe, 'visible');

let credentialed_url = 'https://user:pass@example/?ToKeN=secret&safe=ok&bearer=x&telegram_token=y';
let nested_urls = errors.new('DOWNLOAD_FAILED', 'failed', {
	url: credentialed_url,
	nested: [
		{ endpoint: 'http://name:key@example/path?Cookie=c&Access.Token=a&clientSecret=s' },
		'ordinary text ?token=must-stay',
		'https://array-user:array-pass@example/?refresh-token=r'
	]
}).detail;
assert_equal(nested_urls.url,
	'https://***:***@example/?ToKeN=***&safe=ok&bearer=***&telegram_token=***');
assert_equal(nested_urls.nested[0].endpoint,
	'http://***:***@example/path?Cookie=***&Access.Token=***&clientSecret=***');
assert_equal(nested_urls.nested[1], '[REDACTED]');
assert_equal(nested_urls.nested[2], 'https://***:***@example/?refresh-token=***');
assert_equal(redact.text('ordinary text ?token=must-stay'), 'ordinary text ?token=must-stay');
assert_equal(redact.text(redact.text(credentialed_url)), redact.text(credentialed_url));

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
assert_equal(schema.url('http://example.com:8080/path?q=1#fragment'), 'http://example.com:8080/path?q=1#fragment');
assert_equal(schema.managed_update_url('https://example.com:8443/update'), 'https://example.com:8443/update');
assert_equal(schema.url('https://updates.example.com/path'), 'https://updates.example.com/path');
assert_equal(schema.url('http://192.168.1.1:65535/path?q=1'), 'http://192.168.1.1:65535/path?q=1');
assert_throws(() => schema.url('https://'), 'INVALID_ARGUMENT');
assert_throws(() => schema.url('https://?query'), 'INVALID_ARGUMENT');
assert_throws(() => schema.url('https:///path'), 'INVALID_ARGUMENT');
assert_throws(() => schema.url('https://user@example.com/path'), 'INVALID_ARGUMENT');
assert_throws(() => schema.url('https://example.com/has\tspace'), 'INVALID_ARGUMENT');
assert_throws(() => schema.url(sprintf('https://example.com/%c', 1)), 'INVALID_ARGUMENT');
assert_throws(() => schema.url('https://example..com/path'), 'INVALID_ARGUMENT');
assert_throws(() => schema.url('https://-example.com/path'), 'INVALID_ARGUMENT');
assert_throws(() => schema.url('https://example-.com/path'), 'INVALID_ARGUMENT');
assert_throws(() => schema.url('https://256.1.1.1/path'), 'INVALID_ARGUMENT');
assert_throws(() => schema.url('https://192.168.001.1/path'), 'INVALID_ARGUMENT');
assert_throws(() => schema.url('https://1.2.3/path'), 'INVALID_ARGUMENT');
assert_throws(() => schema.url('https://example.com:/path'), 'INVALID_ARGUMENT');
assert_throws(() => schema.url('https://example.com:abc/path'), 'INVALID_ARGUMENT');
assert_throws(() => schema.url('https://example.com:0/path'), 'INVALID_ARGUMENT');
assert_throws(() => schema.url('https://example.com:65536/path'), 'INVALID_ARGUMENT');
assert_throws(() => schema.url('https://[2001:db8::1]/path'), 'INVALID_ARGUMENT');

let variant_redaction = errors.new('INTERNAL', 'failed', {
	nested: [ {
		'Access-Key': 'one',
		ACCESS_TOKEN: 'two',
		'access token': 'three',
		accessToken: 'four',
		'Refresh.Token': 'five',
		refreshToken: 'six',
		'CLIENT-SECRET': 'seven',
		clientSecret: 'eight',
		monkey: 'visible',
		session_count: 2
	} ]
}).detail.nested[0];
for (let key in [ 'Access-Key', 'ACCESS_TOKEN', 'access token', 'accessToken',
	'Refresh.Token', 'refreshToken', 'CLIENT-SECRET', 'clientSecret' ])
	assert_equal(variant_redaction[key], '[REDACTED]');
assert_equal(variant_redaction.monkey, 'visible');
assert_equal(variant_redaction.session_count, 2);

assert_throws(() => schema.object({ action: 'start', extra: true }, {
	action: { type: 'string', enum: [ 'start', 'stop' ] }
}), 'INVALID_ARGUMENT');
assert_equal(schema.object({ action: 'stop' }, {
	action: { type: 'string', enum: [ 'start', 'stop' ] }
}).action, 'stop');
