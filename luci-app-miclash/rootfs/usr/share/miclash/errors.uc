import * as redact from 'miclash.redact';

const CODES = [
	'INVALID_ARGUMENT',
	'NOT_FOUND',
	'BUSY',
	'VALIDATION_FAILED',
	'HEALTH_FAILED',
	'DOWNLOAD_FAILED',
	'PERMISSION_DENIED',
	'INTERRUPTED',
	'CORRUPT_STATE',
	'RESOURCE_EXHAUSTED',
	'RESPONSE_TOO_LARGE',
	'INSUFFICIENT_STORAGE',
	'INVALID_RESPONSE',
	'INTERNAL'
];

function known_code(code) {
	for (let allowed in CODES)
		if (code == allowed)
			return true;

	return false;
};

export function new(code, message, detail) {
	if (!known_code(code))
		code = 'INTERNAL';

	let error = {
		code,
		message: type(message) == 'string' && length(message) ? message : code
	};

	if (detail != null)
		error.detail = redact.value(null, detail);

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
