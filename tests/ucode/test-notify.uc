import { assert_equal, assert_throws, assert_true } from './testlib.uc';
import * as fakes from './fakes.uc';
import * as notify from 'miclash.notify';

function clone(value) {
	return json(sprintf('%J', value));
};

function make_event(changes) {
	let value = {
		type: 'failure',
		severity: 'warning',
		component: 'dns',
		title: 'DNS repair failed',
		message: 'Fresh DNS observation remains unhealthy',
		dedupe_key: 'failure/failure-1-1000',
		occurred_at: 1000,
		recovery_of: null,
		context: { failure_id: 'failure-1-1000', reason: 'automatic' }
	};
	for (let name, item in changes ?? {})
		value[name] = item;
	return value;
};

function make_runtime(start) {
	let clock = fakes.clock(start ?? 1000);
	let process = fakes.process();
	let published = [];
	let ubus;
	ubus = {
		connect_calls: 0,
		connect: () => {
			ubus.connect_calls++;
			return {
				send: (channel, event) => {
					push(published, { channel, event: clone(event) });
					return true;
				}
			};
		}
	};
	return { runtime: { clock, process, ubus }, clock, process, ubus, published };
};

function settings(changes) {
	let value = {
		dedupe_window_ms: 1000,
		syslog: { enabled: true, minimum_severity: 'info', types: [], components: [] },
		luci: {
			enabled: true,
			channel: 'miclash.notification',
			minimum_severity: 'info',
			types: [],
			components: []
		}
	};
	for (let name, item in changes ?? {})
		value[name] = item;
	return value;
};

function logger_event(call) {
	return json(call.args[length(call.args) - 1]);
};

// Creation and public input boundaries are exact and bounded.
assert_throws(() => notify.create({}, settings()), 'INVALID_ARGUMENT');
assert_throws(() => notify.create(make_runtime().runtime, []), 'INVALID_ARGUMENT');
assert_throws(() => notify.create(make_runtime().runtime,
	{ ...settings(), unknown: true }), 'INVALID_ARGUMENT');
assert_throws(() => notify.create(make_runtime().runtime,
	{ ...settings(), dedupe_window_ms: 0 }), 'INVALID_ARGUMENT');
assert_throws(() => notify.create(make_runtime().runtime,
	{ ...settings(), luci: { ...settings().luci, channel: 'bad channel' } }),
	'INVALID_ARGUMENT');
assert_throws(() => notify.create(make_runtime().runtime,
	{ ...settings(), syslog: { ...settings().syslog, types: [ 'failure', 'failure' ] } }),
	'INVALID_ARGUMENT');

let invalid_center = notify.create(make_runtime().runtime, settings());
for (let malformed in [
	null,
	{},
	{ ...make_event(), extra: true },
	{ ...make_event(), type: 'Bad Type' },
	{ ...make_event(), severity: 'fatal' },
	{ ...make_event(), component: '../dns' },
	{ ...make_event(), title: '' },
	{ ...make_event(), message: sprintf('%2049s', 'x') },
	{ ...make_event(), dedupe_key: 'bad key' },
	{ ...make_event(), occurred_at: -1 },
	{ ...make_event(), recovery_of: 'bad recovery key' },
	{ ...make_event(), context: [] },
	{ ...make_event(), context: { 'token=key-secret': 'value' } },
	{ ...make_event(), context: { 'safe key': 'value' } }
])
	assert_throws(() => invalid_center.emit(malformed), 'INVALID_ARGUMENT');
assert_throws(() => invalid_center.subscribe(null), 'INVALID_ARGUMENT');
assert_throws(() => invalid_center.subscribe({ name: 'bad channel', send: () => true,
	minimum_severity: 'info', types: [], components: [] }), 'INVALID_ARGUMENT');
assert_throws(() => invalid_center.test('bad channel'), 'INVALID_ARGUMENT');

let too_many_types = [];
for (let i = 0; i < 65; i++) push(too_many_types, 'event' + i);
assert_throws(() => notify.create(make_runtime().runtime, settings({
	syslog: { enabled: true, minimum_severity: 'info', types: too_many_types, components: [] }
})), 'INVALID_ARGUMENT');

