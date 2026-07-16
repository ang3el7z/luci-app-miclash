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
		timezones: options?.timezones ?? { list: () => [ 'UTC', 'Etc/UTC', 'Europe/Berlin' ], resolve: (name) => name == 'Europe/Berlin' ? {
			name: 'Europe/Berlin', from: 1700000000, until: 1735000000, initial_offset: 3600,
			transitions: [ { at: 1711846800, offset: 7200 }, { at: 1729990800, offset: 3600 } ]
		} : (name == 'UTC' || name == 'Etc/UTC' ? { name, from: 0, until: 4102444800,
			initial_offset: 0, transitions: [] } : null) },
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
assert_true(schedule.active(spec([ 1 ], '09:00', '10:00', 'UTC'), 1704099600,
	{ ...utc_zone(), name: 'UTC' }), 'exact UTC name is accepted');
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

function corrupt_cached_record(label, mutate) {
	let box = runtime({ observers: {
		dhcp_leases: () => ({ observed_at: 1710000000, data: '' }),
		neighbors: () => ({ observed_at: 1710000000, data: '[]' })
	} });
	box.device_cache = json(committed_cache);
	let item = box.device_cache.devices[keys(box.device_cache.devices)[0]];
	mutate(item.addresses[0], item);
	let before = enc(box.device_cache);
	assert_throws(() => devices.discover(box), 'CORRUPT_STATE', label);
	assert_equal(enc(box.device_cache), before, label + ' preserves cache bytes');
};
for (let sample in [
	[ 'address extra key', (record) => record.extra = true ],
	[ 'address missing field', (record) => delete record.source ],
	[ 'family mismatch', (record) => record.family = record.family == 'ipv4' ? 'ipv6' : 'ipv4' ],
	[ 'noncanonical address', (record) => { record.address = '192.168.001.010'; record.family = 'ipv4'; } ],
	[ 'hazardous cached address', (record) => { record.address = '127.0.0.1'; record.family = 'ipv4'; } ],
	[ 'nonboolean current', (record) => record.current = 1 ],
	[ 'negative address timestamp', (record) => record.last_seen = -1 ],
	[ 'future address timestamp', (record) => record.last_seen = 1710000001 ],
	[ 'invalid address source', (record) => record.source = 'foreign' ],
	[ 'duplicate address interfaces', (record) => {
		record.interfaces = [ 'br-lan', 'br-lan' ]; record.interface_total = 2;
	} ],
	[ 'unsorted address interfaces', (record) => {
		record.interfaces = [ 'wlan0', 'br-lan' ]; record.interface_total = 2;
	} ],
	[ 'address interface counter mismatch', (record) => record.interface_total = 3 ],
	[ 'address interface counter below retained', (record) => record.interface_total = 0 ],
	[ 'address interface counter over bound', (record) => record.interface_total = 513 ],
	[ 'address truncation mismatch', (record) => record.interfaces_truncated = true ],
	[ 'address truncation wrong type', (record) => record.interfaces_truncated = 'true' ],
	[ 'cached DHCP address retains interface evidence', (record, item) => {
		item.sources = [ 'dhcp', 'neighbor' ]; record.source = 'dhcp';
		record.interfaces = [ 'br-lan' ]; record.interface_total = 1;
		record.interfaces_truncated = false;
	} ],
	[ 'cached neighbor address has no interface evidence', (record, item) => {
		item.sources = [ 'dhcp', 'neighbor' ]; record.source = 'neighbor';
		record.interfaces = []; record.interface_total = 0; record.interfaces_truncated = false;
	} ],
	[ 'cached neighbor address has short truncated evidence', (record, item) => {
		item.sources = [ 'dhcp', 'neighbor' ]; record.source = 'neighbor';
		record.interfaces = [ 'br-lan' ]; record.interface_total = 17;
		record.interfaces_truncated = true;
	} ],
	[ 'duplicate device sources', (record, item) => item.sources = [ 'neighbor', 'neighbor' ] ],
	[ 'unsorted device sources', (record, item) => item.sources = [ 'neighbor', 'dhcp' ] ],
	[ 'device extra key', (record, item) => item.extra = true ],
	[ 'identity extra key', (record, item) => item.identity.extra = true ],
	[ 'identity reason mismatch', (record, item) => item.identity.reason = 'locally_administered_mac' ],
	[ 'device interface counter mismatch', (record, item) => item.interface_total = 17 ],
	[ 'device truncation wrong type', (record, item) => item.interfaces_truncated = 'false' ],
	[ 'device has short truncated interface evidence', (record, item) => {
		item.interfaces = [ 'br-lan' ]; item.interface_total = 17;
		item.interfaces_truncated = true;
	} ],
	[ 'conflict extra key', (record, item) => {
		item.conflicts[0] ??= { reason: 'address_interfaces', subject: record.address,
			evidence: [ 'br-lan' ], total: 1, truncated: false };
		item.conflicts[0].extra = true;
	} ],
	[ 'conflict evidence counter mismatch', (record, item) => {
		item.conflicts[0] ??= { reason: 'address_interfaces', subject: record.address,
			evidence: [ 'br-lan' ], total: 1, truncated: false };
		item.conflicts[0].total++;
	} ],
	[ 'conflict invalid reason', (record, item) => {
		item.conflicts[0] ??= { reason: 'address_interfaces', subject: record.address,
			evidence: [ 'br-lan' ], total: 1, truncated: false };
		item.conflicts[0].reason = 'foreign';
	} ],
	[ 'conflict duplicate evidence', (record, item) => {
		item.conflicts[0] = { reason: 'address_interfaces', subject: record.address,
			evidence: [ 'br-lan', 'br-lan' ], total: 2, truncated: false };
	} ],
	[ 'conflict identity evidence is not canonical', (record, item) => {
		item.sources = [ 'dhcp', 'neighbor' ]; item.hostname ??= 'cached';
		item.conflicts[0] = { reason: 'duplicate_hostname', subject: item.hostname,
			evidence: [ 'bogus', 'mac:' + item.mac ], total: 2, truncated: false };
	} ]
]) corrupt_cached_record(sample[0], sample[1]);

