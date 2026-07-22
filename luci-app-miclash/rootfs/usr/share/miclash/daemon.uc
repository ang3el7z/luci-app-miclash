import * as errors from 'miclash.errors';
import * as operations from 'miclash.operations';
import * as settings from 'miclash.settings';
import * as storage from 'miclash.storage';
import * as service from 'miclash.service';
import * as config from 'miclash.config';
import * as state from 'miclash.state';
import * as application from 'miclash.application';
import * as api from 'miclash.api';
import * as memory from 'miclash.memory';
import * as devices from 'miclash.devices';
import * as notify from 'miclash.notify';
import * as notification_settings from 'miclash.notification-settings';
import * as telegram from 'miclash.telegram';
import * as mutation_lock from 'miclash.mutation_lock';
import * as reconcile_adapter from 'miclash.reconcile-adapter';
import * as network from 'miclash.network';
import * as interface_scope from 'miclash.interface-scope';
import * as subscription from 'miclash.subscription';
import * as scheduler from 'miclash.scheduler';
import * as updates from 'miclash.updates';
import * as http from 'miclash.http';
import * as redact from 'miclash.redact';
import * as mihomo_api from 'miclash.mihomo-api';
import * as diagnostics from 'miclash.diagnostics';
import * as route_test from 'miclash.route-test';
import * as routing from 'miclash.routing';
import * as platform from 'miclash.platform';
import * as app_update_scheduler from 'miclash.app-update-scheduler';
import * as device_vendor_update from 'miclash.device-vendor-update';

function clone(value) {
	try { return json(sprintf('%J', value)); }
	catch (error) { errors.fail('INVALID_ARGUMENT'); }
};

function memory_download(runtime, content) {
	if (type(content) != 'string') errors.fail('INVALID_RESPONSE');
	let size = length(content), sha256 = runtime.digest.sha256(content), closed = false;
	if (!match(sha256, /^[0-9a-f]{64}$/)) errors.fail('INTERNAL');
	return {
		size, sha256,
		read: (offset, amount) => {
			if (closed || type(offset) != 'int' || type(amount) != 'int' || offset < 0 ||
			    amount < 0 || offset > size || amount > size - offset)
				errors.fail('INVALID_ARGUMENT');
			return substr(content, offset, amount);
		},
		finish: () => {
			if (closed || runtime.digest.sha256(content) != sha256) errors.fail('CORRUPT_STATE');
			return { size, sha256 };
		},
		close: () => { if (closed) return false; closed = true; content = null; return true; }
	};
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

function memory_options(settings) {
	if (type(settings) != 'object' || type(settings.enabled) != 'bool')
		errors.fail('INVALID_ARGUMENT');
	let result = {};
	for (let name, value in settings)
		if (name != 'enabled') result[name] = value;
	return result;
};

export function bounded_logs(runtime) {
	let popen = runtime.fs?.popen ?? require('fs').popen;
	if (type(popen) != 'function') return '';
	let pipe = null, output = '';
	try {
		pipe = popen("/sbin/logread 2>/dev/null | /bin/grep -E '(^|[[:space:]])(miclash|mihomo|clash(-rules|-hotplug)?)(\\[[0-9]+\\])?:[[:space:]]'", 'r');
		if (pipe == null) return '';
		while (true) {
			let chunk = pipe.read(4096);
			if (type(chunk) != 'string' || !length(chunk)) break;
			output += chunk;
			if (length(output) > 262144)
				output = substr(output, length(output) - 262144);
		}
	}
	catch (error) { output = ''; }
	if (pipe != null) try { pipe.close(); } catch (error) { output = ''; }
	let selected = [];
	for (let line in split(output, '\n'))
		if (match(lc(line), /(^|[ \t])(clash(-rules|-hotplug)?|miclash|mihomo)(\[[0-9]+\])?:[ \t]/))
			push(selected, substr(redact.sanitize(line), 0, 2048));
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

function pretty_release_version(source) {
	let found = match(release_value(source, 'PRETTY_NAME'),
		/([0-9]+(\.[0-9]+)+([.-][0-9A-Za-z]+)?)/);
	return found == null ? '' : substr(found[1], 0, 128);
};

export function parse_openwrt_version(openwrt_release, os_release) {
	let primary = type(openwrt_release) == 'string' ? openwrt_release : '';
	let fallback = type(os_release) == 'string' ? os_release : '';
	let primary_distrib = release_value(primary, 'DISTRIB_RELEASE');
	let fallback_distrib = release_value(fallback, 'DISTRIB_RELEASE');
	if (length(primary_distrib) && primary_distrib != 'SNAPSHOT') return primary_distrib;
	if (length(fallback_distrib) && fallback_distrib != 'SNAPSHOT') return fallback_distrib;
	for (let source in [ primary, fallback ]) {
		let version = release_value(source, 'VERSION_ID');
		if (length(version)) return version;
	}
	for (let source in [ primary, fallback ]) {
		let version = pretty_release_version(source);
		if (length(version)) return version;
	}
	return primary_distrib || fallback_distrib;
};

function normalized_mihomo_version(value) {
	if (type(value) != 'string' || length(value) > 128 || match(value, /[[:cntrl:]]/))
		return '';
	let found = match(value,
		/^v?([0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z][0-9A-Za-z.-]*)?)$/);
	return found == null ? '' : substr(found[1], 0, 64);
};

function binary_mihomo_version(runtime) {
	let popen = runtime.fs?.popen ?? require('fs').popen;
	if (type(popen) != 'function') return '';
	let pipe = null, output = '';
	try {
		pipe = popen('/opt/clash/bin/clash -v 2>&1', 'r');
		if (pipe == null) return '';
		let chunk = null;
		while ((chunk = pipe.read(128)) != null && length(chunk)) {
			output += chunk;
			if (length(output) > 512) {
				pipe.close();
				pipe = null;
				return '';
			}
		}
		let status = pipe.close();
		pipe = null;
		if (status != 0) return '';
	}
	catch (error) {
		if (pipe != null) try { pipe.close(); } catch (close_error) {}
		return '';
	}
	let found = match(trim(output),
		/^(Mihomo|Clash) Meta v?([0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z][0-9A-Za-z.-]*)?)([[:space:]]|$)/);
	return found == null ? '' : substr(found[2], 0, 64);
};

