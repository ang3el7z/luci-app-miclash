const MASK = '[REDACTED]';
const SANITIZE_MAX_DEPTH = 16;
const SANITIZE_MAX_NODES = 4096;
const SANITIZE_MAX_INPUT = 131072;
const SANITIZE_MAX_STRING = 16384;
const SANITIZE_MAX_RAW_SECRETS = 64;
const SANITIZE_MAX_VARIANTS = 256;
const SANITIZE_MIN_URL_ALIAS = 4;

function normalized_name(input) {
	let output = '';
	for (let offset = 0; offset < length(input); offset++) {
		let character = substr(input, offset, 1);
		let previous = offset ? substr(input, offset - 1, 1) : '';
		let next = offset + 1 < length(input) ? substr(input, offset + 1, 1) : '';
		if (match(character, /^[A-Z]$/)) {
			if (length(output) && substr(output, -1) != '_' &&
			    (match(previous, /^[a-z0-9]$/) ||
			     (match(previous, /^[A-Z]$/) && match(next, /^[a-z]$/))))
				output += '_';
			output += lc(character);
		}
		else if (match(character, /^[A-Za-z0-9]$/))
			output += lc(character);
		else if (length(output) && substr(output, -1) != '_')
			output += '_';
	}
	return output;
};

function classified_name(normalized) {
	if (normalized == 'recovery_of')
		return true;
	for (let part in split(normalized, '_'))
		if (part == 'auth' || part == 'authorization' || part == 'bearer' ||
		    part == 'cookie' || part == 'credential' || part == 'password' ||
		    part == 'passwd' || part == 'secret' || part == 'session' ||
		    part == 'token' || part == 'key')
			return true;
	return match(normalized, /^(auth|authorization|bearer|cookie|credential|password|passwd|secret|session|token)$/) ||
	       match(normalized, /_(auth|authorization|bearer|cookie|credential|password|passwd|secret|session|token)$/) ||
	       match(normalized, /^(auth|authorization|bearer|cookie|credential|password|passwd|secret|session|token)_(value|data|header)$/) ||
	       match(normalized, /(^|_)(api|private|access|secret|signing|ssh)key($|_)/) ||
	       match(normalized, /(^|_)(access|refresh)token($|_)/) ||
	       match(normalized, /(^|_)clientsecret($|_)/) ||
	       match(normalized, /(^|_)telegramtoken($|_)/) ||
	       match(normalized, /^subscription_?url/);
};

function secret_key(key) {
	if (type(key) != 'string')
		return false;

	let normalized = normalized_name(key);
	if (normalized == 'public_key' || normalized == 'session_count')
		return false;
	let folded = replace(lc(key), /[^a-z0-9]+/g, '_');
	return classified_name(normalized) || classified_name(folded);
};

function structural_event_key(key, parent_depth) {
	return parent_depth == 0 && (key == 'dedupe_key' || key == 'recovery_of');
};

