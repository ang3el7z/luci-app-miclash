import { assert_equal, assert_match, assert_throws, assert_true } from './testlib.uc';
import * as runtime from 'miclash.runtime';
import * as fakes from './fakes.uc';

let fake_process = fakes.process({
	'echo:hello': { code: 0 }
});
let fake_clock = fakes.clock(1000);
let rt = runtime.create({ process: fake_process, clock: fake_clock });

assert_true(rt.fs != null);
assert_equal(rt.clock.now(), 1000);
let timer_fired = false;
fake_clock.set_timeout(10, () => timer_fired = true);
fake_clock.advance(9);
assert_equal(timer_fired, false);
fake_clock.advance(1);
assert_equal(timer_fired, true);
assert_equal(rt.process.run({ command: 'echo', args: [ 'hello' ] }).stdout, null);
assert_equal(length(fake_process.calls), 1);
assert_equal(fake_process.calls[0].command, 'echo');
assert_throws(() => fake_process.run('echo hello'), 'INVALID_ARGUMENT');
assert_throws(() => fake_process.run({ command: 'echo', args: [], shell: true }), 'INVALID_ARGUMENT');

let timezone_capability = { list: () => [ 'UTC' ], resolve: () => ({}) };
let secure_capability = { open: () => ({}) };
let reconciliation = { run: () => ({ state: 'queued' }) };
let rulesets = { validate: () => true };
let lock_identity = { boot: 'boot', pid: 1, start: 1 };
let extended = runtime.create({
	timezones: timezone_capability, secure_fs: secure_capability,
	reconcile: reconciliation, rulesets, mutation_lock_self: lock_identity,
	core_available: true, app_version: '0.9.2'
});
assert_true(extended.timezones === timezone_capability);
assert_true(extended.secure_fs === secure_capability);
assert_true(extended.reconcile === reconciliation);
assert_true(extended.rulesets === rulesets);
assert_true(extended.mutation_lock_self === lock_identity);
assert_equal(extended.core_available, true);
assert_equal(extended.app_version, '0.9.2');

let production = runtime.create();
assert_true(type(production.clock.set_timeout) == 'function');
assert_true(type(production.clock.set_fallback_timeout) == 'function');
assert_true(type(production.random.hex) == 'function');
assert_true(type(production.secure_fs?.open) == 'function');
assert_true(type(production.secure_fs?.open_at) == 'function');
assert_true(type(production.secure_fs?.open_reader) == 'function');
assert_true(type(production.secure_fs?.replace_atomic) == 'function');
assert_true(type(production.secure_fs?.with_transaction_lease) == 'function');
assert_true(type(production.timezones?.list) == 'function');
assert_true(type(production.timezones?.resolve) == 'function');
let installed_timezones = production.timezones.list();
assert_true(type(installed_timezones) == 'array');
assert_true(length(installed_timezones) >= 1 && length(installed_timezones) <= 512);
assert_true(index(installed_timezones, 'UTC') >= 0);
let utc_capability = production.timezones.resolve('UTC', 1700000000);
assert_equal(utc_capability.name, 'UTC');
assert_equal(utc_capability.from, 1700000000);
assert_equal(utc_capability.until, 1700000001);
assert_equal(utc_capability.initial_offset, 0);
assert_equal(length(utc_capability.transitions), 0);
if (length(installed_timezones) > 1)
	assert_true(production.timezones.resolve(installed_timezones[1], 1700000000) != null);
