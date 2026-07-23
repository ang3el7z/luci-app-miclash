import * as http from 'miclash.http';
import { assert_equal, assert_match, assert_throws, assert_true } from 'testlib';
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
			digest: fakes.digest(filesystem),
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
	let upload_path = null;
	for (let name in filesystem.lsdir('/tmp/miclash/http'))
		if (match(name, /-upload$/))
			upload_path = '/tmp/miclash/http/' + name;
	return {
		config_path,
		config,
		header_path: match(config, /dump-header = "([^"]+)"/)?.[1],
		body_path: match(config, /output = "([^"]+)"/)?.[1],
		upload_path,
		multipart_path: match(config, /data-binary = "@([^"]+)"/)?.[1]
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

let multipart = environment();
let document = '{"schema_version":4,"privacy":{"mode":"lite"}}', document_offset = 0,
	document_finished = 0, document_closed = 0, document_identity = {};
let body_file = {
	identity: document_identity,
	size: length(document),
	sha256: multipart.runtime.digest.sha256(document),
	read: (amount) => {
		let chunk = substr(document, document_offset, amount);
		document_offset += length(chunk);
		return chunk;
	},
	finish: () => { document_finished++; return true; },
	close: () => { document_closed++; return true; },
	field: 'document',
	filename: 'miclash-diagnostic-lite-1700000000000.json',
	content_type: 'application/json',
	fields: { chat_id: '42', caption: 'MiClash Lite diagnostics' }
};
let multipart_session = http.begin(multipart.runtime, {
	url: 'https://api.telegram.org/bot123456:telegram-secret/sendDocument',
	connect_timeout_ms: 2000,
	timeout_ms: 30000,
	max_redirects: 0,
	max_bytes: 65536,
	managed: true,
	accept_statuses: [ 429 ],
	method: 'POST',
	body_file
});
let multipart_paths = output_paths(multipart.filesystem, multipart_session);
assert_true(multipart_paths.upload_path != null, 'multipart upload did not stage a file');
assert_equal(multipart.filesystem.readfile(multipart_paths.upload_path), document);
assert_equal(multipart.filesystem.mode(multipart_paths.upload_path), 0o600);
assert_true(multipart_paths.multipart_path != null, 'curl config omitted multipart body');
assert_equal(multipart.filesystem.mode(multipart_paths.multipart_path), 0o600);
assert_match(multipart_paths.config,
	/header = "Content-Type: multipart\/form-data; boundary=----------------miclash-[0-9a-f]{32}"/);
let multipart_body = multipart.filesystem.readfile(multipart_paths.multipart_path);
assert_match(multipart_body, /name="chat_id"\r\n\r\n42\r\n/);
assert_match(multipart_body, /name="caption"\r\n\r\nMiClash Lite diagnostics\r\n/);
assert_match(multipart_body,
	/name="document"; filename="miclash-diagnostic-lite-1700000000000\.json"\r\nContent-Type: application\/json\r\n\r\n/);
assert_true(index(multipart_body, document) >= 0);
assert_equal(index(multipart_paths.config, '/etc/shadow'), -1);
multipart.filesystem.writefile(multipart_paths.header_path,
	'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n');
multipart.filesystem.writefile(multipart_paths.body_path,
	'{"ok":true,"result":{"message_id":51}}');
assert_equal(multipart_session.complete(0).status, 200);
assert_equal(document_finished, 0,
	'HTTP adapter confirmed delivery before Telegram validated the response');
assert_equal(document_closed, 0,
	'HTTP adapter released a successfully uploaded descriptor before Telegram validation');
assert_equal(length(multipart.filesystem.lsdir('/tmp/miclash/http')), 0);
assert_equal(body_file.finish(), true);
assert_equal(document_finished, 1);

let path_descriptor = environment();
assert_throws(() => http.begin(path_descriptor.runtime, {
	url: 'https://api.telegram.org/bot123456:telegram-secret/sendDocument',
	max_redirects: 0,
	max_bytes: 65536,
	managed: true,
	method: 'POST',
	body_file: {
		path: '/etc/shadow',
		field: 'document',
		filename: 'shadow.txt',
		content_type: 'text/plain',
		fields: { chat_id: '42' }
	}
}), 'INVALID_ARGUMENT');

print('HTTP cancellable session tests passed\n');
