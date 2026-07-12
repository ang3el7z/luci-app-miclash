import { assert_equal, assert_throws, assert_true } from './testlib.uc';
import * as runtime from 'miclash.runtime';
import * as service from 'miclash.service';
import * as mihomo_api from 'miclash.mihomo-api';
import * as fakes from './fakes.uc';

const SECRET = 'never-publish-this-secret';

function make_ubus(running) {
	let fake = { calls: [], running: running ?? false };
	fake.connect = () => ({
		call: (object, method, data) => {
			push(fake.calls, { object, method, data });
			if (object != 'service')
				return null;
			if (method == 'list')
				return fake.running ? {
					clash: { instances: { main: { running: true, pid: 42 } } }
				} : { clash: { instances: {} } };
			if (method == 'start' || method == 'restart')
				fake.running = true;
			if (method == 'stop')
				fake.running = false;
			return {};
		}
	});
	return fake;
};

function make_http(replies) {
	let fake = { calls: [], replies: replies ?? {} };
	fake.request = (request) => {
		push(fake.calls, request);
		return fake.replies[request.method + ':' + request.path] ?? {
			status: 200, body: '{}'
		};
	};
	return fake;
};

function env(options) {
	options ??= {};
	let files = {
		'/opt/clash/bin/clash': 'binary',
		'/usr/libexec/miclash/mihomo-https.uc': 'helper',
		'/opt/clash/config.yaml':
			'external-controller: 127.0.0.1:9090\nsecret: "' + SECRET + '"\n'
	};
	for (let path, content in options.files ?? {})
		files[path] = content;
	let filesystem = fakes.fs(files);
	let ubus = options.ubus ?? make_ubus(options.running);
	let http = options.http ?? make_http(options.replies);
	let clock = options.clock ?? fakes.clock(1000);
	let observers = options.observers ?? {
		dns: () => ({ ready: true }),
		tun: () => ({ ready: true }),
		policy: () => ({ ready: true }),
		forward: () => ({ ready: true })
	};
	let rt = runtime.create({
		fs: filesystem,
		process: options.process ?? fakes.process(),
		ubus,
		http,
		clock,
		observers,
		service_options: { poll_interval_ms: 10 }
	});
	return { rt, filesystem, ubus, http, clock, observers };
};

// Strict controller/profile/path/method parsing and safe authenticated requests.
let api_env = env({ replies: { 'GET:/version': { status: 200, body: '{"version":"1.2.3"}' } } });
let version = mihomo_api.request(api_env.rt, 'GET', '/version', null, 'config.yaml');
assert_equal(version.ok, true);
assert_equal(version.status, 200);
assert_equal(version.data.version, '1.2.3');
assert_equal(api_env.http.calls[0].host, '127.0.0.1');
assert_equal(api_env.http.calls[0].port, 9090);
assert_equal(api_env.http.calls[0].headers.Authorization, 'Bearer ' + SECRET);
assert_equal(index(sprintf('%J', version), SECRET), -1);
assert_throws(() => mihomo_api.request(api_env.rt, 'DELETE', '/version'), 'INVALID_ARGUMENT');
assert_throws(() => mihomo_api.request(api_env.rt, 'GET', '//version'), 'INVALID_ARGUMENT');
assert_throws(() => mihomo_api.request(api_env.rt, 'GET', '/version/../configs'), 'INVALID_ARGUMENT');
assert_throws(() => mihomo_api.request(api_env.rt, 'GET', '/not-allowed'), 'INVALID_ARGUMENT');
assert_throws(() => mihomo_api.request(api_env.rt, 'GET', '/version', null, '../config.yaml'), 'INVALID_ARGUMENT');

for (let controller in [
	'0.0.0.0:9090', '[::]:9090', '192.168.1.1:9090', '127.0.0.1:0',
	'127.0.0.1:65536', 'user@127.0.0.1:9090', '127.0.0.1:9090/path'
]) {
	let hostile = env({ files: {
		'/opt/clash/config.yaml': 'external-controller: ' + controller + '\nsecret: safe\n'
	} });
	assert_throws(() => mihomo_api.request(hostile.rt, 'GET', '/version'), 'INVALID_ARGUMENT');
};

