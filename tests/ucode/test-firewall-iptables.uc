import { assert_equal, assert_throws, assert_true } from './testlib.uc';
import { compile, observe, apply, cleanup } from 'miclash.firewall.iptables';
import { fs } from './fakes.uc';

let filesystem = require('fs');
let root = 'tests/fixtures/network';
let scenarios = json(filesystem.readfile(root + '/scenarios.json')).scenarios;

function command(executable, args) { return { command: executable, args }; };

function semantic_projection(text) {
	let projected = [];
	for (let line in split(text, '\n')) {
		if (!length(line) || substr(line, 0, 1) == '#') continue;
		let fields = split(line, ' '), executable = shift(fields);
		if (index(fields, 'MICLASH_GUARD_FORWARD') >= 0) continue;
		push(projected, command(executable, fields));
	}
	return projected;
};

function encoded(value) { return sprintf('%J', value); };
function all_commands(compiled) {
	return [ ...compiled.stages.anchors, ...compiled.stages.prepare,
		...compiled.stages.verify_prepared, ...compiled.stages.switch,
		...compiled.stages.verify_active, ...compiled.stages.retire ];
};

for (let desired in scenarios) {
	let compiled = compile(desired);
	let golden = filesystem.readfile(root + '/iptables/' + desired.expected.iptables);
	assert_equal(encoded(compiled.model.normalized), encoded(semantic_projection(golden)),
		desired.name + ': argv semantic projection must preserve the accepted golden');
	assert_true(!!match(compiled.generation, /^[0-9a-f]{12}$/),
		desired.name + ': generation suffix is bounded');
	assert_equal(encoded(compile(desired)), encoded(compiled),
		desired.name + ': compilation is deterministic');
	let switched = compile({ ...desired, generation: '111111111111',
		previous_generation: '000000000000' });
	let argv_golden = json(filesystem.readfile(root + '/iptables-argv/' + desired.expected.iptables));
	assert_equal(encoded(switched), encoded(argv_golden),
		desired.name + ': complete staged argv topology matches its independent golden');
	for (let request in all_commands(compiled)) {
		assert_true(index([ 'iptables', 'ip6tables', 'ipset' ], request.command) >= 0,
			desired.name + ': executable is fixed');
		assert_true(type(request.args) == 'array', desired.name + ': argv is an array');
		assert_true(request.shell == null, desired.name + ': no shell command is emitted');
		for (let arg in request.args)
			assert_true(type(arg) == 'string' && !match(arg, /[\n\r]/),
				desired.name + ': argv item is bounded to one argument');
	}
	assert_true(index(encoded(compiled), 'MICLASH_GUARD_FORWARD') < 0,
		desired.name + ': Task 4 never owns or weakens Guard');
	for (let family in desired.ip_families) {
		let local_set = family == 'ipv4' ? 'miclash_local4' : 'miclash_local6';
		let executable = family == 'ipv4' ? 'iptables' : 'ip6tables';
		let local_at = -1, mark_at = -1;
		for (let i = 0; i < length(compiled.model.normalized); i++) {
			let request = compiled.model.normalized[i], args = request.args;
			if (request.command != executable || args[3] != 'MICLASH_OUTPUT') continue;
			if (args[4] == '-m' && args[5] == 'set' && args[6] == '--match-set' &&
			    args[7] == local_set && args[8] == 'dst' && args[10] == 'RETURN') local_at = i;
			if (args[4] == '-m' && args[5] == 'mark' && args[6] == '--mark' &&
			    args[7] == '0x0') mark_at = i;
		}
		assert_true(local_at >= 0 && mark_at > local_at,
			desired.name + ': router replies to local destinations bypass proxy marks for ' + family);
	}
}

let desired = { ...scenarios[0], generation: 'bbbbbbbbbbbb',
	previous_generation: 'aaaaaaaaaaaa' };
let staged = compile(desired);
let serialized = encoded(staged.stages);

let scoped_explicit = encoded(compile(scenarios[4]).model.normalized);
assert_true(index(scoped_explicit,
	'"-i", "br-lan", "-m", "mac", "--mac-source", "02:00:00:00:00:40", "-j", "DROP"') >= 0,
	'explicit Block policy must be constrained to a selected ingress');
assert_true(index(scoped_explicit,
	'"-i", "wlan0", "-m", "mac", "--mac-source", "02:00:00:00:00:41", "-j", "RETURN"') >= 0,
	'explicit Direct policy must be constrained to every selected ingress');
let scoped_exclude = encoded(compile(scenarios[10]).model.normalized);
assert_true(index(scoped_exclude, '"-i", "eth1", "-j", "RETURN"') <
	index(scoped_exclude, '"--mac-source", "02:00:00:00:00:50", "-j", "DROP"'),
	'excluded ingress must return before any device policy participates');
assert_true(index(serialized, 'MCL_PR_bbbbbbbbbbbb') >= 0 &&
	index(serialized, 'MCL_PX_bbbbbbbbbbbb') >= 0 &&
	index(serialized, 'MCL_OU_bbbbbbbbbbbb') >= 0,
	'generation B has bounded entry/proxy/output chains');
assert_true(index(serialized, 'MCL_PR_aaaaaaaaaaaa') >= 0,
	'old generation A is named explicitly for retirement');
assert_true(length(staged.stages.prepare) > 0 && length(staged.stages.verify_prepared) > 0,
	'generation B is populated and verified before switching');