let deep_context = { leaf: true };
for (let i = 0; i < 9; i++) deep_context = { node: deep_context };
assert_throws(() => invalid_center.emit(make_event({ context: deep_context })),
	'INVALID_ARGUMENT');
let wide_context = [];
for (let i = 0; i < 128; i++) push(wide_context, { a: i, b: i, c: i, d: i });
assert_throws(() => invalid_center.emit(make_event({ context: { nodes: wide_context } })),
	'INVALID_ARGUMENT');
let byte_context = {};
for (let i = 0; i < 9; i++) byte_context['field' + i] = sprintf('%4096s', 'x');
assert_throws(() => invalid_center.emit(make_event({ context: byte_context })),
	'INVALID_ARGUMENT');

for (let i = 0; i < 32; i++)
	invalid_center.subscribe({ name: 'channel' + i, send: (event) => true,
		minimum_severity: 'info', types: [], components: [] });
assert_throws(() => invalid_center.subscribe({ name: 'channel32', send: (event) => true,
	minimum_severity: 'info', types: [], components: [] }), 'INVALID_ARGUMENT');

// Syslog is argv-only/data-safe, LuCI publishes the same detached redacted event.
let routed = make_runtime();
let center = notify.create(routed.runtime, settings());
let source = make_event({
	title: 'Failure -- $(touch /tmp/pwned)',
	message: 'See https://user:pass@example.test/path?token=query-secret&safe=yes',
	context: {
		auth: 'auth-secret',
		bearer: 'bearer-secret',
		session: 'session-secret',
		private_key: 'private-secret',
		access_key: 'access-secret',
		nested: [
			{ authorization: 'Basic header-secret', cookie: 'cookie-secret' },
			{ safe: 'visible', url: 'https://u:p@example.test/a?access_token=url-secret' }
		]
	}
});
assert_equal(center.emit(source), true);
source.context.safe = 'mutated';
assert_equal(length(routed.process.calls), 1);
let log_call = routed.process.calls[0];
assert_equal(log_call.command, '/usr/bin/logger');
assert_equal(sprintf('%J', log_call.args), sprintf('%J', [
	'-t', 'miclash', '-p', 'daemon.warning', '--', log_call.args[5]
]));
assert_equal(length(routed.published), 1);
assert_equal(routed.published[0].channel, 'miclash.notification');
let logged = logger_event(log_call);
let luci_event = routed.published[0].event;
assert_equal(sprintf('%J', logged), sprintf('%J', luci_event));
assert_equal(logged.context.auth, '[REDACTED]');
assert_equal(logged.context.bearer, '[REDACTED]');
assert_equal(logged.context.session, '[REDACTED]');
assert_equal(logged.context.private_key, '[REDACTED]');
assert_equal(logged.context.access_key, '[REDACTED]');
assert_equal(logged.context.nested[0].authorization, '[REDACTED]');
assert_equal(logged.context.nested[0].cookie, '[REDACTED]');
assert_equal(logged.context.nested[1].safe, 'visible');
assert_equal(logged.message,
	'See https://***:***@example.test/path?token=***&safe=yes');
assert_equal(logged.context.nested[1].url,
	'https://***:***@example.test/a?access_token=***');
assert_equal(center.history()[0].context.safe, null);
let serialized = sprintf('%J', { history: center.history(), calls: routed.process.calls,
	published: routed.published });
for (let secret in [ 'auth-secret', 'bearer-secret', 'session-secret', 'private-secret',
	'access-secret', 'header-secret', 'cookie-secret', 'query-secret', 'url-secret',
	'user:pass', 'u:p' ])
	assert_true(index(serialized, secret) < 0, 'notification boundary leaked ' + secret);
assert_equal(length(routed.process.calls), 1, 'event data never becomes an executable command');
let history_snapshot = center.history();
history_snapshot[0].context.auth = 'injected-secret';
push(history_snapshot, make_event({ context: { token: 'injected-secret' } }));
assert_equal(length(center.history()), 1);
assert_equal(center.history()[0].context.auth, '[REDACTED]');

