import * as redact from 'miclash.redact';

const MASK = '[REDACTED]';
const MAX_TEXT_INPUT = 131072;
const MAX_TOKEN_LENGTH = 4096;
const MAX_DISCOVERY_TOKENS = 2048;
const MAX_CATALOG_VALUES = 128;
const MAX_CATALOG_BYTES = 32768;
const MAX_VALUE_DEPTH = 16;
const MAX_VALUE_NODES = 4096;
const MAX_PATH_DEPTH = 64;
const MAX_PATH_NODES = 64;
const MAX_PATH_BYTES = 32768;
const MAX_REPLACEMENT_PATTERNS = 1024;
const MAX_REPLACEMENT_MATCHES = 4096;
const MAX_VARIANT_BYTES = 262144;

function enum_mode(mode) {
	if (mode != 'silent' && mode != 'lite' && mode != 'full')
		die('INVALID_ARGUMENT');
	return mode;
};

function contains(values, value) {
	for (let item in values)
		if (item == value)
			return true;
	return false;
};

function fail_closed(catalog) {
	catalog.failed_closed = true;
	return false;
};

function catalog_store(catalog, values, value) {
	if (type(value) != 'string' || !length(value))
		return true;
	if (length(value) > MAX_TOKEN_LENGTH)
		return fail_closed(catalog);
	if (contains(values, value))
		return true;
	if (catalog.count >= MAX_CATALOG_VALUES ||
	    catalog.bytes + length(value) > MAX_CATALOG_BYTES)
		return fail_closed(catalog);
	push(values, value);
	catalog.count++;
	catalog.bytes += length(value);
	return true;
};

function trim_token(value) {
	while (length(value) && (substr(value, 0, 1) == '"' || substr(value, 0, 1) == "'" ||
	       match(substr(value, 0, 1), /^[\[\](),;:<>]$/)))
		value = substr(value, 1);
	while (length(value) && (substr(value, -1) == '"' || substr(value, -1) == "'" ||
	       match(substr(value, -1), /^[\[\](),;:<>.!?]$/)))
		value = substr(value, 0, length(value) - 1);
	return value;
};

function typed_kind(key) {
	let normalized = redact.normalized_key(key);
	if (match(normalized, /(^|_)(hostname|host_name)($|_)/)) return 'hosts';
	if (match(normalized, /(^|_)(device|ssid|mac)($|_)/)) return 'devices';
	if (match(normalized, /(^|_)(id|uuid|user_id|chat_id|telegram_id)($|_)/)) return 'ids';
	return null;
};

function valid_path(path) {
	if (type(path) != 'array' || length(path) > MAX_PATH_DEPTH)
		return false;
	let nodes = 0, bytes = 0;
	for (let segment in path) {
		if (++nodes > MAX_PATH_NODES)
			return false;
		let kind = type(segment);
		if (kind == 'string') {
			if (length(segment) > MAX_TOKEN_LENGTH)
				return false;
			bytes += length(segment);
		}
		else if (kind == 'int' && segment >= 0)
			bytes += 8;
		else
			return false;
		if (bytes > MAX_PATH_BYTES)
			return false;
	}
	return true;
};

function subscription_context(path) {
	for (let segment in path) {
		if (type(segment) != 'string')
			continue;
		let normalized = redact.normalized_key(segment);
		if (match(normalized, /(^|_)subscriptions?($|_)/))
			return true;
	}
	return false;
};

function classified(key, value) {
	return typed_kind(key) == null &&
		(redact.secret_name(key) || match(value, /^[0-9]{5,}:[^[:space:]]+$/));
};

function catalog_add(catalog, kind, value) {
	value = trim_token(value);
	if (!length(value))
		return true;
	return catalog_store(catalog, kind == 'secret' ? catalog.secrets : catalog[kind], value);
};

