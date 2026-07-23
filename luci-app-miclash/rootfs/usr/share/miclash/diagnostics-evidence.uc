import * as errors from 'miclash.errors';

const SECTION_NAMES = [ 'procd', 'packages', 'dns', 'firewall', 'routes', 'interfaces',
	'tun_tproxy', 'guard', 'schedulers', 'memory', 'operations', 'recovery' ];
const SECTION_LIMIT = 65536;
const MAX_RECORDS = 256;

function clone(value) {
	try { return json(sprintf('%J', value)); }
	catch (error) { return value; }
};

function unavailable(name, result) {
	let value = {
		state: 'unavailable',
		code: result?.code ?? 'COLLECTION_UNAVAILABLE',
		message: result?.message ?? (name + ' collector unavailable')
	};
	if (type(result?.exit_code) == 'int') value.exit_code = result.exit_code;
	return value;
};

function present(source, values) {
	return { state: 'present', source, ...(values ?? {}) };
};

function capture(runtime, command, limit) {
	let popen = runtime?.fs?.popen ?? require('fs').popen;
	if (type(popen) != 'function')
		return { ok: false, code: 'COLLECTION_UNAVAILABLE',
			message: 'Command collection is unavailable' };
	let pipe = null, output = '', oversized = false;
	try {
		pipe = popen(command, 'r');
		if (pipe == null)
			return { ok: false, code: 'COLLECTION_UNAVAILABLE',
				message: 'Command is unavailable' };
		while (true) {
			let chunk = pipe.read(4096);
			if (type(chunk) != 'string' || !length(chunk)) break;
			if (limit != null && length(output) + length(chunk) > limit) {
				oversized = true;
				break;
			}
			output += chunk;
		}
		let closed = type(pipe.close) == 'function' ? pipe.close() : null;
		pipe = null;
		if (oversized)
			return { ok: false, code: 'RESPONSE_TOO_LARGE',
				message: 'Command output exceeds the evidence limit' };
		if (closed != 0)
			return { ok: false, code: 'COLLECTION_UNAVAILABLE',
				message: 'Command collection failed', exit_code: closed };
		return { ok: true, output };
	}
	catch (error) {
		if (pipe != null) try { pipe.close(); } catch (ignored) {}
		return { ok: false, code: 'COLLECTION_UNAVAILABLE',
			message: 'Command collection failed' };
	}
};

function json_document(name, source, result) {
	if (result?.ok !== true) return unavailable(name, result);
	try {
		let value = json(result.output);
		if (type(value) != 'object') errors.fail('INVALID_RESPONSE');
		return value;
	}
	catch (error) {
		return unavailable(name, { code: 'INVALID_RESPONSE',
			message: name + ' returned malformed JSON' });
	}
};

function bounded_strings(value) {
	let result = [];
	if (type(value) != 'array') return result;
	for (let item in value) {
		if (length(result) >= MAX_RECORDS) break;
		if (type(item) == 'string' && length(item) <= 1024) push(result, item);
	}
	return result;
};

function collect_procd(runtime) {
	let result = capture(runtime,
		'/bin/ubus call service list \'{"name":"miclash"}\'', SECTION_LIMIT);
	let document = json_document('procd', 'ubus', result);
	if (document?.state == 'unavailable') return document;
	let service = document.miclash;
	return present('ubus', {
		registered: type(service) == 'object',
		service: type(service) == 'object' ? service : null
	});
};

function opkg_packages(output) {
	let packages = [], current = {};
	function finish() {
		if (type(current.name) == 'string' && length(current.name))
			push(packages, current);
		current = {};
	};
	for (let raw in split(output, '\n')) {
		let line = trim(raw);
		if (!length(line)) { finish(); continue; }
		let field = match(line, /^([^:]+):[[:space:]]*(.*)$/);
		if (!field) continue;
		let name = lc(field[1]), value = field[2];
		if (name == 'package') current.name = value;
		else if (name == 'version') current.version = value;
		else if (name == 'status') current.status = value;
		else if (name == 'architecture') current.architecture = value;
	}
	finish();
	return packages;
};

