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

function lower_percent_encoded(value) {
	let output = '';
	for (let offset = 0; offset < length(value); offset++) {
		let character = substr(value, offset, 1);
		output += match(character, /^[A-Za-z0-9_.~-]$/) ? character :
			lc(sprintf('%%%02X', ord(value, offset)));
	}
	return output;
};

function independent_base64(value) {
	let alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/', output = '';
	for (let offset = 0; offset < length(value); offset += 3) {
		let first = ord(value, offset);
		let second = offset + 1 < length(value) ? ord(value, offset + 1) : 0;
		let third = offset + 2 < length(value) ? ord(value, offset + 2) : 0;
		output += substr(alphabet, int(first / 4), 1);
		output += substr(alphabet, (first % 4) * 16 + int(second / 16), 1);
		output += offset + 1 < length(value) ? substr(alphabet, (second % 16) * 4 + int(third / 64), 1) : '=';
		output += offset + 2 < length(value) ? substr(alphabet, third % 64, 1) : '=';
	}
	return output;
};

function independent_base64url(value) {
	return replace(replace(replace(independent_base64(value), /\+/g, '-'), /\//g, '_'), /=+$/, '');
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

// Runtime log lines are not necessarily represented in configuration seeds.
// Every raw or encoded sensitive value below exists only in the streamed text.
let runtime_url = 'https://runtime.example.invalid/path?token=runtime-token';
let runtime_host = 'runtime.example.invalid';
let runtime_ip = '198.51.100.42/24';
let runtime_ipv6 = '2001:db8:1::42/64';
let runtime_mac = '0A:1B:2C:3D:4E:5F';
let runtime_uuid = '123e4567-e89b-12d3-a456-426614174000';
let runtime_device = 'Runtime Handset';
let runtime_text = runtime_url + ' host=' + runtime_host + ' ip=' + runtime_ip +
	' ipv6=' + runtime_ipv6 + ' mac=' + runtime_mac + ' uuid=' + runtime_uuid +
	' device=' + runtime_device + ' pct=' + lower_percent_encoded(runtime_ip) +
	' b64=' + independent_base64(runtime_uuid) + ' b64url=' + independent_base64url(runtime_mac);
let runtime_silent = privacy.create('silent', []).text([], runtime_text);
	assert_absent(runtime_silent, [ runtime_url, runtime_host, runtime_ip, runtime_ipv6,
	runtime_mac, runtime_uuid, runtime_device, lower_percent_encoded(runtime_ip),
	independent_base64(runtime_uuid), independent_base64url(runtime_mac) ], 'runtime silent');
assert_match(runtime_silent, /\[URL-1\].*\[HOST-1\].*\[IP-1\].*\[IP-2\].*\[DEVICE-1\].*\[ID-1\]/);
let runtime_lite = privacy.create('lite', []).text([], runtime_text);
	assert_absent(runtime_lite, [ runtime_url, runtime_ip, runtime_ipv6, runtime_mac,
	runtime_uuid, runtime_device, lower_percent_encoded(runtime_ip),
	independent_base64(runtime_uuid), independent_base64url(runtime_mac) ], 'runtime lite');
assert_true(index(runtime_lite, runtime_host) >= 0, 'lite retains provider domain');
let status_url = 'https://status.provider.example/health';
assert_equal(privacy.create('lite', []).text([], status_url), status_url,
	'lite retains harmless provider status URLs');

// Subscription URLs remain unsafe in every encoded transport representation.
for (let mode in [ 'silent', 'lite' ]) {
	for (let probe in [ percent_encoded(runtime_url), lower_percent_encoded(runtime_url),
		independent_base64(runtime_url), independent_base64url(runtime_url) ]) {
		let output = privacy.create(mode, []).text([], 'subscription=' + probe);
		assert_absent(output, [ runtime_url, probe, runtime_host, 'runtime-token' ],
			mode + ' encoded subscription URL');
	}
}

// Percent encoding may cover any arbitrary mixture of otherwise safe and unsafe URL bytes.
let mixed_percent_urls = [
	'htt%70s%3A%2F%2Frunt%69me.example.invalid%2Fpath%3Ftoken%3Druntime-token',
	'h%74tps://runtime.example.invalid/path%3Ftoken=runtime-token'
];
for (let mode in [ 'silent', 'lite' ])
	for (let probe in mixed_percent_urls) {
		let output = privacy.create(mode, []).text([], 'subscription=' + probe);
		assert_absent(output, [ probe, runtime_host, 'runtime-token' ],
			mode + ' mixed percent subscription URL');
		assert_true(index(output, mode == 'silent' ? '[URL-1]' : '[REDACTED]') >= 0,
			mode + ' replaces mixed percent subscription URL');
	}
for (let mode in [ 'silent', 'lite' ]) {
	let probe = mixed_percent_urls[0];
	let output = privacy.create(mode, []).text([], 'subscription="' + probe + '"');
	assert_absent(output, [ probe, runtime_host, 'runtime-token' ],
		mode + ' quoted mixed percent subscription URL');
}
let oversized_percent_url = 'htt%70s%3A%2F%2Fruntime.example.invalid/';
for (let index = 0; index < 4096; index++) oversized_percent_url += 'a';
oversized_percent_url += '%3Ftoken%3Druntime-token';
for (let mode in [ 'silent', 'lite' ]) {
	let output = privacy.create(mode, []).text([], 'subscription=' + oversized_percent_url);
	assert_absent(output, [ oversized_percent_url, runtime_host, 'runtime-token' ],
		mode + ' oversized percent subscription URL');
}

// Typed labels are shared by object and text transforms within one report.
let typed_source = { hostname: runtime_host, mac: runtime_mac,
	device_name: runtime_device, uuid: runtime_uuid };
let typed_privacy = privacy.create('silent', []);
let typed_object = typed_privacy.value([], typed_source);
assert_equal(typed_object.hostname, '[HOST-1]');
assert_equal(typed_object.mac, '[DEVICE-1]');
assert_equal(typed_object.device_name, '[DEVICE-2]');
assert_equal(typed_object.uuid, '[ID-1]');
let typed_text = typed_privacy.text([], runtime_host + ' ' + runtime_mac + ' device=' +
	runtime_device + ' uuid=' + runtime_uuid);
assert_match(typed_text, /\[HOST-1\].*\[DEVICE-1\].*\[DEVICE-2\].*\[ID-1\]/);

// Text markers use the same typed label as structured values, including local hostnames.
let local_hostname = 'router-main';
let hostname_privacy = privacy.create('silent', []);
assert_equal(hostname_privacy.value([], { hostname: local_hostname }).hostname, '[HOST-1]');
assert_equal(hostname_privacy.text([], 'hostname=' + local_hostname), 'hostname=[HOST-1]');

// Plain and subscription-scoped structured IDs remain identifying data.
let structured_ids = { id: 'plain-42', subscription_id: 'subscription-73' };
let silent_ids = privacy.create('silent', []).value([], structured_ids);
assert_equal(silent_ids.id, '[ID-1]');
assert_equal(silent_ids.subscription_id, '[ID-2]');
let lite_ids = privacy.create('lite', []).value([], structured_ids);
assert_equal(lite_ids.id, '[REDACTED]');
assert_equal(lite_ids.subscription_id, '[REDACTED]');

// Lite keeps kernel interface names only in route/network device contexts.
let lite_devices = privacy.create('lite', []).value([], {
	routing: { routes: [ { device: 'eth0' } ] },
	network: { device: 'br-lan', clients: [ { device: 'phone0' } ] }
});
assert_equal(lite_devices.routing.routes[0].device, 'eth0');
assert_equal(lite_devices.network.device, 'br-lan');
assert_equal(lite_devices.network.clients[0].device, '[REDACTED]');