// Per-channel filters are deterministic; optional sinks receive detached events.
let filtered = make_runtime();
let filtered_center = notify.create(filtered.runtime, settings({
	syslog: {
		enabled: true, minimum_severity: 'error', types: [ 'failure' ], components: [ 'dns' ]
	},
	luci: {
		enabled: true, channel: 'miclash.notification', minimum_severity: 'notice',
		types: [ 'memory_outcome' ], components: [ 'memory' ]
	}
}));
let received = [];
let unsubscribe = filtered_center.subscribe({
	name: 'audit', minimum_severity: 'notice', types: [ 'failure', 'recovery' ],
	components: [ 'dns' ], send: (event) => {
		push(received, clone(event));
		event.context.tamper = true;
		return true;
	}
});
assert_equal(type(unsubscribe), 'function');
filtered_center.emit(make_event({ severity: 'warning', dedupe_key: 'failure/filter-1' }));
assert_equal(length(filtered.process.calls), 0);
assert_equal(length(filtered.published), 0);
assert_equal(length(received), 1);
filtered_center.emit(make_event({
	type: 'memory_outcome', component: 'memory', severity: 'notice',
	title: 'Memory recovery completed', message: 'RSS returned below threshold',
	dedupe_key: 'memory/outcome/memory-1',
	context: { recovery_id: 'memory-1-1000', outcome: 'success' }
}));
assert_equal(length(filtered.published), 1);
assert_equal(length(received), 1);
assert_equal(filtered_center.history()[0].context.tamper, null);
assert_equal(unsubscribe(), true);
assert_equal(unsubscribe(), false);
for (let i = 0; i < 40; i++) {
	let remove = filtered_center.subscribe({
		name: 'temporary', minimum_severity: 'debug', types: [], components: [],
		send: (event) => true
	});
	assert_equal(remove(), true);
};

// A failed built-in or optional sink cannot reject an accepted event.
let isolated = make_runtime();
isolated.process.on_run = () => die('logger unavailable');
isolated.ubus.connect = () => die('ubus unavailable');
let isolated_center = notify.create(isolated.runtime, settings());
let healthy_deliveries = 0;
isolated_center.subscribe({
	name: 'broken', minimum_severity: 'debug', types: [], components: [],
	send: (event) => die('sink unavailable')
});
isolated_center.subscribe({
	name: 'healthy', minimum_severity: 'debug', types: [], components: [],
	send: (event) => { healthy_deliveries++; return true; }
});
assert_equal(isolated_center.emit(make_event()), true);
assert_equal(length(isolated_center.history()), 1);
assert_equal(healthy_deliveries, 1);

// Duplicate failures are suppressed inside the window and deterministically escalate outside it.
let dedupe_env = make_runtime();
let dedupe_center = notify.create(dedupe_env.runtime, settings({
	syslog: { enabled: false, minimum_severity: 'debug', types: [], components: [] },
	luci: { enabled: false, channel: 'miclash.notification', minimum_severity: 'debug',
		types: [], components: [] }
}));
let failure = make_event({ dedupe_key: 'failure/failure-9-1000',
	context: { failure_id: 'failure-9-1000' } });
assert_equal(dedupe_center.emit(failure), true);
assert_equal(dedupe_center.emit(failure), false);
assert_equal(length(dedupe_center.history()), 1);
dedupe_env.clock.advance(1000);
assert_equal(dedupe_center.emit({ ...failure, occurred_at: 2000 }), true);
assert_equal(dedupe_center.history()[1].severity, 'error');
assert_equal(dedupe_center.history()[1].context.occurrences, 2);
dedupe_env.clock.advance(1000);
dedupe_center.emit({ ...failure, occurred_at: 3000 });
assert_equal(dedupe_center.history()[2].severity, 'critical');
dedupe_env.clock.advance(1000);
dedupe_center.emit({ ...failure, occurred_at: 4000 });
assert_equal(dedupe_center.history()[3].severity, 'critical');
assert_throws(() => dedupe_center.emit({ ...failure, occurred_at: 5000,
	component: 'routing' }), 'INVALID_ARGUMENT');
assert_throws(() => dedupe_center.emit({ ...failure, occurred_at: 5000,
	severity: 'critical' }), 'INVALID_ARGUMENT');
assert_throws(() => dedupe_center.emit({ ...failure, occurred_at: 5000,
	title: 'Semantically different failure' }), 'INVALID_ARGUMENT');

