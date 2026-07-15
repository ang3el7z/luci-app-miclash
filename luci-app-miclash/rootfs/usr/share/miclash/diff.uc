import * as errors from 'miclash.errors';

const DEFAULT_LIMITS = {
	max_input_bytes: 262144,
	max_output_bytes: 131072,
	max_lines: 20000,
	max_hunks: 64,
	context_lines: 3
};
const LIMIT_FIELDS = {
	max_input_bytes: true,
	max_output_bytes: true,
	max_lines: true,
	max_hunks: true,
	context_lines: true
};

function invalid() {
	errors.fail('INVALID_ARGUMENT');
};

function continuation(value) {
	return value >= 0x80 && value <= 0xbf;
};

function valid_text(value) {
	if (type(value) != 'string')
		return false;
	for (let offset = 0; offset < length(value);) {
		let first = ord(value, offset);
		if (first <= 0x7f) {
			if (first == 0 || first < 0x20 && first != 0x09 && first != 0x0a && first != 0x0d ||
			    first == 0x7f)
				return false;
			offset++;
			continue;
		}
		if (first >= 0xc2 && first <= 0xdf) {
			if (offset + 1 >= length(value) || !continuation(ord(value, offset + 1)))
				return false;
			offset += 2;
			continue;
		}
		if (first >= 0xe0 && first <= 0xef) {
			if (offset + 2 >= length(value))
				return false;
			let second = ord(value, offset + 1);
			let third = ord(value, offset + 2);
			if (!continuation(third) ||
			    first == 0xe0 && (second < 0xa0 || second > 0xbf) ||
			    first == 0xed && (second < 0x80 || second > 0x9f) ||
			    first != 0xe0 && first != 0xed && !continuation(second))
				return false;
			offset += 3;
			continue;
		}
		if (first >= 0xf0 && first <= 0xf4) {
			if (offset + 3 >= length(value))
				return false;
			let second = ord(value, offset + 1);
			if (first == 0xf0 && (second < 0x90 || second > 0xbf) ||
			    first == 0xf4 && (second < 0x80 || second > 0x8f) ||
			    first != 0xf0 && first != 0xf4 && !continuation(second) ||
			    !continuation(ord(value, offset + 2)) ||
			    !continuation(ord(value, offset + 3)))
				return false;
			offset += 4;
			continue;
		}
		return false;
	}
	return true;
};

function limits(value) {
	if (value == null)
		return { ...DEFAULT_LIMITS };
	if (type(value) != 'object')
		invalid();
	let count = 0;
	for (let name in value) {
		if (!exists(LIMIT_FIELDS, name))
			invalid();
		count++;
	}
	if (count != 5)
		invalid();
	for (let name in LIMIT_FIELDS)
		if (type(value[name]) != 'int')
			invalid();
	if (value.max_input_bytes < 1 || value.max_input_bytes > 1048576 ||
	    value.max_output_bytes < 1 || value.max_output_bytes > 1048576 ||
	    value.max_lines < 1 || value.max_lines > 50000 ||
	    value.max_hunks < 1 || value.max_hunks > 256 ||
	    value.context_lines < 0 || value.context_lines > 16)
		invalid();
	return { ...value };
};

function lines(value) {
	let parts = split(value, '\n');
	let output = [];
	for (let index = 0; index < length(parts); index++) {
		if (index == length(parts) - 1 && parts[index] == '' &&
		    length(value) && substr(value, length(value) - 1) == '\n')
			continue;
		push(output, {
			text: parts[index],
			newline: index < length(parts) - 1
		});
	}
	if (!length(value))
		output = [];
	return output;
};

function same_line(left, right) {
	return left?.text == right?.text && left?.newline == right?.newline;
};

function append(output, marker, values, from, until) {
	for (let index = from; index < until; index++) {
		output += marker + values[index].text + '\n';
		if (!values[index].newline)
			output += '\\ No newline at end of file\n';
	}
	return output;
};

export function unified(old, next, requested_limits) {
	let bounded = limits(requested_limits);
	if (!valid_text(old) || !valid_text(next))
		invalid();
	if (length(old) > bounded.max_input_bytes || length(next) > bounded.max_input_bytes)
		errors.fail('RESPONSE_TOO_LARGE');
	let before = lines(old);
	let after = lines(next);
	if (length(before) > bounded.max_lines || length(after) > bounded.max_lines)
		errors.fail('RESPONSE_TOO_LARGE');
	if (old == next)
		return { changed: false, hunks: 0, text: '' };

	let prefix = 0;
	while (prefix < length(before) && prefix < length(after) &&
	       same_line(before[prefix], after[prefix]))
		prefix++;
	let suffix = 0;
	while (suffix < length(before) - prefix && suffix < length(after) - prefix &&
	       same_line(before[length(before) - suffix - 1],
		       after[length(after) - suffix - 1]))
		suffix++;
	let start = prefix - bounded.context_lines;
	if (start < 0)
		start = 0;
	let before_end = length(before) - suffix + bounded.context_lines;
	let after_end = length(after) - suffix + bounded.context_lines;
	if (before_end > length(before))
		before_end = length(before);
	if (after_end > length(after))
		after_end = length(after);
	let before_count = before_end - start;
	let after_count = after_end - start;
	let output = '--- old\n+++ next\n' + sprintf('@@ -%d,%d +%d,%d @@\n',
		start + 1, before_count, start + 1, after_count);
	output = append(output, ' ', before, start, prefix);
	output = append(output, '-', before, prefix, length(before) - suffix);
	output = append(output, '+', after, prefix, length(after) - suffix);
	output = append(output, ' ', before, length(before) - suffix,
		before_end);
	if (length(output) > bounded.max_output_bytes)
		errors.fail('RESPONSE_TOO_LARGE');
	return { changed: true, hunks: 1, text: output };
};
