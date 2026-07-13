import * as fakes from './fakes.uc';

export const MANIFEST_PATH = '/var/run/miclash/routing-ownership.json';
const TEST_BOOT = '12345678-1234-1234-1234-123456789abc';
const CAPTURE_PREFIX = '/usr/bin/timeout -s KILL 2 ';

export function canonical_route(item) {
	let value = { family: item.family, table: item.table, kind: item.kind,
		destination: item.destination, device: item.device };
	if (item.kind == 'unreachable') { value.unreachable = true; value.metric = item.metric; }
	return value;
};

export function canonical_rule(item) {
	return { family: item.family, priority: item.priority, mark: item.mark,
		mask: item.mask, table: item.table };
};

export function committed(routes, rules) {
	return {
		routes: map(routes ?? [], canonical_route),
		rules: map(rules ?? [], canonical_rule)
	};
};

export function manifest(routes, rules, transition) {
	return sprintf('%J\n', {
		version: 2, owner: 'miclash', protocol: 242,
		committed: committed(routes, rules), transition: transition ?? null
	});
};

export function transition(kind, action, target, retire, pre, post, next) {
	return { kind, action, target, retire, pre, post, next };
};

function pipe(value, status) {
	let offset = 0;
	return {
		read: (amount) => { let chunk = substr(value, offset, amount); offset += length(chunk); return chunk; },
		close: () => status ?? 0
	};
};

export function empty_outputs() {
	let values = {};
	for (let family in [ '-4', '-6' ]) {
		values['ip -j ' + family + ' rule show 2>/dev/null'] = '[]\n';
		values['ip ' + family + ' rule show 2>/dev/null'] = '';
		for (let table in [ 100, 101 ]) {
			values['ip -j ' + family + ' route show table ' + table + ' 2>/dev/null'] = '[]\n';
			values['ip ' + family + ' route show table ' + table + ' 2>/dev/null'] = '';
		}
	}
	values['ip -j link show dev clash-tun 2>/dev/null'] = '[]\n';
	values['ip link show dev clash-tun 2>/dev/null'] = '';
	return values;
};

export function runtime(outputs) {
	let calls = [], captures = [], filesystem = fakes.fs({
		'/proc/sys/kernel/random/boot_id': TEST_BOOT + '\n',
		'/proc/9001/stat': '9001 (routing test) S ' +
			join(' ', [ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 700 ]) + '\n'
	});
	for (let path in [ '/var', '/var/run', '/var/run/miclash' ]) filesystem.mkdir(path);
	filesystem.set_mode('/var/run/miclash', 0o700);
	filesystem.popen = (command, mode) => {
		push(captures, command);
		let logical = substr(command, 0, length(CAPTURE_PREFIX)) == CAPTURE_PREFIX
			? substr(command, length(CAPTURE_PREFIX)) : command;
		let reply = outputs?.[logical] ?? outputs?.[command] ?? '[]\n';
		return type(reply) == 'object' ? pipe(reply.output ?? '', reply.status ?? 0) : pipe(reply);
	};
	return {
		process: { calls, run: (request) => { push(calls, request); return { code: 0 }; } },
		fs: filesystem,
		digest: fakes.digest(filesystem),
		clock: fakes.clock(1000),
		random: fakes.entropy(),
		mutation_lock_self: { boot: TEST_BOOT, pid: 9001, start: 700 },
		paths: { run: '/var/run/miclash' },
		captures
	};
};

export function seed(value, routes, rules, op) {
	value.fs.writefile(MANIFEST_PATH, manifest(routes, rules, op));
	return value;
};

export function set_route_json(outputs, item) {
	let flag = item.family == 'ipv4' ? '-4' : '-6';
	let encoded = {
		type: item.kind, dst: 'default', dev: item.device, table: item.table, protocol: 242
	};
	if (item.kind == 'unreachable') { encoded.metric = item.metric; delete encoded.dev; }
	outputs['ip -j ' + flag + ' route show table ' + item.table + ' 2>/dev/null'] =
		sprintf('[%J]\n', encoded);
};

export function set_rule_json(outputs, item) {
	let flag = item.family == 'ipv4' ? '-4' : '-6';
	outputs['ip -j ' + flag + ' rule show 2>/dev/null'] = sprintf('[%J]\n', {
		priority: item.priority, src: 'all', fwmark: item.mark, fwmask: item.mask,
		table: item.table, protocol: 242
	});
};