let recovery = make_event({
	type: 'recovery', severity: 'notice', title: 'DNS recovered',
	message: 'Fresh observation confirms DNS recovery',
	dedupe_key: 'recovery/failure-9-1000', occurred_at: 5000,
	recovery_of: 'failure/failure-9-1000',
	context: { failure_id: 'failure-9-1000' }
});
assert_throws(() => dedupe_center.emit({ ...recovery, component: 'routing' }),
	'INVALID_ARGUMENT');
assert_equal(dedupe_center.emit(recovery), true);
assert_equal(dedupe_center.history()[4].recovery_of, failure.dedupe_key);
assert_equal(dedupe_center.emit(recovery), false);
assert_throws(() => dedupe_center.emit({ ...recovery,
	dedupe_key: 'recovery/unknown', recovery_of: 'failure/unknown' }), 'INVALID_ARGUMENT');
dedupe_env.clock.advance(1000);
assert_equal(dedupe_center.emit({ ...recovery, occurred_at: 6000 }), false);
assert_equal(dedupe_center.emit({ ...failure, occurred_at: 6000 }), true);
assert_equal(dedupe_center.history()[length(dedupe_center.history()) - 1].severity, 'warning');

// Reconciler-domain events preserve durable failure identity and distinguish Guard behavior.
let lifecycle = make_runtime(10000);
let lifecycle_center = notify.create(lifecycle.runtime, settings({
	syslog: { enabled: false, minimum_severity: 'debug', types: [], components: [] },
	luci: { enabled: false, channel: 'miclash.notification', minimum_severity: 'debug',
		types: [], components: [] }
}));
for (let event in [
	make_event({
		type: 'guard_outage', severity: 'critical', component: 'guard',
		title: 'Guard outage', message: 'Guard could not prove protected routing',
		dedupe_key: 'guard/failure-12-10000', occurred_at: 10000,
		context: { failure_id: 'failure-12-10000', guard_mode: 'enabled' }
	}),
	make_event({
		type: 'fail_closed', severity: 'critical', component: 'mihomo',
		title: 'Internet blocked safely', message: 'Mihomo repair failed while Guard is enabled',
		dedupe_key: 'fail-closed/failure-13-10000', occurred_at: 10000,
		context: { failure_id: 'failure-13-10000', guard_mode: 'enabled' }
	}),
	make_event({
		type: 'direct_fallback', severity: 'warning', component: 'mihomo',
		title: 'Direct fallback active', message: 'Direct reachability was observed after fallback',
		dedupe_key: 'direct-fallback/failure-14-10000', occurred_at: 10000,
		context: { failure_id: 'failure-14-10000', guard_mode: 'disabled' }
	})
])
	assert_equal(lifecycle_center.emit(event), true);
assert_equal(length(lifecycle_center.history()), 3);

