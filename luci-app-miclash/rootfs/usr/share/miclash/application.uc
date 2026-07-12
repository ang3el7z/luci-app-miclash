import * as errors from 'miclash.errors';

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
	    type(dependencies?.state?.snapshot) != 'function' ||
	    type(dependencies?.state?.health) != 'function' ||
	    type(dependencies?.state?.set_desired) != 'function' ||
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
		config_validate: (profile, content, source) => {
			writable();
			return dependencies.config.validate(profile, content, source);
		},
		config_apply: (profile, content, source) => {
			writable();
			return dependencies.config.apply(profile, content, source);
		},
		settings_get: () => dependencies.settings.get(),
		settings_set: (patch, source) => {
			writable();
			patch = dependencies.settings.validate(patch);
			return dependencies.operations.submit('settings.set', source, {}, (ctx) => {
				ctx.stage('settings', 20, '');
				let saved = dependencies.settings.set(patch);
				dependencies.state.set_desired(saved);
				ctx.stage('saved', 100, '');
			});
		},
		set_draining: (value) => {
			if (type(value) != 'bool')
				errors.fail('INVALID_ARGUMENT');
			draining = value;
			return draining;
		}
	};
};
