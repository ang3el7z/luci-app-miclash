import * as http from 'miclash.http';
import * as subscription from 'miclash.subscription';
import * as operations from 'miclash.operations';
import * as errors from 'miclash.errors';
import { assert_equal, assert_match, assert_throws, assert_true } from './testlib.uc';
import * as fakes from 'fakes';

function argument_after(args, name) {
	for (let index = 0; index + 1 < length(args); index++)
		if (args[index] == name)
			return args[index + 1];
	return null;
};

function http_environment(response) {
	let filesystem = fakes.fs();
	filesystem.mkdir('/tmp');
	filesystem.mkdir('/tmp/miclash');
	let process = fakes.process();
	process.on_run = (request) => {
		let header_path = argument_after(request.args, '--dump-header');
		let output_path = argument_after(request.args, '--output');
		filesystem.writefile(header_path, response?.headers ??
			'HTTP/1.1 200 OK\r\nContent-Type: application/yaml\r\n\r\n');
		filesystem.writefile(output_path, response?.body ??
			'proxies: []\nrules: []\n');
	};
	let runtime = {
		fs: filesystem,
		clock: fakes.clock(1700000000000),
		random: fakes.entropy(),
		process,
		paths: { tmp: '/tmp/miclash' }
	};
	return { filesystem, process, runtime };
};

assert_equal(type(http.request), 'function', 'HTTP module exports request()');
assert_equal(type(http.download), 'function', 'HTTP module exports download()');
assert_equal(type(subscription.create), 'function', 'subscription module exports create()');

// A direct HTTPS request is an argv-only curl invocation. The bounded adapter
// returns parsed status/headers/body and removes both owned Candidate files.
let direct = http_environment();
let direct_result = http.request(direct.runtime, {
	url: 'https://subscriptions.example.test/config.yaml',
	headers: { Accept: 'application/yaml' },
	connect_timeout_ms: 8000,
	timeout_ms: 120000,
	max_redirects: 3,
	max_bytes: 1024
});
assert_equal(direct_result.status, 200);
assert_equal(direct_result.headers['content-type'], 'application/yaml');
assert_equal(direct_result.body, 'proxies: []\nrules: []\n');
assert_equal(direct.process.calls[0].command, '/usr/bin/curl');
assert_true(type(direct.process.calls[0].args) == 'array');
assert_true(index(direct.process.calls[0].args,
	'https://subscriptions.example.test/config.yaml') >= 0);
assert_true(index(direct.process.calls[0].args, 'Accept: application/yaml') >= 0);
assert_equal(length(direct.filesystem.lsdir('/tmp/miclash/http')), 0);

// HTTP is opt-in for an explicit user subscription and never accepted for a
// managed endpoint. Credentials and header injection are rejected before the
// adapter or filesystem is touched.
assert_throws(() => http.request(http_environment().runtime, {
	url: 'http://subscriptions.example.test/config.yaml'
}), 'INVALID_ARGUMENT');
let insecure = http_environment();
assert_equal(http.request(insecure.runtime, {
	url: 'http://subscriptions.example.test/config.yaml', allow_insecure_http: true
}).insecure, true);
assert_throws(() => http.request(http_environment().runtime, {
	url: 'http://subscriptions.example.test/config.yaml', allow_insecure_http: true,
	managed: true
}), 'INVALID_ARGUMENT');
for (let hostile in [
	'https://user:pass@subscriptions.example.test/config.yaml',
	'https://subscriptions.example.test/config.yaml\r\nX-Evil: yes'
]) assert_throws(() => http.request(http_environment().runtime, { url: hostile }),
	'INVALID_ARGUMENT');
assert_throws(() => http.request(http_environment().runtime, {
	url: 'https://subscriptions.example.test/config.yaml',
	headers: { 'X-Device': 'router\r\nX-Evil: yes' }
}), 'INVALID_ARGUMENT');
assert_throws(() => http.request(http_environment().runtime, {
	url: 'https://subscriptions.example.test/config.yaml',
	headers: { 'X-Device': 'one', 'x-device': 'two' }
}), 'INVALID_ARGUMENT');
assert_throws(() => http.request(http_environment().runtime, {
	url: 'https://subscriptions.example.test/config.yaml', unknown_option: true
}), 'INVALID_ARGUMENT');

// Curl follows redirects with a protocol floor. Each response block is parsed
// independently and a HTTPS downgrade or duplicate header is rejected.
let redirect = http_environment({ headers:
	'HTTP/1.1 302 Found\r\nLocation: https://cdn.example.test/config.yaml\r\n\r\n' +
	'HTTP/2 200 OK\r\nContent-Type: application/yaml\r\n\r\n' });
