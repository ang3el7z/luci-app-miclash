import { assert_equal, assert_match, assert_throws, assert_true } from './testlib.uc';
import * as api from 'miclash.api';
import * as fakes from './fakes.uc';
import * as notify from 'miclash.notify';
import * as telegram from 'miclash.telegram';

let fixture_fs = require('fs');
function fixture_json(name) {
	return json(fixture_fs.readfile('tests/fixtures/telegram/' + name));
};

function clone(value) {
	return value == null ? null : json(sprintf('%J', value));
};

function update(id, text, sender, chat_type) {
	return {
		update_id: id,
		message: {
			message_id: id,
			from: { id: sender ?? 42, is_bot: false, first_name: 'Owner' },
			chat: { id: sender ?? 42, type: chat_type ?? 'private' },
			date: 1710000000,
			text
		}
	};
};

function active_timers(clock) {
	let count = 0;
	for (let timer in clock.timers)
		if (timer.active)
			count++;
	return count;
};

function environment(changes) {
	let options = changes ?? {};
	let filesystem = options.filesystem ?? fakes.fs();
	for (let directory in [ '/etc', '/etc/miclash', '/var', '/var/run', '/var/run/miclash' ])
		if (filesystem.lstat(directory) == null)
			filesystem.mkdir(directory);
	filesystem.set_mode('/etc/miclash', 0o700);
	let clock = options.clock ?? fakes.clock(1710000000000);
	let runtime = {
		fs: filesystem,
		digest: fakes.digest(filesystem),
		clock,
		random: fakes.entropy(),
		paths: { etc: '/etc/miclash', run: '/var/run/miclash', tmp: '/tmp/miclash' }
	};
	let settings = options.settings ?? {
		telegram: { enabled: true, token: '123456:telegram-secret', user_id: '42' }
	};
	let requests = [], poll_replies = options.poll_replies ?? [];
	let http = {
		request: (rt, request) => {
			push(requests, clone(request));
			if (index(request.url, '/getUpdates?') >= 0) {
				let reply = length(poll_replies) ? shift(poll_replies) :
					{ status: 200, headers: {}, body: '{"ok":true,"result":[]}' };
				if (type(reply) == 'string')
					die(reply);
				return clone(reply);
			}
			if (options.send_failure)
				die('DOWNLOAD_FAILED');
			return { status: 200, headers: {}, body: '{"ok":true,"result":{}}' };
		}
	};
	let submitted = [], domain_calls = [], audit = [], logs = [];
	let operations = {
		submit: (kind, source, context, worker) => {
			let record = {
				id: sprintf('0000000001000-%08d-0123456789abcdef', length(submitted) + 1),
				kind, source, state: 'queued'
			};
			push(submitted, { ...record, context: clone(context), worker });
			return record;
		}
	};
	function record_call(method, args) {
		push(domain_calls, { method, args: clone(args) });
	};
	function operation(method, kind, args, source, context) {
		record_call(method, args);
		return operations.submit(kind, source, context ?? {}, () => null);
	};
	let app = {
		runtime,
		http,
		operations,
		settings_get: () => clone(settings),
		status: () => {
			record_call('status', []);
			return { service: { state: 'running' }, token: 'status-secret' };
		},
		health: () => { record_call('health', []); return { state: 'ok', detail: 'healthy' }; },
		memory_status: () => {
			record_call('memory_status', []);
			return { used_percent: 47, token: 'memory-secret' };
		},
		diagnostics_summary: () => {
			record_call('diagnostics_summary', []);
			return { state: 'ok', url: 'https://example.test/?token=diag-secret' };
		},
		logs_read: () => {
			record_call('logs_read', []);
			return 'ready\nAuthorization: Bearer log-secret\n' + sprintf('%05000d', 0);
		},
		service_start: (profile, source) => operation('service_start', 'service.start',
			[ profile, source ], source, { profile }),
		service_stop: (profile, source) => operation('service_stop', 'service.stop',
			[ profile, source ], source, { profile }),
		service_restart: (profile, source) => operation('service_restart', 'service.restart',
			[ profile, source ], source, { profile }),
		service_reload: (profile, source) => operation('service_reload', 'service.reload',
			[ profile, source ], source, { profile }),
		reboot: () => record_call('reboot', []),
		subscription_update: (url, source) => operation('subscription_update',
			'subscription.update', [ url, source ], source, { url }),
		update_miclash: (source) => operation('update_miclash', 'updates.miclash',
			[ source ], source),
		update_mihomo: (source) => operation('update_mihomo', 'updates.mihomo',
			[ source ], source),
		settings_set: (patch, source) => operation('settings_set', 'settings.set',
			[ patch, source ], source, { patch }),
		backup_create: (source) => operation('backup_create', 'backup.create',
			[ source ], source),
		audit: (event) => push(audit, clone(event)),
		logger: {
			info: (message) => push(logs, message),
			warn: (message) => push(logs, message),
			error: (message) => push(logs, message)
		}
	};
	return { app, runtime, filesystem, clock, settings, requests, poll_replies,
		submitted, domain_calls, audit, logs };
};