function hostile_cache() {
	let box = runtime({ observers: {
		dhcp_leases: () => ({ observed_at: 1710000000, data: '' }),
		neighbors: () => ({ observed_at: 1710000000, data: '[]' })
	} });
	box.device_cache = json(committed_cache); return box;
};
let hostile_graph = {};
for (let depth = 0; depth < 1000; depth++) hostile_graph = { nested: hostile_graph };
let hostile_array_cache = hostile_cache(), hostile_array_original = hostile_array_cache.device_cache;
let hostile_array_item = hostile_array_cache.device_cache.devices[keys(hostile_array_cache.device_cache.devices)[0]];
hostile_array_item.addresses = [];
for (let at = 0; at < 33; at++) push(hostile_array_item.addresses, hostile_graph);
assert_throws(() => devices.discover(hostile_array_cache), 'CORRUPT_STATE',
	'cache address count maps to CORRUPT_STATE before nested traversal');
assert_true(hostile_array_cache.device_cache == hostile_array_original,
	'hostile cache reference is never replaced or serialized');
let hostile_string_cache = hostile_cache(), hostile_string_original = hostile_string_cache.device_cache;
let hostile_string_item = hostile_string_cache.device_cache.devices[keys(hostile_string_cache.device_cache.devices)[0]];
hostile_string_item.identity.extra = sprintf('%0300000d', 0);
assert_throws(() => devices.discover(hostile_string_cache), 'CORRUPT_STATE',
	'cache nested oversized string maps to CORRUPT_STATE before copying');
assert_true(hostile_string_cache.device_cache == hostile_string_original,
	'oversized nested cache string leaves the original object unpublished');
let hostile_hook_cache = hostile_cache(), hostile_hook_original = hostile_hook_cache.device_cache;
let hostile_hook_item = hostile_hook_cache.device_cache.devices[keys(hostile_hook_cache.device_cache.devices)[0]];
hostile_hook_item.identity.extra = { toJSON: () => die('raw cache serializer invoked') };
assert_throws(() => devices.discover(hostile_hook_cache), 'CORRUPT_STATE',
	'toJSON-like cache extras reject by schema without invocation');
assert_true(hostile_hook_cache.device_cache == hostile_hook_original);

function hostname_history(order) {
	let lines = map(order, (host) => '1710003600 ac:bb:cc:dd:ee:44 192.168.1.44 ' + host + ' *');
	return devices.discover(runtime({ observers: {
		dhcp_leases: () => ({ observed_at: 1710000000, data: join('\n', lines) + '\n' }),
		neighbors: () => ({ observed_at: 1710000000, data: '[]' })
	} }))[0];
};
let hostname_abc = hostname_history([ 'alpha', 'beta', 'gamma' ]);
let hostname_cab = hostname_history([ 'gamma', 'alpha', 'beta' ]);
assert_equal(enc(hostname_abc), enc(hostname_cab), 'hostname history permutations are byte-identical');
let hostname_conflict = filter(hostname_abc.conflicts, (item) => item.reason == 'hostname_changed')[0];
assert_equal(hostname_conflict.subject, 'mac:ac:bb:cc:dd:ee:44',
	'hostname conflict subject is the stable identity');
