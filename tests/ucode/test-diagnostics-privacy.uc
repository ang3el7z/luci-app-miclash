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

// Runtime credentials are discovered from their text grammar, not from seeds.
// Each spelling uses an unrelated value so one successful discovery cannot
// accidentally hide a failure in another form.
let runtime_credentials = [
	[ 'token: colon-secret-91x', [ 'colon-secret-91x' ] ],
	[ '  api_key:\t yaml-key-82y', [ 'yaml-key-82y' ] ],
	[ 'Authorization: Bearer bearer-secret-73z', [ 'bearer-secret-73z' ] ],
	[ 'Authorization:\tBearer   spaced-bearer-64q', [ 'spaced-bearer-64q' ] ],
	[ 'Authorization: Basic ' + independent_base64('basic-user:basic-pass-55r'),
		[ independent_base64('basic-user:basic-pass-55r'), 'basic-user:basic-pass-55r',
			'basic-pass-55r' ] ],
	[ 'https://runtime-auth.invalid/check?access_token=query-secret-46s&safe=ok',
		[ 'query-secret-46s', percent_encoded('query-secret-46s'),
			independent_base64('query-secret-46s') ] ],
	[ 'Cookie: sid=cookie-secret-37t; csrf=csrf-secret-28u',
		[ 'cookie-secret-37t', 'csrf-secret-28u' ] ],
	[ 'token: ' + percent_encoded('percent-secret-19v'),
		[ percent_encoded('percent-secret-19v'), 'percent-secret-19v' ] ],
	[ 'token: ' + independent_base64('base64-secret-10w'),
		[ independent_base64('base64-secret-10w'), 'base64-secret-10w' ] ]
];
for (let mode in [ 'silent', 'lite' ])
	for (let probe in runtime_credentials) {
		let output = privacy.create(mode, []).text([], probe[0]);
		assert_absent(output, probe[1], mode + ' runtime credential');
	}

// Quoted JSON fields must expose their complete value to URL detection even
// when the URL has no raw '=' separator and uses arbitrary percent mixing.
let json_subscription =
	'htt%70s%3A%2F%2Fquoted-json.invalid%2Fsub%3Fcredential%3Djson-only-83k';
for (let mode in [ 'silent', 'lite' ]) {
	let output = privacy.create(mode, []).text([],
		'{"subscription":"' + json_subscription + '","status":"pending"}');
	assert_absent(output, [ json_subscription, 'quoted-json.invalid', 'json-only-83k' ],
		mode + ' quoted JSON subscription');
	assert_true(index(output, mode == 'silent' ? '[URL-1]' : '[REDACTED]') >= 0,
		mode + ' masks quoted JSON subscription');
}

// Work bounds fail closed. Oversized tokens and aggregate text are replaced as
// a unit before percent/Base64 expansion, and a long-lived profile cannot grow
// an unbounded runtime catalog across calls.
let oversized_credential = '';
for (let index = 0; index < 5000; index++) oversized_credential += 'A';
oversized_credential += '-oversized-secret-74m';
for (let mode in [ 'silent', 'lite' ])
	assert_equal(privacy.create(mode, []).text([], 'token: ' + oversized_credential),
		'[REDACTED]', mode + ' oversized credential fails closed');

let oversized_text = '';
for (let index = 0; index < 132000; index++) oversized_text += 'x';
oversized_text += ' token: aggregate-secret-65n';
for (let mode in [ 'silent', 'lite' ])
	assert_equal(privacy.create(mode, []).text([], oversized_text), '[REDACTED]',
		mode + ' oversized text fails closed');

for (let mode in [ 'silent', 'lite' ]) {
	let bounded_profile = privacy.create(mode, []);
	let output;
	for (let index = 0; index < 300; index++) {
		let runtime_secret = 'catalog-secret-' + index + '-56p';
		output = bounded_profile.text([], 'token: ' + runtime_secret);
		assert_absent(output, [ runtime_secret ], mode + ' bounded runtime catalog');
	}
	assert_equal(output, '[REDACTED]', mode + ' saturated runtime catalog fails closed');
	assert_equal(bounded_profile.text([], 'https://status.provider.example/health'),
		'[REDACTED]', mode + ' saturated profile remains fail closed');
}