function catalog_url(catalog, spelling, canonical, sensitive) {
	spelling = trim_token(spelling);
	canonical = trim_token(canonical);
	if (!catalog_add(catalog, 'urls', canonical) ||
	    (sensitive && !catalog_store(catalog, catalog.sensitive_urls, canonical)) ||
	    spelling == canonical)
		return !catalog.failed_closed;
	for (let alias in catalog.url_aliases)
		if (alias.spelling == spelling && alias.canonical == canonical)
			return true;
	if (length(spelling) > MAX_TOKEN_LENGTH ||
	    catalog.count >= MAX_CATALOG_VALUES ||
	    catalog.bytes + length(spelling) > MAX_CATALOG_BYTES)
		return fail_closed(catalog);
	push(catalog.url_aliases, { spelling, canonical });
	catalog.count++;
	catalog.bytes += length(spelling);
	return true;
};

function percent_decoded(input) {
	if (length(input) > MAX_TOKEN_LENGTH)
		return null;
	let output = '';
	for (let offset = 0; offset < length(input); offset++) {
		if (substr(input, offset, 1) == '%' && offset + 2 < length(input) &&
		    match(substr(input, offset + 1, 2), /^[0-9A-Fa-f]{2}$/)) {
			output += chr(int(substr(input, offset + 1, 2), 16));
			offset += 2;
		}
		else output += substr(input, offset, 1);
	}
	return output;
};

function classify_token(catalog, token, spelling, sensitive) {
	token = trim_token(token);
	if (!length(token))
		return false;
	if (match(token, /^https?:\/\/[^[:space:]]+$/)) {
		catalog_url(catalog, spelling ?? token, token, sensitive);
		return true;
	}
	else if (match(token, /^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$/)) {
		catalog_add(catalog, 'devices', token);
		return true;
	}
	else if (match(token, /^[0-9]{1,3}(\.[0-9]{1,3}){3}(\/[0-9]{1,2})?$/) ||
	         match(token, /^[0-9A-Fa-f:]+(:[0-9A-Fa-f:]+)+(\/[0-9]{1,3})?$/)) {
		catalog_add(catalog, 'ips', token);
		return true;
	}
	else if (match(token, /^[0-9a-fA-F]{8}-[0-9a-fA-F-]{27}$/)) {
		catalog_add(catalog, 'ids', token);
		return true;
	}
	else if (match(token,
	         /^[A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z]{2,}:[0-9]{1,5}$/)) {
		let separator = index(token, ':');
		let port = int(substr(token, separator + 1));
		if (port > 65535)
			return false;
		catalog_add(catalog, 'hosts', substr(token, 0, separator));
		return true;
	}
	else if (match(token, /^[A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z]{2,}$/)) {
		catalog_add(catalog, 'hosts', token);
		return true;
	}
	return false;
};

function base64_decoded(input) {
	if (length(input) < 4 || length(input) > MAX_TOKEN_LENGTH ||
	    !match(input, /^[A-Za-z0-9+\/_-]+={0,2}$/))
		return null;
	let base64 = replace(replace(input, /-/g, '+'), /_/g, '/');
	let remainder = length(base64) % 4;
	if (remainder == 1)
		return null;
	if (remainder == 2) base64 += '==';
	else if (remainder == 3) base64 += '=';
	try {
		let decoded = b64dec(base64);
		return type(decoded) == 'string' && length(decoded) <= MAX_TOKEN_LENGTH ?
			decoded : null;
	}
	catch (error) {
		return null;
	}
};

function canonical_url(value) {
	if (type(value) != 'string')
		return null;
	let spelling = trim_token(value);
	let decoded = percent_decoded(spelling);
	if (decoded != null && match(decoded, /^https?:\/\/[^[:space:]]+$/))
		return decoded;
	let decoded64 = base64_decoded(spelling);
	if (decoded64 == null)
		return null;
	let canonical64 = percent_decoded(decoded64);
	return canonical64 != null && match(canonical64, /^https?:\/\/[^[:space:]]+$/) ?
		canonical64 : null;
};

