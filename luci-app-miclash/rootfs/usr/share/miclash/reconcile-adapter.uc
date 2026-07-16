import { fail } from 'miclash.errors';

function reason(value) {
	if (type(value) != 'string' || !match(value, /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/))
		fail('INVALID_ARGUMENT');
	return value;
};

export function create(app) {
	if (type(app?.operations?.submit) != 'function' ||
	    type(app?.service?.restart_service) != 'function' ||
	    type(app?.service?.wait_ready) != 'function' ||
	    type(app?.settings?.get) != 'function' || type(app?.clock?.now) != 'function')
		fail('INVALID_ARGUMENT');
	return {
		run: (trigger) => {
			trigger = reason(trigger);
			return app.operations.submit('system.reconcile', 'system', { trigger }, (ctx) => {
				let desired = app.settings.get();
				ctx.stage('restart', 25, 'Restarting Mihomo after configuration change');
				app.service.restart_service('config.yaml');
				ctx.stage('health', 70, 'Waiting for Mihomo and routing health');
				let ready = app.service.wait_ready(app.clock.now() + 5000, 'config.yaml', {
					tun_required: desired?.core?.proxy_mode == 'tun'
				});
				if (ready?.ok !== true) fail('HEALTH_FAILED');
				ctx.stage('complete', 100, 'Reconciliation complete');
				return { trigger, guard_preserved: desired?.guard?.enabled === true };
			});
		}
	};
};
