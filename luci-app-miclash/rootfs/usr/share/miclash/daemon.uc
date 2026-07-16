import * as errors from 'miclash.errors';
import * as operations from 'miclash.operations';
import * as settings from 'miclash.settings';
import * as storage from 'miclash.storage';
import * as history from 'miclash.history';
import * as diff from 'miclash.diff';
import * as service from 'miclash.service';
import * as config from 'miclash.config';
import * as state from 'miclash.state';
import * as application from 'miclash.application';
import * as api from 'miclash.api';
import * as memory from 'miclash.memory';
import * as backup from 'miclash.backup';
import * as devices from 'miclash.devices';
import * as notify from 'miclash.notify';
import * as mutation_lock from 'miclash.mutation_lock';

function clone(value) {
	try { return json(sprintf('%J', value)); }
	catch (error) { errors.fail('INVALID_ARGUMENT'); }
};

function utc_timezones(injected) {
	if (injected != null) {
		if (type(injected.list) != 'function' || type(injected.resolve) != 'function')
			errors.fail('INVALID_ARGUMENT');
		return injected;
	}
	return {
		list: () => [ 'UTC' ],
		resolve: (name, timestamp) => name == 'UTC' ? {
			name: 'UTC', from: 0, until: 4102444800,
			initial_offset: 0, transitions: []
		} : null
	};
};

function notification_config(settings) {
	if (type(settings) != 'object' || type(settings.channels) != 'array' ||
	    type(settings.events) != 'array') errors.fail('INVALID_ARGUMENT');
	let syslog = index(settings.channels, 'syslog') >= 0;
	let luci = index(settings.channels, 'luci') >= 0;
	return {
		dedupe_window_ms: 60000,
		syslog: { enabled: syslog, minimum_severity: 'info',
			types: clone(settings.events), components: [] },
		luci: { enabled: luci, channel: 'miclash.notification', minimum_severity: 'info',
			types: clone(settings.events), components: [] }
	};
};

function memory_options(settings) {
	if (type(settings) != 'object' || type(settings.enabled) != 'bool')
		errors.fail('INVALID_ARGUMENT');
	let result = {};
	for (let name, value in settings)
		if (name != 'enabled') result[name] = value;
	return result;
};

