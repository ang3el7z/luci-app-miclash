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

function query_redacted(url) {
	let query_start = index(url, '?');
	if (query_start < 0)
		return url;

	let fragment_start = index(url, '#');
	if (fragment_start >= 0 && fragment_start < query_start)
		return url;

	let query_end = fragment_start >= 0 ? fragment_start : length(url);
	let query = substr(url, query_start + 1, query_end - query_start - 1);
	let parameters = [];
	for (let parameter in split(query, '&')) {
		let separator = index(parameter, '=');
		if (separator < 0) {
			push(parameters, parameter);
			continue;
		}

		let key = substr(parameter, 0, separator);
		let input = substr(parameter, separator + 1);
		push(parameters, key + '=' + (secret_key(key) && !masked(input) ? '***' : input));
	}

	return substr(url, 0, query_start + 1) + join('&', parameters) +
	       substr(url, query_end);
};

function url_redacted(url) {
	let scheme_end = index(url, '://');
	if (scheme_end < 0)
		return url;

	let authority_start = scheme_end + 3;
	let authority_end = length(url);
	let remainder = substr(url, authority_start);
	for (let delimiter in [ '/', '?', '#' ]) {
		let position = index(remainder, delimiter);
		if (position >= 0 && authority_start + position < authority_end)
			authority_end = authority_start + position;
	}

	let authority = substr(url, authority_start, authority_end - authority_start);
	let userinfo_end = index(authority, '@');
	if (userinfo_end >= 0)
		url = substr(url, 0, authority_start) + '***:***@' +
		      substr(authority, userinfo_end + 1) + substr(url, authority_end);

	return query_redacted(url);
};

function next_url_start(input) {
	let lowered = lc(input);
	let http = index(lowered, 'http://');
	let https = index(lowered, 'https://');
	if (http < 0)
		return https;
	if (https < 0)
		return http;
	return http < https ? http : https;
};

function redact_text(input) {
	let remaining = input;
	let output = '';
	while (length(remaining)) {
		let start = next_url_start(remaining);
		if (start < 0)
			return output + remaining;

		output += substr(remaining, 0, start);
		remaining = substr(remaining, start);
		let end = length(remaining);
		for (let offset = 0; offset < length(remaining); offset++)
			if (match(substr(remaining, offset, 1), /[[:space:][:cntrl:]]/)) {
				end = offset;
				break;
			}

		output += url_redacted(substr(remaining, 0, end));
		remaining = substr(remaining, end);
	}
	return output;
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

	if (type(input) == 'string') {
		let output = redact_text(input);
		if (key != null || output != input)
			return output;
	}

	return key == null ? (masked(input) ? input : MASK) : input;
};
export function text(input) {
	return type(input) == 'string' ? redact_text(input) : value(null, input);
};

export { MASK };
