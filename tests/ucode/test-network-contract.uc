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

// Review regressions are collected together so the RED run exposes the full
// contract gap instead of stopping at the first malformed golden.
let review_failures = [];
let policy_actions = {};
function review(condition, message) {
	if (!condition)
		push(review_failures, message);
};

function valid_mac(value) {
	let octets = split(value, ':');
	if (length(octets) != 6)
		return false;
	for (let octet in octets)
		if (!match(octet, /^[0-9a-fA-F][0-9a-fA-F]$/))
			return false;
	return true;
};

for (let scenario in document.scenarios) {
	let nft = read_required(root + '/nft/' + scenario.expected.nft);
	let iptables = read_required(root + '/iptables/' + scenario.expected.iptables);
	let routes = read_required(root + '/routes/' + scenario.expected.routes);

	if (scenario.guard) {
		review(!match(nft, /established,related/), scenario.name + ': nft Guard must not allow established direct flows');
		review(!match(iptables, /ESTABLISHED,RELATED/), scenario.name + ': iptables Guard must not allow established direct flows');
		for (let family in scenario.ip_families) {
			let nft_family = family == 'ipv4' ? 'ipv4' : 'ipv6';
			let ipt = family == 'ipv4' ? 'iptables' : 'ip6tables';
			let nft_drop = 'miclash_guard forward meta nfproto ' + nft_family + ' drop';
			let ipt_drop = ipt + ' -t filter -A MICLASH_GUARD_FORWARD -j DROP';
			review(index(nft, nft_drop) >= 0,
				scenario.name + ': nft Guard needs family-wide ' + family + ' drop');
			review(index(iptables, ipt_drop) >= 0,
				scenario.name + ': iptables Guard needs family-wide ' + family + ' drop');
			let nft_drop_at = index(nft, nft_drop);
			let nft_tun_at = index(nft, 'miclash_guard forward oifname "clash-tun" accept');
			let nft_local_at = index(nft, family == 'ipv4' ?
				'miclash_guard forward ip daddr @local4 accept' :
				'miclash_guard forward ip6 daddr @local6 accept');
			review(nft_drop_at > nft_tun_at && nft_drop_at > nft_local_at,
				scenario.name + ': nft Guard drop must follow narrow safe exceptions');
			let ipt_drop_at = index(iptables, ipt_drop);
			let ipt_tun_at = index(iptables, ipt + ' -t filter -A MICLASH_GUARD_FORWARD -o clash-tun -j RETURN');
			let ipt_local_at = index(iptables, ipt + ' -t filter -A MICLASH_GUARD_FORWARD -m set');
			review(ipt_drop_at > ipt_tun_at && ipt_drop_at > ipt_local_at,
				scenario.name + ': iptables Guard drop must follow narrow safe exceptions');
		}
		review(!match(nft, /miclash_guard forward oifname [^\n]* drop/),
			scenario.name + ': nft Guard must cover unknown WAN interfaces');
		review(!match(iptables, /MICLASH_GUARD_FORWARD -o [^\n]* -j DROP/),
			scenario.name + ': iptables Guard must cover unknown WAN interfaces');
	}

	review(!!match(iptables, / -A PREROUTING -j MICLASH_PREROUTING/),
		scenario.name + ': iptables PREROUTING hook is unreachable');
	review(!!match(iptables, / -A OUTPUT -j MICLASH_OUTPUT/),
		scenario.name + ': iptables OUTPUT hook is unreachable');
	review(!match(iptables, / -A PREROUTING [^\n]* -j RETURN/),
		scenario.name + ': built-in PREROUTING must never RETURN for exclusions');
	for (let command in scenario.ip_families)
		if (command == 'ipv4') {
			review(index(iptables, 'iptables -t mangle -N MICLASH_PREROUTING') <
				index(iptables, 'iptables -t mangle -A PREROUTING -j MICLASH_PREROUTING'),
				scenario.name + ': IPv4 hook must follow owned chain creation');
			review(index(iptables, 'iptables -t mangle -N MICLASH_OUTPUT') <
				index(iptables, 'iptables -t mangle -A OUTPUT -j MICLASH_OUTPUT'),
				scenario.name + ': IPv4 OUTPUT hook must follow chain creation');
		}
		else {
			review(index(iptables, 'ip6tables -t mangle -N MICLASH_PREROUTING') <
				index(iptables, 'ip6tables -t mangle -A PREROUTING -j MICLASH_PREROUTING'),
				scenario.name + ': IPv6 hook must follow owned chain creation');
			review(index(iptables, 'ip6tables -t mangle -N MICLASH_OUTPUT') <
				index(iptables, 'ip6tables -t mangle -A OUTPUT -j MICLASH_OUTPUT'),
				scenario.name + ': IPv6 OUTPUT hook must follow chain creation');
		}
	if (scenario.interface_mode == 'exclude')
		for (let interface in scenario.wan)
			review(index(iptables, 'MICLASH_PREROUTING -i ' + interface + ' -j RETURN') >= 0,
				scenario.name + ': exclusion is not scoped to MiClash chain');

	let has_iptables4 = !!match(iptables, /^iptables /) || !!match(iptables, /\niptables /);
	let has_iptables6 = !!match(iptables, /^ip6tables /) || !!match(iptables, /\nip6tables /);
	let has_routes4 = !!match(routes, /^ip (route|rule) /) || !!match(routes, /\nip (route|rule) /);
	let has_routes6 = !!match(routes, /^ip -6 /) || !!match(routes, /\nip -6 /);
	review(has_iptables4 == includes(scenario.ip_families, 'ipv4'), scenario.name + ': iptables IPv4 family mismatch');
	review(has_iptables6 == includes(scenario.ip_families, 'ipv6'), scenario.name + ': iptables IPv6 family mismatch');
	review(has_routes4 == includes(scenario.ip_families, 'ipv4'), scenario.name + ': route IPv4 family mismatch');
	review(has_routes6 == includes(scenario.ip_families, 'ipv6'), scenario.name + ': route IPv6 family mismatch');
	let nft_seen = {};
	for (let line in split(nft, '\n')) {
		if (!match(line, /miclash (proxy|output)/) ||
			!match(line, /tproxy to|meta mark set|udp dport 443 reject/))
			continue;
		let family = match(line, /meta nfproto ipv4/) ? 'ipv4' :
			match(line, /meta nfproto ipv6/) ? 'ipv6' : null;
		review(family != null, scenario.name + ': family-neutral nft action: ' + line);
		if (family != null)
			nft_seen[family] = true;
	}
	for (let family in scenario.ip_families)
		review(nft_seen[family], scenario.name + ': nft missing ' + family + ' actions');
	for (let family in [ 'ipv4', 'ipv6' ])
		if (!includes(scenario.ip_families, family))
			review(!nft_seen[family], scenario.name + ': nft has unexpected ' + family + ' actions');

	let first_policy = { nft: null, iptables: null };
	let block_policy = { nft: null, iptables: null };
	for (let policy in scenario.device_policies) {
		review(sprintf('%J', sorted(keys(policy))) == sprintf('%J', [ 'action', 'id', 'mac', 'schedule' ]),
			scenario.name + ': device policy schema lacks stable identity/schedule');
		review(valid_mac(policy.mac), scenario.name + ': invalid stable MAC identity');
		review(includes([ 'inherit', 'proxy', 'direct', 'block' ], policy.action),
			scenario.name + ': invalid device policy action');
		policy_actions[policy.action] = true;
		if (policy.schedule != null)
			review(sprintf('%J', sorted(keys(policy.schedule))) ==
				sprintf('%J', [ 'days', 'end', 'start', 'timezone' ]),
				scenario.name + ': invalid device schedule schema');
		for (let backend, content in { nft, iptables }) {
			let at = index(content, policy.mac);
			review(at >= 0 || policy.action == 'inherit',
				scenario.name + ': ' + backend + ' missing device policy ' + policy.id);
			if (at >= 0 && (first_policy[backend] == null || at < first_policy[backend]))
				first_policy[backend] = at;
			if (policy.action == 'block')
				block_policy[backend] = at;
		}
	}
	if (block_policy.nft != null)
		review(block_policy.nft == first_policy.nft, scenario.name + ': nft block policy must have precedence');
	if (block_policy.iptables != null)
		review(block_policy.iptables == first_policy.iptables, scenario.name + ': iptables block policy must have precedence');
}

