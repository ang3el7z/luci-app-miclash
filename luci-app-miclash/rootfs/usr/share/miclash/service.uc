import { fail } from 'miclash.errors';
import { profile_name } from 'miclash.schema';
import * as mihomo_api from 'miclash.mihomo-api';

const SERVICE = 'clash';

function component(name, state, detail) {
	let record = { component: name, state, ready: state == 'ready' };
	if (detail != null)
		record.detail = detail;
	return record;
};

export function create(runtime) {
	if (type(runtime?.fs?.lstat) != 'function' || type(runtime?.ubus?.connect) != 'function' ||
	    type(runtime?.clock?.now) != 'function' || type(runtime?.clock?.sleep) != 'function' ||
	    type(runtime?.http?.request) != 'function')
		fail('INVALID_ARGUMENT');
	let poll_interval = runtime.service_options?.poll_interval_ms ?? 100;
	if (type(poll_interval) != 'int' || poll_interval < 1 || poll_interval > 1000)
		fail('INVALID_ARGUMENT');

	function profile(value) { return profile_name(value ?? 'config.yaml'); };
	function connection() {
		let result = runtime.ubus.connect();
		if (result == null || type(result.call) != 'function')
			fail('INTERNAL');
		return result;
	};
	function observe(value) {
		profile(value);
		let reply;
		try { reply = connection().call('service', 'list', { name: SERVICE, verbose: true }); }
		catch (error) { return { state: 'unknown', running: false }; }
		let instances = reply?.[SERVICE]?.instances;
		if (type(instances) != 'object')
			return { state: 'unknown', running: false };
		for (let name, instance in instances)
			if (instance?.running === true)
				return { state: 'running', running: true, pid: type(instance.pid) == 'int' ? instance.pid : null };
		let kernel = runtime.fs.lstat('/opt/clash/bin/clash');
		if (kernel?.type != 'file' || kernel.nlink != 1)
			return { state: 'missing_kernel', running: false };
		return { state: 'stopped', running: false };
	};
	function service_state(spawn) {
		try { connection().call('service', 'state', { name: SERVICE, spawn }); }
		catch (error) { fail('HEALTH_FAILED'); }
	};
	function start(value) {
		value = profile(value);
		let observed = observe(value);
		if (observed.state == 'missing_kernel')
			fail('NOT_FOUND');
		if (observed.running)
			return { changed: false, state: 'running' };
		if (observed.state != 'stopped')
			fail('HEALTH_FAILED');
		service_state(true);
		return { changed: true, state: 'starting' };
	};
	function stop(value) {
		value = profile(value);
		let observed = observe(value);
		if (observed.state == 'stopped')
			return { changed: false, state: 'stopped' };
		if (observed.state != 'running')
			fail('HEALTH_FAILED');
		service_state(false);
		return { changed: true, state: 'stopping' };
	};
	function reload(value, controller_config) {
		value = profile(value);
		return mihomo_api.request(runtime, 'PUT', '/configs?force=true', {
			path: '/opt/clash/' + value
		}, value, controller_config);
	};
	function restart_core(value) {
		value = profile(value);
		return mihomo_api.request(runtime, 'POST', '/restart', {}, value);
	};
	function wait_stopped(value, deadline) {
		while (true) {
			if (observe(value).state == 'stopped')
				return true;
			let now = runtime.clock.now();
			if (now >= deadline)
				return false;
			runtime.clock.sleep(min(poll_interval, deadline - now));
		}
	};
	function restart_service(value) {
		value = profile(value);
		let observed = observe(value);
		if (observed.state == 'missing_kernel')
			fail('NOT_FOUND');
		if (observed.state == 'unknown')
			fail('HEALTH_FAILED');
		service_state(false);
		if (!wait_stopped(value, runtime.clock.now() + 5000))
			fail('HEALTH_FAILED');
		service_state(true);
		return { changed: true, state: 'restarting' };
	};
	function observer_record(name) {
		let observer = runtime.observers?.[name];
		if (type(observer) != 'function')
			return component(name, 'unknown');
		let result;
		try { result = observer(); }
		catch (error) { return component(name, 'failed'); }
		return component(name, result?.ready === true ? 'ready' : (result?.state ?? 'failed'));
	};
	function once(value, options) {
		let records = [];
		let observed = observe(value);
		if (options.stopped) {
			let process = component('process', observed.state);
			process.ready = observed.state == 'stopped';
			push(records, process);
			return records;
		}
		push(records, component('process', observed.running ? 'ready' : observed.state));
		if (!observed.running)
			return records;
		let api;
		try { api = mihomo_api.request(runtime, 'GET', '/version', null, value); }
		catch (error) { api = null; }
		push(records, component('api', api?.ok === true ? 'ready' : 'failed'));
		if (api?.ok !== true)
			return records;
		push(records, observer_record('dns'));
		if (options.tun_required)
			push(records, observer_record('tun'));
		push(records, observer_record('policy'));
		push(records, observer_record('forward'));
		return records;
	};
	function all_ready(records) {
		if (!length(records)) return false;
		for (let record in records)
			if (!record.ready) return false;
		return true;
	};
	function wait_ready(deadline, value, options) {
		value = profile(value);
		options ??= {};
		if (type(deadline) != 'int' || deadline < runtime.clock.now() ||
		    type(options) != 'object')
			fail('INVALID_ARGUMENT');
		let records;
		while (true) {
			records = once(value, options);
			if (all_ready(records))
				return { ok: true, timed_out: false, components: records };
			let now = runtime.clock.now();
			if (now >= deadline)
				return { ok: false, timed_out: true, components: records };
			runtime.clock.sleep(min(poll_interval, deadline - now));
		}
	};

	return {
		observe, start, stop, reload, restart_core, restart_service, wait_ready,
		health: (value) => wait_ready(runtime.clock.now() + 5000, value).ok
	};
};
