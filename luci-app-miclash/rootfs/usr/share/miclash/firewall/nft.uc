import { fail } from 'miclash.errors';
import { validate, generation, quoted_set, LOCAL4, LOCAL6 } from 'miclash.firewall.common';

function add(lines, line) { push(lines, line); };
function has(values, wanted) { for (let value in values) if (value == wanted) return true; return false; };
function family_name(family) { return family == 'ipv4' ? 'ip' : 'ip6'; };

function mark_rule(mode, family, device) {
	let prefix = 'add rule inet miclash proxy meta nfproto ' + family + (device ? ' ether saddr "' + device + '"' : '');
	let target = family == 'ipv4' ? 'tproxy ip to 127.0.0.1:7894' : 'tproxy ip6 to [::1]:7894';
	if (mode == 'mixed') return [ prefix + ' meta l4proto tcp ' + target + ' meta mark set 0x1', prefix + ' meta l4proto udp meta mark set 0x3' ];
	if (mode == 'tproxy') return [ prefix + ' meta l4proto tcp ' + target + ' meta mark set 0x1', prefix + ' meta l4proto udp ' + target + ' meta mark set 0x1' ];
	return [ prefix + ' meta l4proto { tcp, udp } meta mark set 0x1' ];
};

function normalized(desired) {
	let l = [ '# MiClash intended nft contract v1', 'add table inet miclash',
		'add set inet miclash local4 { type ipv4_addr; flags interval; }',
		'add element inet miclash local4 { ' + LOCAL4 + ' }',
		'add set inet miclash local6 { type ipv6_addr; flags interval; }',
		'add element inet miclash local6 { ' + LOCAL6 + ' }',
		'add chain inet miclash prerouting { type filter hook prerouting priority mangle; policy accept; }',
		'add chain inet miclash proxy',
		'add chain inet miclash output { type route hook output priority mangle; policy accept; }' ];
	let servers4 = [], servers6 = [], fake4 = [], fake6 = [];
	for (let ip in desired.server_ips) push(index(ip, ':') >= 0 ? servers6 : servers4, ip);
	for (let cidr in desired.fakeip_cidrs) push(index(cidr, ':') >= 0 ? fake6 : fake4, cidr);
	for (let item in [ [ 'proxy_servers4', 'ipv4_addr', servers4 ], [ 'proxy_servers6', 'ipv6_addr', servers6 ],
		[ 'fakeip_whitelist4', 'ipv4_addr', fake4 ], [ 'fakeip_whitelist6', 'ipv6_addr', fake6 ] ]) if (length(item[2])) {
		add(l, 'add set inet miclash ' + item[0] + ' { type ' + item[1] + ';' + (index(item[0], 'fake') == 0 ? ' flags interval;' : '') + ' }');
		add(l, 'add element inet miclash ' + item[0] + ' { ' + join(', ', item[2]) + ' }');
	}
	let interfaces = desired.interface_mode == 'explicit' ? desired.lan : desired.wan;
	if (!length(interfaces) && desired.interface_mode == 'explicit') add(l, '# explicit interface selection empty: no client-ingress jump');
	else {
		if (length(interfaces)) add(l, 'add rule inet miclash prerouting iifname ' + quoted_set(interfaces) + (desired.interface_mode == 'explicit' ? ' jump proxy' : ' return'));
		if (desired.interface_mode == 'exclude') add(l, 'add rule inet miclash prerouting jump proxy');
	}
	for (let policy in desired.device_policies) {
		if (policy.action == 'inherit') { add(l, '# device-policy inherit ' + policy.id + ' ' + policy.mac); continue; }
		for (let family in desired.ip_families) {
			let p = 'add rule inet miclash proxy meta nfproto ' + family + ' ether saddr "' + policy.mac + '" ';
			if (policy.action == 'block') add(l, p + 'drop comment "device-policy:block:' + policy.id + '"');
			else if (policy.action == 'direct') add(l, p + 'return comment "device-policy:direct:' + policy.id + '"');
			else for (let rule in mark_rule(desired.proxy_mode, family, policy.mac)) add(l, rule);
		}
	}
	add(l, 'add rule inet miclash proxy ip daddr @local4 return');
	add(l, 'add rule inet miclash proxy ip6 daddr @local6 return');
	if (length(desired.server_ips)) {
		if (desired.guard) add(l, '# Guard ON: client proxy-server bypass intentionally omitted');
		else { if (length(servers4)) add(l, 'add rule inet miclash proxy ip daddr @proxy_servers4 return'); if (length(servers6)) add(l, 'add rule inet miclash proxy ip6 daddr @proxy_servers6 return'); }
	}
	if (length(desired.fakeip_cidrs)) {
		for (let family in desired.ip_families) {
			let set = family == 'ipv4' ? 'fakeip_whitelist4' : 'fakeip_whitelist6';
			if (!length(family == 'ipv4' ? fake4 : fake6)) continue;
			for (let rule in mark_rule(desired.proxy_mode, family, null)) add(l, replace(rule, 'meta nfproto ' + family, 'meta nfproto ' + family + ' ' + family_name(family) + ' daddr @' + set));
		}
	}
	else {
		if (desired.quic) for (let family in desired.ip_families) add(l, 'add rule inet miclash proxy meta nfproto ' + family + ' udp dport 443 reject');
		if (desired.proxy_mode == 'tun')
			for (let family in desired.ip_families) add(l, mark_rule(desired.proxy_mode, family, null)[0]);
		else
			for (let position in [ 0, 1 ]) for (let family in desired.ip_families)
				add(l, mark_rule(desired.proxy_mode, family, null)[position]);
	}
	add(l, 'add rule inet miclash output meta mark 0x0002 return');
	add(l, 'add rule inet miclash output meta mark and 0xff00 != 0 return');
	if (length(servers4)) add(l, 'add rule inet miclash output ip daddr @proxy_servers4 return');
	if (length(servers6)) add(l, 'add rule inet miclash output ip6 daddr @proxy_servers6 return');
	if (desired.proxy_mode == 'mixed')
		for (let protocol in [ 'tcp', 'udp' ]) for (let family in desired.ip_families)
			add(l, 'add rule inet miclash output meta nfproto ' + family + ' meta mark 0x0 meta l4proto ' + protocol + ' meta mark set ' + (protocol == 'tcp' ? '0x1' : '0x3'));
	else for (let family in desired.ip_families)
		add(l, 'add rule inet miclash output meta nfproto ' + family + ' meta mark 0x0 meta l4proto { tcp, udp } meta mark set 0x1');
	if (desired.proxy_mode != 'tproxy') {
		add(l, 'add chain inet miclash tun_input { type filter hook input priority filter; policy accept; }');
		add(l, 'add rule inet miclash tun_input iifname "clash-tun" accept comment "miclash-fwd"');
		add(l, 'add chain inet miclash tun_forward { type filter hook forward priority filter; policy accept; }');
		add(l, 'add rule inet miclash tun_forward iifname "clash-tun" accept comment "miclash-fwd"');
		add(l, 'add rule inet miclash tun_forward oifname "clash-tun" accept comment "miclash-fwd"');
	}
	return join('\n', l) + '\n';
};