let prepared_checks = encoded(staged.stages.verify_prepared);
for (let owned in [ 'MCL_PR_bbbbbbbbbbbb', 'MCL_PX_bbbbbbbbbbbb', 'MCL_OU_bbbbbbbbbbbb',
	'MCL_TI_bbbbbbbbbbbb', 'MCL_TF_bbbbbbbbbbbb', 'MCL_L4_bbbbbbbbbbbb', 'MCL_F4_bbbbbbbbbbbb' ])
	assert_true(index(prepared_checks, owned) >= 0,
		'prepared topology explicitly verifies owned object ' + owned);
assert_true(length(staged.stages.switch) > 0 && length(staged.stages.verify_active) > 0,
	'permanent anchors are switched and then verified');
assert_true(length(staged.stages.retire) > 0,
	'old generation retirement is a distinct final stage');
for (let item in staged.stages.switch) {
	assert_equal(item.args[2], '-C', 'switch first probes whether A exists in each family anchor');
	assert_true(type(item.on_success) == 'array' && item.on_success[2] == '-R',
		'existing family anchor atomically replaces A with B');
	assert_true(type(item.on_failure) == 'array' && item.on_failure[2] == '-A',
		'new family anchor appends B without assuming A existed');
}

let idempotent = compile({ ...scenarios[0], generation: 'aaaaaaaaaaaa',
	previous_generation: 'aaaaaaaaaaaa' });
assert_equal(length(idempotent.stages.prepare), 0,
	'reconciling the already-selected generation never recreates active chains or sets');
assert_equal(length(idempotent.stages.switch), 0,
	'reconciling the already-selected generation never duplicates anchor jumps');
assert_equal(length(idempotent.stages.retire), 0,
	'reconciling the already-selected generation never retires itself');
assert_true(length(idempotent.stages.verify_active) > 0,
	'idempotent reconciliation still verifies every selected permanent anchor');

for (let invalid in [
	{ ...scenarios[0], generation: 'A;bad' },
	{ ...scenarios[0], previous_generation: 'aaaaaaaaaaaaa' },
	{ ...scenarios[0], lan: [ 'bad;name' ] },
	{ ...scenarios[0], server_ips: [ '$(touch /tmp/pwn)' ] },
	{ ...scenarios[0], set_names: { local4: 'foreign' } }
]) assert_throws(() => compile(invalid), 'INVALID_ARGUMENT');

function repeated(value, count) { let values = []; for (let i = 0; i < count; i++) push(values, value); return values; };
assert_throws(() => compile({ ...scenarios[0], lan: repeated('br-lan', 65) }), 'INVALID_ARGUMENT');
assert_throws(() => compile({ ...scenarios[0], server_ips: repeated('192.0.2.1', 257) }), 'INVALID_ARGUMENT');
assert_throws(() => compile({ ...scenarios[0], fakeip_cidrs: repeated('198.18.0.0/16', 257) }), 'INVALID_ARGUMENT');
let many_policies = [];
for (let i = 0; i < 129; i++) push(many_policies, { id: 'p' + i,
	mac: sprintf('02:00:00:00:%02x:%02x', int(i / 256), i % 256), action: 'proxy' });
assert_throws(() => compile({ ...scenarios[0], device_policies: many_policies }), 'INVALID_ARGUMENT');
assert_throws(() => compile({ ...scenarios[0], previous_ip_families: [ 'ipv4', 'ipv6', 'ipv4' ] }), 'INVALID_ARGUMENT');
assert_throws(() => compile({ ...scenarios[0], ip_families: [ 'ipv4', 'ipv4' ] }), 'INVALID_ARGUMENT');
assert_throws(() => compile({ ...scenarios[0], device_policies: [ {
	id: sprintf('%065d', 1), mac: '02:00:00:00:00:01', action: 'proxy'
} ] }), 'INVALID_ARGUMENT');
let volume_policies = [];
for (let i = 0; i < 128; i++) push(volume_policies, { id: 'v' + i,
	mac: sprintf('02:00:00:01:%02x:%02x', int(i / 256), i % 256), action: 'proxy' });
assert_throws(() => compile({ ...scenarios[4], lan: repeated('br-lan', 64), wan: repeated('eth1', 64),
	server_ips: repeated('192.0.2.1', 256), fakeip_cidrs: repeated('198.18.0.0/16', 256),
	device_policies: volume_policies }), 'INVALID_ARGUMENT');

