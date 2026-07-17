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
import * as subscription from 'miclash.subscription';
import * as updates from 'miclash.updates';
import * as http from 'miclash.http';
import * as redact from 'miclash.redact';
import * as mihomo_api from 'miclash.mihomo-api';

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

function bounded_logs(runtime) {
	let popen = runtime.fs?.popen ?? require('fs').popen;
	if (type(popen) != 'function') return '';
	let pipe = null, output = '';
	try {
		pipe = popen('/sbin/logread 2>/dev/null', 'r');
		if (pipe == null) return '';
		while (length(output) < 32768) {
			let chunk = pipe.read(min(4096, 32768 - length(output)));
			if (type(chunk) != 'string' || !length(chunk)) break;
			output += chunk;
		}
	}
	catch (error) { output = ''; }
	if (pipe != null) try { pipe.close(); } catch (error) { output = ''; }
	let selected = [];
	for (let line in split(output, '\n'))
		if (match(lc(line), /(clash(-rules|-hotplug)?|miclash)(\[[0-9]+\])?:/))
			push(selected, redact.sanitize(line));
	if (length(selected) > 1000)
		selected = slice(selected, length(selected) - 1000);
	return join('\n', selected);
};

function bounded_log_page(runtime, arguments) {
	let generation = arguments?.generation, cursor = arguments?.cursor ?? 0,
		limit = arguments?.limit ?? 100;
	if (type(cursor) != 'int' || cursor < 0 || type(limit) != 'int' || limit < 1 || limit > 200)
		errors.fail('INVALID_ARGUMENT');
	let source = bounded_logs(runtime);
	let lines = length(source) ? split(source, '\n') : [];
	if (cursor > length(lines)) cursor = length(lines);
	let page = slice(lines, cursor, min(length(lines), cursor + limit));
	let next = cursor + length(page);
	let digest = runtime.digest.sha256(source);
	if (type(digest) != 'string' || !match(digest, /^[0-9a-f]{64}$/))
		errors.fail('INTERNAL');
	let current_generation = 'log_' + substr(digest, 0, 16);
	if (generation != null && generation != current_generation)
		return { generation: current_generation, cursor: 0, next_cursor: 0,
			lines: [], has_more: length(lines) > 0, stale: true };
	return { generation: current_generation, cursor,
		next_cursor: next, lines: page, has_more: next < length(lines), stale: false };
};

function bounded_file(runtime, path, limit) {
	let value = null;
	try { value = runtime.fs?.readfile(path); }
	catch (error) { value = null; }
	if (type(value) != 'string') return '';
	return substr(value, 0, limit);
};

function release_value(source, name) {
	for (let line in split(source, '\n')) {
		let prefix = name + '=';
		if (substr(line, 0, length(prefix)) != prefix) continue;
		let value = substr(line, length(prefix));
		if (length(value) >= 2 && ((substr(value, 0, 1) == "'" && substr(value, -1) == "'") ||
		    (substr(value, 0, 1) == '"' && substr(value, -1) == '"')))
			value = substr(value, 1, length(value) - 2);
		return substr(value, 0, 128);
	}
	return '';
};

function mihomo_version(runtime, core) {
	if (core?.type != 'file' || core.nlink != 1 || (core.uid != null && core.uid != 0) ||
	    runtime.fs?.realpath('/opt/clash/bin/clash') != '/opt/clash/bin/clash')
		return '';
	let response = null;
	try {
		response = mihomo_api.request(runtime, 'GET', '/version', null, 'config.yaml');
	}
	catch (error) { return ''; }
	let output = response?.ok === true && type(response?.data?.version) == 'string'
		? response.data.version : '';
	if (length(output) > 128 || match(output, /[[:cntrl:]]/)) return '';
	let found = match(output, /^v?([0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z][0-9A-Za-z.-]*)?)$/);
	return found == null ? '' : substr(found[1], 0, 64);
};

