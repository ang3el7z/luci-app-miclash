import * as errors from 'miclash.errors';

const CONNECT_TIMEOUT_MS = 2000;
const REQUEST_TIMEOUT_MS = 5000;
const RESPONSE_LIMIT = 65536;
const MESSAGE_LIMIT = 4096;
const DOCUMENT_FILE_LIMIT = 16777216;

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

function document_file(value) {
	if (type(value) != 'object' || type(value) == 'array' ||
	    length(keys(value)) != 6 ||
	    type(value.identity) != 'object' || type(value.identity) == 'array' ||
	    type(value.size) != 'int' || value.size < 1 || value.size > DOCUMENT_FILE_LIMIT ||
	    type(value.sha256) != 'string' || !match(value.sha256, /^[0-9a-f]{64}$/) ||
	    type(value.read) != 'function' || type(value.finish) != 'function' ||
	    type(value.close) != 'function')
		invalid();
	return value;
};

function document_filename(value) {
	if (type(value) != 'string' ||
	    !match(value, /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/))
		invalid();
	return value;
};

function document_caption(value) {
	if (value == null) return null;
	if (type(value) != 'string' || !length(value) || length(value) > 1024 ||
	    has_forbidden_control(value, true))
		invalid();
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

	function call_plan(settings, method, fields, post, timeout_ms) {
		let safe = configuration(settings), encoded = query(fields);
		let request = {
			url: 'https://api.telegram.org/bot' + safe.token + '/' + method +
				(post ? '' : '?' + encoded),
			connect_timeout_ms: CONNECT_TIMEOUT_MS, timeout_ms: timeout_ms ?? REQUEST_TIMEOUT_MS,
			max_redirects: 0, max_bytes: RESPONSE_LIMIT, managed: true,
			accept_statuses: [ 429 ]
		};
		if (post) {
			request.method = 'POST';
			request.body = encoded;
			request.headers = { 'Content-Type': 'application/x-www-form-urlencoded' };
		}
		return {
			request,
			complete: (response) => {
				let parsed = document(response);
				if (response.status == 429)
					return { limited: true, retry_after_ms: retry_after(response, parsed) };
				if (response.status < 200 || response.status >= 300 || parsed.ok !== true)
					errors.fail('INVALID_RESPONSE');
				return { limited: false, document: parsed };
			}
		};
	};

	function call(settings, method, fields, post, timeout_ms) {
		let plan = call_plan(settings, method, fields, post, timeout_ms), response;
		try { response = app.http.request(app.runtime, plan.request); }
		catch (error) { errors.fail('DOWNLOAD_FAILED'); }
		return plan.complete(response);
	};

	function document_plan(settings, chat, file, filename, caption, content_type) {
		let safe = configuration(settings), descriptor = document_file(file);
		content_type ??= 'application/json';
		if (content_type != 'application/json' && content_type != 'text/plain')
			invalid();
		let fields = { chat_id: normalized_id(chat) };
		let safe_caption = document_caption(caption);
		if (safe_caption != null) fields.caption = safe_caption;
		let request = {
			url: 'https://api.telegram.org/bot' + safe.token + '/sendDocument',
			connect_timeout_ms: CONNECT_TIMEOUT_MS, timeout_ms: 30000,
			max_redirects: 0, max_bytes: RESPONSE_LIMIT, managed: true,
			accept_statuses: [ 429 ], method: 'POST',
			body_file: {
				identity: descriptor.identity,
				size: descriptor.size,
				sha256: descriptor.sha256,
				read: descriptor.read,
				finish: descriptor.finish,
				close: descriptor.close,
				field: 'document',
				filename: document_filename(filename),
				content_type,
				fields
			}
		};
		return {
			request,
			complete: (response) => {
				let parsed = document(response);
				if (response.status == 429)
					return { limited: true, retry_after_ms: retry_after(response, parsed) };
				if (response.status < 200 || response.status >= 300 || parsed.ok !== true)
					errors.fail('INVALID_RESPONSE');
				let result = parsed.result;
				if (type(result) != 'object' || type(result.message_id) != 'int' ||
				    result.message_id < 1)
					errors.fail('INVALID_RESPONSE');
				return { limited: false, result };
			}
		};
	};

	function poll_plan(settings, offset, poll_timeout_seconds) {
		if (type(offset) != 'int' || offset < -1) invalid();
		let timeout = poll_timeout_seconds ?? 25;
		if (type(timeout) != 'int' || timeout < 5 || timeout > 50) invalid();
		let plan = call_plan(settings, 'getUpdates', {
			offset: offset + 1, timeout,
			limit: 20,
			allowed_updates: [ 'message', 'callback_query' ]
		}, false, (timeout + 5) * 1000);
		return {
			request: plan.request,
			complete: (response) => {
				let reply = plan.complete(response);
				if (reply.limited)
					return { updates: [], retry_after_ms: reply.retry_after_ms };
				let updates = reply.document.result;
				if (type(updates) != 'array' || length(updates) > 100)
					errors.fail('INVALID_RESPONSE');
				for (let update in updates)
					if (type(update) != 'object' || type(update.update_id) != 'int' ||
					    update.update_id < 0)
						errors.fail('INVALID_RESPONSE');
				return { updates, retry_after_ms: 0 };
			}
		};
	};

	function message_fields(settings, chat, text, reply_markup, parse_mode) {
		configuration(settings);
		let fields = {
			chat_id: normalized_id(chat), text: message_text(text),
			disable_web_page_preview: true
		};
		let validated = markup(reply_markup);
		if (validated != null) fields.reply_markup = validated;
		if (parse_mode != null) {
			if (parse_mode != 'MarkdownV2') invalid();
			fields.parse_mode = parse_mode;
		}
		return fields;
	};

	return {
		prepare_poll: poll_plan,
		poll: (settings, offset, poll_timeout_seconds) => {
			let plan = poll_plan(settings, offset, poll_timeout_seconds), response;
			try { response = app.http.request(app.runtime, plan.request); }
			catch (error) { errors.fail('DOWNLOAD_FAILED'); }
			return plan.complete(response);
		},
		send: (settings, chat, text, reply_markup, parse_mode) => {
			let reply = call(settings, 'sendMessage',
				message_fields(settings, chat, text, reply_markup, parse_mode), true);
			if (reply.limited) return null;
			let result = reply.document.result;
			if (type(result) != 'object' || type(result.message_id) != 'int' || result.message_id < 1)
				errors.fail('INVALID_RESPONSE');
			return result;
		},
		edit: (settings, chat, id, text, reply_markup, parse_mode) => {
			let fields = message_fields(settings, chat, text, reply_markup, parse_mode);
			fields.message_id = message_id(id);
			let reply = call(settings, 'editMessageText', fields, true);
			if (reply.limited) return null;
			let result = reply.document.result;
			if (type(result) != 'object' || type(result.message_id) != 'int' || result.message_id < 1)
				errors.fail('INVALID_RESPONSE');
			return result;
		},
		send_document: (settings, chat, file, filename, caption, content_type) => {
			let plan = null, settled = false, response, reply;
			try {
				plan = document_plan(settings, chat, file, filename, caption, content_type);
				response = app.http.request(app.runtime, plan.request);
				reply = plan.complete(response);
				if (reply.limited) {
					if (file.close() !== true) errors.fail('INTERNAL');
					settled = true;
					return reply;
				}
				if (file.finish() !== true) errors.fail('INTERNAL');
				settled = true;
				return reply.result;
			}
			catch (error) {
				if (!settled)
					try { file.close(); } catch (close_error) {}
				let code = errors.normalize(error).code;
				errors.fail(code == 'INVALID_ARGUMENT' || code == 'INVALID_RESPONSE' ||
					code == 'INTERNAL' ? code : 'DOWNLOAD_FAILED');
			}
		},
		answer: (settings, callback_id, text) => {
			if (type(callback_id) != 'string' || !length(callback_id) ||
			    length(callback_id) > 128 || has_forbidden_control(callback_id, false)) invalid();
			if (type(text) != 'string' || length(text) > 200 || has_forbidden_control(text, true)) invalid();
			let reply = call(settings, 'answerCallbackQuery', {
				callback_query_id: callback_id, text
			}, true);
			if (reply.limited) return { ok: false, retry_after_ms: reply.retry_after_ms };
			if (reply.document.result !== true) errors.fail('INVALID_RESPONSE');
			return reply.document;
		},
		delete: (settings, chat, id) => {
			let reply = call(settings, 'deleteMessage', {
				chat_id: normalized_id(chat), message_id: message_id(id)
			}, true);
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
			let reply = call(settings, 'setMyCommands', fields, true);
			if (reply.limited) return false;
			if (reply.document.result !== true) errors.fail('INVALID_RESPONSE');
			return true;
		}
	};
};
