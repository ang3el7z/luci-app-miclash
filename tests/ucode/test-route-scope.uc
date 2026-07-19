import * as route_test from 'miclash.route-test';
import { assert_equal } from 'testlib';

assert_equal(join(',', route_test.proxy_servers(
	'proxy-defaults: &defaults\n  type: ss\nproxies:\n' +
	'  - name: inherited\n    <<: *defaults\n    server: merged.example.test\n')),
	'merged.example.test', 'YAML merge keys preserve proxy endpoint discovery');

let observed = { routing: {
	rules: [
		{ family: 'ipv4', priority: 1000, mark: '0x1', mask: '0xffffffff',
			table: 100, protocol: 242, owned: true },
		{ family: 'ipv6', priority: 1000, mark: '0x1', mask: '0xffffffff',
			table: 100, protocol: 242, owned: true }
	],
	routes: [
		{ family: 'ipv4', table: 100, kind: 'local', destination: 'default',
			device: 'lo', protocol: 242, owned: true },
		{ family: 'ipv6', table: 100, kind: 'local', destination: 'default',
			device: 'lo', protocol: 242, owned: true }
	],
	interfaces: { 'clash-tun': false },
	ownership: { trusted: true, status: 'trusted', committed: {
		rules: [
			{ family: 'ipv4', priority: 1000, mark: '0x1', mask: '0xffffffff', table: 100 },
			{ family: 'ipv6', priority: 1000, mark: '0x1', mask: '0xffffffff', table: 100 }
		],
		routes: [
			{ family: 'ipv4', table: 100, kind: 'local', destination: 'default', device: 'lo' },
			{ family: 'ipv6', table: 100, kind: 'local', destination: 'default', device: 'lo' }
		]
	}, transition: null }
} };

function decision(device_decision, interface_decision, guard_enabled, mihomo_decision) {
	let runtime = { http: { request: () => ({ status: 200, body: sprintf('%J', {
		rules: [ { index: 0, type: 'MATCH', payload: '', proxy: mihomo_decision, size: -1,
			extra: { disabled: false, hitCount: 0, hitAt: '', missCount: 0, missAt: '' } } ]
	}) }) }, process: { run: () => die('unexpected process') },
		paths: { tmp: '/tmp/miclash' }, random: { bytes: () => '0123456789abcdef' } };
	let engine = route_test.create({ runtime, profile: 'config.yaml',
		config_content: 'external-controller: 127.0.0.1:9090\n',
		desired: () => ({ guard: { enabled: guard_enabled },
			devices: device_decision == null ? [] :
				[ { mac: 'aa:bb:cc:dd:ee:ff', decision: device_decision } ],
			interfaces: [ { name: 'br-lan', decision: interface_decision } ],
			proxy_servers: [] }),
		observed: () => observed, dns_answers: () => [] });
	return engine.run({ target: '192.0.2.10', device: 'aa:bb:cc:dd:ee:ff',
		interface: 'br-lan' }).decision;
};

assert_equal(decision('DIRECT', 'PROXY', true, 'PROXY'), 'DIRECT',
	'Direct device policy bypasses Guard inside interface scope');
assert_equal(decision('BLOCK', 'DIRECT', true, 'PROXY'), 'DIRECT',
	'outside-scope interface bypasses Block and Guard');
assert_equal(decision('BLOCK', 'PROXY', true, 'PROXY'), 'BLOCK',
	'Block wins inside interface scope');
assert_equal(decision(null, 'PROXY', true, 'DIRECT'), 'BLOCK',
	'Guard remains fail-closed for inherited direct routing inside scope');
assert_equal(decision(null, 'PROXY', false, 'DIRECT'), 'DIRECT',
	'current Mihomo rule metadata does not hide a valid routing decision');

print('route scope tests passed\n');