export function mihomo_version(runtime, core) {
	if (core?.type != 'file' || core.nlink != 1 || (core.uid != null && core.uid != 0) ||
	    runtime.fs?.realpath('/opt/clash/bin/clash') != '/opt/clash/bin/clash')
		return '';
	let response = null;
	try {
		response = mihomo_api.request(runtime, 'GET', '/version', null, 'config.yaml');
	}
	catch (error) { response = null; }
	let version = response?.ok === true
		? normalized_mihomo_version(response?.data?.version) : '';
	return length(version) ? version : binary_mihomo_version(runtime);
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
	let os_release = bounded_file(runtime, '/etc/os-release', 4096);
	let model = trim(bounded_file(runtime, '/tmp/sysinfo/model', 256));
	let mac = stable_mac(runtime);
	let identifier = runtime.digest.sha256(mac + '|' + model);
	if (type(identifier) != 'string' || !match(identifier, /^[0-9a-f]{64}$/))
		errors.fail('INTERNAL');
	let core = null;
	try { core = runtime.fs?.lstat('/opt/clash/bin/clash'); }
	catch (error) { core = null; }
	let package_manager = platform.detect_package_manager(runtime);
	return {
		app_version: substr(runtime.app_version ?? '', 0, 64),
		mihomo: { installed: core?.type == 'file', version: mihomo_version(runtime, core) },
		openwrt_version: parse_openwrt_version(release, os_release),
		architecture: release_value(release, 'DISTRIB_ARCH'),
		model: substr(model, 0, 128), hwid: substr(identifier, 0, 14), package_manager
	};
};

function bounded_network_interfaces(runtime, settings_domain) {
	return interface_scope.detect(runtime, settings_domain.get());
};

export function effective_network_settings(runtime, wanted) {
	return interface_scope.effective_settings(wanted, interface_scope.detect(runtime, wanted));
};