function restored(changes) {
	return make_event({
		type: 'internet_restored', severity: 'notice', component: 'network',
		title: 'Internet restored', message: 'Fresh DNS and network observations confirm access',
		dedupe_key: 'internet-restored/failure-14-10000', occurred_at: 10000,
		recovery_of: 'direct-fallback/failure-14-10000',
		context: {
			failure_id: 'failure-14-10000',
			guard: { state: 'ok', enabled: false, observed_at: 10000, generation: 7 },
			dns: { state: 'ok', observed_at: 10000 },
			network: { state: 'ok', observed_at: 10000, path: 'direct', guard_generation: 7 }
		},
		...(changes ?? {})
	});
};
assert_throws(() => lifecycle_center.emit(restored({ context: {
	failure_id: 'failure-14-10000',
	guard: { state: 'unknown', enabled: null, observed_at: 10000, generation: 7 },
	dns: { state: 'ok', observed_at: 10000 },
	network: { state: 'ok', observed_at: 10000, path: 'direct', guard_generation: 7 }
} })), 'INVALID_ARGUMENT');
assert_throws(() => lifecycle_center.emit(restored({ context: {
	failure_id: 'failure-14-10000',
	guard: { state: 'ok', enabled: true, observed_at: 10000, generation: 8 },
	dns: { state: 'ok', observed_at: 10000 },
	network: { state: 'ok', observed_at: 10000, path: 'direct', guard_generation: 8 }
} })), 'INVALID_ARGUMENT');
assert_throws(() => lifecycle_center.emit(restored({ context: {
	failure_id: 'failure-14-10000',
	guard: { state: 'ok', enabled: false, observed_at: 10000, generation: 7 },
	dns: { state: 'ok', observed_at: 1 },
	network: { state: 'ok', observed_at: 10000, path: 'direct', guard_generation: 7 }
} })), 'INVALID_ARGUMENT');
assert_throws(() => lifecycle_center.emit(restored({ context: {
	failure_id: 'failure-14-10000',
	guard: { state: 'ok', enabled: false, observed_at: 10000, generation: 7 },
	dns: { state: 'failed', observed_at: 10000 },
	network: { state: 'ok', observed_at: 10000, path: 'direct', guard_generation: 7 }
} })), 'INVALID_ARGUMENT');
assert_throws(() => lifecycle_center.emit(restored({ context: {
	failure_id: 'failure-14-10000',
	guard: { state: 'ok', enabled: false, observed_at: 10000, generation: 7 },
	dns: { state: 'ok', observed_at: 10000 },
	network: { state: 'ok', observed_at: 10000, path: 'direct', guard_generation: 8 }
} })), 'INVALID_ARGUMENT');
assert_equal(length(lifecycle.process.calls), 0,
	'restoration admission never launches a transient direct probe');
assert_equal(lifecycle_center.emit(restored()), true);
assert_equal(lifecycle_center.history()[length(lifecycle_center.history()) - 1].type,
	'internet_restored');

let guarded_failure = make_event({
	type: 'failure', severity: 'warning', component: 'network',
	title: 'Guarded access failed', message: 'Proxy path is unavailable',
	dedupe_key: 'failure/failure-15-10000', occurred_at: 10000,
	context: { failure_id: 'failure-15-10000' }
});
lifecycle_center.emit(guarded_failure);
let guarded_restored = restored({
	dedupe_key: 'internet-restored/failure-15-10000',
	recovery_of: 'failure/failure-15-10000',
	context: {
		failure_id: 'failure-15-10000',
		guard: { state: 'ok', enabled: true, observed_at: 10000, generation: 9 },
		dns: { state: 'ok', observed_at: 10000 },
		network: { state: 'ok', observed_at: 10000, path: 'proxy', guard_generation: 9 }
	}
});
assert_equal(lifecycle_center.emit(guarded_restored), true);

let ordinary_failure = make_event({
	type: 'failure', component: 'dns', title: 'DNS unavailable',
	message: 'DNS observation failed', dedupe_key: 'failure/failure-16-10000',
	context: { failure_id: 'failure-16-10000' }
});
assert_equal(lifecycle_center.emit(ordinary_failure), true);
assert_equal(lifecycle_center.emit(restored({
	dedupe_key: 'internet-restored/failure-16-10000',
	recovery_of: 'failure/failure-16-10000',
	context: {
		failure_id: 'failure-16-10000',
		guard: { state: 'ok', enabled: false, observed_at: 10000, generation: 10 },
		dns: { state: 'ok', observed_at: 10000 },
		network: { state: 'ok', observed_at: 10000, path: 'direct', guard_generation: 10 }
	}
})), true);

// Memory, subscription and update outcomes use the same structured route.
for (let event in [
	make_event({
		type: 'memory_action', severity: 'info', component: 'memory',
		title: 'Memory recovery action', message: 'Reload stage started',
		dedupe_key: 'memory/action/memory-4/reload', occurred_at: 10000,
		context: { recovery_id: 'memory-4-10000', action: 'reload' }
	}),
	make_event({
		type: 'memory_outcome', severity: 'warning', component: 'memory',
		title: 'Memory recovery failed', message: 'RSS did not fall materially',
		dedupe_key: 'memory/outcome/memory-4', occurred_at: 10000,
		context: { recovery_id: 'memory-4-10000', outcome: 'failed' }
	}),
	make_event({
		type: 'subscription_outcome', severity: 'notice', component: 'subscription',
		title: 'Subscription updated', message: 'Validated profile is active',
		dedupe_key: 'subscription/outcome/operation-7', occurred_at: 10000,
		context: { operation_id: 'operation-7', outcome: 'success', profile: 'config.yaml' }
	}),
	make_event({
		type: 'update_outcome', severity: 'error', component: 'updates',
		title: 'Mihomo update failed', message: 'Previous executable remains active',
		dedupe_key: 'updates/outcome/operation-8', occurred_at: 10000,
		context: { operation_id: 'operation-8', outcome: 'failed', kind: 'mihomo' }
	})
])
	assert_equal(lifecycle_center.emit(event), true);

