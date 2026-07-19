import * as errors from 'miclash.errors';

const STATES = { queued: true, running: true, success: true, failure: true,
	interrupted: true };

function invalid() { errors.fail('INVALID_ARGUMENT'); };
function clone(value) {
	try { return value == null ? null : json(sprintf('%J', value)); }
	catch (error) { invalid(); }
};
function target(value) {
	if (type(value) != 'object' || !match(sprintf('%s', value.chat_id), /^[1-9][0-9]{0,19}$/) ||
	    type(value.message_id) != 'int' || value.message_id < 1 ||
	    (value.locale != 'en' && value.locale != 'ru' && value.locale != 'zh-cn')) invalid();
	return { chat_id: sprintf('%s', value.chat_id), message_id: value.message_id,
		locale: value.locale };
};
function operation(value) {
	if (type(value) != 'object' || type(value.id) != 'string' ||
	    !match(value.id, /^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/) ||
	    type(value.kind) != 'string' || !match(value.kind, /^[a-z0-9][a-z0-9_.-]{0,63}$/) ||
	    !STATES[value.state] || type(value.stage) != 'string' ||
	    type(value.progress) != 'int' || value.progress < 0 || value.progress > 100)
		invalid();
	return value;
};

export function create(app, outbox, render) {
	if (type(app) != 'object' || type(app.runtime?.clock?.now) != 'function' ||
	    type(app.runtime?.random?.hex) != 'function' ||
	    type(app.operations?.subscribe) != 'function' ||
	    type(app.operations?.list) != 'function' || type(app.operations?.get) != 'function' ||
	    type(outbox?.enqueue) != 'function' || type(outbox?.update) != 'function' ||
	    type(outbox?.pending) != 'function' || type(render) != 'function') invalid();
	let closed = false;
	function active() { if (closed) errors.fail('INTERRUPTED'); };
	function receipt_id(operation_id) { return 'operation.' + operation_id; };
	function payload(record) {
		let value = render(clone(record));
		if (type(value) != 'object' || type(value) == 'array') invalid();
		return value;
	};
	function pending(operation_id) {
		for (let entry in outbox.pending())
			if (entry.operation_id == operation_id) return entry;
		return null;
	};
	function verified(record) {
		if (record.state != 'success') return false;
		if (type(app.operation_postcheck) != 'function') return true;
		try { return app.operation_postcheck(clone(record)) === true; }
		catch (error) { return false; }
	};
	function update_record(record) {
		record = operation(record);
		let entry = pending(record.id);
		if (entry == null) return false;
		let state = record.state;
		if (state == 'success' && !verified(record)) state = 'verifying';
		outbox.update(entry.id, { state, payload: payload({ ...record, state }) });
		return true;
	};
	let unsubscribe = app.operations.subscribe((record) => {
		if (closed) return;
		try { update_record(record); } catch (error) {}
	});
	if (type(unsubscribe) != 'function') invalid();
	return {
		track: (record, destination) => {
			active(); record = operation(record); destination = target(destination);
			if (record.source != 'telegram') invalid();
			return outbox.enqueue({
				id: receipt_id(record.id), audience: 'user', kind: record.kind,
				locale: destination.locale, chat_id: destination.chat_id,
				message_id: destination.message_id, operation_id: record.id,
				state: record.state, created_at: app.runtime.clock.now(), payload: payload(record)
			});
		},
		operation_event: (record) => { active(); return update_record(record); },
		prepare_reboot: (destination) => {
			active(); destination = target(destination);
			if (type(app.boot_id) != 'function') errors.fail('INTERNAL');
			let before = app.boot_id();
			if (type(before) != 'string' || !match(before, /^[A-Za-z0-9._-]{1,128}$/))
				errors.fail('INTERNAL');
			let operation_id = sprintf('reboot.%d.%s', app.runtime.clock.now(),
				app.runtime.random.hex(8));
			outbox.enqueue({
				id: receipt_id(operation_id), audience: 'user', kind: 'system.reboot',
				locale: destination.locale, chat_id: destination.chat_id,
				message_id: destination.message_id, operation_id,
				state: 'queued', created_at: app.runtime.clock.now(),
				payload: { kind: 'system.reboot', stage: 'reboot', progress: 50,
					boot_id_before: before, error: null }
			});
			return operation_id;
		},
		recover: () => {
			active();
			let recovered = 0;
			for (let entry in outbox.pending()) {
				if (entry.kind == 'system.reboot' && entry.payload?.boot_id_before != null) {
					let boot = type(app.boot_id) == 'function' ? app.boot_id() : null;
					let ready = type(app.daemon_ready) == 'function' ? app.daemon_ready() === true : true;
					if (type(boot) == 'string' && boot != entry.payload.boot_id_before && ready) {
						outbox.update(entry.id, { state: 'success', payload: {
							kind: 'system.reboot', stage: 'complete', progress: 100,
							boot_id_before: entry.payload.boot_id_before, error: null
						} });
						recovered++;
					}
					continue;
				}
				let record;
				try { record = app.operations.get(entry.operation_id); }
				catch (error) { record = null; }
				if (record != null && update_record(record)) recovered++;
			}
			return recovered;
		},
		close: () => {
			if (closed) return false;
			closed = true;
			try { unsubscribe(); } catch (error) {}
			return true;
		}
	};
};
