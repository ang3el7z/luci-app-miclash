import { fail } from 'miclash.errors';
import * as redact from 'miclash.redact';

const EVENT_FIELDS = {
	type: true, severity: true, component: true, title: true, message: true,
	dedupe_key: true, occurred_at: true, recovery_of: true, context: true
};
const SETTINGS_FIELDS = { dedupe_window_ms: true, syslog: true, luci: true };
const FILTER_FIELDS = {
	enabled: true, minimum_severity: true, types: true, components: true
};
const LUCI_FIELDS = {
	enabled: true, channel: true, minimum_severity: true, types: true, components: true
};
const CHANNEL_FIELDS = {
	name: true, minimum_severity: true, types: true, components: true, send: true
};
const SEVERITIES = {
	debug: 0, info: 1, notice: 2, warning: 3, error: 4, critical: 5
};
const SYSLOG_PRIORITIES = {
	debug: 'debug', info: 'info', notice: 'notice', warning: 'warning',
	error: 'err', critical: 'crit'
};
const HISTORY_LIMIT = 200;
const DEDUPE_LIMIT = 512;
const CHANNEL_LIMIT = 32;
const MAX_CONTEXT_BYTES = 32768;
const MAX_CONTEXT_NODES = 512;
const MAX_CONTEXT_DEPTH = 8;
const MAX_OBSERVATION_AGE_MS = 5000;

function invalid() {
	fail('INVALID_ARGUMENT');
};

function exact(value, allowed, count) {
	if (type(value) != 'object' || length(keys(value)) != count)
		invalid();
	for (let name in value)
		if (!exists(allowed, name))
			invalid();
	return value;
};

function clone(value) {
	try { return json(sprintf('%J', value)); }
	catch (error) { invalid(); }
};

function control(value) {
	return match(value, /[[:cntrl:]]/) != null;
};

function identifier(value, maximum) {
	if (type(value) != 'string' || !length(value) || length(value) > maximum ||
	    !match(value, /^[a-z][a-z0-9_.-]*$/) || redact.secret_name(value))
		invalid();
	return value;
};

function key(value) {
	if (type(value) != 'string' || !length(value) || length(value) > 128 ||
	    !match(value, /^[A-Za-z0-9][A-Za-z0-9._:\/-]*$/) || redact.secret_name(value))
		invalid();
	return value;
};

function channel_name(value) {
	return identifier(value, 64);
};

function severity(value) {
	if (type(value) != 'string' || !exists(SEVERITIES, value))
		invalid();
	return value;
};

function unique_identifiers(value) {
	if (type(value) != 'array' || length(value) > 64)
		invalid();
	let result = [], seen = {};
	for (let item in value) {
		item = identifier(item, 64);
		if (seen[item])
			invalid();
		seen[item] = true;
		push(result, item);
	}
	return result;
};

function validate_context(value, depth, state) {
	state.nodes++;
	if (state.nodes > MAX_CONTEXT_NODES || depth > MAX_CONTEXT_DEPTH)
		invalid();

	let kind = type(value);
	if (kind == 'string') {
		if (length(value) > 4096 || control(value))
			invalid();
		return;
	}
	if (kind == 'array') {
		if (length(value) > 128)
			invalid();
		for (let item in value)
			validate_context(item, depth + 1, state);
		return;
	}
	if (kind == 'object') {
		if (length(keys(value)) > 128)
			invalid();
		for (let name, item in value) {
			if (type(name) != 'string' || !length(name) || length(name) > 128 ||
			    !match(name, /^[A-Za-z_][A-Za-z0-9_.-]*$/))
				invalid();
			validate_context(item, depth + 1, state);
		}
		return;
	}
	if (kind != 'null' && kind != 'bool' && kind != 'int' && kind != 'double')
		invalid();
};

function clean_text(value, maximum) {
	if (type(value) != 'string' || !length(value) || length(value) > maximum || control(value))
		invalid();
	return value;
};

