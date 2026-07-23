import * as redact from 'miclash.redact';

const MASK = '[REDACTED]';

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

function add(values, value) {
	if (type(value) == 'string' && length(value) && !contains(values, value))
		push(values, value);
};

function trim_token(value) {
	while (length(value) && match(substr(value, 0, 1), /^[\[\](),;:'"<>]$/))
		value = substr(value, 1);
	while (length(value) && match(substr(value, -1), /^[\[\](),;:'"<>.!?]$/))
		value = substr(value, 0, length(value) - 1);
	return value;
};

function typed_kind(key) {
	let normalized = redact.normalized_key(key);
	if (match(normalized, /(^|_)(hostname|host_name)($|_)/)) return 'hosts';
	if (match(normalized, /(^|_)(device|ssid|mac)($|_)/)) return 'devices';
	if (match(normalized, /(^|_)(uuid|user_id|chat_id|telegram_id)($|_)/)) return 'ids';
	return null;
};

function classified(key, value) {
	return typed_kind(key) == null &&
		(redact.secret_name(key) || match(value, /^[0-9]{5,}:[^[:space:]]+$/));
};

function add_variant(values, value) {
	add(values, value);
	let percent = '';
	for (let offset = 0; offset < length(value); offset++)
		percent += sprintf('%%%02X', ord(value, offset));
	add(values, percent);
	try {
		let base64 = b64enc(value);
		add(values, base64);
		let urlsafe = replace(replace(base64, /\+/g, '-'), /\//g, '_');
		add(values, urlsafe);
		add(values, replace(base64, /=+$/, ''));
		add(values, replace(urlsafe, /=+$/, ''));
	}
	catch (error) {}
};

function catalog_add(catalog, kind, value) {
	value = trim_token(value);
	if (!length(value))
		return;
	if (kind == 'secret')
		add_variant(catalog.secrets, value);
	else
		add(catalog[kind], value);
};

function percent_decoded(input) {
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

function classify_token(catalog, token) {
	token = trim_token(token);
	if (match(token, /^https?:\/\/[^[:space:]]+$/)) catalog_add(catalog, 'urls', token);
	else if (match(token, /^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$/)) catalog_add(catalog, 'devices', token);
	else if (match(token, /^[0-9]{1,3}(\.[0-9]{1,3}){3}(\/[0-9]{1,2})?$/) ||
	         match(token, /^[0-9A-Fa-f:]+(:[0-9A-Fa-f:]+)+(\/[0-9]{1,3})?$/)) catalog_add(catalog, 'ips', token);
	else if (match(token, /^[0-9a-fA-F]{8}-[0-9a-fA-F-]{27}$/)) catalog_add(catalog, 'ids', token);
	else if (match(token, /^[A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z]{2,}$/)) catalog_add(catalog, 'hosts', token);
};

function marker_values(catalog, input, marker, kind) {
	let offset = 0, lowered = lc(input), wanted = lc(marker) + '=';
	while (offset < length(input)) {
		let relative = index(substr(lowered, offset), wanted);
		if (relative < 0) return;
		let start = offset + relative + length(wanted), end = length(input);
		for (let cursor = start; cursor < length(input); cursor++) {
			if (!match(substr(input, cursor, 1), /^[[:space:]]$/)) continue;
			let next = cursor + 1;
			while (next < length(input) && match(substr(input, next, 1), /^[[:space:]]$/)) next++;
			let equals = index(substr(input, next), '=');
			let space = index(substr(input, next), ' ');
			if (equals >= 0 && (space < 0 || equals < space)) {
				end = cursor;
				break;
			}
		}
		catalog_add(catalog, kind, substr(input, start, end - start));
		offset = max(end + 1, start);
	}
};

function discover_text(catalog, input) {
	for (let name in [ 'token', 'secret', 'password', 'cookie', 'authorization', 'bearer' ])
		marker_values(catalog, input, name, 'secret');
	for (let name in [ 'device', 'device_name', 'ssid', 'hostname' ])
		marker_values(catalog, input, name, 'devices');
	for (let name in [ 'uuid', 'id', 'user_id', 'chat_id' ])
		marker_values(catalog, input, name, 'ids');
	for (let word in split(replace(input, /[[:space:]]/g, ' '), ' '))
		classify_token(catalog, word);
	let words = split(replace(input, /[[:space:],;=]/g, ' '), ' ');
	for (let word in words) {
		classify_token(catalog, word);
		let decoded = percent_decoded(word);
		if (decoded != word) classify_token(catalog, decoded);
		try {
			let base64 = replace(replace(word, /-/g, '+'), /_/g, '/');
			let padding = length(base64) % 4;
			if (padding) base64 += padding == 2 ? '==' : '=';
			let decoded64 = b64dec(base64);
			if (decoded64 != null) classify_token(catalog, decoded64);
		}
		catch (error) {}
	}
};

function discover(seed_values) {
	let catalog = { secrets: [], urls: [], ips: [], hosts: [], devices: [], ids: [] };
	let stack = [ { value: seed_values, key: '' } ];
	while (length(stack)) {
		let item = pop(stack), kind = type(item.value);
		if (kind == 'array')
			for (let value in item.value) push(stack, { value, key: item.key });
		else if (kind == 'object')
			for (let key, value in item.value) push(stack, { value, key });
		else if (kind == 'string') {
			let typed = typed_kind(item.key);
			if (typed != null) catalog_add(catalog, typed, item.value);
			else if (classified(item.key, item.value)) catalog_add(catalog, 'secret', item.value);
			discover_text(catalog, item.value);
		}
	}
	for (let name in [ 'secrets', 'urls', 'ips', 'hosts', 'devices', 'ids' ])
		sort(catalog[name], (left, right) => length(right) - length(left));
	return catalog;
};

function replace_all(input, wanted, replacement) {
	let output = '', rest = input;
	while (length(wanted)) {
		let position = index(rest, wanted);
		if (position < 0) return output + rest;
		output += substr(rest, 0, position) + replacement;
		rest = substr(rest, position + length(wanted));
	}
	return input;
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

function replace_catalog(input, values, labels, kind, replacement) {
	for (let value in values)
		input = replace_all(input, value, replacement == null ? label(labels, kind, value) : replacement);
	return input;
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

function replace_variants(input, values, labels, kind, replacement) {
	for (let value in values) {
		let output = replacement == null ? label(labels, kind, value) : replacement;
		input = replace_all(input, value, output);
		input = replace_all(input, encoded(value, false), output);
		input = replace_all(input, lc(encoded(value, false)), output);
		input = replace_all(input, encoded(value, true), output);
		input = replace_all(input, lc(encoded(value, true)), output);
		try {
			let base64 = b64enc(value), urlsafe = replace(replace(base64, /\+/g, '-'), /\//g, '_');
			input = replace_all(input, base64, output);
			input = replace_all(input, urlsafe, output);
			input = replace_all(input, replace(base64, /=+$/, ''), output);
			input = replace_all(input, replace(urlsafe, /=+$/, ''), output);
		}
		catch (error) {}
	}
	return input;
};

function subscription_url(value) {
	return index(lc(value), 'token=') >= 0 || index(lc(value), 'subscribe') >= 0 ||
		index(lc(value), 'subscription') >= 0 || match(value, /^https?:\/\/[^\/@]+:[^\/@]+@/);
};

function replace_urls(input, values, labels, mode) {
	for (let value in values)
		if (mode == 'silent' || subscription_url(value))
			input = replace_variants(input, [ value ], labels, 'URL',
				mode == 'silent' ? null : MASK);
	return input;
};

function transform_text(mode, catalog, labels, value) {
	if (type(value) != 'string' || mode == 'full') return value;
	discover_text(catalog, value);
	value = replace_urls(value, catalog.urls, labels, mode);
	value = replace_variants(value, catalog.secrets, labels, 'REDACTED', MASK);
	if (mode == 'lite') {
		value = replace_variants(value, catalog.ips, labels, 'IP', MASK);
		value = replace_variants(value, catalog.devices, labels, 'DEVICE', MASK);
		return replace_variants(value, catalog.ids, labels, 'ID', MASK);
	}
	value = replace_variants(value, catalog.ips, labels, 'IP');
	value = replace_variants(value, catalog.hosts, labels, 'HOST');
	value = replace_variants(value, catalog.devices, labels, 'DEVICE');
	return replace_variants(value, catalog.ids, labels, 'ID');
};

function transform(mode, catalog, labels, path, value) {
	if (mode == 'full') return value;
	if (type(value) == 'array') {
		let output = [];
		for (let item in value) push(output, transform(mode, catalog, labels, path, item));
		return output;
	}
	if (type(value) == 'object') {
		let output = {};
		for (let key, item in value) {
			let key_path = [ ...path, key ];
			let typed = typed_kind(key);
			if (typed != null) {
				if (mode == 'silent' && type(item) == 'string') {
					let kind = typed == 'hosts' ? 'HOST' : typed == 'devices' ? 'DEVICE' : 'ID';
					output[key] = label(labels, kind, item);
				}
				else output[key] = MASK;
			}
			else if (classified(key, item)) {
				if (mode == 'silent' && type(item) == 'string') {
					output[key] = MASK;
				}
				else output[key] = MASK;
			}
			else output[key] = transform(mode, catalog, labels, key_path, item);
		}
		return output;
	}
	return transform_text(mode, catalog, labels, value);
};

export function create(mode, seed_values) {
	mode = enum_mode(mode);
	let catalog = discover(seed_values), labels = {};
	return {
		value: (path, value) => transform(mode, catalog, labels, path, value),
		text: (path, value) => transform_text(mode, catalog, labels, value),
		metadata: () => ({ mode, contains_secrets: mode == 'full', sharing_safe: mode != 'full' })
	};
};