function stable_mac(runtime) {
	let names = [];
	try { names = sort(runtime.fs?.lsdir('/sys/class/net') ?? []); }
	catch (error) { names = []; }
	for (let name in names) {
		if (type(name) != 'string' || name == 'lo' ||
		    !match(name, /^[A-Za-z0-9_.:@-]{1,64}$/)) continue;
		let value = lc(trim(bounded_file(runtime, '/sys/class/net/' + name + '/address', 64)));
		if (match(value, /^[0-9a-f]{2}(:[0-9a-f]{2}){5}$/) && value != '00:00:00:00:00:00')
			return value;
	}
	return '';
};

function bounded_system_info(runtime) {
	let release = bounded_file(runtime, '/etc/openwrt_release', 4096);
	let model = trim(bounded_file(runtime, '/tmp/sysinfo/model', 256));
	let mac = stable_mac(runtime);
	let identifier = runtime.digest.sha256(mac + '|' + model);
	if (type(identifier) != 'string' || !match(identifier, /^[0-9a-f]{64}$/))
		errors.fail('INTERNAL');
	let core = null;
	try { core = runtime.fs?.lstat('/opt/clash/bin/clash'); }
	catch (error) { core = null; }
	let package_manager = '';
	for (let candidate in [ [ 'apk', '/usr/bin/apk' ], [ 'apk', '/bin/apk' ],
	    [ 'opkg', '/bin/opkg' ], [ 'opkg', '/usr/bin/opkg' ] ]) {
		let stat = null;
		try { stat = runtime.fs?.lstat(candidate[1]); } catch (error) {}
		if (stat?.type == 'file') { package_manager = candidate[0]; break; }
	}
	return {
		app_version: substr(runtime.app_version ?? '', 0, 64),
		mihomo: { installed: core?.type == 'file', version: mihomo_version(runtime, core) },
		openwrt_version: release_value(release, 'DISTRIB_RELEASE'),
		architecture: release_value(release, 'DISTRIB_ARCH'),
		model: substr(model, 0, 128), hwid: substr(identifier, 0, 14), package_manager
	};
};

function bounded_network_interfaces(runtime, settings_domain) {
	let names = [];
	try { names = runtime.fs?.lsdir('/sys/class/net') ?? []; }
	catch (error) { names = []; }
	if (type(names) != 'array') names = [];
	let interfaces = [];
	for (let name in names) {
		if (length(interfaces) >= 128) break;
		if (type(name) != 'string' || !match(name, /^[A-Za-z0-9_.:@-]{1,64}$/) ||
		    name == 'lo' || name == 'clash-tun' || index(interfaces, name) >= 0)
			continue;
		push(interfaces, name);
	}
	interfaces = sort(interfaces);
	let configured = settings_domain.get().interfaces;
	let lan = configured.detected_lan, wan = configured.detected_wan;
	if (type(lan) != 'string' || index(interfaces, lan) < 0)
		lan = index(interfaces, 'br-lan') >= 0 ? 'br-lan' :
			(index(interfaces, 'lan') >= 0 ? 'lan' : '');
	if (type(wan) != 'string' || index(interfaces, wan) < 0) {
		wan = '';
		let routes = bounded_file(runtime, '/proc/net/route', 65536);
		for (let line in split(routes, '\n')) {
			let found = match(line,
				/^([A-Za-z0-9_.:@-]{1,64})[ \t]+00000000[ \t]+[0-9A-Fa-f]{8}[ \t]+/);
			if (found != null && index(interfaces, found[1]) >= 0) { wan = found[1]; break; }
		}
		if (!length(wan) && index(interfaces, 'wan') >= 0) wan = 'wan';
	}
	return { interfaces, detected_lan: lan, detected_wan: wan };
};

const RULESET_ROOT = '/opt/clash/lst';
const WHITELIST_RULESET = 'fakeip-whitelist-ipcidr.txt';

function ruleset_name(value) {
	if (type(value) != 'string' || length(value) < 5 || length(value) > 90 ||
	    !match(value, /^[a-z0-9][a-z0-9_-]*\.txt$/))
		errors.fail('INVALID_ARGUMENT');
	return value;
};

