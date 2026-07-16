import { assert_equal, assert_match, assert_throws, assert_true } from './testlib.uc';
import * as fakes from './fakes.uc';
import * as devices from 'miclash.devices';
import * as schedule from 'miclash.schedule';

const BOOT = '12345678-1234-1234-1234-123456789abc';
const NOW = 1710000000000;
let fs = require('fs');
function enc(value) { return sprintf('%J', value); };
function fixture(name) { return json(fs.readfile('tests/fixtures/devices/' + name + '.json')); };

function runtime(options) {
	let filesystem = fakes.fs({
		'/proc/sys/kernel/random/boot_id': BOOT + '\n',
		'/proc/8123/stat': '8123 (devices test) S ' +
			join(' ', [ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 222 ]) + '\n'
	});
	for (let path in [ '/etc', '/etc/miclash', '/var', '/var/run', '/var/run/miclash' ])
		filesystem.mkdir(path);
	filesystem.set_mode('/etc', 0o755);
	filesystem.set_mode('/etc/miclash', 0o700);
	filesystem.set_mode('/var/run/miclash', 0o700);
	let uci = fakes.uci(options?.uci ?? { miclash: {
		guard: { '.type': 'guard', enabled: options?.guard == null ? '0' : (options.guard ? '1' : '0') }
	} });
	let value = {
		fs: filesystem, digest: fakes.digest(filesystem), clock: fakes.clock(NOW),
		random: fakes.entropy(), uci, uci_fake: uci,
		mutation_lock_self: { boot: BOOT, pid: 8123, start: 222 },
		observers: options?.observers, core_available: options?.core_available ?? true,
		timezones: { resolve: (name) => name == 'Europe/Berlin' ? {
			name: 'Europe/Berlin', from: 1700000000, until: 1735000000, initial_offset: 3600,
			transitions: [ { at: 1711846800, offset: 7200 }, { at: 1729990800, offset: 3600 } ]
		} : { name: 'Etc/UTC', from: 0, until: 4102444800, initial_offset: 0, transitions: [] } },
		device_cache: {}
	};
	return value;
};

function utc_zone() {
	return { name: 'Etc/UTC', from: 0, until: 4102444800, initial_offset: 0, transitions: [] };
};
function berlin_zone() {
	return {
		name: 'Europe/Berlin', from: 1700000000, until: 1735000000, initial_offset: 3600,
		transitions: [ { at: 1711846800, offset: 7200 }, { at: 1729990800, offset: 3600 } ]
	};
};
function spec(days, start, end, timezone) {
	return { days, start, end, timezone: timezone ?? 'Etc/UTC' };
};

// The fake must model native ucode UCI named-section lifecycle exactly.
let uci_contract = fakes.uci({ miclash: {} }), uci_contract_cursor = uci_contract.cursor();
assert_equal(uci_contract_cursor.set('miclash', 'dp-invalid', 'device_policy'), null,
	'invalid native UCI named-section identifiers are rejected');
assert_equal(uci_contract_cursor.set('miclash', 'dp_1_0000000000000001', 'device_policy'), true);
assert_equal(uci_contract_cursor.get_all('miclash', 'dp_1_0000000000000001')['.type'],
	'device_policy', 'three-argument set creates a named typed section');
assert_equal(uci_contract_cursor.set('miclash', 'dp_1_0000000000000001', '.type', 'forged'), null,
	'.type metadata is read-only');
assert_equal(uci_contract_cursor.delete('miclash', 'dp_1_0000000000000001'), true,
	'two-argument delete removes the whole section');
assert_equal(uci_contract_cursor.get_all('miclash', 'dp_1_0000000000000001'), null);

// UTC, exact boundaries, weekdays, overnight association, and closed schemas.
assert_true(schedule.active(spec([ 1 ], '09:00', '10:00'), 1704099600, utc_zone()), 'Monday start inclusive');
assert_true(schedule.active(spec([ 1 ], '09:00', '10:00'), 1704103199, utc_zone()), 'end-minus-one active');
assert_true(!schedule.active(spec([ 1 ], '09:00', '10:00'), 1704103200, utc_zone()), 'end exclusive');
assert_true(schedule.active(spec([ 1 ], '23:00', '02:00'), 1704151800, utc_zone()), 'Monday overnight active Tuesday');
assert_true(!schedule.active(spec([ 2 ], '23:00', '02:00'), 1704151800, utc_zone()), 'overnight belongs to start day');
assert_throws(() => schedule.active(spec([ 1 ], '09:00', '09:00'), 1704099600, utc_zone()), 'INVALID_ARGUMENT');
assert_throws(() => schedule.active({ ...spec([ 1 ], '09:00', '10:00'), extra: true }, 1, utc_zone()), 'INVALID_ARGUMENT');
assert_throws(() => schedule.active(spec([ 0 ], '09:00', '10:00'), 1, utc_zone()), 'INVALID_ARGUMENT');
assert_throws(() => schedule.active(spec([ 1 ], '09:00', '10:00', '../zone'), 1, utc_zone()), 'INVALID_ARGUMENT');
assert_throws(() => schedule.active(spec([ 1 ], '09:00', '10:00'), -1, utc_zone()), 'INVALID_ARGUMENT');