function runtime_with(options) {
	let calls = [], fail_at = options?.fail_at ?? null, sequence = 0;
	let save_count = 0;
	let inventory_visible = true;
	let orphan_visible = !!options?.orphan_generation;
	let cleanup_mutated = false;
	let guard_wrong = !!options?.guard_before_anchor_is_wrong;
	let task_hook_count = options?.no_anchors ? 0 : 1;
	let states = options?.states ?? {
		iptables: { MCL_AN_PR: 'aaaaaaaaaaaa', MCL_AN_OU: 'aaaaaaaaaaaa',
			MCL_AN_TI: 'aaaaaaaaaaaa', MCL_AN_TF: 'aaaaaaaaaaaa' },
		ip6tables: { MCL_AN_PR: '', MCL_AN_OU: '', MCL_AN_TI: '', MCL_AN_TF: '' }
	};
	function saved(executable, table) {
		let base = executable == 'iptables-save' ? 'iptables' : 'ip6tables', lines = [ '*' + table ];
		for (let chain, id in (options?.no_anchors ? {} : states[base])) {
			let is_filter = chain == 'MCL_AN_TI' || chain == 'MCL_AN_TF';
			if (is_filter != (table == 'filter')) continue;
			push(lines, ':' + chain + ' - [0:0]');
			if (length(id)) {
				let prefix = chain == 'MCL_AN_PR' ? 'MCL_PR_' : chain == 'MCL_AN_OU' ? 'MCL_OU_' :
					chain == 'MCL_AN_TI' ? 'MCL_TI_' : 'MCL_TF_';
				push(lines, '-A ' + chain + ' -j ' + prefix + id);
			}
		}
		if (!options?.no_anchors) {
			if (table == 'mangle') push(lines, '-A PREROUTING -j MCL_AN_PR', '-A OUTPUT -j MCL_AN_OU');
			else {
				push(lines, '-A INPUT -j MCL_AN_TI');
				if (task_hook_count == 2) {
					push(lines, '-A FORWARD -j MCL_AN_TF');
					if (options?.guard) push(lines, '-A FORWARD -j MICLASH_GUARD_FORWARD');
					push(lines, '-A FORWARD -j MCL_AN_TF');
				}
				else {
					if (options?.guard && !guard_wrong) push(lines, '-A FORWARD -j MICLASH_GUARD_FORWARD');
					if (task_hook_count) push(lines, '-A FORWARD -j MCL_AN_TF');
					if (options?.guard && guard_wrong) push(lines, '-A FORWARD -j MICLASH_GUARD_FORWARD');
				}
			}
		}
		if (options?.remaining_generation && table == 'mangle')
			push(lines, ':MCL_PR_' + options.remaining_generation + ' - [0:0]');
		if (options?.retained_old && table == 'mangle' && base == 'iptables')
			push(lines, ':MCL_PR_aaaaaaaaaaaa - [0:0]');
		if (orphan_visible && base == 'iptables') {
			let orphan = options.orphan_generation;
			if (table == 'mangle')
				for (let prefix in (options?.partial_orphan ? [ 'PR' ] : [ 'PR', 'PX', 'OU' ]))
					push(lines, ':MCL_' + prefix + '_' + orphan + ' - [0:0]');
			else if (!options?.partial_orphan)
				for (let prefix in [ 'TI', 'TF' ]) push(lines, ':MCL_' + prefix + '_' + orphan + ' - [0:0]');
		}
		let inventory = options?.inventory ?? staged?.inventory ?? [];
		if (inventory_visible)
			for (let item in inventory) if (item.command == base && item.args[1] == table) {
				if (item.args[2] == '-N') push(lines, ':' + item.args[3] + ' - [0:0]');
				else if (item.args[2] == '-A') {
					let fields = [];
					for (let i = 2; i < length(item.args); i++) push(fields, item.args[i]);
					push(lines, join(' ', fields));
				}
			}
		if (options?.extra_generation_rule && table == 'mangle' && base == 'iptables') {
			let extra_id = 'bbbbbbbbbbbb';
			for (let item in inventory) if (item.command == 'iptables' && item.args[2] == '-N') {
				extra_id = substr(item.args[3], -12); break;
			}
			push(lines, '-A MCL_PX_' + extra_id + ' -p icmp -j RETURN');
		}
		if (options?.foreign_generation_jump && table == 'mangle' && base == 'iptables')
			push(lines, '-A PREROUTING -j MCL_PR_bbbbbbbbbbbb');
		if (options?.foreign_generation_goto && table == 'mangle' && base == 'iptables')
			push(lines, '-A PREROUTING -g MCL_PR_bbbbbbbbbbbb');
		if (options?.foreign_generation_long_goto && table == 'mangle' && base == 'iptables')
			push(lines, '-A PREROUTING --goto MCL_PR_bbbbbbbbbbbb');
		if (options?.orphan_foreign_edge && table == 'mangle' && base == 'iptables')
			push(lines, '-A PREROUTING -j MCL_PR_' + options.orphan_generation);
		if (base == 'ip6tables' && table == 'filter' && options?.duplicate_permanent_hook)
			push(lines, '-A FORWARD -j MCL_AN_TF');
		if (base == 'iptables' && table == 'mangle' && options?.parameterized_canonical_edge)
			push(lines, '-A MCL_AN_PR -s 192.0.2.0/24 -j MCL_PR_bbbbbbbbbbbb');
		if (base == 'iptables' && table == 'mangle' && options?.duplicate_canonical_edge)
			push(lines, '-A MCL_AN_PR -j MCL_PR_bbbbbbbbbbbb');
		if (base == 'ip6tables' && table == 'mangle' && options?.cross_family_partial)
			push(lines, ':MCL_PR_bbbbbbbbbbbb - [0:0]');
		if (base == 'iptables' && table == 'mangle' && options?.foreign_anchor_verdict)
			push(lines, ':FOREIGN - [0:0]', '-A FOREIGN ' + options.foreign_anchor_verdict + ' MCL_AN_PR');
		if (base == 'iptables' && table == 'mangle' && cleanup_mutated && options?.post_cleanup_edge)
			push(lines, ':FOREIGN - [0:0]', options.post_cleanup_edge);
		push(lines, 'COMMIT', '');
		return join('\n', lines);
	};
	let p = { calls };
	p.run = (request) => {
		push(calls, request);
		sequence++;
		let code = sequence == fail_at || (type(options?.fail_when) == 'function' && options.fail_when(request)) ? 1 : 0;
		let key = request.command + ':' + join(' ', request.args);
		let reply = options?.replies?.[key];
		if (reply == null && request.command == 'ipset' && request.args[0] == 'save') {
			let lines = [], inventory = options?.inventory ?? staged?.inventory ?? [];
			if (inventory_visible) for (let item in inventory) {
				if (item.command != 'ipset') continue;
				if (item.args[0] == 'create') push(lines, 'create ' + item.args[1] +
					(options?.wrong_set_schema ? ' hash:ip family ' : ' hash:net family ') + item.args[4]);
				else if (item.args[0] == 'add' && !(options?.missing_set_member && item.args[2] == '10.0.0.0/8'))
					push(lines, 'add ' + item.args[1] + ' ' + item.args[2]);
			}
			if (options?.retained_old) push(lines, 'create MCL_L4_aaaaaaaaaaaa hash:net family inet');
			if (orphan_visible && !options?.partial_orphan) {
				push(lines, 'create MCL_L4_' + options.orphan_generation + ' hash:net family inet');
				push(lines, 'create MCL_F4_' + options.orphan_generation + ' hash:net family inet');
			}
			if (options?.extra_set_member) push(lines, 'add MCL_L4_bbbbbbbbbbbb 11.0.0.0/8');
			return { code: 0, stdout: join('\n', lines) + '\n', stderr: null };
		}
		if (reply == null && request.command == 'ipset' && request.args[0] == 'list' && request.args[1] == '-name')
			return { code: 0, stdout: options?.remaining_generation ? 'MCL_L4_' + options.remaining_generation + '\n' : '', stderr: null };
		if (options?.no_anchors && (request.args[2] == '-C' || request.args[2] == '-L') &&
		    index([ 'MCL_AN_PR', 'MCL_AN_OU', 'MCL_AN_TI', 'MCL_AN_TF' ], request.args[length(request.args) - 1]) >= 0)
			return { code: 1, stdout: null, stderr: null };
		if (options?.orphan_generation && !orphan_visible &&
		    ((request.args[2] == '-L' && substr(request.args[3] ?? '', -12) == options.orphan_generation) ||
		     (request.command == 'ipset' && request.args[0] == 'list' &&
		      substr(request.args[1] ?? '', -12) == options.orphan_generation)))
			return { code: 1, stdout: null, stderr: null };
		if (options?.absent && request.command == 'ipset' && request.args[0] == 'list' && request.args[1] == '-name')
			return { code: 0, stdout: '', stderr: null };
		if (options?.absent && (request.args[2] == '-C' || request.args[2] == '-L' ||
		    (request.command == 'ipset' && request.args[0] == 'list')))
			return { code: 1, stdout: null, stderr: null };
		if (request.command == 'iptables-save' || request.command == 'ip6tables-save') save_count++;
		if (options?.capture_fail_at == save_count &&
		    (request.command == 'iptables-save' || request.command == 'ip6tables-save'))
			return { code: options.capture_failure == 'status' ? 1 : 0, stdout: null, stderr: null };
		if (reply == null && (request.command == 'iptables-save' || request.command == 'ip6tables-save'))
			return { code, stdout: saved(request.command, request.args[1]), stderr: null };
		if (code == 0 && ((request.command == 'iptables' || request.command == 'ip6tables') &&
		    (index(request.args, '-D') >= 0 || index(request.args, '-F') >= 0 || index(request.args, '-X') >= 0) ||
		    request.command == 'ipset' && request.args[0] == 'destroy')) cleanup_mutated = true;
		if (code == 0 && (request.command == 'iptables' || request.command == 'ip6tables') &&
		    (request.args[2] == '-R' || request.args[2] == '-A' || request.args[2] == '-F') &&
		    states[request.command]?.[request.args[3]] != null) {
			if (request.args[2] == '-F') states[request.command][request.args[3]] = '';
			else states[request.command][request.args[3]] = substr(request.args[length(request.args) - 1], -12);
		}
		if (code == 0 && request.args[3] == 'FORWARD' &&
		    request.args[length(request.args) - 1] == 'MCL_AN_TF') {
			if (request.args[2] == '-A') { task_hook_count++; guard_wrong = false; }
			if (request.args[2] == '-D' && task_hook_count) task_hook_count--;
		}
		if (code == 0 && request.args[2] == '-X' && match(request.args[3] ?? '', /^MCL_.._bbbbbbbbbbbb$/))
			inventory_visible = false;
		if (code == 0 && request.args[2] == '-X' &&
		    substr(request.args[3] ?? '', -12) == options?.orphan_generation) orphan_visible = false;
		return { code: reply?.code ?? code, stdout: reply?.stdout ?? null,
			stderr: reply?.stderr ?? null };
	};
	let runtime = { process: p };
	if (options?.capture_failure && options.capture_failure != 'status') {
		runtime.fs = fs();
		runtime.fs.popen = () => {
			if (options.capture_failure == 'open') return null;
			return {
				read: () => options.capture_failure == 'read' ? null :
					options.capture_failure == 'oversize' ? sprintf('%04096d', 0) : '',
				close: () => options.capture_failure == 'close' ? 1 : 0
			};
		};
	}
	return runtime;
};