function collect_packages(runtime) {
	let opkg = capture(runtime, '/usr/bin/opkg status luci-app-miclash', SECTION_LIMIT);
	if (opkg.ok !== true)
		opkg = capture(runtime, '/bin/opkg status luci-app-miclash', SECTION_LIMIT);
	if (opkg.ok === true)
		return present('opkg', { manager: 'opkg', packages: opkg_packages(opkg.output) });
	let apk = capture(runtime, '/sbin/apk info --all luci-app-miclash', SECTION_LIMIT);
	if (apk.ok === true) {
		let records = [];
		for (let line in split(apk.output, '\n'))
			if (length(trim(line)) && length(records) < MAX_RECORDS)
				push(records, trim(line));
		return present('apk', { manager: 'apk', records });
	}
	return unavailable('packages', {
		code: apk.code ?? opkg.code,
		message: 'Neither opkg nor apk package evidence is available',
		exit_code: apk.exit_code ?? opkg.exit_code
	});
};

function collect_dns(runtime) {
	let result = capture(runtime, '/bin/ubus call network.interface dump', SECTION_LIMIT);
	let document = json_document('dns', 'ubus', result);
	if (document?.state == 'unavailable') return document;
	if (type(document.interface) != 'array')
		return unavailable('dns', { code: 'INVALID_RESPONSE',
			message: 'DNS interface data is malformed' });
	let interfaces = [];
	for (let item in document.interface) {
		if (length(interfaces) >= MAX_RECORDS || type(item) != 'object' ||
		    type(item.interface) != 'string') continue;
		push(interfaces, {
			name: item.interface,
			up: item.up === true,
			dns_servers: bounded_strings(item['dns-server']),
			dns_search: bounded_strings(item['dns-search'])
		});
	}
	return present('ubus', { interfaces });
};

const IPTABLES_ANCHORS = {
	MCL_AN_PR: { table: 'mangle', hook: 'PREROUTING', prefix: 'MCL_PR_' },
	MCL_AN_OU: { table: 'mangle', hook: 'OUTPUT', prefix: 'MCL_OU_' },
	MCL_AN_TI: { table: 'filter', hook: 'INPUT', prefix: 'MCL_TI_' },
	MCL_AN_TF: { table: 'filter', hook: 'FORWARD', prefix: 'MCL_TF_' }
};

function generation_chain(name) {
	let found = match(name ?? '', /^MCL_(PR|PX|OU|TI|TF)_([0-9a-f]{12})$/);
	return found ? { prefix: 'MCL_' + found[1] + '_', id: found[2] } : null;
};

function iptables_rule(line) {
	let source = match(line, /^-A ([A-Za-z0-9_.:-]+)[ \t]+/);
	if (!source) return null;
	let verdict = match(line,
		/(^|[ \t])(-j|--jump|-g|--goto)[ \t]+([A-Za-z0-9_.:-]+)([ \t]|$)/);
	return { line, source: source[1], target: verdict ? verdict[3] : null };
};