// Real 2024 Europe/Berlin transitions: skipped 02:30 has no active instant;
// repeated 02:30 during the autumn fold is active in both occurrences.
assert_true(!schedule.active(spec([ 7 ], '02:15', '02:45', 'Europe/Berlin'), 1711848600, berlin_zone()),
	'spring gap maps directly to 03:30');
assert_true(schedule.active(spec([ 7 ], '02:15', '02:45', 'Europe/Berlin'), 1729989000, berlin_zone()),
	'first autumn 02:30 active');
assert_true(schedule.active(spec([ 7 ], '02:15', '02:45', 'Europe/Berlin'), 1729992600, berlin_zone()),
	'second autumn 02:30 active');
assert_throws(() => schedule.active(spec([ 7 ], '02:15', '02:45', 'Europe/Berlin'),
	1729992600, { ...berlin_zone(), extra: true }), 'INVALID_ARGUMENT');
let reversed_zone = berlin_zone();
reversed_zone.transitions = [ reversed_zone.transitions[1], reversed_zone.transitions[0] ];
assert_throws(() => schedule.active(spec([ 7 ], '02:15', '02:45', 'Europe/Berlin'),
	1729992600, reversed_zone), 'INVALID_ARGUMENT');

let observed = runtime({ observers: {
	dhcp_leases: () => fixture('dhcp'),
	neighbors: (family) => fixture(family == 'ipv4' ? 'neighbors4' : 'neighbors6')
} });
let found = devices.discover(observed);
assert_equal(length(found), 5, 'three MAC identities and two IP-only identities');
let kitchen = filter(found, (item) => item.mac == 'ac:bb:cc:dd:ee:10')[0];
assert_equal(kitchen.hostname, 'kitchen', 'bounded hostname metadata retained');
assert_equal(length(kitchen.addresses), 2, 'same MAC merges IPv4 and IPv6');
assert_equal(kitchen.addresses[1].address, '2001:db8::10', 'IPv6 canonicalized');
assert_true(kitchen.identity.confidence == 'high', 'globally administered MAC is stable');
let randomized = filter(found, (item) => item.mac == '02:11:22:33:44:55')[0];
assert_equal(randomized.identity.confidence, 'low', 'local MAC explicitly low confidence');
assert_true(!randomized.identity.persistent_policy_eligible, 'random MAC is not silently stable');
let ephemeral = filter(found, (item) => item.mac == null)[0];
assert_equal(ephemeral.identity.kind, 'ip', 'unavailable MAC explicitly ephemeral');
assert_true(!ephemeral.identity.persistent_policy_eligible, 'IP-only identity cannot acquire MAC policy');
let duplicate_host = filter(found, (item) => item.hostname == 'kitchen');
assert_equal(length(duplicate_host), 2, 'duplicate hostname never merges MACs');
assert_true(length(duplicate_host[0].conflicts) > 0, 'duplicate hostname conflict is explicit');
function interface_discovery(order) {
	let entries = map(order, (iface) => ({ dst: '192.168.1.42', dev: iface,
		lladdr: 'ac:bb:cc:dd:ee:42', state: [ 'REACHABLE' ] }));
	return devices.discover(runtime({ observers: {
		dhcp_leases: () => ({ observed_at: 1710000000, data: '' }),
		neighbors: (family) => ({ observed_at: 1710000000,
			data: family == 'ipv4' ? sprintf('%J', entries) : '[]' })
	} }));
};
let multi_interface = interface_discovery([ 'wlan0', 'br-lan' ]);
assert_equal(enc(multi_interface[0].addresses[0].interfaces), enc([ 'br-lan', 'wlan0' ]),
	'address retains canonical multi-interface evidence');
assert_true(length(filter(multi_interface[0].conflicts,
	(item) => item.reason == 'address_interfaces')) == 1, 'multi-interface conflict is explicit');
assert_equal(enc(multi_interface), enc(interface_discovery([ 'br-lan', 'wlan0' ])),
	'observer interface order cannot change discovery output');

// Observer objects are read-only inputs, and a late invalid observer cannot
// partially publish DHCP/neighbor changes into the cache.
let observer_dhcp = fixture('dhcp'), observer_v4 = fixture('neighbors4'), observer_v6 = fixture('neighbors6');
let observer_snapshot = enc([ observer_dhcp, observer_v4, observer_v6 ]);
let immutable_observers = runtime({ observers: {
	dhcp_leases: () => observer_dhcp,
	neighbors: (family) => family == 'ipv4' ? observer_v4 : observer_v6
} });
devices.discover(immutable_observers);
assert_equal(enc([ observer_dhcp, observer_v4, observer_v6 ]), observer_snapshot,
	'discovery never mutates injected observer objects');
