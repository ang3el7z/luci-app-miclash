import { assert_equal, assert_throws, assert_true } from 'testlib';
import * as diagnostics from 'miclash.diagnostics';
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
function percent_encoded(value) {
	let output = '';
	for (let offset = 0; offset < length(value); offset++) {
		let byte = ord(value, offset);
		let character = substr(value, offset, 1);
		output += match(character, /^[A-Za-z0-9_.~-]$/) ? character : sprintf('%%%02X', byte);
	}
	return output;
};

let secrets = fixture('secret-corpus.json');
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
		'rss sampled with ' + secrets.password }),
	updates: () => ({ state: 'idle', url: secrets.subscription_url }),
	settings: () => ({
		core: { subscription_url: secrets.subscription_url },
		telegram: { enabled: true, token: secrets.telegram_token, user_id: '42' }
	}),
	last_repair: () => ({ result: 'success', context:
		'cookie=' + secrets.cookie }),
	config: () => 'secret: ' + secrets.api_key + '\n',
	process: () => ({ stdout: 'password=' + secrets.password,
		stderr: 'Bearer ' + secrets.authorization }),
	logs: () => [
		'url=' + secrets.subscription_url,
		'token=' + secrets.telegram_token
	],
	uci: () => ({ telegram: { token: secrets.telegram_token },
		remote: { api_key: secrets.api_key } }),
	operations: () => [ { id: 'safe-operation', context:
		'cookie=' + secrets.cookie + ' password=' + secrets.password } ]
};

assert_equal(type(diagnostics.create), 'function');
assert_equal(type(route_test.create), 'function');
assert_throws(() => diagnostics.create({
	runtime: { ...runtime, digest: { sha256: runtime.digest.sha256 } }, sources
}), 'INVALID_ARGUMENT');
let center = diagnostics.create({ runtime, sources });
for (let method in [ 'summary', 'create_report', 'read_report' ])
	assert_equal(type(center[method]), 'function', method + ' is exported');

function assert_no_secrets(value, label) {
	let text = type(value) == 'string' ? value : sprintf('%J', value);
	for (let name, secret in secrets)
		assert_true(index(text, secret) < 0,
			(label ?? 'diagnostics') + ' leaked ' + name);
};

let summary = center.summary();
assert_equal(summary.schema_version, 1);
assert_equal(summary.versions.miclash, 'v0.9.2');
assert_equal(summary.architecture, 'aarch64_cortex-a53');
assert_equal(summary.telegram.enabled, true);
assert_equal(summary.telegram.configured, true);
assert_true(type(summary.state.desired) == 'object');
assert_true(type(summary.state.observed) == 'object');
assert_true(type(summary.health.mihomo) == 'object');
assert_equal(summary.memory.phase, 'monitoring');
assert_equal(summary.updates.state, 'idle');
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

// Redaction is a closed, bounded boundary: all secret occurrences and safe
// encodings disappear from both keys and values before serialization.
let encoded_secret = 'encoded/secret+value=';
let overlap_short = 'overlap-secret';
let overlap_long = 'overlap-secret-tail';
let bearer_first = 'first-bearer-secret';
let bearer_late = 'late-bearer-secret';
let long_secret = repeated('long-secret-', 500) + 'end';
let adversarial_sources = { ...sources,
	settings: () => ({ core: { subscription_url: '' }, telegram: {
		enabled: true, token: encoded_secret, user_id: '42' } }),
	uci: () => ({ auth: { password: long_secret, api_key: overlap_short,
		access_token: overlap_long } }),
	state: () => ({ desired: { [encoded_secret]: 'key-value' }, observed: {} }),
	logs: () => [
		'Bearer ' + bearer_first + ' ignored Bearer ' + bearer_late,
		'percent=' + percent_encoded(encoded_secret),
		'base64=' + b64enc(encoded_secret),
		'overlap=' + overlap_long + ' and ' + overlap_short,
		'long=' + long_secret
	],
	process: () => ({ stderr: 'Bearer ' + bearer_first }),
	operations: () => [ { authorization: 'Bearer ' + bearer_first } ]
};
let adversarial_center = diagnostics.create({ runtime, sources: adversarial_sources });
let adversarial_report = adversarial_center.read_report({
	id: adversarial_center.create_report().id, format: 'json'
});
for (let secret in [ encoded_secret, percent_encoded(encoded_secret),
	b64enc(encoded_secret), bearer_first, bearer_late, long_secret,
	overlap_short, overlap_long, '-tail' ])
	assert_true(index(adversarial_report.content, secret) < 0,
		'adversarial report leaked ' + substr(secret, 0, 32));