// Existing producer envelopes normalize before entering history or any sink.
let producer_env = make_runtime(30000);
let producer_center = notify.create(producer_env.runtime, settings({
	syslog: { enabled: false, minimum_severity: 'debug', types: [], components: [] },
	luci: { enabled: false, channel: 'miclash.notification', minimum_severity: 'debug',
		types: [], components: [] }
}));
assert_equal(producer_center.emit({ type: 'failure', data: {
	failure_id: 'failure-21-30000', component: 'guard', reason: 'automatic'
} }), true);
assert_equal(producer_center.history()[0].type, 'guard_outage');
assert_equal(producer_center.history()[0].dedupe_key, 'failure/failure-21-30000');
assert_equal(producer_center.history()[0].context.failure_id, 'failure-21-30000');
assert_equal(producer_center.emit({ type: 'failure', data: {
	failure_id: 'failure-21-30000', component: 'guard', reason: 'automatic'
} }), false);
assert_equal(producer_center.emit({ type: 'recovery', data: {
	failure_id: 'failure-21-30000', component: 'guard', reason: 'scheduled'
} }), true);
assert_equal(producer_center.history()[1].type, 'recovery');
assert_equal(producer_center.history()[1].recovery_of, 'failure/failure-21-30000');

for (let producer in [
	{ input: { type: 'fail_closed', data: {
		failure_id: 'failure-22-30000', component: 'mihomo', reason: 'automatic'
	} }, expected: 'fail_closed' },
	{ input: { type: 'direct_fallback', data: {
		failure_id: 'failure-23-30000', component: 'mihomo', reason: 'automatic'
	} }, expected: 'direct_fallback' },
	{ input: { type: 'memory_recovery_stage', data: {
		recovery_id: 'memory-1-30000', action: 'reload', ready: false,
		material_drop: false, preserve_guard: true
	} }, expected: 'memory_action' },
	{ input: { type: 'memory_recovery', data: {
		recovery_id: 'memory-1-30000', result: 'failed', preserve_guard: true
	} }, expected: 'memory_outcome' },
	{ input: { type: 'operation', data: {
		id: 'operation-31', kind: 'subscription.update', state: 'success',
		source: 'auto', context: { profile: 'config.yaml', token: 'operation-secret' }
	} }, expected: 'subscription_outcome' },
	{ input: { type: 'operation', data: {
		id: 'operation-32', kind: 'updates.mihomo', state: 'failure',
		source: 'luci', context: { private_key: 'update-secret' }
	} }, expected: 'update_outcome' },
	{ input: { type: 'operation', data: {
		id: 'operation-33', kind: 'updates.miclash', state: 'interrupted',
		source: 'system', error: { code: 'INTERRUPTED' }
	} }, expected: 'update_outcome' }
]) {
	assert_equal(producer_center.emit(producer.input), true);
	assert_equal(producer_center.history()[length(producer_center.history()) - 1].type,
		producer.expected);
};
let producer_serialized = sprintf('%J', producer_center.history());
assert_true(index(producer_serialized, 'operation-secret') < 0);
assert_true(index(producer_serialized, 'update-secret') < 0);

assert_throws(() => producer_center.emit({ type: 'internet_restored', data: {
	failure_id: 'failure-23-30000', recovery_of: 'direct-fallback/failure-23-30000',
	guard: { state: 'unknown', enabled: null, observed_at: 30000, generation: 11 },
	dns: { state: 'ok', observed_at: 30000 },
	network: { state: 'ok', observed_at: 30000, path: 'direct', guard_generation: 11 }
} }), 'INVALID_ARGUMENT');
assert_equal(producer_center.emit({ type: 'internet_restored', data: {
	failure_id: 'failure-23-30000', recovery_of: 'direct-fallback/failure-23-30000',
	guard: { state: 'ok', enabled: false, observed_at: 30000, generation: 11 },
	dns: { state: 'ok', observed_at: 30000 },
	network: { state: 'ok', observed_at: 30000, path: 'direct', guard_generation: 11 }
} }), true);
assert_equal(producer_center.history()[length(producer_center.history()) - 1].type,
	'internet_restored');
