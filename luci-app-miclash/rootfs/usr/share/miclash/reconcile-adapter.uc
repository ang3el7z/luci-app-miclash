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
	function component(records, name) {
		for (let record in records ?? [])
			if (record?.component == name) return record;
		return null;
	};
	function restoration(failure_id, desired, ready) {
		let guard = component(ready?.components, 'guard');
		let dns = component(ready?.components, 'dns');
		let forward = component(ready?.components, 'forward');
		if (guard?.ready !== true || guard.enabled !== desired?.guard?.enabled ||
		    type(guard.observed_at) != 'int' || type(guard.generation) != 'int' ||
		    dns?.ready !== true || forward?.ready !== true)
			return null;
		let observed_at = app.clock.now();
		return {
			failure_id,
			recovery_of: (guard.enabled ? 'fail-closed/' : 'failure/') + failure_id,
			guard: { state: 'ok', enabled: guard.enabled,
				observed_at: guard.observed_at, generation: guard.generation },
			dns: { state: 'ok', observed_at },
			network: { state: 'ok', observed_at, path: 'proxy',
				guard_generation: guard.generation }
		};
	};
	function emit(type_name, data) {
		try { return app.events?.emit?.(type_name, data) === true; }
		catch (error) { return false; }
	};
	return {
		run: (trigger) => {
			trigger = reason(trigger);
			return app.operations.submit('system.reconcile', 'system', { trigger }, (ctx) => {
				let desired = app.settings.get(), ready = null;
				try {
					ctx.stage('restart', 25, 'Restarting Mihomo after configuration change');
					app.service.restart_service('config.yaml');
					ctx.stage('health', 70, 'Waiting for Mihomo and routing health');
					ready = app.service.wait_ready(app.clock.now() + 5000, 'config.yaml', {
						tun_required: desired?.core?.proxy_mode == 'tun',
						guard_enabled: desired?.guard?.enabled === true
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
					let evidence = restoration(active_failure, desired, ready);
					if (evidence == null) fail('HEALTH_FAILED');
					emit('internet_restored', evidence);
					// Guard failures create two active incidents. Internet restoration
					// closes fail-closed; the ordinary recovery closes the base failure.
					if (desired?.guard?.enabled === true)
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
