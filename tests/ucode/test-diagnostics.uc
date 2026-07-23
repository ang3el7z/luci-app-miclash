import { assert_equal, assert_match, assert_throws, assert_true } from 'testlib';
import * as diagnostics from 'miclash.diagnostics';
import * as operations from 'miclash.operations';
import * as route_test from 'miclash.route-test';
import * as fakes from 'fakes';

function fixture(name) {
	return json(require('fs').readfile('tests/fixtures/diagnostics/' + name));
};
function repeated(value, count) {
	let output = '';
	for (let index = 0; index < count; index++) output += value;
	return output;
};

function report_shape(value) {
	if (type(value) == 'array')
		return map(value, (item) => report_shape(item));
	if (type(value) == 'object') {
		let shape = {};
		for (let name in sort(keys(value)))
			shape[name] = report_shape(value[name]);
		return shape;
	}
	return type(value);
};
function percent_encoded(value) {
	let output = '';
	for (let offset = 0; offset < length(value); offset++) {
		let byte = ord(value, offset);
		let character = substr(value, offset, 1);
		output += match(character, /^[A-Za-z0-9_.~-]$/) ? character : sprintf('%%%02X', byte);
	}
	return output;
};
function full_percent_lower(value) {
	let output = '';
	for (let offset = 0; offset < length(value); offset++)
		output += lc(sprintf('%%%02X', ord(value, offset)));
	return output;
};
function urlsafe_unpadded_base64(value) {
	let output = replace(replace(b64enc(value), /\+/g, '-'), /\//g, '_');
	return replace(output, /=+$/, '');
};

let secrets = fixture('secret-corpus.json');
let config_private_key = 'diagnostic-private-key-must-never-leak';
let config_uuid = '00000000-1111-2222-3333-444444444444';
let filesystem = fakes.fs({});
for (let directory in [ '/tmp', '/tmp/miclash' ])
	if (filesystem.lstat(directory) == null)
		filesystem.mkdir(directory);
filesystem.chmod('/tmp/miclash', 0o700);

let runtime = {
	fs: filesystem,
	clock: fakes.clock(1700000000000),
	random: fakes.entropy(),
	digest: fakes.digest(filesystem),
	paths: { tmp: '/tmp/miclash' }
};
let report_source_calls = { config: 0, process: 0, logs: 0, uci: 0, operations: 0 };
function report_source(name, value) {
	report_source_calls[name]++;
	return value;
};
let sources = {
	versions: () => ({ miclash: 'v0.9.2', mihomo: 'v1.19.10' }),
	architecture: () => 'aarch64_cortex-a53',
	state: () => ({
		desired: {
			core: { subscription_url: secrets.subscription_url },
			telegram: { enabled: true, token: secrets.telegram_token }
		},
		observed: { service: { state: 'running', output:
			'mihomo says ' + secrets.telegram_token } }
	}),
	health: () => ({ mihomo: { state: 'ok', details: {
		header: 'Authorization: ' + secrets.authorization } } }),
	memory: () => ({ phase: 'monitoring', diagnostic:
		'password=' + secrets.password }),
	updates: () => ({ state: 'idle', url: secrets.subscription_url,
		automatic_miclash: { enabled: true, readiness: 'assets_pending',
			publication_retry_count: 1, response_body: secrets.password,
			package_url: secrets.subscription_url } }),
	settings: () => ({
		core: { subscription_url: secrets.subscription_url },
		telegram: { enabled: true, token: secrets.telegram_token, user_id: '42' }
	}),
	telegram: () => ({ running: true, enabled: true, configured: true,
		last_error: null, failures: 0, token: secrets.telegram_token }),
	network_components: () => ({ dns: { state: 'active' }, firewall: { state: 'active' },
		routing: { state: 'active' }, guard: { state: 'enabled' } }),
	last_repair: () => ({ result: 'success', context:
		'cookie=' + secrets.cookie }),
	config: () => report_source('config', 'secret: ' + secrets.api_key + '\n' +
		'private-key: ' + config_private_key + '\n' +
		'uuid: ' + config_uuid + '\nmode: rule\n'),
	process: () => report_source('process', { stdout: 'password=' + secrets.password,
		stderr: 'Bearer ' + secrets.authorization }),
	logs: () => report_source('logs', [
		'url=' + secrets.subscription_url,
		'token=' + secrets.telegram_token
	]),
	uci: () => report_source('uci', { telegram: { token: secrets.telegram_token },
		remote: { api_key: secrets.api_key } }),
	operations: () => report_source('operations', [ { id: 'safe-operation', context:
		'cookie=' + secrets.cookie + ' password=' + secrets.password } ]),
	evidence: () => [
		{ name: 'procd', value: {
			state: 'unavailable', code: 'COLLECTION_UNAVAILABLE',
			message: 'procd service status is unavailable' } },
		{ name: 'interfaces', value: {
			state: 'unavailable', code: 'COLLECTION_UNAVAILABLE',
			message: 'interface topology is unavailable' } },
		{ name: 'firewall', value: {
			state: 'unavailable', code: 'COLLECTION_UNAVAILABLE',
			message: 'Complete iptables fallback evidence is unavailable' } },
		{ name: 'logs', value: {
			state: 'unavailable', code: 'COLLECTION_UNAVAILABLE',
			message: 'logread collection unavailable' } }
	]
};

assert_equal(type(diagnostics.create), 'function');
assert_equal(type(route_test.create), 'function');
assert_throws(() => diagnostics.create({
	runtime: { ...runtime, digest: { sha256: runtime.digest.sha256 } }, sources
}), 'INVALID_ARGUMENT');
let center = diagnostics.create({ runtime, sources });
for (let method in [ 'summary', 'submit_report', 'open_report' ])
	assert_equal(type(center[method]), 'function', method + ' is exported');
for (let method in [ 'create_report', 'read_report' ])
	assert_true(center[method] == null, method + ' is not publicly reachable');

function assert_no_secrets(value, label) {
	let text = type(value) == 'string' ? value : sprintf('%J', value);
	for (let name, secret in secrets)
		assert_true(index(text, secret) < 0,
			(label ?? 'diagnostics') + ' leaked ' + name);
};

let summary = center.summary();
for (let name in report_source_calls)
	assert_equal(report_source_calls[name], 0,
		'summary must not collect report-only source ' + name);
assert_equal(summary.schema_version, 1);
assert_equal(summary.versions.miclash, 'v0.9.2');
assert_equal(summary.architecture, 'aarch64_cortex-a53');
assert_equal(summary.telegram.enabled, true);
assert_equal(summary.telegram.configured, true);
assert_equal(summary.telegram.running, true);
assert_equal(summary.telegram.last_error, null);
assert_equal(summary.telegram.failures, 0);
assert_equal(summary.components.dns.state, 'active');
assert_equal(summary.components.firewall.state, 'active');
assert_equal(summary.components.routing.state, 'active');
assert_equal(summary.components.guard.state, 'enabled');
assert_true(type(summary.state.desired) == 'object');
assert_true(type(summary.state.observed) == 'object');
assert_true(type(summary.health.mihomo) == 'object');
assert_equal(summary.memory.phase, 'monitoring');
assert_equal(summary.updates.state, 'idle');
assert_equal(summary.updates.automatic_miclash.enabled, true);
assert_equal(summary.updates.automatic_miclash.readiness, 'assets_pending');
assert_equal(summary.updates.automatic_miclash.publication_retry_count, 1);
assert_equal(summary.last_repair.result, 'success');
assert_no_secrets(summary, 'summary');

let status_sources = { ...sources,
	settings: () => ({
		core: { subscription_url: 'http://plain.example.invalid/config' },
		telegram: { enabled: true, token: '', user_id: '42' }
	})
};
let status_center = diagnostics.create({ runtime, sources: status_sources });
let status_summary = status_center.summary();
assert_equal(status_summary.telegram.enabled, true);
assert_equal(status_summary.telegram.configured, false);
assert_equal(status_summary.subscription.configured, true);
assert_equal(status_summary.subscription.transport, 'http');
assert_equal(status_summary.subscription.insecure, true);

let collision_sources = { ...sources,
	settings: () => ({ core: { subscription_url: '' }, telegram: {
		enabled: true, token: 'collision-secret', user_id: '42' } }),
	state: () => ({ desired: {
		'collision-secret': 'one',
		'[REDACTED]': 'two'
	}, observed: {} })
};
let collision_center_redaction = diagnostics.create({
	runtime, sources: collision_sources
});
assert_throws(() => collision_center_redaction.summary(), 'INVALID_RESPONSE');

let deep = { leaf: true };
for (let depth = 0; depth < 20; depth++) deep = { child: deep };
let deep_center = diagnostics.create({ runtime,
	sources: { ...sources, state: () => deep } });
assert_throws(() => deep_center.summary(), 'RESPONSE_TOO_LARGE');
let many = [];
for (let index = 0; index < 4200; index++) push(many, index);
let many_center = diagnostics.create({ runtime,
	sources: { ...sources, state: () => many } });
assert_throws(() => many_center.summary(), 'RESPONSE_TOO_LARGE');
let huge_filesystem = fakes.fs({});
for (let directory in [ '/tmp', '/tmp/miclash' ]) huge_filesystem.mkdir(directory);
huge_filesystem.chmod('/tmp/miclash', 0o700);
let huge_runtime = { ...runtime,
	fs: huge_filesystem,
	clock: fakes.clock(1700000000000),
	digest: fakes.digest(huge_filesystem) };
let huge_logs = [];
for (let index = 0; index < 1000; index++)
	push(huge_logs, sprintf('line-%04d %396s', index, 'x'));
let huge_center = diagnostics.create({ runtime: huge_runtime,
	sources: { ...sources,
		config: () => repeated('c', 70000),
		logs: () => join('\n', huge_logs),
		health: () => ({ observed: { readiness: { components: [
			{ component: 'process', state: 'ready' },
			{ component: 'dns', state: 'failed', code: 'HEALTH_FAILED',
				message: 'DNS probe failed' }
		] } } }),
		operations: () => [ { id: 'failed-operation', kind: 'subscription.update',
			state: 'failure', code: 'HEALTH_FAILED', message: 'Activation failed' } ],
		last_repair: () => ({ state: 'none' }) } });
assert_equal(huge_center.summary().schema_version, 1,
	'summary must not collect report-only logs');

// Route diagnostics derive bypass destinations from the active Mihomo config.
assert_equal(join(',', route_test.proxy_servers(
	'external-controller: 127.0.0.1:9090\n' +
	'proxies:\n' +
	'  - name: primary\n' +
	'    type: socks5\n' +
	'    server: proxy.example.test\n' +
	'  - name: duplicate\n' +
	'    server: "proxy.example.test"\n' +
	'  - name: ipv6\n' +
	"    server: '2001:db8::1'\n" +
	'proxy-groups:\n' +
	'  - name: ignored\n' +
	'    server: ignored.example.test\n')), 'proxy.example.test,2001:db8::1');
assert_equal(length(route_test.proxy_servers('rules:\n  - MATCH,DIRECT\n')), 0);
assert_equal(join(',', route_test.proxy_servers(
	'proxies:\n' +
	'- name: canonical\n' +
	'  type: socks5\n' +
	'  server: canonical.example.test\n')), 'canonical.example.test');
assert_equal(join(',', route_test.proxy_servers(
	'proxies:\n' +
	'  - { name: flow, type: socks5, server: flow.example.test, port: 443 }\n')),
	'flow.example.test');
assert_equal(join(',', route_test.proxy_servers(
	'proxies: # endpoint list\n' +
	'- name: commented\n' +
	'  server: commented.example.test\n')), 'commented.example.test');
assert_equal(join(',', route_test.proxy_servers(
	'proxies:\n' +
	'  - { name: flow, server: flow-comment.example.test } # endpoint\n')),
	'flow-comment.example.test');
assert_equal(join(',', route_test.proxy_servers(
	'proxies:\n' +
	'  - name: nested\n' +
	'    plugin-opts:\n' +
	'      server: nested.example.test\n' +
	'    server: endpoint.example.test\n')), 'endpoint.example.test');
assert_equal(join(',', route_test.proxy_servers(
	'proxy-defaults: &defaults\n' +
	'  type: ss\n' +
	'proxies:\n' +
	'  - name: inherited\n' +
	'    <<: *defaults\n' +
	'    server: merged.example.test\n')), 'merged.example.test',
	'valid YAML merge keys do not hide the proxy endpoint');
assert_throws(() => route_test.proxy_servers('proxies:\n  - server: bad host name\n'),
	'INVALID_ARGUMENT');
assert_throws(() => route_test.proxy_servers(repeated('x', 1048577)),
	'INVALID_ARGUMENT');

let route_scenarios = fixture('route-scenarios.json');
for (let scenario in route_scenarios) {
	let http_calls = [], process_calls = [];
	let route_runtime = {
		fs: filesystem,
		http: {
			request: (request) => {
				push(http_calls, request);
				if (scenario.rules == null)
					die('HEALTH_FAILED');
				let response_rules = scenario.rules;
				if (response_rules == 'oversized') {
					response_rules = [];
					for (let index = 0; index < 513; index++)
						push(response_rules, { type: 'DOMAIN', payload: 'miss-' + index + '.example',
							proxy: 'ProxyGroup' });
				}
				return { status: 200, body: sprintf('%J', { rules: response_rules }) };
			}
		},
		process: { run: (request) => {
			push(process_calls, request);
			die('unexpected process execution');
		} },
		paths: { tmp: '/tmp/miclash' },
		random: fakes.entropy()
	};
	let observed = { routing: {
		rules: [
			{ family: 'ipv4', priority: 1000, mark: '0x1',
				mask: '0xffffffff', table: 100, protocol: 242, owned: true },
			{ family: 'ipv6', priority: 1000, mark: '0x1',
				mask: '0xffffffff', table: 100, protocol: 242, owned: true }
		],
		routes: [
			{ family: 'ipv4', table: 100, kind: 'local',
				destination: 'default', device: 'lo', protocol: 242, owned: true },
			{ family: 'ipv6', table: 100, kind: 'local',
				destination: 'default', device: 'lo', protocol: 242, owned: true }
		],
		interfaces: { 'clash-tun': false },
		ownership: {
			trusted: true,
			status: 'trusted',
			committed: {
				rules: [
					{ family: 'ipv4', priority: 1000, mark: '0x1',
						mask: '0xffffffff', table: 100 },
					{ family: 'ipv6', priority: 1000, mark: '0x1',
						mask: '0xffffffff', table: 100 }
				],
				routes: [
					{ family: 'ipv4', table: 100, kind: 'local',
						destination: 'default', device: 'lo' },
					{ family: 'ipv6', table: 100, kind: 'local',
						destination: 'default', device: 'lo' }
				]
			},
			transition: null
		}
	} };
	if (scenario.routing == 'missing') {
		observed.routing.rules = [];
		observed.routing.routes = [];
	}
	else if (scenario.routing == 'contradictory')
		push(observed.routing.routes, { family: 'ipv4', table: 100,
			kind: 'unicast', destination: 'default', device: 'clash-tun' });
	else if (scenario.routing == 'malformed')
		observed.routing.rules[0].mark = 1;
	else if (scenario.routing == 'foreign-owned') {
		observed.routing.rules[0].owned = false;
		observed.routing.routes[0].owned = false;
	}
	else if (scenario.routing == 'foreign-protocol') {
		observed.routing.rules[0].protocol = 99;
		observed.routing.routes[0].protocol = 99;
	}
	else if (scenario.routing == 'missing-ownership')
		delete observed.routing.ownership;
	else if (scenario.routing == 'long-interface')
		observed.routing.routes[0].device = '1234567890123456';
	else if (scenario.routing == 'oversized')
		for (let index = 0; index < 65; index++)
			push(observed.routing.rules, { family: 'ipv4', priority: 2000 + index,
				mark: '0x2', mask: '0xffffffff', table: 200 + index });
	let desired = scenario.desired;
	if (scenario.desired_fault == 'devices-missing')
		delete desired.devices;
	else if (scenario.desired_fault == 'devices-oversized')
		for (let index = 0; index < 129; index++)
			push(desired.devices, { mac: sprintf('02:00:00:00:00:%02x', index), decision: 'DIRECT' });
	else if (scenario.desired_fault == 'devices-malformed')
		desired.devices = [ { mac: 'not-a-mac', decision: 'DIRECT' } ];
	else if (scenario.desired_fault == 'devices-decision')
		desired.devices = [ { mac: '02:00:00:00:00:01', decision: 'ALLOW' } ];
	else if (scenario.desired_fault == 'interfaces-missing')
		delete desired.interfaces;
	else if (scenario.desired_fault == 'interfaces-oversized')
		for (let index = 0; index < 129; index++)
			push(desired.interfaces, { name: 'if' + index, decision: 'DIRECT' });
	else if (scenario.desired_fault == 'interfaces-malformed')
		desired.interfaces = [ { name: '../wan', decision: 'DIRECT' } ];
	else if (scenario.desired_fault == 'interfaces-decision')
		desired.interfaces = [ { name: 'guest', decision: 'ALLOW' } ];
	else if (scenario.desired_fault == 'proxy-missing')
		delete desired.proxy_servers;
	else if (scenario.desired_fault == 'proxy-oversized')
		for (let index = 0; index < 129; index++)
			push(desired.proxy_servers, '198.18.0.' + index);
	else if (scenario.desired_fault == 'proxy-malformed')
		desired.proxy_servers = [ 'bad host name' ];
	let engine = route_test.create({
		runtime: route_runtime,
		profile: 'config.yaml',
		config_content: 'external-controller: 127.0.0.1:9090\n' +
			'secret: controller-secret-value\n',
		desired: () => desired,
		observed: () => observed,
		dns_answers: (target) => {
			if (scenario.dns == 'unavailable') die('DNS_UNAVAILABLE');
			if (scenario.dns == 'invalid') return [ 'not-an-address' ];
			if (scenario.dns == 'oversized') {
				let values = [];
				for (let index = 0; index < 17; index++) push(values, '192.0.2.' + index);
				return values;
			}
			return scenario.answers;
		}
	});
	assert_equal(type(engine.run), 'function');
	let result = engine.run(scenario.input);
	assert_equal(result.decision, scenario.expected, scenario.name);
	if (scenario.normalized != null)
		assert_equal(result.input.target, scenario.normalized,
			scenario.name + ' returns normalized target');
	assert_true(type(result.steps) == 'array' && length(result.steps) >= 6,
		scenario.name + ' returns ordered reasoning');
	let order = [];
	for (let step in result.steps) {
		assert_true(type(step.source) == 'string');
		assert_true(type(step.evidence) == 'object');
		assert_true(type(step.decision) == 'string');
		push(order, step.source);
	}
	assert_equal(order[0], 'input');
	assert_true(index(order, 'dns') >= 0);
	assert_true(index(order, 'device_policy') >= 0);
	assert_true(index(order, 'interface_policy') >= 0);
	assert_true(index(order, 'proxy_server_bypass') >= 0);
	assert_true(index(order, 'mihomo_rule') >= 0);
	assert_true(index(order, 'routing') >= 0);
	assert_equal(order[length(order) - 1], 'guard');
	let routing_step = result.steps[index(order, 'routing')];
	assert_equal(type(routing_step.evidence.available), 'bool');
	assert_equal(type(routing_step.evidence.valid), 'bool');
	let route_expected = scenario.routing != 'missing' && scenario.routing != 'contradictory' &&
		scenario.routing != 'malformed' && scenario.routing != 'foreign-owned' &&
		scenario.routing != 'foreign-protocol' && scenario.routing != 'missing-ownership' &&
		scenario.routing != 'long-interface' &&
		scenario.routing != 'oversized' &&
		(length(scenario.answers) > 0 || match(scenario.input.target, /:|^[0-9.]+$/));
	if (!route_expected)
		assert_equal(routing_step.evidence.valid, false);
	else
		assert_equal(routing_step.evidence.valid, true);
	if (scenario.routing_code != null)
		assert_equal(routing_step.evidence.code, scenario.routing_code, scenario.name);
	let dns_step = result.steps[index(order, 'dns')];
	if (scenario.dns != null) {
		assert_equal(dns_step.evidence.available, false,
			scenario.name + ' marks DNS unavailable');
		assert_equal(dns_step.evidence.cached, false,
			scenario.name + ' does not claim cached evidence');
		assert_equal(length(dns_step.evidence.answers), 0);
	}
	let guard_step = result.steps[index(order, 'guard')];
	if (scenario.guard_unknown === true) {
		assert_equal(guard_step.evidence.known, false,
			scenario.name + ' reports unknown Guard state');
		assert_equal(guard_step.evidence.state, 'unknown');
	}
	for (let source in [ 'device_policy', 'interface_policy', 'proxy_server_bypass' ]) {
		let evidence = result.steps[index(order, source)].evidence;
		assert_equal(type(evidence.available), 'bool', source + ' availability evidence');
		assert_equal(type(evidence.valid), 'bool', source + ' validity evidence');
		assert_equal(type(evidence.code), 'string', source + ' status code');
	}
	if (scenario.desired_fault == null) {
		for (let field, source in { devices: 'device_policy', interfaces: 'interface_policy',
			proxy_servers: 'proxy_server_bypass' })
			if (type(desired[field]) == 'array' && !length(desired[field])) {
				let evidence = result.steps[index(order, source)].evidence;
				assert_equal(evidence.available, true, source + ' empty collection is available');
				assert_equal(evidence.valid, true, source + ' empty collection is valid');
				assert_equal(evidence.code, 'EMPTY', source + ' empty collection is explicit');
			}
	}
	if (scenario.policy_evidence != null) {
		let expected = scenario.policy_evidence;
		let policy_step = result.steps[index(order, expected.source)];
		assert_equal(policy_step.evidence.available, expected.available, scenario.name);
		assert_equal(policy_step.evidence.valid, expected.valid, scenario.name);
		assert_equal(policy_step.evidence.code, expected.code, scenario.name);
	}
	assert_no_secrets(result, scenario.name);
	assert_equal(length(process_calls), 0,
		scenario.name + ' never emits probe/process traffic');
	if (scenario.rules == null)
		assert_equal(length(http_calls), 1);
	else {
		assert_equal(length(http_calls), 1);
		assert_equal(http_calls[0].host, '127.0.0.1');
		assert_equal(http_calls[0].port, 9090);
		assert_equal(http_calls[0].method, 'GET');
		assert_equal(http_calls[0].path, '/rules');
	}
}

let invalid_route = route_test.create({
	runtime: { fs: filesystem, http: { request: () => die('unexpected') },
		process: { run: () => die('unexpected') }, paths: { tmp: '/tmp/miclash' },
		random: fakes.entropy() },
	profile: 'config.yaml',
	config_content: 'external-controller: 127.0.0.1:9090\n',
	desired: () => ({ guard: { enabled: false }, devices: [], interfaces: [],
		proxy_servers: [] }),
	observed: () => ({ routing: { rules: [], routes: [] } }),
	dns_answers: () => []
});
for (let input in [
	{},
	{ target: 'bad host name' },
	{ target: 'example.com', device: 'not-a-mac' },
	{ target: 'example.com', interface: '../wan' },
	{ target: 'example.com', interface: '1234567890123456' },
	{ target: 'example.com', extra: true },
	{ target: '999.1.1.1' },
	{ target: '2001:::1' },
	{ target: '1:2:3:4:5:6:7:8:9' },
	{ target: '2001:db8::gg' }
])
	assert_throws(() => invalid_route.run(input), 'INVALID_ARGUMENT');

// New report generation is an asynchronous observation operation backed by a
// single-use streamed file. Aborting a transfer retains it until TTL.
let async_fs = fakes.fs({});
for (let directory in [ '/tmp', '/tmp/miclash', '/tmp/miclash/operations' ])
	async_fs.mkdir(directory);
async_fs.chmod('/tmp/miclash', 0o700);
async_fs.chmod('/tmp/miclash/operations', 0o700);
let async_runtime = {
	fs: async_fs,
	clock: fakes.clock(1900000000000),
	random: fakes.entropy(),
	digest: fakes.digest(async_fs),
	storage: { free_blocks: () => 65536 },
	paths: { tmp: '/tmp/miclash' }
};
let async_operations = operations.create(async_runtime);
let async_logs = [ 'connected hostname=beta-router.local' ];
for (let index = 0; index < 1200; index++)
	push(async_logs, sprintf('diagnostic-line-%04d %64s', index, 'x'));
let streamed_config = 'secret: ' + secrets.api_key + '\n' +
	'private-key: ' + config_private_key + '\n' +
	'uuid: ' + config_uuid + '\nmode: rule\n';
let async_log_reads = 0, async_logs_complete = false, evidence_events = [],
	config_opens = 0, config_reads = 0, maximum_config_read = 0;
let async_sources = {
	...sources,
	config: () => ({
		size: length(streamed_config),
		sha256: async_runtime.digest.sha256(streamed_config),
		open: () => {
			config_opens++;
			let offset = 0, closed = false;
			return {
				read: (amount) => {
					assert_true(amount <= 4096,
						'active config reads remain bounded to 4 KiB');
					maximum_config_read = max(maximum_config_read, amount);
					config_reads++;
					let chunk = substr(streamed_config, offset, amount);
					offset += length(chunk);
					return chunk;
				},
				finish: () => {
					assert_equal(offset, length(streamed_config));
					closed = true;
					return true;
				},
				close: () => { closed = true; return true; }
			};
		}
	}),
	state: () => ({ desired: {
		primary_hostname: 'alpha-router.local',
		backup_hostname: 'beta-router.local'
	}, observed: {} }),
	logs: () => {
		let async_log_offset = 0;
		return {
		read: (amount) => {
			async_log_reads++;
			let records = [];
			for (let count = 0; count < amount && async_log_offset < length(async_logs); count++)
				push(records, async_logs[async_log_offset++]);
			let done = async_log_offset >= length(async_logs);
			if (done) async_logs_complete = true;
			return { records, done };
		}
		};
	},
	evidence: () => {
		let index = 0;
		return {
			read: (amount) => {
				push(evidence_events, 'section-' + index);
				if (!index)
					async_runtime.clock.set_timeout(0, () => push(evidence_events, 'timer'));
				let records = index++ ? [ {
					name: 'logs',
					value: async_logs_complete ?
						{ state: 'present', source: 'test-log-stream',
							records: length(async_logs) } :
						{ state: 'unavailable', code: 'COLLECTION_UNAVAILABLE',
							message: 'logs have not finished' }
				} ] : [ { name: 'procd', value: { state: 'present', source: 'test' } } ];
				return { records, done: index >= 2 };
			},
			close: () => true
		};
	}
};
let async_center = diagnostics.create({
	runtime: async_runtime, sources: async_sources, operations: async_operations
});
for (let method in [ 'submit_report', 'open_report' ])
	assert_equal(type(async_center[method]), 'function', method + ' is exported');
let asynchronous = async_center.submit_report({
	mode: 'silent', acknowledge_secrets: false, source: 'luci'
});
assert_match(asynchronous.report_id, /^rpt_[0-9a-f]{32}$/);
assert_match(asynchronous.operation.id, /^[0-9]{13}-/);
async_runtime.clock.advance(0);
let asynchronous_record = async_operations.get(asynchronous.operation.id);
assert_equal(asynchronous_record.state, 'success');
assert_true(async_log_reads > 1,
	'large log sources are consumed through multiple event-loop chunks');
assert_equal(join(',', evidence_events), 'section-0,timer,section-1',
	'evidence collection yields to an event-loop timer between sections');
assert_equal(join(',', map(asynchronous_record.timeline, (item) => item.stage)),
	'queued,preflight,system,configuration,network,providers,operations,logs,validation,complete');
let streamed = async_center.open_report(asynchronous.report_id);
assert_true(streamed.size > 4096);
assert_match(streamed.sha256, /^[0-9a-f]{64}$/);
let first_chunk = streamed.read(0, min(49152, streamed.size));
assert_true(length(first_chunk) > 0);
assert_equal(streamed.close(), true);
let resumed = async_center.open_report(asynchronous.report_id);
let content = '', offset = 0;
while (offset < resumed.size) {
	let chunk = resumed.read(offset, min(257, resumed.size - offset));
	content += chunk;
	offset += length(chunk);
}
assert_equal(resumed.finish().size, resumed.size);
assert_true(index(content, secrets.telegram_token) < 0,
	'silent asynchronous report must apply the privacy profile');
let async_payload = json(content);
for (let name in [ 'metadata', 'system', 'installation', 'state', 'network', 'firewall',
	'providers', 'subscription', 'updates', 'telegram', 'memory', 'operations',
	'rpc', 'recovery', 'config' ])
	assert_true(exists(async_payload, name),
		'schema v4 requires top-level ' + name);
assert_equal(type(async_payload.operations), 'array');
assert_equal(async_payload.metadata.schema.name, 'miclash.diagnostics');
assert_equal(async_payload.metadata.schema.version, 4);
assert_equal(async_payload.metadata.schema_version, 4);
assert_equal(type(async_payload.metadata.started_at), 'int');
assert_equal(type(async_payload.metadata.completed_at), 'int');
assert_equal(type(async_payload.metadata.duration_ms), 'int');
assert_true(async_payload.metadata.duration_ms >= 0);
assert_equal(async_payload.state.desired.primary_hostname, '[HOST-1]');
assert_equal(async_payload.state.desired.backup_hostname, '[HOST-2]');
assert_true(index(async_payload.logs[0], '[HOST-2]') >= 0,
	'report-local host labels must stay stable across sections');
assert_equal(length(async_payload.logs), length(async_logs),
	'stream generation preserves every available relevant log record');
for (let name in [ 'versions', 'architecture', 'state', 'health', 'memory',
	'updates', 'settings', 'telegram', 'config', 'process', 'network_components',
	'uci', 'operations', 'logs', 'evidence' ]) {
	assert_true(type(async_payload.collection.sources[name]) == 'object',
		'collection records source ' + name);
	assert_equal(type(async_payload.collection.sources[name].duration_ms), 'int',
		'collection duration is recorded for ' + name);
}
assert_true(config_opens >= 2,
	'privacy modes pre-scan then stream the active config without materializing it');
assert_true(config_reads >= config_opens && maximum_config_read > 0 &&
	maximum_config_read <= 4096,
	'active config is pulled through bounded reader chunks');
assert_true(length(filter(async_payload.issues,
	(item) => item.section == 'collection' && item.component == 'logs')) == 0,
	'collection evidence is captured after a successful live log stream');

let full_job = async_center.submit_report({
	mode: 'full', acknowledge_secrets: true, source: 'luci'
});
async_runtime.clock.advance(0);
assert_equal(async_operations.get(full_job.operation.id).state, 'success');
let full_stream = async_center.open_report(full_job.report_id);
let full_content = '', full_offset = 0;
while (full_offset < full_stream.size) {
	let chunk = full_stream.read(full_offset, min(49152, full_stream.size - full_offset));
	full_content += chunk;
	full_offset += length(chunk);
}
full_stream.finish();
let full_payload = json(full_content);
assert_equal(full_payload.config.active_yaml, streamed_config,
	'Full schema v4 includes the byte-exact active YAML instead of a hash/size summary');
assert_true(full_payload.subscription.active_config == null,
	'active YAML has one canonical schema-v4 location');
let lite_job = async_center.submit_report({
	mode: 'lite', acknowledge_secrets: false, source: 'luci'
});
async_runtime.clock.advance(0);
assert_equal(async_operations.get(lite_job.operation.id).state, 'success');
let lite_stream = async_center.open_report(lite_job.report_id);
let lite_content = '', lite_offset = 0;
while (lite_offset < lite_stream.size) {
	let chunk = lite_stream.read(lite_offset, min(49152, lite_stream.size - lite_offset));
	lite_content += chunk;
	lite_offset += length(chunk);
}
lite_stream.finish();
assert_equal(sprintf('%J', report_shape(json(lite_content))),
	sprintf('%J', report_shape(async_payload)),
	'Silent and Lite retain identical recursive schema depth');
assert_equal(sprintf('%J', report_shape(full_payload)),
	sprintf('%J', report_shape(async_payload)),
	'Silent and Full retain identical recursive schema depth');
assert_throws(() => async_center.open_report(asynchronous.report_id), 'NOT_FOUND');
assert_throws(() => async_center.submit_report({
	mode: 'full', acknowledge_secrets: false, source: 'luci'
}), 'PERMISSION_DENIED');
assert_throws(() => async_center.submit_report({
	mode: 'full', acknowledge_secrets: true, source: 'telegram'
}), 'PERMISSION_DENIED');

// Publishing the file is not success until the terminal operation record is
// durable. Either final journal boundary must discard the published report.
function terminal_publication_failure(boundary) {
	let failure_fs = fakes.fs({});
	for (let directory in [ '/tmp', '/tmp/miclash', '/tmp/miclash/operations' ])
		failure_fs.mkdir(directory);
	failure_fs.chmod('/tmp/miclash', 0o700);
	failure_fs.chmod('/tmp/miclash/operations', 0o700);
	let failure_runtime = {
		fs: failure_fs,
		clock: fakes.clock(1950000000000),
		random: fakes.entropy(),
		digest: fakes.digest(failure_fs),
		storage: { free_blocks: () => 65536 },
		paths: { tmp: '/tmp/miclash' }
	};
	let failure_operations = operations.create(failure_runtime);
	let failure_center = diagnostics.create({
		runtime: failure_runtime, sources: async_sources, operations: failure_operations
	});
	let published = false;
	failure_fs.on_rename = (from, to) => {
		if (index(to, '/tmp/miclash/diagnostics/stream-report-') == 0) {
			published = true;
			if (boundary == 'stage') failure_fs.fail_rename_once = true;
			return;
		}
		if (boundary == 'complete' && published &&
			index(to, '/tmp/miclash/operations/') == 0) {
			let record = json(failure_fs.readfile(to));
			if (record?.state == 'running' && record?.stage == 'complete')
				failure_fs.fail_rename_once = true;
		}
	};
	let submitted = failure_center.submit_report({
		mode: 'lite', acknowledge_secrets: false, source: 'luci'
	});
	failure_runtime.clock.advance(0);
	assert_equal(failure_operations.get(submitted.operation.id).state, 'failure',
		boundary + ' terminal journal failure must fail the report operation');
	assert_throws(() => failure_center.open_report(submitted.report_id), 'NOT_FOUND');
}
terminal_publication_failure('stage');
terminal_publication_failure('complete');

print('diagnostics tests passed\n');
