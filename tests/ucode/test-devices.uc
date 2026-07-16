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
assert_throws(() => { observed.clock.advance(-1000); devices.discover(observed); }, 'CORRUPT_STATE');

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
let invalid_identity = devices.discover(invalid_mac_observation)[0];
assert_equal(invalid_identity.identity.kind, 'ip', 'syntactically invalid observed MAC is explicit ephemeral identity');
assert_equal(invalid_identity.identity.reason, 'invalid_mac', 'invalid MAC evidence is not hidden');
let unrelated_ip_only = runtime({ observers: {
	dhcp_leases: () => ({ observed_at: 1710000000,
		data: '1710003600 invalid-mac 192.168.1.88 guest *\n' }),
	neighbors: (family) => ({ observed_at: 1710000000, data: family == 'ipv4' ?
		'[{"dst":"192.168.1.88","dev":"br-lan","state":["STALE"]}]' : '[]' })
} });
let unrelated = devices.discover(unrelated_ip_only);
assert_equal(length(unrelated), 2, 'unrelated observations never merge by shared IP');
assert_true(unrelated[0].identity.value != unrelated[1].identity.value,
	'ephemeral identities carry distinct observation evidence');
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
assert_match(direct.id, /^dp-[0-9]+-[0-9a-f]{16}$/, 'opaque generated policy ID');
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
let restarted = runtime({ uci: precedence.uci_fake.values, guard: false });
assert_throws(() => set_policy(restarted, { scope: 'device', mac: device_policy.mac,
	action: 'proxy', schedule: null }), 'VALIDATION_FAILED');

// Tampered persisted DIRECT never bypasses Guard; unavailable core becomes BLOCK.
let guarded = runtime({ guard: true, core_available: false, uci: { miclash: {
	guard: { '.type': 'guard', enabled: '1' },
	'dp-1-0000000000000001': { '.type': 'device_policy', revision: '1', scope: 'device',
		mac: 'ac:bb:cc:dd:ee:10', action: 'direct', schedule: '' }
} } });
assert_equal(devices.effective(guarded, { mac: 'ac:bb:cc:dd:ee:10', interface: 'br-lan',
	timestamp: 1710000000 }).action, 'block', 'tampered direct fails closed');
let extra_uci = runtime({ uci: { miclash: {
	guard: { '.type': 'guard', enabled: '0' },
	'dp-1-0000000000000001': { '.type': 'device_policy', revision: '1', scope: 'device',
		mac: 'ac:bb:cc:dd:ee:10', action: 'proxy', schedule: '', extra: 'untrusted' }
} } });
assert_throws(() => devices.policy_list(extra_uci), 'CORRUPT_STATE');
let unknown_guard = runtime({ core_available: true, uci: { miclash: {
	guard: { '.type': 'guard', enabled: 'maybe' },
	'dp-1-0000000000000001': { '.type': 'device_policy', revision: '1', scope: 'device',
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
let collision_id = 'dp-' + NOW + '-0000000000000002';
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
			interfaces: [ 'br-lan' ], conflicts: [], addresses: [ { address: '192.168.1.50', family: 'ipv4',
				current: true, last_seen: 1710000000, source: 'neighbor', interface: 'br-lan' } ] },
		{ identity: { kind: 'mac', value: 'ac:bb:cc:dd:ee:11', confidence: 'high', persistent_policy_eligible: true,
			reason: 'stable_mac' },
			mac: 'ac:bb:cc:dd:ee:11', hostname: 'two', last_seen: 1710000000, sources: [ 'neighbor' ],
			interfaces: [ 'br-lan' ], conflicts: [], addresses: [ { address: '192.168.1.50', family: 'ipv4',
				current: true, last_seen: 1710000000, source: 'neighbor', interface: 'br-lan' } ] }
	]
};
let compiled = devices.compile_sets(precedence, compile_input);
assert_equal(enc(compiled.ipv4.block), enc([ '192.168.1.50' ]), 'shared IP resolves conservatively to BLOCK');
assert_equal(length(compiled.ipv4.proxy), 0, 'compiled sets disjoint');
assert_true(length(compiled.reasoning) > 0, 'shared-IP conflict reasoning explicit');
assert_equal(length(precedence.process.calls), 0, 'compiler never calls firewall/processes');
assert_equal(enc(compiled), enc(devices.compile_sets(precedence, compile_input)),
	'compiled output deterministic');
let malformed_compile = json(enc(compile_input));
malformed_compile.devices[0].identity.extra = 'untrusted';
assert_throws(() => devices.compile_sets(precedence, malformed_compile), 'INVALID_ARGUMENT');
