import { assert_equal, assert_match, assert_throws, assert_true } from 'testlib';
import * as transport_module from 'miclash.telegram-transport';

function clone(value) { return value == null ? null : json(sprintf('%J', value)); };

function environment(responder) {
	let requests = [];
	let app = {
		runtime: {},
		http: { request: (runtime, request) => {
			push(requests, clone(request));
			let method = match(request.url, /\/([A-Za-z]+)(\?|$)/)?.[1];
			return responder != null ? responder(method, request) : {
				status: 200, headers: {}, body: sprintf('%J', {
					ok: true,
					result: method == 'getUpdates' ? [ { update_id: 12 } ] :
						(method == 'sendMessage' || method == 'editMessageText' ?
							{ message_id: method == 'sendMessage' ? 9 : 10 } : true)
				})
			};
		} }
	};
	return { transport: transport_module.create(app), requests };
};

let settings = { token: '123456:telegram-secret', user_id: '42' };
assert_throws(() => transport_module.create({}), 'INVALID_ARGUMENT');

let env = environment(), transport = env.transport;
let polled = transport.poll(settings, 12);
assert_equal(polled.updates[0].update_id, 12);
assert_equal(polled.retry_after_ms, 0);
let sent = transport.send(settings, '42', 'Ready', { inline_keyboard: [] });
assert_equal(sent.message_id, 9);
let edited = transport.edit(settings, '42', 10, 'Ready', { inline_keyboard: [] });
assert_equal(edited.message_id, 10);
assert_equal(transport.answer(settings, 'callback-1', '').ok, true);
assert_equal(transport.delete(settings, '42', 11), true);
assert_equal(transport.set_commands(settings, 'ru', [
	{ command: 'start', description: 'Открыть панель' }
]), true);

assert_equal(length(env.requests), 6);
for (let request in env.requests) {
	assert_match(request.url, /^https:\/\/api\.telegram\.org\/bot123456:telegram-secret\//);
	assert_equal(request.connect_timeout_ms, 2000);
	assert_equal(request.timeout_ms, 5000);
	assert_equal(request.max_redirects, 0);
	assert_equal(request.max_bytes, 65536);
	assert_equal(request.managed, true);
	assert_equal(sprintf('%J', request.accept_statuses), '[ 429 ]');
}
assert_match(env.requests[0].url, /getUpdates\?/);
assert_match(env.requests[0].url, /offset=13/);
assert_match(env.requests[0].url, /timeout=0/);
assert_match(env.requests[0].url, /allowed_updates=/);
assert_match(env.requests[1].url, /sendMessage\?/);
assert_match(env.requests[1].url, /reply_markup=/);
assert_match(env.requests[2].url, /editMessageText\?/);
assert_match(env.requests[3].url, /answerCallbackQuery\?/);
assert_match(env.requests[4].url, /deleteMessage\?/);
assert_match(env.requests[5].url, /setMyCommands$/);
assert_equal(env.requests[5].method, 'POST');
assert_match(env.requests[5].body, /language_code=ru/);
assert_true(length(env.requests[5].url) < 2048);

for (let invalid in [
	null, {}, { token: '', user_id: '42' },
	{ token: '123456:telegram-secret', user_id: '0' },
	{ token: 'token-in-wrong-shape', user_id: '42' }
])
	assert_throws(() => transport.poll(invalid, 0), 'INVALID_ARGUMENT');
assert_throws(() => transport.poll(settings, -2), 'INVALID_ARGUMENT');
assert_throws(() => transport.send(settings, '42', '', null), 'INVALID_ARGUMENT');
assert_throws(() => transport.send(settings, '42', sprintf('%04100d', 0), null),
	'INVALID_ARGUMENT');
assert_throws(() => transport.edit(settings, '42', 0, 'Ready', null), 'INVALID_ARGUMENT');
assert_throws(() => transport.answer(settings, '', ''), 'INVALID_ARGUMENT');
assert_throws(() => transport.set_commands(settings, 'zh-cn', []), 'INVALID_ARGUMENT');

let limited = environment(() => ({ status: 429, headers: { 'retry-after': '7' },
	body: '{"ok":false,"parameters":{"retry_after":7}}' })).transport;
let limited_poll = limited.poll(settings, -1);
assert_equal(length(limited_poll.updates), 0);
assert_equal(limited_poll.retry_after_ms, 7000);
assert_equal(limited.send(settings, '42', 'Ready', null), null);

for (let reply in [
	{ status: 200, headers: {}, body: 'not-json' },
	{ status: 200, headers: {}, body: '{"ok":"yes","result":true}' },
	{ status: 200, headers: {}, body: '{"ok":true,"result":"wrong"}' },
	{ status: 500, headers: {}, body: '{"ok":false}' },
	{ status: 200, headers: {}, body: sprintf('%070000d', 0) }
]) {
	let broken = environment(() => reply).transport;
	assert_throws(() => broken.delete(settings, '42', 11), 'INVALID_RESPONSE');
}

let thrown = null;
try {
	let failing = environment(() => die('network failed for telegram-secret')).transport;
	failing.send(settings, '42', 'Ready', null);
}
catch (error) { thrown = error; }
assert_true(thrown != null);
assert_equal(index(sprintf('%J', thrown), 'telegram-secret'), -1,
	'transport errors must not expose the bot token');

print('telegram transport tests passed\n');
