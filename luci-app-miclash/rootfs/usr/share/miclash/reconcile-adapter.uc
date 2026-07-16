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
	if (app.events != null && type(app.events.emit) != 'function')
		fail('INVALID_ARGUMENT');
	let failure_sequence = 0, active_failure = null;
	function emit(type_name, data) {
		try { return app.events?.emit?.(type_name, data) === true; }
		catch (error) { return false; }
	};
	return {
		run: (trigger) => {
			trigger = reason(trigger);
			return app.operations.submit('system.reconcile', 'system', { trigger }, (ctx) => {
				let desired = app.settings.get();
				try {
					ctx.stage('restart', 25, 'Restarting Mihomo after configuration change');
					app.service.restart_service('config.yaml');
					ctx.stage('health', 70, 'Waiting for Mihomo and routing health');
					let ready = app.service.wait_ready(app.clock.now() + 5000, 'config.yaml', {
						tun_required: desired?.core?.proxy_mode == 'tun'
					});
					if (ready?.ok !== true) fail('HEALTH_FAILED');
				}
				catch (error) {
					if (active_failure == null)
						active_failure = sprintf('failure-%d-%d', ++failure_sequence,
							app.clock.now());
					let data = { failure_id: active_failure, component: 'mihomo', reason: trigger };
					emit('failure', data);
					if (desired?.guard?.enabled === true) emit('fail_closed', data);
					fail(error?.code ?? error?.message ?? 'HEALTH_FAILED');
				}
				if (active_failure != null) {
					emit('recovery', { failure_id: active_failure,
						component: 'mihomo', reason: trigger });
					active_failure = null;
				}
				ctx.stage('complete', 100, 'Reconciliation complete');
				return { trigger, guard_preserved: desired?.guard?.enabled === true };
			});
		}
	};
};
