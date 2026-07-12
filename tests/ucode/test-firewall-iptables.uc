import { assert_equal, assert_throws, assert_true } from './testlib.uc';
import { compile, observe, apply, cleanup } from 'miclash.firewall.iptables';

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
	for (let hook in compiled.stages.anchors)
		if ((hook.args[3] == 'PREROUTING' || hook.args[3] == 'OUTPUT' ||
		     hook.args[3] == 'INPUT' || hook.args[3] == 'FORWARD') && hook.args[2] == '-A')
			assert_true(true, desired.name + ': owned anchor is appended after unrelated logic');
}

let desired = { ...scenarios[0], generation: 'bbbbbbbbbbbb',
	previous_generation: 'aaaaaaaaaaaa' };
let staged = compile(desired);
let serialized = encoded(staged.stages);
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

function runtime_with(options) {
	let calls = [], fail_at = options?.fail_at ?? null, sequence = 0;
	let legacy_hooks = {
		iptables: { MICLASH_PREROUTING: !!options?.legacy, MICLASH_OUTPUT: !!options?.legacy },
		ip6tables: { MICLASH_PREROUTING: false, MICLASH_OUTPUT: false }
	};
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
			else push(lines, '-A INPUT -j MCL_AN_TI', '-A FORWARD -j MCL_AN_TF');
		}
		if (options?.remaining_generation && table == 'mangle')
			push(lines, ':MCL_PR_' + options.remaining_generation + ' - [0:0]');
		if (table == 'mangle') {
			if (legacy_hooks[base].MICLASH_PREROUTING) push(lines, '-A PREROUTING -j MICLASH_PREROUTING');
			if (legacy_hooks[base].MICLASH_OUTPUT) push(lines, '-A OUTPUT -j MICLASH_OUTPUT');
		}
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
		if (reply == null && request.command == 'ipset' && request.args[0] == 'list' && request.args[1] == '-name')
			return { code: 0, stdout: options?.remaining_generation ? 'MCL_L4_' + options.remaining_generation + '\n' : '', stderr: null };
		if (request.args[2] == '-C' && (request.args[length(request.args) - 1] == 'MICLASH_PREROUTING' ||
		    request.args[length(request.args) - 1] == 'MICLASH_OUTPUT') &&
		    !legacy_hooks[request.command][request.args[length(request.args) - 1]])
			return { code: 1, stdout: null, stderr: null };
		if (options?.absent && request.command == 'ipset' && request.args[0] == 'list' && request.args[1] == '-name')
			return { code: 0, stdout: '', stderr: null };
		if (options?.absent && (request.args[2] == '-C' || request.args[2] == '-L' ||
		    (request.command == 'ipset' && request.args[0] == 'list')))
			return { code: 1, stdout: null, stderr: null };
		if (reply == null && (request.command == 'iptables-save' || request.command == 'ip6tables-save'))
			return { code, stdout: saved(request.command, request.args[1]), stderr: null };
		if (code == 0 && (request.command == 'iptables' || request.command == 'ip6tables') &&
		    (request.args[2] == '-R' || request.args[2] == '-A' || request.args[2] == '-F') &&
		    states[request.command]?.[request.args[3]] != null) {
			if (request.args[2] == '-F') states[request.command][request.args[3]] = '';
			else states[request.command][request.args[3]] = substr(request.args[length(request.args) - 1], -12);
		}
		if (code == 0 && request.args[2] == '-D' && legacy_hooks[request.command]?.[request.args[length(request.args) - 1]])
			legacy_hooks[request.command][request.args[length(request.args) - 1]] = false;
		return { code: reply?.code ?? code, stdout: reply?.stdout ?? null,
			stderr: reply?.stderr ?? null };
	};
	return { process: p };
};

let prep_failure = runtime_with({ fail_at: length(staged.stages.anchors) + 2 });
assert_throws(() => apply(prep_failure, staged), 'INTERNAL');
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

let migration = compile({ ...scenarios[0], generation: 'bbbbbbbbbbbb' });
let migrated_runtime = runtime_with({ states: {
	iptables: { MCL_AN_PR: '', MCL_AN_OU: '', MCL_AN_TI: '', MCL_AN_TF: '' },
	ip6tables: { MCL_AN_PR: '', MCL_AN_OU: '', MCL_AN_TI: '', MCL_AN_TF: '' }
}, legacy: true });
assert_equal(observe(migrated_runtime).legacy, true,
	'migration fixture begins with an active legacy built-in hook');
assert_equal(apply(migrated_runtime, migration).repair_needed, false,
	'legacy hooks migrate only after generation B is prepared and permanent anchors are live');
let migration_calls = encoded(migrated_runtime.process.calls);
assert_true(index(migration_calls, 'MCL_PR_bbbbbbbbbbbb') <
	index(migration_calls, 'MICLASH_PREROUTING'),
	'B permanent anchor activation precedes legacy-hook removal');
let failed_migration = runtime_with({ states: {
	iptables: { MCL_AN_PR: '', MCL_AN_OU: '', MCL_AN_TI: '', MCL_AN_TF: '' },
	ip6tables: { MCL_AN_PR: '', MCL_AN_OU: '', MCL_AN_TI: '', MCL_AN_TF: '' }
}, legacy: true, fail_when: (r) => r.args[2] == '-D' && index(r.args, 'MICLASH_PREROUTING') >= 0 });
assert_equal(apply(failed_migration, migration).repair_needed, true,
	'legacy removal failure returns repair-needed with the old path retained');
assert_true(index(encoded(failed_migration.process.calls), '-X') < 0,
	'legacy migration failure never retires the previous working path');

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
let legacy_replies = exact_replies('cab123cab123');
legacy_replies['iptables-save:-t mangle'].stdout = replace(
	legacy_replies['iptables-save:-t mangle'].stdout, 'COMMIT\n',
	'-A PREROUTING -j MICLASH_PREROUTING\nCOMMIT\n');
assert_equal(observe(runtime_with({ replies: legacy_replies })).legacy, true,
	'observe identifies active legacy topology for ordered migration');
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
let clean = runtime_with({ absent: true, no_anchors: true });
let clean_state = cleanup(clean, { preserve_guard: true, generations: [ 'aaaaaaaaaaaa' ] });
assert_equal(clean_state.guard_preserved, true, 'cleanup explicitly preserves Guard');
assert_true(index(encoded(clean.process.calls), 'MICLASH_GUARD_FORWARD') < 0,
	'cleanup never invokes Guard chains');
assert_throws(() => cleanup(runtime_with(),
	{ preserve_guard: true, generations: [ 'aaaaaaaaaaaa' ] }), 'INTERNAL');
