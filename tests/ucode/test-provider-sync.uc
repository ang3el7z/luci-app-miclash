import * as provider_data from 'miclash.provider-data';
import * as provider_sync from 'miclash.provider-sync';
import { assert_equal, assert_throws, assert_true } from './testlib.uc';
import * as fakes from './fakes.uc';

const CONFIG = `
dns:
  enable: true
  enhanced-mode: fake-ip
  fake-ip-filter-mode: whitelist
proxies:
  - name: inline
    server: 192.0.2.10
proxy-providers:
  remote:
    type: http
    path: ./proxy_providers/remote.yaml
rule-providers:
  routed-ips:
    behavior: ipcidr
    path: ./ruleset/routed.yaml
  routed-mrs:
    behavior: ipcidr
    path: ./ruleset/routed.mrs
  direct-ips:
    behavior: ipcidr
    path: ./ruleset/direct.yaml
rules:
  - RULE-SET,routed-ips,PROXY
  - RULE-SET,routed-mrs,PROXY
  - RULE-SET,direct-ips,DIRECT
`;

let filesystem = fakes.fs({
	'/opt/clash/config.yaml': CONFIG,
	'/opt/clash/proxy_providers/remote.yaml': `proxies:
  - name: remote
    server: edge.example.test
`,
	'/opt/clash/ruleset/routed.yaml': `payload:
  - 198.18.0.0/16
  - 2001:db8:1::/48
`,
	'/opt/clash/ruleset/routed.mrs': 'binary-ruleset',
	'/opt/clash/ruleset/direct.yaml': `payload:
  - 203.0.113.0/24
`,
	'/opt/clash/lst/fakeip-whitelist-ipcidr.txt': `192.0.2.0/24
`
});
let snapshot = provider_data.collect({ fs: filesystem }, CONFIG, {
	auto_fakeip_whitelist: true,
	resolve: (host) => host == 'edge.example.test'
		? [ '198.51.100.20', '2001:db8::20' ] : [],
	convert_mrs: (path, behavior) => {
		assert_equal(path, '/opt/clash/ruleset/routed.mrs');
		assert_equal(behavior, 'ipcidr');
		return 'payload:\n  - 203.0.113.0/24\n';
	}
});
assert_equal(join(',', snapshot.server_ips),
	'192.0.2.10,198.51.100.20,2001:db8::20');
assert_equal(join(',', snapshot.fakeip_cidrs),
	'192.0.2.0/24,198.18.0.0/16,2001:db8:1::/48,203.0.113.0/24');
let partial_snapshot = provider_data.collect({ fs: filesystem }, CONFIG, {
	auto_fakeip_whitelist: true, resolve: () => [], convert_mrs: () => ''
});
assert_equal(join(',', partial_snapshot.server_ips), '192.0.2.10');
assert_equal(partial_snapshot.evidence.skipped, 1);
assert_equal(partial_snapshot.evidence.endpoints[0].host, 'edge.example.test');
assert_equal(partial_snapshot.evidence.endpoints[0].result, 'dns_no_records');
filesystem.set_symlink('/opt/clash/proxy_providers/remote.yaml',
	'/opt/clash/ruleset/routed.yaml');
assert_throws(() => provider_data.collect({ fs: filesystem }, CONFIG, {
	auto_fakeip_whitelist: true, resolve: () => [ '198.51.100.20' ], convert_mrs: () => ''
}), 'INVALID_ARGUMENT');

// Provider files referenced by a freshly installed profile do not exist until
// Mihomo has downloaded them. Absence is a transient input state, while a
// symlink or malformed path above remains a hard validation failure.
let missing_provider_fs = fakes.fs({ '/opt/clash/config.yaml': CONFIG });
assert_throws(() => provider_data.collect({ fs: missing_provider_fs }, CONFIG, {
	auto_fakeip_whitelist: true, resolve: () => [ '198.51.100.20' ], convert_mrs: () => ''
}), 'NOT_FOUND');

