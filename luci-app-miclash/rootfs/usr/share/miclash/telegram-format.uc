const MAX_MESSAGE_TEXT = 4096;

function indentation(depth) {
	let output = '';
	for (let index = 0; index < depth; index++) output += '  ';
	return output;
};

export function pretty_json(value) {
	let source = sprintf('%J', value), output = '', depth = 0;
	let quoted = false, escaped = false;
	for (let index = 0; index < length(source); index++) {
		let character = substr(source, index, 1), next = substr(source, index + 1, 1);
		if (quoted) {
			output += character;
			if (escaped) escaped = false;
			else if (character == '\\') escaped = true;
			else if (character == '"') quoted = false;
			continue;
		}
		if (character == ' ' || character == '\t' || character == '\r' || character == '\n')
			continue;
		if (character == '"') { quoted = true; output += character; }
		else if (character == '{' || character == '[') {
			output += character;
			if (next != '}' && next != ']') {
				depth++;
				output += '\n' + indentation(depth);
			}
		}
		else if (character == '}' || character == ']') {
			if (substr(source, index - 1, 1) == '{' || substr(source, index - 1, 1) == '[')
				output += character;
			else {
				depth--;
				output += '\n' + indentation(depth) + character;
			}
		}
		else if (character == ',') output += ',\n' + indentation(depth);
		else if (character == ':') output += ': ';
		else output += character;
	}
	return output;
};

export function fenced_code(value, language) {
	let source = type(value) == 'string' ? value : sprintf('%J', value);
	let output = '```' + (language ?? '') + '\n';
	for (let index = 0; index < length(source) && length(output) < MAX_MESSAGE_TEXT - 16; index++) {
		let character = substr(source, index, 1);
		if (character == '`' || character == '\\') output += '\\';
		output += character;
	}
	if (length(output) < length(source) + 4) output += '\n[truncated]';
	return output + '\n```';
};