function ruleset_path(name) { return RULESET_ROOT + '/' + ruleset_name(name); };

function ensure_ruleset_root(runtime) {
	let stat = runtime.fs.lstat(RULESET_ROOT);
	if (stat == null) {
		if (runtime.fs.mkdir(RULESET_ROOT) !== true) errors.fail('INTERNAL');
		stat = runtime.fs.lstat(RULESET_ROOT);
	}
	if (stat?.type != 'directory' || (stat.uid != null && stat.uid != 0) ||
	    runtime.fs.realpath(RULESET_ROOT) != RULESET_ROOT)
		errors.fail('INTERNAL');
	if (stat.mode != 0o700 && runtime.fs.chmod(RULESET_ROOT, 0o700) !== true)
		errors.fail('INTERNAL');
	return true;
};

function ruleset_read(runtime, name) {
	let path = ruleset_path(name), before = runtime.fs.lstat(path);
	if (before?.type != 'file' || before.nlink != 1 || before.size > 4194304 ||
	    runtime.fs.realpath(path) != path)
		errors.fail('NOT_FOUND');
	let content = runtime.fs.readfile(path), after = runtime.fs.lstat(path);
	if (after?.type != 'file' || after.nlink != 1 ||
	    before.inode != after.inode || before.dev?.major != after.dev?.major ||
	    before.dev?.minor != after.dev?.minor ||
	    runtime.rulesets.validate(name, content) !== true)
		errors.fail('NOT_FOUND');
	return { name, content };
};

function ruleset_list(runtime) {
	ensure_ruleset_root(runtime);
	let names = [];
	for (let name in runtime.fs.lsdir(RULESET_ROOT) ?? []) {
		if (length(names) >= 128 || name == WHITELIST_RULESET ||
		    type(name) != 'string' || !match(name, /^[a-z0-9][a-z0-9_-]*\.txt$/))
			continue;
		let path = RULESET_ROOT + '/' + name, stat = runtime.fs.lstat(path);
		if (stat?.type == 'file' && stat.nlink == 1 && runtime.fs.realpath(path) == path)
			push(names, name);
	}
	return { names: sort(names) };
};

function ruleset_write(runtime, manager, arguments, whitelist) {
	let name = whitelist ? WHITELIST_RULESET : ruleset_name(arguments.name);
	let content = arguments.content;
	if (runtime.rulesets.validate(name, content) !== true) errors.fail('INVALID_ARGUMENT');
	return manager.submit(whitelist ? 'rulesets.whitelist' : 'rulesets.write', arguments.source,
		{ name }, (ctx) => {
			ctx.stage('write', 30, 'write'); ensure_ruleset_root(runtime);
			storage.atomic_write(runtime, ruleset_path(name), content, 0o600);
			if (whitelist) {
				ctx.stage('apply', 70, 'apply');
				if (runtime.process.run({ command: '/opt/clash/bin/clash-rules',
					args: [ 'update-ip-whitelist' ] })?.code != 0)
					errors.fail('HEALTH_FAILED');
			}
			ctx.stage('complete', 100, 'complete'); return { name };
		});
};

function ruleset_delete(runtime, manager, arguments) {
	let name = ruleset_name(arguments.name);
	if (name == WHITELIST_RULESET) errors.fail('INVALID_ARGUMENT');
	return manager.submit('rulesets.delete', arguments.source, { name }, (ctx) => {
		ctx.stage('delete', 50, 'delete');
		let path = ruleset_path(name), stat = runtime.fs.lstat(path);
		if (stat?.type != 'file' || stat.nlink != 1 || runtime.fs.realpath(path) != path ||
		    runtime.fs.unlink(path) !== true)
			errors.fail('NOT_FOUND');
		ctx.stage('complete', 100, 'complete'); return { name };
	});
};