// Subscription context, not URL spelling, determines whether an opaque URL is
// unsafe in Lite. Every probe is runtime-only and uses an empty seed catalog.
let opaque_subscription_url = 'https://opaque.provider.example/cfg/A9z7Yx6Wv5';
let opaque_percent_url = percent_encoded(opaque_subscription_url);
let opaque_base64_url = independent_base64(opaque_subscription_url);
let opaque_base64url_url = independent_base64url(opaque_subscription_url);
let lite_subscription_probes = [
	[ privacy.create('lite', []).text([], 'subscription: ' + opaque_subscription_url),
		[ opaque_subscription_url ] ],
	[ privacy.create('lite', []).value([], { subscription: opaque_subscription_url }),
		[ opaque_subscription_url ] ],
	[ privacy.create('lite', []).value([ 'subscriptions', 0, 'url' ],
		opaque_subscription_url), [ opaque_subscription_url ] ],
	[ privacy.create('lite', []).value([ 'subscriptions', 0, 'url' ],
		opaque_percent_url), [ opaque_percent_url, opaque_subscription_url ] ],
	[ privacy.create('lite', []).value([], { subscription: opaque_base64_url }),
		[ opaque_base64_url, opaque_subscription_url ] ],
	[ privacy.create('lite', []).text([], 'subscription=' + opaque_percent_url),
		[ opaque_percent_url, opaque_subscription_url ] ],
	[ privacy.create('lite', []).text([], 'subscription=' + opaque_base64_url),
		[ opaque_base64_url, opaque_subscription_url ] ],
	[ privacy.create('lite', []).text([], 'subscription=' + opaque_base64url_url),
		[ opaque_base64url_url, opaque_subscription_url ] ]
];
for (let probe in lite_subscription_probes)
	assert_absent(probe[0], probe[1], 'lite opaque subscription URL');

// Credential query names make the whole URL unsafe; a normal provider status
// endpoint remains visible in Lite.
for (let name in [ 'credential', 'credentials', 'password', 'passwd', 'auth',
	'session', 'access_key', 'api_key', 'signing_key', 'client_secret' ]) {
	let credential_url = 'https://status.provider.example/health?' + name +
		'=query-only-' + name;
	assert_absent(privacy.create('lite', []).text([], credential_url),
		[ credential_url, 'query-only-' + name ], 'lite credential-bearing URL');
	for (let encoded_url in [ percent_encoded(credential_url),
		independent_base64(credential_url), independent_base64url(credential_url) ])
		assert_absent(privacy.create('lite', []).text([], encoded_url),
			[ encoded_url, credential_url, 'query-only-' + name ],
			'lite encoded credential-bearing URL');
}
assert_equal(privacy.create('lite', []).value([], {
	url: 'https://status.provider.example/health'
}).url, 'https://status.provider.example/health',
	'lite retains harmless structured provider status URL');

// A route/network `device` exception accepts interface names, not arbitrary
// network identifiers that happen to fit the old interface character class.
assert_equal(privacy.create('lite', []).value([ 'network' ], {
	device: 'eth0'
}).device, 'eth0', 'lite retains a valid interface name');
for (let identifier in [ '192.0.2.10', '192.0.2.0/24', '2001:db8::10',
	'0A:1B:2C:3D:4E:5F', 'https://router.invalid', 'router.example' ])
	assert_equal(privacy.create('lite', []).value([ 'network' ], {
		device: identifier
	}).device, '[REDACTED]', 'lite rejects non-interface device identifier ' + identifier);