assert_equal(production.timezones.resolve('../etc/passwd', 1700000000), null);
assert_true(type(production.observers?.dhcp_leases) == 'function');
assert_true(type(production.observers?.neighbors) == 'function');
assert_true(type(production.observers?.dns) == 'function');
assert_true(type(production.observers?.tun) == 'function');
assert_true(type(production.observers?.policy) == 'function');
assert_true(type(production.observers?.forward) == 'function');
assert_true(type(production.events?.emit) == 'function');
assert_true(type(production.events?.subscribe) == 'function');
assert_true(type(production.reboot) == 'function');
assert_true(type(production.mutation_lock_self?.boot) == 'string');
assert_true(type(production.mutation_lock_self?.pid) == 'int');
assert_true(type(production.mutation_lock_self?.start) == 'int');
assert_true(type(production.core_available) == 'bool');
assert_equal(production.rulesets.validate('safe.txt', 'DOMAIN,example.test\n'), true);
assert_equal(production.rulesets.validate('../unsafe.txt', 'DOMAIN,example.test\n'), false);
assert_equal(production.rulesets.validate('safe.txt', 'DOMAIN,' + sprintf('%c', 1) + '\n'), false);
let random_hex = production.random.hex(8);
assert_match(random_hex, /^[0-9a-f]{16}$/);
assert_equal(production.fs.flush({ flush: () => null, error: () => null }), true);
assert_equal(production.fs.flush({ flush: () => true, error: () => null }), false);
assert_equal(production.fs.flush({ flush: () => null, error: () => 'stale error' }), true);
assert_throws(() => production.process.run('echo hello'), 'INVALID_ARGUMENT');
assert_throws(() => production.process.run({ command: 'echo', args: [], shell: true }), 'INVALID_ARGUMENT');

let validation_fake = fakes.process();
function assert_process_rejected(request) {
	assert_throws(() => production.process.run(request), 'INVALID_ARGUMENT');
	assert_throws(() => validation_fake.run(request), 'INVALID_ARGUMENT');
};

function assert_process_boundary_rejected(request) {
	assert_throws(() => runtime.validate_process_request(request), 'INVALID_ARGUMENT');
	assert_throws(() => validation_fake.run(request), 'INVALID_ARGUMENT');
};

assert_process_rejected({ command: '', args: [] });
assert_process_rejected({ command: 'echo', args: [ 1 ] });
assert_process_rejected({ command: 'echo', env: [] });
assert_process_rejected({ command: 'echo', env: { 'BAD-NAME': 'value' } });
assert_process_rejected({ command: 'echo', env: { GOOD_NAME: 1 } });
assert_process_rejected({ command: 'echo', timeout_ms: -1 });
assert_process_rejected({ command: 'echo', timeout_ms: 1.5 });
assert_process_rejected({ command: 'echo', capture_limit: 8192 });
assert_process_rejected({ command: 'echo', shell: true });
assert_process_rejected({ command: 'echo', stdin: '' });
assert_process_boundary_rejected({ command: 'echo' + sprintf('%c', 0) + 'hidden' });
assert_process_boundary_rejected({ command: 'echo', args: [ 'safe', 'bad' + sprintf('%c', 0) + 'hidden' ] });
assert_equal(length(validation_fake.calls), 0);

let production_result = production.process.run({ command: '/bin/true' });
assert_equal(production_result.code, 0);
assert_true(exists(production_result, 'stdout'));
assert_true(exists(production_result, 'stderr'));
assert_equal(production_result.stdout, null);
assert_equal(production_result.stderr, null);

let timezone_fs = fakes.fs({
	'/usr/share/zoneinfo/zone1970.tab': 'RU\t+5545+03737\tEurope/Moscow\n',
	'/usr/share/zoneinfo/Europe/Moscow': 'TZif'
});
let timezone_runtime = runtime.create({
	fs: timezone_fs, digest: fakes.digest(timezone_fs), random: fakes.entropy(),
	clock: fakes.clock(0), process: fakes.process(), uci: fakes.uci({}),
	ubus: { connect: () => null }, http: { request: () => null }
});
assert_true(index(timezone_runtime.timezones.list(), 'Europe/Moscow') >= 0);
assert_true(timezone_runtime.timezones.resolve('Europe/Moscow', 1700000000) != null);

let fake_result = validation_fake.run({ command: '/bin/true' });
assert_equal(fake_result.code, 0);
assert_equal(fake_result.stdout, null);
assert_equal(fake_result.stderr, null);

