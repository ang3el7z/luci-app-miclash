import * as errors from 'miclash.errors';

const MIN_SYNCED_MS = 1577836800000;
const MAX_TIMESTAMP_MS = 4102444799999;
const DAY_SECONDS = 86400;
const WINDOW_START = 2 * 60;
const WINDOW_END = 6 * 60;
const START_CUTOFF = 5 * 60 + 30;

function invalid() { errors.fail('INVALID_ARGUMENT'); };

function zone_name(value) {
	if (type(value) != 'string' || length(value) < 3 || length(value) > 64 ||
	    (value != 'UTC' && !match(value,
	    /^[A-Za-z][A-Za-z0-9_+.-]*(\/[A-Za-z0-9_+.-]+)+$/)) ||
	    match(value, /(^|\/)\.\.?($|\/)/))
		return null;
	return value;
};
function offset_at(runtime, name, timestamp) {
	let value;
	try { value = runtime.timezones.resolve(name, timestamp); }
	catch (error) { return null; }
	if (type(value) != 'object' || value.name != name || type(value.from) != 'int' ||
	    type(value.until) != 'int' || timestamp < value.from || timestamp >= value.until ||
	    type(value.initial_offset) != 'int' || value.initial_offset < -50400 ||
	    value.initial_offset > 50400 || type(value.transitions) != 'array' ||
	    length(value.transitions) > 512)
		return null;
	let offset = value.initial_offset, previous = value.from - 1;
	for (let transition in value.transitions) {
		if (type(transition) != 'object' || type(transition.at) != 'int' ||
		    type(transition.offset) != 'int' || transition.at <= previous ||
		    transition.at < value.from || transition.at >= value.until ||
		    transition.offset < -50400 || transition.offset > 50400)
			return null;
		if (transition.at <= timestamp)
			offset = transition.offset;
		previous = transition.at;
	}
	return offset;
};

function date_string(value) {
	return sprintf('%04d-%02d-%02d', value.year, value.mon, value.mday);
};

function target_utc(runtime, name, local_day_pseudo, minimum_day) {
	for (let day = minimum_day; day <= minimum_day + 3; day++) {
		let wanted = local_day_pseudo + day * DAY_SECONDS + 2 * 3600;
		let candidate = wanted;
		for (let attempt = 0; attempt < 4; attempt++) {
			let offset = offset_at(runtime, name, candidate);
			if (offset == null) break;
			let next = wanted - offset;
			if (next == candidate) break;
			candidate = next;
		}
		let final_offset = offset_at(runtime, name, candidate);
		let local = final_offset == null ? null : gmtime(candidate + final_offset);
		if (local != null && local.hour == 2 && local.min == 0)
			return candidate * 1000;
	}
	return null;
};

export function create(runtime) {
	if (type(runtime?.uci?.cursor) != 'function' ||
	    type(runtime?.timezones?.resolve) != 'function')
		invalid();
	return {
		observe: (timestamp_ms) => {
			let invalid_result = { valid: false, local_date: null, minute: null,
				in_window: false, before_cutoff: false, next_window: null };
			if (type(timestamp_ms) != 'int' || timestamp_ms < MIN_SYNCED_MS ||
			    timestamp_ms > MAX_TIMESTAMP_MS)
				return invalid_result;
			let cursor, section, configured;
			try {
				cursor = runtime.uci.cursor();
				section = cursor.get_first('system', 'system');
				configured = section == null ? null : cursor.get('system', section, 'zonename');
			}
			catch (error) { return invalid_result; }
			let name = configured == null || configured == '' ? 'UTC' : zone_name(configured);
			if (name == null) return invalid_result;
			let timestamp = int(timestamp_ms / 1000);
			let offset = offset_at(runtime, name, timestamp);
			if (offset == null) return invalid_result;
			let local = gmtime(timestamp + offset);
			if (local == null) return invalid_result;
			let minute = local.hour * 60 + local.min;
			let local_day_pseudo = timestamp + offset -
				(local.hour * 3600 + local.min * 60 + local.sec);
			let next_window = target_utc(runtime, name, local_day_pseudo,
				minute < WINDOW_START ? 0 : 1);
			if (next_window == null) return invalid_result;
			return {
				valid: true,
				local_date: date_string(local),
				minute,
				in_window: minute >= WINDOW_START && minute < WINDOW_END,
				before_cutoff: minute < START_CUTOFF,
				next_window
			};
		}
	};
};