assert_equal(enc(hostname_conflict.evidence), enc([ 'alpha', 'beta', 'gamma' ]));
assert_equal(hostname_conflict.total, 3);
assert_true(!hostname_conflict.truncated);

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
	'::', '::1', 'ff02::1', 'fe80::1%br-lan',
	'::ffff:0.0.0.0', '::ffff:127.0.0.1', '::ffff:7f00:1',
	'0:0:0:0:0:ffff:e000:1', '::ffff:255.255.255.255',
	'::192.168.1.1', '::c0a8:101' ]) {
	let bad_ip = runtime({ observers: {
		dhcp_leases: () => ({ observed_at: 1710000000, data: '' }),
		neighbors: (family) => ({ observed_at: 1710000000, data:
			(family == (index(hazardous_ip, ':') >= 0 ? 'ipv6' : 'ipv4')) ?
				'[{"dst":"' + hazardous_ip + '","dev":"br-lan","state":["STALE"]}]' : '[]' })
	} });
	assert_throws(() => devices.discover(bad_ip), 'INVALID_RESPONSE');
}
function discovered_ipv6(value) {
	let box = runtime({ observers: {
		dhcp_leases: () => ({ observed_at: 1710000000, data: '' }),
		neighbors: (family) => ({ observed_at: 1710000000, data: family == 'ipv6' ?
			'[{' + '"dst":"' + value + '","dev":"br-lan",' +
			'"lladdr":"ac:bb:cc:dd:ee:45","state":["REACHABLE"]}]' : '[]' })
	} });
	return devices.discover(box)[0].addresses[0].address;
};
assert_equal(discovered_ipv6('fd00::1'), 'fd00::1', 'ULA remains valid');
assert_equal(discovered_ipv6('fe80::1'), 'fe80::1', 'link-local with interface evidence remains valid');
assert_equal(discovered_ipv6('::ffff:192.168.1.10'), '::ffff:c0a8:10a',
	'valid mapped IPv4 canonicalizes as IPv6');
assert_equal(discovered_ipv6('::ffff:c0a8:10a'), discovered_ipv6('0:0:0:0:0:ffff:192.168.1.10'),
	'mapped dotted and hexadecimal forms canonicalize equivalently');
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
function many_interfaces(count, reverse) {
	let entries = [];
	for (let i = 0; i < count; i++)
		push(entries, { dst: '192.168.3.9', dev: 'if' + i,
			lladdr: 'ac:bb:cc:dd:ee:61', state: [ 'REACHABLE' ] });
	if (reverse) entries = sort(entries, (a, b) => a.dev < b.dev ? 1 : -1);
	let app = runtime({ observers: {
		dhcp_leases: () => ({ observed_at: 1710000000, data: '' }),
		neighbors: (family) => ({ observed_at: 1710000000,
			data: family == 'ipv4' ? sprintf('%J', entries) : '[]' })
	} });
	return { app, devices: devices.discover(app) };
};
let interface_max = many_interfaces(16);
devices.policy_set(interface_max.app, { scope: 'global', action: 'proxy', schedule: null });
let interface_max_compiled = devices.compile_sets(interface_max.app,
	{ timestamp: 1710000000, devices: interface_max.devices });
assert_equal(enc(interface_max_compiled.ipv4.proxy), enc([ '192.168.3.9' ]),
	'exact interface evidence maximum follows the policy normally');
let interface_over = many_interfaces(17), interface_over_address = interface_over.devices[0].addresses[0];
assert_equal(length(interface_over_address.interfaces), 16, 'max+1 interfaces truncate to output budget');
assert_equal(interface_over_address.interface_total, 17, 'interface total survives truncation');
assert_true(interface_over_address.interfaces_truncated, 'interface truncation is explicit');
devices.policy_set(interface_over.app, { scope: 'global', action: 'proxy', schedule: null });
let interface_over_compiled = devices.compile_sets(interface_over.app,
	{ timestamp: 1710000000, devices: interface_over.devices });
assert_equal(enc(interface_over_compiled.ipv4.block), enc([ '192.168.3.9' ]),
	'truncated interface evidence enforces conservative BLOCK');
assert_equal(length(interface_over_compiled.ipv4.proxy), 0, 'truncated interface BLOCK stays disjoint');
assert_equal(interface_over_compiled.reasoning[0].safety, 'interface_evidence_truncated',
	'truncation safety provenance is explicit');
let interface_over_reverse = many_interfaces(17, true);
devices.policy_set(interface_over_reverse.app, { scope: 'global', action: 'proxy', schedule: null });
assert_equal(enc(interface_over_compiled), enc(devices.compile_sets(interface_over_reverse.app,
	{ timestamp: 1710000000, devices: interface_over_reverse.devices })),
	'truncated interface enforcement is observer-order independent');
let explicit_truncated = devices.effective(interface_over.app, { mac: 'ac:bb:cc:dd:ee:61',
	interfaces: interface_over_address.interfaces, interface_total: 17,
	interfaces_truncated: true, timestamp: 1710000000 });