assert_equal(type(telegram.create), 'function');

let offset_path = '/etc/miclash/telegram-offset.json';

// The command test double must preserve caller arguments instead of manufacturing telegram.
let source_probe = environment();
source_probe.app.service_start('config2.yaml', 'luci');
assert_equal(source_probe.submitted[0].source, 'luci');

// Disabled or incomplete settings never poll, send, or expose credentials.
for (let settings in [
	{},
	{ telegram: { enabled: false, token: '123456:disabled-secret', user_id: '42' } },
	{ telegram: { enabled: true, token: '', user_id: '42' } },
	{ telegram: { enabled: true, token: '123456:missing-user-secret', user_id: '' } }
]) {
	let env = environment({ settings });
	let controller = telegram.create(env.app);
	assert_equal(controller.start(), false);
	assert_equal(controller.poll_once(), false);
	assert_equal(controller.test(), false);
	assert_equal(length(env.requests), 0);
	let encoded = sprintf('%J', controller.status());
	assert_equal(index(encoded, 'disabled-secret'), -1);
	assert_equal(index(encoded, 'missing-user-secret'), -1);
}

// Authorization accepts one normalized ID and private messages only.
let authorized = environment();
let authorized_controller = telegram.create(authorized.app);
assert_equal(authorized_controller.handle_update(
	fixture_json('private-authorized-status-string-id.json')), true);
assert_equal(length(authorized.requests), 1);
let authorized_writes = length(authorized.filesystem.calls.open);
assert_equal(json(authorized.filesystem.readfile(offset_path)).last_update_id, 102);
assert_equal(authorized_controller.handle_update(fixture_json('group-authorized.json')), false);
assert_equal(authorized_controller.handle_update(fixture_json('private-wrong-sender.json')), false);
for (let unsupported in fixture_json('unsupported-updates.json'))
	assert_equal(authorized_controller.handle_update(unsupported), false);
assert_equal(authorized_controller.handle_update(update(108, '/unknown')), false);
assert_equal(length(authorized.submitted), 0);
assert_equal(length(authorized.filesystem.calls.open), authorized_writes,
	'rejected updates wrote durable state');
assert_equal(json(authorized.filesystem.readfile(offset_path)).last_update_id, 102);
assert_equal(authorized_controller.status().last_update_id, 108);
assert_equal(authorized_controller.poll_once(), true);
assert_match(authorized.requests[length(authorized.requests) - 1].url,
	/\/getUpdates\?offset=109&timeout=20/);

// A handled update is consumed once, including rejected/unsupported updates.
let duplicate = fixture_json('private-authorized-reboot.json');
assert_equal(authorized_controller.handle_update(duplicate), false,
	'older update IDs are duplicates after a newer update');
