import * as errors from 'miclash.errors';

const CONNECT_TIMEOUT_MS = 2000;
const REQUEST_TIMEOUT_MS = 5000;
const RESPONSE_LIMIT = 65536;
const MESSAGE_LIMIT = 4096;

function invalid() { errors.fail('INVALID_ARGUMENT'); };

function normalized_id(value) {
	let text = type(value) == 'int' ? sprintf('%d', value) : value;
	if (type(text) != 'string' || !match(text, /^[1-9][0-9]{0,19}$/)) invalid();
	return text;
};

function configuration(settings) {
	if (type(settings) != 'object' ||
	    type(settings.token) != 'string' ||
	    !match(settings.token, /^[1-9][0-9]{0,19}:[A-Za-z0-9_-]{8,128}$/))
		invalid();
	return { token: settings.token, user_id: normalized_id(settings.user_id) };
};

function percent_encode(value) {
	let output = '', source = sprintf('%s', value);
	for (let offset = 0; offset < length(source); offset++) {
		let character = substr(source, offset, 1);
		output += match(character, /^[A-Za-z0-9_.~-]$/) ? character :
			sprintf('%%%02X', ord(source, offset));
	}
	return output;
};

function query(fields) {
	let output = [];
	for (let name, value in fields) {
		if (!match(name, /^[a-z_]{1,32}$/) || value == null) invalid();
		let encoded;
		if (type(value) == 'object' || type(value) == 'array')
			encoded = sprintf('%J', value);
		else if (type(value) == 'string' || type(value) == 'int' || type(value) == 'bool')
			encoded = sprintf('%s', value);
		else invalid();
		push(output, percent_encode(name) + '=' + percent_encode(encoded));
	}
	return join('&', output);
};

function document(reply) {
	if (type(reply) != 'object' || type(reply.status) != 'int' ||
	    type(reply.body) != 'string' || length(reply.body) > RESPONSE_LIMIT)
		errors.fail('INVALID_RESPONSE');
	let value;
	try { value = json(reply.body); }
	catch (error) { errors.fail('INVALID_RESPONSE'); }
	if (type(value) != 'object' || type(value.ok) != 'bool')
		errors.fail('INVALID_RESPONSE');
	return value;
};

function retry_after(reply, value) {
	let seconds = value?.parameters?.retry_after;
	if (type(seconds) != 'int') {
		let header = reply?.headers?.['retry-after'];
		if (type(header) == 'string' && match(header, /^[0-9]+$/)) seconds = int(header);
	}
	if (type(seconds) != 'int' || seconds < 1) seconds = 1;
	return min(seconds, 3600) * 1000;
};

function has_forbidden_control(value, multiline) {
	for (let offset = 0; offset < length(value); offset++) {
		let byte = ord(value, offset);
		if (byte < 32 && !(multiline && (byte == 9 || byte == 10 || byte == 13)))
			return true;
	}
	return false;
};

function message_text(value) {
	if (type(value) != 'string' || !length(value) || length(value) > MESSAGE_LIMIT ||
	    has_forbidden_control(value, true)) invalid();
	return value;
};

function message_id(value) {
	if (type(value) != 'int' || value < 1) invalid();
	return value;
};

function markup(value) {
	if (value == null) return null;
	if (type(value) != 'object' || type(value) == 'array') invalid();
	let encoded = sprintf('%J', value);
	if (length(encoded) > 8192) invalid();
	return value;
};