for (let action in [ 'inherit', 'proxy', 'direct', 'block' ])
	review(policy_actions[action], 'device policy matrix missing action: ' + action);

let capture_source = read_required('tools/capture-network-contract.sh');
review(!!match(capture_source, /unshare --mount --net --pid/), 'capture must require mount+network+PID namespaces');
review(!!match(capture_source, /mount --make-rprivate/), 'capture mount namespace must be private');
review(!!match(capture_source, /findmnt/), 'capture must reject nested mounts');
review(!!match(capture_source, /nft-batch/), 'nft fake must record batch stdin/file content');
review(!!match(capture_source, /normalize_nft/) && !!match(capture_source, /normalize_routes/),
	'capture must normalize desired nft and route state separately');
review(!!match(capture_source, /mixed-explicit-guard-devices-dualstack.*capture_wan6=eth1/),
	'dual-stack device capture WAN6 must match metadata');
review(!!match(capture_source, /mixed-explicit-guard-provider-bypass.*capture_wan6=eth1/),
	'dual-stack provider capture WAN6 must match metadata');

let normalization = fs.popen(`sh -c '
	set -eu
	d=$(mktemp -d)
	trap "rm -rf -- $d" EXIT HUP INT TERM
	printf "nft\\tlist\\ttables\\nnft\\tdelete\\ttable\\tinet\\tcapture\\nnft\\tadd\\ttable\\tinet\\tcapture\\nnft\\t-f\\t-\\nnft-batch\\tadd chain inet capture c\\n" > "$d/nft.raw"
	printf "iptables\\t-t\\tmangle\\t-D\\tPREROUTING\\t-j\\tCAPTURE\\niptables\\t-t\\tmangle\\t-F\\tCAPTURE\\niptables\\t-t\\tmangle\\t-N\\tCAPTURE\\niptables\\t-t\\tmangle\\t-A\\tPREROUTING\\t-j\\tCAPTURE\\n" > "$d/iptables.raw"
	printf "ip\\troute\\tshow\\tdefault\\nip\\troute\\tflush\\ttable\\t100\\nip\\trule\\tdel\\tfwmark\\t0x1\\ttable\\t100\\nip\\troute\\treplace\\tlocal\\tdefault\\tdev\\tlo\\ttable\\t100\\nip\\trule\\tadd\\tpref\\t1000\\tfwmark\\t0x1\\ttable\\t100\\n" > "$d/routes.raw"
	tools/capture-network-contract.sh --normalize nft "$d/nft.raw" "$d/nft.out"
	tools/capture-network-contract.sh --normalize iptables "$d/iptables.raw" "$d/iptables.out"
	tools/capture-network-contract.sh --normalize routes "$d/routes.raw" "$d/routes.out"
	printf "NFT\\n"; cat "$d/nft.out"
	printf "IPTABLES\\n"; cat "$d/iptables.out"
	printf "ROUTES\\n"; cat "$d/routes.out"
'`, 'r');
let normalized_output = normalization.read('all');
review(normalization.close() == 0, 'capture normalization integration failed');
review(normalized_output == join('\n', [
	'NFT',
	'add table inet capture',
	'add chain inet capture c',
	'IPTABLES',
	'iptables -t mangle -N CAPTURE',
	'iptables -t mangle -A PREROUTING -j CAPTURE',
	'ROUTES',
	'ip route replace local default dev lo table 100',
	'ip rule add pref 1000 fwmark 0x1 table 100',
	''
]), 'capture normalization leaked observations/cleanup: ' + normalized_output);