let duplicate_env = environment();
let duplicate_controller = telegram.create(duplicate_env.app);
let original_submit = duplicate_env.app.operations.submit;
let durable_at_submit = null;
duplicate_env.app.operations.submit = (kind, source, context, worker) => {
	durable_at_submit = json(duplicate_env.filesystem.readfile(offset_path));
	return original_submit(kind, source, context, worker);
};
assert_equal(duplicate_controller.handle_update(duplicate), true);
assert_equal(duplicate_controller.handle_update(duplicate), false);
assert_equal(length(duplicate_env.submitted), 1);
assert_equal(duplicate_env.submitted[0].kind, 'system.reboot');
assert_equal(duplicate_env.submitted[0].source, 'telegram');
assert_equal(durable_at_submit.last_update_id, duplicate.update_id,
	'authorized command dispatched before durable offset persistence');
duplicate_env.submitted[0].worker({ stage: () => null });
assert_equal(duplicate_env.domain_calls[0].method, 'reboot');

// Every approved command routes through a domain method and uses source=telegram.
let commands = fixture_json('approved-commands.json');
let command_id = 1000;
for (let command in commands) {
	let env = environment();
	let controller = telegram.create(env.app);
	assert_equal(controller.handle_update(update(++command_id, command.text)), true, command.text);
	if (command.kind != null) {
		assert_equal(length(env.submitted), 1, command.text);
		assert_equal(env.submitted[0].kind, command.kind, command.text);
		assert_equal(env.submitted[0].source, 'telegram', command.text);
	}
	else
		assert_equal(length(env.submitted), 0, command.text);
	if (command.text == '/reboot')
		env.submitted[0].worker({ stage: () => null });
	let expected_calls = command.call == null ? [] : [ command.call ];
	assert_equal(sprintf('%J', env.domain_calls), sprintf('%J', expected_calls), command.text);
	let output = sprintf('%J', env.requests);
	for (let secret in [ 'status-secret', 'memory-secret', 'diag-secret',
		'log-secret', 'url-secret' ])
		assert_equal(index(output, secret), -1, command.text + ' leaked ' + secret);
}

// Commands are exact; /subscription alone, extra args, aliases, and bot suffixes reject.
let exact_env = environment();
let exact_controller = telegram.create(exact_env.app);
for (let text in [ '/status now', '/status@miclash_bot', '/subscription',
	'/subscription https://one.test/a https://two.test/b', '/unknown', ' /status' ])
	assert_equal(exact_controller.handle_update(update(++command_id, text)), false, text);
assert_equal(length(exact_env.submitted), 0);

// Offset advances atomically under the persistent private authority and survives reboot.
let poll_env = environment({ poll_replies: [ {
	status: 200, headers: {}, body: fixture_fs.readfile('tests/fixtures/telegram/poll-updates.json')
} ] });
let poll_controller = telegram.create(poll_env.app);
assert_equal(poll_controller.poll_once(), true);
assert_match(poll_env.requests[0].url, /\/getUpdates\?offset=0&timeout=20/);
assert_equal(poll_env.requests[0].timeout_ms, 30000);
assert_equal(poll_controller.status().last_update_id, 702);
let persisted_bytes = poll_env.filesystem.readfile(offset_path);
assert_true(type(persisted_bytes) == 'string', 'durable Telegram offset was not persisted');
let persisted = json(persisted_bytes);
assert_equal(persisted.last_update_id, 702);
assert_equal(poll_env.filesystem.lstat(offset_path).mode, 0o600);
assert_equal(poll_env.filesystem.lstat(offset_path).uid, 0);
assert_equal(poll_env.filesystem.lstat(offset_path).nlink, 1);
assert_equal(poll_env.filesystem.realpath(offset_path), offset_path);
assert_equal(poll_env.filesystem.readfile('/var/run/miclash/telegram-offset.json'), null);
let recreated = environment({ filesystem: poll_env.filesystem });
let recreated_controller = telegram.create(recreated.app);
assert_equal(recreated_controller.poll_once(), true);
assert_match(recreated.requests[0].url, /\/getUpdates\?offset=703&timeout=20/);