for (let controller in [ 'localhost:9090', '[::1]:9090' ]) {
	let loopback = env({ files: {
		'/opt/clash/config.yaml': 'external-controller: ' + controller + '\nsecret: safe\n'
	} });
	assert_equal(mihomo_api.request(loopback.rt, 'GET', '/version').ok, true);
};

let ambiguous = env({ files: {
	'/opt/clash/config.yaml':
		'external-controller: 127.0.0.1:9090\nexternal-controller-tls: 127.0.0.1:9443\nsecret: safe\n'
} });
assert_throws(() => mihomo_api.request(ambiguous.rt, 'GET', '/version'), 'INVALID_ARGUMENT');
let oversized_body = '';
for (let i = 0; i < 17; i++) oversized_body += sprintf('%4096s', 'x');
let https_env = env({ files: {
	'/opt/clash/config.yaml': 'external-controller-tls: 127.0.0.1:9443\nsecret: ' + SECRET + '\n'
} });
https_env.rt.process.on_run = (request) => {
	assert_equal(request.command, '/usr/bin/ucode');
	assert_equal(request.args[0], '--');
	assert_equal(request.args[1], '/usr/libexec/miclash/mihomo-https.uc');
	assert_equal(index(sprintf('%J', request), SECRET), -1);
	for (let path in https_env.filesystem.files) {
		if (match(path, /\.status$/))
			https_env.filesystem.files[path] = '200';
		if (match(path, /\.response$/))
			https_env.filesystem.files[path] = '{"version":"tls"}';
	}
};
let https_result = mihomo_api.request(https_env.rt, 'GET', '/version');
assert_equal(https_result.data.version, 'tls');
assert_equal(index(sprintf('%J', https_result), SECRET), -1);
assert_equal(length(https_env.http.calls), 0);
for (let path in https_env.filesystem.files)
	assert_equal(index(path, '/tmp/miclash/curl-'), -1);

let https_oversize = env({ files: {
	'/opt/clash/config.yaml': 'external-controller-tls: 127.0.0.1:9443\nsecret: ' + SECRET + '\n'
} });
https_oversize.rt.process.on_run = (request) => {
	for (let path in https_oversize.filesystem.files) {
		if (match(path, /\.status$/))
			https_oversize.filesystem.files[path] = '200';
		if (match(path, /\.response$/))
			https_oversize.filesystem.files[path] = oversized_body;
	}
};
assert_throws(() => mihomo_api.request(https_oversize.rt, 'GET', '/version'), 'RESPONSE_TOO_LARGE');
for (let path in https_oversize.filesystem.files)
	assert_equal(index(path, '/tmp/miclash/curl-'), -1);

let https_missing_helper = env({ files: {
	'/opt/clash/config.yaml': 'external-controller-tls: 127.0.0.1:9443\nsecret: ' + SECRET + '\n',
	'/usr/libexec/miclash/mihomo-https.uc': null
} });
https_missing_helper.filesystem.unlink('/usr/libexec/miclash/mihomo-https.uc');
assert_throws(() => mihomo_api.request(https_missing_helper.rt, 'GET', '/version'), 'INTERNAL');
assert_equal(length(https_missing_helper.rt.process.calls), 0);

let oversized = env({ replies: { 'GET:/version': { status: 200, body: oversized_body } } });
assert_throws(() => mihomo_api.request(oversized.rt, 'GET', '/version'), 'RESPONSE_TOO_LARGE');
let corrupt = env({ replies: { 'GET:/version': { status: 200, body: '{bad' } } });
assert_throws(() => mihomo_api.request(corrupt.rt, 'GET', '/version'), 'INVALID_RESPONSE');
let deep = '[';
for (let i = 0; i < 20; i++) deep += '[';
for (let i = 0; i < 21; i++) deep += ']';
let too_deep = env({ replies: { 'GET:/version': { status: 200, body: deep } } });
assert_throws(() => mihomo_api.request(too_deep.rt, 'GET', '/version'), 'INVALID_RESPONSE');