assert_equal(producer_center.history()[length(producer_center.history()) - 1].recovery_of,
	'direct-fallback/failure-23-30000');

for (let malformed in [
	{ type: 'unknown_producer', data: {} },
	{ type: 'failure', data: { failure_id: '../collision', component: 'dns', reason: 'auto' } },
	{ type: 'operation', data: { id: 'operation-34', kind: 'service.restart', state: 'success' } },
	{ type: 'failure', data: { failure_id: 'failure-33-30000', component: 'dns', reason: 'auto' },
		extra: true }
])
	assert_throws(() => producer_center.emit(malformed), 'INVALID_ARGUMENT');

// Explicit channel tests bypass filters/dedupe/history but still use safe redacted payloads.
let tested = make_runtime(20000);
let tested_center = notify.create(tested.runtime, settings());
let test_received = [];
tested_center.subscribe({
	name: 'external', minimum_severity: 'critical', types: [ 'failure' ], components: [ 'dns' ],
	send: (event) => { push(test_received, clone(event)); return true; }
});
assert_equal(tested_center.test('external'), true);
assert_equal(length(test_received), 1);
assert_equal(test_received[0].type, 'test');
assert_equal(test_received[0].occurred_at, 20000);
assert_equal(length(tested_center.history()), 0);
assert_equal(tested_center.test('syslog'), true);
assert_equal(tested_center.test('luci'), true);
assert_throws(() => tested_center.test('missing'), 'INVALID_ARGUMENT');

// Dedupe state has a deterministic 512-key ceiling and evicts the oldest identity.
let dedupe_bound_env = make_runtime(40000);
let dedupe_bound = notify.create(dedupe_bound_env.runtime, settings({
	syslog: { enabled: false, minimum_severity: 'debug', types: [], components: [] },
	luci: { enabled: false, channel: 'miclash.notification', minimum_severity: 'debug',
		types: [], components: [] }
}));
for (let i = 0; i < 513; i++)
	assert_equal(dedupe_bound.emit(make_event({
		dedupe_key: 'failure/bounded-' + i,
		context: { failure_id: 'bounded-' + i }
	})), true);
assert_equal(dedupe_bound.emit(make_event({ dedupe_key: 'failure/bounded-512',
	context: { failure_id: 'bounded-512' } })), false);
assert_throws(() => dedupe_bound.emit(make_event({
	type: 'recovery', severity: 'notice', title: 'Old failure recovered',
	message: 'Old failure recovery arrived after eviction',
	dedupe_key: 'recovery/bounded-0', recovery_of: 'failure/bounded-0',
	context: { failure_id: 'bounded-0' }
})), 'INVALID_ARGUMENT');

// Latest history is fixed at 200 and the 201st accepted event evicts the oldest.
let bounded = make_runtime(50000);
let bounded_center = notify.create(bounded.runtime, settings({
	dedupe_window_ms: 60000,
	syslog: { enabled: false, minimum_severity: 'debug', types: [], components: [] },
	luci: { enabled: false, channel: 'miclash.notification', minimum_severity: 'debug',
		types: [], components: [] }
}));
for (let i = 0; i < 201; i++)
	assert_equal(bounded_center.emit(make_event({
		type: 'update_outcome', severity: 'info', component: 'updates',
		title: 'Update outcome', message: 'Outcome ' + i,
		dedupe_key: 'updates/outcome/' + i, occurred_at: 50000 + i,
		context: { operation_id: 'operation-' + i, outcome: 'success' }
	})), true);
assert_equal(length(bounded_center.history()), 200);
assert_equal(bounded_center.history()[0].dedupe_key, 'updates/outcome/1');
assert_equal(bounded_center.history()[199].dedupe_key, 'updates/outcome/200');
