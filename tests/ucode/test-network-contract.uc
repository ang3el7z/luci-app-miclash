import { assert_equal, assert_match, assert_true } from './testlib.uc';

let fs = require('fs');
let root = 'tests/fixtures/network';
assert_true(index('\n' + fs.readfile('.gitattributes'), '\n*.golden text eol=lf\n') >= 0,
	'golden fixtures must remain LF on every checkout');
let required_keys = [
	'name', 'proxy_mode', 'interface_mode', 'lan', 'wan', 'guard', 'quic',
	'server_ips', 'fakeip_cidrs', 'device_policies', 'ip_families',
	'existing_clash_tun', 'rationale', 'expected'
];

function sorted(values) {
	return sort(values);
};

function includes(values, wanted) {
	for (let value in values)
		if (value == wanted)
			return true;
	return false;
};

function has_pair(scenarios, proxy_mode, interface_mode) {
	for (let scenario in scenarios)
		if (scenario.proxy_mode == proxy_mode && scenario.interface_mode == interface_mode)
			return true;
	return false;
};

function has_value(scenarios, key, wanted) {
	for (let scenario in scenarios)
		if (scenario[key] == wanted)
			return true;
	return false;
};

function has_array_value(scenarios, key, wanted) {
	for (let scenario in scenarios)
		if (includes(scenario[key], wanted))
			return true;
	return false;
};

function read_required(path) {
	let value = fs.readfile(path);
	assert_true(value != null, 'missing fixture: ' + path);
	return value;
};

let document = json(read_required(root + '/scenarios.json'));
assert_equal(sprintf('%J', sorted(keys(document))), sprintf('%J', [ 'metadata', 'scenarios', 'schema_version' ]),
	'unexpected top-level fixture schema');
assert_equal(document.schema_version, 1, 'unexpected network fixture schema');
assert_true(type(document.metadata) == 'object', 'missing fixture metadata');
assert_equal(sprintf('%J', sorted(keys(document.metadata))),
	sprintf('%J', [ 'contract', 'corrections', 'normalization', 'rationale' ]),
	'unexpected metadata schema');
assert_match(document.metadata.contract, /intended/, 'contract must describe intended semantics');
assert_true(length(document.metadata.corrections) > 0, 'legacy corrections must be documented');
assert_true(length(document.scenarios) >= 10, 'use named representative scenarios, not a sparse matrix');