export function compose(runtime, overrides) {
	if (type(runtime?.ubus?.connect) != 'function' ||
	    type(runtime?.clock?.now) != 'function' || runtime?.paths?.tmp == null)
		errors.fail('INVALID_ARGUMENT');

	let modules = {
		operations, settings, storage, history, diff, service, config, state, application,
		api, memory, backup, devices, notify, mutation_lock,
		...(overrides ?? {})
	};
	let operation_manager = modules.operations.create(runtime);
	operation_manager.recover_interrupted();

	let connection = runtime.ubus.connect();
	if (connection == null)
		errors.fail('INTERNAL');
	let disconnected = false;
	function disconnect() {
		if (disconnected)
			return false;
		if (type(connection.disconnect) != 'function')
			return false;
		disconnected = true;
		if (connection.disconnect() !== true)
			errors.fail('INTERNAL');
		return true;
	};

	let transfers = null, close_domains = [];
	try {
		if (type(connection.publish) != 'function' ||
		    type(connection.disconnect) != 'function' ||
		    type(connection.call) != 'function')
			errors.fail('INTERNAL');
		// Domain adapters borrow the daemon-owned connection. They never own or close it.
		runtime.ubus = { connect: () => connection };
		let service_adapter = modules.service.create(runtime);
		runtime.service = service_adapter;
		let history_store = modules.history.create(runtime, { diff: modules.diff });
		let configuration = modules.config.create(runtime, operation_manager, history_store);
		let settings_domain = {
			get: () => modules.settings.load(runtime),
			validate: (patch) => modules.settings.validate_patch(patch),
			set: (patch) => modules.settings.save(runtime, patch)
		};
		let desired = settings_domain.get();
		let notification_settings = clone(desired.notifications);
		let notifier = modules.notify.create(runtime, notification_config(notification_settings));
		let producer = modules.notify.producer(runtime);
		let notifications_closed = false;
		let notifications_domain = {
			settings: () => clone(notification_settings),
			test: (channel) => {
				if (notifications_closed) errors.fail('HEALTH_FAILED');
				if (channel == 'telegram') return false;
				return notifier.test(channel) === true;
			},
			configure: (next) => {
				if (notifications_closed) errors.fail('HEALTH_FAILED');
				let configured = clone(next);
				let replacement = modules.notify.create(runtime, notification_config(configured));
				notification_settings = configured;
				notifier = replacement;
				return clone(notification_settings);
			},
			close: () => {
				if (notifications_closed) return false;
				notifications_closed = true; notifier = null; return true;
			}
		};
		push(close_domains, notifications_domain);

		let guard = modules.memory.create(runtime, service_adapter, operation_manager, (event) => {
			if (notifications_closed) return false;
			try { return notifier.emit(producer.memory(event)) === true; }
			catch (error) { return false; }
		});
		let memory_enabled = false, memory_timer = null, memory_closed = false;
		function cancel_memory_timer() {
			if (memory_timer == null) return false;
			let current = memory_timer; memory_timer = null;
			if (type(current.cancel) == 'function') current.cancel();
			return true;
		};
		function schedule_memory_sample() {
			cancel_memory_timer();
			if (!memory_enabled || memory_closed || type(runtime.clock.set_timeout) != 'function')
				return false;
			let interval = guard.settings().sample_interval_ms;
			memory_timer = runtime.clock.set_timeout(interval, () => {
				memory_timer = null;
				if (!memory_enabled || memory_closed) return;
				try { guard.sample(); } catch (error) {}
				schedule_memory_sample();
			});
			if (memory_timer == null) errors.fail('INTERNAL');
			return true;
		};
		let memory_domain = {
			status: () => guard.status(),
			settings: () => ({ enabled: memory_enabled, ...guard.settings() }),
			reset_baseline: () => guard.reset_baseline(),
			configure: (next) => {
				if (memory_closed) errors.fail('HEALTH_FAILED');
				guard.settings(memory_options(next));
				memory_enabled = next.enabled;
				schedule_memory_sample();
				return { enabled: memory_enabled, ...guard.settings() };
			},
			close: () => {
				if (memory_closed) return false;
				memory_closed = true; cancel_memory_timer(); return true;
			}
		};
		memory_domain.configure(desired.memory);
		push(close_domains, memory_domain);

		let timezone_adapter = utc_timezones(runtime.timezones);
		let device_app = { ...runtime, timezones: timezone_adapter };
		let devices_closed = false;
		let devices_domain = {
			list: () => { if (devices_closed) errors.fail('HEALTH_FAILED'); return modules.devices.discover(device_app); },
			timezones: () => { if (devices_closed) errors.fail('HEALTH_FAILED'); return modules.devices.timezones(device_app); },
			policy_list: () => { if (devices_closed) errors.fail('HEALTH_FAILED'); return modules.devices.policy_list(device_app); },
			policy_set: (policy) => { if (devices_closed) errors.fail('HEALTH_FAILED'); return modules.devices.policy_set(device_app, policy); },
			policy_delete: (id, revision) => { if (devices_closed) errors.fail('HEALTH_FAILED'); return modules.devices.policy_delete(device_app, id, revision); },
			close: () => { if (devices_closed) return false; devices_closed = true; return true; }
		};
		push(close_domains, devices_domain);

		let backup_app = {
			runtime, secure_fs: runtime.secure_fs, app_version: runtime.app_version ?? '0.9.2',
			settings: modules.settings, operations: operation_manager,
			config: configuration,
			rulesets: runtime.rulesets,
			lock: { with_lock: (rt, options, worker) => modules.mutation_lock.with_lock(rt, options, worker) },
			reconcile: runtime.reconcile
		};
		let backup_closed = false;
		let backup_domain = {
			list: () => { if (backup_closed) errors.fail('HEALTH_FAILED'); return modules.backup.list(backup_app, {}); },
			create: (options, source) => { if (backup_closed) errors.fail('HEALTH_FAILED'); return modules.backup.create(backup_app, options, source); },
			inspect: (id, options) => { if (backup_closed) errors.fail('HEALTH_FAILED'); return modules.backup.inspect(backup_app, id, options); },
			restore: (id, source) => { if (backup_closed) errors.fail('HEALTH_FAILED'); return modules.backup.restore(backup_app, id, {}, source); },
			download: (id) => { if (backup_closed) errors.fail('HEALTH_FAILED'); return modules.backup.transfer_download(backup_app, id); },
			import: (staged) => { if (backup_closed) errors.fail('HEALTH_FAILED'); return modules.backup.transfer_import(backup_app, staged); },
			close: () => { if (backup_closed) return false; backup_closed = true; return true; }
		};
		push(close_domains, backup_domain);
		let state_model = modules.state.create({
			settings: settings_domain,
			service: service_adapter,
			operations: operation_manager,
			clock: runtime.clock,
			store: {
				write: (snapshot) => modules.storage.write_json(runtime,
					runtime.paths.tmp + '/state.json', snapshot, 0o600)
			}
		});
		let app = modules.application.create({
			operations: operation_manager,
			settings: settings_domain,
			service: service_adapter,
			config: configuration,
			history: history_store,
			state: state_model,
			memory: memory_domain,
			backup: backup_domain,
			devices: devices_domain,
			notifications: notifications_domain,
			clock: runtime.clock
		});
		transfers = modules.api.create_transfers({
			runtime,
			uploads: { backup: (staged) => backup_domain.import(staged) },
			downloads: { backup: (id) => backup_domain.download(id) }
		});
		let published = modules.api.register(connection, app, transfers);
		let closed = false;
		return {
			app,
			state: state_model,
			connection,
			published,
			transfers,
			domains: { memory: memory_domain, backup: backup_domain,
				devices: devices_domain, notifications: notifications_domain },
			drain: () => app.set_draining(true),
			// NORMAL_CLOSE_BEGIN
			close: () => {
				if (closed)
					return false;
				closed = true;
				app.set_draining(true);
				let failure = null;
				try { transfers.close(); }
				catch (error) { failure = errors.normalize(error).code; }
				for (let index = length(close_domains) - 1; index >= 0; index--)
					try { close_domains[index].close(); }
					catch (error) { failure ??= errors.normalize(error).code; }
				try { state_model.close(); }
				catch (error) { failure ??= errors.normalize(error).code; }
				try { state_model.flush(); }
				catch (error) { failure ??= errors.normalize(error).code; }
				try { disconnect(); }
				catch (error) { failure ??= 'INTERNAL'; }
				if (failure != null)
					errors.fail(failure);
					return true;
			},
			// NORMAL_CLOSE_END
		};
	}
	catch (error) {
		let code = errors.normalize(error).code;
		if (transfers != null) try { transfers.close(); } catch (close_error) {}
		for (let index = length(close_domains) - 1; index >= 0; index--)
			try { close_domains[index].close(); } catch (close_error) {}
		try { disconnect(); } catch (disconnect_error) {}
		errors.fail(code);
	}
};