let prep_failure = runtime_with({ fail_when: (r) => r.args[2] == '-N' &&
	index(r.args, 'MCL_PX_bbbbbbbbbbbb') >= 0 });
let prep_error = null, prep_result = null;
try { prep_result = apply(prep_failure, staged); } catch (error) { prep_error = error; }
assert_equal(prep_error?.code ?? prep_error?.message, 'INTERNAL',
	'preparation failure must throw after verified rollback: result=' + encoded(prep_result) + ' error=' + encoded(prep_error));
let prep_log = encoded(prep_failure.process.calls);
assert_true(index(prep_log, 'MCL_PR_aaaaaaaaaaaa') < 0,
	'preparation failure never modifies or removes selected generation A');
assert_true(index(prep_log, 'MCL_PR_bbbbbbbbbbbb') >= 0 && index(prep_log, 'MICLASH_GUARD_FORWARD') < 0,
	'preparation failure removes only incomplete B and leaves Guard untouched');

let post_switch = runtime_with({ fail_when: (request) => request.args[2] == '-R' && request.args[3] == 'MCL_AN_OU' });
let repair = apply(post_switch, staged);
assert_equal(repair.repair_needed, true,
	'post-switch failure returns repair-needed instead of rolling traffic back unsafely');
let post_log = encoded(post_switch.process.calls);
assert_true(index(post_log, '-X","MCL_PR_aaaaaaaaaaaa') < 0 &&
	index(post_log, '-X","MCL_PR_bbbbbbbbbbbb') < 0,
	'post-switch failure keeps both generations');

