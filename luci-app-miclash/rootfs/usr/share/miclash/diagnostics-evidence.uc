import * as errors from 'miclash.errors';

const SECTION_NAMES = [ 'procd', 'packages', 'dns', 'firewall', 'routes', 'interfaces',
	'tun_tproxy', 'guard', 'schedulers', 'memory', 'operations', 'recovery' ];

function unavailable(code, message) {
	return { state: 'unavailable', code: code ?? 'UNAVAILABLE',
		message: message ?? 'Collector unavailable' };
};

function read_command(runtime, command, limit) {
	let popen = runtime?.fs?.popen ?? require('fs').popen;
	if (type(popen) != 'function') return null;
	let pipe = null, output = '';
	try {
		pipe = popen(command, 'r');
		if (pipe == null) return null;
		while (true) {
			let chunk = pipe.read(4096);
			if (type(chunk) != 'string' || !length(chunk)) break;
			if (limit != null && length(output) + length(chunk) > limit)
				chunk = substr(chunk, 0, limit - length(output));
			output += chunk;
			if (limit != null && length(output) >= limit) break;
		}
		let closed = type(pipe.close) == 'function' ? pipe.close() : null;
		pipe = null;
		if (closed != 0) return null;
		return output;
	}
	catch (error) {
		if (pipe != null) try { pipe.close(); } catch (ignored) {}
		return null;
	}
};

function section_value(runtime, name, collector) {
	if (type(collector) == 'function') {
		try {
			let value = collector();
			return value == null ? unavailable('UNAVAILABLE', name + ' collector unavailable') : value;
		}
		catch (error) { return unavailable('UNAVAILABLE', name + ' collector unavailable'); }
	}
	let commands = {
		procd: '/bin/ubus call service list', packages: '/usr/bin/opkg status',
		dns: '/bin/ubus call network.interface dump', firewall: '/usr/sbin/nft list ruleset',
		routes: '/sbin/ip route show table all', interfaces: '/sbin/ip -details link show',
		tun_tproxy: '/sbin/ip rule show', guard: '/bin/ubus call service list',
		schedulers: '/bin/ubus call service list', memory: '/bin/cat /proc/meminfo',
		operations: '/bin/ubus call service list', recovery: '/bin/ubus call service list'
	};
	let output = read_command(runtime, commands[name], 65536);
	return output == null ? unavailable('UNAVAILABLE', name + ' collector unavailable') :
		{ state: 'present', command: commands[name], output };
};

function log_entry(line) {
	let header = match(line, /^([^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+)[[:space:]]+[^[:space:]]+[[:space:]]+([^:[:space:]]+)(\[[0-9]+\])?:[[:space:]]*(.*)$/);
	if (!header) return { timestamp: null, facility: 'syslog', severity: 'info', component: 'kernel', message: line };
	let message = header[4], lowered = lc(message);
	return { timestamp: header[1], facility: 'syslog',
		severity: match(lowered, /(error|failed|oom|out of memory|crash)/) ? 'error' :
			(match(lowered, /(warn|denied|retry)/) ? 'warning' : 'info'),
		component: replace(lc(header[2]), /\[[0-9]+\]$/, ''), message };
};

function relevant_log(line) {
	let lowered = lc(line);
	return index(lowered, 'miclash') >= 0 || index(lowered, 'mihomo') >= 0 ||
		index(lowered, 'clash') >= 0 || index(lowered, 'procd') >= 0 ||
		index(lowered, 'dnsmasq') >= 0 || index(lowered, 'netifd') >= 0 ||
		index(lowered, 'firewall') >= 0 || index(lowered, 'fw4') >= 0 ||
		(index(lowered, 'kernel:') >= 0 && (index(lowered, 'tun') >= 0 ||
		index(lowered, 'tproxy') >= 0 || index(lowered, 'route') >= 0 ||
		index(lowered, 'oom') >= 0 || index(lowered, 'out of memory') >= 0 ||
		index(lowered, 'crash') >= 0));
};

export function create(runtime, collectors) {
	if (type(runtime) != 'object') errors.fail('INVALID_ARGUMENT');
	collectors = collectors ?? {};
	return {
		sections: () => map(SECTION_NAMES, (name) => ({ name,
			value: section_value(runtime, name, collectors[name]) })),
		logs: () => {
			let source = read_command(runtime, '/sbin/logread');
			if (source == null) return [];
			let result = [];
			for (let line in split(source, '\n'))
				if (length(line) && relevant_log(line)) push(result, log_entry(line));
			return result;
		}
	};
};
