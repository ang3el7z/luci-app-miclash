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
	if (value != 'config.yaml' && value != 'config2.yaml' && value != 'config3.yaml')
		invalid();
	return value;
};

function validate_dns_host(host) {
	if (length(host) > 253)
		invalid();

	for (let label in split(host, '.'))
		if (!length(label) || length(label) > 63 ||
		    !match(label, /^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$/))
			invalid();
};

function validate_ipv4_host(host) {
	let octets = split(host, '.');
	if (length(octets) != 4)
		invalid();

	for (let octet in octets) {
		if (!match(octet, /^(0|[1-9][0-9]*)$/))
			invalid();
		let number = int(octet);
		if (number == null || number < 0 || number > 255)
			invalid();
	}
};

function validate_url_host(host) {
	if (match(host, /^[0-9.]+$/) && index(host, '.') >= 0)
		validate_ipv4_host(host);
	else
		validate_dns_host(host);
};

function validated_url(value) {
	validate({ type: 'string', max_length: 2048 }, value);
	if (match(value, /[[:space:][:cntrl:]]/))
		invalid();

	let offset;
	if (match(value, /^https:\/\//))
		offset = 8;
	else if (match(value, /^http:\/\//))
		offset = 7;
	else
		invalid();

	let remainder = substr(value, offset);
	let boundary = length(remainder);
	for (let delimiter in [ '/', '?', '#' ]) {
		let position = index(remainder, delimiter);
		if (position >= 0 && position < boundary)
			boundary = position;
	}

	let authority = substr(remainder, 0, boundary);
	let parts = split(authority, ':');
	if (!length(authority) || length(parts) > 2)
		invalid();

	validate_url_host(parts[0]);
	if (length(parts) == 2) {
		if (!match(parts[1], /^[0-9]+$/))
			invalid();
		let port = int(parts[1]);
		if (port == null || port < 1 || port > 65535)
			invalid();
	}

	return value;
};

export function url(value) {
	return validated_url(value);
};

export function managed_update_url(value) {
	validated_url(value);
	if (!match(value, /^https:\/\//))
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