function sanitize_secret_key(key, parent_depth) {
	if (structural_event_key(key, parent_depth))
		return false;
	return secret_key(key);
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

function last_character(input, wanted) {
	let result = -1;
	for (let offset = 0; offset < length(input); offset++)
		if (substr(input, offset, 1) == wanted)
			result = offset;
	return result;
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
	let userinfo_end = last_character(authority, '@');
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

function add_secret(secrets, input) {
	if (type(input) != 'string' || !length(input) || length(input) > SANITIZE_MAX_STRING ||
	    input == MASK || input == '***')
		return;
	for (let existing in secrets)
		if (existing == input)
			return;
	if (length(secrets) >= SANITIZE_MAX_RAW_SECRETS)
		die('RESPONSE_TOO_LARGE');
	push(secrets, input);
};

function discover_marker(secrets, input, marker) {
	let lowered = lc(input), offset = 0;
	while (offset < length(input)) {
		let relative = index(substr(lowered, offset), marker);
		if (relative < 0)
			return;
		let start = offset + relative + length(marker);
		while (start < length(input) && match(substr(input, start, 1), /[ \t]/))
			start++;
		let end = start;
		while (end < length(input) &&
		       !match(substr(input, end, 1), /[[:space:],;'"<>?&#]/))
			end++;
		if (end > start)
			add_secret(secrets, substr(input, start, end - start));
		offset = max(end, offset + relative + length(marker));
	}
};

function percent_decoded(input) {
	let output = '';
	for (let offset = 0; offset < length(input); offset++) {
		if (substr(input, offset, 1) == '%' && offset + 2 < length(input)) {
			let hex = substr(input, offset + 1, 2);
			if (match(hex, /^[0-9A-Fa-f]{2}$/)) {
				output += chr(int(hex, 16));
				offset += 2;
				continue;
			}
		}
		output += substr(input, offset, 1);
	}
	return output;
};

function discover_url_component(secrets, input) {
	if (!length(input))
		return;
	let decoded = percent_decoded(input);
	if (length(input) < SANITIZE_MIN_URL_ALIAS ||
	    length(decoded) < SANITIZE_MIN_URL_ALIAS)
		die('INVALID_ARGUMENT');
	add_secret(secrets, input);
	if (decoded != input)
		add_secret(secrets, decoded);
};

function discover_url_userinfo(secrets, input) {
	let remaining = input;
	while (length(remaining)) {
		let start = next_url_start(remaining);
		if (start < 0)
			return;
		let candidate = substr(remaining, start), end = length(candidate);
		for (let offset = 0; offset < length(candidate); offset++)
			if (match(substr(candidate, offset, 1), /[[:space:][:cntrl:]]/)) {
				end = offset;
				break;
			}
		let first_scheme_end = index(candidate, '://') + 3;
		let next_url = next_url_start(substr(candidate, first_scheme_end));
		if (next_url >= 0 && first_scheme_end + next_url < end)
			end = first_scheme_end + next_url;
		let url = substr(candidate, 0, end);
		let scheme_end = index(url, '://'), authority_start = scheme_end + 3;
		let authority_end = length(url), authority_tail = substr(url, authority_start);
		for (let delimiter in [ '/', '?', '#' ]) {
			let position = index(authority_tail, delimiter);
			if (position >= 0 && authority_start + position < authority_end)
				authority_end = authority_start + position;
		}
		let authority = substr(url, authority_start, authority_end - authority_start);
		let userinfo_end = last_character(authority, '@');
		if (userinfo_end >= 0) {
			let userinfo = substr(authority, 0, userinfo_end);
			let separator = index(userinfo, ':');
			if (separator < 0)
				discover_url_component(secrets, userinfo);
			else {
				discover_url_component(secrets, substr(userinfo, 0, separator));
				discover_url_component(secrets, substr(userinfo, separator + 1));
			}
		}
		remaining = substr(candidate, max(end, 1));
	}
};

function discover_text(secrets, input) {
	discover_url_userinfo(secrets, input);
	for (let marker in [
		'bearer ', 'basic ', 'auth=', 'auth:', 'authorization=', 'authorization:',
		'cookie=', 'cookie:', 'credential=', 'credential:', 'password=', 'password:',
		'passwd=', 'passwd:', 'secret=', 'secret:', 'session=', 'session:',
		'token=', 'token:', 'api_key=', 'api_key:', 'api-key=', 'api-key:',
		'private_key=', 'private_key:', 'private-key=', 'private-key:',
		'access_key=', 'access_key:', 'access-key=', 'access-key:',
		'client_secret=', 'client_secret:', 'client-secret=', 'client-secret:'
	])
		discover_marker(secrets, input, marker);

	let lowered = lc(input), offset = 0;
	while (offset < length(input)) {
		let relative = index(substr(lowered, offset), 'cookie:');
		if (relative < 0)
			break;
		let start = offset + relative + 7, end = start;
		while (end < length(input) && substr(input, end, 1) != '\n' &&
		       substr(input, end, 1) != '\r')
			end++;
		for (let pair in split(substr(input, start, end - start), ';')) {
			let separator = index(pair, '=');
			if (separator < 0)
				continue;
			let item = trim(substr(pair, separator + 1));
			if (length(item) >= 2 &&
			    ((substr(item, 0, 1) == '"' && substr(item, -1) == '"') ||
			     (substr(item, 0, 1) == "'" && substr(item, -1) == "'")))
				item = substr(item, 1, length(item) - 2);
			add_secret(secrets, item);
		}
		offset = max(end + 1, start);
	}
};

function discover(input) {
	let secrets = [], stack = [ { value: input, key: null, depth: 0, sensitive: false } ];
	let nodes = 0, aggregate = 0;
	while (length(stack)) {
		let item = pop(stack), kind = type(item.value);
		if (item.depth > SANITIZE_MAX_DEPTH || ++nodes > SANITIZE_MAX_NODES)
			die('RESPONSE_TOO_LARGE');
		let sensitive = item.sensitive;
		if (type(item.key) == 'string') {
			if (length(item.key) > SANITIZE_MAX_STRING)
				die('RESPONSE_TOO_LARGE');
			aggregate += length(item.key);
			discover_text(secrets, item.key);
			sensitive = sensitive || sanitize_secret_key(item.key, item.depth - 1);
		}
		if (kind == 'string') {
			if (length(item.value) > SANITIZE_MAX_STRING)
				die('RESPONSE_TOO_LARGE');
			aggregate += length(item.value);
			discover_text(secrets, item.value);
			if (sensitive)
				add_secret(secrets, item.value);
		}
		else if (kind == 'array')
			for (let child in item.value)
				push(stack, { value: child, key: null, depth: item.depth + 1, sensitive });
		else if (kind == 'object')
			for (let name, child in item.value)
				push(stack, { value: child, key: name, depth: item.depth + 1, sensitive });
		else {
			if (sensitive)
				die('INVALID_ARGUMENT');
			if (kind != null && kind != 'null' && kind != 'bool' &&
			    kind != 'int' && kind != 'double')
				die('INVALID_ARGUMENT');
		}
		if (aggregate > SANITIZE_MAX_INPUT)
			die('RESPONSE_TOO_LARGE');
	}
	return secrets;
};

function percent_variant(input, all) {
	let output = '';
	for (let offset = 0; offset < length(input); offset++) {
		let character = substr(input, offset, 1);
		output += !all && match(character, /^[A-Za-z0-9_.~-]$/) ?
			character : sprintf('%%%02X', ord(input, offset));
	}
	return output;
};

function secret_variants(raw) {
	let output = [];
	function add(input) {
		if (type(input) != 'string' || !length(input) || length(input) > SANITIZE_MAX_INPUT)
			return;
		for (let existing in output)
			if (existing == input)
				return;
		if (length(output) >= SANITIZE_MAX_VARIANTS)
			die('RESPONSE_TOO_LARGE');
		push(output, input);
	};
	for (let secret in raw) {
		add(secret);
		add(percent_variant(secret, false));
		add(lc(percent_variant(secret, false)));
		add(percent_variant(secret, true));
		add(lc(percent_variant(secret, true)));
		try {
			let base64 = b64enc(secret);
			let urlsafe = replace(replace(base64, /\+/g, '-'), /\//g, '_');
			add(base64);
			add(urlsafe);
			add(replace(base64, /=+$/, ''));
			add(replace(urlsafe, /=+$/, ''));
		}
		catch (error) {}
	}
	sort(output, (left, right) => length(right) - length(left));
	return output;
};

function replace_all(input, wanted, replacement) {
	if (!length(wanted))
		return input;
	let output = '', rest = input;
	while (true) {
		let position = index(rest, wanted);
		if (position < 0)
			return output + rest;
		output += substr(rest, 0, position) + replacement;
		rest = substr(rest, position + length(wanted));
	}
};

function replace_mixed_percent(input, wanted) {
	if (!length(wanted))
		return input;
	let output = '', offset = 0;
	while (offset < length(input)) {
		let cursor = offset, wanted_offset = 0, encoded = false;
		while (wanted_offset < length(wanted) && cursor < length(input)) {
			let expected = substr(wanted, wanted_offset, 1);
			if (substr(input, cursor, 1) == '%' && cursor + 2 < length(input)) {
				let hex = substr(input, cursor + 1, 2);
				if (match(hex, /^[0-9A-Fa-f]{2}$/) &&
				    lc(hex) == lc(sprintf('%02X', ord(wanted, wanted_offset)))) {
					cursor += 3;
					wanted_offset++;
					encoded = true;
					continue;
				}
			}
			if (substr(input, cursor, 1) != expected)
				break;
			cursor++;
			wanted_offset++;
		}
		if (encoded && wanted_offset == length(wanted)) {
			output += MASK;
			offset = cursor;
		}
		else {
			output += substr(input, offset, 1);
			offset++;
		}
	}
	return output;
};

function scrub_text(input, secrets) {
	let output = redact_text(input);
	for (let secret in secrets) {
		output = replace_all(output, secret, MASK);
		output = replace_mixed_percent(output, secret);
	}
	return output;
};

function scrub(input, secrets, depth) {
	if (type(input) == 'array') {
		let output = [];
		for (let item in input)
			push(output, scrub(item, secrets, depth + 1));
		return output;
	}
	if (type(input) == 'object') {
		let output = {};
		for (let name, item in input) {
			let scrubbed_name = scrub_text(name, secrets);
			let sensitive = sanitize_secret_key(name, depth);
			if (scrubbed_name != name)
				die('INVALID_ARGUMENT');
			if (exists(output, name))
				die('INVALID_ARGUMENT');
			output[name] = sensitive ? MASK : scrub(item, secrets, depth + 1);
		}
		return output;
	}
	return type(input) == 'string' ? scrub_text(input, secrets) : input;
};

export function sanitize(input) {
	let safe = scrub(input, secret_variants(discover(input)), 0);
	let encoded;
	try { encoded = sprintf('%J', safe); }
	catch (error) { die('INVALID_ARGUMENT'); }
	if (length(encoded) > SANITIZE_MAX_INPUT)
		die('RESPONSE_TOO_LARGE');
	return safe;
};

export function secret_name(input) {
	return secret_key(input);
};

export function normalized_key(input) {
	return type(input) == 'string' ? normalized_name(input) : '';
};

export { MASK };