let committed_cache = enc(immutable_observers.device_cache);
immutable_observers.observers.dhcp_leases = () => ({ observed_at: 1710000000,
	data: '1710003600 ac:bb:cc:dd:ee:10 192.168.1.200 changed *\n' });
immutable_observers.observers.neighbors = (family) => ({ observed_at: 1710000000,
	data: family == 'ipv4' ? '[]' : '[{"dst":"::","dev":"br-lan","state":["STALE"]}]' });
let late_error = null;
try { devices.discover(immutable_observers); } catch (error) { late_error = error; }
assert_equal(late_error?.code ?? late_error?.message, 'INVALID_RESPONSE');
assert_equal(enc(immutable_observers.device_cache), committed_cache,
	'late observer rejection leaves cache byte-equivalent');
let corrupt_cache = runtime({ observers: {
	dhcp_leases: () => ({ observed_at: 1710000000, data: '' }),
	neighbors: () => ({ observed_at: 1710000000, data: '[]' })
} });
corrupt_cache.device_cache = { extra: true };
let corrupt_cache_before = enc(corrupt_cache.device_cache);
assert_throws(() => devices.discover(corrupt_cache), 'CORRUPT_STATE');
assert_equal(enc(corrupt_cache.device_cache), corrupt_cache_before, 'invalid existing cache is not rewritten');

// Stable MAC retains bounded history when its IP changes; expiry and rollback are deterministic.
observed.observers.dhcp_leases = () => ({ observed_at: 1710000100,
	data: '1710003700 ac:bb:cc:dd:ee:10 192.168.1.77 kitchen *\n' });
observed.observers.neighbors = () => ({ observed_at: 1710000100, data: '[]' });
observed.clock.advance(100000);
let changed = devices.discover(observed);
let changed_kitchen = filter(changed, (item) => item.mac == 'ac:bb:cc:dd:ee:10')[0];
assert_equal(length(changed_kitchen.addresses), 3, 'address history retained under stable MAC');
assert_true(changed_kitchen.addresses[2].current, 'changed address is current');
observed.clock.advance(8 * 86400 * 1000);
observed.observers.dhcp_leases = () => ({ observed_at: 1710691300, data: '' });
observed.observers.neighbors = () => ({ observed_at: 1710691300, data: '[]' });
assert_equal(length(devices.discover(observed)), 0, 'stale devices expire deterministically');
let rollback_cache = enc(observed.device_cache);
assert_throws(() => { observed.clock.advance(-1000); devices.discover(observed); }, 'CORRUPT_STATE');
assert_equal(enc(observed.device_cache), rollback_cache, 'clock rollback cannot mutate cache');

for (let invalid in [
	'ff:ff:ff:ff:ff:ff', '01:00:5e:00:00:01', '00:00:00:00:00:00'
]) {
	let bad = runtime({ observers: {
		dhcp_leases: () => ({ observed_at: 1710000000,
			data: '1710003600 ' + invalid + ' 192.168.1.1 h *\n' }),
		neighbors: () => ({ observed_at: 1710000000, data: '[]' })
	} });
	assert_throws(() => devices.discover(bad), 'INVALID_RESPONSE');
}
let oversized = runtime({ observers: {
	dhcp_leases: () => ({ observed_at: 1710000000, data: sprintf('%0260000d', 0) }),
	neighbors: () => ({ observed_at: 1710000000, data: '[]' })
} });
assert_throws(() => devices.discover(oversized), 'RESPONSE_TOO_LARGE');
let future = runtime({ observers: {
	dhcp_leases: () => ({ observed_at: 1710000001, data: '' }),
	neighbors: () => ({ observed_at: 1710000000, data: '[]' })
} });
assert_throws(() => devices.discover(future), 'INVALID_RESPONSE');
let invalid_mac_observation = runtime({ observers: {
	dhcp_leases: () => ({ observed_at: 1710000000, data: '' }),
	neighbors: (family) => ({ observed_at: 1710000000, data: family == 'ipv4' ?
		'[{"dst":"192.168.1.88","dev":"br-lan","lladdr":"not-a-mac","state":["STALE"]}]' : '[]' })
} });
assert_throws(() => devices.discover(invalid_mac_observation), 'INVALID_RESPONSE');
let unrelated_ip_only = runtime({ observers: {
	dhcp_leases: () => ({ observed_at: 1710000000, data: '' }),
	neighbors: (family) => ({ observed_at: 1710000000, data: family == 'ipv4' ?
		'[{"dst":"192.168.1.88","dev":"br-lan","state":["STALE"]},' +
		'{"dst":"192.168.1.88","dev":"br-lan","state":["STALE"]}]' : '[]' })
} });
let unrelated = devices.discover(unrelated_ip_only);
assert_equal(length(unrelated), 2, 'unrelated observations never merge by shared IP');
assert_true(unrelated[0].identity.value != unrelated[1].identity.value,
	'ephemeral identities carry distinct observation evidence');