for (let failure in [ 'open', 'read', 'close', 'status', 'oversize' ]) {
	let before_capture = runtime_with({ capture_failure: failure, capture_fail_at: 2 });
	assert_throws(() => apply(before_capture, staged), 'INTERNAL');
	let removed_b = false;
	for (let request in before_capture.process.calls)
		removed_b = removed_b || (request.args[2] == '-X' && request.args[3] == 'MCL_PR_bbbbbbbbbbbb');
	assert_true(removed_b,
		'pre-switch ' + failure + ' capture failure rolls back prepared B');
	let after_capture = runtime_with({ capture_failure: failure, capture_fail_at: 11 });
	let repair = apply(after_capture, staged);
	assert_equal(repair.repair_needed, true,
		'post-switch ' + failure + ' capture failure returns repair-needed');
	let removed_a = false;
	for (let request in after_capture.process.calls)
		removed_a = removed_a || (request.args[2] == '-X' && request.args[3] == 'MCL_PR_aaaaaaaaaaaa');
	assert_true(!removed_a,
		'post-switch capture failure retains A');
}

for (let failure in [
	{ name: 'anchor creation', match: (r) => index(r.args, 'MCL_AN_PR') >= 0 },
	{ name: 'prepared verification', match: (r) => r.args[2] == '-L' && index(r.args, 'MCL_TI_bbbbbbbbbbbb') >= 0 },
	{ name: 'first switch', match: (r) => r.args[2] == '-R' && r.args[3] == 'MCL_AN_PR' }
]) {
	let failed = runtime_with({ fail_when: failure.match });
	assert_throws(() => apply(failed, staged), 'INTERNAL');
	assert_true(index(encoded(failed.process.calls), 'MICLASH_GUARD_FORWARD') < 0,
		failure.name + ' failure never touches Guard');
}

let verify_failure = runtime_with({ fail_when: (r) => r.args[2] == '-C' && r.args[3] == 'MCL_AN_OU' &&
	index(r.args, 'MCL_OU_bbbbbbbbbbbb') >= 0 });
assert_equal(apply(verify_failure, staged).repair_needed, true,
	'active B verification failure keeps generations for repair');

let retire_failure = runtime_with({ fail_when: (r) => r.args[2] == '-X' &&
	index(r.args, 'MCL_PR_aaaaaaaaaaaa') >= 0 });
assert_equal(apply(retire_failure, staged).repair_needed, true,
	'old-generation retirement failure cannot report success');
assert_equal(apply(runtime_with({ retained_old: true }), staged).repair_needed, true,
	'fresh structural inventory must prove old A absent after retirement');

let rollback_failure = runtime_with({ fail_when: (r) =>
	(r.args[2] == '-L' && index(r.args, 'MCL_TI_bbbbbbbbbbbb') >= 0) ||
	(r.args[2] == '-F' && index(r.args, 'MCL_PR_bbbbbbbbbbbb') >= 0) });
let rollback_repair = apply(rollback_failure, staged);
assert_equal(rollback_repair.stage, 'rollback',
	'rollback failure returns explicit repair metadata instead of hiding incomplete B');
let rollback_probe_error = runtime_with({ remaining_generation: 'bbbbbbbbbbbb', fail_when: (r) =>
	(r.args[2] == '-L' && index(r.args, 'MCL_TI_bbbbbbbbbbbb') >= 0) ||
	(r.args[2] == '-L' && index(r.args, 'MCL_PR_bbbbbbbbbbbb') >= 0) });
assert_equal(apply(rollback_probe_error, staged).stage, 'rollback',
	'failed rollback existence probe requires fresh inventory and repair metadata');

assert_throws(() => compile({ ...scenarios[0], generation: 'aaaaaaaaaaaa',
	previous_generation: 'aaaaaaaaaaaa', previous_ip_families: [ 'ipv4', 'ipv6' ] }),
	'INVALID_ARGUMENT');