if (length(review_failures))
	die('network contract review regressions:\n- ' + join('\n- ', review_failures));

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
		assert_equal(sprintf('%J', sorted(keys(policy))), sprintf('%J', [ 'action', 'id', 'mac', 'schedule' ]),
			'unexpected device policy schema');
		assert_true(valid_mac(policy.mac), 'invalid device policy MAC');
		assert_true(includes([ 'inherit', 'proxy', 'direct', 'block' ], policy.action), 'invalid device policy action');
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
				assert_true(index(content, policy.mac) >= 0, 'nft device policy missing: ' + policy.mac);
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
				for (let family in scenario.ip_families)
					assert_true(index(content, 'meta nfproto ' + family + ' drop') >= 0,
						'missing fail-closed nft family: ' + family);
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
				assert_true(index(content, policy.mac) >= 0, 'iptables device policy missing: ' + policy.mac);
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

// nft --check still consults netlink, so only use it when an isolated network
// namespace probe succeeds. The check flag parses/validates without applying.
let nft_path_proc = fs.popen('command -v nft 2>/dev/null', 'r');
let nft_path = nft_path_proc ? trim(nft_path_proc.read('all')) : '';
if (nft_path_proc)
	nft_path_proc.close();
let unshare_path_proc = fs.popen('command -v unshare 2>/dev/null', 'r');
let unshare_path = unshare_path_proc ? trim(unshare_path_proc.read('all')) : '';
if (unshare_path_proc)
	unshare_path_proc.close();
if (nft_path != '' && unshare_path != '') {
	let probe = fs.popen("printf 'add table inet miclash_syntax_probe\\n' | unshare --net --fork nft --check --file - 2>&1", 'r');
	let probe_output = probe.read('all');
	let probe_status = probe.close();
	if (probe_status == 0) {
		for (let filename in expected_files.nft) {
			let path = root + '/nft/' + filename;
			let check = fs.popen('unshare --net --fork nft --check --file ' + path + ' 2>&1', 'r');
			let output = check.read('all');
			assert_equal(check.close(), 0, 'nft syntax failed for ' + filename + ': ' + output);
		}
	}
}