for (let hazardous_ip in [ '0.1.2.3', '127.0.0.1', '224.0.0.1', '255.255.255.255',
	'::', 'ff02::1', 'fe80::1%br-lan' ]) {
	let bad_ip = runtime({ observers: {
		dhcp_leases: () => ({ observed_at: 1710000000, data: '' }),
		neighbors: (family) => ({ observed_at: 1710000000, data:
			(family == (index(hazardous_ip, ':') >= 0 ? 'ipv6' : 'ipv4')) ?
				'[{"dst":"' + hazardous_ip + '","dev":"br-lan","state":["STALE"]}]' : '[]' })
	} });
	assert_throws(() => devices.discover(bad_ip), 'INVALID_RESPONSE');
}
function lease_lines(count, duplicate_hostname) {
	let lines = [];
	for (let i = 1; i <= count; i++) {
		let mac_value = duplicate_hostname ? sprintf('ac:bb:cc:dd:00:%02x', i) : 'ac:bb:cc:dd:ee:60';
		push(lines, '1710003600 ' + mac_value + ' 192.168.2.' + i +
			' ' + (duplicate_hostname ? 'crowded' : 'bounded') + ' *');
	}
	return join('\n', lines) + (length(lines) ? '\n' : '');
};
function leases_runtime(count, duplicate_hostname) {
	return runtime({ observers: {
		dhcp_leases: () => ({ observed_at: 1710000000, data: lease_lines(count, duplicate_hostname) }),
		neighbors: () => ({ observed_at: 1710000000, data: '[]' })
	} });
};
let address_max_app = leases_runtime(32, false), address_max = devices.discover(address_max_app);
assert_equal(length(address_max[0].addresses), 32, 'exact address history maximum is accepted');
devices.compile_sets(address_max_app, { timestamp: 1710000000, devices: address_max });
let address_over_app = leases_runtime(33, false), address_over_before = enc(address_over_app.device_cache);
assert_throws(() => devices.discover(address_over_app), 'RESPONSE_TOO_LARGE');
assert_equal(enc(address_over_app.device_cache), address_over_before, 'max+1 address failure is transactional');
let evidence_app = leases_runtime(20, true), evidence_devices = devices.discover(evidence_app);
let crowded_conflict = filter(evidence_devices[0].conflicts,
	(item) => item.reason == 'duplicate_hostname')[0];
assert_equal(length(crowded_conflict.evidence), 16, 'evidence is deterministically bounded');
assert_equal(crowded_conflict.total, 20, 'evidence retains total count');
assert_true(crowded_conflict.truncated, 'evidence truncation is explicit');
devices.compile_sets(evidence_app, { timestamp: 1710000000, devices: evidence_devices });
function many_interfaces(count) {
	let entries = [];
	for (let i = 0; i < count; i++)
		push(entries, { dst: '192.168.3.9', dev: 'if' + i,
			lladdr: 'ac:bb:cc:dd:ee:61', state: [ 'REACHABLE' ] });
	let app = runtime({ observers: {
		dhcp_leases: () => ({ observed_at: 1710000000, data: '' }),
		neighbors: (family) => ({ observed_at: 1710000000,
			data: family == 'ipv4' ? sprintf('%J', entries) : '[]' })
	} });
	return { app, devices: devices.discover(app) };
};
let interface_max = many_interfaces(16);
devices.compile_sets(interface_max.app, { timestamp: 1710000000, devices: interface_max.devices });
let interface_over = many_interfaces(17), interface_over_address = interface_over.devices[0].addresses[0];
assert_equal(length(interface_over_address.interfaces), 16, 'max+1 interfaces truncate to output budget');
assert_equal(interface_over_address.interface_total, 17, 'interface total survives truncation');
assert_true(interface_over_address.interfaces_truncated, 'interface truncation is explicit');
devices.compile_sets(interface_over.app, { timestamp: 1710000000, devices: interface_over.devices });
let far_clock = runtime({ observers: {
	dhcp_leases: () => ({ observed_at: 4102444799, data: '' }),
	neighbors: () => ({ observed_at: 4102444799, data: '[]' })
} });
far_clock.clock.advance(4102444800000 - NOW);
assert_throws(() => devices.discover(far_clock), 'CORRUPT_STATE');