function clean_event(input) {
	exact(input, EVENT_FIELDS, 9);
	let value = clone(input);
	value.type = identifier(value.type, 64);
	value.severity = severity(value.severity);
	value.component = identifier(value.component, 64);
	value.title = clean_text(value.title, 128);
	value.message = clean_text(value.message, 2048);
	value.dedupe_key = key(value.dedupe_key);
	if (type(value.occurred_at) != 'int' || value.occurred_at < 0)
		invalid();
	if (value.recovery_of != null)
		value.recovery_of = key(value.recovery_of);
	if (type(value.context) != 'object')
		invalid();
	validate_context(value.context, 0, { nodes: 0 });
	let encoded;
	try { encoded = sprintf('%J', value.context); }
	catch (error) { invalid(); }
	if (length(encoded) > MAX_CONTEXT_BYTES)
		invalid();
	if (value.recovery_of == null && SEVERITIES[value.severity] >= SEVERITIES.warning &&
	    exists(value.context, 'occurrences'))
		invalid();
	let safe = redact.sanitize(value);
	if (safe.type != value.type || safe.severity != value.severity ||
	    safe.component != value.component || safe.dedupe_key != value.dedupe_key ||
	    safe.occurred_at != value.occurred_at || safe.recovery_of != value.recovery_of)
		invalid();
	return safe;
};

function failure_id(value) {
	if (type(value) != 'string' || length(value) > 128 ||
	    !match(value, /^failure-[0-9]+-[0-9]+$/))
		invalid();
	return value;
};

function memory_id(value) {
	if (type(value) != 'string' || length(value) > 128 ||
	    !match(value, /^memory-[0-9]+-[0-9]+$/))
		invalid();
	return value;
};

function producer_event(runtime, input) {
	exact(input, { type: true, data: true }, 2);
	let type_name = identifier(input.type, 64);
	if (type(input.data) != 'object')
		invalid();
	let data = clone(input.data), now = runtime.clock.now();
	if (type(now) != 'int' || now < 0)
		invalid();

	if (type_name == 'failure' || type_name == 'recovery' ||
	    type_name == 'fail_closed' || type_name == 'direct_fallback') {
		let id = failure_id(data.failure_id);
		let component = identifier(data.component, 64);
		let base_key = 'failure/' + id;
		if (type_name == 'failure')
			return {
				type: component == 'guard' ? 'guard_outage' : 'failure',
				severity: component == 'guard' ? 'critical' : 'warning',
				component,
				title: component == 'guard' ? 'Guard outage' : 'MiClash repair failed',
				message: component == 'guard' ?
					'Guard could not prove protected routing' :
					'Fresh observation remains unhealthy',
				dedupe_key: base_key, occurred_at: now, recovery_of: null, context: data
			};
		if (type_name == 'recovery')
			return {
				type: 'recovery', severity: 'notice', component,
				title: 'MiClash component recovered',
				message: 'Fresh observation confirms recovery',
				dedupe_key: 'recovery/' + id, occurred_at: now,
				recovery_of: base_key, context: data
			};
		if (type_name == 'fail_closed')
			return {
				type: 'fail_closed', severity: 'critical', component,
				title: 'Internet blocked safely',
				message: 'Repair failed while Guard remains enabled',
				dedupe_key: 'fail-closed/' + id, occurred_at: now,
				recovery_of: null, context: { ...data, guard_mode: 'enabled' }
			};
		return {
			type: 'direct_fallback', severity: 'warning', component,
			title: 'Direct fallback active',
			message: 'Direct reachability was confirmed after fallback',
			dedupe_key: 'direct-fallback/' + id, occurred_at: now,
			recovery_of: null, context: { ...data, guard_mode: 'disabled' }
		};
	}

	if (type_name == 'memory_recovery_stage') {
		let id = memory_id(data.recovery_id), action = identifier(data.action, 64);
		return {
			type: 'memory_action', severity: 'info', component: 'memory',
			title: 'Memory recovery action', message: 'Memory recovery stage started',
			dedupe_key: 'memory/action/' + id + '/' + action,
			occurred_at: now, recovery_of: null, context: data
		};
	}
	if (type_name == 'memory_recovery') {
		let id = memory_id(data.recovery_id);
		if (data.result != 'success' && data.result != 'failed')
			invalid();
		return {
			type: 'memory_outcome',
			severity: data.result == 'success' ? 'notice' : 'warning',
			component: 'memory', title: data.result == 'success' ?
				'Memory recovery completed' : 'Memory recovery failed',
			message: data.result == 'success' ?
				'Memory returned below the adaptive threshold' :
				'Memory remained above the adaptive threshold',
			dedupe_key: 'memory/outcome/' + id, occurred_at: now,
			recovery_of: null, context: data
		};
	}

	if (type_name == 'operation') {
		let id = key(data.id), kind = identifier(data.kind, 64);
		if (data.state != 'success' && data.state != 'failure' &&
		    data.state != 'interrupted')
			invalid();
		let subscription = kind == 'subscription.update';
		let update = substr(kind, 0, 8) == 'updates.';
		if (!subscription && !update)
			invalid();
		let success = data.state == 'success';
		return {
			type: subscription ? 'subscription_outcome' : 'update_outcome',
			severity: success ? 'notice' : 'error',
			component: subscription ? 'subscription' : 'updates',
			title: subscription ?
				(success ? 'Subscription updated' : 'Subscription update failed') :
				(success ? 'MiClash update completed' : 'MiClash update failed'),
			message: success ? 'The validated operation completed successfully' :
				'The operation failed without weakening Guard',
			dedupe_key: (subscription ? 'subscription/outcome/' : 'updates/outcome/') + id,
			occurred_at: now, recovery_of: null, context: data
		};
	}

	if (type_name == 'internet_restored') {
		let id = failure_id(data.failure_id);
		let target = key(data.recovery_of);
		if (target != 'failure/' + id && target != 'direct-fallback/' + id &&
		    target != 'fail-closed/' + id)
			invalid();
		return {
			type: 'internet_restored', severity: 'notice', component: 'network',
			title: 'Internet restored',
			message: 'Fresh DNS and network observations confirm access',
			dedupe_key: 'internet-restored/' + id, occurred_at: now,
			recovery_of: target,
			context: {
				failure_id: id, guard: data.guard, dns: data.dns, network: data.network
			}
		};
	}

	invalid();
};

