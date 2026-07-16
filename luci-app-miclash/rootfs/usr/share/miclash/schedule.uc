import { fail } from 'miclash.errors';

const MAX_TIMESTAMP = 4102444799;
const MAX_TRANSITIONS = 512;

function invalid() { fail('INVALID_ARGUMENT'); };
function exact(value, allowed) {
	if (type(value) != 'object' || type(value) == 'array') invalid();
	for (let name in value) if (!exists(allowed, name)) invalid();
	for (let name in allowed) if (!exists(value, name)) invalid();
};
function integer(value, minimum, maximum) {
	if (type(value) != 'int' || value < minimum || value > maximum) invalid();
	return value;
};
function zone_name(value) {
	if (type(value) != 'string' || length(value) < 3 || length(value) > 64 ||
	    !match(value, /^[A-Za-z][A-Za-z0-9_+.-]*(\/[A-Za-z0-9_+.-]+)+$/) ||
	    match(value, /(^|\/)\.\.?($|\/)/)) invalid();
	return value;
};
function minute(value) {
	if (type(value) != 'string' || !match(value, /^(0[0-9]|1[0-9]|2[0-3]):[0-5][0-9]$/))
		invalid();
	return int(substr(value, 0, 2)) * 60 + int(substr(value, 3, 2));
};
function contains(values, wanted) {
	for (let value in values) if (value == wanted) return true;
	return false;
};

// `timezone` is a Plan4-ready, process-independent capability produced by an
// IANA resolver. It describes UTC coverage and offset transitions. This module
// revalidates the complete bounded capability and never mutates process TZ.
function capability(value, timestamp, expected_name) {
	exact(value, { name: true, from: true, until: true, initial_offset: true, transitions: true });
	if (zone_name(value.name) != expected_name) invalid();
	let from = integer(value.from, 0, MAX_TIMESTAMP);
	let until = integer(value.until, 1, MAX_TIMESTAMP + 1);
	let offset = integer(value.initial_offset, -50400, 50400);
	if (from >= until || timestamp < from || timestamp >= until ||
	    type(value.transitions) != 'array' || length(value.transitions) > MAX_TRANSITIONS)
		invalid();
	let previous = from - 1;
	for (let transition in value.transitions) {
		exact(transition, { at: true, offset: true });
		let at = integer(transition.at, from, until - 1);
		let next_offset = integer(transition.offset, -50400, 50400);
		if (at <= previous) invalid();
		if (at <= timestamp) offset = next_offset;
		previous = at;
	}
	return offset;
};

export function active(spec, timestamp, timezone) {
	exact(spec, { days: true, start: true, end: true, timezone: true });
	integer(timestamp, 0, MAX_TIMESTAMP);
	let name = zone_name(spec.timezone);
	if (type(spec.days) != 'array' || !length(spec.days) || length(spec.days) > 7)
		invalid();
	let days = [];
	for (let day in spec.days) {
		integer(day, 1, 7);
		if (contains(days, day)) invalid();
		push(days, day);
	}
	let start = minute(spec.start), end = minute(spec.end);
	if (start == end) invalid();
	let offset = capability(timezone, timestamp, name);
	let local = gmtime(timestamp + offset);
	if (local == null) invalid();
	let current = local.hour * 60 + local.min;
	if (start < end)
		return contains(days, local.wday) && current >= start && current < end;
	if (current >= start)
		return contains(days, local.wday);
	let previous_day = local.wday == 1 ? 7 : local.wday - 1;
	return current < end && contains(days, previous_day);
};
