const CODES = [
	'INVALID_ARGUMENT',
	'NOT_FOUND',
	'BUSY',
	'VALIDATION_FAILED',
	'HEALTH_FAILED',
	'DOWNLOAD_FAILED',
	'PERMISSION_DENIED',
	'INTERRUPTED',
	'INTERNAL'
];

function known_code(code) {
	for (let allowed in CODES)
		if (code == allowed)
			return true;

	return false;
};

function redact(value, key) {
	if (key != null && match(lc(key), /(authorization|cookie|password|secret|token)/))
		return '[REDACTED]';

	if (type(value) == 'array') {
		let copy = [];
		for (let item in value)
			push(copy, redact(item, null));
		return copy;
	}

	if (type(value) == 'object') {
		let copy = {};
		for (let name, item in value)
			copy[name] = redact(item, name);
		return copy;
	}

	return value;
};

export function new(code, message, detail) {
	if (!known_code(code))
		code = 'INTERNAL';

	let error = {
		code,
		message: type(message) == 'string' && length(message) ? message : code
	};

	if (detail != null)
		error.detail = redact(detail, null);

	return error;
};

export function normalize(error) {
	if (type(error) == 'object' && known_code(error.code))
		return new(error.code, error.message, error.detail);

	let message = type(error) == 'string' ? error : error?.message;
	if (known_code(message))
		return new(message, message, null);

	return new('INTERNAL', 'Internal error', null);
};

export function fail(code) {
	die(known_code(code) ? code : 'INTERNAL');
};

export { CODES };
