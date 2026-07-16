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
	let entropy_sequence = 0;
	return { runtime: { clock, process, ubus,
		random: { hex: () => sprintf('%032x', ++entropy_sequence) }
	}, clock, process, ubus, published };
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

function percent_all(value) {
	let output = '';
	for (let offset = 0; offset < length(value); offset++)
		output += sprintf('%%%02X', ord(value, offset));
	return output;
};

function percent_mixed(value) {
	let output = '';
	for (let offset = 0; offset < length(value); offset++)
		output += offset % 2 ? substr(value, offset, 1) :
			sprintf('%%%02x', ord(value, offset));
	return output;
};

function text_of_length(count) {
	let output = '';
	for (let i = 0; i < count; i++)
		output += 'x';
	return output;
};

function context_of_bytes(target) {
	let output = {};
	for (let i = 0; i < 8; i++)
		output['padding' + i] = '';
	let remaining = target - length(sprintf('%J', output));
	for (let i = 0; i < 8; i++) {
		let size = min(4096, remaining);
		output['padding' + i] = text_of_length(size);
		remaining -= size;
	}
	assert_equal(remaining, 0);
	assert_equal(length(sprintf('%J', output)), target);
	return output;
};

function assert_exact_event(value) {
	assert_equal(join(',', sort(keys(value))),
		'component,context,dedupe_key,message,occurred_at,recovery_of,severity,title,type');
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
assert_throws(() => invalid_center.emit(make_event({ component: 'api_secret' })),
	'INVALID_ARGUMENT');
assert_throws(() => invalid_center.emit(make_event({ type: 'token_event' })),
	'INVALID_ARGUMENT');
assert_throws(() => invalid_center.emit(make_event({ component: 'apikey' })),
	'INVALID_ARGUMENT');
assert_throws(() => invalid_center.emit(make_event({ type: 'clientsecret' })),
	'INVALID_ARGUMENT');
assert_throws(() => invalid_center.emit(make_event({
	dedupe_key: 'failure/apiSecret-deadbeef'
})), 'INVALID_ARGUMENT');
assert_throws(() => invalid_center.emit(make_event({
	dedupe_key: 'failure/deadbeef42', context: { token: 'deadbeef42' }
})), 'INVALID_ARGUMENT');
let secret_identity = notify.create(make_runtime().runtime, settings());
assert_throws(() => {
	secret_identity.emit(make_event({ dedupe_key: 'failure/api_secret-deadbeef' }));
	secret_identity.emit(make_event({
		type: 'recovery', severity: 'notice', title: 'Recovered', message: 'Recovered',
		dedupe_key: 'recovery/safe-id', recovery_of: 'failure/api_secret-deadbeef'
	}));
}, 'INVALID_ARGUMENT');

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

// URL userinfo contributes raw and percent-decoded aliases before any sink.
let url_alias_env = make_runtime(900);
let url_alias_center = notify.create(url_alias_env.runtime, settings());
let url_alias_optional = [];
url_alias_center.subscribe({
	name: 'url-alias-capture', minimum_severity: 'debug', types: [], components: [],
	send: (event) => { push(url_alias_optional, clone(event)); return true; }
});
assert_throws(() => url_alias_center.emit(make_event({
	dedupe_key: 'failure/pass',
	message: 'Probe failed at https://user:pass@example.test/path'
})), 'INVALID_ARGUMENT');
assert_equal(length(url_alias_center.history()), 0);
assert_equal(length(url_alias_env.process.calls), 0);
assert_equal(length(url_alias_env.published), 0);
assert_equal(length(url_alias_optional), 0);

assert_equal(url_alias_center.emit(make_event({
	dedupe_key: 'failure/url-alias-safe',
	title: 'Credentials user pass were rejected',
	message: 'Probe failed at https://u%73er:p%61ss@example.test/path',
	context: { aliases: 'user pass u%73er p%61ss' }
})), true);
let url_alias_serialized = sprintf('%J', {
	history: url_alias_center.history(), calls: url_alias_env.process.calls,
	published: url_alias_env.published, optional: url_alias_optional
});
for (let alias in [ 'user', 'pass', 'u%73er', 'p%61ss' ])
	assert_true(index(url_alias_serialized, alias) < 0,
		'URL credential alias leaked ' + alias);
assert_equal(length(url_alias_center.history()), 1);
assert_equal(length(url_alias_env.process.calls), 1);
assert_equal(length(url_alias_env.published), 1);
assert_equal(length(url_alias_optional), 1);

assert_equal(url_alias_center.emit(make_event({
	dedupe_key: 'failure/url-alias-adjacent',
	title: 'Adjacent credential aliases were rejected',
	message: 'https://alpha:bravo@one.test,https://charlie:delta@two.test',
	context: { aliases: 'alpha bravo charlie delta' }
})), true);
let adjacent_url_serialized = sprintf('%J', {
	history: url_alias_center.history(), calls: url_alias_env.process.calls,
	published: url_alias_env.published, optional: url_alias_optional
});
for (let alias in [ 'alpha', 'bravo', 'charlie', 'delta' ])
	assert_true(index(adjacent_url_serialized, alias) < 0,
		'adjacent URL credential alias leaked ' + alias);
assert_equal(length(url_alias_center.history()), 2);
assert_equal(length(url_alias_env.process.calls), 2);
assert_equal(length(url_alias_env.published), 2);
assert_equal(length(url_alias_optional), 2);

assert_equal(url_alias_center.emit(make_event({
	dedupe_key: 'failure/url-alias-multiple-at',
	title: 'Malformed authority credential aliases were rejected',
	message: 'Probe failed at https://user@proxy:pass@host.test/path',
	context: { alias: 'pass' }
})), true);
let multiple_at_serialized = sprintf('%J', {
	history: url_alias_center.history(), calls: url_alias_env.process.calls,
	published: url_alias_env.published, optional: url_alias_optional
});
assert_true(index(multiple_at_serialized, 'pass') < 0,
	'multiple-at URL password alias leaked');
assert_equal(length(url_alias_center.history()), 3);
assert_equal(length(url_alias_env.process.calls), 3);
assert_equal(length(url_alias_env.published), 3);
assert_equal(length(url_alias_optional), 3);

assert_throws(() => url_alias_center.emit(make_event({
	dedupe_key: 'failure/url-alias-short',
	message: 'Short credentials https://u:p@short.test/path',
	context: { aliases: 'u p' }
})), 'INVALID_ARGUMENT');
assert_equal(length(url_alias_center.history()), 3);
assert_equal(length(url_alias_env.process.calls), 3);
assert_equal(length(url_alias_env.published), 3);
assert_equal(length(url_alias_optional), 3);

assert_throws(() => url_alias_center.emit(make_event({
	dedupe_key: 'failure/alias-case',
	context: {
		password: 'authorizationHeader',
		authorizationHeader: 'other-sensitive-value'
	}
})), 'INVALID_ARGUMENT');
assert_equal(length(url_alias_center.history()), 3);
assert_equal(length(url_alias_env.process.calls), 3);
assert_equal(length(url_alias_env.published), 3);
assert_equal(length(url_alias_optional), 3);

// Sensitive values are strings or fail closed before history and every sink.
let scalar_secret_env = make_runtime(950);
let scalar_secret_center = notify.create(scalar_secret_env.runtime, settings());
let scalar_secret_optional = [];
scalar_secret_center.subscribe({
	name: 'scalar-capture', minimum_severity: 'debug', types: [], components: [],
	send: (event) => { push(scalar_secret_optional, clone(event)); return true; }
});
for (let scalar_case in [
	{ value: 123456, suffix: '123456' },
	{ value: true, suffix: 'bool' },
	{ value: null, suffix: 'null' }
])
	assert_throws(() => scalar_secret_center.emit(make_event({
		dedupe_key: 'failure/' + scalar_case.suffix,
		message: 'Sensitive scalar alias ' + scalar_case.suffix,
		context: { token: scalar_case.value }
	})), 'INVALID_ARGUMENT');
assert_equal(length(scalar_secret_center.history()), 0);
assert_equal(length(scalar_secret_env.process.calls), 0);
assert_equal(length(scalar_secret_env.published), 0);
assert_equal(length(scalar_secret_optional), 0);

// Syslog is argv-only/data-safe, LuCI publishes the same detached redacted event.
let routed = make_runtime();
let center = notify.create(routed.runtime, settings());
let optional_events = [];
center.subscribe({
	name: 'capture', minimum_severity: 'debug', types: [], components: [],
	send: (event) => { push(optional_events, clone(event)); return true; }
});
let encoded_secret = 'encoded-secret-value';
let encoded_base64 = b64enc(encoded_secret);
let encoded_percent = percent_all(encoded_secret);
let encoded_mixed = percent_mixed(encoded_secret);
let source = make_event({
	title: 'Failure proxy_password=title-password-secret -- $(touch /tmp/pwned)',
	message: 'Bearer message-bearer-secret password=plain-password-secret ' +
		'encoded=' + encoded_base64 + ' percent=' + encoded_percent +
		' mixed=' + encoded_mixed +
		' See https://url-user:url-credential@example.test/path?token=query-secret&safe=yes',
	context: {
		auth: 'auth-secret',
		credential: 'bearer-secret',
		session: 'session-secret',
		private_key: 'private-secret',
		access_key: 'access-secret',
		proxy_password: 'proxy-password-secret',
		api_secret: 'api-secret-value',
		secret_key: 'root-secret-key-value',
		x_api_key: 'x-api-key-value',
		signing_key: 'signing-key-value',
		ssh_key: 'ssh-key-value',
		token_value: 'token-value-secret',
		apiSecret: 'camel-api-secret',
		proxyPassword: 'camel-proxy-password',
		authorizationHeader: 'camel-authorization-header',
		sessionId: 'camel-session-id',
		cookieValue: 'camel-cookie-value',
		bearerToken: 'camel-bearer-token',
		xAPIKey: 'acronym-api-key',
		encoded_token: encoded_secret,
		nested_meta: {
			dedupe_key: 'nested-dedupe-secret',
			recovery_of: 'nested-recovery-secret'
		},
		nested: [
			{ authorization: 'Basic header-secret',
				cookie: 'sid=cookie-secret; csrf="cookie-second-secret"' },
			{ safe: 'visible', url: 'https://nested-user:nested-pass@example.test/a?access_token=url-secret' }
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
assert_equal(logged.context.credential, '[REDACTED]');
assert_equal(logged.context.session, '[REDACTED]');
assert_equal(logged.context.private_key, '[REDACTED]');
assert_equal(logged.context.access_key, '[REDACTED]');
assert_equal(logged.context.proxy_password, '[REDACTED]');
assert_equal(logged.context.api_secret, '[REDACTED]');
assert_equal(logged.context.secret_key, '[REDACTED]');
assert_equal(logged.context.x_api_key, '[REDACTED]');
assert_equal(logged.context.signing_key, '[REDACTED]');
assert_equal(logged.context.ssh_key, '[REDACTED]');
assert_equal(logged.context.token_value, '[REDACTED]');
assert_equal(logged.context.apiSecret, '[REDACTED]');
assert_equal(logged.context.proxyPassword, '[REDACTED]');
assert_equal(logged.context.authorizationHeader, '[REDACTED]');
assert_equal(logged.context.sessionId, '[REDACTED]');
assert_equal(logged.context.cookieValue, '[REDACTED]');
assert_equal(logged.context.bearerToken, '[REDACTED]');
assert_equal(logged.context.xAPIKey, '[REDACTED]');
assert_equal(logged.context.nested_meta.dedupe_key, '[REDACTED]');
assert_equal(logged.context.nested_meta.recovery_of, '[REDACTED]');
assert_equal(logged.context.encoded_token, '[REDACTED]');
assert_equal(logged.context.nested[0].authorization, '[REDACTED]');
assert_equal(logged.context.nested[0].cookie, '[REDACTED]');
assert_equal(logged.context.nested[1].safe, 'visible');
assert_equal(logged.message,
	'Bearer [REDACTED] password=[REDACTED] ' +
	'encoded=[REDACTED] percent=[REDACTED] mixed=[REDACTED] ' +
	'See https://***:***@example.test/path?token=***&safe=yes');
assert_equal(logged.context.nested[1].url,
	'https://***:***@example.test/a?access_token=***');
assert_equal(center.history()[0].context.safe, null);
let serialized = sprintf('%J', { history: center.history(), calls: routed.process.calls,
	published: routed.published, optional: optional_events });
for (let secret in [ 'auth-secret', 'bearer-secret', 'session-secret', 'private-secret',
	'access-secret', 'header-secret', 'cookie-secret', 'query-secret', 'url-secret',
	'cookie-second-secret', 'proxy-password-secret', 'api-secret-value',
	'root-secret-key-value', 'x-api-key-value', 'signing-key-value', 'ssh-key-value',
	'token-value-secret', 'nested-dedupe-secret', 'nested-recovery-secret',
	'camel-api-secret', 'camel-proxy-password', 'camel-authorization-header',
	'camel-session-id', 'camel-cookie-value', 'camel-bearer-token', 'acronym-api-key',
	'title-password-secret', 'message-bearer-secret', 'plain-password-secret',
	encoded_secret, encoded_base64, encoded_percent, encoded_mixed,
	'url-user:url-credential',
	'nested-user:nested-pass' ])
	assert_true(index(serialized, secret) < 0, 'notification boundary leaked ' + secret);
assert_equal(length(optional_events), 1);
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

// Internal occurrence enrichment is included in the final context byte bound.
let context_bound_env = make_runtime(3500);
let context_bound = notify.create(context_bound_env.runtime, settings({
	syslog: { enabled: false, minimum_severity: 'debug', types: [], components: [] },
	luci: { enabled: false, channel: 'miclash.notification', minimum_severity: 'debug',
		types: [], components: [] }
}));
assert_throws(() => context_bound.emit(make_event({
	dedupe_key: 'failure/context-bound', occurred_at: 3500,
	context: context_of_bytes(32768)
})), 'RESPONSE_TOO_LARGE');
assert_equal(length(context_bound.history()), 0);
	assert_equal(context_bound.emit(make_event({
	dedupe_key: 'failure/context-bound', occurred_at: 3500,
	context: context_of_bytes(32750)
})), true);
assert_equal(context_bound.history()[0].context.occurrences, 1);
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

let window_env = make_runtime(7000);
let window_center = notify.create(window_env.runtime, settings({
	syslog: { enabled: false, minimum_severity: 'debug', types: [], components: [] },
	luci: { enabled: false, channel: 'miclash.notification', minimum_severity: 'debug',
		types: [], components: [] }
}));
let window_event = make_event({ dedupe_key: 'failure/window-boundary', occurred_at: 7000 });
assert_equal(window_center.emit(window_event), true);
window_env.clock.advance(999);
assert_equal(window_center.emit({ ...window_event, occurred_at: 7999 }), false);
window_env.clock.advance(1);
assert_equal(window_center.emit({ ...window_event, occurred_at: 8000 }), true);

let rollback_env = make_runtime(9000);
let rollback_center = notify.create(rollback_env.runtime, settings({
	syslog: { enabled: false, minimum_severity: 'debug', types: [], components: [] },
	luci: { enabled: false, channel: 'miclash.notification', minimum_severity: 'debug',
		types: [], components: [] }
}));
let rollback_event = make_event({ dedupe_key: 'failure/clock-rollback', occurred_at: 9000 });
assert_equal(rollback_center.emit(rollback_event), true);
rollback_env.clock.advance(-2000);
assert_equal(rollback_center.emit({ ...rollback_event, occurred_at: 7000 }), true);

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

function guard_matrix_case(index_value, outage_type, guard_enabled, path, expected) {
	let env = make_runtime(12000);
	let center_value = notify.create(env.runtime, settings({
		syslog: { enabled: false, minimum_severity: 'debug', types: [], components: [] },
		luci: { enabled: false, channel: 'miclash.notification', minimum_severity: 'debug',
			types: [], components: [] }
	}));
	let id = 'failure-' + (100 + index_value) + '-12000';
	let target = (outage_type == 'direct_fallback' ? 'direct-fallback/' :
		(outage_type == 'fail_closed' ? 'fail-closed/' : 'failure/')) + id;
	let component = outage_type == 'guard_outage' ? 'guard' :
		(outage_type == 'failure' ? 'dns' : 'mihomo');
	center_value.emit(make_event({
		type: outage_type,
		severity: outage_type == 'guard_outage' || outage_type == 'fail_closed' ?
			'critical' : 'warning',
		component, title: 'Outage active', message: 'Outage requires a fresh recovery proof',
		dedupe_key: target, occurred_at: 12000,
		context: { failure_id: id }
	}));
	let restoration = make_event({
		type: 'internet_restored', severity: 'notice', component: 'network',
		title: 'Internet restored', message: 'Coherent observations confirm reachability',
		dedupe_key: 'internet-restored/' + id, occurred_at: 12000,
		recovery_of: target,
		context: {
			failure_id: id,
			guard: { state: 'ok', enabled: guard_enabled, observed_at: 12000,
				generation: 100 + index_value },
			dns: { state: 'ok', observed_at: 12000 },
			network: { state: 'ok', observed_at: 12000, path,
				guard_generation: 100 + index_value }
		}
	});
	if (expected)
		assert_equal(center_value.emit(restoration), true,
			outage_type + '/' + guard_enabled + '/' + path);
	else {
		assert_throws(() => center_value.emit(restoration), 'INVALID_ARGUMENT');
		assert_equal(length(center_value.history()), 1,
			'failed-closed restoration must not enter history');
	}
};

let guard_matrix = [
	[ 'direct_fallback', false, 'direct', true ],
	[ 'direct_fallback', false, 'proxy', false ],
	[ 'direct_fallback', false, 'guarded', false ],
	[ 'direct_fallback', true, 'proxy', false ],
	[ 'fail_closed', true, 'proxy', true ],
	[ 'fail_closed', true, 'guarded', true ],
	[ 'fail_closed', false, 'direct', false ],
	[ 'guard_outage', true, 'proxy', true ],
	[ 'guard_outage', false, 'direct', false ],
	[ 'failure', false, 'direct', true ],
	[ 'failure', false, 'proxy', true ],
	[ 'failure', false, 'guarded', false ],
	[ 'failure', true, 'direct', false ],
	[ 'failure', true, 'proxy', true ],
	[ 'failure', true, 'guarded', true ]
];
for (let index_value, item in guard_matrix)
	guard_matrix_case(index_value, item[0], item[1], item[2], item[3]);

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

// Public emit is exact; an explicit unwired adapter converts legacy producers.
let producer_env = make_runtime(30000);
let producer_center = notify.create(producer_env.runtime, settings({
	syslog: { enabled: false, minimum_severity: 'debug', types: [], components: [] },
	luci: { enabled: false, channel: 'miclash.notification', minimum_severity: 'debug',
		 types: [], components: [] }
}));
assert_throws(() => producer_center.emit({ type: 'failure', data: {
	failure_id: 'failure-21-30000', component: 'guard', reason: 'automatic'
} }), 'INVALID_ARGUMENT');
let producer_adapter = notify.producer(producer_env.runtime);
let backup_success_event = producer_adapter.backup(true);
assert_exact_event(backup_success_event);
assert_equal(backup_success_event.type, 'backup_outcome');
assert_equal(backup_success_event.severity, 'notice');
let backup_failure_event = producer_adapter.backup(false);
assert_equal(backup_failure_event.severity, 'error');
let guard_failure_event = producer_adapter.reconcile('failure', {
	failure_id: 'failure-21-30000', component: 'guard', reason: 'automatic'
});
assert_exact_event(guard_failure_event);
assert_equal(producer_center.emit(guard_failure_event), true);
assert_equal(producer_center.history()[0].type, 'guard_outage');
assert_equal(producer_center.history()[0].dedupe_key, 'failure/failure-21-30000');
assert_equal(producer_center.history()[0].context.failure_id, 'failure-21-30000');
assert_equal(producer_center.emit(producer_adapter.reconcile('failure', {
	failure_id: 'failure-21-30000', component: 'guard', reason: 'automatic'
})), false);
let guard_recovery_event = producer_adapter.reconcile('recovery', {
	failure_id: 'failure-21-30000', component: 'guard', reason: 'scheduled'
});
assert_exact_event(guard_recovery_event);
assert_equal(producer_center.emit(guard_recovery_event), true);
assert_equal(producer_center.history()[1].type, 'recovery');
assert_equal(producer_center.history()[1].recovery_of, 'failure/failure-21-30000');

for (let produced in [
	{ event: producer_adapter.reconcile('fail_closed', {
		failure_id: 'failure-22-30000', component: 'mihomo', reason: 'automatic'
	}), expected: 'fail_closed' },
	{ event: producer_adapter.reconcile('direct_fallback', {
		failure_id: 'failure-23-30000', component: 'mihomo', reason: 'automatic'
	}), expected: 'direct_fallback' },
	{ event: producer_adapter.memory({ type: 'memory_recovery_stage',
		recovery_id: 'memory-1-30000', action: 'reload', ready: false,
		material_drop: false, preserve_guard: true
	}), expected: 'memory_action' },
	{ event: producer_adapter.memory({ type: 'memory_recovery',
		recovery_id: 'memory-1-30000', result: 'failed', preserve_guard: true
	}), expected: 'memory_outcome' },
	{ event: producer_adapter.operation({
		id: 'operation-31', kind: 'subscription.update', state: 'success',
		source: 'auto', context: { profile: 'config.yaml', token: 'operation-secret' }
	}), expected: 'subscription_outcome' },
	{ event: producer_adapter.operation({
		id: 'operation-32', kind: 'updates.mihomo', state: 'failure',
		source: 'luci', context: { private_key: 'update-secret' }
	}), expected: 'update_outcome' },
	{ event: producer_adapter.operation({
		id: 'operation-33', kind: 'updates.miclash', state: 'interrupted',
		source: 'system', error: { code: 'INTERRUPTED' }
	}), expected: 'update_outcome' }
]) {
	assert_exact_event(produced.event);
	assert_equal(producer_center.emit(produced.event), true);
	assert_equal(producer_center.history()[length(producer_center.history()) - 1].type,
		produced.expected);
};
let producer_serialized = sprintf('%J', producer_center.history());
assert_true(index(producer_serialized, 'operation-secret') < 0);
assert_true(index(producer_serialized, 'update-secret') < 0);

let unknown_restoration = producer_adapter.internet({
	failure_id: 'failure-23-30000', recovery_of: 'direct-fallback/failure-23-30000',
	guard: { state: 'unknown', enabled: null, observed_at: 30000, generation: 11 },
	dns: { state: 'ok', observed_at: 30000 },
	network: { state: 'ok', observed_at: 30000, path: 'direct', guard_generation: 11 }
});
assert_exact_event(unknown_restoration);
assert_throws(() => producer_center.emit(unknown_restoration), 'INVALID_ARGUMENT');
let producer_restoration = producer_adapter.internet({
	failure_id: 'failure-23-30000', recovery_of: 'direct-fallback/failure-23-30000',
	guard: { state: 'ok', enabled: false, observed_at: 30000, generation: 11 },
	dns: { state: 'ok', observed_at: 30000 },
	network: { state: 'ok', observed_at: 30000, path: 'direct', guard_generation: 11 }
});
assert_exact_event(producer_restoration);
assert_equal(producer_center.emit(producer_restoration), true);
assert_equal(producer_center.history()[length(producer_center.history()) - 1].type,
	'internet_restored');
assert_equal(producer_center.history()[length(producer_center.history()) - 1].recovery_of,
	'direct-fallback/failure-23-30000');

assert_throws(() => producer_adapter.reconcile('unknown_producer', {}), 'INVALID_ARGUMENT');
assert_throws(() => producer_adapter.reconcile('failure', {
	failure_id: '../collision', component: 'dns', reason: 'auto'
}), 'INVALID_ARGUMENT');
assert_throws(() => producer_adapter.operation({
	id: 'operation-34', kind: 'service.restart', state: 'success'
}), 'INVALID_ARGUMENT');
assert_throws(() => producer_center.emit({
	...make_event(), data: { failure_id: 'failure-33-30000' }
}), 'INVALID_ARGUMENT');

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

// Dedupe state evicts the oldest inactive identity without orphaning active failures.
let dedupe_bound_env = make_runtime(40000);
let dedupe_bound = notify.create(dedupe_bound_env.runtime, settings({
	syslog: { enabled: false, minimum_severity: 'debug', types: [], components: [] },
	luci: { enabled: false, channel: 'miclash.notification', minimum_severity: 'debug',
		types: [], components: [] }
}));
for (let i = 0; i < 512; i++)
	assert_equal(dedupe_bound.emit(make_event({
		type: 'update_outcome', severity: 'info', component: 'updates',
		title: 'Bounded update outcome', message: 'Outcome ' + i,
		dedupe_key: 'updates/bounded-' + i,
		context: { operation_id: 'bounded-' + i, outcome: 'success' }
	})), true);
assert_equal(dedupe_bound.emit(make_event({
	type: 'update_outcome', severity: 'info', component: 'updates',
	title: 'Bounded update outcome', message: 'Outcome 512',
	dedupe_key: 'updates/bounded-512',
	context: { operation_id: 'bounded-512', outcome: 'success' }
})), true);
assert_equal(dedupe_bound.emit(make_event({
	type: 'update_outcome', severity: 'info', component: 'updates',
	title: 'Bounded update outcome', message: 'Outcome 1',
	dedupe_key: 'updates/bounded-1',
	context: { operation_id: 'bounded-1', outcome: 'success' }
})), false);
assert_equal(dedupe_bound.emit(make_event({
	type: 'update_outcome', severity: 'info', component: 'updates',
	title: 'Bounded update outcome', message: 'Outcome 0',
	dedupe_key: 'updates/bounded-0',
	context: { operation_id: 'bounded-0', outcome: 'success' }
})), true);

let active_bound_env = make_runtime(41000);
let active_bound = notify.create(active_bound_env.runtime, settings({
	syslog: { enabled: false, minimum_severity: 'debug', types: [], components: [] },
	luci: { enabled: false, channel: 'miclash.notification', minimum_severity: 'debug',
		types: [], components: [] }
}));
for (let i = 0; i < 512; i++)
	assert_equal(active_bound.emit(make_event({
		dedupe_key: 'failure/active-' + i,
		context: { failure_id: 'active-' + i }
	})), true);
assert_throws(() => active_bound.emit(make_event({
	dedupe_key: 'failure/active-overflow',
	context: { failure_id: 'active-overflow' }
})), 'BUSY');
assert_equal(active_bound.emit(make_event({
	type: 'recovery', severity: 'notice', title: 'Old failure recovered',
	message: 'Oldest active failure recovered safely',
	dedupe_key: 'recovery/active-0', recovery_of: 'failure/active-0',
	context: { failure_id: 'active-0' }
})), true);
assert_equal(active_bound.emit(make_event({
	dedupe_key: 'failure/active-overflow',
	context: { failure_id: 'active-overflow' }
})), true);
assert_equal(active_bound.emit(make_event({
	type: 'recovery', severity: 'notice', title: 'Another failure recovered',
	message: 'Another original active failure is still recoverable',
	dedupe_key: 'recovery/active-1', recovery_of: 'failure/active-1',
	context: { failure_id: 'active-1' }
})), true);

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
let first_batch = bounded_center.list({ generation: null, cursor: 0, limit: 2 });
assert_true(match(first_batch.generation, /^ng_[0-9a-f]{32}$/) != null);
assert_equal(first_batch.stale, false);
assert_equal(length(first_batch.events), 0);
assert_equal(first_batch.cursor, 201);
assert_equal(first_batch.has_more, false);
for (let i = 201; i < 203; i++)
	assert_equal(bounded_center.emit(make_event({
		type: 'update_outcome', severity: 'info', component: 'updates',
		title: 'Update outcome', message: 'Outcome ' + i,
		dedupe_key: 'updates/outcome/' + i, occurred_at: 50000 + i,
		context: { operation_id: 'operation-' + i, outcome: 'success' }
	})), true);
let second_batch = bounded_center.list({ generation: first_batch.generation,
	cursor: first_batch.cursor, limit: 1 });
assert_equal(second_batch.stale, false);
assert_equal(length(second_batch.events), 1);
assert_equal(second_batch.events[0].cursor, 202);
assert_equal(second_batch.events[0].event.dedupe_key, 'updates/outcome/201');
assert_equal(second_batch.cursor, 202);
assert_equal(second_batch.has_more, true);
let third_batch = bounded_center.list({ generation: first_batch.generation,
	cursor: second_batch.cursor, limit: 200 });
assert_equal(length(third_batch.events), 1);
assert_equal(third_batch.cursor, 203);
assert_equal(third_batch.has_more, false);
let evicted_cursor = bounded_center.list({ generation: first_batch.generation,
	cursor: 0, limit: 10 });
assert_equal(evicted_cursor.stale, true);
assert_equal(length(evicted_cursor.events), 0);
assert_equal(evicted_cursor.cursor, 203);
let wrong_generation = bounded_center.list({
	generation: 'ng_ffffffffffffffffffffffffffffffff', cursor: 201, limit: 10
});
assert_equal(wrong_generation.stale, true);
assert_equal(wrong_generation.generation, first_batch.generation);
assert_equal(wrong_generation.cursor, 203);
assert_throws(() => bounded_center.list({ generation: first_batch.generation,
	cursor: 201, limit: 201 }), 'INVALID_ARGUMENT');

// Reconfiguration is prepared before commit and preserves history, dedupe and
// optional channel subscriptions on the same notifier instance.
let reconfigure_env = make_runtime(5000);
let reconfigured = notify.create(reconfigure_env.runtime, settings());
let reconfigured_channel = [];
reconfigured.subscribe({
	name: 'telegram', minimum_severity: 'info', types: [], components: [],
	send: (event) => { push(reconfigured_channel, clone(event)); return true; }
});
assert_equal(reconfigured.emit(make_event({ occurred_at: 5000 })), true);
let prepared_notify = reconfigured.prepare(settings({ dedupe_window_ms: 2000 }));
assert_equal(reconfigured.configure(prepared_notify), true);
assert_equal(length(reconfigured.history()), 1);
assert_equal(reconfigured.emit(make_event({ occurred_at: 5001 })), false);
assert_equal(length(reconfigured.history()), 1);
assert_equal(length(reconfigured_channel), 1);