function environment(sequence, options) {
	options ??= {};
	let fs = fakes.fs({ '/opt/clash/config.yaml': 'active\n' });
	let clock = fakes.clock(1700000000000), applied = [], logs = [], cursor = 0;
	let runtime = { fs, clock, digest: fakes.digest(fs), random: fakes.entropy() };
	let machine = provider_sync.create({
		runtime, logger: {
			info: (message) => push(logs, { level: 'info', message }),
			warn: (message) => push(logs, { level: 'warn', message })
		},
		collect: () => {
			let value = sequence[cursor++];
			if (value == 'error') die('HEALTH_FAILED');
			if (value == 'missing') die('NOT_FOUND');
			return value;
		},
		ready: options.ready,
		apply: (value) => { push(applied, value); return true; }
	});
	return { fs, clock, machine, applied, logs };
};

let stopped = environment([
	{ server_ips: [ '192.0.2.1' ], fakeip_cidrs: [] }
], { ready: () => false });
stopped.machine.start(); stopped.clock.advance(0);
assert_equal(length(stopped.applied), 0);
assert_equal(length(stopped.logs), 0);
assert_equal(stopped.machine.status().reason, 'waiting_for_mihomo');

let providers_pending = environment([ 'missing' ]);
providers_pending.machine.start(); providers_pending.clock.advance(0);
assert_equal(length(providers_pending.applied), 0);
assert_equal(length(providers_pending.logs), 0);
assert_equal(providers_pending.machine.status().reason, 'waiting_for_providers');

let normal = environment([
	{ server_ips: [ '192.0.2.1' ], fakeip_cidrs: [], evidence: {
		checked_at: 1700000000000, endpoints_total: 1, resolved: 0, skipped: 1,
		endpoints: [ { host: 'await.akira.click', result: 'dns_no_records', addresses: [] } ]
	} },
	{ server_ips: [ '192.0.2.1' ], fakeip_cidrs: [] },
	{ server_ips: [ '192.0.2.2' ], fakeip_cidrs: [] }
]);
assert_equal(normal.machine.start(), true);
normal.clock.advance(0);
assert_equal(length(normal.applied), 1);
assert_equal(normal.logs[0].message,
	'provider-sync: synchronized endpoints=1 fakeip_cidrs=0');
assert_equal(normal.machine.status().reason, 'synchronized');
let diagnostic = normal.machine.diagnostics();
assert_equal(diagnostic.skipped, 1);
assert_equal(diagnostic.endpoints[0].host, 'await.akira.click');
assert_equal(normal.machine.status().reason, 'synchronized',
	'diagnostic DNS observations do not alter provider health');
assert_equal(normal.clock.timers[length(normal.clock.timers) - 1].due,
	normal.clock.now() + 30 * 60 * 1000);
normal.machine.refresh();
normal.clock.advance(0);
assert_equal(length(normal.applied), 1, 'unchanged snapshot is not reconciled');
normal.machine.refresh();
normal.clock.advance(0);
assert_equal(length(normal.applied), 2);

let retained = environment([
	{ server_ips: [ '192.0.2.1' ], fakeip_cidrs: [ '198.18.0.0/16' ] },
	'error'
]);
retained.machine.start(); retained.clock.advance(0);
retained.machine.refresh(); retained.clock.advance(0);
assert_equal(join(',', retained.machine.current().server_ips), '192.0.2.1');
assert_equal(retained.machine.status().reason, 'HEALTH_FAILED');
assert_equal(retained.logs[length(retained.logs) - 1].message,
	'provider-sync: failed code=HEALTH_FAILED');
assert_equal(retained.clock.timers[length(retained.clock.timers) - 1].due,
	retained.clock.now() + 5 * 60 * 1000);

let corrupt_fs = fakes.fs({
	'/opt/clash/provider-sync.json':
		'{"server_ips":["192.0.2.1"],"fakeip_cidrs":[]}',
	'/opt/clash/foreign.json':
		'{"server_ips":["192.0.2.1"],"fakeip_cidrs":[]}'
});
corrupt_fs.set_symlink('/opt/clash/provider-sync.json', '/opt/clash/foreign.json');
let corrupt_clock = fakes.clock(1700000000000);
assert_throws(() => provider_sync.create({
	runtime: { fs: corrupt_fs, clock: corrupt_clock, digest: fakes.digest(corrupt_fs),
		random: fakes.entropy() },
	collect: () => ({ server_ips: [], fakeip_cidrs: [] }), apply: () => true
}), 'CORRUPT_STATE');

print('provider synchronization tests passed\n');