// Simulated reboot clears /var/run but preserves flash state; an approved reboot update
// is still at-most-once and cannot submit a second system operation after boot.
let before_reboot = environment();
let before_reboot_controller = telegram.create(before_reboot.app);
assert_equal(before_reboot_controller.handle_update(duplicate), true);
let durable_bytes = before_reboot.filesystem.readfile(offset_path);
let after_reboot_fs = fakes.fs({ [offset_path]: durable_bytes });
let after_reboot = environment({ filesystem: after_reboot_fs });
let after_reboot_controller = telegram.create(after_reboot.app);
assert_equal(after_reboot_controller.handle_update(duplicate), false);
assert_equal(length(after_reboot.submitted), 0);
assert_equal(after_reboot_controller.status().last_update_id, duplicate.update_id);

// Existing durable state and its authority are authenticated before trust.
let corrupt_offset = environment({ filesystem: fakes.fs({ [offset_path]: '{broken' }) });
assert_throws(() => telegram.create(corrupt_offset.app), 'CORRUPT_STATE');
let wide_offset = environment({ filesystem: fakes.fs({
	[offset_path]: '{"last_update_id":702}\n'
}) });
wide_offset.filesystem.set_mode(offset_path, 0o640);
assert_throws(() => telegram.create(wide_offset.app), 'CORRUPT_STATE');
let foreign_offset = environment({ filesystem: fakes.fs({
	[offset_path]: '{"last_update_id":702}\n'
}) });
foreign_offset.filesystem.set_uid(offset_path, 1000);
assert_throws(() => telegram.create(foreign_offset.app), 'CORRUPT_STATE');
let linked_offset = environment({ filesystem: fakes.fs({
	'/tmp/foreign-offset': '{"last_update_id":702}\n'
}) });
linked_offset.filesystem.set_symlink(offset_path, '/tmp/foreign-offset');
assert_throws(() => telegram.create(linked_offset.app), 'CORRUPT_STATE');
let unsafe_authority = environment();
unsafe_authority.filesystem.set_mode('/etc/miclash', 0o755);
assert_throws(() => telegram.create(unsafe_authority.app), 'INVALID_ARGUMENT');
let swapped_offset = environment({ filesystem: fakes.fs({
	[offset_path]: '{"last_update_id":702}\n'
}) });
swapped_offset.filesystem.on_lstat = (path, count) => {
	if (path == offset_path && count == 2)
		swapped_offset.filesystem.bump_inode(path);
};
assert_throws(() => telegram.create(swapped_offset.app), 'CORRUPT_STATE');
let write_authority_swap = environment();
let write_authority_swap_controller = telegram.create(write_authority_swap.app);
write_authority_swap.filesystem.on_lstat = (path, count) => {
	if (path == offset_path && count == 4)
		write_authority_swap.filesystem.bump_inode('/etc/miclash');
};
assert_equal(write_authority_swap_controller.handle_update(update(703, '/reboot')), false);
assert_equal(length(write_authority_swap.submitted), 0);

// Directory size is mutable metadata and must not invalidate a stable authority identity.
let resized_authority = environment();
let resized_authority_controller = telegram.create(resized_authority.app);
let authority_lstat = resized_authority.filesystem.lstat;
let authority_reads = 0;
resized_authority.filesystem.lstat = (path) => {
	let identity = authority_lstat(path);
	if (path == '/etc/miclash' && identity != null) {
		authority_reads++;
		identity = { ...identity, size: authority_reads == 1 ? 0 : 4096 };
	}
	return identity;
};
assert_equal(resized_authority_controller.handle_update(update(704, '/reboot')), true);
assert_equal(length(resized_authority.submitted), 1);
assert_equal(json(resized_authority.filesystem.readfile(offset_path)).last_update_id, 704);