// Observation and lifecycle are idempotent and only use procd's ubus service methods.
let missing = env();
missing.filesystem.unlink('/opt/clash/bin/clash');
let missing_service = service.create(missing.rt);
assert_equal(missing_service.observe('config.yaml').state, 'missing_kernel');
assert_throws(() => missing_service.start('config.yaml'), 'NOT_FOUND');

let stopped = env();
let adapter = service.create(stopped.rt);
assert_equal(adapter.observe('config.yaml').state, 'stopped');
assert_equal(adapter.start('config.yaml').changed, true);
assert_equal(stopped.ubus.calls[length(stopped.ubus.calls) - 1].method, 'start');
assert_equal(adapter.start('config.yaml').changed, false);
assert_equal(stopped.ubus.calls[2].data.name, 'clash');
assert_equal(adapter.stop('config.yaml').changed, true);
assert_equal(adapter.stop('config.yaml').changed, false);
for (let call in stopped.ubus.calls)
	assert_equal(call.object, 'service');

let actions = env({ running: true });
let actions_service = service.create(actions.rt);
assert_equal(actions_service.reload('config.yaml').ok, true);
assert_equal(actions.http.calls[0].method, 'PUT');
assert_equal(actions.http.calls[0].path, '/configs?force=true');
assert_equal(actions.http.calls[0].body.path, '/opt/clash/config.yaml');
assert_equal(actions_service.restart_core('config.yaml').ok, true);
assert_equal(actions.http.calls[1].method, 'POST');
assert_equal(actions.http.calls[1].path, '/restart');
assert_equal(actions_service.restart_service('config.yaml').changed, true);
assert_equal(actions.ubus.calls[length(actions.ubus.calls) - 1].method, 'restart');
assert_throws(() => actions_service.reload('config4.yaml'), 'INVALID_ARGUMENT');

// Readiness observes in deterministic order and never repairs.
let order = [];
let ready_env = env({
	observers: {
		dns: () => { push(order, 'dns'); return { ready: true }; },
		tun: () => { push(order, 'tun'); return { ready: true }; },
		policy: () => { push(order, 'policy'); return { ready: true }; },
		forward: () => { push(order, 'forward'); return { ready: true }; }
	},
	running: true,
	replies: { 'GET:/version': { status: 200, body: '{"version":"1"}' } }
});
let ready = service.create(ready_env.rt).wait_ready(1100, 'config.yaml', { tun_required: true });
assert_equal(ready.ok, true);
assert_equal(join(',', map(ready.components, (item) => item.component)),
	'process,api,dns,tun,policy,forward');
assert_equal(join(',', order), 'dns,tun,policy,forward');

let no_tun = service.create(ready_env.rt).wait_ready(1100, 'config.yaml', { tun_required: false });
assert_equal(join(',', map(no_tun.components, (item) => item.component)),
	'process,api,dns,policy,forward');

let missing_observer = env({ running: true, observers: {
		dns: () => ({ ready: true }), tun: () => ({ ready: true }),
		policy: () => ({ ready: true })
} });
let unknown = service.create(missing_observer.rt).wait_ready(1020, 'config.yaml');
assert_equal(unknown.ok, false);
assert_equal(unknown.components[length(unknown.components) - 1].state, 'unknown');

let timeout_clock = fakes.clock(0);
let timeout_env = env({ running: false, clock: timeout_clock });
let timed = service.create(timeout_env.rt).wait_ready(25, 'config.yaml');
assert_equal(timed.ok, false);
assert_equal(timed.timed_out, true);
assert_true(timeout_clock.now() >= 25);
assert_true(timeout_clock.now() < 40);

// Stop readiness only verifies process absence; it never requires API/network observers.
let stop_env = env({ running: false, observers: {} });
let stopped_ready = service.create(stop_env.rt).wait_ready(1020, 'config.yaml', { stopped: true });
assert_equal(stopped_ready.ok, true);
assert_equal(length(stopped_ready.components), 1);
assert_equal(stopped_ready.components[0].component, 'process');
assert_equal(stopped_ready.components[0].state, 'stopped');

// Task 6 compatibility: config expects reload(profile) + health(profile).
assert_equal(type(actions_service.health), 'function');
