import * as http from 'miclash.http';
import { assert_equal, assert_true } from 'testlib';
import * as fakes from 'fakes';

function argument_after(args, name) {
	for (let index = 0; index + 1 < length(args); index++)
		if (args[index] == name)
			return args[index + 1];
	return null;
};

function environment() {
	let filesystem = fakes.fs();
	filesystem.mkdir('/tmp');
	filesystem.mkdir('/tmp/miclash');
	return {
		filesystem,
		runtime: {
			fs: filesystem,
			clock: fakes.clock(1700000000000),
			random: fakes.entropy(),
			process: fakes.process(),
			paths: { tmp: '/tmp/miclash' }
		}
	};
};

function output_paths(filesystem, session) {
	let config_path = argument_after(session.args, '--config');
	let config = filesystem.readfile(config_path);
	return {
		config_path,
		config,
		header_path: match(config, /dump-header = "([^"]+)"/)?.[1],
		body_path: match(config, /output = "([^"]+)"/)?.[1]
	};
};

assert_equal(type(http.begin), 'function', 'HTTP module exports begin()');

let completed = environment();
let session = http.begin(completed.runtime, {
	url: 'https://api.telegram.org/bot123456:telegram-secret/getUpdates?timeout=25',
	connect_timeout_ms: 2000,
	timeout_ms: 30000,
	max_redirects: 0,
	max_bytes: 65536,
	managed: true,
	accept_statuses: [ 429 ]
});
assert_equal(session.command, '/usr/bin/curl');
assert_equal(sprintf('%J', session.args), sprintf('%J', [ '--config', session.args[1] ]));
assert_true(index(sprintf('%J', session.args), 'telegram-secret') < 0,
	'credentials must not appear in process argv');
let paths = output_paths(completed.filesystem, session);
assert_true(index(paths.config, 'telegram-secret') >= 0,
	'credentials stay in the root-owned curl config');
for (let path in [ paths.config_path, paths.header_path, paths.body_path ])
	assert_equal(completed.filesystem.mode(path), 0o600);
completed.filesystem.writefile(paths.header_path,
	'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n');
completed.filesystem.writefile(paths.body_path, '{"ok":true,"result":[]}');
let reply = session.complete(0);
assert_equal(reply.status, 200);
assert_equal(reply.body, '{"ok":true,"result":[]}');
assert_equal(length(completed.filesystem.lsdir('/tmp/miclash/http')), 0);

let cancelled = environment();
let cancelled_session = http.begin(cancelled.runtime, {
	url: 'https://api.telegram.org/bot123456:telegram-secret/getUpdates?timeout=25',
	connect_timeout_ms: 2000,
	timeout_ms: 30000,
	max_redirects: 0,
	max_bytes: 65536,
	managed: true,
	accept_statuses: [ 429 ]
});
assert_true(length(cancelled.filesystem.lsdir('/tmp/miclash/http')) > 0);
assert_equal(cancelled_session.abort(), true);
assert_equal(cancelled_session.abort(), true, 'abort must be idempotent');
assert_equal(length(cancelled.filesystem.lsdir('/tmp/miclash/http')), 0);

print('HTTP cancellable session tests passed\n');