// Production Guard verification follows the typed requested state even when
// the retained legacy settings file says the exact opposite.
let guard_fs = fakes.fs({ '/opt/clash/settings': 'INTERNET_ONLY_MICLASH=false\n' });
let guard_process = fakes.process({
	'/opt/clash/bin/clash-rules:guard_verify_on': { code: 0 },
	'/opt/clash/bin/clash-rules:guard_verify_off': { code: 0 }
});
let guard_clock = fakes.clock(1700000000000);
let guard_runtime = runtime.create({
	fs: guard_fs, digest: fakes.digest(guard_fs), random: fakes.entropy(),
	clock: guard_clock, process: guard_process, uci: fakes.uci({}),
	ubus: { connect: () => null }, http: { request: () => null }
});
assert_equal(guard_runtime.observers.guard(true).ready, true,
	'legacy false overrode canonical Guard ON verification');
guard_fs.writefile('/opt/clash/settings', 'INTERNET_ONLY_MICLASH=true\n');
guard_clock.advance(1);
assert_equal(guard_runtime.observers.guard(false).ready, true,
	'legacy true overrode canonical Guard OFF verification');
assert_equal(guard_process.calls[0].args[0], 'guard_verify_on');
assert_equal(guard_process.calls[1].args[0], 'guard_verify_off');

let fake_fs = fakes.fs({ '/etc/miclash/config': 'old' });
assert_equal(fake_fs.readfile('/etc/miclash/config'), 'old');
fake_fs.writefile('/etc/miclash/config', 'new');
assert_equal(fake_fs.readfile('/etc/miclash/config'), 'new');

let fake_uci = fakes.uci({ miclash: { core: { enabled: '1' } } });
assert_equal(fake_uci.get('miclash', 'core', 'enabled'), '1');
fake_uci.set('miclash', 'core', 'enabled', '0');
assert_equal(fake_uci.get('miclash', 'core', 'enabled'), '0');

let events = fakes.events();
events.emit('operation', { id: 'op-1' });
assert_equal(events.items[0].type, 'operation');

function http_socket(parts) {
	let fake = {
		POLLIN: 1, POLLOUT: 4, POLLERR: 8, POLLHUP: 16,
		SOCK_STREAM: 1, parts, sent: '', closed: false
	};
	let conn = {
		send: (data) => { fake.sent += data; return length(data); },
		recv: (amount) => length(fake.parts) ? shift(fake.parts) : '',
		close: () => fake.closed = true
	};
	fake.connect = (address, service, hints, timeout) => conn;
	fake.poll = (timeout, spec) => {
		let wanted = spec[1];
		return [ [ conn, wanted & fake.POLLOUT ? fake.POLLOUT : fake.POLLIN ] ];
	};
	return fake;
};

function http_response(parts) {
	let clock = fakes.clock(0);
	let socket = http_socket(parts);
	return runtime.create_http_adapter(clock, socket).request({
		host: '127.0.0.1', port: 9090, method: 'GET', path: '/version',
		headers: {}, body: null
	});
};

let chunk_prefix = 'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n';
assert_equal(http_response([ chunk_prefix + '1\r\nx\r\n0\r\n\r\n', '' ]).body, 'x');
assert_equal(http_response([ chunk_prefix + '1\r\nx\r\n0\r\nX-Test: yes\r\n\r\n', '' ]).body, 'x');
assert_throws(() => http_response([ chunk_prefix + '0\r\nBad Trailer\r\n\r\n', '' ]), 'INVALID_RESPONSE');
assert_throws(() => http_response([ chunk_prefix + '0\r\n\r\ntrailing', '' ]), 'INVALID_RESPONSE');
assert_throws(() => http_response([ chunk_prefix + '1\r\nx\r\n0\r\n', '' ]), 'INVALID_RESPONSE');
assert_throws(() => http_response([ chunk_prefix + '10001\r\n', '' ]), 'RESPONSE_TOO_LARGE');
assert_throws(() => http_response([ chunk_prefix + 'FFFFFFFFFFFFFFFF\r\n', '' ]), 'INVALID_RESPONSE');
let length_prefix = 'HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\n';
assert_throws(() => http_response([ length_prefix + 'x', 'trailing', '' ]), 'INVALID_RESPONSE');