function credential_query_url(value) {
	let query_start = index(value, '?');
	if (query_start < 0)
		return false;
	let fragment_start = index(value, '#');
	let query_end = fragment_start >= 0 ? fragment_start : length(value);
	let query = replace(substr(value, query_start + 1,
		query_end - query_start - 1), /;/g, '&');
	for (let parameter in split(query, '&')) {
		let separator = index(parameter, '=');
		if (separator < 1)
			continue;
		let key = substr(parameter, 0, separator);
		let normalized = redact.normalized_key(key);
		if (redact.secret_name(key) || normalized == 'credentials')
			return true;
	}
	return false;
};

function sensitive_url(value) {
	let lowered = lc(value);
	return index(lowered, 'token=') >= 0 || index(lowered, 'subscribe') >= 0 ||
		index(lowered, 'subscription') >= 0 || credential_query_url(value) ||
		match(value, /^https?:\/\/[^\/@]+:[^\/@]+@/);
};

function credential_add(catalog, input) {
	input = trim_token(input);
	if (!length(input))
		return true;
	if (length(input) > MAX_TOKEN_LENGTH)
		return fail_closed(catalog);
	if (!catalog_add(catalog, 'secret', input))
		return false;
	let decoded = percent_decoded(input);
	if (decoded == null)
		return fail_closed(catalog);
	if (decoded != input && !catalog_add(catalog, 'secret', decoded))
		return false;
	let decoded64 = base64_decoded(input);
	if (decoded64 != null && match(decoded64, /^[[:print:]\t]+$/) &&
	    !catalog_add(catalog, 'secret', decoded64))
		return false;
	return true;
};

function marker_key_character(character) {
	return match(character, /^[A-Za-z0-9_.-]$/);
};