// A durable write failure is a batch barrier: later updates wait while N retries.
let barrier_document = sprintf('%J', {
	ok: true,
	result: [ update(800, '/reboot'), update(801, '/status', 43) ]
});
let barrier_fs = fakes.fs({ [offset_path]: '{"last_update_id":799}\n' });
let barrier = environment({
	filesystem: barrier_fs,
	poll_replies: [
		{ status: 200, headers: {}, body: barrier_document },
		{ status: 200, headers: {}, body: barrier_document }
	]
});
let barrier_controller = telegram.create(barrier.app);
assert_equal(barrier_controller.start(), true);
barrier.filesystem.fail_on = 'rename';
barrier.clock.advance(0);
assert_equal(barrier_controller.status().last_update_id, 799);
assert_equal(json(barrier.filesystem.readfile(offset_path)).last_update_id, 799);
assert_equal(length(barrier.submitted), 0);
assert_equal(length(barrier.audit), 0, 'later update crossed persistence barrier');
assert_equal(barrier_controller.status().last_error, 'INTERNAL');
assert_equal(barrier_controller.status().retry_after_ms, 1000);
assert_equal(active_timers(barrier.clock), 1);
assert_match(barrier.requests[0].url, /\/getUpdates\?offset=800&timeout=20/);
barrier.filesystem.fail_on = null;
barrier.clock.advance(999);
assert_equal(length(barrier.requests), 1);
assert_equal(active_timers(barrier.clock), 1);
barrier.clock.advance(1);
assert_match(barrier.requests[1].url, /\/getUpdates\?offset=800&timeout=20/);
assert_equal(json(barrier.filesystem.readfile(offset_path)).last_update_id, 800);
assert_equal(barrier_controller.status().last_update_id, 801);
assert_equal(length(barrier.submitted), 1);
assert_equal(barrier_controller.status().retry_after_ms, 0);
assert_equal(active_timers(barrier.clock), 1);

// Telegram 429 honors retry_after; network failures back off exponentially.
let limited_poll = environment({ poll_replies: [ {
	status: 429,
	headers: { 'retry-after': '7' },
	body: '{"ok":false,"error_code":429,"parameters":{"retry_after":7}}'
} ] });
let limited_controller = telegram.create(limited_poll.app);
assert_equal(limited_controller.poll_once(), false);
assert_equal(limited_controller.status().retry_after_ms, 7000);
let network = environment({ poll_replies: [ 'DOWNLOAD_FAILED', 'DOWNLOAD_FAILED' ] });
let network_controller = telegram.create(network.app);
assert_equal(network_controller.poll_once(), false);
assert_equal(network_controller.status().retry_after_ms, 1000);
assert_equal(network_controller.poll_once(), false);
assert_equal(network_controller.status().retry_after_ms, 2000);

// Start/stop controls one timer; the process timeout stays above long-poll timeout.
let lifecycle = environment();
let lifecycle_controller = telegram.create(lifecycle.app);
assert_equal(lifecycle_controller.start(), true);
assert_equal(lifecycle_controller.start(), false);
assert_equal(lifecycle_controller.status().running, true);
lifecycle.clock.advance(0);
assert_true(length(lifecycle.requests) >= 1);
assert_equal(lifecycle_controller.stop(), true);
assert_equal(lifecycle_controller.stop(), false);
assert_equal(lifecycle_controller.status().running, false);

// Poll dispatch uses its validated settings snapshot; no handler-level reread can fail.
let snapshot = environment({ poll_replies: [ {
	status: 200,
	headers: {},
	body: sprintf('%J', { ok: true, result: [ update(900, '/reboot') ] })
} ] });
let snapshot_reads = 0;
snapshot.app.settings_get = () => {
	snapshot_reads++;
	if (snapshot_reads <= 2)
		return clone(snapshot.settings);
	die('INTERNAL');
};
let snapshot_controller = telegram.create(snapshot.app);
assert_equal(snapshot_controller.start(), true);
snapshot.clock.advance(0);
assert_equal(snapshot_reads, 2, 'poll handler reread validated settings');
assert_equal(length(snapshot.submitted), 1);
assert_equal(active_timers(snapshot.clock), 1);
let snapshot_requests = length(snapshot.requests);
snapshot.clock.advance(10);
assert_equal(snapshot_controller.status().last_error, 'SETTINGS_UNAVAILABLE');
assert_equal(snapshot_controller.status().retry_after_ms, 1000);
assert_equal(length(snapshot.requests), snapshot_requests);
assert_equal(active_timers(snapshot.clock), 1);
snapshot.clock.advance(999);
assert_equal(length(snapshot.requests), snapshot_requests);
assert_equal(active_timers(snapshot.clock), 1);

