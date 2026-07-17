import * as errors from 'miclash.errors';

function clone(value) {
	try { return json(sprintf('%J', value)); }
	catch (error) { errors.fail('INVALID_ARGUMENT'); }
};

function same(left, right) {
	try { return sprintf('%J', left) == sprintf('%J', right); }
	catch (error) { errors.fail('INVALID_ARGUMENT'); }
};

function effective(current, patch) {
	let result = clone(current);
	if (type(result) != 'object' || type(patch) != 'object') errors.fail('INVALID_ARGUMENT');
	for (let section, values in patch) {
		if (type(values) != 'object') errors.fail('INVALID_ARGUMENT');
		result[section] ??= {};
		for (let name, value in values) result[section][name] = clone(value);
	}
	return result;
};

export function create(dependencies) {
	if (type(dependencies?.operations?.submit) != 'function' ||
	    type(dependencies?.operations?.get) != 'function' ||
	    type(dependencies?.operations?.list) != 'function' ||
	    type(dependencies?.service?.start) != 'function' ||
	    type(dependencies?.service?.stop) != 'function' ||
	    type(dependencies?.service?.reload) != 'function' ||
	    type(dependencies?.service?.restart_service) != 'function' ||
	    type(dependencies?.service?.wait_ready) != 'function' ||
	    type(dependencies?.settings?.get) != 'function' ||
	    type(dependencies?.settings?.validate) != 'function' ||
	    type(dependencies?.settings?.set) != 'function' ||
	    type(dependencies?.config?.validate) != 'function' ||
	    type(dependencies?.config?.apply) != 'function' ||
	    type(dependencies?.config?.swap) != 'function' ||
	    type(dependencies?.config?.read_draft) != 'function' ||
	    type(dependencies?.config?.save_draft) != 'function' ||
	    type(dependencies?.history?.list) != 'function' ||
	    type(dependencies?.history?.diff) != 'function' ||
	    type(dependencies?.history?.open_draft) != 'function' ||
	    type(dependencies?.history?.restore) != 'function' ||
	    type(dependencies?.state?.snapshot) != 'function' ||
	    type(dependencies?.state?.health) != 'function' ||
	    type(dependencies?.state?.set_desired) != 'function' ||
	    type(dependencies?.memory?.status) != 'function' ||
	    type(dependencies?.memory?.settings) != 'function' ||
	    type(dependencies?.memory?.reset_baseline) != 'function' ||
	    type(dependencies?.memory?.configure) != 'function' ||
	    type(dependencies?.backup?.list) != 'function' ||
	    type(dependencies?.backup?.create) != 'function' ||
	    type(dependencies?.backup?.inspect) != 'function' ||
	    type(dependencies?.backup?.restore) != 'function' ||
	    type(dependencies?.backup?.configure) != 'function' ||
	    type(dependencies?.devices?.list) != 'function' ||
	    type(dependencies?.devices?.policy_list) != 'function' ||
	    type(dependencies?.devices?.policy_set) != 'function' ||
	    type(dependencies?.devices?.policy_delete) != 'function' ||
	    type(dependencies?.devices?.timezones) != 'function' ||
	    type(dependencies?.notifications?.settings) != 'function' ||
	    type(dependencies?.notifications?.test) != 'function' ||
	    type(dependencies?.notifications?.list) != 'function' ||
	    type(dependencies?.notifications?.configure) != 'function' ||
	    type(dependencies?.telegram?.status) != 'function' ||
	    type(dependencies?.telegram?.settings) != 'function' ||
	    type(dependencies?.telegram?.test) != 'function' ||
	    type(dependencies?.telegram?.configure) != 'function' ||
	    type(dependencies?.clock?.now) != 'function')
		errors.fail('INVALID_ARGUMENT');

	let draining = false;
	function writable() {
		if (draining)
			errors.fail('BUSY');
	};
	function service_action(action, profile, source) {
		writable();
		return dependencies.operations.submit('service.' + action, source,
			{ profile }, (ctx) => {
				ctx.stage('service_' + action, 20, '');
				if (action == 'start')
					dependencies.service.start(profile);
				else if (action == 'stop')
					dependencies.service.stop(profile);
				else if (action == 'reload') {
					let reply = dependencies.service.reload(profile);
					if (reply !== true && reply?.ok !== true)
						errors.fail('HEALTH_FAILED');
				}
				else
					dependencies.service.restart_service(profile);

				let ready = dependencies.service.wait_ready(
					dependencies.clock.now() + 5000, profile,
					action == 'stop' ? { stopped: true } : {});
				if (ready?.ok !== true)
					errors.fail('HEALTH_FAILED');
				ctx.stage('ready', 100, '');
			});
	};
	function domain_action(kind, source, context, worker) {
		writable();
		return dependencies.operations.submit(kind, source, context, (ctx) => {
			ctx.stage(kind, 20, '');
			let result = worker(ctx);
			ctx.stage('complete', 100, '');
			return result;
		});
	};

	return {
		status: () => dependencies.state.snapshot(),
		health: () => dependencies.state.health(),
		operation_get: (id) => dependencies.operations.get(id),
		operation_list: (filter) => dependencies.operations.list(filter),
		service_start: (profile, source) => service_action('start', profile, source),
		service_stop: (profile, source) => service_action('stop', profile, source),
		service_reload: (profile, source) => service_action('reload', profile, source),
		service_restart: (profile, source) => service_action('restart', profile, source),
		config_list: () => dependencies.config.list_profiles(),
		config_read: (profile) => dependencies.config.read_active(profile),
		config_read_draft: (profile) => dependencies.config.read_draft(profile),
		config_save_draft: (profile, content, source) => {
			writable();
			return dependencies.config.save_draft(profile, content, source);
		},
		config_validate: (profile, content, source) => {
			writable();
			return dependencies.config.validate(profile, content, source);
		},
		config_apply: (profile, content, source) => {
			writable();
			return dependencies.config.apply(profile, content, source);
		},
		operational_settings_apply: (profile, content, patch, source) => {
			writable();
			if (type(dependencies.config.apply_operational) != 'function')
				errors.fail('HEALTH_FAILED');
			patch = dependencies.settings.validate(patch);
			let allowed = { core: true, interfaces: true, updates: true };
			for (let section in keys(patch))
				if (allowed[section] !== true) errors.fail('INVALID_ARGUMENT');
			return dependencies.config.apply_operational(profile, content, source, {
				prepare: () => clone(dependencies.settings.get()),
				commit: () => {
					let saved = dependencies.settings.set(patch);
					dependencies.state.set_desired(saved);
					return true;
				},
				rollback: (before) => {
					let saved = dependencies.settings.set(before);
					dependencies.state.set_desired(saved);
					return true;
				}
			});
		},
		config_swap: (profile, source) => {
			writable();
			return dependencies.config.swap(profile, source);
		},
		history_list: (arguments) => {
			let records = dependencies.history.list(arguments.profile), output = [];
			for (let index = length(records) - 1;
			     index >= 0 && length(output) < arguments.limit; index--)
				push(output, records[index]);
			return output;
		},
		history_diff: (arguments) => dependencies.history.diff(arguments.profile,
			arguments.from_revision, arguments.to_revision),
		history_open_draft: (arguments) => {
			writable();
			return dependencies.history.open_draft(arguments.profile, arguments.revision,
				arguments.source);
		},
		history_restore: (arguments) => {
			writable();
			return dependencies.history.restore(arguments.profile, arguments.revision,
				arguments.source);
		},
		settings_get: () => dependencies.settings.get(),
		guard_transition: (enabled, source) => {
			writable();
			if (type(dependencies.guard?.transition) != 'function') errors.fail('HEALTH_FAILED');
			return dependencies.guard.transition(enabled, source);
		},
		settings_set: (patch, source) => {
			writable();
			patch = dependencies.settings.validate(patch);
			return dependencies.operations.submit('settings.set', source, {}, (ctx) => {
				let before = clone(dependencies.settings.get());
				let wanted = effective(before, patch);
				let memory_changed = !same(before.memory, wanted.memory);
				let notifications_changed = !same(before.notifications, wanted.notifications);
				let telegram_changed = !same(before.telegram, wanted.telegram);
				let backup_changed = !same(before.backup, wanted.backup);
				let prepare_memory = type(dependencies.memory.prepare) == 'function'
					? dependencies.memory.prepare : clone;
				let prepare_notifications = type(dependencies.notifications.prepare) == 'function'
					? dependencies.notifications.prepare : clone;
				let prepare_telegram = type(dependencies.telegram.prepare) == 'function'
					? dependencies.telegram.prepare : clone;
				let prepare_backup = type(dependencies.backup.prepare) == 'function'
					? dependencies.backup.prepare : clone;
				let next_memory = memory_changed ? prepare_memory(wanted.memory) : null;
				let next_notifications = notifications_changed
					? prepare_notifications(wanted.notifications) : null;
				let next_telegram = telegram_changed ? prepare_telegram(wanted.telegram) : null;
				let next_backup = backup_changed ? prepare_backup(wanted.backup) : null;
				let prior_notifications = notifications_changed
					? prepare_notifications(before.notifications) : null;
				let prior_telegram = telegram_changed ? prepare_telegram(before.telegram) : null;
				let prior_backup = backup_changed ? prepare_backup(before.backup) : null;
				ctx.stage('settings', 20, '');
				let persisted = false, notifications_attempted = false,
					telegram_attempted = false, backup_attempted = false, failure = null;
				try {
					let saved = dependencies.settings.set(patch);
					persisted = true;
					ctx.stage('committing', 80, '');
					dependencies.state.set_desired(saved);
					if (telegram_changed) {
						telegram_attempted = true;
						dependencies.telegram.configure(next_telegram);
					}
					if (notifications_changed) {
						notifications_attempted = true;
						dependencies.notifications.configure(next_notifications);
					}
					if (backup_changed) {
						backup_attempted = true;
						dependencies.backup.configure(next_backup);
					}
					// This is deliberately the last fallible commit. The Guard validates
					// and persists transactionally, so a failure preserves its baseline.
					if (memory_changed) dependencies.memory.configure(next_memory);
				}
				catch (error) { failure = errors.normalize(error).code; }
				if (failure != null) {
					let rollback_failed = false;
					if (persisted)
						try { dependencies.settings.set(before); }
						catch (error) { rollback_failed = true; }
					if (telegram_attempted)
						try { dependencies.telegram.configure(prior_telegram); }
						catch (error) { rollback_failed = true; }
					if (notifications_attempted)
						try { dependencies.notifications.configure(prior_notifications); }
						catch (error) { rollback_failed = true; }
					if (backup_attempted)
						try { dependencies.backup.configure(prior_backup); }
						catch (error) { rollback_failed = true; }
					if (persisted)
						try { dependencies.state.set_desired(before); }
						catch (error) { rollback_failed = true; }
					errors.fail(rollback_failed ? 'INTERNAL' : failure);
				}
			});
		},
		memory_status: () => dependencies.memory.status(),
		memory_settings: () => dependencies.memory.settings(),
		memory_reset_baseline: (arguments) => domain_action('memory.reset_baseline',
			arguments.source, {}, () => dependencies.memory.reset_baseline()),
		backup_list: () => dependencies.backup.list(),
		backup_create: (arguments) => domain_action('backup.create', arguments.source,
			{ options: arguments.options }, () => dependencies.backup.create(arguments.options,
				arguments.source)),
		backup_inspect: (arguments) => dependencies.backup.inspect(arguments.backup_id,
			arguments.options),
		backup_restore: (arguments) => {
			writable();
			return dependencies.backup.restore(arguments.inspection_id, arguments.source);
		},
		devices_list: () => dependencies.devices.list(),
		devices_timezones: () => dependencies.devices.timezones(),
		devices_policy_list: () => dependencies.devices.policy_list(),
		devices_policy_set: (arguments) => domain_action('devices.policy_set', arguments.source,
			{}, () => dependencies.devices.policy_set(arguments.policy)),
		devices_policy_delete: (arguments) => domain_action('devices.policy_delete',
			arguments.source, {}, () => dependencies.devices.policy_delete(arguments.policy_id,
				arguments.expected_revision)),
		notifications_settings: () => dependencies.notifications.settings(),
		notifications_test: (arguments) => ({ sent: dependencies.notifications.test(arguments.channel) === true }),
		notifications_list: (arguments) => dependencies.notifications.list(arguments),
		telegram_status: () => dependencies.telegram.status(),
		telegram_settings: () => dependencies.telegram.settings(),
		telegram_test: () => dependencies.telegram.test() === true,
		set_draining: (value) => {
			if (type(value) != 'bool')
				errors.fail('INVALID_ARGUMENT');
			draining = value;
			return draining;
		}
	};
};