let dual_to_single = compile({ ...scenarios[0], generation: 'bbbbbbbbbbbb',
	previous_generation: 'aaaaaaaaaaaa', previous_ip_families: [ 'ipv4', 'ipv6' ] });
let dual_state = {
	iptables: { MCL_AN_PR: 'aaaaaaaaaaaa', MCL_AN_OU: 'aaaaaaaaaaaa', MCL_AN_TI: 'aaaaaaaaaaaa', MCL_AN_TF: 'aaaaaaaaaaaa' },
	ip6tables: { MCL_AN_PR: 'aaaaaaaaaaaa', MCL_AN_OU: 'aaaaaaaaaaaa', MCL_AN_TI: 'aaaaaaaaaaaa', MCL_AN_TF: 'aaaaaaaaaaaa' }
};
let narrowed = apply(runtime_with({ states: dual_state }), dual_to_single);
assert_equal(narrowed.repair_needed, false, 'dual-stack A to IPv4-only B reconciles removed IPv6 anchors');
assert_true(index(encoded(dual_to_single.stages.switch), 'ip6tables') >= 0,
	'removed IPv6 family receives explicit anchor detach operations');

let success = runtime_with();
let active = apply(success, staged);
assert_equal(active.generation, 'bbbbbbbbbbbb', 'successful apply selects generation B');
assert_equal(active.repair_needed, false, 'successful apply needs no repair');
let calls = success.process.calls, verify_at = null, retire_at = null;
for (let i = 0; i < length(calls); i++) {
	if (calls[i].args[2] == '-C' && index(calls[i].args, 'MCL_PR_bbbbbbbbbbbb') >= 0)
		verify_at = i;
	if (calls[i].args[2] == '-X' && index(calls[i].args, 'MCL_PR_aaaaaaaaaaaa') >= 0)
		retire_at = i;
}
assert_true(verify_at != null && retire_at != null && verify_at < retire_at,
	'old A is removed only after active B verification');

let reordered_guard = runtime_with({ guard: true, guard_before_anchor_is_wrong: true });
assert_equal(apply(reordered_guard, staged).repair_needed, false,
	'apply repairs Task 4 forwarding anchor behind an existing Guard hook');
let moved_delete = false, moved_append = false;
for (let request in reordered_guard.process.calls) {
	if (request.args[3] == 'FORWARD' && request.args[length(request.args) - 1] == 'MCL_AN_TF') {
		moved_delete = moved_delete || request.args[2] == '-D';
		moved_append = moved_append || request.args[2] == '-A';
	}
	if (index(request.args, 'MICLASH_GUARD_FORWARD') >= 0)
		assert_true(request.args[2] != '-D' && request.args[2] != '-I' && request.args[2] != '-A',
			'Guard ordering never mutates the Guard hook');
}
assert_true(moved_delete && moved_append, 'Guard ordering repair moves only the Task 4 anchor');

let guard_append_failure = runtime_with({ guard: true, guard_before_anchor_is_wrong: true,
	fail_when: (r) => r.args[2] == '-A' && r.args[3] == 'FORWARD' && r.args[length(r.args) - 1] == 'MCL_AN_TF' });
assert_throws(() => apply(guard_append_failure, staged), 'INTERNAL');
let deleted_before_append = false;
for (let request in guard_append_failure.process.calls)
	deleted_before_append = deleted_before_append || (request.args[2] == '-D' && request.args[3] == 'FORWARD' &&
		request.args[length(request.args) - 1] == 'MCL_AN_TF');
assert_true(!deleted_before_append, 'failed Guard-order append keeps the original Task 4 hook active');

let guard_verify_failure = apply(runtime_with({ guard: true, guard_before_anchor_is_wrong: true,
	capture_failure: 'read', capture_fail_at: 2 }), staged);
assert_equal(guard_verify_failure.repair_needed, true,
	'Guard transitional verification failure returns repair-needed with detectable duplicate hooks');
let guard_delete_failure = apply(runtime_with({ guard: true, guard_before_anchor_is_wrong: true,
	fail_when: (r) => r.args[2] == '-D' && r.args[3] == 'FORWARD' &&
		r.args[length(r.args) - 1] == 'MCL_AN_TF' }), staged);
assert_equal(guard_delete_failure.repair_needed, true,
	'Guard old-hook delete failure returns repair-needed instead of opening the path');

assert_throws(() => apply(runtime_with({ extra_generation_rule: true }), staged), 'INTERNAL');
assert_throws(() => apply(runtime_with({ missing_set_member: true }), staged), 'INTERNAL');
assert_throws(() => apply(runtime_with({ extra_set_member: true }), staged), 'INTERNAL');
assert_throws(() => apply(runtime_with({ wrong_set_schema: true }), staged), 'INTERNAL');
assert_throws(() => apply(runtime_with({ foreign_generation_jump: true }), staged), 'INTERNAL');
assert_throws(() => apply(runtime_with({ foreign_generation_goto: true }), staged), 'INTERNAL');
assert_throws(() => apply(runtime_with({ foreign_generation_long_goto: true }), staged), 'INTERNAL');
let same_id_extra = apply(runtime_with({ inventory: idempotent.inventory,
	extra_generation_rule: true }), idempotent);
assert_equal(same_id_extra.stage, 'verify-generation',
	'same-generation reconciliation rejects extra generation rules structurally');