function owned_iptables_document(output, table) {
	let entries = [], declaration_counts = {}, rules = [];
	for (let raw in split(output, '\n')) {
		let line = trim(raw);
		if (!length(line) || length(line) > 4096) continue;
		let declaration = match(line,
			/^:(MCL_AN_(PR|OU|TI|TF)|MCL_(PR|PX|OU|TI|TF)_[0-9a-f]{12}) - \[[0-9]+:[0-9]+\]$/);
		if (declaration) {
			declaration_counts[declaration[1]] =
				(declaration_counts[declaration[1]] ?? 0) + 1;
			push(entries, { kind: 'declaration', name: declaration[1], line });
			continue;
		}
		let rule = iptables_rule(line);
		if (rule != null) {
			push(rules, rule);
			push(entries, { kind: 'rule', value: rule, line });
		}
	}

	let anchors = {}, active_ids = {}, reachable = {};
	for (let name in IPTABLES_ANCHORS) {
		let contract = IPTABLES_ANCHORS[name];
		if (contract.table != table || declaration_counts[name] != 1) continue;
		let hook_line = '-A ' + contract.hook + ' -j ' + name;
		let anchor_rules = [], hook_rules = [];
		for (let rule in rules) {
			if (rule.source == name) push(anchor_rules, rule);
			if (rule.source == contract.hook && rule.target == name) push(hook_rules, rule);
		}
		if (length(hook_rules) != 1 || hook_rules[0].line != hook_line ||
		    length(anchor_rules) != 1) continue;
		let target = anchor_rules[0].target;
		let generation = generation_chain(target);
		let anchor_line = '-A ' + name + ' -j ' + target;
		if (generation == null || generation.prefix != contract.prefix ||
		    declaration_counts[target] != 1 || anchor_rules[0].line != anchor_line) continue;
		anchors[name] = { hook_line, anchor_line, target };
		active_ids[generation.id] = true;
		reachable[target] = true;
	}

	let changed = true;
	while (changed) {
		changed = false;
		for (let rule in rules) {
			if (!reachable[rule.source] || rule.target == null || reachable[rule.target]) continue;
			let source = generation_chain(rule.source), target = generation_chain(rule.target);
			if (source != null && target != null && source.id == target.id &&
			    active_ids[target.id] && declaration_counts[rule.target] == 1) {
				reachable[rule.target] = true;
				changed = true;
			}
		}
	}

	let lines = [];
	for (let entry in entries) {
		if (length(lines) >= MAX_RECORDS) break;
		if (entry.kind == 'declaration') {
			if (anchors[entry.name] != null || reachable[entry.name]) push(lines, entry.line);
			continue;
		}
		let rule = entry.value, owned = false;
		for (let name in anchors)
			if (rule.line == anchors[name].hook_line || rule.line == anchors[name].anchor_line)
				owned = true;
		if (!owned && reachable[rule.source]) {
			let target_generation = generation_chain(rule.target);
			owned = rule.target == null || index(rule.target, 'MCL_') != 0 ||
				(target_generation != null && reachable[rule.target]);
		}
		if (owned) push(lines, rule.line);
	}
	return { lines, active_ids };
};

function owned_ipset_lines(output, active_ids) {
	let lines = [];
	for (let raw in split(output, '\n')) {
		let line = trim(raw);
		if (length(lines) >= MAX_RECORDS) break;
		let owned = match(line,
			/^(create|add) MCL_(L4|F4|L6|F6)_([0-9a-f]{12})( |$)/);
		if (length(line) <= 4096 && owned && active_ids[owned[3]])
			push(lines, line);
	}
	return lines;
};

function collect_firewall(runtime) {
	let nft = capture(runtime, '/usr/sbin/nft -j list table inet miclash', SECTION_LIMIT);
	if (nft.ok === true) {
		let document = json_document('firewall', 'nft', nft);
		if (document?.state != 'unavailable' && type(document.nftables) == 'array')
			return present('nft', { backend: 'nft', table: document });
	}
	let documents = [], available = false, last_failure = nft, active_ids = {};
	for (let executable in [ '/usr/sbin/iptables-save', '/usr/sbin/ip6tables-save' ])
		for (let table in [ 'mangle', 'filter' ]) {
			let result = capture(runtime, executable + ' -t ' + table, SECTION_LIMIT);
			if (result.ok !== true) { last_failure = result; continue; }
			available = true;
			let owned = owned_iptables_document(result.output, table);
			for (let id in owned.active_ids) active_ids[id] = true;
			push(documents, {
				family: executable == '/usr/sbin/ip6tables-save' ? 'ipv6' : 'ipv4',
				table,
				lines: owned.lines
			});
		}
	if (available) {
		let sets = capture(runtime, '/usr/sbin/ipset save', SECTION_LIMIT);
		if (sets.ok === true)
			return present('iptables', {
				backend: 'iptables',
				documents,
				sets: owned_ipset_lines(sets.output, active_ids)
			});
		return {
			...unavailable('firewall', sets),
			backend: 'iptables',
			documents,
			sets: []
		};
	}
	return unavailable('firewall', {
		code: last_failure?.code,
		message: 'Owned nftables and iptables evidence is unavailable',
		exit_code: last_failure?.exit_code
	});
};

