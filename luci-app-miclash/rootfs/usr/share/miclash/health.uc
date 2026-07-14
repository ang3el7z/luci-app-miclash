import { fail } from 'miclash.errors';
import * as redact from 'miclash.redact';

const COMPONENTS = [ 'guard', 'firewall', 'routing', 'dns', 'mihomo', 'scheduler', 'telegram' ];
const STATES = { ok: true, degraded: true, failed: true, unknown: true };

function clone(value) {
	try { return json(sprintf('%J', value)); }
	catch (error) { return null; }
};

function safe_text(value, maximum) {
	return type(value) == 'string' && length(value) <= maximum &&
		!match(value, /[[:cntrl:]]/);
};

function unavailable(code) {
	return {
		state: 'unknown',
		code,
		message: 'Health observation unavailable',
		observed_at: null,
		details: {}
	};
};

function canonical(value) {
	if (type(value) != 'object' || !STATES[value.state] ||
	    !safe_text(value.code, 64) || !match(value.code, /^[A-Z][A-Z0-9_]*$/) ||
	    !safe_text(value.message, 512) || type(value.details) != 'object')
		return unavailable('INVALID_OBSERVATION');

	let details = clone(redact.value('details', value.details));
	if (type(details) != 'object' || length(sprintf('%J', details)) > 4096)
		return unavailable('INVALID_OBSERVATION');
	return {
		state: value.state,
		code: value.code,
		message: redact.text(value.message),
		observed_at: null,
		details
	};
};

function validate(app) {
	if (type(app?.clock?.now) != 'function' || type(app?.observers) != 'object')
		fail('INVALID_ARGUMENT');
	for (let name in COMPONENTS)
		if (type(app.observers[name]) != 'function')
			fail('INVALID_ARGUMENT');
};

function observe_range(app, first) {
	validate(app);
	if (type(first) != 'int' || first < 0 || first >= length(COMPONENTS))
		fail('INVALID_ARGUMENT');
	let observed_at = app.clock.now();
	if (type(observed_at) != 'int' || observed_at < 0)
		fail('INTERNAL');
	let graph = {};
	for (let i = first; i < length(COMPONENTS); i++) {
		let name = COMPONENTS[i];
		let record;
		try { record = canonical(app.observers[name]()); }
		catch (error) { record = unavailable('OBSERVER_FAILED'); }
		record.observed_at = observed_at;
		graph[name] = record;
	}
	return clone(graph);
};

export function observe_all(app) {
	return observe_range(app, 0);
};

export function observe_from(app, component) {
	let first = index(COMPONENTS, component);
	if (first < 0)
		fail('INVALID_ARGUMENT');
	return observe_range(app, first);
};

export function components() {
	return [ ...COMPONENTS ];
};