assert_true(index(adversarial_report.content, encoded_secret) < 0,
	'object key secret is scrubbed');

let collision_sources = { ...sources,
	settings: () => ({ core: { subscription_url: '' }, telegram: {
		enabled: true, token: encoded_secret, user_id: '42' } }),
	state: () => ({ desired: {
		[encoded_secret]: 'one',
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
let huge_center = diagnostics.create({ runtime,
	sources: { ...sources, logs: () => [ repeated('x', 20000) ] } });
assert_throws(() => huge_center.summary(), 'RESPONSE_TOO_LARGE');

let created = center.create_report();
assert_true(match(created.id, /^rpt_[0-9a-f]{32}$/));
assert_equal(created.created_at, 1700000000000);
assert_true(created.expires_at > created.created_at);
assert_equal(length(created.files), 2);
assert_equal(created.files[0], 'report.json');
assert_equal(created.files[1], 'report.txt');
assert_true(index(sprintf('%J', created), '/tmp/') < 0,
	'report capability must not expose a path');

let json_report = center.read_report({ id: created.id, format: 'json' });
assert_equal(json_report.id, created.id);
assert_equal(json_report.format, 'json');
assert_true(type(json(json_report.content).summary) == 'object');
assert_no_secrets(json_report, 'json report');
let text_report = center.read_report({ id: created.id, format: 'text' });
assert_equal(text_report.format, 'text');
assert_true(index(text_report.content, 'MiClash diagnostic report') >= 0);
assert_no_secrets(text_report, 'text report');

// Expiry revokes the opaque capability and removes only its owned directory.
runtime.clock.advance(900000);
assert_throws(() => center.read_report({ id: created.id, format: 'json' }),
	'NOT_FOUND');
assert_equal(length(filesystem.lsdir('/tmp/miclash/diagnostics')), 0,
	'expired report directory is removed');

// Retention is bounded, and a daemon restart invalidates and cleans all old IDs.
let retained = [];
for (let index = 0; index < 6; index++) {
	runtime.clock.advance(1);
	push(retained, center.create_report());
}
assert_throws(() => center.read_report({ id: retained[0].id, format: 'json' }),
	'NOT_FOUND');
assert_true(length(filesystem.lsdir('/tmp/miclash/diagnostics')) <= 5);
let restarted = diagnostics.create({ runtime, sources });
assert_throws(() => restarted.read_report({
	id: retained[5].id, format: 'json'
}), 'NOT_FOUND');
assert_equal(length(filesystem.lsdir('/tmp/miclash/diagnostics')), 0,
	'restart cleanup leaves no hidden inaccessible reports');

assert_throws(() => center.read_report({
	id: created.id, format: 'json', path: '/etc/shadow'
}), 'INVALID_ARGUMENT');
assert_throws(() => center.read_report({
	id: '../../etc/shadow', format: 'json'
}), 'INVALID_ARGUMENT');

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
				mask: '0xffffffff', table: 100 },
			{ family: 'ipv6', priority: 1000, mark: '0x1',
				mask: '0xffffffff', table: 100 }
		],
		routes: [
			{ family: 'ipv4', table: 100, kind: 'local',
				destination: 'default', device: 'lo' },
			{ family: 'ipv6', table: 100, kind: 'local',
				destination: 'default', device: 'lo' }
		],
		interfaces: { 'clash-tun': false }
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
	else if (scenario.routing == 'oversized')
		for (let index = 0; index < 65; index++)
			push(observed.routing.rules, { family: 'ipv4', priority: 2000 + index,
				mark: '0x2', mask: '0xffffffff', table: 200 + index });
	let engine = route_test.create({
		runtime: route_runtime,
		profile: 'config.yaml',
		config_content: 'external-controller: 127.0.0.1:9090\n' +
			'secret: controller-secret-value\n',
		desired: () => scenario.desired,
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
		scenario.routing != 'malformed' && scenario.routing != 'oversized' &&
		(length(scenario.answers) > 0 || match(scenario.input.target, /:|^[0-9.]+$/));
	if (!route_expected)
		assert_equal(routing_step.evidence.valid, false);
	else
		assert_equal(routing_step.evidence.valid, true);
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
	{ target: 'example.com', extra: true },
	{ target: '999.1.1.1' },
	{ target: '2001:::1' },
	{ target: '1:2:3:4:5:6:7:8:9' },
	{ target: '2001:db8::gg' }
])
	assert_throws(() => invalid_route.run(input), 'INVALID_ARGUMENT');

function report_environment(random) {
	let fs = fakes.fs({});
	for (let directory in [ '/tmp', '/tmp/miclash' ])
		if (fs.lstat(directory) == null) fs.mkdir(directory);
	fs.chmod('/tmp/miclash', 0o700);
	let clock = fakes.clock(1800000000000);
	let runtime = { fs, clock, random: random ?? fakes.entropy(),
		digest: fakes.digest(fs), paths: { tmp: '/tmp/miclash' } };
	return { fs, clock, runtime,
		center: () => diagnostics.create({ runtime, sources }) };
};

// Foreign and malformed restart debris is never followed or silently deleted.
let foreign = report_environment();
foreign.fs.mkdir('/tmp/miclash/diagnostics');
foreign.fs.chmod('/tmp/miclash/diagnostics', 0o700);
foreign.fs.writefile('/tmp/miclash/diagnostics/foreign-entry', 'foreign');
assert_throws(() => foreign.center(), 'CORRUPT_STATE');
assert_equal(foreign.fs.readfile('/tmp/miclash/diagnostics/foreign-entry'), 'foreign');

let linked_directory = report_environment();
linked_directory.fs.mkdir('/tmp/miclash/diagnostics');
linked_directory.fs.chmod('/tmp/miclash/diagnostics', 0o700);
linked_directory.fs.set_symlink(
	'/tmp/miclash/diagnostics/report-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', '/tmp');
assert_throws(() => linked_directory.center(), 'CORRUPT_STATE');
assert_equal(linked_directory.fs.lstat(
	'/tmp/miclash/diagnostics/report-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa').type, 'link');

let incomplete = report_environment();
incomplete.fs.mkdir('/tmp/miclash/diagnostics');
incomplete.fs.chmod('/tmp/miclash/diagnostics', 0o700);
incomplete.fs.mkdir('/tmp/miclash/diagnostics/report-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb');
incomplete.fs.chmod(
	'/tmp/miclash/diagnostics/report-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb', 0o700);
assert_throws(() => incomplete.center(), 'CORRUPT_STATE');
assert_true(incomplete.fs.lstat(
	'/tmp/miclash/diagnostics/report-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb') != null);

// Authenticated reads detect a leaf identity swap before returning bytes.
let raced = report_environment();
let raced_center = raced.center();
let raced_report = raced_center.create_report();
let raced_dir = raced.fs.lsdir('/tmp/miclash/diagnostics')[0];
let raced_json = '/tmp/miclash/diagnostics/' + raced_dir + '/report.json';
let swapped = false;
raced.fs.on_lstat = (path, count) => {
	if (!swapped && path == raced_json) {
		swapped = true;
		raced.fs.bump_inode(path);
	}
};
assert_throws(() => raced_center.read_report({
	id: raced_report.id, format: 'json'
}), 'INTERNAL');
raced.fs.on_lstat = null;
diagnostics.create({ runtime: raced.runtime, sources });
assert_equal(length(raced.fs.lsdir('/tmp/miclash/diagnostics')), 0);

// ID and directory collisions are retried without exposing a path.
let values = [
	'11111111111111111111111111111111',
	'22222222222222222222222222222222',
	'11111111111111111111111111111111',
	'33333333333333333333333333333333',
	'44444444444444444444444444444444'
];
let collision_random = { hex: (bytes) => shift(values) };
let collision = report_environment(collision_random);
let collision_center = collision.center();
let first_collision = collision_center.create_report();
let second_collision = collision_center.create_report();
assert_true(first_collision.id != second_collision.id);
assert_equal(length(collision.fs.lsdir('/tmp/miclash/diagnostics')), 2);

// Real directories may have multiple links; only report files require nlink=1.
let directory_links = report_environment();
directory_links.fs.set_nlink('/tmp/miclash', 2);
directory_links.fs.on_mkdir = (path) => {
	if (path == '/tmp/miclash/diagnostics' ||
	    match(path, /^\/tmp\/miclash\/diagnostics\/report-/))
		directory_links.fs.set_nlink(path, 2);
};
let linked_center = directory_links.center();
let linked_report = linked_center.create_report();
assert_equal(linked_center.read_report({
	id: linked_report.id, format: 'json'
}).id, linked_report.id);

// Every failed publication removes its exact owned partial staging tree.
for (let failure in [ 'write', 'second-file-open' ]) {
	let partial = report_environment();
	let partial_center = partial.center();
	if (failure == 'write') partial.fs.fail_on = 'write';
	else partial.fs.fail_open_once_matching = 'report.txt';
	assert_throws(() => partial_center.create_report(), 'INTERNAL');
	partial.fs.fail_on = null;
	assert_equal(length(partial.fs.lsdir('/tmp/miclash/diagnostics')), 0,
		failure + ' leaves no hidden staging directory');
	assert_equal(type(partial_center.summary()), 'object');
}

// The creation capability begins before mkdir. Every injected failure is
// either cleaned immediately or recognized and cleaned by a fresh daemon.
for (let failure in [ 'mkdir-crash', 'chmod', 'verify', 'open', 'write-crash' ]) {
	let interrupted = report_environment();
	let interrupted_center = interrupted.center();
	let injected = false;
	interrupted.fs.on_mkdir = (path) => {
		if (injected || !match(path, /\/diagnostics\/(\.stage-|report-)/)) return;
		if (failure == 'verify') return;
		injected = true;
		if (failure == 'mkdir-crash') die('INTERNAL');
		if (failure == 'chmod') interrupted.fs.fail_on = 'chmod';
		if (failure == 'write-crash') interrupted.fs.fail_on = 'write';
	};
	if (failure == 'verify')
		interrupted.fs.on_lstat = (path, count) => {
			if (!injected && match(path, /\/diagnostics\/(\.stage-|report-)/) && count >= 2) {
				injected = true;
				die('INTERNAL');
			}
		};
	if (failure == 'open')
		interrupted.fs.fail_open_once_matching = 'report.json';
	assert_throws(() => interrupted_center.create_report(), 'INTERNAL');
	interrupted.fs.on_mkdir = null;
	interrupted.fs.on_lstat = null;
	interrupted.fs.fail_on = null;
	let recovered_center = interrupted.center();
	assert_equal(type(recovered_center.summary()), 'object');
	assert_equal(length(interrupted.fs.lsdir('/tmp/miclash/diagnostics')), 0,
		failure + ' is restart recoverable');
}

print('diagnostics tests passed\n');