// A live controller becomes inactive without a tight loop when settings are disabled/incomplete.
for (let change in [ 'disabled', 'incomplete' ]) {
	let inactive = environment();
	let inactive_controller = telegram.create(inactive.app);
	assert_equal(inactive_controller.start(), true);
	if (change == 'disabled')
		inactive.settings.telegram.enabled = false;
	else
		inactive.settings.telegram.token = '';
	inactive.clock.advance(0);
	assert_equal(inactive_controller.status().running, false, change);
	assert_equal(active_timers(inactive.clock), 0, change);
	assert_equal(length(inactive.requests), 0, change);
	inactive.clock.advance(60000);
	assert_equal(active_timers(inactive.clock), 0, change + ' rescheduled');
	assert_equal(length(inactive.requests), 0, change + ' polled');
}

// A settings read error remains distinguishable and retries with bounded backoff, not 10ms.
let settings_error = environment();
let settings_error_controller = telegram.create(settings_error.app);
assert_equal(settings_error_controller.start(), true);
settings_error.app.settings_get = () => die('INTERNAL');
settings_error.clock.advance(0);
assert_equal(settings_error_controller.status().running, true);
assert_equal(settings_error_controller.status().last_error, 'SETTINGS_UNAVAILABLE');
assert_equal(settings_error_controller.status().retry_after_ms, 1000);
assert_equal(active_timers(settings_error.clock), 1);
assert_equal(length(settings_error.requests), 0);
settings_error.clock.advance(999);
assert_equal(active_timers(settings_error.clock), 1);
assert_equal(length(settings_error.requests), 0);
settings_error.clock.advance(1);
assert_equal(settings_error_controller.status().retry_after_ms, 2000);
assert_equal(active_timers(settings_error.clock), 1);
assert_equal(length(settings_error.requests), 0);

// The authorized command limiter is bounded and audited without IDs, token, URL, or text.
let rate = environment();
let rate_controller = telegram.create(rate.app);
let rate_update = fixture_json('rate-limit.json');
for (let index = 0; index < 5; index++) {
	let candidate = clone(rate_update);
	candidate.update_id += index;
	assert_equal(rate_controller.handle_update(candidate), true);
}
let rejected = clone(rate_update);
rejected.update_id += 5;
assert_equal(rate_controller.handle_update(rejected), false);
assert_equal(rate.audit[length(rate.audit) - 1].result, 'rate_limited');
let audit_text = sprintf('%J', rate.audit);
for (let secret in [ '42', 'telegram-secret', '/status', 'url-secret' ])
	assert_equal(index(audit_text, secret), -1, 'audit leaked ' + secret);

// Status, settings and logs are redacted at source; sending failures are isolated.
let masking = environment({ send_failure: true });
let masking_controller = telegram.create(masking.app);
assert_equal(masking_controller.test(), false);
assert_equal(masking_controller.send_event({
	type: 'failure', severity: 'error', component: 'routing',
	title: 'Routing failed', message: 'https://user:pass@example.test/?token=event-secret',
	dedupe_key: 'failure/failure-1-1710000000000', occurred_at: 1710000000000,
	recovery_of: null, context: { authorization: 'Bearer context-secret' }
}), false);
let public_state = sprintf('%J', masking_controller.status());
for (let secret in [ 'telegram-secret', 'event-secret', 'context-secret', 'user:pass', '42' ])
	assert_equal(index(public_state, secret), -1, 'public state leaked ' + secret);
assert_true(length(masking.logs) == 0 || index(sprintf('%J', masking.logs), 'telegram-secret') < 0);