export function create(app) {
	if (type(app) != 'object' || type(app.runtime) != 'object' ||
	    type(app.http?.request) != 'function') invalid();

	function call(settings, method, fields) {
		let safe = configuration(settings), response;
		try {
			response = app.http.request(app.runtime, {
				url: 'https://api.telegram.org/bot' + safe.token + '/' + method + '?' + query(fields),
				connect_timeout_ms: CONNECT_TIMEOUT_MS, timeout_ms: REQUEST_TIMEOUT_MS,
				max_redirects: 0, max_bytes: RESPONSE_LIMIT, managed: true,
				accept_statuses: [ 429 ]
			});
		}
		catch (error) { errors.fail('DOWNLOAD_FAILED'); }
		let parsed = document(response);
		if (response.status == 429)
			return { limited: true, retry_after_ms: retry_after(response, parsed) };
		if (response.status < 200 || response.status >= 300 || parsed.ok !== true)
			errors.fail('INVALID_RESPONSE');
		return { limited: false, document: parsed };
	};

	function message_fields(settings, chat, text, reply_markup) {
		configuration(settings);
		let fields = {
			chat_id: normalized_id(chat), text: message_text(text),
			disable_web_page_preview: true
		};
		let validated = markup(reply_markup);
		if (validated != null) fields.reply_markup = validated;
		return fields;
	};

	return {
		poll: (settings, offset) => {
			if (type(offset) != 'int' || offset < -1) invalid();
			let reply = call(settings, 'getUpdates', {
				offset: offset + 1, timeout: 0,
				limit: 20,
				allowed_updates: [ 'message', 'callback_query' ]
			});
			if (reply.limited) return { updates: [], retry_after_ms: reply.retry_after_ms };
			let updates = reply.document.result;
			if (type(updates) != 'array' || length(updates) > 100)
				errors.fail('INVALID_RESPONSE');
			for (let update in updates)
				if (type(update) != 'object' || type(update.update_id) != 'int' || update.update_id < 0)
					errors.fail('INVALID_RESPONSE');
			return { updates, retry_after_ms: 0 };
		},
		send: (settings, chat, text, reply_markup) => {
			let reply = call(settings, 'sendMessage',
				message_fields(settings, chat, text, reply_markup));
			if (reply.limited) return null;
			let result = reply.document.result;
			if (type(result) != 'object' || type(result.message_id) != 'int' || result.message_id < 1)
				errors.fail('INVALID_RESPONSE');
			return result;
		},
		edit: (settings, chat, id, text, reply_markup) => {
			let fields = message_fields(settings, chat, text, reply_markup);
			fields.message_id = message_id(id);
			let reply = call(settings, 'editMessageText', fields);
			if (reply.limited) return null;
			let result = reply.document.result;
			if (type(result) != 'object' || type(result.message_id) != 'int' || result.message_id < 1)
				errors.fail('INVALID_RESPONSE');
			return result;
		},
		answer: (settings, callback_id, text) => {
			if (type(callback_id) != 'string' || !length(callback_id) ||
			    length(callback_id) > 128 || has_forbidden_control(callback_id, false)) invalid();
			if (type(text) != 'string' || length(text) > 200 || has_forbidden_control(text, true)) invalid();
			let reply = call(settings, 'answerCallbackQuery', {
				callback_query_id: callback_id, text
			});
			if (reply.limited) return { ok: false, retry_after_ms: reply.retry_after_ms };
			if (reply.document.result !== true) errors.fail('INVALID_RESPONSE');
			return reply.document;
		},
		delete: (settings, chat, id) => {
			let reply = call(settings, 'deleteMessage', {
				chat_id: normalized_id(chat), message_id: message_id(id)
			});
			if (reply.limited) return false;
			if (reply.document.result !== true) errors.fail('INVALID_RESPONSE');
			return true;
		},
		set_commands: (settings, language, commands) => {
			if (language != '' && language != 'ru' && language != 'zh') invalid();
			if (type(commands) != 'array' || !length(commands) || length(commands) > 100) invalid();
			for (let command in commands)
				if (type(command) != 'object' || !match(command.command, /^[a-z0-9_]{1,32}$/) ||
				    type(command.description) != 'string' || !length(command.description) ||
				    length(command.description) > 256)
					invalid();
			let fields = { commands };
			if (length(language)) fields.language_code = language;
			let reply = call(settings, 'setMyCommands', fields);
			if (reply.limited) return false;
			if (reply.document.result !== true) errors.fail('INVALID_RESPONSE');
			return true;
		}
	};
};
