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
	    type(app?.network?.is_clean) != 'function' ||
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
	function operational_log(level, message) {
		try {
			let write = app.logger?.[level];
			if (type(write) == 'function') write('reconcile: ' + message);
		}
		catch (error) {}
	};
	function component(records, name) {
		for (let record in records ?? [])
			if (record?.component == name) return record;
		return null;
	};
	function readiness_log(ready) {
		let values = [];
		for (let record in ready?.components ?? []) {
			let name = record?.component, state = record?.state;
			if (type(name) != 'string' || !match(name, /^[A-Za-z0-9._-]{1,32}$/)) continue;
			if (type(state) != 'string' || !match(state, /^[A-Za-z0-9._-]{1,32}$/))
				state = record?.ready === true ? 'ready' : 'failed';
			push(values, name + ':' + state);
			if (length(values) >= 12) break;
		}
		if (length(values)) operational_log('error', 'readiness ' + join(',', values));
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
	function restore_system(desired) {
		let failed = false;
		// Keep the independent owner in place until every MiClash network
		// component has returned to the ordinary OpenWrt path. Guard OFF permits
		// direct traffic only after that terminal state is freshly verified.
		try { protect_transition(desired); }
		catch (error) { failed = true; }
		try {
			let observed = app.service.observe('config.yaml');
			if (observed?.state == 'running') {
				app.service.stop('config.yaml');
				let stopped = app.service.wait_ready(app.clock.now() + STOPPED_READY_TIMEOUT_MS,
					'config.yaml', { stopped: true });
				if (stopped?.ok !== true) failed = true;
			}
			else if (observed?.state != 'stopped' && observed?.state != 'missing_kernel')
				failed = true;
		}
		catch (error) { failed = true; }
		try { app.network.cleanup(desired); }
		catch (error) { failed = true; }
		try { if (app.network.is_clean() !== true) failed = true; }
		catch (error) { failed = true; }
		if (!failed) {
			try { release_transition(desired); }
			catch (error) { failed = true; }
		}
		if (!failed) {
			operational_log('info', 'rollback restored OpenWrt network ownership');
			return true;
		}
		// An unproved rollback is the only Guard-OFF failure allowed to remain
		// fail-closed. Persist the latch so reboot/startup cannot silently weaken it.
		try { app.guard.latch_set(); } catch (latch_error) {}
		try { app.guard.protect(); } catch (protect_error) {}
		operational_log('error', 'rollback failed; fail-closed protection retained');
		return false;
	};
	function reconcile_now(trigger, stage, service_action) {
		let desired = app.settings.get(), ready = null, failure_component = 'network';
		operational_log('info', sprintf('started reason=%s action=%s',
			trigger, service_action));
		try {
			if (app.guard.is_latched())
				desired = recover_guard(trigger, stage);
			// On a cold start, prove that Mihomo remains alive and its local API is
			// reachable before redirecting any router/client traffic to it. Guard ON
			// remains fail-closed; Guard OFF keeps the untouched OpenWrt path online.
			if (service_action == 'start') {
				failure_component = 'mihomo';
				if (desired?.guard?.enabled === true) {
					stage?.('guard-protect', 10, 'Maintaining fail-closed Guard protection');
					protect_transition(desired);
				}
				stage?.('core-start', 20, 'Starting Mihomo before network handoff');
				app.service.start('config.yaml');
				ready = app.service.wait_ready(app.clock.now() + RUNNING_READY_TIMEOUT_MS,
					'config.yaml', { core_only: true });
				if (ready?.ok !== true) fail('HEALTH_FAILED');
				operational_log('info', 'mihomo preflight ready components=process,api');
				ready = null;
				failure_component = 'network';
			}
			// Every multi-component network mutation has a separate physical safety
			// owner, even when canonical Guard is OFF. It is released only after the
			// complete native generation verifies, so partial state cannot leak direct
			// traffic between routing, DNS and firewall transitions.
			stage?.('guard-protect', service_action == 'start' ? 35 : 20,
				'Maintaining network handoff protection');
			if (app.guard.protect() !== true || app.guard.verify_protected() !== true)
				fail('HEALTH_FAILED');
			if (desired?.guard?.enabled === true && app.guard.verify(true) !== true)
				fail('HEALTH_FAILED');
			stage?.('network', service_action == 'start' ? 45 : 30,
				'Applying native firewall, routing and DNS state');
			app.network.apply(desired);
			operational_log('info', 'network state applied components=dns,firewall,routing');
			// Upgrade cleanup keeps an independent fail-closed owner armed until
			// the native network generation is fully installed. Canonical OFF may
			// only release it after that handoff point, never before.
			if (desired?.guard?.enabled !== true) {
				stage?.('guard-release', service_action == 'start' ? 55 : 45,
					'Releasing temporary network handoff protection');
				if (app.guard.disable() !== true || app.guard.verify(false) !== true)
					fail('HEALTH_FAILED');
			}
			failure_component = 'mihomo';
			stage?.('restart', service_action == 'start' ? 60 : 50,
				service_action == 'start' ? 'Verifying started Mihomo with native network state' :
					(service_action == 'observe' ? 'Keeping running Mihomo instance' :
						'Restarting Mihomo after configuration change'));
			let service_health = health_options(desired);
			if (service_action == 'repair') {
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
			operational_log('info', sprintf(
				'ready components=mihomo,dns,firewall,routing guard=%s',
				desired?.guard?.enabled === true ? 'enabled' : 'disabled'));
		}
		catch (error) {
			let code = error?.code ?? error?.message ?? 'HEALTH_FAILED';
			let rollback_required = desired?.guard?.enabled !== true && !app.guard.is_latched();
			let rolled_back = rollback_required ? restore_system(desired) : false;
			let reported_code = rollback_required && !rolled_back ? 'INTERNAL' : code;
			if (!rolled_back) {
				try { app.guard.protect(); } catch (protect_error) {}
				try { app.guard.latch_set(); } catch (latch_error) {}
			}
			if (active_failure == null)
				active_failure = sprintf('failure-%d-%d', ++failure_sequence, app.clock.now());
			active_component = failure_component;
			operational_log('error', sprintf(
				'failed component=%s reason=%s code=%s',
				failure_component, trigger, reported_code));
			readiness_log(ready);
			let data = { failure_id: active_failure, component: failure_component, reason: trigger };
			emit('failure', data);
			if (!rolled_back) emit('fail_closed', data);
			fail(reported_code);
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
				if (app.network.is_clean() === true) {
					if (desired?.guard?.enabled === true) protect_transition(desired);
					else release_transition(desired);
					return true;
				}
				protect_transition(desired);
				try {
					app.network.cleanup(desired);
					release_transition(desired);
				}
				catch (error) {
					fail(error?.code ?? error?.message ?? 'INTERNAL');
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
		recover_network: (trigger) => {
			reason(trigger);
			let desired = app.settings.get();
			if (desired?.guard?.enabled === true) fail('PERMISSION_DENIED');
			if (!restore_system(desired)) fail('INTERNAL');
			return true;
		},
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