// Every notification family has a concise, redacted and URL-adapter-bounded format.
let notification_cases = [
	[ 'failure', 'Failure' ],
	[ 'recovery', 'Recovery' ],
	[ 'update_outcome', 'Update' ],
	[ 'subscription_outcome', 'Subscription' ],
	[ 'memory_outcome', 'Memory' ],
	[ 'guard_outage', 'Guard%20outage' ]
];
for (let item in notification_cases) {
	let family = environment();
	let family_controller = telegram.create(family.app);
	assert_equal(family_controller.send_event({
		type: item[0], severity: 'warning', component: 'test',
		title: 'Family title',
		message: 'Family message https://user:pass@example.test/?token=family-secret ' +
			sprintf('%01000d', 0),
		dedupe_key: 'family/test', occurred_at: 1710000000000,
		recovery_of: null, context: { authorization: 'Bearer context-secret' }
	}), true, item[0]);
	let request_url = family.requests[0].url;
	assert_true(index(request_url, 'text=' + item[1] + '%3A%20') >= 0,
		item[0] + ': ' + request_url);
	assert_true(length(request_url) <= 2048, item[0] + ' was not bounded');
	for (let secret in [ 'family-secret', 'context-secret', 'user:pass' ])
		assert_equal(index(request_url, secret), -1, item[0] + ' leaked ' + secret);
}

// Notification subscription formats supported events and isolates Telegram failure.
let notify_env = environment({ send_failure: true });
let notify_controller = telegram.create(notify_env.app);
let runtime = {
	clock: notify_env.clock,
	random: notify_env.app.runtime.random,
	process: fakes.process(),
	ubus: { connect: () => ({ send: () => true }) }
};
let center = notify.create(runtime, {
	dedupe_window_ms: 1000,
	syslog: { enabled: false, minimum_severity: 'debug', types: [], components: [] },
	luci: { enabled: false, channel: 'miclash.notify', minimum_severity: 'debug',
		types: [], components: [] }
});
center.subscribe(notify.telegram_channel(notify_controller));
let healthy_deliveries = 0;
center.subscribe({
	name: 'healthy', minimum_severity: 'debug', types: [], components: [],
	send: () => { healthy_deliveries++; return true; }
});
assert_equal(center.emit({
	type: 'guard_outage', severity: 'critical', component: 'guard',
	title: 'Guard outage', message: 'Protected routing unavailable',
	dedupe_key: 'guard/failure-9-1710000000000', occurred_at: 1710000000000,
	recovery_of: null, context: { failure_id: 'failure-9-1710000000000' }
}), true);
assert_equal(healthy_deliveries, 1);

// API exposes only redacted Telegram reads and an isolated channel test.
let api_env = environment();
let controller = telegram.create(api_env.app);
assert_equal(sprintf('%J', sort(keys(controller))), sprintf('%J', sort([
	'start', 'stop', 'status', 'test', 'poll_once', 'handle_update', 'send_event'
])));
let minimal_app = {
	status: () => ({}), health: () => ({}), operation_get: () => null,
	operation_list: () => [], service_start: () => ({ id: 'op-1' }),
	service_stop: () => ({ id: 'op-1' }), service_reload: () => ({ id: 'op-1' }),
	service_restart: () => ({ id: 'op-1' }), config_list: () => [],
	config_read: () => '', config_read_draft: () => '',
	config_save_draft: () => ({ id: 'op-1' }), config_validate: () => ({ id: 'op-1' }),
	config_apply: () => ({ id: 'op-1' }), settings_get: () => ({}),
	settings_set: () => ({ id: 'op-1' }), set_draining: () => null,
	telegram_status: () => controller.status(),
	telegram_settings: () => api_env.settings.telegram,
	telegram_test: () => controller.test()
};
let methods = api.method_table(minimal_app);
assert_true(methods.telegram_status != null);
assert_true(methods.telegram_settings != null);
assert_true(methods.telegram_test != null);
assert_equal(length(keys(methods.telegram_status.args)), 0);
assert_equal(length(keys(methods.telegram_settings.args)), 0);
assert_equal(length(keys(methods.telegram_test.args)), 0);
let telegram_settings = methods.telegram_settings.call({ args: {} });
assert_equal(telegram_settings.token, '[REDACTED]');
assert_equal(telegram_settings.user_id, api_env.settings.telegram.user_id);
assert_equal(methods.telegram_test.call({ args: {} }).sent, true);
