import * as errors from 'miclash.errors';

const SERVICE_READY_TIMEOUT_MS = 30000;
const SERVICE_STOP_TIMEOUT_MS = 5000;

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
	    type(dependencies?.state?.snapshot) != 'function' ||
	    type(dependencies?.state?.health) != 'function' ||
	    type(dependencies?.state?.set_desired) != 'function' ||
	    type(dependencies?.memory?.status) != 'function' ||
	    type(dependencies?.memory?.settings) != 'function' ||
	    type(dependencies?.memory?.reset_baseline) != 'function' ||
	    type(dependencies?.memory?.configure) != 'function' ||
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
					dependencies.clock.now() + (action == 'stop'
						? SERVICE_STOP_TIMEOUT_MS : SERVICE_READY_TIMEOUT_MS), profile,
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
		overview: () => type(dependencies.state.current) == 'function'
			? dependencies.state.current() : dependencies.state.snapshot(),
		health: () => dependencies.state.health(),
		operation_get: (id) => dependencies.operations.get(id),
		operation_list: (filter) => dependencies.operations.list(filter),
		service_start: (profile, source) => service_action('start', profile, source),
		service_stop: (profile, source) => service_action('stop', profile, source),
		service_reload: (profile, source) => service_action('reload', profile, source),
		service_restart: (profile, source) => service_action('restart', profile, source),
		config_list: () => dependencies.config.list_profiles(),
		config_read: (profile) => dependencies.config.read_active(profile),
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
			let allowed = { core: true, interfaces: true };
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
				let prepare_memory = type(dependencies.memory.prepare) == 'function'
					? dependencies.memory.prepare : clone;
				let prepare_notifications = type(dependencies.notifications.prepare) == 'function'
					? dependencies.notifications.prepare : clone;
				let prepare_telegram = type(dependencies.telegram.prepare) == 'function'
					? dependencies.telegram.prepare : clone;
				let next_memory = memory_changed ? prepare_memory(wanted.memory) : null;
				let next_notifications = notifications_changed
					? prepare_notifications(wanted.notifications) : null;
				let next_telegram = telegram_changed ? prepare_telegram(wanted.telegram) : null;
				let prior_notifications = notifications_changed
					? prepare_notifications(before.notifications) : null;
				let prior_telegram = telegram_changed ? prepare_telegram(before.telegram) : null;
				ctx.stage('settings', 20, '');
				let persisted = false, notifications_attempted = false,
					telegram_attempted = false, failure = null;
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
		devices_list: () => dependencies.devices.list(),
		devices_timezones: () => dependencies.devices.timezones(),
		devices_policy_list: () => dependencies.devices.policy_list(),
		devices_policy_set: (arguments) => domain_action('devices.policy_set', arguments.source,
			{}, (ctx) => dependencies.devices.policy_set(arguments.policy, ctx.stage)),
		devices_policy_delete: (arguments) => domain_action('devices.policy_delete',
			arguments.source, {}, (ctx) => dependencies.devices.policy_delete(arguments.policy_id,
				arguments.expected_revision, ctx.stage)),
		notifications_settings: () => dependencies.notifications.settings(),
		notifications_test: (arguments) => ({ sent: dependencies.notifications.test(arguments.channel) === true }),
		notifications_list: (arguments) => dependencies.notifications.list(arguments),
		telegram_status: () => dependencies.telegram.status(),
		telegram_settings: () => dependencies.telegram.settings(),
		telegram_token_reveal: () => {
			let settings = dependencies.telegram.settings();
			let token = type(settings?.token) == 'string' ? settings.token : '';
			return { configured: length(token) > 0, token };
		},
		telegram_test: () => dependencies.telegram.test() === true,
		set_draining: (value) => {
			if (type(value) != 'bool')
				errors.fail('INVALID_ARGUMENT');
			draining = value;
			return draining;
		}
	};
};
