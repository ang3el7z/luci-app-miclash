import { assert_equal, assert_throws, assert_true } from './testlib.uc';
import * as runtime from 'miclash.runtime';
import * as service from 'miclash.service';
import * as mihomo_api from 'miclash.mihomo-api';
import * as fakes from './fakes.uc';

const SECRET = 'never-publish-this-secret';

function make_ubus(running) {
	let fake = { calls: [], running: running ?? false, list_error: false };
	fake.connect = () => ({
		call: (object, method, data) => {
			push(fake.calls, { object, method, data });
			if (object != 'service')
				return null;
			if (method == 'list') {
				if (fake.list_error)
					die('ubus failed');
				return fake.running ? {
					clash: { instances: { main: { running: true, pid: 42 } } }
				} : { clash: { instances: {} } };
			}
			if (method == 'state') {
				fake.running = data.spawn;
				return null;
			}
			die('unexpected ubus method');
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
		dataplane: () => ({ ready: true }),
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
		random: options.random ?? fakes.entropy(),
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

// DNS diagnostics use Mihomo's controller without widening the generic path allowlist.
let dns_env = env({ replies: {
	'GET:/dns/query?name=domain.example.test&type=A': {
		status: 200,
		body: '{"Status":0,"Answer":[{"name":"domain.example.test.","type":1,"TTL":60,"data":"198.51.100.10"}]}'
	}
} });
let dns_reply = mihomo_api.dns_query(dns_env.rt, 'domain.example.test', 'A',
	'config.yaml');
assert_equal(dns_reply.ok, true);
assert_equal(dns_reply.data.Answer[0].data, '198.51.100.10');
assert_equal(dns_env.http.calls[0].path,
	'/dns/query?name=domain.example.test&type=A');
assert_throws(() => mihomo_api.dns_query(dns_env.rt, 'bad host name', 'A'),
	'INVALID_ARGUMENT');
assert_throws(() => mihomo_api.dns_query(dns_env.rt, 'domain.example.test', 'TXT'),
	'INVALID_ARGUMENT');
assert_throws(() => mihomo_api.request(dns_env.rt, 'GET',
	'/dns/query?name=domain.example.test&type=A'), 'INVALID_ARGUMENT');
assert_throws(() => mihomo_api.request(api_env.rt, 'DELETE', '/version'), 'INVALID_ARGUMENT');
assert_throws(() => mihomo_api.request(api_env.rt, 'GET', '//version'), 'INVALID_ARGUMENT');
assert_throws(() => mihomo_api.request(api_env.rt, 'GET', '/version/../configs'), 'INVALID_ARGUMENT');
assert_throws(() => mihomo_api.request(api_env.rt, 'GET', '/not-allowed'), 'INVALID_ARGUMENT');
assert_throws(() => mihomo_api.request(api_env.rt, 'GET', '/version', null, '../config.yaml'), 'INVALID_ARGUMENT');

for (let controller in [
	'192.168.1.1:9090', '127.0.0.1:0',
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

for (let controller in [ '0.0.0.0:9090', '[::]:9090' ]) {
	let wildcard = env({ files: {
		'/opt/clash/config.yaml': 'external-controller: ' + controller + '\nsecret: safe\n'
	} });
	assert_equal(mihomo_api.request(wildcard.rt, 'GET', '/version').ok, true);
	assert_equal(wildcard.http.calls[0].host,
		controller == '0.0.0.0:9090' ? '127.0.0.1' : '::1');
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
	for (let path in https_env.filesystem.files)
		if (match(path, /\.config$/))
			assert_equal(index(https_env.filesystem.files[path], 'data-binary'), -1);
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

for (let slot = 0; slot < 4; slot++) {
	let suffix = [ '.config', '.request', '.status', '.response' ][slot];
	let collision_path = '/tmp/miclash/curl-0000000000000001' + suffix;
	let collision = env({
		files: {
			'/opt/clash/config.yaml': 'external-controller-tls: 127.0.0.1:9443\nsecret: safe\n',
			[collision_path]: 'foreign'
		}
	});
	assert_throws(() => mihomo_api.request(collision.rt, 'GET', '/version'), 'INTERNAL');
	assert_equal(collision.filesystem.files[collision_path], 'foreign');
	let remaining_temps = [];
	for (let path in collision.filesystem.files)
		if (index(path, '/tmp/miclash/curl-') == 0) push(remaining_temps, path);
	assert_equal(length(remaining_temps), 1);
	assert_equal(remaining_temps[0], collision_path);
};

let replaced = env({ files: {
	'/opt/clash/config.yaml': 'external-controller-tls: 127.0.0.1:9443\nsecret: safe\n'
} });
replaced.rt.process.on_run = (request) => {
	for (let path in replaced.filesystem.files) {
		if (match(path, /\.status$/)) replaced.filesystem.files[path] = '200';
		if (match(path, /\.response$/)) {
			replaced.filesystem.files[path] = 'foreign';
			replaced.filesystem.bump_inode(path);
		}
	}
};
assert_throws(() => mihomo_api.request(replaced.rt, 'GET', '/version'), 'INTERNAL');
let foreign_response = '/tmp/miclash/curl-0000000000000001.response';
assert_equal(replaced.filesystem.files[foreign_response], 'foreign');

let oversized = env({ replies: { 'GET:/version': { status: 200, body: oversized_body } } });
assert_throws(() => mihomo_api.request(oversized.rt, 'GET', '/version'), 'RESPONSE_TOO_LARGE');
let corrupt = env({ replies: { 'GET:/version': { status: 200, body: '{bad' } } });
assert_throws(() => mihomo_api.request(corrupt.rt, 'GET', '/version'), 'INVALID_RESPONSE');
let deep = '[';
for (let i = 0; i < 20; i++) deep += '[';
for (let i = 0; i < 21; i++) deep += ']';
let too_deep = env({ replies: { 'GET:/version': { status: 200, body: deep } } });
assert_throws(() => mihomo_api.request(too_deep.rt, 'GET', '/version'), 'INVALID_RESPONSE');

// Reload transports through the controller that was live before activation,
// while subsequent health probes parse the newly active TLS controller.
let transition = env({ running: true, files: {
	'/opt/clash/config.yaml':
		'external-controller-tls: 127.0.0.1:9443\nsecret: new-secret\n'
} });
let transition_service = service.create(transition.rt);
let prior_controller =
	'external-controller: 127.0.0.1:9191\nsecret: old-secret\n';
assert_equal(transition_service.reload('config.yaml', prior_controller).ok, true);
assert_equal(transition.http.calls[0].port, 9191);
assert_equal(transition.http.calls[0].headers.Authorization, 'Bearer old-secret');
transition.rt.process.on_run = (request) => {
	for (let path in transition.filesystem.files) {
		if (match(path, /\.config$/)) {
			assert_true(index(transition.filesystem.files[path], 'https://127.0.0.1:9443/version') >= 0);
			assert_true(index(transition.filesystem.files[path], 'Bearer new-secret') >= 0);
		}
		if (match(path, /\.status$/)) transition.filesystem.files[path] = '200';
		if (match(path, /\.response$/)) transition.filesystem.files[path] = '{}';
	}
};
assert_equal(transition_service.health('config.yaml'), true);
assert_throws(() => transition_service.reload('config.yaml', 42), 'INVALID_ARGUMENT');
let oversized_config = '';
for (let i = 0; i < 257; i++) oversized_config += sprintf('%4096s', 'x');
assert_throws(() => transition_service.reload('config.yaml', oversized_config), 'INVALID_ARGUMENT');

// Observation and lifecycle are idempotent and only use procd's ubus service methods.
let missing = env();
missing.filesystem.unlink('/opt/clash/bin/clash');
let missing_service = service.create(missing.rt);
assert_equal(missing_service.observe('config.yaml').state, 'missing_kernel');
assert_throws(() => missing_service.start('config.yaml'), 'NOT_FOUND');
assert_throws(() => missing_service.stop('config.yaml'), 'HEALTH_FAILED');

let stopped = env();
let adapter = service.create(stopped.rt);
assert_equal(adapter.observe('config.yaml').state, 'stopped');
assert_equal(adapter.start('config.yaml').changed, true);
assert_equal(stopped.ubus.calls[length(stopped.ubus.calls) - 1].method, 'state');
assert_equal(stopped.ubus.calls[length(stopped.ubus.calls) - 1].data.spawn, true);
assert_equal(adapter.start('config.yaml').changed, false);
assert_equal(stopped.ubus.calls[2].data.name, 'clash');
assert_equal(adapter.stop('config.yaml').changed, true);
assert_equal(stopped.ubus.calls[length(stopped.ubus.calls) - 1].method, 'state');
assert_equal(stopped.ubus.calls[length(stopped.ubus.calls) - 1].data.spawn, false);
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
let state_calls = [];
for (let call in actions.ubus.calls)
	if (call.method == 'state') push(state_calls, call);
assert_equal(length(state_calls), 2);
assert_equal(state_calls[0].data.spawn, false);
assert_equal(state_calls[1].data.spawn, true);
assert_throws(() => actions_service.reload('config4.yaml'), 'INVALID_ARGUMENT');

// Bounded recovery always attempts the least disruptive action first and
// stops as soon as full readiness is observed.
function recovery_http(outcomes) {
	let fake = { calls: [], outcomes: [ ...outcomes ] };
	fake.request = (request) => {
		push(fake.calls, request.method + ':' + request.path);
		let status = length(fake.outcomes) ? shift(fake.outcomes) : 200;
		return { status, body: request.path == '/version' ? '{"version":"1"}' : '{}' };
	};
	return fake;
};
let reload_http = recovery_http([ 200, 200 ]);
let reload_recovery = env({ running: true, http: reload_http });
let reload_result = service.create(reload_recovery.rt).recover('config.yaml');
assert_equal(reload_result.ok, true);
assert_equal(reload_result.stage, 'reload');
assert_equal(join(',', reload_http.calls), 'PUT:/configs?force=true,GET:/version');

let core_http = recovery_http([ 503, 200, 200 ]);
let core_recovery = env({ running: true, http: core_http });
let core_result = service.create(core_recovery.rt).recover('config.yaml');
assert_equal(core_result.ok, true);
assert_equal(core_result.stage, 'restart_core');
assert_equal(join(',', core_http.calls),
	'PUT:/configs?force=true,POST:/restart,GET:/version');

let service_http = recovery_http([ 503, 503, 200 ]);
let service_recovery = env({ running: true, http: service_http });
let service_result = service.create(service_recovery.rt).recover('config.yaml');
assert_equal(service_result.ok, true);
assert_equal(service_result.stage, 'restart_service');
assert_equal(join(',', service_http.calls),
	'PUT:/configs?force=true,POST:/restart,GET:/version');
let recovery_state_calls = filter(service_recovery.ubus.calls, (call) => call.method == 'state');
assert_equal(length(recovery_state_calls), 2);
assert_equal(recovery_state_calls[0].data.spawn, false);
assert_equal(recovery_state_calls[1].data.spawn, true);

let unknown_service_env = env();
unknown_service_env.ubus.list_error = true;
let unknown_service = service.create(unknown_service_env.rt);
assert_throws(() => unknown_service.start('config.yaml'), 'HEALTH_FAILED');
assert_throws(() => unknown_service.stop('config.yaml'), 'HEALTH_FAILED');
assert_equal(length(filter(unknown_service_env.ubus.calls, (call) => call.method == 'state')), 0);

let missing_running = env({ running: true });
missing_running.filesystem.unlink('/opt/clash/bin/clash');
let missing_running_service = service.create(missing_running.rt);
assert_equal(missing_running_service.observe('config.yaml').state, 'running');
assert_equal(missing_running_service.stop('config.yaml').changed, true);
assert_equal(missing_running.ubus.calls[length(missing_running.ubus.calls) - 1].data.spawn, false);

let restart_timeout = env({ running: true });
restart_timeout.ubus.connect = () => ({ call: (object, method, data) => {
	push(restart_timeout.ubus.calls, { object, method, data });
	if (method == 'list') return { clash: { instances: { main: { running: true, pid: 42 } } } };
	return null;
} });
assert_throws(() => service.create(restart_timeout.rt).restart_service('config.yaml'), 'HEALTH_FAILED');
assert_equal(length(filter(restart_timeout.ubus.calls,
	(call) => call.method == 'state' && call.data.spawn === true)), 0);

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

let incompatible_dataplane = env({ running: true, observers: {
	dataplane: () => ({ ready: false }), dns: () => ({ ready: true }),
	tun: () => ({ ready: true }), policy: () => ({ ready: true }),
	forward: () => ({ ready: true })
} });
let incompatible_ready = service.create(incompatible_dataplane.rt).wait_ready(
	1020, 'config.yaml', { proxy_mode: 'tproxy' });
assert_equal(incompatible_ready.ok, false);
let dataplane_component = filter(incompatible_ready.components,
	(item) => item.component == 'dataplane')[0];
assert_equal(dataplane_component.ready, false,
	'incompatible Mihomo listener contract was accepted as ready');

let missing_observer = env({ running: true, observers: {
	dns: () => ({ ready: true }), tun: () => ({ ready: true }),
	policy: () => ({ ready: true }), forward: null
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

let stop_unknown_env = env({ observers: {} });
stop_unknown_env.ubus.list_error = true;
let stop_unknown = service.create(stop_unknown_env.rt).wait_ready(1020, 'config.yaml', { stopped: true });
assert_equal(stop_unknown.ok, false);
assert_equal(stop_unknown.components[0].state, 'unknown');

let stop_missing_env = env({ observers: {} });
stop_missing_env.filesystem.unlink('/opt/clash/bin/clash');
let stop_missing = service.create(stop_missing_env.rt).wait_ready(1020, 'config.yaml', { stopped: true });
assert_equal(stop_missing.ok, false);
assert_equal(stop_missing.components[0].state, 'missing_kernel');

// Task 6 compatibility: config expects reload(profile) + health(profile).
assert_equal(type(actions_service.health), 'function');
