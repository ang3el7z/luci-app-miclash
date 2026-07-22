import * as poller_runtime from 'miclash.telegram-poller-runtime';
import { assert_equal, assert_true } from 'testlib';

function environment(options) {
	let timers = [], processes = [], signals = [], ingested = [], disconnects = 0, ended = 0;
	let enabled = options?.enabled !== false;
	let connection = {
		call: (object, method, payload) => {
			if (method == 'telegram_status')
				return { last_update_id: 10 };
			if (method == 'telegram_ingest') {
				push(ingested, payload.update);
				return { retryable: false };
			}
			return null;
		},
		disconnect: () => { disconnects++; }
	};
	let app = {
		load_settings: () => ({ telegram: enabled ? {
			enabled: true,
			token: '123456:telegram-secret',
			user_id: '42',
			poll_timeout_seconds: 25
		} : { enabled: false } }),
		connect: () => options?.connect_failure ? null : connection,
		transport: {
			prepare_poll: (settings, offset, timeout) => ({
				request: { url: 'secure-request', timeout_ms: (timeout + 5) * 1000 },
				complete: (reply) => ({ updates: reply.updates, retry_after_ms: 0 })
			})
		},
		http: {
			begin: (runtime, request) => {
				let aborted = false;
				return {
					command: '/usr/bin/curl', args: [ '--config', '/tmp/opaque' ],
					complete: (code) => {
						if (code != 0) die('DOWNLOAD_FAILED');
						return { updates: [ { update_id: 11 } ] };
					},
					abort: () => { aborted = true; return true; },
					was_aborted: () => aborted
				};
			}
		},
		runtime: {},
		poll_timeout_seconds: () => 25,
		retry_delay_ms: () => 1000,
		timer: (delay, callback) => {
			let timer = { delay, callback, active: true };
			timer.cancel = () => { timer.active = false; return true; };
			push(timers, timer);
			return timer;
		},
		process: (command, args, callback) => {
			let process = { command, args, callback, pid: 4242 };
			push(processes, process);
			return process;
		},
		signal_process: (pid, signal) => {
			push(signals, { pid, signal });
			return true;
		},
		end: () => { ended++; },
		logger: { warn: () => {} }
	};
	return { app, timers, processes, signals, ingested,
		disconnects: () => disconnects, ended: () => ended };
};

let normal = environment();
let normal_poller = poller_runtime.create(normal.app);
normal_poller.start();
assert_equal(length(normal.processes), 1);
normal.processes[0].callback(0);
assert_equal(length(normal.ingested), 1);
assert_equal(normal.ingested[0].update_id, 11);
assert_equal(normal.disconnects(), 1);
assert_equal(normal.timers[length(normal.timers) - 1].delay, 0,
	'successful polling rearms immediately');

let disabled = environment({ enabled: false });
poller_runtime.create(disabled.app).start();
assert_equal(length(disabled.processes), 0);
assert_equal(disabled.timers[0].delay, 1000);

let stopping = environment();
let stopping_poller = poller_runtime.create(stopping.app);
stopping_poller.start();
assert_equal(length(stopping.processes), 1);
stopping_poller.shutdown();
stopping_poller.shutdown();
assert_equal(sprintf('%J', stopping.signals),
	sprintf('%J', [ { pid: 4242, signal: 'TERM' } ]),
	'TERM is sent once');
assert_equal(stopping.ended(), 0, 'loop waits for the child callback');
let escalation = stopping.timers[length(stopping.timers) - 1];
assert_equal(escalation.delay, 1000);
escalation.callback();
assert_equal(sprintf('%J', stopping.signals),
	sprintf('%J', [
		{ pid: 4242, signal: 'TERM' },
		{ pid: 4242, signal: 'KILL' }
	]));
stopping.processes[0].callback(143);
assert_equal(stopping.disconnects(), 1);
assert_equal(stopping.ended(), 1);
assert_equal(length(stopping.processes), 1,
	'shutdown must never rearm polling');

let idle = environment({ enabled: false });
let idle_poller = poller_runtime.create(idle.app);
idle_poller.start();
idle_poller.shutdown();
assert_equal(idle.timers[0].active, false);
assert_equal(idle.ended(), 1);

print('Telegram poller runtime tests passed\n');