// Silent URL typing wins over generic secret-key classification, and an
// equivalent URL has one report-local typed label through every API surface.
let equivalent_url = 'https://typed-url.invalid/opaque/A1b2C3d4';
let silent_url_profile = privacy.create('silent', []);
let silent_url_fields = silent_url_profile.value([], {
	subscription_url: equivalent_url,
	url: equivalent_url,
	password: equivalent_url
});
assert_equal(silent_url_fields.subscription_url, '[URL-1]');
assert_equal(silent_url_fields.url, '[URL-1]');
assert_equal(silent_url_fields.password, '[URL-1]');
assert_equal(silent_url_profile.text([], 'observed=' + equivalent_url),
	'observed=[URL-1]');

// The text API receives the same report path as the structured API. Opaque
// subscription URLs are unsafe because of that path even when the spelling has
// no credential hint.
for (let spelling in [ opaque_subscription_url, opaque_percent_url,
	opaque_base64_url, opaque_base64url_url ])
	assert_equal(privacy.create('lite', []).text([ 'subscriptions', 0, 'url' ],
		spelling), '[REDACTED]', 'lite text masks path-scoped subscription URL');

// URL identity is based on the decoded canonical URL. Partial percent encoding
// must neither create a second Silent label nor evade structured Lite query
// credential classification.
let raw_api_url =
	'https://status.provider.example/health?api_key=query-canonical-secret';
let partial_api_url =
	'https://status.provider.example/health?api%5Fkey=query-canonical-secret';
let canonical_profile = privacy.create('silent', []);
let canonical_fields = canonical_profile.value([], {
	raw: raw_api_url,
	partial: partial_api_url
});
assert_equal(canonical_fields.raw, '[URL-1]');
assert_equal(canonical_fields.partial, '[URL-1]');
assert_equal(canonical_profile.text([], 'retry=' + partial_api_url), 'retry=[URL-1]');
assert_equal(privacy.create('lite', []).value([], {
	url: partial_api_url
}).url, '[REDACTED]', 'lite masks partially encoded structured API key URL');

// Runtime YAML/log fields use the shared secret-name classifier, including
// camelCase names. Device-name fields are identifying in both sharing-safe
// modes and accept ':' as well as '=' assignments.
let marker_probes = [
	[ 'apiSecret: camel-api-secret-31a', 'camel-api-secret-31a' ],
	[ 'authorizationHeader: Bearer camel-auth-secret-42b', 'camel-auth-secret-42b' ],
	[ 'sessionId: camel-session-secret-53c', 'camel-session-secret-53c' ],
	[ 'xAPIKey: camel-key-secret-64d', 'camel-key-secret-64d' ],
	[ 'deviceName: Personal Handset 75e\nstatus: online', 'Personal Handset 75e' ],
	[ 'clientDeviceName=Kitchen Tablet 86f\nstatus=online', 'Kitchen Tablet 86f' ]
];
for (let mode in [ 'silent', 'lite' ])
	for (let probe in marker_probes)
		assert_absent(privacy.create(mode, []).text([], probe[0]), [ probe[1] ],
			mode + ' runtime camel/YAML marker');

// Caller-controlled paths are part of the untrusted redaction boundary. They
// are validated before discovery or context scanning and fail closed on depth,
// node-count, or aggregate-byte exhaustion.
let oversized_path = [];
for (let index = 0; index < 5000; index++)
	push(oversized_path, 'segment-' + index);
let oversized_path_segment = '';
for (let index = 0; index < 5000; index++)
	oversized_path_segment += 'x';
let aggregate_path = [], aggregate_segment = '';
for (let index = 0; index < 4000; index++)
	aggregate_segment += 'y';
for (let index = 0; index < 9; index++)
	push(aggregate_path, aggregate_segment);
