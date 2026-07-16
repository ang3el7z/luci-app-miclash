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
import * as telegram from 'miclash.telegram';
import * as mutation_lock from 'miclash.mutation_lock';
import * as reconcile_adapter from 'miclash.reconcile-adapter';

function clone(value) {
	try { return json(sprintf('%J', value)); }
	catch (error) { errors.fail('INVALID_ARGUMENT'); }
};

function same(left, right) {
	try { return sprintf('%J', left) == sprintf('%J', right); }
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
		api, memory, backup, devices, notify, telegram, mutation_lock,
		reconcile_adapter,
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

	let transfers = null, state_model = null, close_domains = [];
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
		if (runtime.reconcile == null)
			runtime.reconcile = modules.reconcile_adapter.create({
				operations: operation_manager, service: service_adapter,
				settings: settings_domain, clock: runtime.clock
			});
		let notification_settings = clone(desired.notifications);
		let notifier = modules.notify.create(runtime, notification_config(notification_settings));
		let producer = modules.notify.producer(runtime);
		let telegram_controller = null, telegram_channel_unsubscribe = null;
		let operation_unsubscribe = operation_manager.subscribe((record) => {
			if (record?.state != 'success' && record?.state != 'failure' &&
			    record?.state != 'interrupted') return;
			try { notifier.emit(producer.operation(record)); } catch (error) {}
		});
		let notifications_closed = false;
		function sync_telegram_channel() {
			if (telegram_channel_unsubscribe != null) {
				try { telegram_channel_unsubscribe(); } catch (error) {}
				telegram_channel_unsubscribe = null;
			}
			if (notifications_closed || telegram_controller == null ||
			    index(notification_settings.channels, 'telegram') < 0)
				return false;
			let channel = modules.notify.telegram_channel(telegram_controller);
			channel.types = clone(notification_settings.events);
			telegram_channel_unsubscribe = notifier.subscribe(channel);
			return true;
		};
		function prepare_notification_settings(next) {
			if (notifications_closed) errors.fail('HEALTH_FAILED');
			let configured = clone(next);
			let notifier_settings = notification_config(configured);
			if (type(notifier.prepare) == 'function')
				notifier_settings = notifier.prepare(notifier_settings);
			return { settings: configured, notifier: notifier_settings };
		};
		let notifications_domain = {
			settings: () => clone(notification_settings),
			list: (arguments) => {
				if (notifications_closed) errors.fail('HEALTH_FAILED');
				return notifier.list(arguments);
			},
			test: (channel) => {
				if (notifications_closed) errors.fail('HEALTH_FAILED');
				if (channel == 'telegram')
					return telegram_controller != null && telegram_controller.test() === true;
				return notifier.test(channel) === true;
			},
			prepare: prepare_notification_settings,
			configure: (next) => {
				if (notifications_closed) errors.fail('HEALTH_FAILED');
				let prepared = next?.settings != null && next?.notifier != null
					? next : prepare_notification_settings(next);
				if (type(notifier.configure) == 'function')
					notifier.configure(prepared.notifier);
				else
					notifier = modules.notify.create(runtime, prepared.notifier);
				notification_settings = clone(prepared.settings);
				sync_telegram_channel();
				return clone(notification_settings);
			},
			close: () => {
				if (notifications_closed) return false;
				notifications_closed = true;
				if (operation_unsubscribe != null) {
					operation_unsubscribe(); operation_unsubscribe = null;
				}
				if (telegram_channel_unsubscribe != null) {
					telegram_channel_unsubscribe(); telegram_channel_unsubscribe = null;
				}
				notifier = null; return true;
			}
		};
		push(close_domains, notifications_domain);
		let telegram_settings = clone(desired.telegram ?? {
			enabled: false, token: '', user_id: ''
		});
		function prepare_telegram_settings(next) {
			if (type(next) != 'object' || type(next.enabled) != 'bool')
				errors.fail('INVALID_ARGUMENT');
			return clone(next);
		};
		let telegram_domain = {
			status: () => telegram_controller == null ? {
				running: false, enabled: telegram_settings.enabled, configured: false
			} : telegram_controller.status(),
			settings: () => clone(telegram_settings),
			test: () => telegram_controller != null && telegram_controller.test() === true,
			prepare: prepare_telegram_settings,
			configure: (next) => {
				next = prepare_telegram_settings(next);
				telegram_settings = clone(next);
				if (telegram_controller == null) return clone(telegram_settings);
				let running = telegram_controller.status().running === true;
				if (next.enabled && !running) telegram_controller.start();
				if (!next.enabled && running) telegram_controller.stop();
				return clone(telegram_settings);
			}
		};

		let guard = modules.memory.create(runtime, service_adapter, operation_manager, (event) => {
			if (notifications_closed) return false;
			try { return notifier.emit(producer.memory(event)) === true; }
			catch (error) { return false; }
		});
		let memory_enabled = false, memory_timer = null, memory_closed = false;
		function prepare_memory_settings(next) {
			if (memory_closed) errors.fail('HEALTH_FAILED');
			memory_options(next);
			return clone(next);
		};
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
			prepare: prepare_memory_settings,
			configure: (next) => {
				if (memory_closed) errors.fail('HEALTH_FAILED');
				next = prepare_memory_settings(next);
				let wanted = memory_options(next), current = guard.settings();
				let options_changed = !same(current, wanted);
				let enabled_changed = memory_enabled != next.enabled;
				if (options_changed) guard.settings(wanted);
				memory_enabled = next.enabled;
				if (options_changed || enabled_changed) schedule_memory_sample();
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
		let backup_closed = false, backup_timer = null, backup_failures = 0;
		let backup_pending_prune = false;
		let backup_running = false, next_cleanup_at = runtime.clock.now() + 900000;
		let next_backup_at = null;
		let backup_settings = { enabled: false, retention: 5, include_secrets: false,
			interval_hours: 24, schedule_time: '03:00', ...(desired.backup ?? {}) };
		function prepare_backup_settings(next) {
			if (backup_closed || type(next) != 'object' || type(next.enabled) != 'bool' ||
			    type(next.retention) != 'int' || next.retention < 1 || next.retention > 100 ||
			    type(next.include_secrets) != 'bool' || type(next.interval_hours) != 'int' ||
			    next.interval_hours < 1 || next.interval_hours > 168 ||
			    !match(next.schedule_time, /^([01][0-9]|2[0-3]):[0-5][0-9]$/))
				errors.fail(backup_closed ? 'HEALTH_FAILED' : 'INVALID_ARGUMENT');
			return clone(next);
		};
		function scheduled_at(next, now) {
			let parts = split(next.schedule_time, ':');
			let anchor = (int(parts[0]) * 60 + int(parts[1])) * 60000;
			let interval = next.interval_hours * 3600000;
			if (now < anchor) return anchor;
			return anchor + (int((now - anchor) / interval) + 1) * interval;
		};
		function cancel_backup_timer() {
			if (backup_timer == null) return false;
			let current = backup_timer; backup_timer = null;
			if (type(current.cancel) == 'function') current.cancel();
			return true;
		};
		function schedule_backup_timer() {
			if (backup_closed || type(runtime.clock.set_timeout) != 'function')
				return cancel_backup_timer();
			let due = next_cleanup_at;
			if ((backup_settings.enabled || backup_pending_prune) && next_backup_at != null && next_backup_at < due)
				due = next_backup_at;
			let previous = backup_timer, timer = null, activated = false, fired = false;
			try {
				timer = runtime.clock.set_timeout(max(0, due - runtime.clock.now()), () => {
					if (!activated) { fired = true; return; }
					if (backup_timer !== timer || backup_closed) return;
					backup_timer = null;
					let now = runtime.clock.now();
					if (now >= next_cleanup_at) {
						try { modules.backup.list(backup_app, {}); } catch (cleanup_error) {}
						try {
							if (type(modules.backup.prune) != 'function') errors.fail('INTERNAL');
							modules.backup.prune(backup_app, { retain: backup_settings.retention });
							if (backup_pending_prune) {
								backup_pending_prune = false; backup_failures = 0;
								next_backup_at = backup_settings.enabled ?
									scheduled_at(backup_settings, now) : null;
							}
						}
						catch (prune_error) {
							backup_pending_prune = true;
							backup_failures = min(backup_failures + 1, 4);
							let retry = 300000;
							for (let index = 1; index < backup_failures; index++) retry *= 2;
							next_backup_at = now + min(retry, 3600000);
							try {
								if (type(producer.backup) == 'function')
									notifier.emit(producer.backup(false));
							} catch (notify_error) {}
						}
						next_cleanup_at = now + 900000;
					}
					if ((backup_settings.enabled || backup_pending_prune) && next_backup_at != null &&
					    now >= next_backup_at && !backup_running) {
						backup_running = true; let success = false;
						try {
							if (!backup_pending_prune) {
								modules.backup.create(backup_app,
									{ include_secrets: backup_settings.include_secrets }, 'auto');
								backup_pending_prune = true;
								backup_failures = 0;
							}
							if (type(modules.backup.prune) != 'function') errors.fail('INTERNAL');
							modules.backup.prune(backup_app, { retain: backup_settings.retention });
							backup_pending_prune = false;
							success = true;
						}
						catch (backup_error) {}
						backup_running = false;
						try {
							if (type(producer.backup) == 'function')
								notifier.emit(producer.backup(success));
						} catch (notify_error) {}
						if (success) {
							backup_failures = 0;
							next_backup_at = scheduled_at(backup_settings, now);
						}
						else {
							backup_failures = min(backup_failures + 1, 4);
							let retry = 300000;
							for (let index = 1; index < backup_failures; index++) retry *= 2;
							next_backup_at = now + min(retry, 3600000);
						}
					}
					try { schedule_backup_timer(); } catch (schedule_error) {}
				});
			}
			catch (error) { errors.fail('INTERNAL'); }
			if (timer == null || type(timer.cancel) != 'function' || fired) {
				try { timer?.cancel?.(); } catch (error) {}
				errors.fail('INTERNAL');
			}
			backup_timer = timer; activated = true;
			if (previous != null) try { previous.cancel(); } catch (error) {}
			return true;
		};
		let backup_domain = {
			list: () => { if (backup_closed) errors.fail('HEALTH_FAILED'); return modules.backup.list(backup_app, {}); },
			create: (options, source) => { if (backup_closed) errors.fail('HEALTH_FAILED'); return modules.backup.create(backup_app, options, source); },
			inspect: (id, options) => { if (backup_closed) errors.fail('HEALTH_FAILED'); return modules.backup.inspect(backup_app, id, options); },
			restore: (id, source) => { if (backup_closed) errors.fail('HEALTH_FAILED'); return modules.backup.restore(backup_app, id, {}, source); },
			download: (id) => { if (backup_closed) errors.fail('HEALTH_FAILED'); return modules.backup.transfer_download(backup_app, id); },
			import: (staged) => { if (backup_closed) errors.fail('HEALTH_FAILED'); return modules.backup.transfer_import(backup_app, staged); },
			prepare: prepare_backup_settings,
			configure: (next) => {
				next = prepare_backup_settings(next); backup_settings = clone(next);
				backup_failures = 0;
				if (next.enabled) next_backup_at = scheduled_at(next, runtime.clock.now());
				else if (!backup_pending_prune) next_backup_at = null;
				schedule_backup_timer(); return clone(backup_settings);
			},
			close: () => {
				if (backup_closed) return false;
				backup_closed = true; cancel_backup_timer(); return true;
			}
		};
		backup_domain.configure(backup_settings);
		push(close_domains, backup_domain);
		state_model = modules.state.create({
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
			telegram: telegram_domain,
			clock: runtime.clock
		});
		if (type(desired.telegram) == 'object') {
			let unavailable = () => errors.fail('HEALTH_FAILED');
			let telegram_app = {
				runtime, http: runtime.http, operations: operation_manager,
				logger: runtime.logger, audit: runtime.audit,
				settings_get: app.settings_get,
				status: app.status, health: app.health,
				memory_status: app.memory_status,
				diagnostics_summary: () => ({ status: app.status(), health: app.health(),
					memory: app.memory_status() }),
				logs_read: () => [],
				service_start: app.service_start, service_stop: app.service_stop,
				service_restart: app.service_restart, service_reload: app.service_reload,
				reboot: type(runtime.reboot) == 'function' ? runtime.reboot : unavailable,
				subscription_update: type(app.subscription_update) == 'function'
					? app.subscription_update : unavailable,
				update_miclash: type(app.update_miclash) == 'function'
					? app.update_miclash : unavailable,
				update_mihomo: type(app.update_mihomo) == 'function'
					? app.update_mihomo : unavailable,
				settings_set: app.settings_set,
				backup_create: (source) => app.backup_create({
					options: { include_secrets: false }, source
				})
			};
			telegram_controller = modules.telegram.create(telegram_app);
			sync_telegram_channel();
			telegram_domain.configure(telegram_settings);
			let telegram_closed = false;
			push(close_domains, { close: () => {
				if (telegram_closed) return false;
				telegram_closed = true;
				if (telegram_channel_unsubscribe != null) {
					telegram_channel_unsubscribe(); telegram_channel_unsubscribe = null;
				}
				telegram_controller.stop();
				telegram_controller = null;
				return true;
			} });
		}
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
		if (state_model != null) {
			try { state_model.close(); } catch (close_error) {}
			try { state_model.flush(); } catch (close_error) {}
		}
		try { disconnect(); } catch (disconnect_error) {}
		errors.fail(code);
	}
};