export function device_external_interfaces(snapshot) {
	let wan = snapshot?.detected_wan;
	return type(wan) == 'string' && length(wan) ? [ wan ] : [];
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
				if (runtime.reconcile?.run?.('ruleset-whitelist') == null)
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
		operations, settings, storage, service, config, state, application,
		api, memory, devices, notify, notification_settings, telegram, mutation_lock,
		reconcile_adapter, network, interface_scope, subscription, scheduler, updates, http, diagnostics, route_test, routing,
		mihomo_api, app_update_scheduler, device_vendor_update,
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
		let configuration = modules.config.create(runtime, operation_manager);
		let settings_domain = {
			get: () => modules.settings.load(runtime),
			validate: (patch) => modules.settings.validate_patch(patch),
			set: (patch) => modules.settings.save(runtime, patch)
		};
		let desired = effective_network_settings(runtime, settings_domain.get());
		let device_app = null;
		let native_network = modules.network.create(runtime);
		let policy_network = {
			apply: (settings) => {
				if (device_app == null) errors.fail('HEALTH_FAILED');
				let timestamp = int(runtime.clock.now() / 1000);
				let device_policies = modules.devices.active_device_policies(device_app, timestamp);
				let effective = modules.interface_scope.effective_settings(settings,
					modules.interface_scope.detect(runtime, settings));
				return native_network.apply(effective, { device_policies });
			},
			cleanup: (settings) => native_network.cleanup(settings)
		};
		let reconcile_settings = {
			get: () => effective_network_settings(runtime, settings_domain.get()),
			set: (patch) => {
				let saved = settings_domain.set(patch);
				desired = effective_network_settings(runtime, saved);
				if (state_model != null) state_model.set_desired(saved);
				return saved;
			}
		};
		if (runtime.reconcile == null)
			runtime.reconcile = modules.reconcile_adapter.create({
				operations: operation_manager, service: service_adapter,
				settings: reconcile_settings, guard: runtime.guard_control,
				network: policy_network,
				clock: runtime.clock, events: runtime.events
			});
		let notification_settings = clone(desired.notifications);
		let notifier = modules.notify.create(runtime,
			modules.notification_settings.notifier_config(notification_settings));
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
			let configured = modules.notification_settings.telegram_config(notification_settings);
			if (notifications_closed || telegram_controller == null || !configured.enabled)
				return false;
			let channel = modules.notify.telegram_channel(telegram_controller);
			channel.types = clone(configured.types);
			telegram_channel_unsubscribe = notifier.subscribe(channel);
			return true;
		};
		function prepare_notification_settings(next) {
			if (notifications_closed) errors.fail('HEALTH_FAILED');
			let configured = clone(next);
			let notifier_settings = modules.notification_settings.notifier_config(configured);
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
			enabled: false, token: '', user_id: '', poll_timeout_seconds: 25
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
				let previous = clone(telegram_settings);
				telegram_settings = clone(next);
				try {
					if (next.enabled) {
						telegram_controller.configure();
						if (!telegram_controller.status().running &&
						    telegram_controller.start() !== true)
							errors.fail('HEALTH_FAILED');
					}
					else if (telegram_controller.status().running &&
					         telegram_controller.stop() !== true)
						errors.fail('HEALTH_FAILED');
				}
				catch (error) {
					telegram_settings = previous;
					errors.fail(errors.normalize(error).code);
				}
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
			status: () => modules.memory.live_status(guard, memory_enabled,
				state_model?.snapshot()?.observed?.service),
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
		device_app = { ...runtime, timezones: timezone_adapter, device_cache: {},
			external_interfaces: () => device_external_interfaces(
				bounded_network_interfaces(runtime, settings_domain)) };
		let devices_closed = false;
		function apply_device_policy(stage) {
			if (runtime.reconcile?.apply?.('device-policy', stage) !== true)
				errors.fail('HEALTH_FAILED');
			return true;
		};
		function mutate_device_policy(callback, stage) {
			let strict = false;
			try {
				let guard_on = settings_domain.get()?.guard?.enabled === true ||
					runtime.guard_control?.is_latched?.() === true;
				if (guard_on) {
					if (type(runtime.guard_control?.protect_strict) != 'function' ||
					    runtime.guard_control.protect_strict() !== true)
						errors.fail('HEALTH_FAILED');
					strict = true;
				}
				let result = callback();
				apply_device_policy(stage);
				return result;
			}
			catch (error) {
				if (strict) try { runtime.guard_control.protect(); } catch (restore_error) {}
				errors.fail(errors.normalize(error).code);
			}
		};
		let devices_domain = {
			list: () => {
				if (devices_closed) errors.fail('HEALTH_FAILED');
				let wanted = settings_domain.get();
				return modules.devices.discover_effective(device_app,
					modules.interface_scope.resolve(wanted,
						modules.interface_scope.detect(runtime, wanted)));
			},
			timezones: () => { if (devices_closed) errors.fail('HEALTH_FAILED'); return modules.devices.timezones(device_app); },
			policy_list: () => { if (devices_closed) errors.fail('HEALTH_FAILED'); return modules.devices.policy_list(device_app); },
			policy_set: (policy, stage) => {
				if (devices_closed) errors.fail('HEALTH_FAILED');
				return mutate_device_policy(() => modules.devices.policy_set(device_app, policy), stage);
			},
			policy_delete: (id, revision, stage) => {
				if (devices_closed) errors.fail('HEALTH_FAILED');
				return mutate_device_policy(() => modules.devices.policy_delete(device_app, id, revision), stage);
			},
			close: () => { if (devices_closed) return false; devices_closed = true; return true; }
		};
		push(close_domains, devices_domain);

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
		let lifecycle_service = {
			...service_adapter,
			start: () => runtime.reconcile.start('service-start'),
			stop: () => runtime.reconcile.stop('service-stop'),
			reload: () => runtime.reconcile.reload('service-reload'),
			restart_service: () => runtime.reconcile.restart('service-restart')
		};
		let app = modules.application.create({
			operations: operation_manager,
			settings: settings_domain,
			service: lifecycle_service,
			config: configuration,
			state: state_model,
			memory: memory_domain,
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
		let subscription_scheduler_domain = modules.scheduler.create({
			runtime, operations: operation_manager, settings: domain_settings,
			subscription: subscription_domain
		});
		push(close_domains, { close: () => subscription_scheduler_domain.stop() });
		if (subscription_scheduler_domain.start() !== true)
			errors.fail('INTERNAL');
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
		let app_update_domain = modules.app_update_scheduler.create({
			runtime, operations: operation_manager, updates: updates_domain,
			settings: domain_settings
		});
		push(close_domains, app_update_domain);
		if (app_update_domain.start() !== true)
			errors.fail('INTERNAL');
		let device_vendor_domain = modules.device_vendor_update.create({
			runtime, http: modules.http
		});
		push(close_domains, device_vendor_domain);
		if (device_vendor_domain.start() !== true)
			errors.fail('INTERNAL');
		app.logs_read = (arguments) => bounded_log_page(runtime, arguments);
		app.system_info = () => bounded_system_info(runtime);
		app.network_interfaces = () => bounded_network_interfaces(runtime, settings_domain);
		app.ruleset_list = () => ruleset_list(runtime);
		app.ruleset_read = (arguments) => ruleset_read(runtime, arguments.name);
		app.ruleset_write = (arguments) => ruleset_write(runtime, operation_manager, arguments, false);
		app.ruleset_delete = (arguments) => ruleset_delete(runtime, operation_manager, arguments);
		app.ruleset_apply_whitelist = (arguments) => ruleset_write(runtime, operation_manager, arguments, true);
		app.subscription_get = (arguments) => subscription_domain.get(arguments.profile);
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
		app.config_external_adopt = (arguments) => configuration.adopt_external(
			arguments.profile, arguments.source);
		function last_repair() {
			let records = operation_manager.list(), result = { state: 'none' };
			for (let index = length(records) - 1; index >= 0; index--)
				if (records[index]?.kind == 'system.reconcile' ||
				    records[index]?.kind == 'memory.recovery') {
					result = records[index]; break;
				}
			return result;
		};
		let diagnostics_domain = modules.diagnostics.create({ runtime, sources: {
			versions: () => { let info = bounded_system_info(runtime); return {
				miclash: info.app_version, mihomo: info.mihomo.version }; },
			architecture: () => bounded_system_info(runtime).architecture,
			state: app.status, health: app.health, memory: app.memory_status,
			updates: () => ({ ...updates_domain.status(),
				automatic_config: subscription_scheduler_domain.status(),
				automatic_miclash: app_update_domain.status(),
				device_vendors: device_vendor_domain.status() }),
			settings: settings_domain.get,
			last_repair,
			config: () => configuration.read_active('config.yaml'),
			process: () => service_adapter.observe('config.yaml'),
			logs: () => bounded_logs(runtime), uci: settings_domain.get,
			operations: () => operation_manager.list()
		} });
		app.diagnostics_summary = () => diagnostics_domain.summary();
		app.diagnostics_create_report = () => diagnostics_domain.create_report();
		app.diagnostics_route_test = (arguments) => {
			let persisted = settings_domain.get(), snapshot = modules.interface_scope.detect(runtime, persisted),
				projection = modules.interface_scope.resolve(persisted, snapshot),
				wanted = modules.interface_scope.effective_settings(persisted, snapshot),
				device_policies = [], interface_policies = [],
				config_content = configuration.read_active('config.yaml');
			if (arguments.device != null) {
				let effective = modules.devices.effective({ ...device_app,
					core_available: runtime.core_available }, {
					mac: arguments.device, interfaces: arguments.interface == null
						? [] : [ arguments.interface ], timestamp: int(runtime.clock.now() / 1000)
				}, projection);
				push(device_policies, { mac: arguments.device, decision: uc(effective.action) });
			}
			// Diagnose the queried interface from the exact projection used to compile
			// nftables. Supplying the queried fallback is important: in explicit mode an
			// unmatched ingress is DIRECT, while in exclude mode it is PROXY.
			if (arguments.interface != null)
				push(interface_policies, { name: arguments.interface,
					decision: modules.network.interface_decision(wanted, arguments.interface) });
			function dns_values(reply, record_type) {
				if (reply?.ok !== true) errors.fail('HEALTH_FAILED');
				let data = reply.data;
				if (type(data) != 'object' || type(data.Status) != 'int')
					errors.fail('INVALID_RESPONSE');
				if (data.Status != 0) return [];
				if (data.Answer == null) return [];
				if (type(data.Answer) != 'array' || length(data.Answer) > 32)
					errors.fail('INVALID_RESPONSE');
				let values = [];
				for (let answer in data.Answer) {
					if (type(answer) != 'object' || type(answer.type) != 'int' ||
					    type(answer.data) != 'string' || length(answer.data) > 253)
						errors.fail('INVALID_RESPONSE');
					if (answer.type == record_type) push(values, answer.data);
				}
				return values;
			};
			let engine = modules.route_test.create({ runtime, profile: 'config.yaml',
				config_content,
				desired: () => ({ guard: wanted.guard, devices: device_policies,
					interfaces: interface_policies,
					proxy_servers: modules.route_test.proxy_servers(config_content) }),
				observed: () => ({ routing: modules.routing.observe(runtime) }),
				dns_answers: (name) => {
					let values = [], seen = {};
					for (let item in [
						...dns_values(modules.mihomo_api.dns_query(runtime, name, 'A',
							'config.yaml', config_content), 1),
						...dns_values(modules.mihomo_api.dns_query(runtime, name, 'AAAA',
							'config.yaml', config_content), 28)
					]) {
						if (seen[item]) continue;
						if (length(values) >= 16) errors.fail('RESPONSE_TOO_LARGE');
						seen[item] = true; push(values, item);
					}
					return values;
				}
			});
			return engine.run(arguments);
		};
		if (type(desired.telegram) == 'object') {
			let telegram_app = {
				runtime, http: modules.http, operations: operation_manager,
				logger: runtime.logger, audit: runtime.audit,
				boot_id: () => {
					let value = runtime.fs.readfile('/proc/sys/kernel/random/boot_id');
					if (type(value) != 'string') errors.fail('INTERNAL');
					value = trim(value);
					if (!match(value, /^[A-Za-z0-9._-]{1,128}$/)) errors.fail('INTERNAL');
					return value;
				},
				daemon_ready: () => {
					try { return type(state_model.snapshot()) == 'object'; }
					catch (error) { return false; }
				},
				operation_postcheck: (record) => {
					if (record?.state != 'success') return false;
					if (record.kind == 'settings.set' || record.kind == 'subscription.set_url')
						return true;
					if (record.kind == 'updates.miclash' || record.kind == 'updates.mihomo' ||
					    record.kind == 'updates.mihomo.rollback') {
						let update = updates_domain.status();
						if (update.operation_id == record.id && update.postcheck == 'stopped')
							return service_adapter.observe('config.yaml').running === false;
						if (update.operation_id == record.id && update.postcheck != 'ready')
							return false;
						// After a miclashd restart the volatile update status is gone, but a
						// successful journal record already proves that the updater completed
						// its explicit ready/stopped postcheck. Re-observe the current state so
						// Telegram never reports success for an ambiguous service transition.
						let observed = service_adapter.observe('config.yaml');
						if (observed.running === false)
							return update.operation_id != record.id;
					}
					if (record.kind == 'service.stop')
						return service_adapter.observe('config.yaml').running === false;
					if (record.kind == 'guard.transition') {
						let enabled = settings_domain.get()?.guard?.enabled === true;
						try { return runtime.guard_control?.verify?.(enabled) === true; }
						catch (error) { return false; }
					}
					let fresh;
					try { fresh = state_model.observe('config.yaml'); }
					catch (error) { return false; }
					return fresh?.service?.running === true && fresh?.readiness?.ok === true;
				},
				settings_get: app.settings_get,
				status: app.status, health: app.health,
				system_info: app.system_info,
				updates_status: () => ({ ...updates_domain.status(),
					automatic_config: subscription_scheduler_domain.status(),
					automatic_miclash: app_update_domain.status() }),
				subscription_status: () => subscription_domain.get_redacted('config.yaml'),
				subscription_operation: () => {
					let records = operation_manager.list();
					for (let index = length(records) - 1; index >= 0; index--)
						if (records[index]?.kind == 'subscription.update') return records[index];
					return null;
				},
				guard_status: () => {
					let enabled = settings_domain.get()?.guard?.enabled === true;
					try {
						return runtime.guard_control?.verify?.(enabled) === true ?
							(enabled ? 'enabled' : 'disabled') : 'failed';
					}
					catch (error) { return 'failed'; }
				},
				memory_status: app.memory_status,
				diagnostics_summary: () => ({ status: app.status(), health: app.health(),
					memory: app.memory_status() }),
				logs_read: () => bounded_logs(runtime),
				diagnostics_route_test: app.diagnostics_route_test,
				service_start: app.service_start, service_stop: app.service_stop,
				service_restart: app.service_restart, service_reload: app.service_reload,
				reboot: runtime.reboot,
				subscription_update: (url, source) => url == null
					? subscription_domain.update({ profile: 'config.yaml', url: null }, source)
					: subscription_domain.replace({ profile: 'config.yaml', url }, source),
				update_miclash: (source) => updates_domain.update_miclash({
					version: null, channel: null
				}, source),
				update_mihomo: (source) => updates_domain.update_mihomo({
					version: null, channel: null
				}, source),
				settings_set: app.settings_set,
				guard_transition
			};
			telegram_controller = modules.telegram.create(telegram_app);
			app.telegram_ingest = (update) => telegram_controller.ingest(update);
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
			uploads: {},
			downloads: {
				report: (id, metadata) => {
					let report = diagnostics_domain.read_report({ id,
						format: metadata?.format ?? 'json' });
					return memory_download(runtime, report.content);
				}
			}
		});
		let published = modules.api.register(connection, app, transfers);
		let closed = false;
		return {
			app,
			state: state_model,
			connection,
			published,
			transfers,
			domains: { memory: memory_domain,
				devices: devices_domain, notifications: notifications_domain,
				subscription_scheduler: subscription_scheduler_domain,
				app_update: app_update_domain, device_vendors: device_vendor_domain },
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