function transactional(model, id, previous) {
	let suffix = '_g_' + id;
	let l = [ '# miclash schema=1 generation=' + id,
		'add table inet miclash { comment "miclash:schema=1;generation=' + id + '"; }',
		'add chain inet miclash prerouting { type filter hook prerouting priority mangle; policy accept; }',
		'add chain inet miclash output { type route hook output priority mangle; policy accept; }',
		'add chain inet miclash tun_input { type filter hook input priority filter; policy accept; }',
		'add chain inet miclash tun_forward { type filter hook forward priority filter; policy accept; }',
		'flush chain inet miclash prerouting', 'flush chain inet miclash output',
		'flush chain inet miclash tun_input', 'flush chain inet miclash tun_forward',
		'add chain inet miclash prerouting' + suffix,
		'add chain inet miclash output' + suffix,
		'add chain inet miclash proxy' + suffix,
		'add chain inet miclash tun_input' + suffix,
		'add chain inet miclash tun_forward' + suffix,
		'add set inet miclash local4' + suffix + ' { type ipv4_addr; flags interval; }',
		'add set inet miclash local6' + suffix + ' { type ipv6_addr; flags interval; }',
		'add set inet miclash proxy_servers4' + suffix + ' { type ipv4_addr; }',
		'add set inet miclash proxy_servers6' + suffix + ' { type ipv6_addr; }',
		'add set inet miclash fakeip_whitelist4' + suffix + ' { type ipv4_addr; flags interval; }',
		'add set inet miclash fakeip_whitelist6' + suffix + ' { type ipv6_addr; flags interval; }' ];
	let tun = index(model, 'add chain inet miclash tun_input') >= 0;
	for (let line in split(model, '\n')) {
		if (!match(line, /^add (element|chain|rule) inet miclash /)) continue;
		if (match(line, /^add chain inet miclash (prerouting|proxy|output|tun_input|tun_forward)( |$)/)) continue;
		for (let name in [ 'local4', 'local6', 'proxy_servers4', 'proxy_servers6', 'fakeip_whitelist4', 'fakeip_whitelist6', 'proxy', 'prerouting', 'output', 'tun_input', 'tun_forward' ]) {
			if (name != 'proxy') line = replace(line, '@' + name, '@' + name + suffix);
			line = replace(line, ' ' + name + ' ', ' ' + name + suffix + ' ');
			if (name == 'proxy') line = replace(line, ' jump proxy', ' jump proxy' + suffix);
			if (line == 'add chain inet miclash ' + name) line += suffix;
		}
		push(l, line);
	}
	push(l, 'add rule inet miclash prerouting jump prerouting' + suffix, 'add rule inet miclash output jump output' + suffix);
	if (tun) push(l, 'add rule inet miclash tun_input jump tun_input' + suffix, 'add rule inet miclash tun_forward jump tun_forward' + suffix);
	if (previous != null && previous != id)
		for (let name in [ 'prerouting', 'output', 'tun_input', 'tun_forward', 'proxy', 'local4', 'local6', 'proxy_servers4', 'proxy_servers6', 'fakeip_whitelist4', 'fakeip_whitelist6' ])
			push(l, 'delete ' + (index([ 'local4', 'local6', 'proxy_servers4', 'proxy_servers6', 'fakeip_whitelist4', 'fakeip_whitelist6' ], name) >= 0 ? 'set' : 'chain') + ' inet miclash ' + name + '_g_' + previous);
	return join('\n', l) + '\n';
};

