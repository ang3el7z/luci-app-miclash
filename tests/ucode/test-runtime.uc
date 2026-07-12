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

let production = runtime.create();
assert_true(type(production.clock.set_timeout) == 'function');
assert_true(type(production.random.hex) == 'function');
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

let fake_result = validation_fake.run({ command: '/bin/true' });
assert_equal(fake_result.code, 0);
assert_equal(fake_result.stdout, null);
assert_equal(fake_result.stderr, null);

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