function capture_json_array(runtime, name, command) {
	let result = capture(runtime, command, SECTION_LIMIT);
	if (result.ok !== true) return { error: unavailable(name, result) };
	try {
		let values = json(result.output);
		if (type(values) != 'array') errors.fail('INVALID_RESPONSE');
		return { values };
	}
	catch (error) {
		return { error: unavailable(name, { code: 'INVALID_RESPONSE',
			message: name + ' returned malformed JSON' }) };
	}
};

function collect_routes(runtime) {
	return {
		...unavailable('routes', {
			code: 'OWNERSHIP_UNVERIFIED',
			message: 'Verified MiClash routing ownership evidence is unavailable'
		}),
		source: 'routing-ownership'
	};
};

function collect_interfaces(runtime) {
	let result = capture_json_array(runtime, 'interfaces', '/sbin/ip -j link show');
	if (result.error != null) return result.error;
	let interfaces = [];
	for (let item in result.values) {
		if (length(interfaces) >= MAX_RECORDS || type(item) != 'object' ||
		    type(item.ifname) != 'string') continue;
		push(interfaces, {
			name: item.ifname,
			state: item.operstate ?? null,
			mtu: type(item.mtu) == 'int' ? item.mtu : null,
			address: type(item.address) == 'string' ? item.address : null
		});
	}
	return present('iproute2', { interfaces });
};

function collect_tun_tproxy(runtime) {
	let link = capture_json_array(runtime, 'tun_tproxy',
		'/sbin/ip -j link show dev clash-tun');
	if (link.error != null) {
		if (link.error.exit_code == 1)
			return present('iproute2', { tun: { present: false }, tproxy_rules: [] });
		return link.error;
	}
	let routes = collect_routes(runtime);
	if (routes.state == 'unavailable') return routes;
	return present('iproute2', {
		tun: { present: length(link.values) > 0 },
		tproxy_rules: routes.rules
	});
};

function meminfo_value(output, name) {
	for (let line in split(output, '\n')) {
		let found = match(line, /^([^:]+):[ \t]+([0-9]+)[ \t]+kB$/);
		if (found && found[1] == name) return int(found[2]);
	}
	return null;
};

function collect_memory(runtime) {
	let result = capture(runtime, '/bin/cat /proc/meminfo', SECTION_LIMIT);
	if (result.ok !== true) return unavailable('memory', result);
	let total = meminfo_value(result.output, 'MemTotal');
	let available = meminfo_value(result.output, 'MemAvailable');
	if (total == null || available == null)
		return unavailable('memory', { code: 'INVALID_RESPONSE',
			message: 'Memory evidence is malformed' });
	return present('procfs', { mem_total_kib: total, mem_available_kib: available });
};

function default_section(runtime, name) {
	if (name == 'procd') return collect_procd(runtime);
	if (name == 'packages') return collect_packages(runtime);
	if (name == 'dns') return collect_dns(runtime);
	if (name == 'firewall') return collect_firewall(runtime);
	if (name == 'routes') return collect_routes(runtime);
	if (name == 'interfaces') return collect_interfaces(runtime);
	if (name == 'tun_tproxy') return collect_tun_tproxy(runtime);
	if (name == 'memory') return collect_memory(runtime);
	return unavailable(name, { message: name + ' domain adapter is unavailable' });
};