export function executable_projection(batch, id) {
	if (type(batch) != 'string' || !match(id, /^[0-9a-f]{12}$/)) fail('INVALID_ARGUMENT');
	let suffix = '_g_' + id, projected = [];
	for (let line in split(batch, '\n')) {
		let fields = split(line, ' '), include = false;
		if (length(fields) >= 6 && fields[0] == 'add' && fields[1] == 'element' &&
		    fields[2] == 'inet' && fields[3] == 'miclash')
			include = substr(fields[4], -length(suffix)) == suffix;
		else if (length(fields) >= 6 && fields[0] == 'add' && fields[1] == 'rule' &&
		         fields[2] == 'inet' && fields[3] == 'miclash')
			include = substr(fields[4], -length(suffix)) == suffix;
		if (include) push(projected, replace(line, suffix, ''));
	}
	return join('\n', projected) + '\n';
};

export function compile(desired) {
	validate(desired);
	let model = normalized(desired), id = generation(desired, model);
	return { generation: id, model: { schema_version: 1, normalized: model }, batch: transactional(model, id, desired.previous_generation) };
};

function captured(runtime, command) {
	const MAX_CAPTURE = 262144;
	let popen = runtime.fs?.popen ?? require('fs').popen;
	if (type(popen) != 'function') return null;
	let pipe = popen(command + ' 2>/dev/null', 'r');
	if (pipe == null) return null;
	let output = '', capture_failed = false;
	while (true) {
		let chunk;
		try { chunk = pipe.read(4096); } catch (error) { capture_failed = true; break; }
		if (type(chunk) != 'string') { capture_failed = true; break; }
		if (!length(chunk)) break;
		if (length(output) + length(chunk) > MAX_CAPTURE) { capture_failed = true; break; }
		output += chunk;
	}
	let closed = null;
	try { closed = pipe.close(); } catch (error) { capture_failed = true; }
	if (capture_failed || (closed !== 0 && closed !== true)) fail('INTERNAL');
	return output;
};

