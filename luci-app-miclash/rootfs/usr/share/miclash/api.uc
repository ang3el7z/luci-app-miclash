import * as errors from 'miclash.errors';
import * as redact from 'miclash.redact';
import * as schema from 'miclash.schema';

const MAX_CONTENT = 1048576;
const MUTATION_SOURCES = [ 'luci', 'telegram' ];
const OPERATION_SOURCES = [ 'luci', 'telegram', 'auto', 'system' ];
const OPERATION_STATES = [ 'queued', 'running', 'success', 'failure', 'interrupted' ];

function canonical_error(error) {
	let normalized = errors.normalize(error);
	return {
		error: {
			code: normalized.code,
			message: normalized.code == 'INTERNAL' ? 'Internal error' : normalized.code
		}
	};
};

function guarded(callback) {
	return (request) => {
		try { return callback(request?.args ?? {}); }
		catch (error) { return canonical_error(error); }
	};
};

function exact(arguments, fields) {
	return schema.object(arguments, fields);
};

function source(arguments) {
	return schema.enum_value(arguments.source ?? 'luci', MUTATION_SOURCES);
};

function profile(arguments) {
	return schema.profile_name(arguments.profile ?? 'config.yaml');
};

function content(arguments) {
	return schema.validate({ type: 'string', min_length: 1, max_length: MAX_CONTENT },
		arguments.content);
};

function operation_reply(record) {
	if (type(record?.id) != 'string')
		errors.fail('INTERNAL');
	return { operation_id: schema.operation_id(record.id) };
};

function method(policy, callback) {
	return { args: policy, call: guarded(callback) };
};

export function method_table(app) {
	for (let name in [
		'status', 'health', 'operation_get', 'operation_list',
		'service_start', 'service_stop', 'service_reload', 'service_restart',
		'config_list', 'config_read', 'config_validate', 'config_apply',
		'settings_get', 'settings_set', 'set_draining'
	]) if (type(app?.[name]) != 'function')
		errors.fail('INVALID_ARGUMENT');

	let empty = {};
	let service_policy = { profile: '', source: '' };
	let config_policy = { profile: '', content: '', source: '' };

	return {
		status: method(empty, (arguments) => {
			exact(arguments, {});
			return app.status();
		}),
		health: method(empty, (arguments) => {
			exact(arguments, {});
			return app.health();
		}),
		operation_get: method({ operation_id: '' }, (arguments) => {
			exact(arguments, { operation_id: { type: 'string', required: true } });
			let operation = app.operation_get(schema.operation_id(arguments.operation_id));
			if (operation == null)
				errors.fail('NOT_FOUND');
			return { operation: redact.value('operation', operation) };
		}),
		operation_list: method({ state: '', kind: '', source: '' }, (arguments) => {
			exact(arguments, {
				state: { type: 'string' }, kind: { type: 'string', max_length: 128 },
				source: { type: 'string' }
			});
			if (arguments.state != null)
				schema.enum_value(arguments.state, OPERATION_STATES);
			if (arguments.source != null)
				schema.enum_value(arguments.source, OPERATION_SOURCES);
			if (arguments.kind != null && !match(arguments.kind,
				/^[A-Za-z0-9][A-Za-z0-9._-]*$/))
				errors.fail('INVALID_ARGUMENT');
			return { operations: redact.value('operations', app.operation_list(arguments)) };
		}),
		service_start: method(service_policy, (arguments) => {
			exact(arguments, { profile: { type: 'string' }, source: { type: 'string' } });
			return operation_reply(app.service_start(profile(arguments), source(arguments)));
		}),
		service_stop: method(service_policy, (arguments) => {
			exact(arguments, { profile: { type: 'string' }, source: { type: 'string' } });
			return operation_reply(app.service_stop(profile(arguments), source(arguments)));
		}),
		service_reload: method(service_policy, (arguments) => {
			exact(arguments, { profile: { type: 'string' }, source: { type: 'string' } });
			return operation_reply(app.service_reload(profile(arguments), source(arguments)));
		}),
		service_restart: method(service_policy, (arguments) => {
			exact(arguments, { profile: { type: 'string' }, source: { type: 'string' } });
			return operation_reply(app.service_restart(profile(arguments), source(arguments)));
		}),
		config_list: method(empty, (arguments) => {
			exact(arguments, {});
			return { profiles: app.config_list() };
		}),
		config_read: method({ profile: '' }, (arguments) => {
			exact(arguments, { profile: { type: 'string' } });
			let selected_profile = profile(arguments);
			return {
				profile: selected_profile,
				content: app.config_read(selected_profile)
			};
		}),
		config_validate: method(config_policy, (arguments) => {
			exact(arguments, {
				profile: { type: 'string' }, content: { type: 'string', required: true },
				source: { type: 'string' }
			});
			return operation_reply(app.config_validate(profile(arguments),
				content(arguments), source(arguments)));
		}),
		config_apply: method(config_policy, (arguments) => {
			exact(arguments, {
				profile: { type: 'string' }, content: { type: 'string', required: true },
				source: { type: 'string' }
			});
			return operation_reply(app.config_apply(profile(arguments),
				content(arguments), source(arguments)));
		}),
		settings_get: method(empty, (arguments) => {
			exact(arguments, {});
			return redact.value('settings', app.settings_get());
		}),
		settings_set: method({ settings: {}, source: '' }, (arguments) => {
			exact(arguments, {
				settings: { type: 'object', required: true }, source: { type: 'string' }
			});
			return operation_reply(app.settings_set(arguments.settings, source(arguments)));
		})
	};
};

export function set_draining(app, draining) {
	if (type(app) != 'object' || type(draining) != 'bool')
		errors.fail('INVALID_ARGUMENT');
	return app.set_draining(draining);
};

export function register(connection, app) {
	if (type(connection?.publish) != 'function')
		errors.fail('INVALID_ARGUMENT');
	let object = connection.publish('miclash', method_table(app));
	if (object == null)
		errors.fail('INTERNAL');
	return object;
};