function routing_projection(name, value) {
	if (value?.state == 'unavailable') return value;
	if (type(value?.routes) != 'array' || type(value?.rules) != 'array')
		return unavailable(name, {
			code: 'OWNERSHIP_UNVERIFIED',
			message: 'Verified MiClash routing ownership evidence is unavailable'
		});
	if (value.ownership?.trusted !== true || value.ownership?.status != 'trusted')
		return unavailable(name, {
			code: 'OWNERSHIP_UNVERIFIED',
			message: 'MiClash routing ownership is not trusted'
		});
	return {
		state: 'present',
		source: value.source ?? 'routing-ownership',
		routes: filter(value.routes, (item) => item?.owned === true),
		rules: filter(value.rules, (item) => item?.owned === true),
		ownership: {
			status: 'trusted',
			trusted: true,
			transition_state: value.ownership.transition_state ?? null
		}
	};
};

function section_value(runtime, name, collector) {
	if (type(collector) != 'function') return default_section(runtime, name);
	try {
		let value = collector();
		if (value == null) return unavailable(name, null);
		if (type(value) != 'object') return present('domain', { data: value });
		if (name == 'routes') return routing_projection(name, value);
		if (name == 'tun_tproxy' && type(value.routes) == 'array' &&
		    type(value.rules) == 'array') {
			let routing = routing_projection(name, value);
			if (routing.state == 'unavailable') return routing;
			return { ...value, routes: routing.routes, rules: routing.rules,
				ownership: routing.ownership };
		}
		return value;
	}
	catch (error) {
		return unavailable(name, {
			code: errors.normalize(error).code,
			message: name + ' collector failed'
		});
	}
};

function inferred_severity(message) {
	let lowered = lc(message);
	if (match(lowered, /(error|failed|oom|out of memory|crash)/)) return 'error';
	if (match(lowered, /(warn|denied|retry)/)) return 'warning';
	return 'info';
};

function log_entry(line) {
	let openwrt = match(line,
		/^([A-Z][a-z][a-z][[:space:]]+[A-Z][a-z][a-z][[:space:]]+[0-9]+[[:space:]]+[0-9][0-9]:[0-9][0-9]:[0-9][0-9][[:space:]]+[0-9][0-9][0-9][0-9])[[:space:]]+([A-Za-z0-9_-]+)\.([A-Za-z0-9_-]+)[[:space:]]+([^:[:space:]]+)(\[[0-9]+\])?:[[:space:]]*(.*)$/);
	if (openwrt)
		return {
			timestamp: openwrt[1],
			facility: lc(openwrt[2]),
			severity: lc(openwrt[3]),
			component: replace(lc(openwrt[4]), /\[[0-9]+\]$/, ''),
			message: openwrt[6]
		};
	let legacy = match(line,
		/^([A-Z][a-z][a-z][[:space:]]+[0-9]+[[:space:]]+[0-9][0-9]:[0-9][0-9]:[0-9][0-9])[[:space:]]+[^[:space:]]+[[:space:]]+([^:[:space:]]+)(\[[0-9]+\])?:[[:space:]]*(.*)$/);
	if (legacy)
		return {
			timestamp: legacy[1],
			facility: null,
			severity: inferred_severity(legacy[4]),
			component: replace(lc(legacy[2]), /\[[0-9]+\]$/, ''),
			message: legacy[4]
		};
	return { timestamp: null, facility: null, severity: inferred_severity(line),
		component: 'unknown', message: line };
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
	let log_status = unavailable('logs', {
		code: 'COLLECTION_UNAVAILABLE',
		message: 'logread has not been collected'
	});
	return {
		sections: () => [
			...map(SECTION_NAMES, (name) => ({
				name,
				value: section_value(runtime, name, collectors[name])
			})),
			{ name: 'logs', value: clone(log_status) }
		],
		logs: () => {
			let source = capture(runtime, '/sbin/logread', null);
			if (source.ok !== true) {
				log_status = unavailable('logs', source);
				return [];
			}
			let result = [];
			for (let line in split(source.output, '\n'))
				if (length(line) && relevant_log(line)) push(result, log_entry(line));
			log_status = present('/sbin/logread', {
				records: length(result),
				oldest_timestamp: length(result) ? result[0].timestamp : null,
				newest_timestamp: length(result) ? result[length(result) - 1].timestamp : null
			});
			return result;
		},
		logs_status: () => clone(log_status)
	};
};