function json_anchor_generation(document) {
	let chains = [], rules = [];
	for (let item in document.nftables ?? []) {
		if (item.chain?.family == 'inet' && item.chain?.table == 'miclash' && item.chain?.name == 'prerouting')
			push(chains, item.chain);
		if (item.rule?.family == 'inet' && item.rule?.table == 'miclash' && item.rule?.chain == 'prerouting')
			push(rules, item.rule);
	}
	if (length(chains) != 1 || chains[0].type != 'filter' || chains[0].hook != 'prerouting' ||
	    chains[0].prio != -150 || chains[0].policy != 'accept' || length(rules) != 1 ||
	    length(rules[0].expr ?? []) != 1)
		return null;
	let found = match(rules[0].expr[0].jump?.target ?? '', /^prerouting_g_([0-9a-f]{12})$/);
	return found ? found[1] : null;
};

function text_anchor_generation(text) {
	let found = match(text ?? '', /chain prerouting \{([^}]*)\}/);
	if (!found || !match(found[1], /type filter hook prerouting priority (mangle|-150); policy accept;/))
		return null;
	let jumps = match(found[1], /jump prerouting_g_([0-9a-f]{12})/g);
	if (!jumps || length(jumps) != 1) return null;
	let target = match(jumps[0], /jump prerouting_g_([0-9a-f]{12})/);
	return target ? target[1] : null;
};

export function observe(runtime) {
	let result = runtime.process.run({ command: 'nft', args: [ '-j', 'list', 'table', 'inet', 'miclash' ] });
	if (result.code == 0 && result.stdout == null)
		result.stdout = captured(runtime, 'nft -j list table inet miclash');
	if (result.code == 0 && type(result.stdout) == 'string') {
		try {
			let document = json(result.stdout);
			let id = json_anchor_generation(document);
			if (id) return { installed: true, generation: id, source: 'json-anchor' };
		} catch (error) {}
	}
	let fallback = runtime.process.run({ command: 'nft', args: [ 'list', 'table', 'inet', 'miclash' ] });
	if (fallback.code == 0 && fallback.stdout == null)
		fallback.stdout = captured(runtime, 'nft list table inet miclash');
	let id = fallback.code == 0 ? text_anchor_generation(fallback.stdout) : null;
	return { installed: id != null, generation: id, source: 'text' };
};

function write_all(runtime, handle, data) {
	let offset = 0;
	while (offset < length(data)) { let amount = runtime.fs.write(handle, substr(data, offset)); if (type(amount) != 'int' || amount < 1) fail('INTERNAL'); offset += amount; }
};

export function apply(runtime, compiled) {
	if (type(compiled?.batch) != 'string' || !match(compiled?.generation, /^[0-9a-f]{12}$/)) fail('INVALID_ARGUMENT');
	let path = runtime.paths.tmp + '/nft-' + compiled.generation + '-' + runtime.random.hex(8) + '.batch';
	let handle = runtime.fs.open(path, 'wx', 0o600);
	if (handle == null) fail('INTERNAL');
	let state = null, failure = null;
	try {
		write_all(runtime, handle, compiled.batch);
		if (!runtime.fs.flush(handle) || runtime.fs.close(handle) != true) fail('INTERNAL');
		handle = null;
		if (runtime.process.run({ command: 'nft', args: [ '-f', path ] }).code != 0) fail('INTERNAL');
		state = observe(runtime);
		if (state.generation != compiled.generation) fail('INTERNAL');
	}
	catch (error) { failure = error?.code ?? error?.message ?? 'INTERNAL'; }
	if (handle != null) try { runtime.fs.close(handle); } catch (error) {}
	let cleanup_failed = false;
	try { runtime.fs.unlink(path); } catch (error) { cleanup_failed = true; }
	try { if (runtime.fs.lstat(path) != null) cleanup_failed = true; }
	catch (error) { cleanup_failed = true; }
	if (cleanup_failed) failure = 'INTERNAL';
	if (failure != null) fail(failure);
	return state;
};

export function cleanup(runtime, mode) {
	if (mode?.preserve_guard !== true) fail('INVALID_ARGUMENT');
	let result = runtime.process.run({ command: 'nft', args: [ 'delete', 'table', 'inet', 'miclash' ] });
	if (result.code != 0) fail('INTERNAL');
	return { clean: !observe(runtime).installed, guard_preserved: true };
};