function set_policy(app, value) { return devices.policy_set(app, value); };
let policies = runtime({ guard: false });
let direct = set_policy(policies, { scope: 'device', mac: 'AC:BB:CC:DD:EE:10',
	action: 'direct', schedule: null });
assert_match(direct.id, /^dp_[0-9]+_[0-9a-f]{16}$/, 'opaque generated policy ID');
assert_equal(direct.mac, 'ac:bb:cc:dd:ee:10', 'policy MAC normalized');
assert_equal(direct.revision, 1, 'new policy revision');
assert_equal(policies.uci_fake.commit_calls, 1, 'policy UCI committed');
assert_true(length(policies.fs.calls.rename) >= 2, 'durable journal published around UCI');
assert_throws(() => set_policy(policies, { scope: 'device', mac: direct.mac,
	action: 'proxy', schedule: null }), 'VALIDATION_FAILED');
assert_throws(() => set_policy(policies, { id: direct.id, expected_revision: 2,
	scope: 'device', mac: direct.mac, action: 'proxy', schedule: null }), 'BUSY');
let updated = set_policy(policies, { id: direct.id, expected_revision: 1,
	scope: 'device', mac: direct.mac, action: 'proxy', schedule: null });
assert_equal(updated.revision, 2, 'CAS update increments revision');
assert_equal(length(devices.policy_list(policies)), 1, 'policy survives fresh UCI cursor/restart-style load');
assert_throws(() => devices.policy_delete(policies, direct.id, 1), 'BUSY');
assert_true(devices.policy_delete(policies, direct.id, 2), 'CAS delete succeeds');
assert_equal(length(devices.policy_list(policies)), 0, 'deleted policy absent');
policies.fs.writefile('/etc/miclash/device-policies.json', sprintf('%J\n', {
	version: 1, owner: 'miclash-device-policies', state: 'stable', policies: [], extra: true
}));
assert_throws(() => devices.policy_list(policies), 'CORRUPT_STATE');
function persisted_policies(count) {
	let sections = { guard: { '.type': 'guard', enabled: '0' } };
	for (let i = 0; i < count; i++) {
		let id = 'dp_1_' + sprintf('%016x', i + 1);
		sections[id] = { '.type': 'device_policy', revision: '1', scope: 'device',
			mac: sprintf('ac:bb:cc:dd:%02x:%02x', int(i / 256), i % 256),
			action: 'proxy', schedule: '' };
	}
	return runtime({ guard: false, uci: { miclash: sections } });
};
assert_equal(length(devices.policy_list(persisted_policies(256))), 256,
	'exact persisted policy maximum is accepted');
let too_many_policies = persisted_policies(257);
assert_throws(() => devices.policy_list(too_many_policies), 'RESPONSE_TOO_LARGE');
assert_equal(too_many_policies.uci_fake.commit_calls, 0, 'oversized UCI state cannot mutate');
let oversized_option = persisted_policies(1);
oversized_option.uci_fake.values.miclash['dp_1_0000000000000001'].schedule = sprintf('%0513d', 0);
assert_throws(() => devices.policy_list(oversized_option), 'RESPONSE_TOO_LARGE');
let journal_bound = runtime({ guard: false });
let stable_empty = sprintf('%J', { version: 1, owner: 'miclash-device-policies',
	state: 'stable', policies: [] });
journal_bound.fs.writefile('/etc/miclash/device-policies.json', stable_empty +
	sprintf('%' + (524288 - length(stable_empty)) + 's', ''));
assert_equal(length(devices.policy_list(journal_bound)), 0, 'exact raw journal maximum is accepted');
journal_bound.fs.writefile('/etc/miclash/device-policies.json', stable_empty +
	sprintf('%' + (524289 - length(stable_empty)) + 's', ''));
assert_throws(() => devices.policy_list(journal_bound), 'RESPONSE_TOO_LARGE');
assert_equal(journal_bound.uci_fake.commit_calls, 0, 'oversized journal cannot mutate UCI');
assert_throws(() => set_policy(runtime({ guard: true }), { scope: 'device',
	mac: 'ac:bb:cc:dd:ee:10', action: 'direct', schedule: null }), 'VALIDATION_FAILED');

// Device > interface > global, inactive schedules inherit, and block is explicit.
let precedence = runtime({ guard: false });
let global_policy = set_policy(precedence, { scope: 'global', action: 'proxy', schedule: null });
let interface_policy = set_policy(precedence, { scope: 'interface', interface: 'br-lan',
	action: 'direct', schedule: null });
let device_policy = set_policy(precedence, { scope: 'device', mac: 'ac:bb:cc:dd:ee:10',
	action: 'block', schedule: null });
