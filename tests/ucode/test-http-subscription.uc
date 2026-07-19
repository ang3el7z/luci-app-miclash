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

function curl_config_paths(filesystem, args) {
	let config_path = argument_after(args, '--config');
	let config = filesystem.readfile(config_path);
	let header = match(config, /dump-header = "([^"]+)"/);
	let output = match(config, /output = "([^"]+)"/);
	return { config_path, config, header_path: header?.[1], output_path: output?.[1] };
};

function http_environment(response) {
	let filesystem = fakes.fs();
	filesystem.mkdir('/tmp');
	filesystem.mkdir('/tmp/miclash');
	let process = fakes.process();
	process.on_run = (request) => {
		let paths = curl_config_paths(filesystem, request.args);
		filesystem.writefile(paths.header_path, response?.headers ??
			'HTTP/1.1 200 OK\r\nContent-Type: application/yaml\r\n\r\n');
		filesystem.writefile(paths.output_path, response?.body ??
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

// A direct HTTPS request exposes only an opaque root-owned curl config pathname
// in argv. The config contains the credentials and all owned output paths.
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
assert_equal(length(direct.process.calls[0].args), 2);
assert_equal(direct.process.calls[0].args[0], '--config');
assert_true(index(direct.process.calls[0].args,
	'https://subscriptions.example.test/config.yaml') < 0);
assert_true(index(direct.process.calls[0].args, 'Accept: application/yaml') < 0);
assert_equal(length(direct.filesystem.lsdir('/tmp/miclash/http')), 0);
assert_equal(direct.filesystem.mode('/tmp/miclash'), 0o700);
assert_equal(direct.filesystem.mode('/tmp/miclash/http'), 0o700);
let existing_secure = http_environment();
existing_secure.filesystem.set_mode('/tmp/miclash', 0o700);
existing_secure.filesystem.mkdir('/tmp/miclash/http');
existing_secure.filesystem.set_mode('/tmp/miclash/http', 0o700);
assert_equal(http.request(existing_secure.runtime, {
	url: 'https://subscriptions.example.test/config.yaml'
}).status, 200);

// Managed callers may explicitly inspect a bounded non-success status without
// changing the default fail-closed download contract.
let accepted_429 = http_environment({
	headers: 'HTTP/1.1 429 Too Many Requests\r\nRetry-After: 7\r\n\r\n',
	body: '{"ok":false,"error_code":429}'
});
let accepted_429_result = http.request(accepted_429.runtime, {
	url: 'https://api.telegram.org/bot123456:test/getUpdates',
	managed: true,
	accept_statuses: [ 429 ],
	max_redirects: 0,
	max_bytes: 65536
});
assert_equal(accepted_429_result.status, 429);
assert_equal(accepted_429_result.headers['retry-after'], '7');
let rejected_429 = http_environment({
	headers: 'HTTP/1.1 429 Too Many Requests\r\nRetry-After: 7\r\n\r\n',
	body: '{"ok":false,"error_code":429}'
});
assert_throws(() => http.request(rejected_429.runtime, {
	url: 'https://api.telegram.org/bot123456:test/getUpdates', managed: true
}), 'DOWNLOAD_FAILED');
assert_throws(() => http.request(http_environment().runtime, {
	url: 'https://api.telegram.org/bot123456:test/getUpdates',
	accept_statuses: [ 429 ]
}), 'INVALID_ARGUMENT');
assert_throws(() => http.request(http_environment().runtime, {
	url: 'https://api.telegram.org/bot123456:test/getUpdates', managed: true,
	accept_statuses: [ 500 ]
}), 'INVALID_ARGUMENT');

// Both the runtime parent and HTTP child are root-owned private authorities.
// Existing foreign directories, symlinks, ineffective chmod, and identity
// replacement during hardening all fail before curl is invoked.
let foreign_parent = http_environment();
foreign_parent.filesystem.set_uid('/tmp/miclash', 1000);
assert_throws(() => http.request(foreign_parent.runtime, {
	url: 'https://subscriptions.example.test/config.yaml'
}), 'INTERNAL');
assert_equal(length(foreign_parent.process.calls), 0);
let linked_parent = http_environment();
linked_parent.filesystem.set_symlink('/tmp/miclash', '/tmp');
assert_throws(() => http.request(linked_parent.runtime, {
	url: 'https://subscriptions.example.test/config.yaml'
}), 'INTERNAL');
assert_equal(length(linked_parent.process.calls), 0);
let foreign_child = http_environment();
foreign_child.filesystem.mkdir('/tmp/miclash/http');
foreign_child.filesystem.set_uid('/tmp/miclash/http', 1000);
assert_throws(() => http.request(foreign_child.runtime, {
	url: 'https://subscriptions.example.test/config.yaml'
}), 'INTERNAL');
assert_equal(length(foreign_child.process.calls), 0);
let linked_child = http_environment();
linked_child.filesystem.set_symlink('/tmp/miclash/http', '/tmp');
assert_throws(() => http.request(linked_child.runtime, {
	url: 'https://subscriptions.example.test/config.yaml'
}), 'INTERNAL');
assert_equal(length(linked_child.process.calls), 0);
let unfixable_child = http_environment();
unfixable_child.filesystem.set_mode('/tmp/miclash', 0o700);
unfixable_child.filesystem.mkdir('/tmp/miclash/http');
unfixable_child.filesystem.ignore_chmod = true;
assert_throws(() => http.request(unfixable_child.runtime, {
	url: 'https://subscriptions.example.test/config.yaml'
}), 'INTERNAL');
assert_equal(length(unfixable_child.process.calls), 0);
let replaced_child = http_environment();
replaced_child.filesystem.set_mode('/tmp/miclash', 0o700);
replaced_child.filesystem.mkdir('/tmp/miclash/http');
replaced_child.filesystem.on_lstat = (path, count) => {
	if (path == '/tmp/miclash/http' && count == 2)
		replaced_child.filesystem.bump_inode(path);
};
assert_throws(() => http.request(replaced_child.runtime, {
	url: 'https://subscriptions.example.test/config.yaml'
}), 'INTERNAL');
assert_equal(length(replaced_child.process.calls), 0);
let replaced_candidate_create = http_environment();
replaced_candidate_create.filesystem.set_mode('/tmp/miclash', 0o700);
replaced_candidate_create.filesystem.on_lstat = (path, count) => {
	if (match(path, /-body$/) && count == 1)
		replaced_candidate_create.filesystem.bump_inode(path);
};
assert_throws(() => http.request(replaced_candidate_create.runtime, {
	url: 'https://subscriptions.example.test/config.yaml'
}), 'INTERNAL');
assert_equal(length(replaced_candidate_create.process.calls), 0);

// A replacement after the final pre-curl verification is detected immediately
// after the adapter returns, before any response bytes are trusted.
let replaced_during_curl = http_environment();
replaced_during_curl.filesystem.set_mode('/tmp/miclash', 0o700);
replaced_during_curl.process.on_run = (request) => {
	let paths = curl_config_paths(replaced_during_curl.filesystem, request.args);
	replaced_during_curl.filesystem.writefile(paths.header_path,
		'HTTP/1.1 200 OK\r\n\r\n');
	replaced_during_curl.filesystem.writefile(paths.output_path, 'proxies: []\n');
	replaced_during_curl.filesystem.bump_inode('/tmp/miclash/http');
};
assert_throws(() => http.request(replaced_during_curl.runtime, {
	url: 'https://subscriptions.example.test/config.yaml'
}), 'INTERNAL');
let candidate_during_curl = http_environment();
candidate_during_curl.filesystem.set_mode('/tmp/miclash', 0o700);
candidate_during_curl.filesystem.writefile('/tmp/foreign-curl-target', 'foreign');
candidate_during_curl.process.on_run = (request) => {
	let paths = curl_config_paths(candidate_during_curl.filesystem, request.args);
	candidate_during_curl.filesystem.writefile(paths.header_path,
		'HTTP/1.1 200 OK\r\n\r\n');
	candidate_during_curl.filesystem.writefile(paths.output_path, 'proxies: []\n');
	candidate_during_curl.filesystem.set_symlink(paths.output_path,
		'/tmp/foreign-curl-target');
};
assert_throws(() => http.request(candidate_during_curl.runtime, {
	url: 'https://subscriptions.example.test/config.yaml'
}), 'INTERNAL');
assert_equal(candidate_during_curl.filesystem.readfile('/tmp/foreign-curl-target'), 'foreign');

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
assert_true(index(curl_config_paths(redirect.filesystem,
	redirect.process.calls[0].args).config, 'proto-redir = "=https"') >= 0);
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

// Managed GitHub transport failures retry once through the fixed proxy while
// preserving the official URL as the response authority. Arbitrary downloads,
// non-GitHub managed endpoints, and non-transport curl failures never retry.
function fallback_environment(first_code) {
	let environment = http_environment(), configs = [];
	environment.process.run = (request) => {
		push(environment.process.calls, request);
		let paths = curl_config_paths(environment.filesystem, request.args);
		push(configs, environment.filesystem.readfile(paths.config_path));
		if (length(configs) == 1)
			return { code: first_code, stdout: null, stderr: null };
		environment.filesystem.writefile(paths.header_path, 'HTTP/1.1 200 OK\r\n\r\n');
		environment.filesystem.writefile(paths.output_path, 'proxied-body');
		return { code: 0, stdout: null, stderr: null };
	};
	return { ...environment, configs };
};

let github_timeout = fallback_environment(28);
let github_url = 'https://github.com/ang3el7z/luci-app-miclash/releases/download/v2.0.2/luci-app-miclash-2.0.2.apk';
let github_result = http.request(github_timeout.runtime, {
	url: github_url, managed: true, max_bytes: 1024
});
assert_equal(length(github_timeout.process.calls), 2,
	'managed GitHub timeout uses one proxy fallback');
assert_true(index(github_timeout.configs[1],
	'url = "https://gh-proxy.com/' + github_url + '"') >= 0,
	'fallback curl config uses the fixed proxy transport URL');
assert_equal(github_result.url, github_url,
	'fallback response keeps the official GitHub authority');
assert_equal(github_result.body, 'proxied-body');

let unmanaged_github = fallback_environment(28);
assert_throws(() => http.request(unmanaged_github.runtime, { url: github_url }),
	'DOWNLOAD_FAILED');
assert_equal(length(unmanaged_github.process.calls), 1,
	'unmanaged GitHub request never uses the update fallback');

let foreign_managed = fallback_environment(28);
assert_throws(() => http.request(foreign_managed.runtime, {
	url: 'https://downloads.example.test/package.apk', managed: true
}), 'DOWNLOAD_FAILED');
assert_equal(length(foreign_managed.process.calls), 1,
	'non-GitHub managed request is not rewritten');

let github_http_error = fallback_environment(22);
assert_throws(() => http.request(github_http_error.runtime, {
	url: github_url, managed: true
}), 'DOWNLOAD_FAILED');
assert_equal(length(github_http_error.process.calls), 1,
	'non-transport curl failure does not use the proxy');
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
	let settings_failures = 0, settings_fail_after_commit = false;
	let settings = {
		get: () => value,
		validate: (patch) => patch,
		set: (patch) => {
			push(calls.settings, patch);
			if (settings_failures > 0 && !settings_fail_after_commit) {
				settings_failures--; errors.fail('INTERNAL');
			}
			value = { ...value,
				core: { ...value.core, ...(patch.core ?? {}) },
				updates: { ...value.updates, ...(patch.updates ?? {}) }
			};
			if (settings_failures > 0) { settings_failures--; errors.fail('INTERNAL'); }
			return value;
		}
	};
	let config = { validation_result: { ok: true }, activation_result: {
		ok: true, activated: true, reload_ok: true
	} };
	config.validate_in_operation = (ctx, profile, content) => {
			push(calls.validate, { id: ctx.id, profile, content });
			return config.validation_result;
		};
	config.apply_in_operation = (ctx, profile, content, source, extra) => {
			push(calls.apply, { id: ctx.id, profile, content, source, extra });
		return config.activation_result;
	};
	config.apply_transaction_in_operation = (ctx, profile, content, source, extra, transaction) => {
	let prepared;
	try { prepared = transaction.prepare(); }
	catch (error) {
		try { transaction.rollback(prepared); } catch (rollback_error) {}
		return { ok: false, activated: false, reload_ok: false,
			error: errors.new(error?.code ?? error?.message ?? 'INTERNAL') };
	}
		push(calls.apply, { id: ctx.id, profile, content, source, extra, transactional: true });
		if (config.activation_result?.ok !== true) {
			transaction.rollback(prepared);
			return config.activation_result;
		}
		if (transaction.commit(prepared) !== true) {
			transaction.rollback(prepared);
			return { ok: false, activated: true, reload_ok: false, error: errors.new('INTERNAL') };
		}
		return config.activation_result;
	};
	let client = subscription.create({ runtime, operations: ops, config, settings,
		http: http_adapter });
	return { filesystem, clock, runtime, ops, calls, config, settings, client,
		fail_settings: () => { settings_failures++; settings_fail_after_commit = false; },
		fail_settings_after: () => { settings_failures++; settings_fail_after_commit = true; } };
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

let replacement_url = 'https://subscriptions.example.test/replacement.yaml';
let replacement = subscription_environment({
	[replacement_url]: { body: yaml }
});
let replacement_op = replacement.client.replace({
	profile: 'config.yaml', url: replacement_url
}, 'telegram');
let replacement_done = finish_subscription(replacement, replacement_op);
assert_equal(replacement_done.state, 'success', sprintf('replacement failed: %J', replacement_done));
assert_equal(length(replacement.calls.settings), 1,
	'successful Telegram replacement persists one canonical URL patch');
assert_equal(replacement.calls.settings[0].core.subscription_url_config_yaml,
	replacement_url);
assert_equal(replacement.settings.get().core.subscription_url_config_yaml, replacement_url);

let settings_failure = subscription_environment({ [replacement_url]: { body: yaml } });
settings_failure.fail_settings();
let settings_failure_op = settings_failure.client.replace({
	profile: 'config.yaml', url: replacement_url
}, 'telegram');
let settings_failure_record = finish_subscription(settings_failure, settings_failure_op);
assert_equal(settings_failure_record.error.code, 'INTERNAL');
assert_equal(length(settings_failure.calls.apply), 0,
	'config activated before durable replacement URL prepare succeeded');
assert_equal(settings_failure.settings.get().core.subscription_url_config_yaml, '');

let partial_settings_failure = subscription_environment({ [replacement_url]: { body: yaml } });
partial_settings_failure.fail_settings_after();
let partial_failure_op = partial_settings_failure.client.replace({
	profile: 'config.yaml', url: replacement_url
}, 'telegram');
assert_equal(finish_subscription(partial_settings_failure, partial_failure_op).error.code, 'INTERNAL');
assert_equal(length(partial_settings_failure.calls.apply), 0,
	'partially committed URL prepare proceeded into activation');
assert_equal(partial_settings_failure.settings.get().core.subscription_url_config_yaml, '',
	'partially committed URL prepare was not rolled back');
assert_equal(length(partial_settings_failure.calls.settings), 2);

let replacement_health = subscription_environment({ [replacement_url]: { body: yaml } });
replacement_health.config.activation_result = { ok: false, activated: true, reload_ok: false,
	error: errors.new('HEALTH_FAILED') };
let replacement_health_op = replacement_health.client.replace({
	profile: 'config.yaml', url: replacement_url
}, 'telegram');
assert_equal(finish_subscription(replacement_health, replacement_health_op).error.code,
	'HEALTH_FAILED');
assert_equal(replacement_health.settings.get().core.subscription_url_config_yaml,
	replacement_url, 'failed activation must retain the newly selected URL');
assert_equal(length(replacement_health.calls.settings), 1,
	'failed activation must not roll back the selected URL');

// Queue admission is not a rollback snapshot. An earlier serialized settings
// mutation may complete before this worker starts; a failed activation must
// restore that newer canonical value, never the stale admission-time value.
let queued_previous_url = 'https://subscriptions.example.test/newer-canonical.yaml';
let queued_replacement = subscription_environment({ [replacement_url]: { body: yaml } });
queued_replacement.config.activation_result = { ok: false, activated: true, reload_ok: false,
	error: errors.new('HEALTH_FAILED') };
let queued_replacement_op = queued_replacement.client.replace({
	profile: 'config.yaml', url: replacement_url
}, 'telegram');
queued_replacement.settings.set({ core: {
	subscription_url_config_yaml: queued_previous_url
} });
assert_equal(finish_subscription(queued_replacement, queued_replacement_op).error.code,
	'HEALTH_FAILED');
assert_equal(queued_replacement.settings.get().core.subscription_url_config_yaml,
	replacement_url, 'worker must persist the user-selected replacement URL');

// Admission metadata may be stale for a dynamically resolved saved URL. The
// immutable worker result records the actual transport that was downloaded.
let admission_https = 'https://subscriptions.example.test/admission.yaml';
let worker_http = 'http://subscriptions.example.test/worker.yaml';
let dynamic_settings = {
	core: {
		proxy_mode: 'tproxy', tun_stack: 'system', hwid_enabled: false,
		hwid_user_agent: 'MiClash', hwid_device_os: 'OpenWrt', subscription_url: '',
		subscription_url_config_yaml: admission_https,
		subscription_url_config2_yaml: '', subscription_url_config3_yaml: ''
	}, updates: { interval_hours: 4 }
};
let dynamic_transport = subscription_environment({
	[admission_https]: { body: yaml }, [worker_http]: { body: yaml }
}, dynamic_settings);
let dynamic_op = dynamic_transport.client.update({
	profile: 'config.yaml', url: null
}, 'auto');
dynamic_transport.settings.set({ core: { subscription_url_config_yaml: worker_http } });
let dynamic_done = finish_subscription(dynamic_transport, dynamic_op);
assert_equal(dynamic_done.state, 'success');
assert_equal(dynamic_transport.calls.http[0].url, worker_http);
assert_equal(dynamic_done.result.insecure, true,
	'worker result did not record the actual insecure transport');
let failed_replacement = subscription_environment({
	[replacement_url]: 'DOWNLOAD_FAILED'
});
let failed_replacement_op = failed_replacement.client.replace({
	profile: 'config.yaml', url: replacement_url
}, 'telegram');
assert_equal(finish_subscription(failed_replacement, failed_replacement_op).error.code,
	'DOWNLOAD_FAILED');
assert_equal(length(failed_replacement.calls.settings), 1,
	'accepted replacement URL must be saved before download');
assert_equal(failed_replacement.settings.get().core.subscription_url_config_yaml,
	replacement_url, 'failed download must retain the selected URL for retry');
assert_equal(direct_sub.calls.apply[0].extra.validation_result, 'success');
assert_equal(direct_sub.ops.get(updated.id).result.interval_hours, 12);
assert_true(index(sprintf('%J', direct_sub.ops.get(updated.id)),
	'subscriptions.example.test') < 0);
let scheduled_hook = 0;
let scheduled_update = direct_sub.client.update_scheduled({ profile: 'config.yaml',
	url: 'https://subscriptions.example.test/config.yaml' }, 'auto', (record) => {
	scheduled_hook++;
	assert_equal(record.state, 'queued');
});
assert_equal(scheduled_hook, 1);
assert_equal(finish_subscription(direct_sub, scheduled_update).state, 'success');
assert_equal(direct_sub.ops.get(scheduled_update.id).result.interval_hours, 12);

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
	ok: false, activated: true, reload_ok: false,
	error: errors.new('HEALTH_FAILED', 'HEALTH_FAILED', { profile: 'config.yaml' })
};
let activation_op = activation.client.update({ profile: 'config.yaml',
	url: 'https://subscriptions.example.test/health-fail' }, 'auto');
assert_equal(finish_subscription(activation, activation_op).error.code, 'HEALTH_FAILED');
assert_equal(length(activation.ops.list()), 1);
assert_equal(activation.ops.get(activation_op.id).result.interval_hours, null);
assert_equal(activation.ops.get(activation_op.id).stage, 'reload');

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