for (let mode in [ 'silent', 'lite' ]) {
	assert_equal(privacy.create(mode, []).value(oversized_path, status_url),
		'[REDACTED]', mode + ' rejects 5000-segment caller path');
	assert_equal(privacy.create(mode, []).text([ oversized_path_segment ], status_url),
		'[REDACTED]', mode + ' rejects oversized caller path bytes');
	assert_equal(privacy.create(mode, []).text(aggregate_path, status_url),
		'[REDACTED]', mode + ' rejects aggregate caller path bytes');
}

// A domain followed by a TCP/UDP port remains one host identity in Silent.
// Only the host is anonymized so the diagnostic port evidence stays useful.
let port_profile = privacy.create('silent', []);
assert_equal(port_profile.text([], 'provider.example:443 -> provider.example:8443'),
	'[HOST-1]:443 -> [HOST-1]:8443');
assert_equal(port_profile.value([], { endpoint: 'provider.example:443' }).endpoint,
	'[HOST-1]:443');
assert_equal(privacy.create('lite', []).text([], 'provider.example:443'),
	'provider.example:443', 'lite retains provider domain and port');

// Pre-seeded secrets may later appear with any mixture of raw and percent-
// encoded bytes, not just the fixed fully encoded spellings.
let preseed_mixed_secret = 'preseed-secret-Alpha92';
let preseed_mixed_spelling = 'pre%73eed-secret-%41lpha92';
for (let mode in [ 'silent', 'lite' ]) {
	let profile = privacy.create(mode, [ { token: preseed_mixed_secret } ]);
	let output = profile.text([], 'observed=' + preseed_mixed_spelling);
	assert_absent(output, [ preseed_mixed_secret, preseed_mixed_spelling ],
		mode + ' pre-seeded mixed-percent secret');
	assert_equal(output, 'observed=[REDACTED]',
		mode + ' replaces pre-seeded mixed-percent secret');
}

// YAML literal and folded block scalars under secret keys are one credential.
// Discovery must mask the indented source and retain the de-indented/folded
// canonical value for later occurrences in the same report.
for (let mode in [ 'silent', 'lite' ]) {
	let literal_profile = privacy.create(mode, []);
	let literal_output = literal_profile.text([], 'api_key: |\n' +
		'  literal-block-secret-42x\n  literal-tail-42x\nstatus: ready');
	assert_absent(literal_output,
		[ 'literal-block-secret-42x', 'literal-tail-42x' ],
		mode + ' YAML literal secret block');
	assert_absent(literal_profile.text([], 'retry="literal-block-secret-42x\n' +
		'literal-tail-42x"'),
		[ 'literal-block-secret-42x', 'literal-tail-42x' ],
		mode + ' YAML literal canonical secret');

	let folded_profile = privacy.create(mode, []);
	let folded_output = folded_profile.text([], 'password: >\n' +
		'  folded-block-secret-53y\n  folded-tail-53y\nstatus: ready');
	assert_absent(folded_output,
		[ 'folded-block-secret-53y', 'folded-tail-53y' ],
		mode + ' YAML folded secret block');
	assert_equal(folded_profile.text([], 'retry=folded-block-secret-53y folded-tail-53y'),
		'retry=[REDACTED]', mode + ' YAML folded canonical secret');

	let indented_profile = privacy.create(mode, []);
	let indented_output = indented_profile.text([], 'password: >\n' +
		'  alpha-secret-64z\n    beta-secret-64z\n  gamma-secret-64z');
	assert_absent(indented_output,
		[ 'alpha-secret-64z', 'beta-secret-64z', 'gamma-secret-64z' ],
		mode + ' YAML folded more-indented secret block');
	assert_equal(indented_profile.text([], 'observed=alpha-secret-64z\n' +
		'  beta-secret-64z\ngamma-secret-64z\n'), 'observed=[REDACTED]',
		mode + ' YAML folded more-indented canonical secret');

	let blank_profile = privacy.create(mode, []);
	let blank_output = blank_profile.text([], 'password: >\n' +
		'  blank-alpha-secret-75a\n\n  blank-beta-secret-75a\nstatus: ready');
	assert_absent(blank_output,
		[ 'blank-alpha-secret-75a', 'blank-beta-secret-75a' ],
		mode + ' YAML folded blank-line secret block');
	assert_equal(blank_profile.text([], 'observed=blank-alpha-secret-75a\n' +
		'blank-beta-secret-75a\n'), 'observed=[REDACTED]',
		mode + ' YAML folded blank-line canonical secret');

	let combined_profile = privacy.create(mode, []);
	let combined_output = combined_profile.text([], 'password: >\n' +
		'  combined-alpha-secret-86b\n    combined-beta-secret-86b\n\n' +
		'  combined-gamma-secret-86b\nstatus: ready');
	assert_absent(combined_output,
		[ 'combined-alpha-secret-86b', 'combined-beta-secret-86b',
			'combined-gamma-secret-86b' ],
		mode + ' YAML folded more-indented blank-line secret block');
	assert_equal(combined_profile.text([], 'observed=combined-alpha-secret-86b\n' +
		'  combined-beta-secret-86b\n\ncombined-gamma-secret-86b\n'),
		'observed=[REDACTED]',
		mode + ' YAML folded more-indented blank-line canonical secret');
}