let tampered = json(encoded(staged));
tampered.stages.prepare[0] = command('sh', [ '-c', 'iptables -F; nft delete table inet miclash_guard_bootstrap_v1' ]);
let rejected_runtime = runtime_with();
assert_throws(() => apply(rejected_runtime, tampered), 'INVALID_ARGUMENT');
assert_equal(length(rejected_runtime.process.calls), 0,
	'tampered compiled executables are rejected before any process invocation');

let guard_tamper = json(encoded(staged));
guard_tamper.stages.prepare[0] = command('iptables',
	[ '-t', 'filter', '-F', 'MICLASH_GUARD_FORWARD' ]);
let guard_rejected = runtime_with();
assert_throws(() => apply(guard_rejected, guard_tamper), 'INVALID_ARGUMENT');
assert_equal(length(guard_rejected.process.calls), 0,
	'tampered fixed argv cannot target Guard before validation');

function exact_replies(id, counters, extra) {
	let c = counters ?? '0:0', replies = {};
	replies['iptables-save:-t mangle'] = { stdout: '*mangle\n:MCL_AN_PR - [' + c + ']\n-A MCL_AN_PR -j MCL_PR_' + id +
		'\n' + (extra ?? '') + ':MCL_AN_OU - [0:0]\n-A MCL_AN_OU -j MCL_OU_' + id +
		'\n-A PREROUTING -j MCL_AN_PR\n-A OUTPUT -j MCL_AN_OU\nCOMMIT\n' };
	replies['iptables-save:-t filter'] = { stdout: '*filter\n:MCL_AN_TI - [0:0]\n-A MCL_AN_TI -j MCL_TI_' + id +
		'\n:MCL_AN_TF - [0:0]\n-A MCL_AN_TF -j MCL_TF_' + id +
		'\n-A INPUT -j MCL_AN_TI\n-A FORWARD -j MCL_AN_TF\nCOMMIT\n' };
	replies['ip6tables-save:-t mangle'] = { stdout: '*mangle\nCOMMIT\n' };
	replies['ip6tables-save:-t filter'] = { stdout: '*filter\nCOMMIT\n' };
	return replies;
};

function capture_runtime(outputs, mode) {
	let rt = runtime_with(), calls = [];
	rt.fs = fs();
	rt.process.run = (request) => ({ code: 0, stdout: null, stderr: null });
	rt.fs.popen = (fixed, access) => {
		push(calls, fixed);
		let value = outputs[fixed] ?? '', offset = 0;
		return {
			read: (amount) => {
				if (mode == 'read-error') return null;
				if (mode == 'oversize') return sprintf('%04096d', 0);
				let chunk = substr(value, offset, amount); offset += length(chunk); return chunk;
			},
			close: () => mode == 'close-error' ? 1 : 0
		};
	};
	rt.capture_calls = calls;
	return rt;
};

let capture_docs = exact_replies('cab123cab123');
let captured_rt = capture_runtime({
	'iptables-save -t mangle': capture_docs['iptables-save:-t mangle'].stdout,
	'iptables-save -t filter': capture_docs['iptables-save:-t filter'].stdout,
	'ip6tables-save -t mangle': capture_docs['ip6tables-save:-t mangle'].stdout,
	'ip6tables-save -t filter': capture_docs['ip6tables-save:-t filter'].stdout
});
assert_equal(observe(captured_rt).generation, 'cab123cab123',
	'production status-only adapter uses bounded fixed-command capture');
assert_equal(encoded(captured_rt.capture_calls), encoded([
	'iptables-save -t mangle', 'iptables-save -t filter',
	'ip6tables-save -t mangle', 'ip6tables-save -t filter'
]), 'capture surface is limited to fixed save commands');
for (let mode in [ 'read-error', 'close-error', 'oversize' ])
	assert_throws(() => observe(capture_runtime(capture_docs, mode)), 'INTERNAL');

let observed = observe(runtime_with({ replies: exact_replies('cab123cab123') }));
assert_equal(observed.generation, 'cab123cab123',
	'observe derives the selected generation from the exact permanent anchor');

let counted = observe(runtime_with({ replies: exact_replies('def456def456', '3:100') }));
assert_equal(counted.generation, 'def456def456',
	'observe accepts nonzero packet counters without weakening topology checks');

let ambiguous = observe(runtime_with({ replies:
	exact_replies('cab123cab123', null, '-A MCL_AN_PR -j RETURN\n') }));
assert_equal(ambiguous.generation, null,
	'observe rejects a permanent anchor with any extra rule');

let partial_replies = exact_replies('cab123cab123');
partial_replies['iptables-save:-t mangle'].stdout = replace(
	partial_replies['iptables-save:-t mangle'].stdout, 'MCL_OU_cab123cab123', 'MCL_OU_def456def456');
assert_equal(observe(runtime_with({ replies: partial_replies })).generation, null,
	'observe rejects mixed generations across PREROUTING and OUTPUT');
let duplicate_hook = exact_replies('cab123cab123');
duplicate_hook['iptables-save:-t mangle'].stdout = replace(
	duplicate_hook['iptables-save:-t mangle'].stdout, '-A OUTPUT -j MCL_AN_OU\n',
	'-A OUTPUT -j MCL_AN_OU\n-A OUTPUT -j MCL_AN_OU\n');
assert_equal(observe(runtime_with({ replies: duplicate_hook })).generation, null,
	'observe rejects duplicate permanent built-in hooks');
