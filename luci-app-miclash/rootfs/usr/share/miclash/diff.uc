import * as errors from 'miclash.errors';

const DEFAULT_LIMITS = {
	max_input_bytes: 262144,
	max_output_bytes: 131072,
	max_lines: 20000,
	max_hunks: 64,
	context_lines: 3,
	max_cells: 250000
};
const LIMIT_FIELDS = {
	max_input_bytes: true,
	max_output_bytes: true,
	max_lines: true,
	max_hunks: true,
	context_lines: true,
	max_cells: true
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
	if (count != 6)
		invalid();
	for (let name in LIMIT_FIELDS)
		if (type(value[name]) != 'int')
			invalid();
	if (value.max_input_bytes < 1 || value.max_input_bytes > 1048576 ||
	    value.max_output_bytes < 1 || value.max_output_bytes > 1048576 ||
	    value.max_lines < 1 || value.max_lines > 50000 ||
	    value.max_hunks < 1 || value.max_hunks > 256 ||
	    value.context_lines < 0 || value.context_lines > 16 ||
	    value.max_cells < 1 || value.max_cells > 1000000)
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
		push(output, { text: parts[index], newline: index < length(parts) - 1 });
	}
	return length(value) ? output : [];
};

function same_line(left, right) {
	return left?.text == right?.text && left?.newline == right?.newline;
};

function operation(output, kind, line) {
	push(output, { kind, line, old_before: 0, next_before: 0 });
};

function edit_script(before, after, maximum_cells) {
	let prefix = 0;
	while (prefix < length(before) && prefix < length(after) &&
	       same_line(before[prefix], after[prefix]))
		prefix++;
	let suffix = 0;
	while (suffix < length(before) - prefix && suffix < length(after) - prefix &&
	       same_line(before[length(before) - suffix - 1],
		       after[length(after) - suffix - 1]))
		suffix++;
	let old_count = length(before) - prefix - suffix;
	let next_count = length(after) - prefix - suffix;
	let cells = (old_count + 1) * (next_count + 1);
	if (cells > maximum_cells)
		errors.fail('RESPONSE_TOO_LARGE');
	let matrix = [];
	for (let old_index = 0; old_index <= old_count; old_index++) {
		let row = [];
		for (let next_index = 0; next_index <= next_count; next_index++)
			push(row, 0);
		push(matrix, row);
	}
	for (let old_index = old_count - 1; old_index >= 0; old_index--)
		for (let next_index = next_count - 1; next_index >= 0; next_index--)
			if (same_line(before[prefix + old_index], after[prefix + next_index]))
				matrix[old_index][next_index] = matrix[old_index + 1][next_index + 1] + 1;
			else
				matrix[old_index][next_index] =
					matrix[old_index + 1][next_index] >= matrix[old_index][next_index + 1] ?
					matrix[old_index + 1][next_index] : matrix[old_index][next_index + 1];

	let output = [];
	for (let index = 0; index < prefix; index++)
		operation(output, ' ', before[index]);
	let old_index = 0;
	let next_index = 0;
	while (old_index < old_count || next_index < next_count) {
		if (old_index < old_count && next_index < next_count &&
		    same_line(before[prefix + old_index], after[prefix + next_index])) {
			operation(output, ' ', before[prefix + old_index]);
			old_index++;
			next_index++;
		}
		else if (old_index < old_count &&
		         (next_index == next_count ||
		          matrix[old_index + 1][next_index] >= matrix[old_index][next_index + 1])) {
			operation(output, '-', before[prefix + old_index]);
			old_index++;
		}
		else {
			operation(output, '+', after[prefix + next_index]);
			next_index++;
		}
	}
	for (let index = length(before) - suffix; index < length(before); index++)
		operation(output, ' ', before[index]);
	let old_seen = 0;
	let next_seen = 0;
	for (let item in output) {
		item.old_before = old_seen;
		item.next_before = next_seen;
		if (item.kind != '+')
			old_seen++;
		if (item.kind != '-')
			next_seen++;
	}
	return output;
};

function regions(operations, context, maximum_hunks) {
	let output = [];
	for (let index = 0; index < length(operations); index++) {
		if (operations[index].kind == ' ')
			continue;
		let start = index - context;
		if (start < 0)
			start = 0;
		let end = index + context + 1;
		if (end > length(operations))
			end = length(operations);
		let last = length(output) ? output[length(output) - 1] : null;
		if (last != null && start <= last.end) {
			if (end > last.end)
				last.end = end;
		}
		else
			push(output, { start, end });
	}
	if (length(output) > maximum_hunks)
		errors.fail('RESPONSE_TOO_LARGE');
	return output;
};

function emit(state, value, maximum) {
	state.text += value;
	if (length(state.text) > maximum)
		errors.fail('RESPONSE_TOO_LARGE');
};

function emit_line(state, item, maximum) {
	emit(state, item.kind + item.line.text + '\n', maximum);
	if (!item.line.newline)
		emit(state, '\\ No newline at end of file\n', maximum);
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
	let operations = edit_script(before, after, bounded.max_cells);
	let hunks = regions(operations, bounded.context_lines, bounded.max_hunks);
	let state = { text: '' };
	emit(state, '--- old\n+++ next\n', bounded.max_output_bytes);
	for (let region in hunks) {
		let old_count = 0;
		let next_count = 0;
		for (let index = region.start; index < region.end; index++) {
			if (operations[index].kind != '+')
				old_count++;
			if (operations[index].kind != '-')
				next_count++;
		}
		let first = operations[region.start];
		let old_start = old_count ? first.old_before + 1 : first.old_before;
		let next_start = next_count ? first.next_before + 1 : first.next_before;
		emit(state, sprintf('@@ -%d,%d +%d,%d @@\n',
			old_start, old_count, next_start, next_count), bounded.max_output_bytes);
		for (let index = region.start; index < region.end; index++)
			emit_line(state, operations[index], bounded.max_output_bytes);
	}
	return { changed: true, hunks: length(hunks), text: state.text };
};