// Credential aliases compose their bounded codecs: percent encoding may wrap
// either Base64 alphabet, and the decoded raw credential remains report-wide.
let percent_base64_secret = 'percent-base64-secret-64q';
let percent_base64_alias = percent_encoded(independent_base64(percent_base64_secret));
let percent_base64url_secret = 'percent-base64url-secret-???';
let percent_base64url_alias =
	percent_encoded(independent_base64url(percent_base64url_secret));
for (let mode in [ 'silent', 'lite' ])
	for (let probe in [
		[ percent_base64_alias, percent_base64_secret, 'Base64' ],
		[ percent_base64url_alias, percent_base64url_secret, 'Base64URL' ]
	]) {
		let profile = privacy.create(mode, []);
		assert_absent(profile.text([], 'token: ' + probe[0]), [ probe[0], probe[1] ],
			mode + ' percent-encoded ' + probe[2] + ' credential');
		assert_equal(profile.text([], 'observed=' + probe[1]), 'observed=[REDACTED]',
			mode + ' catalogs raw ' + probe[2] + ' credential');
	}

// Brackets are IPv6 transport syntax, not an extra pair to retain around a
// privacy label. The port remains useful evidence; Lite still masks every IP.
let bracketed_ipv6 = '2001:db8::77';
let bracketed_silent_raw = privacy.create('silent', []).text([], bracketed_ipv6);
assert_equal(bracketed_silent_raw, '[IP-1]',
	'silent redacts raw compressed IPv6, got ' + bracketed_silent_raw);
let bracketed_silent_bare =
	privacy.create('silent', []).text([], '[' + bracketed_ipv6 + ']');
assert_equal(bracketed_silent_bare, '[IP-1]',
	'silent redacts bracketed IPv6, got ' + bracketed_silent_bare);
assert_equal(privacy.create('silent', []).text([], '[' + bracketed_ipv6 + ']:8443'),
	'[IP-1]:8443', 'silent redacts bracketed IPv6 and retains port');
assert_equal(privacy.create('lite', []).text([], '[' + bracketed_ipv6 + ']'),
	'[REDACTED]',
	'lite masks bracketed IPv6');
assert_equal(privacy.create('lite', []).text([], '[' + bracketed_ipv6 + ']:8443'),
	'[REDACTED]:8443', 'lite masks bracketed IPv6 and retains port');
let embedded_ipv6 = '::ffff:192.0.2.128';
assert_equal(privacy.create('silent', []).text([], '[' + embedded_ipv6 + ']:443'),
	'[IP-1]:443', 'silent redacts bracketed IPv4-embedded IPv6');
assert_equal(privacy.create('lite', []).text([], '[' + embedded_ipv6 + ']:443'),
	'[REDACTED]:443', 'lite masks bracketed IPv4-embedded IPv6');