let expected_files = { nft: [], iptables: [], routes: [] };
let names = {};
for (let scenario in document.scenarios) {
	assert_equal(sprintf('%J', sorted(keys(scenario))), sprintf('%J', sorted(required_keys)),
		'unexpected scenario schema: ' + (scenario.name ?? '<unnamed>') +
		' keys=' + sprintf('%J', sorted(keys(scenario))));
	assert_match(scenario.name, /^[a-z0-9][a-z0-9-]*$/, 'invalid scenario name');
	assert_true(!match(scenario.name, /--/) && substr(scenario.name, -1) != '-', 'invalid scenario name');
	assert_true(!names[scenario.name], 'duplicate scenario name: ' + scenario.name);
	names[scenario.name] = true;
	assert_true(includes([ 'tproxy', 'tun', 'mixed' ], scenario.proxy_mode), 'invalid proxy mode');
	assert_true(includes([ 'explicit', 'exclude' ], scenario.interface_mode), 'invalid interface mode');
	assert_true(type(scenario.lan) == 'array' && type(scenario.wan) == 'array', 'interfaces must be arrays');
	assert_true(type(scenario.guard) == 'bool' && type(scenario.quic) == 'bool', 'guard/quic must be booleans');
	assert_true(type(scenario.server_ips) == 'array' && type(scenario.fakeip_cidrs) == 'array',
		'IP collections must be arrays');
	assert_true(type(scenario.device_policies) == 'array', 'device policies must be an array');
	assert_true(length(scenario.ip_families) > 0, 'each scenario needs an IP family');
	for (let family in scenario.ip_families)
		assert_true(includes([ 'ipv4', 'ipv6' ], family), 'invalid IP family');
	for (let policy in scenario.device_policies) {
		assert_equal(sprintf('%J', sorted(keys(policy))), sprintf('%J', [ 'action', 'source' ]),
			'unexpected device policy schema');
		assert_true(includes([ 'direct', 'proxy' ], policy.action), 'invalid device policy action');
	}
	assert_true(length(scenario.rationale) > 0, 'each scenario needs a rationale');
	assert_equal(sprintf('%J', sorted(keys(scenario.expected))), sprintf('%J', [ 'iptables', 'nft', 'routes' ]),
		'each scenario needs every canonical output');

	for (let backend in [ 'nft', 'iptables', 'routes' ]) {
		let filename = scenario.expected[backend];
		assert_equal(filename, scenario.name + '.golden', 'fixture name must match scenario name');
		assert_true(index(filename, '/') < 0 && index(filename, '..') < 0, 'fixture name escapes backend directory');
		push(expected_files[backend], filename);
		let content = read_required(root + '/' + backend + '/' + filename);
		assert_true(length(content) > 0, 'empty fixture: ' + filename);
		assert_true(substr(content, -1) == '\n', 'fixture must end with LF: ' + filename);
		assert_true(index(content, '\r') < 0, 'fixture must use LF only: ' + filename);
		assert_true(!match(content, /[ \t]\n/), 'fixture has trailing whitespace: ' + filename);
		assert_true(!match(content, /pid=[0-9]+|timestamp=[0-9]+|updated_at=[0-9]+/),
			'fixture contains volatile data: ' + filename);
		if (backend == 'nft') {
			assert_match(content, /^# MiClash intended nft contract v1\n/);
			assert_equal(!!match(content, /udp dport 443 reject/), scenario.quic,
				'nft QUIC state mismatch: ' + scenario.name);
			if (length(scenario.fakeip_cidrs))
				assert_match(content, /fakeip_whitelist4/);
			for (let policy in scenario.device_policies)
				assert_true(index(content, policy.source) >= 0, 'nft device policy missing: ' + policy.source);
			if (scenario.interface_mode == 'explicit' && !length(scenario.lan))
				assert_match(content, /explicit interface selection empty/);
			for (let interface in scenario.interface_mode == 'explicit' ? scenario.lan : scenario.wan)
				assert_true(index(content, '"' + interface + '"') >= 0,
					'nft interface missing: ' + interface);
			assert_equal(!!match(content, /add table inet miclash_guard/), scenario.guard,
				'nft Guard state mismatch: ' + scenario.name);
			if (scenario.guard && length(scenario.server_ips)) {
				assert_match(content, /Guard ON: client proxy-server bypass intentionally omitted/);
				assert_true(!match(content, /miclash proxy ip6? daddr @proxy_servers/),
					'Guard ON must omit nft client provider bypass');
				assert_match(content, /miclash output ip6? daddr @proxy_servers/,
					'router output loop prevention must remain');
			}
			if (scenario.guard && !length(scenario.wan)) {
				assert_match(content, /meta nfproto ipv4 drop/);
				assert_match(content, /meta nfproto ipv6 drop/);
			}
		}
		else if (backend == 'iptables') {
			assert_match(content, /^# MiClash intended iptables contract v1\n/);
			assert_equal(!!match(content, /--dport 443 -j REJECT/), scenario.quic,
				'iptables QUIC state mismatch: ' + scenario.name);
			if (length(scenario.fakeip_cidrs))
				assert_match(content, /clash_fakeip_whitelist/);
			if (includes(scenario.ip_families, 'ipv6'))
				assert_match(content, /ip6tables/);
			for (let policy in scenario.device_policies)
				assert_true(index(content, policy.source) >= 0, 'iptables device policy missing: ' + policy.source);
			if (scenario.interface_mode == 'explicit' && !length(scenario.lan))
				assert_match(content, /explicit interface selection empty/);
			for (let interface in scenario.interface_mode == 'explicit' ? scenario.lan : scenario.wan)
				assert_true(index(content, ' ' + interface + ' ') >= 0,
					'iptables interface missing: ' + interface);
			assert_equal(!!match(content, /MICLASH_GUARD_FORWARD/), scenario.guard,
				'iptables Guard state mismatch: ' + scenario.name);
			if (scenario.guard && length(scenario.server_ips)) {
				assert_match(content, /Guard ON client proxy-server bypass intentionally omitted/);
				assert_true(!match(content, /MICLASH_PROXY -d [0-9a-fA-F:.]+ -j RETURN/),
					'Guard ON must omit iptables client provider bypass');
				assert_match(content, /MICLASH_OUTPUT -d [0-9a-fA-F:.]+ -j RETURN/);
			}
			if (scenario.guard && !length(scenario.wan))
				assert_match(content, /MICLASH_GUARD_FORWARD -j DROP/);
		}
		else {
			assert_match(content, /^# MiClash intended routing contract v1\n/);
			assert_match(content, /table 100/);
			if (includes(scenario.ip_families, 'ipv6'))
				assert_match(content, /ip -6/);
			assert_equal(!!match(content, /table 101/), scenario.proxy_mode == 'mixed',
				'routing mode mismatch: ' + scenario.name);
			if (scenario.existing_clash_tun && scenario.proxy_mode != 'tproxy')
				assert_match(content, /default dev clash-tun/);
		}
	}
}

for (let correction in document.metadata.corrections) {
	assert_equal(sprintf('%J', sorted(keys(correction))),
		sprintf('%J', [ 'id', 'intended_semantics', 'legacy_observation', 'scenarios' ]),
		'unexpected correction schema');
	assert_true(length(correction.scenarios) > 0, 'correction must cite scenarios');
	for (let scenario_name in correction.scenarios)
		assert_true(names[scenario_name], 'correction cites unknown scenario: ' + scenario_name);
}

for (let proxy_mode in [ 'tproxy', 'tun', 'mixed' ])
	for (let interface_mode in [ 'explicit', 'exclude' ])
		assert_true(has_pair(document.scenarios, proxy_mode, interface_mode),
			'missing proxy/interface pair: ' + proxy_mode + '/' + interface_mode);

assert_true(has_value(document.scenarios, 'guard', true), 'missing Guard ON');
assert_true(has_value(document.scenarios, 'guard', false), 'missing Guard OFF');
assert_true(has_value(document.scenarios, 'quic', true), 'missing QUIC ON');
assert_true(has_value(document.scenarios, 'quic', false), 'missing QUIC OFF');
assert_true(has_array_value(document.scenarios, 'ip_families', 'ipv4'), 'missing IPv4');
assert_true(has_array_value(document.scenarios, 'ip_families', 'ipv6'), 'missing IPv6');
assert_true(has_value(document.scenarios, 'existing_clash_tun', true), 'missing existing clash-tun restart');

let empty_detection = false;
let multiple_wan = false;
let one_wan = false;
let provider_bypass = false;
let guarded_provider = false;
let open_provider = false;
let fakeip_whitelist = false;
let device_policy = false;
for (let scenario in document.scenarios) {
	empty_detection = empty_detection || (!length(scenario.lan) && !length(scenario.wan));
	multiple_wan = multiple_wan || length(scenario.wan) > 1;
	one_wan = one_wan || length(scenario.wan) == 1;
	provider_bypass = provider_bypass || length(scenario.server_ips) > 0;
	guarded_provider = guarded_provider || (scenario.guard && length(scenario.server_ips) > 0);
	open_provider = open_provider || (!scenario.guard && length(scenario.server_ips) > 0);
	fakeip_whitelist = fakeip_whitelist || length(scenario.fakeip_cidrs) > 0;
	device_policy = device_policy || length(scenario.device_policies) > 0;
}
assert_true(empty_detection, 'missing empty interface detection');
assert_true(multiple_wan, 'missing multiple WANs');
assert_true(one_wan, 'missing one WAN');
assert_true(provider_bypass, 'missing provider/server bypass');
assert_true(guarded_provider && open_provider, 'provider bypass needs Guard ON and OFF representatives');
assert_true(fakeip_whitelist, 'missing fake-IP whitelist');
assert_true(device_policy, 'missing device policies');

for (let backend in [ 'nft', 'iptables', 'routes' ]) {
	let actual = [];
	for (let entry in fs.lsdir(root + '/' + backend))
		if (entry != '.' && entry != '..')
			push(actual, entry);
	assert_equal(sprintf('%J', sorted(actual)), sprintf('%J', sorted(expected_files[backend])),
		'unexpected or missing files in ' + backend);
}