function assigned_values(catalog, input) {
	let offset = 0;
	while (offset < length(input) && !catalog.failed_closed) {
		while (offset < length(input) &&
		       !marker_key_character(substr(input, offset, 1)))
			offset++;
		let found = offset;
		while (offset < length(input) &&
		       marker_key_character(substr(input, offset, 1)))
			offset++;
		if (offset <= found)
			continue;
		let key = substr(input, found, offset - found), cursor = offset;
		while (cursor < length(input) &&
		       match(substr(input, cursor, 1), /^[ \t]$/))
			cursor++;
		if (cursor >= length(input) ||
		    (substr(input, cursor, 1) != ':' && substr(input, cursor, 1) != '=')) {
			offset = max(cursor, found + 1);
			continue;
		}
		let secret = redact.secret_name(key), typed = typed_kind(key);
		if (!secret && typed == null) {
			offset = cursor + 1;
			continue;
		}
		cursor++;
		while (cursor < length(input) &&
		       match(substr(input, cursor, 1), /^[ \t]$/))
			cursor++;
		if (secret) {
			let tail = lc(substr(input, cursor));
			for (let scheme in [ 'bearer', 'basic' ])
				if (substr(tail, 0, length(scheme)) == scheme &&
				    match(substr(tail, length(scheme), 1), /^[ \t]$/)) {
					cursor += length(scheme);
					while (cursor < length(input) &&
					       match(substr(input, cursor, 1), /^[ \t]$/))
						cursor++;
					break;
				}
		}
		let quote = cursor < length(input) &&
			(substr(input, cursor, 1) == '"' || substr(input, cursor, 1) == "'") ?
			substr(input, cursor++, 1) : null;
		let end = cursor;
		if (quote != null) {
			while (end < length(input) && substr(input, end, 1) != quote)
				end++;
		}
		else if (secret) {
			while (end < length(input) &&
			       !match(substr(input, end, 1), /^[[:space:],;'"<>&#]$/))
				end++;
		}
		else {
			while (end < length(input) && substr(input, end, 1) != '\n' &&
			       substr(input, end, 1) != '\r') {
				if (match(substr(input, end, 1), /^[ \t]$/)) {
					let next = end + 1;
					while (next < length(input) &&
					       match(substr(input, next, 1), /^[ \t]$/))
						next++;
					let key_end = next;
					while (key_end < length(input) &&
					       marker_key_character(substr(input, key_end, 1)))
						key_end++;
					let delimiter = key_end;
					while (delimiter < length(input) &&
					       match(substr(input, delimiter, 1), /^[ \t]$/))
						delimiter++;
					if (key_end > next && delimiter < length(input) &&
					    (substr(input, delimiter, 1) == ':' ||
					     substr(input, delimiter, 1) == '=')) {
						end = max(cursor, end);
						break;
					}
				}
				end++;
			}
		}
		let discovered = trim(substr(input, cursor, end - cursor));
		if (length(discovered)) {
			if (secret)
				credential_add(catalog, discovered);
			else
				catalog_add(catalog, typed, discovered);
		}
		offset = max(end + 1, found + 1);
	}
};

function marker_boundary(input, offset) {
	return offset <= 0 || !match(substr(input, offset - 1, 1), /^[A-Za-z0-9_-]$/);
};

function marked_url_values(catalog, input, marker) {
	let lowered = lc(input), offset = 0;
	while (offset < length(input) && !catalog.failed_closed) {
		let relative = index(substr(lowered, offset), marker);
		if (relative < 0)
			return;
		let found = offset + relative, cursor = found + length(marker);
		if (!marker_boundary(input, found)) {
			offset = cursor;
			continue;
		}
		while (cursor < length(input) && match(substr(input, cursor, 1), /^[ \t]$/))
			cursor++;
		if (cursor >= length(input) ||
		    (substr(input, cursor, 1) != ':' && substr(input, cursor, 1) != '=')) {
			offset = found + length(marker);
			continue;
		}
		cursor++;
		while (cursor < length(input) && match(substr(input, cursor, 1), /^[ \t]$/))
			cursor++;
		let quote = cursor < length(input) &&
			(substr(input, cursor, 1) == '"' || substr(input, cursor, 1) == "'") ?
			substr(input, cursor++, 1) : null;
		let end = cursor;
		while (end < length(input)) {
			let character = substr(input, end, 1);
			if ((quote != null && character == quote) ||
			    (quote == null && match(character, /^[[:space:],;'"<>]$/)))
				break;
			end++;
		}
		if (end > cursor) {
			let spelling = substr(input, cursor, end - cursor);
			if (length(spelling) > MAX_TOKEN_LENGTH) {
				fail_closed(catalog);
				return;
			}
			let canonical = canonical_url(spelling);
			if (canonical != null)
				catalog_url(catalog, spelling, canonical, true);
		}
		offset = max(end + 1, found + length(marker));
	}
};

function scheme_secret_values(catalog, input, scheme) {
	let lowered = lc(input), offset = 0;
	while (offset < length(input) && !catalog.failed_closed) {
		let relative = index(substr(lowered, offset), scheme);
		if (relative < 0)
			return;
		let found = offset + relative, cursor = found + length(scheme);
		if (!marker_boundary(input, found) || cursor >= length(input) ||
		    !match(substr(input, cursor, 1), /^[ \t]$/)) {
			offset = cursor;
			continue;
		}
		while (cursor < length(input) && match(substr(input, cursor, 1), /^[ \t]$/))
			cursor++;
		let end = cursor;
		while (end < length(input) &&
		       !match(substr(input, end, 1), /^[[:space:],;'"<>&#]$/))
			end++;
		if (end > cursor)
			credential_add(catalog, substr(input, cursor, end - cursor));
		offset = max(end + 1, cursor);
	}
};

function cookie_values(catalog, input) {
	let lowered = lc(input), offset = 0;
	while (offset < length(input) && !catalog.failed_closed) {
		let relative = index(substr(lowered, offset), 'cookie');
		if (relative < 0)
			return;
		let found = offset + relative, cursor = found + 6;
		if (!marker_boundary(input, found)) {
			offset = cursor;
			continue;
		}
		while (cursor < length(input) && match(substr(input, cursor, 1), /^[ \t]$/))
			cursor++;
		if (cursor >= length(input) ||
		    (substr(input, cursor, 1) != ':' && substr(input, cursor, 1) != '=')) {
			offset = found + 6;
			continue;
		}
		cursor++;
		let end = cursor;
		while (end < length(input) && substr(input, end, 1) != '\n' &&
		       substr(input, end, 1) != '\r')
			end++;
		for (let pair in split(substr(input, cursor, end - cursor), ';')) {
			let separator = index(pair, '=');
			credential_add(catalog, trim(separator < 0 ? pair :
				substr(pair, separator + 1)));
			if (catalog.failed_closed)
				return;
		}
		offset = max(end + 1, cursor);
	}
};

function json_subscription_values(catalog, input) {
	let lowered = lc(input), marker = '"subscription"', offset = 0;
	while (offset < length(input) && !catalog.failed_closed) {
		let relative = index(substr(lowered, offset), marker);
		if (relative < 0)
			return;
		let found = offset + relative, cursor = found + length(marker);
		while (cursor < length(input) && match(substr(input, cursor, 1), /^[ \t]$/))
			cursor++;
		if (cursor >= length(input) || substr(input, cursor, 1) != ':') {
			offset = found + length(marker);
			continue;
		}
		cursor++;
		while (cursor < length(input) && match(substr(input, cursor, 1), /^[ \t]$/))
			cursor++;
		if (cursor >= length(input) ||
		    (substr(input, cursor, 1) != '"' && substr(input, cursor, 1) != "'")) {
			offset = cursor;
			continue;
		}
		let quote = substr(input, cursor++, 1), end = cursor;
		while (end < length(input) && substr(input, end, 1) != quote)
			end++;
		let spelling = substr(input, cursor, end - cursor);
		if (length(spelling) > MAX_TOKEN_LENGTH) {
			fail_closed(catalog);
			return;
		}
		let decoded = percent_decoded(spelling);
		if (decoded == null) {
			fail_closed(catalog);
			return;
		}
		if (!classify_token(catalog, decoded, spelling, true)) {
			let decoded64 = base64_decoded(spelling);
			if (decoded64 != null)
				classify_token(catalog, decoded64, spelling, true);
		}
		offset = max(end + 1, cursor);
	}
};

function discover_tokens(catalog, input, sensitive) {
	let normalized = replace(input, /[[:space:]\[\](),;'"<>]/g, ' ');
	let words = split(normalized, ' '), suffixes = [];
	for (let word in words) {
		let separator = index(word, '=');
		if (separator >= 0 && separator + 1 < length(word))
			push(suffixes, substr(word, separator + 1));
	}
	let groups = [ words, suffixes ];
	let tokens = 0;
	for (let words in groups) {
		for (let word in words)
			if (length(word) && ++tokens > MAX_DISCOVERY_TOKENS)
				return fail_closed(catalog);
		for (let word in words) {
			word = trim_token(word);
			if (!length(word))
				continue;
			if (length(word) > MAX_TOKEN_LENGTH)
				return fail_closed(catalog);
			classify_token(catalog, word, word, sensitive);
			if (catalog.failed_closed)
				return false;
			let decoded = percent_decoded(word);
			if (decoded == null)
				return fail_closed(catalog);
			if (decoded != word)
				classify_token(catalog, decoded, word, sensitive);
			if (catalog.failed_closed)
				return false;
			let decoded64 = base64_decoded(word);
			if (decoded64 != null)
				classify_token(catalog, decoded64, word, sensitive);
			if (catalog.failed_closed)
				return false;
		}
	}
	return true;
};

function discover_text(catalog, input, sensitive_urls) {
	if (type(input) != 'string' || length(input) > MAX_TEXT_INPUT)
		return fail_closed(catalog);
	assigned_values(catalog, input);
	for (let name in [ 'subscription', 'subscriptions', 'subscription_url' ])
		marked_url_values(catalog, input, name);
	for (let scheme in [ 'bearer', 'basic' ])
		scheme_secret_values(catalog, input, scheme);
	cookie_values(catalog, input);
	json_subscription_values(catalog, input);
	if (catalog.failed_closed)
		return false;
	return discover_tokens(catalog, input, sensitive_urls);
};

function discover_into(catalog, seed_values, base_path) {
	base_path = base_path ?? [];
	let initial_key = '';
	for (let offset = length(base_path) - 1; offset >= 0; offset--)
		if (type(base_path[offset]) == 'string') {
			initial_key = base_path[offset];
			break;
		}
	let stack = [ { value: seed_values, key: initial_key,
		path: base_path, depth: 0 } ];
	let nodes = 0, aggregate = 0;
	while (length(stack) && !catalog.failed_closed) {
		let item = pop(stack), kind = type(item.value);
		if (item.depth > MAX_VALUE_DEPTH || ++nodes > MAX_VALUE_NODES) {
			fail_closed(catalog);
			break;
		}
		if (kind == 'array')
			for (let index, value in item.value) {
				if (length(stack) >= MAX_VALUE_NODES) {
					fail_closed(catalog);
					break;
				}
				push(stack, { value, key: item.key,
					path: [ ...item.path, index ], depth: item.depth + 1 });
			}
		else if (kind == 'object')
			for (let key, value in item.value) {
				if (length(stack) >= MAX_VALUE_NODES) {
					fail_closed(catalog);
					break;
				}
				aggregate += length(key);
				if (aggregate > MAX_TEXT_INPUT || length(key) > MAX_TOKEN_LENGTH) {
					fail_closed(catalog);
					break;
				}
				push(stack, { value, key, path: [ ...item.path, key ],
					depth: item.depth + 1 });
			}
		else if (kind == 'string') {
			aggregate += length(item.value);
			if (aggregate > MAX_TEXT_INPUT || length(item.value) > MAX_TEXT_INPUT) {
				fail_closed(catalog);
				break;
			}
			let url = canonical_url(item.value);
			let typed = typed_kind(item.key);
			if (url != null)
				catalog_url(catalog, item.value, url,
					subscription_context(item.path) || sensitive_url(url));
			else if (typed != null) catalog_add(catalog, typed, item.value);
			else if (classified(item.key, item.value)) catalog_add(catalog, 'secret', item.value);
			discover_text(catalog, item.value, subscription_context(item.path));
		}
	}
	for (let name in [ 'secrets', 'urls', 'ips', 'hosts', 'devices', 'ids' ])
		sort(catalog[name], (left, right) => length(right) - length(left));
	return !catalog.failed_closed;
};

function discover(seed_values) {
	let catalog = {
		secrets: [], urls: [], sensitive_urls: [], url_aliases: [],
		ips: [], hosts: [], devices: [], ids: [],
		count: 0, bytes: 0, failed_closed: false
	};
	discover_into(catalog, seed_values, []);
	return catalog;
};

function replacement_work() {
	return { patterns: 0, matches: 0, variant_bytes: 0, failed: false };
};

function replace_all(input, wanted, replacement, work) {
	if (!length(wanted))
		return input;
	if (++work.patterns > MAX_REPLACEMENT_PATTERNS) {
		work.failed = true;
		return null;
	}
	let output = '', rest = input;
	while (true) {
		let position = index(rest, wanted);
		if (position < 0) {
			output += rest;
			if (length(output) > MAX_TEXT_INPUT) {
				work.failed = true;
				return null;
			}
			return output;
		}
		if (++work.matches > MAX_REPLACEMENT_MATCHES) {
			work.failed = true;
			return null;
		}
		output += substr(rest, 0, position) + replacement;
		if (length(output) > MAX_TEXT_INPUT) {
			work.failed = true;
			return null;
		}
		rest = substr(rest, position + length(wanted));
	}
};

function label(labels, kind, value) {
	let key = kind + '::' + value;
	if (labels[key] == null) {
		let count = 0;
		for (let existing in labels)
			if (substr(existing, 0, length(kind) + 2) == kind + '::') count++;
		labels[key] = '[' + kind + '-' + (count + 1) + ']';
	}
	return labels[key];
};

function encoded(value, all) {
	let output = '';
	for (let offset = 0; offset < length(value); offset++) {
		let character = substr(value, offset, 1);
		output += !all && match(character, /^[A-Za-z0-9_.~-]$/) ? character :
			sprintf('%%%02X', ord(value, offset));
	}
	return output;
};

function variant_add(variants, value, work) {
	if (type(value) != 'string' || !length(value) || contains(variants, value))
		return true;
	work.variant_bytes += length(value);
	if (work.variant_bytes > MAX_VARIANT_BYTES) {
		work.failed = true;
		return false;
	}
	push(variants, value);
	return true;
};

function replace_variants(input, values, labels, kind, replacement, work) {
	for (let value in values) {
		let output = replacement == null ? label(labels, kind, value) : replacement;
		let variants = [], partial = encoded(value, false), complete = encoded(value, true);
		for (let variant in [ value, partial, lc(partial), complete, lc(complete) ])
			if (!variant_add(variants, variant, work))
				return null;
		try {
			let base64 = b64enc(value), urlsafe = replace(replace(base64, /\+/g, '-'), /\//g, '_');
			for (let variant in [ base64, urlsafe, replace(base64, /=+$/, ''),
				replace(urlsafe, /=+$/, '') ])
				if (!variant_add(variants, variant, work))
					return null;
		}
		catch (error) {}
		for (let variant in variants) {
			input = replace_all(input, variant, output, work);
			if (input == null)
				return null;
		}
	}
	return input;
};

function replace_url_aliases(input, aliases, sensitive_urls, labels, mode, work) {
	for (let alias in aliases)
		if (mode == 'silent' || sensitive_url(alias.canonical) ||
		    contains(sensitive_urls, alias.canonical)) {
			input = replace_all(input, alias.spelling,
				mode == 'silent' ? label(labels, 'URL', alias.canonical) : MASK, work);
			if (input == null)
				return null;
		}
	return input;
};

function replace_urls(input, values, sensitive_urls, labels, mode, work) {
	for (let value in values)
		if (mode == 'silent' || sensitive_url(value) ||
		    contains(sensitive_urls, value)) {
			input = replace_variants(input, [ value ], labels, 'URL',
				mode == 'silent' ? null : MASK, work);
			if (input == null)
				return null;
		}
	return input;
};

function transform_text(mode, catalog, labels, path, value, shared_work) {
	if (type(value) != 'string' || mode == 'full') return value;
	if (catalog.failed_closed || length(value) > MAX_TEXT_INPUT) {
		fail_closed(catalog);
		return MASK;
	}
	if (!discover_text(catalog, value, subscription_context(path)))
		return MASK;
	for (let name in [ 'secrets', 'urls' ])
		sort(catalog[name], (left, right) => length(right) - length(left));
	let work = shared_work ?? replacement_work();
	value = replace_url_aliases(value, catalog.url_aliases, catalog.sensitive_urls,
		labels, mode, work);
	if (value == null) {
		fail_closed(catalog);
		return MASK;
	}
	value = replace_urls(value, catalog.urls, catalog.sensitive_urls, labels, mode, work);
	if (value == null) {
		fail_closed(catalog);
		return MASK;
	}
	value = replace_variants(value, catalog.secrets, labels, 'REDACTED', MASK, work);
	if (value == null) {
		fail_closed(catalog);
		return MASK;
	}
	if (mode == 'lite') {
		value = replace_variants(value, catalog.ips, labels, 'IP', MASK, work);
		if (value != null)
			value = replace_variants(value, catalog.devices, labels, 'DEVICE', MASK, work);
		if (value != null)
			value = replace_variants(value, catalog.ids, labels, 'ID', MASK, work);
	}
	else {
		value = replace_variants(value, catalog.ips, labels, 'IP', null, work);
		if (value != null)
			value = replace_variants(value, catalog.hosts, labels, 'HOST', null, work);
		if (value != null)
			value = replace_variants(value, catalog.devices, labels, 'DEVICE', null, work);
		if (value != null)
			value = replace_variants(value, catalog.ids, labels, 'ID', null, work);
	}
	if (value == null || work.failed || length(value) > MAX_TEXT_INPUT) {
		fail_closed(catalog);
		return MASK;
	}
	return value;
};

function lite_system_interface(path, key, value) {
	if (redact.normalized_key(key) != 'device' || type(value) != 'string' ||
	    length(value) < 1 || length(value) > 15 ||
	    !match(value, /^[A-Za-z0-9][A-Za-z0-9_.:-]*$/))
		return false;
	if (canonical_url(value) != null ||
	    match(value, /^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$/) ||
	    match(value, /^[0-9]{1,3}(\.[0-9]{1,3}){3}(\/[0-9]{1,2})?$/) ||
	    match(value, /^[0-9A-Fa-f:]+(:[0-9A-Fa-f:]+)+(\/[0-9]{1,3})?$/) ||
	    match(value, /^[A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z]{2,}$/))
		return false;
	let parent = length(path) ? redact.normalized_key(path[-1]) : '';
	return parent == 'route' || parent == 'routes' || parent == 'routing' ||
		parent == 'network' || parent == 'networks';
};

function transform(mode, catalog, labels, path, value, work) {
	if (mode == 'full') return value;
	if (type(value) == 'array') {
		let output = [];
		for (let item in value)
			push(output, transform(mode, catalog, labels, path, item, work));
		return output;
	}
	if (type(value) == 'object') {
		let output = {};
		for (let key, item in value) {
			let key_path = [ ...path, key ];
			let typed = typed_kind(key);
			let url = canonical_url(item);
			if (url != null) {
				let unsafe = subscription_context(key_path) || sensitive_url(url) ||
					classified(key, item) || typed == 'devices' || typed == 'ids';
				if (!catalog_url(catalog, item, url, unsafe))
					output[key] = MASK;
				else if (mode == 'silent')
					output[key] = label(labels, 'URL', url);
				else
					output[key] = unsafe ? MASK : item;
			}
			else if (typed != null) {
				if (mode == 'lite' && typed == 'devices' &&
				    lite_system_interface(path, key, item)) {
					output[key] = item;
				}
				else if (mode == 'silent' && type(item) == 'string') {
					let kind = typed == 'hosts' ? 'HOST' : typed == 'devices' ? 'DEVICE' : 'ID';
					output[key] = label(labels, kind, item);
				}
				else output[key] = MASK;
			}
			else if (classified(key, item)) {
				output[key] = MASK;
			}
			else output[key] = transform(mode, catalog, labels, key_path, item, work);
		}
		return output;
	}
	if (type(value) == 'string') {
		let url = canonical_url(value);
		if (url != null) {
			let unsafe = subscription_context(path) || sensitive_url(url);
			if (!catalog_url(catalog, value, url, unsafe))
				return MASK;
			if (mode == 'silent')
				return label(labels, 'URL', url);
			if (unsafe)
				return MASK;
		}
	}
	return transform_text(mode, catalog, labels, path, value, work);
};

export function create(mode, seed_values) {
	mode = enum_mode(mode);
	let catalog = discover(mode == 'full' ? [] : seed_values), labels = {};
	return {
		value: (path, value) => {
			if (mode == 'full')
				return value;
			if (!valid_path(path)) {
				fail_closed(catalog);
				return MASK;
			}
			if (catalog.failed_closed || !discover_into(catalog, value, path))
				return MASK;
			let work = replacement_work();
			let output = transform(mode, catalog, labels, path, value, work);
			return catalog.failed_closed || work.failed ? MASK : output;
		},
		text: (path, value) => {
			if (mode == 'full')
				return value;
			if (!valid_path(path)) {
				fail_closed(catalog);
				return MASK;
			}
			return transform_text(mode, catalog, labels, path, value);
		},
		metadata: () => ({ mode, contains_secrets: mode == 'full', sharing_safe: mode != 'full' })
	};
};
