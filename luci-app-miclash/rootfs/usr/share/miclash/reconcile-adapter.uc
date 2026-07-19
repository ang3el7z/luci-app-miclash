import { fail } from 'miclash.errors';

const RUNNING_READY_TIMEOUT_MS = 30000;
const STOPPED_READY_TIMEOUT_MS = 5000;

function reason(value) {
	if (type(value) != 'string' || !match(value, /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/))
		fail('INVALID_ARGUMENT');
	return value;
};

export function create(app) {
	if (type(app?.operations?.submit) != 'function' ||
	    type(app?.service?.restart_service) != 'function' ||
	    type(app?.service?.observe) != 'function' || type(app?.service?.start) != 'function' ||
	    type(app?.service?.stop) != 'function' ||
	    type(app?.service?.wait_ready) != 'function' ||
	    type(app?.service?.recover) != 'function' ||
	    type(app?.network?.apply) != 'function' || type(app?.network?.cleanup) != 'function' ||
	    type(app?.settings?.get) != 'function' || type(app?.settings?.set) != 'function' ||
	    type(app?.guard?.is_latched) != 'function' || type(app?.guard?.latch_set) != 'function' ||
	    type(app?.guard?.protect) != 'function' ||
	    type(app?.guard?.verify_protected) != 'function' ||
	    type(app?.guard?.disable) != 'function' || type(app?.guard?.verify) != 'function' ||
	    type(app?.guard?.latch_clear) != 'function' ||
	    type(app?.clock?.now) != 'function')
		fail('INVALID_ARGUMENT');
	if (app.events != null && type(app.events.emit) != 'function')
		fail('INVALID_ARGUMENT');
	let failure_sequence = 0, active_failure = null, active_component = null;
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
	function recover_guard(trigger, stage) {
		trigger = reason(trigger);
		if (!app.guard.is_latched()) return app.settings.get();
		let desired;
		try {
			stage?.('guard-protect', 10, 'Maintaining fail-closed Guard protection');
			if (app.guard.protect() !== true) fail('HEALTH_FAILED');
			stage?.('guard-settings', 15, 'Repairing canonical Guard setting');
			desired = app.settings.set({ guard: { enabled: true } });
			if (desired?.guard?.enabled !== true || app.guard.verify(true) !== true)
				fail('HEALTH_FAILED');
			stage?.('guard-latch', 20, 'Releasing repaired Guard safety latch');
			if (app.guard.latch_clear() !== true || app.guard.is_latched())
				fail('HEALTH_FAILED');
			return desired;
		}
		catch (error) {
			// Startup and ordinary reconciliation share this exact fail-closed
			// transaction. Partial latch release is always durably re-armed.
			try { app.guard.latch_set(); } catch (latch_error) {}
			try { app.guard.protect(); } catch (protect_error) {}
			fail(error?.code ?? error?.message ?? 'HEALTH_FAILED');
		}
	};
	function protect_transition(desired) {
		if (app.guard.protect() !== true || app.guard.verify_protected() !== true)
			fail('HEALTH_FAILED');
		if (desired?.guard?.enabled === true && app.guard.verify(true) !== true)
			fail('HEALTH_FAILED');
		return true;
	};
	function release_transition(desired) {
		if (desired?.guard?.enabled !== true &&
		    (app.guard.disable() !== true || app.guard.verify(false) !== true))
			fail('HEALTH_FAILED');
		return true;
	};
	function health_options(desired) {
		let mode = desired?.core?.proxy_mode;
		return {
			proxy_mode: mode,
			tun_required: mode == 'tun' || mode == 'mixed',
			guard_enabled: desired?.guard?.enabled === true
		};
	};
	function restore_running(desired) {
		try {
			// disable() may have changed physical state before OFF verification
			// failed. Re-establish the independent safety owner before any restore.
			protect_transition(desired);
			app.network.apply(desired);
			app.service.start('config.yaml');
			let ready = app.service.wait_ready(app.clock.now() + RUNNING_READY_TIMEOUT_MS, 'config.yaml',
				health_options(desired));
			if (ready?.ok !== true) fail('HEALTH_FAILED');
			release_transition(desired);
			return true;
		}
		catch (error) {
			// Availability restoration itself failed. Persist the physical safety
			// owner so later startup repairs canonical Guard before any traffic.
			try { app.guard.latch_set(); } catch (latch_error) {}
			try { app.guard.protect(); } catch (protect_error) {}
			return false;
		}
	};
	function reconcile_now(trigger, stage, service_action) {
		let desired = app.settings.get(), ready = null, failure_component = 'network';
		try {
			if (app.guard.is_latched())
				desired = recover_guard(trigger, stage);
			// Every multi-component network mutation has a separate physical safety
			// owner, even when canonical Guard is OFF. It is released only after the
			// complete native generation verifies, so partial state cannot leak direct
			// traffic between routing, DNS and firewall transitions.
			stage?.('guard-protect', 20, 'Maintaining network handoff protection');
			if (app.guard.protect() !== true || app.guard.verify_protected() !== true)
				fail('HEALTH_FAILED');
			if (desired?.guard?.enabled === true && app.guard.verify(true) !== true)
				fail('HEALTH_FAILED');
			stage?.('network', 30, 'Applying native firewall, routing and DNS state');
			app.network.apply(desired);
			// Upgrade cleanup keeps an independent fail-closed owner armed until
			// the native network generation is fully installed. Canonical OFF may
			// only release it after that handoff point, never before.
			if (desired?.guard?.enabled !== true) {
				stage?.('guard-release', 45, 'Releasing temporary network handoff protection');
				if (app.guard.disable() !== true || app.guard.verify(false) !== true)
					fail('HEALTH_FAILED');
			}
			failure_component = 'mihomo';
			stage?.('restart', 50, service_action == 'start'
				? 'Starting Mihomo with native network state'
				: (service_action == 'observe' ? 'Keeping running Mihomo instance' :
					'Restarting Mihomo after configuration change'));
			let service_health = health_options(desired);
			if (service_action == 'start') app.service.start('config.yaml');
			else if (service_action == 'repair') {
				let repaired = app.service.recover('config.yaml', null, service_health);
				ready = repaired?.ready;
				if (repaired?.ok !== true) fail('HEALTH_FAILED');
			}
			else if (service_action != 'observe') app.service.restart_service('config.yaml');
			stage?.('health', 75, 'Waiting for Mihomo and routing health');
			if (ready == null)
				ready = app.service.wait_ready(app.clock.now() + RUNNING_READY_TIMEOUT_MS,
					'config.yaml', service_health);
			if (ready?.ok !== true) fail('HEALTH_FAILED');
		}
		catch (error) {
			// Keep the independent bootstrap owner armed after any failed network
			// handoff. Canonical OFF is not rewritten; the next successful reconcile
			// releases this temporary owner only after full verification.
			try { app.guard.protect(); } catch (protect_error) {}
			if (desired?.guard?.enabled === true || app.guard.is_latched()) {
				try { app.guard.latch_set(); } catch (latch_error) {}
			}
			if (active_failure == null)
				active_failure = sprintf('failure-%d-%d', ++failure_sequence, app.clock.now());
			active_component = failure_component;
			let data = { failure_id: active_failure, component: failure_component, reason: trigger };
			emit('failure', data);
			if (desired?.guard?.enabled === true || app.guard.is_latched()) emit('fail_closed', data);
			fail(error?.code ?? error?.message ?? 'HEALTH_FAILED');
		}
		return { desired, ready };
	};
	function stop_now(trigger) {
		let desired = app.settings.get();
		protect_transition(desired);
		try {
			app.service.stop('config.yaml');
			let stopped = app.service.wait_ready(app.clock.now() + STOPPED_READY_TIMEOUT_MS,
				'config.yaml', { stopped: true });
			if (stopped?.ok !== true) fail('HEALTH_FAILED');
			app.network.cleanup(desired);
			release_transition(desired);
		}
		catch (error) {
			let code = error?.code ?? error?.message ?? 'INTERNAL';
			if (restore_running(desired)) fail(code);
			fail('INTERNAL');
		}
		return true;
	};
	return {
		recover_guard: (trigger) => {
			recover_guard(trigger, null);
			return true;
		},
		startup: (trigger) => {
			trigger = reason(trigger);
			let observed = app.service.observe('config.yaml');
			if (observed?.state == 'stopped' || observed?.state == 'missing_kernel') {
				let desired = app.settings.get();
				protect_transition(desired);
				try {
					app.network.cleanup(desired);
					release_transition(desired);
				}
				catch (error) {
					if (restore_running(desired)) return true;
					fail('INTERNAL');
				}
				return true;
			}
			if (observed?.state != 'running') fail('HEALTH_FAILED');
			let result = reconcile_now(trigger, null, 'observe');
			return result?.ready?.ok === true;
		},
		start: (trigger) => reconcile_now(reason(trigger), null, 'start')?.ready?.ok === true,
		stop: (trigger) => stop_now(reason(trigger)),
		restart: (trigger) => reconcile_now(reason(trigger), null, 'restart')?.ready?.ok === true,
		reload: (trigger) => reconcile_now(reason(trigger), null, 'repair')?.ready?.ok === true,
		external: (trigger) => reconcile_now(reason(trigger), null, 'repair')?.ready?.ok === true,
		apply: (trigger, stage) => reconcile_now(reason(trigger), stage, 'observe')?.ready?.ok === true,
		run: (trigger) => {
			trigger = reason(trigger);
			return app.operations.submit('system.reconcile', 'system', { trigger }, (ctx) => {
				let reconciled = reconcile_now(trigger, ctx.stage, 'repair');
				let desired = reconciled.desired, ready = reconciled.ready;
				if (active_failure != null) {
					let evidence = restoration(active_failure, desired, ready);
					if (evidence == null) fail('HEALTH_FAILED');
					emit('internet_restored', evidence);
					// Guard failures create two active incidents. Internet restoration
					// closes fail-closed; the ordinary recovery closes the base failure.
					if (desired?.guard?.enabled === true)
						emit('recovery', { failure_id: active_failure,
							component: active_component ?? 'mihomo', reason: trigger });
					active_failure = null;
					active_component = null;
				}
				ctx.stage('complete', 100, 'Reconciliation complete');
				return { trigger, guard_preserved: desired?.guard?.enabled === true };
			});
		}
	};
};