function normalized_event(runtime, input) {
	return clean_event(input);
};

export function producer(runtime) {
	if (type(runtime?.clock?.now) != 'function')
		invalid();
	return {
		reconcile: (type_name, data) => producer_event(runtime,
			{ type: type_name, data }),
		memory: (event) => {
			if (type(event) != 'object' || type(event.type) != 'string')
				invalid();
			return producer_event(runtime, { type: event.type, data: event });
		},
		operation: (record) => producer_event(runtime, { type: 'operation', data: record }),
		internet: (data) => producer_event(runtime, { type: 'internet_restored', data })
	};
};

export function telegram_channel(telegram) {
	if (type(telegram?.send_event) != 'function')
		invalid();
	return {
		name: 'telegram',
		minimum_severity: 'info',
		types: [],
		components: [],
		send: (event) => {
			try { return telegram.send_event(event) === true; }
			catch (error) { return false; }
		}
	};
};

function clean_filter(value, luci) {
	exact(value, luci ? LUCI_FIELDS : FILTER_FIELDS, luci ? 5 : 4);
	if (type(value.enabled) != 'bool')
		invalid();
	let result = {
		enabled: value.enabled,
		minimum_severity: severity(value.minimum_severity),
		types: unique_identifiers(value.types),
		components: unique_identifiers(value.components)
	};
	if (luci)
		result.channel = channel_name(value.channel);
	return result;
};

function clean_settings(value) {
	exact(value, SETTINGS_FIELDS, 3);
	if (type(value.dedupe_window_ms) != 'int' || value.dedupe_window_ms < 1 ||
	    value.dedupe_window_ms > 86400000)
		invalid();
	return {
		dedupe_window_ms: value.dedupe_window_ms,
		syslog: clean_filter(value.syslog, false),
		luci: clean_filter(value.luci, true)
	};
};

function clean_channel(value) {
	exact(value, CHANNEL_FIELDS, 5);
	if (type(value.send) != 'function')
		invalid();
	return {
		name: channel_name(value.name),
		minimum_severity: severity(value.minimum_severity),
		types: unique_identifiers(value.types),
		components: unique_identifiers(value.components),
		send: value.send
	};
};

