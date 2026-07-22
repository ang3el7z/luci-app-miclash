import * as errors from 'miclash.errors';
import * as redact from 'miclash.redact';

const RECENT_LIMIT = 20;

function clone(value) {
	try { return json(sprintf('%J', value)); }
	catch (error) { errors.fail('INTERNAL'); }
};

function operation_summary(record) {
	if (type(record) != 'object')
		return null;

	let summary = {};
	for (let field in [ 'id', 'kind', 'source', 'state', 'stage', 'progress',
		'created_at', 'updated_at', 'finished_at' ])
		if (exists(record, field))
			summary[field] = record[field];
	if (type(record.error?.code) == 'string')
		summary.error = { code: record.error.code };

	return redact.value('operation', summary);
};

export function create(dependencies) {
	if (type(dependencies?.settings?.get) != 'function' ||
	    type(dependencies?.service?.observe) != 'function' ||
	    type(dependencies?.service?.wait_ready) != 'function' ||
	    type(dependencies?.operations?.list) != 'function' ||
	    type(dependencies?.operations?.subscribe) != 'function' ||
	    type(dependencies?.clock?.now) != 'function' ||
	    type(dependencies?.store?.write) != 'function')
		errors.fail('INVALID_ARGUMENT');

	let desired = redact.value('settings', dependencies.settings.get());
	let observed = { service: { state: 'unknown', running: false }, readiness: null };
	let observed_at = null;
	let recent = [];
	for (let record in dependencies.operations.list() ?? []) {
		let summary = operation_summary(record);
		if (summary != null)
			push(recent, summary);
	}
	while (length(recent) > RECENT_LIMIT)
		shift(recent);

	let subscribers = [];
	let subscription_sequence = 0;
	let closed = false;

	function safe_snapshot() {
		return clone(redact.value('state', {
			desired,
			observed,
			recent_operations: recent,
			observed_at
		}));
	};

	function current_snapshot() {
		return clone(redact.value('state', {
			desired,
			observed,
			observed_at
		}));
	};

	function publish() {
		let snapshot = safe_snapshot();
		for (let subscription in subscribers) {
			try { subscription.callback(clone(snapshot)); }
			catch (error) {}
		}
	};

	let unsubscribe_operations = dependencies.operations.subscribe((record) => {
		if (closed)
			return;
		let summary = operation_summary(record);
		if (summary == null)
			return;
		let replacement = [];
		for (let existing in recent)
			if (existing.id != summary.id)
				push(replacement, existing);
		push(replacement, summary);
		while (length(replacement) > RECENT_LIMIT)
			shift(replacement);
		recent = replacement;
		publish();
	});

	let model = {};
	model.snapshot = safe_snapshot;
	model.current = current_snapshot;
	model.health = () => clone(redact.value('health', {
		observed,
		observed_at
	}));
	model.last_repair = () => {
		for (let index = length(recent) - 1; index >= 0; index--)
			if (recent[index]?.kind == 'system.reconcile' ||
			    recent[index]?.kind == 'memory.recovery')
				return clone(recent[index]);
		return { state: 'none' };
	};
	model.refresh_desired = () => {
		desired = redact.value('settings', dependencies.settings.get());
		publish();
		return clone(desired);
	};
	model.set_desired = (settings) => {
		if (type(settings) != 'object')
			errors.fail('INVALID_ARGUMENT');
		desired = redact.value('settings', settings);
		publish();
		return clone(desired);
	};
	model.observe = (profile) => {
		if (closed)
			errors.fail('BUSY');
		let service = dependencies.service.observe(profile);
		let readiness;
		try {
			readiness = dependencies.service.wait_ready(
				dependencies.clock.now(), profile, {});
		}
		catch (error) {
			readiness = { ok: false, state: 'unknown', components: [] };
		}
		observed = redact.value('observed', { service, readiness });
		observed_at = dependencies.clock.now();
		publish();
		return clone(observed);
	};
	model.subscribe = (callback) => {
		if (type(callback) != 'function' || closed)
			errors.fail('INVALID_ARGUMENT');
		let id = ++subscription_sequence;
		push(subscribers, { id, callback });
		let active = true;
		return () => {
			if (!active)
				return false;
			active = false;
			let remaining = [];
			for (let subscription in subscribers)
				if (subscription.id != id)
					push(remaining, subscription);
			subscribers = remaining;
			return true;
		};
	};
	model.flush = () => {
		dependencies.store.write(safe_snapshot());
		return true;
	};
	model.close = () => {
		if (closed)
			return false;
		closed = true;
		if (type(unsubscribe_operations) == 'function')
			unsubscribe_operations();
		subscribers = [];
		return true;
	};

	return model;
};