assert_equal(http.request(redirect.runtime, {
	url: 'https://subscriptions.example.test/config.yaml', max_redirects: 2
}).status, 200);
assert_true(index(redirect.process.calls[0].args, '--proto-redir') >= 0);
assert_throws(() => http.request(http_environment({ headers:
	'HTTP/1.1 302 Found\r\nLocation: http://plain.example.test/config.yaml\r\n\r\n' +
	'HTTP/1.1 200 OK\r\n\r\n' }).runtime, {
	url: 'https://subscriptions.example.test/config.yaml'
}), 'INVALID_RESPONSE');
assert_throws(() => http.request(http_environment({ headers:
	'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\ncontent-type: text/yaml\r\n\r\n'
}).runtime, { url: 'https://subscriptions.example.test/config.yaml' }),
	'INVALID_RESPONSE');
assert_throws(() => http.request(http_environment({ headers:
	'HTTP/1.1 302 Found\r\nLocation: /again\r\n\r\n' +
	'HTTP/1.1 302 Found\r\nLocation: /again\r\n\r\n' +
	'HTTP/1.1 200 OK\r\n\r\n'
}).runtime, { url: 'https://subscriptions.example.test/config.yaml' }),
	'INVALID_RESPONSE');

// Adapter ambiguity, process failures, byte ceilings, and cleanup failures are
// safe terminal errors. The body limit is checked while reading, regardless of
// Content-Length.
let ambiguous = http_environment();
ambiguous.runtime.process.run = (request) => null;
assert_throws(() => http.request(ambiguous.runtime, {
	url: 'https://subscriptions.example.test/config.yaml'
}), 'INTERNAL');
let timeout = http_environment();
timeout.runtime.process.run = (request) => ({ code: 28, stdout: null, stderr: null });
assert_throws(() => http.request(timeout.runtime, {
	url: 'https://subscriptions.example.test/config.yaml'
}), 'DOWNLOAD_FAILED');
assert_throws(() => http.request(http_environment({ body: '0123456789' }).runtime, {
	url: 'https://subscriptions.example.test/config.yaml', max_bytes: 5
}), 'RESPONSE_TOO_LARGE');
let cleanup = http_environment();
cleanup.filesystem.fail_unlink_once = true;
assert_throws(() => http.request(cleanup.runtime, {
	url: 'https://subscriptions.example.test/config.yaml'
}), 'INTERNAL');

// Clock/random collisions retry exclusive creation and still leave no owned
// candidates behind.
let collision = http_environment();
collision.filesystem.collide_next_open = true;
assert_equal(http.download(collision.runtime, {
	url: 'https://subscriptions.example.test/config.yaml'
}).status, 200);
assert_equal(length(collision.filesystem.lsdir('/tmp/miclash/http')), 0);
let repeated_collision = http_environment();
repeated_collision.runtime.random = { hex: (bytes) => '0000000000000000' };
let foreign_candidate = '/tmp/miclash/http/1700000000000-0000000000000000-body';
repeated_collision.filesystem.writefile(foreign_candidate, 'foreign');
assert_throws(() => http.request(repeated_collision.runtime, {
	url: 'https://subscriptions.example.test/config.yaml'
}), 'INTERNAL');
assert_equal(repeated_collision.filesystem.readfile(foreign_candidate), 'foreign');