export function compose(runtime, overrides) {
	if (type(runtime?.ubus?.connect) != 'function' ||
	    type(runtime?.clock?.now) != 'function' || runtime?.paths?.tmp == null)
		errors.fail('INVALID_ARGUMENT');

	let modules = {
		operations, settings, storage, history, diff, service, config, state, application,
		api, memory, backup, devices, notify, telegram, mutation_lock,
		reconcile_adapter, subscription, updates, http,
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
		let reconcile_settings = {
			get: settings_domain.get,
			set: (patch) => {
				let saved = settings_domain.set(patch);
				desired = saved;
				if (state_model != null) state_model.set_desired(saved);
				return saved;
			}
		};
		if (runtime.reconcile == null)
			runtime.reconcile = modules.reconcile_adapter.create({
				operations: operation_manager, service: service_adapter,
				settings: reconcile_settings, guard: runtime.guard_control,
				clock: runtime.clock, events: runtime.events
			});
		let notification_settings = clone(desired.notifications);
		let notifier = modules.notify.create(runtime, notification_config(notification_settings));
		let producer = modules.notify.producer(runtime);
		let telegram_controller = null, telegram_channel_unsubscribe = null;
		let lifecycle_unsubscribe = null;
		if (type(runtime.events?.subscribe) == 'function')
			lifecycle_unsubscribe = runtime.events.subscribe((type_name, data) => {
				try {
					let event = type_name == 'internet_restored'
						? producer.internet(data)
						: producer.reconcile(type_name, data);
					notifier.emit(event);
				}
				catch (error) {}
			});
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
				if (lifecycle_unsubscribe != null) {
					lifecycle_unsubscribe(); lifecycle_unsubscribe = null;
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
				if (telegram_controller == null) {
					telegram_settings = clone(next);
					return clone(telegram_settings);
				}
				let running = telegram_controller.status().running === true;
				if (next.enabled && !running) {
					let started = false, failure = null;
					try { started = telegram_controller.start() === true; }
					catch (error) { failure = errors.normalize(error).code; }
					if (!started) {
						try { telegram_controller.stop(); } catch (cleanup_error) {}
						errors.fail(failure ?? 'HEALTH_FAILED');
					}
				}
				if (!next.enabled && running) {
					let stopped = false, failure = null;
					try { stopped = telegram_controller.stop() === true; }
					catch (error) { failure = errors.normalize(error).code; }
					if (!stopped) errors.fail(failure ?? 'HEALTH_FAILED');
				}
				telegram_settings = clone(next);
				return clone(telegram_settings);
			}
		};

		let guard = modules.memory.create(runtime, service_adapter, operation_manager, (event) => {
			if (notifications_closed) return false;
			try { return notifier.emit(producer.memory(event)) === true; }
			catch (error) { return false; }
		});
		let memory_enabled = false, memory_timer = null, memory_closed = false;
		let schedule_memory_sample = null;
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
		function create_memory_timer(interval, allow_fallback) {
			let timer = null, activated = false, fired = false;
			let callback = () => {
				if (!activated) { fired = true; return; }
				if (memory_timer !== timer || !memory_enabled || memory_closed) return;
				memory_timer = null;
				try { guard.sample(); } catch (error) {}
				schedule_memory_sample(true);
			};
			try {
				timer = runtime.clock.set_timeout(interval, callback);
			}
			catch (error) {}
			if (timer == null && !fired && allow_fallback === true) {
				try { timer?.cancel?.(); } catch (error) {}
				fired = false;
				try {
					if (type(runtime.clock.set_fallback_timeout) == 'function')
						timer = runtime.clock.set_fallback_timeout(interval, callback);
				}
				catch (error) { timer = null; }
			}
			if (timer == null || type(timer.cancel) != 'function' || fired) {
				try { timer?.cancel?.(); } catch (error) {}
				errors.fail('INTERNAL');
			}
			return { timer, activate: () => { activated = true; return true; } };
		};
		schedule_memory_sample = (allow_fallback) => {
			if (!memory_enabled || memory_closed || type(runtime.clock.set_timeout) != 'function')
				return cancel_memory_timer();
			let prepared = create_memory_timer(guard.settings().sample_interval_ms, allow_fallback);
			let previous = memory_timer;
			memory_timer = prepared.timer;
			prepared.activate();
			if (previous != null) try { previous.cancel(); } catch (error) {}
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
				let prepared = null;
				if ((options_changed || enabled_changed) && next.enabled) {
					if (type(runtime.clock.set_timeout) != 'function') errors.fail('INTERNAL');
					prepared = create_memory_timer(wanted.sample_interval_ms, false);
				}
				try {
					if (options_changed) guard.settings(wanted);
				}
				catch (error) {
					try { prepared?.timer?.cancel?.(); } catch (cancel_error) {}
					errors.fail(errors.normalize(error).code);
				}
				let previous = memory_timer;
				memory_enabled = next.enabled;
				if (prepared != null) {
					memory_timer = prepared.timer;
					prepared.activate();
				}
				else if (options_changed || enabled_changed)
					memory_timer = null;
				if (previous != null && previous !== memory_timer)
					try { previous.cancel(); } catch (error) {}
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
		function schedule_backup_timer(allow_fallback) {
			if (backup_closed || type(runtime.clock.set_timeout) != 'function')
				return cancel_backup_timer();
			let due = next_cleanup_at;
			if ((backup_settings.enabled || backup_pending_prune) && next_backup_at != null && next_backup_at < due)
				due = next_backup_at;
			let previous = backup_timer, timer = null, activated = false, fired = false;
			let callback = () => {
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
							next_backup_at = backup_settings.enabled ? scheduled_at(backup_settings, now) : null;
						}
					}
					catch (prune_error) {
						backup_pending_prune = true; backup_failures = min(backup_failures + 1, 4);
						let retry = 300000; for (let index = 1; index < backup_failures; index++) retry *= 2;
						next_backup_at = now + min(retry, 3600000);
						try { if (type(producer.backup) == 'function') notifier.emit(producer.backup(false)); } catch (notify_error) {}
					}
					next_cleanup_at = now + 900000;
				}
				if ((backup_settings.enabled || backup_pending_prune) && next_backup_at != null && now >= next_backup_at && !backup_running) {
					backup_running = true; let success = false;
					try {
						if (!backup_pending_prune) {
							modules.backup.create(backup_app, { include_secrets: backup_settings.include_secrets }, 'auto');
							backup_pending_prune = true; backup_failures = 0;
						}
						if (type(modules.backup.prune) != 'function') errors.fail('INTERNAL');
						modules.backup.prune(backup_app, { retain: backup_settings.retention });
						backup_pending_prune = false; success = true;
					}
					catch (backup_error) {}
					backup_running = false;
					try { if (type(producer.backup) == 'function') notifier.emit(producer.backup(success)); } catch (notify_error) {}
					if (success) { backup_failures = 0; next_backup_at = scheduled_at(backup_settings, now); }
					else {
						backup_failures = min(backup_failures + 1, 4);
						let retry = 300000; for (let index = 1; index < backup_failures; index++) retry *= 2;
						next_backup_at = now + min(retry, 3600000);
					}
				}
				try { schedule_backup_timer(true); } catch (schedule_error) {}
			};
			try {
				timer = runtime.clock.set_timeout(max(0, due - runtime.clock.now()), callback);
			}
			catch (error) {}
			if (timer == null && !fired && allow_fallback === true) {
				try { timer?.cancel?.(); } catch (error) {}
				fired = false;
				try {
					if (type(runtime.clock.set_fallback_timeout) == 'function')
						timer = runtime.clock.set_fallback_timeout(max(0, due - runtime.clock.now()), callback);
				}
				catch (error) { timer = null; }
			}
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
				schedule_backup_timer(false); return clone(backup_settings);
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
		let guard_failure_sequence = 0;
		function guard_failure(protected, reason) {
			let failure_id = sprintf('failure-%d-%d', ++guard_failure_sequence,
				runtime.clock.now());
			let data = { failure_id, component: 'guard', reason };
			try { runtime.events?.emit?.('failure', data); } catch (error) {}
			if (protected)
				try { runtime.events?.emit?.('fail_closed', data); } catch (error) {}
			try { runtime.reconcile?.run?.('guard-transition'); } catch (error) {}
		};
		function persist_guard(enabled) {
			let failure = null;
			for (let attempt = 0; attempt < 2; attempt++) {
				try {
					let saved = settings_domain.set({ guard: { enabled } });
					state_model.set_desired(saved);
					return saved;
				}
				catch (error) { failure = errors.normalize(error).code; }
			}
			errors.fail(failure ?? 'INTERNAL');
		};
		function exact_protection() {
			let control = runtime.guard_control;
			if (type(control?.protect) != 'function') errors.fail('HEALTH_FAILED');
			for (let attempt = 0; attempt < 2; attempt++) {
				try { if (control.protect() === true) return true; }
				catch (error) {}
			}
			errors.fail('HEALTH_FAILED');
		};
		function exact_guard(enabled) {
			let control = runtime.guard_control;
			if (type(control?.verify) != 'function' || control.verify(enabled) !== true)
				errors.fail('HEALTH_FAILED');
			return true;
		};
		function exact_latch_set() {
			let control = runtime.guard_control;
			if (type(control?.latch_set) != 'function' || control.latch_set() !== true ||
			    type(control?.is_latched) != 'function' || control.is_latched() !== true)
				errors.fail('HEALTH_FAILED');
			return true;
		};
		function exact_latch_clear() {
			let control = runtime.guard_control;
			if (type(control?.latch_clear) != 'function' || control.latch_clear() !== true ||
			    type(control?.is_latched) != 'function' || control.is_latched() !== false)
				errors.fail('HEALTH_FAILED');
			return true;
		};
		function guard_transition(enabled, source) {
			if (type(enabled) != 'bool') errors.fail('INVALID_ARGUMENT');
			return operation_manager.submit('guard.transition', source, { enabled }, (ctx) => {
				let failure = 'HEALTH_FAILED', protected = false, persisted = false;
				try {
					ctx.stage('latch', 5, 'Arming durable fail-closed Guard latch');
					exact_latch_set();
					ctx.stage('protect', 10, 'Establishing fail-closed Guard');
					exact_protection(); protected = true;
					ctx.stage('settings', 35, 'Applying canonical Guard setting');
					persist_guard(enabled); persisted = true;
					if (!enabled) {
						ctx.stage('disable', 65, 'Atomically disabling Guard');
						if (type(runtime.guard_control?.disable) != 'function' ||
						    runtime.guard_control.disable() !== true)
							errors.fail('HEALTH_FAILED');
						if (runtime.guard_control.is_latched() !== false)
							errors.fail('HEALTH_FAILED');
						protected = false;
					}
					ctx.stage('verify', 90, 'Verifying applied Guard state');
					exact_guard(enabled);
					if (enabled) exact_latch_clear();
					ctx.stage('ready', 100, 'Guard transition complete');
					return { enabled, guard_preserved: enabled };
				}
				catch (error) {
					failure = errors.normalize(error).code;
					// Every failed transition is durable fail-closed. Latch persistence,
					// physical emergency recovery and UCI repair are independent so one
					// broken backend cannot skip the others.
					try { exact_latch_set(); } catch (latch_error) { failure = 'INTERNAL'; }
					try { exact_protection(); protected = true; }
					catch (protect_error) { protected = false; failure = 'INTERNAL'; }
					try { persist_guard(true); persisted = true; }
					catch (intent_error) { failure = 'INTERNAL'; }
					if (protected && persisted)
						try { exact_guard(true); }
						catch (verify_error) { failure = 'INTERNAL'; }
					guard_failure(protected, enabled ? 'enable-transition' : 'disable-transition');
					errors.fail(failure);
				}
			});
		};
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
			guard: { transition: guard_transition },
			clock: runtime.clock
		});
		let domain_settings = { get: reconcile_settings.get, set: reconcile_settings.set,
			validate: settings_domain.validate };
		let subscription_domain = modules.subscription.create({
			runtime, http: modules.http, operations: operation_manager,
			config: configuration, settings: domain_settings
		});
		// Profile bytes and their subscription URL share one transaction. The
		// configuration domain invokes rollback after any failed activation.
		app.config_swap = (profile, source) => configuration.swap(profile, source, {
			prepare: () => clone(reconcile_settings.get()),
			commit: (before) => {
				let selected_key = profile == 'config2.yaml'
					? 'subscription_url_config2_yaml' : 'subscription_url_config3_yaml';
				let main = before.core.subscription_url_config_yaml;
				if (!length(main ?? '')) main = before.core.subscription_url;
				let selected = before.core[selected_key];
				reconcile_settings.set({ core: {
					subscription_url: selected, subscription_url_config_yaml: selected,
					[selected_key]: main
				} });
				return true;
			},
			rollback: (before) => {
				reconcile_settings.set(before);
				return true;
			}
		});
		let updates_domain = modules.updates.create({
			runtime, operations: operation_manager, service: service_adapter,
			settings: domain_settings
		});
		app.logs_read = (arguments) => bounded_log_page(runtime, arguments);
		app.system_info = () => bounded_system_info(runtime);
		app.network_interfaces = () => bounded_network_interfaces(runtime, settings_domain);
		app.ruleset_list = () => ruleset_list(runtime);
		app.ruleset_read = (arguments) => ruleset_read(runtime, arguments.name);
		app.ruleset_write = (arguments) => ruleset_write(runtime, operation_manager, arguments, false);
		app.ruleset_delete = (arguments) => ruleset_delete(runtime, operation_manager, arguments);
		app.ruleset_apply_whitelist = (arguments) => ruleset_write(runtime, operation_manager, arguments, true);
		app.subscription_get = (arguments) => subscription_domain.get_redacted(arguments.profile);
		app.subscription_set = (arguments) => subscription_domain.set_url({
			profile: arguments.profile, url: arguments.url,
			interval_hours: reconcile_settings.get().updates.interval_hours
		}, arguments.source);
		app.subscription_update = (arguments) => subscription_domain.update({
			profile: arguments.profile, url: null
		}, arguments.source);
		app.update_release = (arguments) => updates_domain.release_info({
			kind: arguments.kind, channel: arguments.channel, version: null
		});
		app.update_miclash = (arguments) => updates_domain.update_miclash({
			version: null, channel: arguments.channel
		}, arguments.source);
		app.update_mihomo = (arguments) => updates_domain.update_mihomo({
			version: null, channel: arguments.channel
		}, arguments.source);
		app.update_rollback_mihomo = (arguments) => {
			let previous_id = updates_domain.status().previous_id;
			if (type(previous_id) != 'string') errors.fail('NOT_FOUND');
			return updates_domain.rollback_mihomo({ id: previous_id }, arguments.source);
		};
		if (type(desired.telegram) == 'object') {
			let unavailable = () => errors.fail('HEALTH_FAILED');
			let telegram_app = {
				runtime, http: modules.http, operations: operation_manager,
				logger: runtime.logger, audit: runtime.audit,
				settings_get: app.settings_get,
				status: app.status, health: app.health,
				memory_status: app.memory_status,
				diagnostics_summary: () => ({ status: app.status(), health: app.health(),
					memory: app.memory_status() }),
				logs_read: () => bounded_logs(runtime),
				service_start: app.service_start, service_stop: app.service_stop,
				service_restart: app.service_restart, service_reload: app.service_reload,
				reboot: type(runtime.reboot) == 'function' ? runtime.reboot : unavailable,
				subscription_update: (url, source) => subscription_domain.update({
					profile: 'config.yaml', url
				}, source),
				update_miclash: (source) => updates_domain.update_miclash({
					version: null, channel: null
				}, source),
				update_mihomo: (source) => updates_domain.update_mihomo({
					version: null, channel: null
				}, source),
				settings_set: app.settings_set,
				guard_transition,
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