assert_equal(explicit_truncated.action, 'block');
assert_equal(explicit_truncated.safety, 'interface_evidence_truncated');
let far_clock = runtime({ observers: {
	dhcp_leases: () => ({ observed_at: 4102444799, data: '' }),
	neighbors: () => ({ observed_at: 4102444799, data: '[]' })
} });
far_clock.clock.advance(4102444800000 - NOW);
assert_throws(() => devices.discover(far_clock), 'CORRUPT_STATE');

function set_policy(app, value) { return devices.policy_set(app, value); };
assert_equal(devices.timezones(runtime())[0], 'UTC', 'daemon-provided timezone list is canonical');
let timezone_validation = runtime();
let timezone_before = enc(timezone_validation.uci_fake.values);
assert_throws(() => set_policy(timezone_validation, { scope: 'global', action: 'proxy',
	schedule: spec([ 1 ], '09:00', '10:00', 'Madeup/Zone') }), 'VALIDATION_FAILED',
	'unknown timezone is rejected before persistence');
assert_equal(enc(timezone_validation.uci_fake.values), timezone_before,
	'unknown timezone cannot mutate UCI');
let utc_policy = set_policy(timezone_validation, { scope: 'global', action: 'proxy',
	schedule: spec([ 1 ], '09:00', '10:00', 'UTC') });
assert_equal(utc_policy.schedule.timezone, 'UTC', 'exact UTC timezone is accepted');
let resolved_timestamps = [];
let strict_timezone = runtime({ timezones: {
	list: () => [ 'UTC' ],
	resolve: (name, timestamp) => {
		push(resolved_timestamps, timestamp);
		return type(timestamp) == 'int' ? { name: 'UTC', from: 0, until: 4102444800,
			initial_offset: 0, transitions: [] } : null;
	}
} });
let strict_policy = set_policy(strict_timezone, { scope: 'global', action: 'proxy',
	schedule: spec([ 1 ], '09:00', '10:00', 'UTC') });
devices.effective(strict_timezone, { mac: null, interface: null, timestamp: 1710000000 });
assert_equal(resolved_timestamps[0], int(NOW / 1000), 'policy validation resolves the current instant');
assert_equal(resolved_timestamps[1], 1710000000, 'policy evaluation resolves the requested instant');
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
let create_at_max = persisted_policies(256), create_at_max_uci = enc(create_at_max.uci_fake.values);
assert_throws(() => devices.policy_set(create_at_max, { scope: 'device',
	mac: 'ac:bb:cc:dd:01:00', action: 'proxy', schedule: null }), 'RESOURCE_EXHAUSTED');
assert_equal(create_at_max.uci_fake.commit_calls, 0, 'capacity failure cannot commit UCI');
assert_equal(create_at_max.uci_fake.set_calls, 0, 'capacity failure cannot stage UCI');
assert_equal(create_at_max.fs.lstat('/etc/miclash/device-policies.json'), null,
	'capacity failure cannot publish a journal');
assert_equal(enc(create_at_max.uci_fake.values), create_at_max_uci,
	'capacity failure preserves persisted policy bytes');
let create_to_max = persisted_policies(255);
devices.policy_set(create_to_max, { scope: 'device', mac: 'ac:bb:cc:dd:00:ff',
	action: 'proxy', schedule: null });
assert_equal(length(devices.policy_list(create_to_max)), 256,
	'creating the exact policy maximum succeeds and restarts readably');
let max_revision = runtime({ guard: false, uci: { miclash: {
	guard: { '.type': 'guard', enabled: '0' },
	'dp_1_0000000000000001': { '.type': 'device_policy', revision: '2147483647',
		scope: 'device', mac: 'ac:bb:cc:dd:ee:01', action: 'proxy', schedule: '' }
} } });
let max_revision_uci = enc(max_revision.uci_fake.values);
assert_throws(() => devices.policy_set(max_revision, { id: 'dp_1_0000000000000001',
	expected_revision: 2147483647, scope: 'device', mac: 'ac:bb:cc:dd:ee:01',
	action: 'block', schedule: null }), 'RESOURCE_EXHAUSTED');
assert_equal(max_revision.uci_fake.commit_calls, 0, 'revision overflow cannot commit UCI');
assert_equal(max_revision.uci_fake.set_calls, 0, 'revision overflow cannot stage UCI');
assert_equal(max_revision.fs.lstat('/etc/miclash/device-policies.json'), null,
	'revision overflow cannot publish a journal');