let decision = devices.effective(precedence, { mac: 'ac:bb:cc:dd:ee:10', interface: 'br-lan', timestamp: 1710000000 });
assert_equal(decision.action, 'block', 'active explicit device BLOCK wins');
assert_equal(decision.policy_id, device_policy.id, 'device provenance retained');
set_policy(precedence, { id: device_policy.id, expected_revision: 1, scope: 'device',
	mac: device_policy.mac, action: 'inherit', schedule: null });
assert_equal(devices.effective(precedence, { mac: device_policy.mac, interface: 'br-lan',
	timestamp: 1710000000 }).policy_id, interface_policy.id, 'inherit continues to interface');
set_policy(precedence, { id: interface_policy.id, expected_revision: 1, scope: 'interface',
	interface: 'br-lan', action: 'inherit', schedule: null });
assert_equal(devices.effective(precedence, { mac: device_policy.mac, interface: 'br-lan',
	timestamp: 1710000000 }).policy_id, global_policy.id, 'inherit continues to global');
let scheduled = set_policy(precedence, { id: device_policy.id, expected_revision: 2, scope: 'device',
	mac: device_policy.mac, action: 'block',
	schedule: spec([ 1 ], '09:00', '10:00') });
assert_equal(devices.effective(precedence, { mac: device_policy.mac, interface: 'br-lan',
	timestamp: 1710000000 }).policy_id, global_policy.id, 'inactive schedule behaves as inherit');

function precedence_runtime(device_action, interface_action, global_action, guard_enabled) {
	return runtime({ guard: guard_enabled, uci: { miclash: {
		guard: { '.type': 'guard', enabled: guard_enabled ? '1' : '0' },
		'dp_1_0000000000000001': { '.type': 'device_policy', revision: '1', scope: 'device',
			mac: 'ac:bb:cc:dd:ee:10', action: device_action, schedule: '' },
		'dp_1_0000000000000002': { '.type': 'device_policy', revision: '1', scope: 'interface',
			interface: 'br-lan', action: interface_action, schedule: '' },
		'dp_1_0000000000000003': { '.type': 'device_policy', revision: '1', scope: 'global',
			action: global_action, schedule: '' }
	} } });
};
for (let device_action in [ 'block', 'proxy', 'direct', 'inherit' ])
	for (let interface_action in [ 'block', 'proxy', 'direct', 'inherit' ])
		for (let global_action in [ 'block', 'proxy', 'direct', 'inherit' ]) {
			let expected = (device_action == 'block' || interface_action == 'block' ||
				global_action == 'block') ? 'block' :
				(device_action != 'inherit' ? device_action :
				 (interface_action != 'inherit' ? interface_action : global_action));
			let table_decision = devices.effective(
				precedence_runtime(device_action, interface_action, global_action, false),
				{ mac: 'ac:bb:cc:dd:ee:10', interface: 'br-lan', timestamp: 1710000000 });
			assert_equal(table_decision.action, expected,
				'precedence table ' + device_action + '/' + interface_action + '/' + global_action);
		}
let guard_lower_block = devices.effective(precedence_runtime('direct', 'inherit', 'block', true),
	{ mac: 'ac:bb:cc:dd:ee:10', interface: 'br-lan', timestamp: 1710000000 });
assert_equal(guard_lower_block.action, 'block', 'Guard-safe DIRECT override cannot mask lower BLOCK');
assert_equal(guard_lower_block.policy_id, 'dp_1_0000000000000003', 'BLOCK provenance is explicit');
let all_blocks = devices.effective(precedence_runtime('block', 'block', 'block', false),
	{ mac: 'ac:bb:cc:dd:ee:10', interface: 'br-lan', timestamp: 1710000000 });
assert_equal(all_blocks.policy_id, 'dp_1_0000000000000001', 'most-specific BLOCK provenance wins');
let interface_candidates = runtime({ guard: false, uci: { miclash: {
	guard: { '.type': 'guard', enabled: '0' },
	'dp_1_0000000000000004': { '.type': 'device_policy', revision: '1', scope: 'interface',
		interface: 'wlan0', action: 'direct', schedule: '' },
	'dp_1_0000000000000005': { '.type': 'device_policy', revision: '1', scope: 'interface',
		interface: 'br-lan', action: 'proxy', schedule: '' }
} } });
let interface_forward = devices.effective(interface_candidates, { mac: 'ac:bb:cc:dd:ee:10',
	interfaces: [ 'wlan0', 'br-lan' ], timestamp: 1710000000 });
let interface_reverse = devices.effective(interface_candidates, { mac: 'ac:bb:cc:dd:ee:10',
	interfaces: [ 'br-lan', 'wlan0' ], timestamp: 1710000000 });
assert_equal(interface_forward.action, 'proxy', 'multi-interface fallback uses conservative action');
assert_equal(enc(interface_forward), enc(interface_reverse), 'interface fallback is order-independent');
assert_equal(interface_forward.policy_id, 'dp_1_0000000000000005',
	'equal/action provenance is canonical');
