import { fail } from 'miclash.errors';

function invalid() {
	fail('INVALID_ARGUMENT');
};

function expected_type(value, expected) {
	let actual = type(value);

	if (expected == 'integer')
		return actual == 'int';
	if (expected == 'number')
		return actual == 'int' || actual == 'double';
	if (expected == 'boolean')
		return actual == 'bool';

	return actual == expected;
};

export function enum_value(value, allowed) {
	for (let candidate in allowed)
		if (value == candidate)
			return value;

	invalid();
};

export function validate(spec, value) {
	if (type(spec) == 'string')
		spec = { type: spec };

	if (type(spec) != 'object')
		invalid();

	if (value == null && spec.nullable)
		return value;

	if (spec.type != null && !expected_type(value, spec.type))
		invalid();

	if (spec.max_length != null &&
	    (type(value) != 'string' && type(value) != 'array' || length(value) > spec.max_length))
		invalid();

	if (spec.min_length != null &&
	    (type(value) != 'string' && type(value) != 'array' || length(value) < spec.min_length))
		invalid();

	if (spec.enum != null)
		enum_value(value, spec.enum);

	if (spec.items != null) {
		if (type(value) != 'array')
			invalid();
		for (let item in value)
			validate(spec.items, item);
	}

	if (spec.fields != null)
		object(value, spec.fields);

	return value;
};

export function object(value, fields) {
	if (type(value) != 'object' || type(fields) != 'object')
		invalid();

	for (let name in value)
		if (!exists(fields, name))
			invalid();

	for (let name, field in fields) {
		if (!exists(value, name)) {
			if (field.required)
				invalid();
			continue;
		}

		validate(field, value[name]);
	}

	return value;
};

export function secret(value) {
	return validate({ type: 'string', max_length: 4096 }, value);
};

export function profile_name(value) {
	validate({ type: 'string', max_length: 12 }, value);
	if (!match(value, /^config[0-3]\.yaml$/))
		invalid();
	return value;
};

export function url(value) {
	validate({ type: 'string', max_length: 2048 }, value);
	if (!match(value, /^https?:\/\/[^ ]+$/))
		invalid();
	return value;
};

export function managed_update_url(value) {
	validate({ type: 'string', max_length: 2048 }, value);
	if (!match(value, /^https:\/\/[^ ]+$/))
		invalid();
	return value;
};

export function mac_address(value) {
	validate({ type: 'string', max_length: 17 }, value);
	if (!match(value, /^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$/))
		invalid();
	return value;
};

export function operation_id(value) {
	validate({ type: 'string', min_length: 1, max_length: 64 }, value);
	if (!match(value, /^[A-Za-z0-9][A-Za-z0-9._-]*$/))
		invalid();
	return value;
};

export function archive_name(value) {
	validate({ type: 'string', min_length: 1, max_length: 128 }, value);
	if (!match(value, /^[A-Za-z0-9][A-Za-z0-9._-]*$/) || match(value, /\.\./))
		invalid();
	return value;
};