function subscription_environment(responses, initial_settings) {
	let filesystem = fakes.fs({ '/opt/clash/config.yaml': 'old-active\n' });
	filesystem.mkdir('/tmp');
	filesystem.mkdir('/tmp/miclash');
	let clock = fakes.clock(1700000000000);
	let runtime = {
		fs: filesystem, clock, random: fakes.entropy(), digest: fakes.digest(filesystem),
		paths: { tmp: '/tmp/miclash' }
	};
	let ops = operations.create(runtime);
	let calls = { http: [], validate: [], apply: [], settings: [] };
	let http_adapter = {
		download: (rt, options) => {
			push(calls.http, options);
			let response = responses[options.url];
			if (type(response) == 'string')
				errors.fail(response);
			if (response == null)
				errors.fail('DOWNLOAD_FAILED');
			return {
				status: 200, headers: response.headers ?? {}, body: response.body,
				url: options.url, insecure: match(options.url, /^http:\/\//) != null
			};
		}
	};
	let value = initial_settings ?? {
		core: {
			proxy_mode: 'tproxy', tun_stack: 'system', hwid_enabled: false,
			hwid_user_agent: 'MiClash Test', hwid_device_os: 'OpenWrt Test',
			subscription_url: '', subscription_url_config_yaml: '',
			subscription_url_config2_yaml: '', subscription_url_config3_yaml: ''
		}, updates: { interval_hours: 4 }
	};
	let settings = {
		get: () => value,
		validate: (patch) => patch,
		set: (patch) => { push(calls.settings, patch); return value; }
	};
	let config = { validation_result: { ok: true }, activation_result: { ok: true } };
	config.validate_in_operation = (ctx, profile, content) => {
			push(calls.validate, { id: ctx.id, profile, content });
			return config.validation_result;
		};
	config.apply_in_operation = (ctx, profile, content, source, extra) => {
			push(calls.apply, { id: ctx.id, profile, content, source, extra });
			return config.activation_result;
		};
	let client = subscription.create({ runtime, operations: ops, config, settings,
		http: http_adapter });
	return { filesystem, clock, runtime, ops, calls, config, settings, client };
};

function finish_subscription(env, record) {
	env.clock.advance(0);
	return env.ops.get(record.id);
};

let yaml = require('fs').readfile('tests/fixtures/subscription/direct.yaml');
let direct_sub = subscription_environment({
	'https://subscriptions.example.test/config.yaml': {
		headers: { 'profile-update-interval': '12' }, body: yaml
	}
});
let probe = direct_sub.client.probe({
	url: 'https://subscriptions.example.test/config.yaml'
});
assert_equal(probe.mode, 'direct');
assert_equal(probe.interval_hours, 12);
assert_equal(probe.payload, 'yaml');
assert_equal(direct_sub.calls.http[0].headers['User-Agent'], 'MiClash Test');
assert_equal(direct_sub.calls.http[0].headers['X-Device-OS'], 'OpenWrt Test');

let updated = direct_sub.client.update({ profile: 'config.yaml',
	url: 'https://subscriptions.example.test/config.yaml' }, 'auto');
let updated_record = finish_subscription(direct_sub, updated);
assert_equal(updated_record.state, 'success');
assert_equal(length(direct_sub.ops.list()), 1, 'one outer subscription operation');
assert_equal(length(direct_sub.calls.validate), 1);
assert_equal(length(direct_sub.calls.apply), 1);
assert_equal(direct_sub.calls.validate[0].id, direct_sub.calls.apply[0].id);
assert_match(direct_sub.calls.apply[0].content, /^mode: rule\n# Proxy Mode: TPROXY\nredir-port: 7892\ntproxy-port: 7894\n/);
assert_equal(direct_sub.calls.apply[0].extra.download_result, 'success');
assert_equal(direct_sub.calls.apply[0].extra.validation_result, 'success');

// URL + interval validation happens before queue mutation. The valid patch is
// committed by one central worker and one settings transaction.
let saved = subscription_environment({});
assert_throws(() => saved.client.set_url({ profile: 'config.yaml',
	url: 'ftp://secret.example/file', interval_hours: 6 }, 'luci'), 'INVALID_ARGUMENT');
assert_equal(length(saved.ops.list()), 0);
let saved_op = saved.client.set_url({ profile: 'config2.yaml',
	url: 'http://token.example.test/private?token=abc', interval_hours: 6 }, 'luci');
assert_equal(finish_subscription(saved, saved_op).state, 'success');
assert_equal(length(saved.calls.settings), 1);
assert_equal(saved.calls.settings[0].core.subscription_url_config2_yaml,
	'http://token.example.test/private?token=abc');
assert_equal(saved.calls.settings[0].updates.interval_hours, 6);

let secret_settings = {
	core: {
		proxy_mode: 'tun', tun_stack: 'gvisor', hwid_enabled: false,
		hwid_user_agent: 'MiClash', hwid_device_os: 'OpenWrt', subscription_url: '',
		subscription_url_config_yaml: 'http://secret.example.test/path?token=super-secret',
		subscription_url_config2_yaml: '', subscription_url_config3_yaml: ''
	}, updates: { interval_hours: 4 }
};
let redacted = subscription_environment({}, secret_settings).client.get_redacted('config.yaml');
assert_equal(redacted.insecure, true);
assert_true(index(sprintf('%J', redacted), 'super-secret') < 0);
assert_true(index(sprintf('%J', redacted), '/path') < 0);

// A decoded base64 YAML payload is valid directly. URI/base64 providers use
// the Remnawave /mihomo candidate, and GitHub raw/jsDelivr candidates work in
// both directions.
let encoded = subscription_environment({
	'https://subscriptions.example.test/base64': { body: b64enc(yaml) }
});
assert_equal(encoded.client.probe({
	url: 'https://subscriptions.example.test/base64'
}).payload, 'base64-yaml');
let remnawave = subscription_environment({
	'https://panel.example.test/sub/secret': {
		headers: { 'profile-update-interval': '24' },
		body: 'vless://secret@host.test:443'
	},
	'https://panel.example.test/sub/secret/mihomo': { body: yaml }
});
let remnawave_probe = remnawave.client.probe({
	url: 'https://panel.example.test/sub/secret'
});
assert_equal(remnawave_probe.mode, 'remnawave');
assert_equal(remnawave_probe.interval_hours, 24);
assert_equal(length(remnawave.calls.http), 2);
let raw_url = 'https://raw.githubusercontent.com/acme/profiles/main/config.yaml';
let cdn_url = 'https://cdn.jsdelivr.net/gh/acme/profiles@main/config.yaml';
let raw_responses = {};
raw_responses[raw_url] = 'DOWNLOAD_FAILED';
raw_responses[cdn_url] = { body: yaml };
let raw = subscription_environment(raw_responses);
assert_equal(raw.client.probe({ url: raw_url }).mode, 'github-cdn');
let cdn_responses = {};
cdn_responses[cdn_url] = 'DOWNLOAD_FAILED';
cdn_responses[raw_url] = { body: yaml };
let cdn = subscription_environment(cdn_responses);
assert_equal(cdn.client.probe({ url: cdn_url }).mode, 'github-raw');

// Invalid interval values are ignored and operation failures preserve Active
// byte-for-byte. Validation failure never enters activation.
let invalid = subscription_environment({
	'https://subscriptions.example.test/invalid': {
		headers: { 'profile-update-interval': '999999' }, body: 'not: a mihomo profile\n'
	}
});
invalid.config.validation_result = {
	ok: false, error: errors.new('VALIDATION_FAILED', 'VALIDATION_FAILED', { profile: 'config.yaml' })
};
let before_active = invalid.filesystem.readfile('/opt/clash/config.yaml');
let invalid_op = invalid.client.update({ profile: 'config.yaml',
	url: 'https://subscriptions.example.test/invalid' }, 'auto');
assert_equal(finish_subscription(invalid, invalid_op).error.code, 'VALIDATION_FAILED');
assert_equal(invalid.filesystem.readfile('/opt/clash/config.yaml'), before_active);
assert_equal(length(invalid.calls.apply), 0);
assert_equal(invalid.client.probe({
	url: 'https://subscriptions.example.test/invalid'
}).interval_hours, null);

let activation = subscription_environment({
	'https://subscriptions.example.test/health-fail': { body: yaml }
});
activation.config.activation_result = {
	ok: false, error: errors.new('HEALTH_FAILED', 'HEALTH_FAILED', { profile: 'config.yaml' })
};
let activation_op = activation.client.update({ profile: 'config.yaml',
	url: 'https://subscriptions.example.test/health-fail' }, 'auto');
assert_equal(finish_subscription(activation, activation_op).error.code, 'HEALTH_FAILED');
assert_equal(length(activation.ops.list()), 1);

// Header/device values and public operation status cannot disclose or inject
// the subscription secret.
let hostile_settings = { ...secret_settings,
	core: { ...secret_settings.core, hwid_user_agent: 'bad\nheader' } };
assert_throws(() => subscription_environment({}, hostile_settings).client.probe({
	url: 'https://subscriptions.example.test/config.yaml'
}), 'INVALID_ARGUMENT');
let safe_status_env = subscription_environment({
	'https://secret.example.test/private?token=super-secret': { body: yaml }
});
let safe_op = safe_status_env.client.update({ profile: 'config.yaml',
	url: 'https://secret.example.test/private?token=super-secret' }, 'auto');
finish_subscription(safe_status_env, safe_op);
assert_true(index(sprintf('%J', safe_status_env.ops.get(safe_op.id)), 'super-secret') < 0);
let cleanup_failure = subscription_environment({
	'https://subscriptions.example.test/cleanup': 'INTERNAL'
});
assert_throws(() => cleanup_failure.client.probe({
	url: 'https://subscriptions.example.test/cleanup'
}), 'INTERNAL');

let tun_settings = {
	core: {
		proxy_mode: 'tun', tun_stack: 'gvisor', hwid_enabled: false,
		hwid_user_agent: 'MiClash', hwid_device_os: 'OpenWrt', subscription_url: '',
		subscription_url_config_yaml: '', subscription_url_config2_yaml: '',
		subscription_url_config3_yaml: ''
	}, updates: { interval_hours: 4 }
};
let already_transformed = 'mode: rule\n# Proxy Mode: TPROXY\nredir-port: 7892\n' +
	'tproxy-port: 7894\ntun:\n  enable: false\nproxies: []\nrules: []\n';
let canonical = subscription_environment({
	'https://subscriptions.example.test/canonical': { body: already_transformed }
}, tun_settings);
let canonical_op = canonical.client.update({ profile: 'config.yaml',
	url: 'https://subscriptions.example.test/canonical' }, 'auto');
assert_equal(finish_subscription(canonical, canonical_op).state, 'success');
let canonical_content = canonical.calls.apply[0].content;
assert_true(index(canonical_content, 'tproxy-port:') < 0);
assert_match(canonical_content, /# Proxy Mode: TUN\ntun:\n  enable: true\n  device: clash-tun\n  stack: gvisor/);

print('ok - HTTP and subscription module contracts\n');
