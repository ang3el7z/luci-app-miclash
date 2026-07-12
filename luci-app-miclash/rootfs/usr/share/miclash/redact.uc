const MASK = '[REDACTED]';

function secret_key(key) {
	if (type(key) != 'string')
		return false;

	let normalized = replace(lc(key), /[^a-z0-9]+/g, '_');
	return match(normalized, /^(auth|authorization|bearer|cookie|credential|password|passwd|secret|session|token)$/) ||
	       match(normalized, /^(api|private|access)_?key$/) ||
	       match(normalized, /^(access|refresh)_?token$/) ||
	       match(normalized, /^client_?secret$/) ||
	       match(normalized, /^telegram_?token$/);
};

function masked(value) {
	return value == MASK || value == '***';
};

export function value(key, input) {
	if (key != null && secret_key(key))
		return masked(input) ? input : MASK;

	if (type(input) == 'array') {
		let copy = [];
		for (let item in input)
			push(copy, value(null, item));
		return copy;
	}

	if (type(input) == 'object') {
		let copy = {};
		for (let name, item in input)
			copy[name] = value(name, item);
		return copy;
	}

	return key == null ? (masked(input) ? input : MASK) : input;
};

export function text(input) {
	if (type(input) != 'string')
		return value(null, input);

	let output = replace(input,
		/([A-Za-z][A-Za-z0-9+.-]*:\/\/)[^\/@[:space:]]*@/g,
		'$1***:***@');

	output = replace(output,
		/([?&](auth|authorization|credential|password|passwd|secret|session|token)=)[^&#[:space:]]*/gi,
		'$1***');
	return replace(output,
		/([?&](api[_-]?key|private[_-]?key|access[_-]?(key|token)|refresh[_-]?token|client[_-]?secret)=)[^&#[:space:]]*/gi,
		'$1***');
};

export { MASK };