function includes(values, candidate) {
	return !length(values) || index(values, candidate) >= 0;
};

function accepts(filter, event) {
	return SEVERITIES[event.severity] >= SEVERITIES[filter.minimum_severity] &&
		includes(filter.types, event.type) && includes(filter.components, event.component);
};

function valid_runtime(runtime) {
	return type(runtime) == 'object' && type(runtime.clock?.now) == 'function' &&
		type(runtime.process?.run) == 'function' && type(runtime.ubus?.connect) == 'function';
};

function validate_restoration(runtime, event) {
	if (event.type != 'internet_restored')
		return;
	let context = event.context;
	if (event.recovery_of == null ||
	    type(context.guard) != 'object' || context.guard.state != 'ok' ||
	    type(context.guard.enabled) != 'bool' ||
	    type(context.guard.observed_at) != 'int' ||
	    type(context.guard.generation) != 'int' || context.guard.generation < 0 ||
	    type(context.dns) != 'object' || context.dns.state != 'ok' ||
	    type(context.dns.observed_at) != 'int' ||
	    type(context.network) != 'object' || context.network.state != 'ok' ||
	    type(context.network.observed_at) != 'int' ||
	    type(context.network.guard_generation) != 'int' ||
	    context.network.guard_generation != context.guard.generation ||
	    (context.network.path != 'direct' && context.network.path != 'proxy' &&
	     context.network.path != 'guarded'))
		invalid();
	let now = runtime.clock.now();
	for (let observed in [ context.guard.observed_at, context.dns.observed_at,
		context.network.observed_at ])
		if (observed > now || now - observed > MAX_OBSERVATION_AGE_MS)
			invalid();
	if (context.guard.enabled && context.network.path == 'direct')
		invalid();
	if (!context.guard.enabled && context.network.path == 'guarded')
		invalid();
};

function validate_restoration_target(event, target) {
	if (event.type != 'internet_restored')
		return;
	let enabled = event.context.guard.enabled;
	let path = event.context.network.path;
	if (target.type == 'direct_fallback' && (enabled || path != 'direct'))
		invalid();
	if ((target.type == 'fail_closed' || target.type == 'guard_outage') &&
	    (!enabled || (path != 'proxy' && path != 'guarded')))
		invalid();
};

function validate_final_event(event) {
	let encoded;
	try { encoded = sprintf('%J', event.context); }
	catch (error) { invalid(); }
	if (length(encoded) > MAX_CONTEXT_BYTES)
		fail('RESPONSE_TOO_LARGE');
};