let parameterized_hook = exact_replies('cab123cab123');
parameterized_hook['iptables-save:-t mangle'].stdout = replace(
	parameterized_hook['iptables-save:-t mangle'].stdout, '-A OUTPUT -j MCL_AN_OU\n',
	'-A OUTPUT -j MCL_AN_OU\n-A OUTPUT -d 192.0.2.1 -j MCL_AN_OU\n');
assert_equal(observe(runtime_with({ replies: parameterized_hook })).generation, null,
	'observe rejects parameterized duplicate traversal to an owned anchor');

let invalid_cleanup = runtime_with();
assert_throws(() => cleanup(invalid_cleanup,
	{ preserve_guard: true, generations: [ 'bad' ] }), 'INVALID_ARGUMENT');
assert_equal(length(invalid_cleanup.process.calls), 0,
	'cleanup validates every generation before its first mutation');
let clean = runtime_with({ absent: true, no_anchors: true, inventory: [] });
let clean_state = cleanup(clean, { preserve_guard: true, generations: [ 'aaaaaaaaaaaa' ] });
assert_equal(clean_state.guard_preserved, true, 'cleanup explicitly preserves Guard');
assert_true(index(encoded(clean.process.calls), 'MICLASH_GUARD_FORWARD') < 0,
	'cleanup never invokes Guard chains');
let orphan_cleanup = runtime_with({ no_anchors: true, inventory: [], orphan_generation: 'cccccccccccc' });
assert_equal(cleanup(orphan_cleanup, { preserve_guard: true, generations: [] }).clean, true,
	'cleanup discovers and removes complete unlisted owned generations');
let orphan_removed = false;
for (let request in orphan_cleanup.process.calls)
	orphan_removed = orphan_removed || (request.args[2] == '-X' && request.args[3] == 'MCL_PR_cccccccccccc');
assert_true(orphan_removed, 'global cleanup does not depend on caller generation hints');
let ambiguous_cleanup = runtime_with({ no_anchors: true, inventory: [],
	orphan_generation: 'dddddddddddd', partial_orphan: true });
assert_throws(() => cleanup(ambiguous_cleanup, { preserve_guard: true, generations: [] }), 'INTERNAL');
for (let request in ambiguous_cleanup.process.calls)
	assert_true(request.args[2] != '-D' && request.args[2] != '-F' && request.args[2] != '-X' &&
		request.args[0] != 'destroy', 'ambiguous owned inventory fails before mutation');
let referenced_orphan = runtime_with({ no_anchors: true, inventory: [],
	orphan_generation: 'eeeeeeeeeeee', orphan_foreign_edge: true });
assert_throws(() => cleanup(referenced_orphan, { preserve_guard: true, generations: [] }), 'INTERNAL');
for (let request in referenced_orphan.process.calls)
	assert_true(request.args[2] != '-D' && request.args[2] != '-F' && request.args[2] != '-X' &&
		request.args[0] != 'destroy', 'foreign-referenced orphan fails before cleanup mutation');

function assert_cleanup_preflight_failure(options, message) {
	let rt = runtime_with({ ...options, states: {
		iptables: { MCL_AN_PR: 'bbbbbbbbbbbb', MCL_AN_OU: 'bbbbbbbbbbbb', MCL_AN_TI: 'bbbbbbbbbbbb', MCL_AN_TF: 'bbbbbbbbbbbb' },
		ip6tables: { MCL_AN_PR: '', MCL_AN_OU: '', MCL_AN_TI: '', MCL_AN_TF: '' }
	} });
	assert_throws(() => cleanup(rt, { preserve_guard: true, generations: [] }), 'INTERNAL');
	for (let request in rt.process.calls)
		assert_true(request.args[2] != '-D' && request.args[2] != '-F' && request.args[2] != '-X' &&
			request.args[0] != 'destroy', message + ': zero mutations before full preflight');
};
assert_cleanup_preflight_failure({ duplicate_permanent_hook: true }, 'duplicate permanent hook');
assert_cleanup_preflight_failure({ parameterized_canonical_edge: true }, 'parameterized canonical-source edge');
assert_cleanup_preflight_failure({ duplicate_canonical_edge: true }, 'duplicate canonical incoming edge');
assert_cleanup_preflight_failure({ cross_family_partial: true }, 'cross-family partial generation inventory');
for (let spelling in [ '-j', '-g', '--goto' ])
	assert_cleanup_preflight_failure({ foreign_anchor_verdict: spelling },
		'foreign-chain ' + spelling + ' edge to permanent anchor');
for (let edge in [ '-A FOREIGN -j MCL_AN_PR',
	'-A FOREIGN -g MCL_AN_PR', '-A FOREIGN --goto MCL_AN_PR' ]) {
	let recapture = runtime_with({ no_anchors: true, inventory: [],
		orphan_generation: 'ffffffffffff', post_cleanup_edge: edge });
	assert_throws(() => cleanup(recapture, { preserve_guard: true, generations: [] }), 'INTERNAL');
	let mutated = false;
	for (let request in recapture.process.calls)
		mutated = mutated || request.args[2] == '-D' || request.args[2] == '-F' || request.args[2] == '-X' ||
			request.args[0] == 'destroy';
	assert_true(mutated, 'final recapture rejects injected edge after executing the immutable plan');
}
assert_throws(() => cleanup(runtime_with(),
	{ preserve_guard: true, generations: [ 'aaaaaaaaaaaa' ] }), 'INTERNAL');
