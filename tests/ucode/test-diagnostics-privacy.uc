import { assert_equal, assert_match, assert_true } from 'testlib';
import * as privacy from 'miclash.diagnostics-privacy';

function percent_encoded(value) {
	let output = '';
	for (let offset = 0; offset < length(value); offset++)
		output += sprintf('%%%02X', ord(value, offset));
	return output;
};

function urlsafe_base64(value) {
	return replace(replace(replace(b64enc(value), /\+/g, '-'), /\//g, '_'), /=+$/, '');
};

function assert_absent(value, forbidden, label) {
	let text = type(value) == 'string' ? value : sprintf('%J', value);
	for (let item in forbidden)
		assert_true(index(text, item) < 0, label + ' leaked ' + item);
};

let secret = '8841880153:exampleTokenMustDisappear';
let source = {
	token: secret,
	endpoint: 'await.akira.click',
	ip: '192.0.2.10',
	mac: 'AA:BB:CC:DD:EE:FF',
	device_name: 'Angel Phone',
	message: 'await.akira.click -> 192.0.2.10'
};
let silent = privacy.create('silent', [ source ]).value([], source);
assert_equal(silent.endpoint, '[HOST-1]');
assert_equal(silent.ip, '[IP-1]');
assert_match(silent.message, /\[HOST-1\].*\[IP-1\]/);
let lite = privacy.create('lite', [ source ]).value([], source);
assert_equal(lite.endpoint, 'await.akira.click');
assert_equal(lite.ip, '[REDACTED]');
assert_equal(lite.token, '[REDACTED]');
assert_equal(privacy.create('full', [ source ]).value([], source).token, secret);

let encoded = {
	token: secret,
	url: 'https://user:' + secret + '@await.akira.click/path?token=' + secret,
	cookie: 'sid=' + secret + '; csrf=' + secret,
	authorization: 'Bearer ' + secret,
	yaml: 'token: ' + secret + '\nnested:\n  api_key: ' + secret,
	nested: { credentials: { password: secret } },
	ipv6: '2001:db8:85a3::8a2e:370:7334/64',
	message: 'encoded=' + percent_encoded(secret) + ' base64=' + b64enc(secret) +
		' base64url=' + urlsafe_base64(secret) + ' split ' + secret
};
for (let mode in [ 'silent', 'lite' ]) {
	let transformed = privacy.create(mode, [ encoded ]).value([], encoded);
	assert_absent(transformed, [ secret, percent_encoded(secret), b64enc(secret),
		urlsafe_base64(secret), '192.0.2.10', 'AA:BB:CC:DD:EE:FF',
		'Angel Phone', '2001:db8:85a3::8a2e:370:7334/64' ], mode);
}

let metadata = privacy.create('silent', [ source ]).metadata();
assert_equal(metadata.mode, 'silent');
assert_equal(metadata.contains_secrets, false);
assert_equal(metadata.sharing_safe, true);