export function create(runtime, settings) {
	if (!valid_runtime(runtime))
		invalid();
	let configured = clean_settings(settings);
	let history = [], dedupe = {}, dedupe_order = [], active = {};
	let channels = {}, channel_order = [];

	function send_syslog(event) {
		let result = runtime.process.run({
			command: '/usr/bin/logger',
			args: [ '-t', 'miclash', '-p', 'daemon.' + SYSLOG_PRIORITIES[event.severity],
				'--', sprintf('%J', event) ]
		});
		return type(result) == 'object' && result.code === 0;
	};

	function send_luci(event) {
		let connection = runtime.ubus.connect();
		if (type(connection?.send) != 'function')
			return false;
		return connection.send(configured.luci.channel, clone(event)) === true;
	};

	function safe_send(send, event) {
		try { return send(clone(event)) === true; }
		catch (error) { return false; }
	};

	function dispatch(event) {
		if (configured.syslog.enabled && accepts(configured.syslog, event))
			safe_send(send_syslog, event);
		if (configured.luci.enabled && accepts(configured.luci, event))
			safe_send(send_luci, event);
		for (let name in channel_order) {
			let channel = channels[name];
			if (channel != null && accepts(channel, event))
				safe_send(channel.send, event);
		}
	};

	function remember(key_value, event) {
		if (dedupe[key_value] != null)
			return dedupe[key_value];
		if (length(dedupe_order) >= DEDUPE_LIMIT) {
			let evict_at = null;
			for (let i = 0; i < length(dedupe_order); i++)
				if (active[dedupe_order[i]] == null) {
					evict_at = i;
					break;
				}
			if (evict_at == null && event.recovery_of != null &&
			    active[event.recovery_of] != null)
				evict_at = index(dedupe_order, event.recovery_of);
			if (evict_at == null || evict_at < 0)
				fail('BUSY');
			let evicted = dedupe_order[evict_at];
			splice(dedupe_order, evict_at, 1);
			delete dedupe[evicted];
		}
		let record = {
			type: event.type, component: event.component,
			severity: event.severity, title: event.title, message: event.message,
			recovery_of: event.recovery_of, last_at: null, occurrences: 0
		};
		dedupe[key_value] = record;
		push(dedupe_order, key_value);
		return record;
	};

	function test_event() {
		return {
			type: 'test', severity: 'notice', component: 'notify',
			title: 'MiClash notification test',
			message: 'Notification channel is reachable',
			dedupe_key: 'notify/test', occurred_at: runtime.clock.now(),
			recovery_of: null, context: {}
		};
	};

	let notifier = {};
	notifier.history = () => clone(history);
	notifier.emit = (input) => {
		let event = normalized_event(runtime, input);
		validate_restoration(runtime, event);
		let now = runtime.clock.now();
		if (type(now) != 'int' || now < 0)
			invalid();

		let record = dedupe[event.dedupe_key];
		if (record != null && (record.type != event.type || record.component != event.component ||
		    record.severity != event.severity || record.title != event.title ||
		    record.message != event.message || record.recovery_of != event.recovery_of))
			invalid();
		if (record != null && record.last_at != null && now >= record.last_at &&
		    now - record.last_at < configured.dedupe_window_ms)
			return false;
		let target = event.recovery_of == null ? null : active[event.recovery_of];
		if (event.recovery_of != null && target == null) {
			if (record != null)
				return false;
			invalid();
		}
		if (target != null && event.type != 'internet_restored' &&
		    target.component != event.component)
			invalid();
		if (target != null && event.type == 'internet_restored' &&
		    target.type != 'failure' && target.type != 'guard_outage' &&
		    target.type != 'direct_fallback' && target.type != 'fail_closed')
			invalid();
		if (target != null)
			validate_restoration_target(event, target);

		let next_occurrences = null;
		if (event.recovery_of == null && SEVERITIES[event.severity] >= SEVERITIES.warning) {
			next_occurrences = (record?.occurrences ?? 0) + 1;
			let base_severity = record?.severity ?? event.severity;
			let escalated = min(SEVERITIES.critical,
				SEVERITIES[base_severity] + next_occurrences - 1);
			for (let name, rank in SEVERITIES)
				if (rank == escalated)
					event.severity = name;
			event.context.occurrences = next_occurrences;
		}
		validate_final_event(event);

		record = remember(event.dedupe_key, event);
		record.last_at = now;
		if (next_occurrences != null) {
			record.occurrences = next_occurrences;
			active[event.dedupe_key] = { type: event.type, component: event.component };
		}
		if (event.recovery_of != null) {
			delete active[event.recovery_of];
			let prior = dedupe[event.recovery_of];
			if (prior != null) {
				prior.last_at = null;
				prior.occurrences = 0;
			}
		}

		push(history, clone(event));
		if (length(history) > HISTORY_LIMIT)
			shift(history);
		dispatch(event);
		return true;
	};

	notifier.subscribe = (input) => {
		let channel = clean_channel(input);
		if (channel.name == 'syslog' || channel.name == 'luci' ||
		    channels[channel.name] != null || length(channel_order) >= CHANNEL_LIMIT)
			invalid();
		channels[channel.name] = channel;
		push(channel_order, channel.name);
		let active_subscription = true;
		return () => {
			if (!active_subscription)
				return false;
			active_subscription = false;
			delete channels[channel.name];
			let remaining = [];
			for (let name in channel_order)
				if (name != channel.name)
					push(remaining, name);
			channel_order = remaining;
			return true;
		};
	};

	notifier.test = (name) => {
		name = channel_name(name);
		let event = test_event();
		if (name == 'syslog')
			return safe_send(send_syslog, event);
		if (name == 'luci')
			return safe_send(send_luci, event);
		let channel = channels[name];
		if (channel == null)
			invalid();
		return safe_send(channel.send, event);
	};

	return notifier;
};