let restarted = runtime({ uci: precedence.uci_fake.values, guard: false });
assert_throws(() => set_policy(restarted, { scope: 'device', mac: device_policy.mac,
	action: 'proxy', schedule: null }), 'VALIDATION_FAILED');

// Tampered persisted DIRECT never bypasses Guard; unavailable core becomes BLOCK.
let guarded = runtime({ guard: true, core_available: false, uci: { miclash: {
	guard: { '.type': 'guard', enabled: '1' },
	'dp_1_0000000000000001': { '.type': 'device_policy', revision: '1', scope: 'device',
		mac: 'ac:bb:cc:dd:ee:10', action: 'direct', schedule: '' }
} } });
assert_equal(devices.effective(guarded, { mac: 'ac:bb:cc:dd:ee:10', interface: 'br-lan',
	timestamp: 1710000000 }).action, 'block', 'tampered direct fails closed');
let extra_uci = runtime({ uci: { miclash: {
	guard: { '.type': 'guard', enabled: '0' },
	'dp_1_0000000000000001': { '.type': 'device_policy', revision: '1', scope: 'device',
		mac: 'ac:bb:cc:dd:ee:10', action: 'proxy', schedule: '', extra: 'untrusted' }
} } });
assert_throws(() => devices.policy_list(extra_uci), 'CORRUPT_STATE');
let unknown_guard = runtime({ core_available: true, uci: { miclash: {
	guard: { '.type': 'guard', enabled: 'maybe' },
	'dp_1_0000000000000001': { '.type': 'device_policy', revision: '1', scope: 'device',
		mac: 'ac:bb:cc:dd:ee:10', action: 'direct', schedule: '' }
} } });
let unknown_decision = devices.effective(unknown_guard, { mac: 'ac:bb:cc:dd:ee:10',
	interface: 'br-lan', timestamp: 1710000000 });
assert_equal(unknown_decision.action, 'proxy', 'unknown Guard cannot compile direct');
assert_equal(unknown_decision.safety, 'guard_safe_override', 'Guard-safe override provenance explicit');
assert_throws(() => set_policy(unknown_guard, { scope: 'device', mac: 'ac:bb:cc:dd:ee:12',
	action: 'direct', schedule: null }), 'VALIDATION_FAILED');
let guard_race = runtime({ guard: false });
guard_race.uci_fake.on_cursor = (calls) => {
	if (calls == 2) guard_race.uci_fake.values.miclash.guard.enabled = '1';
};
assert_throws(() => set_policy(guard_race, { scope: 'device', mac: 'ac:bb:cc:dd:ee:12',
	action: 'direct', schedule: null }), 'VALIDATION_FAILED');
// The mutation lock consumes entropy call 1; generated policy suffix starts at 2.
let collision_id = 'dp_' + NOW + '_0000000000000002';
let collision = runtime({ guard: false, uci: { miclash: {
	guard: { '.type': 'guard', enabled: '0' },
	[collision_id]: { '.type': 'device_policy', revision: '1', scope: 'device',
		mac: 'ac:bb:cc:dd:ee:13', action: 'proxy', schedule: '' }
} } });
let collision_created = set_policy(collision, { scope: 'device', mac: 'ac:bb:cc:dd:ee:14',
	action: 'proxy', schedule: null });
assert_true(collision_created.id != collision_id, 'generated ID collision retries instead of overwriting');
assert_equal(length(devices.policy_list(collision)), 2, 'ID collision preserves existing policy');

// Compilation is structured, deterministic, disjoint, conservative on shared IP, and invokes no firewall.
set_policy(precedence, { id: scheduled.id, expected_revision: scheduled.revision, scope: 'device',
	mac: scheduled.mac, action: 'block', schedule: null });
precedence.process = fakes.process();
let compile_input = {
	timestamp: 1710000000,
	devices: [
		{ identity: { kind: 'mac', value: 'ac:bb:cc:dd:ee:10', confidence: 'high', persistent_policy_eligible: true,
			reason: 'stable_mac' },
			mac: 'ac:bb:cc:dd:ee:10', hostname: 'one', last_seen: 1710000000, sources: [ 'neighbor' ],
			interfaces: [ 'br-lan' ], interface_total: 1, interfaces_truncated: false,
			conflicts: [], addresses: [ { address: '192.168.1.50', family: 'ipv4', current: true,
				last_seen: 1710000000, source: 'neighbor', interfaces: [ 'br-lan' ],
				interface_total: 1, interfaces_truncated: false } ] },
		{ identity: { kind: 'mac', value: 'ac:bb:cc:dd:ee:11', confidence: 'high', persistent_policy_eligible: true,
			reason: 'stable_mac' },
			mac: 'ac:bb:cc:dd:ee:11', hostname: 'two', last_seen: 1710000000, sources: [ 'neighbor' ],
			interfaces: [ 'br-lan' ], interface_total: 1, interfaces_truncated: false,
			conflicts: [], addresses: [ { address: '192.168.1.50', family: 'ipv4', current: true,
				last_seen: 1710000000, source: 'neighbor', interfaces: [ 'br-lan' ],
				interface_total: 1, interfaces_truncated: false } ] }
	]
};
let compiled = devices.compile_sets(precedence, compile_input);
assert_equal(enc(compiled.ipv4.block), enc([ '192.168.1.50' ]), 'shared IP resolves conservatively to BLOCK');
assert_equal(length(compiled.ipv4.proxy), 0, 'compiled sets disjoint');
assert_true(length(compiled.reasoning) > 0, 'shared-IP conflict reasoning explicit');
assert_equal(length(precedence.process.calls), 0, 'compiler never calls firewall/processes');
assert_equal(enc(compiled), enc(devices.compile_sets(precedence, compile_input)),
	'compiled output deterministic');
