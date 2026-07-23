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

function classified(key, value) {
	let normalized = redact.normalized_key(key);
	if (redact.secret_name(key) || match(normalized, /(^|_)(device|hostname|host_name|ssid|uuid|user_id|chat_id|telegram_id|mac)($|_)/))
		return true;
	return match(value, /^[0-9]{5,}:[^[:space:]]+$/);
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

function classify_token(catalog, token) {
	token = trim_token(token);
	if (match(token, /^https?:\/\/[^[:space:]]+$/)) catalog_add(catalog, 'urls', token);
	else if (match(token, /^[0-9]{1,3}(\.[0-9]{1,3}){3}(\/[0-9]{1,2})?$/) ||
	         match(token, /^[0-9A-Fa-f:]+(:[0-9A-Fa-f:]+)+(\/[0-9]{1,3})?$/)) catalog_add(catalog, 'ips', token);
	else if (match(token, /^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$/)) catalog_add(catalog, 'devices', token);
	else if (match(token, /^[0-9a-fA-F]{8}-[0-9a-fA-F-]{27}$/)) catalog_add(catalog, 'ids', token);
	else if (match(token, /^[A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z]{2,}$/)) catalog_add(catalog, 'hosts', token);
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
			if (classified(item.key, item.value)) catalog_add(catalog, 'secret', item.value);
			let words = split(replace(item.value, /[[:space:],;=]/g, ' '), ' ');
			for (let word in words) classify_token(catalog, word);
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
	let key = kind + '\u0000' + value;
	if (labels[key] == null) {
		let count = 0;
		for (let existing in labels)
			if (substr(existing, 0, length(kind) + 1) == kind + '\u0000') count++;
		labels[key] = '[' + kind + '-' + (count + 1) + ']';
	}
	return labels[key];
};

function replace_catalog(input, values, labels, kind, replacement) {
	for (let value in values)
		input = replace_all(input, value, replacement == null ? label(labels, kind, value) : replacement);
	return input;
};

function transform_text(mode, catalog, labels, value) {
	if (type(value) != 'string' || mode == 'full') return value;
	value = replace_catalog(value, catalog.secrets, labels, 'REDACTED', MASK);
	if (mode == 'lite') {
		value = replace_catalog(value, catalog.urls, labels, 'URL', MASK);
		value = replace_catalog(value, catalog.ips, labels, 'IP', MASK);
		value = replace_catalog(value, catalog.devices, labels, 'DEVICE', MASK);
		return replace_catalog(value, catalog.ids, labels, 'ID', MASK);
	}
	value = replace_catalog(value, catalog.urls, labels, 'URL');
	value = replace_catalog(value, catalog.ips, labels, 'IP');
	value = replace_catalog(value, catalog.hosts, labels, 'HOST');
	value = replace_catalog(value, catalog.devices, labels, 'DEVICE');
	return replace_catalog(value, catalog.ids, labels, 'ID');
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
			if (classified(key, item)) {
				if (mode == 'silent' && type(item) == 'string') {
					let kind = match(redact.normalized_key(key), /device|ssid|mac|host/) ? 'DEVICE' :
						match(redact.normalized_key(key), /id|uuid/) ? 'ID' : 'REDACTED';
					output[key] = kind == 'REDACTED' ? MASK : label(labels, kind, item);
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