assert_equal(enc(max_revision.uci_fake.values), max_revision_uci,
	'revision overflow preserves persisted policy bytes');
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
// Durable latch is effective Guard ON even while canonical UCI is still OFF.
// It must close both policy mutation and persisted DIRECT evaluation windows.
let latched_guard = runtime({ guard: false, core_available: true, uci: { miclash: {
	guard: { '.type': 'guard', enabled: '0' },
	'dp_1_0000000000000001': { '.type': 'device_policy', revision: '1', scope: 'device',
		mac: 'ac:bb:cc:dd:ee:10', action: 'direct', schedule: '' }
} } });
latched_guard.fs.writefile('/etc/miclash/guard-safety-latch', 'corrupt');
let latched_decision = devices.effective(latched_guard, {
	mac: 'ac:bb:cc:dd:ee:10', interface: 'br-lan', timestamp: 1710000000
});
assert_equal(latched_decision.action, 'proxy');
assert_equal(latched_decision.safety, 'guard_safe_override');
assert_throws(() => set_policy(latched_guard, { scope: 'device', mac: 'ac:bb:cc:dd:ee:12',
	action: 'direct', schedule: null }), 'VALIDATION_FAILED');
let latch_race = runtime({ guard: false });
latch_race.uci_fake.on_cursor = (calls) => {
	if (calls == 2) latch_race.fs.writefile('/etc/miclash/guard-safety-latch', 'corrupt');
};
assert_throws(() => set_policy(latch_race, { scope: 'device', mac: 'ac:bb:cc:dd:ee:12',
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
assert_throws(() => devices.compile_sets(deterministic_app(false), {
	timestamp: 1710000000, devices: [ uncanonical ] }), 'INVALID_ARGUMENT');
let malformed_compile = json(enc(compile_input));
malformed_compile.devices[0].identity.extra = 'untrusted';
assert_throws(() => devices.compile_sets(precedence, malformed_compile), 'INVALID_ARGUMENT');

// Raw devices must be bounded before any whole-object JSON clone. The same
// deeply nested object is referenced from every over-limit address slot: a
// preflight length rejection is constant-work and never traverses this graph.
let deep_untrusted = {};
for (let depth = 0; depth < 1000; depth++) deep_untrusted = { nested: deep_untrusted };
let over_limit_raw = json(enc(deterministic_one));
over_limit_raw.addresses = [];
for (let at = 0; at < 33; at++) push(over_limit_raw.addresses, deep_untrusted);
assert_throws(() => devices.compile_sets(deterministic_app(false), {
	timestamp: 1710000000, devices: [ over_limit_raw ]
}), 'INVALID_ARGUMENT', 'address count rejects before traversing raw nested values');
let huge_nested_string = json(enc(deterministic_one));
huge_nested_string.identity.extra = sprintf('%0300000d', 0);
assert_throws(() => devices.compile_sets(deterministic_app(false), {
	timestamp: 1710000000, devices: [ huge_nested_string ]
}), 'INVALID_ARGUMENT', 'nested schema rejects before copying an oversized string');
let hostile_compile_hook = json(enc(deterministic_one));
hostile_compile_hook.identity.extra = { toJSON: () => die('raw compile serializer invoked') };
assert_throws(() => devices.compile_sets(deterministic_app(false), {
	timestamp: 1710000000, devices: [ hostile_compile_hook ]
}), 'INVALID_ARGUMENT', 'toJSON-like compile extras reject by schema without invocation');

function semantic_device() { return json(enc(deterministic_one)); };
function reject_semantic(label, mutate) {
	let item = semantic_device(); mutate(item);
	assert_throws(() => devices.compile_sets(deterministic_app(false), {
		timestamp: 1710000000, devices: [ item ]
	}), 'INVALID_ARGUMENT', label);
};
for (let sample in [
	[ 'DHCP address cannot retain neighbor interfaces', (item) => {
		item.sources = [ 'dhcp', 'neighbor' ]; item.addresses[0].source = 'dhcp';
	} ],
	[ 'DHCP address interface counters are exactly empty', (item) => {
		item.sources = [ 'dhcp', 'neighbor' ]; item.addresses[0].source = 'dhcp';
		item.addresses[0].interfaces = []; item.addresses[0].interface_total = 1;
		item.addresses[0].interfaces_truncated = true;
	} ],
	[ 'neighbor address requires retained interface evidence', (item) => {
		item.addresses[0].interfaces = []; item.addresses[0].interface_total = 0;
	} ],
	[ 'short neighbor evidence cannot claim truncation', (item) => {
		item.addresses[0].interface_total = 2; item.addresses[0].interfaces_truncated = true;
	} ],
	[ 'device source must cover each address source', (item) => item.sources = [ 'dhcp' ] ]
]) reject_semantic(sample[0], sample[1]);

function conflict_device(reason) {
	let item = semantic_device(), self = 'mac:' + item.mac;
	if (reason == 'hostname_changed') {
		item.hostname = 'alpha'; item.sources = [ 'dhcp', 'neighbor' ];
		item.conflicts = [ { reason, subject: self, evidence: [ 'alpha', 'beta' ],
			total: 2, truncated: false } ];
	}
	else if (reason == 'duplicate_hostname') {
		item.hostname = 'same'; item.sources = [ 'dhcp', 'neighbor' ];
		item.conflicts = [ { reason, subject: 'same',
			evidence: [ self, 'mac:ac:bb:cc:dd:ee:71' ], total: 2, truncated: false } ];
	}
	else if (reason == 'shared_address') item.conflicts = [ { reason,
		subject: 'ipv4:192.168.9.9', evidence: [ self, 'mac:ac:bb:cc:dd:ee:71' ],
		total: 2, truncated: false } ];
	else {
		item.interfaces = [ 'br-lan', 'wlan0' ]; item.interface_total = 2;
		item.addresses[0].interfaces = [ 'br-lan', 'wlan0' ];
		item.addresses[0].interface_total = 2;
		item.conflicts = [ { reason: 'address_interfaces', subject: '192.168.9.9',
			evidence: [ 'br-lan', 'wlan0' ], total: 2, truncated: false } ];
	}
	return item;
};
function reject_conflict(label, reason, mutate) {
	let item = conflict_device(reason); mutate(item.conflicts[0], item);
	assert_throws(() => devices.compile_sets(deterministic_app(false), {
		timestamp: 1710000000, devices: [ item ]
	}), 'INVALID_ARGUMENT', label);
};
for (let sample in [
	[ 'hostname history requires two names', 'hostname_changed', (conflict) => {
		conflict.evidence = [ 'alpha' ]; conflict.total = 1;
	} ],
	[ 'hostname history must retain selected hostname', 'hostname_changed', (conflict) =>
		conflict.evidence = [ 'beta', 'gamma' ] ],
	[ 'hostname history requires DHCP provenance', 'hostname_changed', (conflict, item) =>
		item.sources = [ 'neighbor' ] ],
	[ 'duplicate hostname subject matches device hostname', 'duplicate_hostname', (conflict) =>
		conflict.subject = 'other' ],
	[ 'duplicate hostname requires a retained device hostname', 'duplicate_hostname', (conflict, item) => {
		item.hostname = null; conflict.subject = '*';
	} ],
	[ 'duplicate hostname evidence uses canonical identities', 'duplicate_hostname', (conflict) =>
		conflict.evidence[1] = 'bogus' ],
	[ 'duplicate hostname requires at least two identities', 'duplicate_hostname', (conflict) => {
		conflict.evidence = [ conflict.evidence[0] ]; conflict.total = 1;
	} ],
	[ 'shared address subject matches a current address', 'shared_address', (conflict) =>
		conflict.subject = 'ipv4:192.168.9.10' ],
	[ 'shared address evidence uses canonical identities', 'shared_address', (conflict) =>
		conflict.evidence[1] = 'MAC:AC:BB:CC:DD:EE:71' ],
	[ 'multiple-interface evidence matches its address', 'address_interfaces', (conflict) =>
		conflict.evidence = [ 'br-lan', 'eth0' ] ],
	[ 'multiple-interface conflict requires two interfaces', 'address_interfaces', (conflict) => {
		conflict.evidence = [ 'br-lan' ]; conflict.total = 1;
	} ],
	[ 'multiple-interface evidence cannot be omitted', 'address_interfaces', (conflict, item) =>
		item.conflicts = [] ],
	[ 'short conflict evidence cannot claim truncation', 'duplicate_hostname', (conflict) => {
		conflict.total = 17; conflict.truncated = true;
	} ]
]) reject_conflict(sample[0], sample[1], sample[2]);
assert_throws(() => devices.effective(deterministic_app(false), {
	mac: deterministic_one.mac, interfaces: [ 'br-lan' ], interface_total: 17,
	interfaces_truncated: true, timestamp: 1710000000
}), 'INVALID_ARGUMENT', 'effective rejects forged short-truncated interface evidence');

// Every closed provenance form emitted by discovery remains compilable.
let split_entries = [];
for (let iface = 0; iface < 16; iface++) {
	push(split_entries, { dst: '192.168.4.1', dev: sprintf('a%02d', iface),
		lladdr: 'ac:bb:cc:dd:ee:72', state: [ 'REACHABLE' ] });
	push(split_entries, { dst: '192.168.4.2', dev: sprintf('z%02d', iface),
		lladdr: 'ac:bb:cc:dd:ee:72', state: [ 'REACHABLE' ] });
}
let split_max_app = runtime({ observers: {
	dhcp_leases: () => ({ observed_at: 1710000000, data: '' }),
	neighbors: (family) => ({ observed_at: 1710000000,
		data: family == 'ipv4' ? enc(split_entries) : '[]' })
} });
let split_max_devices = devices.discover(split_max_app);
assert_equal(split_max_devices[0].interface_total, 32,
	'max-bound round trip retains the exact device interface total');
devices.compile_sets(split_max_app, { timestamp: 1710000000, devices: split_max_devices });

function aggregate_hostname_lines(count, reverse, duplicate) {
	let lines = [];
	for (let at = 1; at <= count; at++) push(lines,
		'1710003600 ac:bb:cc:dd:ee:74 192.168.5.2 name' +
		sprintf('%03d', duplicate ? 1 : at) + ' *');
	if (reverse) lines = sort(lines, (a, b) => a < b ? 1 : -1);
	return join('\n', lines) + (length(lines) ? '\n' : '');
};
function aggregate_hostname_runtime(count, reverse, duplicate) {
	let app = runtime({ observers: {
		dhcp_leases: () => ({ observed_at: 1710000000,
			data: '1710003600 ac:bb:cc:dd:ee:74 192.168.5.2 name000 *\n' }),
		neighbors: () => ({ observed_at: 1710000000, data: '[]' })
	} });
	devices.discover(app);
	app.observers.dhcp_leases = () => ({ observed_at: 1710000000,
		data: aggregate_hostname_lines(count, reverse, duplicate) });
	return app;
};
let hostname_over_app = aggregate_hostname_runtime(512, false, false);
let hostname_over_cache = enc(hostname_over_app.device_cache);
assert_throws(() => devices.discover(hostname_over_app), 'INVALID_ARGUMENT');
assert_equal(enc(hostname_over_app.device_cache), hostname_over_cache,
	'retained and new hostname provenance overflow cannot mutate cache');
let hostname_max_app = aggregate_hostname_runtime(511, false, false);
let hostname_max_devices = devices.discover(hostname_max_app);
let hostname_max_conflict = filter(hostname_max_devices[0].conflicts,
	(item) => item.reason == 'hostname_changed')[0];
assert_equal(hostname_max_conflict.total, 512,
	'exact retained and new hostname provenance maximum is accepted');
devices.compile_sets(hostname_max_app, { timestamp: 1710000000, devices: hostname_max_devices });
let hostname_max_reload = devices.discover(hostname_max_app);
devices.compile_sets(hostname_max_app, { timestamp: 1710000000, devices: hostname_max_reload });
let hostname_reverse_app = aggregate_hostname_runtime(511, true, false);
assert_equal(enc(hostname_max_devices), enc(devices.discover(hostname_reverse_app)),
	'hostname provenance is observer-order independent');
let hostname_duplicate_app = aggregate_hostname_runtime(512, true, true);
let hostname_duplicate_devices = devices.discover(hostname_duplicate_app);
let hostname_duplicate_conflict = filter(hostname_duplicate_devices[0].conflicts,
	(item) => item.reason == 'hostname_changed')[0];
assert_equal(hostname_duplicate_conflict.total, 2,
	'repeated identical hostname evidence does not inflate totals');

function aggregate_neighbor_entries(family, count, reverse, duplicate) {
	let entries = [];
	for (let at = 0; at < count; at++) push(entries, {
		dst: family == 'ipv4' ? '192.168.5.1' : 'fd00::5',
		dev: (family == 'ipv4' ? 'v4' : 'v6') + sprintf('%03d', duplicate ? 0 : at),
		lladdr: 'ac:bb:cc:dd:ee:73', state: [ 'REACHABLE' ]
	});
	if (reverse) entries = sort(entries, (a, b) => a.dev < b.dev ? 1 : -1);
	return entries;
};
function aggregate_neighbor_runtime(v4_count, v6_count, reverse, duplicate) {
	let v4 = aggregate_neighbor_entries('ipv4', v4_count, reverse, duplicate);
	let v6 = aggregate_neighbor_entries('ipv6', v6_count, reverse, duplicate);
	return runtime({ observers: {
		dhcp_leases: () => ({ observed_at: 1710000000, data: '' }),
		neighbors: (family) => ({ observed_at: 1710000000,
			data: enc(family == 'ipv4' ? v4 : v6) })
	} });
};
let aggregate_over_app = aggregate_neighbor_runtime(512, 512, false, false);
let aggregate_over_cache = enc(aggregate_over_app.device_cache);
assert_throws(() => devices.discover(aggregate_over_app), 'INVALID_ARGUMENT');
assert_equal(enc(aggregate_over_app.device_cache), aggregate_over_cache,
	'combined neighbor provenance overflow cannot mutate cache');
let aggregate_max_app = aggregate_neighbor_runtime(256, 256, false, false);
let aggregate_max_devices = devices.discover(aggregate_max_app);
assert_equal(aggregate_max_devices[0].interface_total, 512,
	'exact combined neighbor provenance maximum is accepted');
devices.compile_sets(aggregate_max_app, { timestamp: 1710000000, devices: aggregate_max_devices });
let aggregate_max_reload = devices.discover(aggregate_max_app);
devices.compile_sets(aggregate_max_app, { timestamp: 1710000000, devices: aggregate_max_reload });
let aggregate_reverse_app = aggregate_neighbor_runtime(256, 256, true, false);
assert_equal(enc(aggregate_max_devices), enc(devices.discover(aggregate_reverse_app)),
	'combined neighbor provenance is observer-order independent');
let aggregate_duplicate_app = aggregate_neighbor_runtime(512, 512, true, true);
let aggregate_duplicate_devices = devices.discover(aggregate_duplicate_app);
assert_equal(aggregate_duplicate_devices[0].interface_total, 2,
	'repeated identical neighbor interface evidence does not inflate totals');
for (let discovered in [ hostname_history([ 'gamma', 'alpha', 'beta' ]),
	evidence_devices[0], multi_interface[0], interface_over.devices[0], unrelated[0] ])
	devices.compile_sets(runtime({ guard: false }), { timestamp: 1710000000, devices: [ discovered ] });

function reasoning_devices(all_truncated) {
	let output = [], address_number = 0;
	for (let device_number = 0; device_number < 34; device_number++) {
		let truncated = all_truncated || device_number == 33, addresses = [];
		let device_interfaces = [ 'br-lan' ];
		if (truncated) for (let iface = 0; iface < 15; iface++)
			push(device_interfaces, sprintf('if%02d', iface));
		let count = device_number == 33 ? 1 : 32;
		for (let at = 0; at < count; at++) {
			address_number++;
			let ip = device_number == 33 ? '10.255.255.254' :
				sprintf('10.%d.%d.%d', int(address_number / 65536),
					int((address_number % 65536) / 256), address_number % 256);
			push(addresses, { address: ip, family: 'ipv4', current: true,
				last_seen: 1710000000, source: 'neighbor', interfaces: [ 'br-lan' ],
				interface_total: 1, interfaces_truncated: false });
		}
		let mac_value = sprintf('ac:bb:cc:dd:%02x:%02x', int(device_number / 256),
			device_number % 256);
		push(output, { identity: { kind: 'mac', value: mac_value, confidence: 'high',
			persistent_policy_eligible: true, reason: 'stable_mac' }, mac: mac_value,
			hostname: null, last_seen: 1710000000, sources: [ 'neighbor' ],
			interfaces: device_interfaces, interface_total: truncated ? 17 : 1,
			interfaces_truncated: truncated, conflicts: [], addresses });
	}
	return output;
};
function reverse_reasoning_devices(input) {
	let output = [];
	for (let at = length(input) - 1; at >= 0; at--) {
		let device = json(enc(input[at])), addresses = [];
		for (let address_at = length(device.addresses) - 1; address_at >= 0; address_at--)
			push(addresses, device.addresses[address_at]);
		device.addresses = addresses; push(output, device);
	}
	return output;
};
let reasoning_input = reasoning_devices(false), reasoning_app = runtime({ guard: false });
let bounded_reasoning = devices.compile_sets(reasoning_app,
	{ timestamp: 1710000000, devices: reasoning_input });
assert_equal(bounded_reasoning.reasoning_total, 1057, 'reasoning reports exact unique total');
assert_equal(length(bounded_reasoning.reasoning), 1024, 'reasoning retention is bounded');
assert_true(bounded_reasoning.reasoning_truncated, 'reasoning truncation is explicit');
assert_equal(bounded_reasoning.safety_conflicts_total, 1, 'late safety conflict is counted');
assert_true(!bounded_reasoning.safety_conflicts_truncated,
	'priority retention preserves the sole late safety conflict');
assert_equal(length(filter(bounded_reasoning.reasoning,
	(item) => item.safety == 'interface_evidence_truncated')), 1,
	'late safety conflict is prioritized into retained reasoning');
assert_equal(enc(sort(keys(bounded_reasoning))), enc([ 'ipv4', 'ipv6', 'reasoning',
	'reasoning_total', 'reasoning_truncated', 'safety_conflicts_total',
	'safety_conflicts_truncated' ]), 'compiled output schema is exact');
assert_equal(enc(sort(keys(bounded_reasoning.reasoning[0]))), enc([ 'action', 'address',
	'conflict', 'family', 'identities', 'policy_id', 'safety' ]),
	'reasoning summary schema is exact');
assert_equal(enc(bounded_reasoning), enc(devices.compile_sets(runtime({ guard: false }),
	{ timestamp: 1710000000, devices: reverse_reasoning_devices(reasoning_input) })),
	'large reasoning output is byte-identical under device/address permutations');
let all_safety = devices.compile_sets(runtime({ guard: false }),
	{ timestamp: 1710000000, devices: reasoning_devices(true) });
assert_equal(all_safety.safety_conflicts_total, 1057, 'all safety conflicts are counted');
assert_true(all_safety.safety_conflicts_truncated, 'omitted safety evidence is explicit');
assert_equal(length(all_safety.reasoning), 1024);
assert_equal(length(all_safety.ipv4.block), 1057, 'reasoning bounds never weaken BLOCK enforcement');