function compiled_device(mac_value, iface, duplicate) {
	let address_value = { address: '192.168.9.9', family: 'ipv4', current: true,
		last_seen: 1710000000, source: 'neighbor', interfaces: [ iface ],
		interface_total: 1, interfaces_truncated: false };
	return { identity: { kind: 'mac', value: mac_value, confidence: 'high',
		persistent_policy_eligible: true, reason: 'stable_mac' }, mac: mac_value,
		hostname: null, last_seen: 1710000000, sources: [ 'neighbor' ], interfaces: [ iface ],
		interface_total: 1, interfaces_truncated: false, conflicts: [],
		addresses: duplicate ? [ address_value, json(enc(address_value)) ] : [ address_value ] };
};
function deterministic_app(reverse) {
	let sections = { guard: { '.type': 'guard', enabled: '0' } };
	let device_section = { '.type': 'device_policy', revision: '1', scope: 'device',
		mac: 'ac:bb:cc:dd:ee:70', action: 'proxy', schedule: '' };
	let interface_section = { '.type': 'device_policy', revision: '1', scope: 'interface',
		interface: 'br-alt', action: 'proxy', schedule: '' };
	if (reverse) {
		sections['dp_1_0000000000000002'] = interface_section;
		sections['dp_1_0000000000000003'] = device_section;
	}
	else {
		sections['dp_1_0000000000000003'] = device_section;
		sections['dp_1_0000000000000002'] = interface_section;
	}
	return runtime({ guard: false, uci: { miclash: sections } });
};
let deterministic_one = compiled_device('ac:bb:cc:dd:ee:70', 'wlan0', true);
let deterministic_two = compiled_device('ac:bb:cc:dd:ee:71', 'br-alt', false);
let deterministic_a = devices.compile_sets(deterministic_app(false), {
	timestamp: 1710000000, devices: [ deterministic_one, deterministic_two ] });
let reversed_one = json(enc(deterministic_one));
reversed_one.addresses = [ reversed_one.addresses[1], reversed_one.addresses[0] ];
let deterministic_b = devices.compile_sets(deterministic_app(true), {
	timestamp: 1710000000, devices: [ deterministic_two, reversed_one ] });
assert_equal(enc(deterministic_a), enc(deterministic_b),
	'device/address/policy permutations compile byte-identically');
assert_equal(deterministic_a.reasoning[0].policy_id, 'dp_1_0000000000000003',
	'equal-action shared IP chooses more-specific policy provenance');
assert_equal(enc(deterministic_a.reasoning[0].identities),
	enc([ 'ac:bb:cc:dd:ee:70', 'ac:bb:cc:dd:ee:71' ]), 'identities are sorted unique');
let duplicate_only = devices.compile_sets(deterministic_app(false), {
	timestamp: 1710000000, devices: [ deterministic_one ] });
assert_true(!duplicate_only.reasoning[0].conflict,
	'duplicate same-device address is deduplicated, not a shared-identity conflict');
let uncanonical = json(enc(deterministic_one));
uncanonical.interfaces = [ 'wlan0', 'br-lan', 'wlan0' ];
uncanonical.interface_total = 2;
uncanonical.addresses[0].interfaces = [ 'wlan0', 'br-lan', 'wlan0' ];
uncanonical.addresses[0].interface_total = 2;
let canonicalized_compile = devices.compile_sets(deterministic_app(false), {
	timestamp: 1710000000, devices: [ uncanonical ] });
assert_equal(enc(canonicalized_compile), enc(duplicate_only),
	'compile canonicalizes duplicate and unsorted interface metadata');
let malformed_compile = json(enc(compile_input));
malformed_compile.devices[0].identity.extra = 'untrusted';
assert_throws(() => devices.compile_sets(precedence, malformed_compile), 'INVALID_ARGUMENT');
