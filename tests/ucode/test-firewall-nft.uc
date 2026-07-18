import { assert_equal, assert_throws, assert_true } from './testlib.uc';
import { compile, observe, apply, cleanup, executable_projection } from 'miclash.firewall.nft';
import { fs, entropy } from './fakes.uc';

let filesystem = require('fs');
let root = 'tests/fixtures/network';
let scenarios = json(filesystem.readfile(root + '/scenarios.json')).scenarios;

function compiler_projection(full_contract) {
	let lines = [];
	for (let line in split(full_contract, '\n'))
		if (!match(line, /^add (table|set|element|chain) inet miclash_guard( |$)/) &&
		    !match(line, /^add rule inet miclash_guard /))
			push(lines, line);
	return join('\n', lines);
};

function executable_semantics(contract) {
	let lines = [];
	for (let line in split(contract, '\n'))
		if (match(line, /^add (element|rule) inet miclash /)) push(lines, line);
	return join('\n', lines) + '\n';
};

for (let desired in scenarios) {
	let compiled = compile(desired);
	let golden = filesystem.readfile(root + '/nft/' + desired.expected.nft);
	assert_equal(compiled.model.normalized, compiler_projection(golden),
		desired.name + ': exact normalized compiler-owned projection of full nft golden');
	assert_true(!!match(compiled.generation, /^[0-9a-f]{12}$/), desired.name + ': deterministic generation id');
	assert_equal(compile(desired).batch, compiled.batch, desired.name + ': deterministic batch');
	assert_equal(executable_projection(compiled.batch, compiled.generation),
		executable_semantics(compiler_projection(golden)),
		desired.name + ': executable transaction exactly preserves ordered golden semantics');
	let switched = compile({ ...desired, generation: '111111111111',
		previous_generation: '000000000000' });
	let batch_golden = filesystem.readfile(root + '/nft-batch/' + desired.expected.nft);
	assert_true(batch_golden != null, desired.name + ': missing complete executable batch golden');
	assert_equal(switched.batch, batch_golden,
		desired.name + ': exact full batch topology including old-generation deletion');
	assert_true(index(compiled.batch, 'miclash_guard_bootstrap') < 0 &&
		index(compiled.batch, 'miclash_guard_emergency') < 0 &&
		index(compiled.batch, 'miclash_guard ') < 0,
		desired.name + ': compiler cannot own Guard tables');
	assert_true(index(compiled.batch, 'flush chain inet miclash prerouting') >= 0 &&
		index(compiled.batch, 'jump prerouting_g_' + compiled.generation) >= 0,
		desired.name + ': one transaction links the generation through a stable anchor');
	assert_true(index(compiled.batch, 'add chain inet miclash prerouting_g_' + compiled.generation) >= 0 &&
		index(compiled.batch, 'add chain inet miclash output_g_' + compiled.generation) >= 0,
		desired.name + ': generation entry chains exist before anchor links');
	for (let family in desired.ip_families) {
		let local = family == 'ipv4' ? 'ip daddr @local4 return' : 'ip6 daddr @local6 return';
		let local_at = index(compiled.model.normalized, 'add rule inet miclash output ' + local);
		let mark_at = index(compiled.model.normalized,
			'add rule inet miclash output meta nfproto ' + family + ' meta mark 0x0');
		assert_true(local_at >= 0 && mark_at > local_at,
			desired.name + ': router replies to local destinations bypass proxy marks for ' + family);
	}
}

let open = compile(scenarios[1]);
assert_true(index(open.model.normalized, 'proxy ip daddr @proxy_servers4 return') <
	index(open.model.normalized, 'meta l4proto tcp tproxy'),
	'client proxy-server bypass precedes redirect when Guard is off');

for (let invalid in [
	{ ...scenarios[0], lan: [ 'br-lan\"; delete table inet miclash_guard_bootstrap_v1' ] },
	{ ...scenarios[0], server_ips: [ '999.1.1.1' ] },
	{ ...scenarios[0], server_ips: [ ':' ] },
	{ ...scenarios[0], server_ips: [ '1:2' ] },
	{ ...scenarios[0], server_ips: [ '2001:db8::1::2' ] },
	{ ...scenarios[0], server_ips: [ '192.0.2.1::' ] },
	{ ...scenarios[0], server_ips: [ 'ffff:192.0.2.1::' ] },
	{ ...scenarios[0], fakeip_cidrs: [ '10.0.0.0/99' ] },
	{ ...scenarios[0], fakeip_cidrs: [ ':/64' ] },
	{ ...scenarios[0], fakeip_cidrs: [ '192.0.2.1::/64' ] },
	{ ...scenarios[0], fakeip_cidrs: [ '2001:db8::/129' ] },
	{ ...scenarios[0], lan: [ ':' ] },
	{ ...scenarios[0], lan: [ 'bad/name' ] },
	{ ...scenarios[0], lan: [ 'bad name' ] },
	{ ...scenarios[0], lan: [ '.' ] },
	{ ...scenarios[0], lan: [ '..' ] },
	{ ...scenarios[0], lan: [ 'abcdefghijklmnop' ] },
	{ ...scenarios[0], set_names: { local4: 'user-controlled-set' } },
	{ ...scenarios[0], generation: 'bad-name' }
])
	assert_throws(() => compile(invalid), 'INVALID_ARGUMENT', 'invalid nft input rejected');
for (let valid6 in [ '::', '::1', '2001:db8::1', '2001:db8:0:1:2:3:4:5', '::ffff:192.0.2.1' ])
	assert_true(compile({ ...scenarios[0], server_ips: [ valid6 ] }) != null,
		'strict IPv6 parser accepts valid boundary ' + valid6);
for (let valid_cidr6 in [ '::/0', '2001:db8::1/128' ])
	assert_true(compile({ ...scenarios[0], fakeip_cidrs: [ valid_cidr6 ] }) != null,
		'strict IPv6 CIDR parser accepts prefix boundary ' + valid_cidr6);

let semantic = compile(scenarios[0]).generation;
assert_equal(compile({ ...scenarios[0], previous_generation: 'aaaaaaaaaaaa',
	metadata: { z: 1, a: 2 }, observed_at: 1234 }).generation, semantic,
	'operational and metadata fields do not churn generation');
let reordered = {
	ip_families: scenarios[0].ip_families, device_policies: scenarios[0].device_policies,
	fakeip_cidrs: scenarios[0].fakeip_cidrs, server_ips: scenarios[0].server_ips,
	quic: scenarios[0].quic, guard: scenarios[0].guard, wan: scenarios[0].wan,
	lan: scenarios[0].lan, interface_mode: scenarios[0].interface_mode,
	proxy_mode: scenarios[0].proxy_mode
};
assert_equal(compile(reordered).generation, semantic, 'serialization key order does not churn generation');
assert_true(compile({ ...scenarios[0], quic: !scenarios[0].quic }).generation != semantic,
	'meaningful semantic policy change creates a new generation');

function runtime_with(replies) {
	let p = { calls: [], replies: replies ?? {} };
	p.run = (request) => {
		push(p.calls, request);
		let reply = p.replies[request.command + ':' + join(' ', request.args ?? [])] ?? {};
		return { code: reply.code ?? 0, stdout: reply.stdout ?? null, stderr: reply.stderr ?? null };
	};
	let f = fs();
	return { fs: f, process: p, random: entropy(), paths: { tmp: '/tmp/miclash' } };
};

let observation = observe(runtime_with({
	'nft:-j list table inet miclash': { code: 0, stdout: sprintf('%J', {
		nftables: [ { table: { family: 'inet', name: 'miclash', comment: 'miclash:schema=1;generation=abc123abc123' } } ]
	}) },
	'nft:list table inet miclash': { code: 1 }
}));
assert_equal(observation.generation, null, 'stale table comment cannot identify active generation');
let anchor_observation = observe(runtime_with({
	'nft:-j list table inet miclash': { code: 0, stdout: sprintf('%J', { nftables: [
		{ chain: { family: 'inet', table: 'miclash', name: 'prerouting', type: 'filter',
			hook: 'prerouting', prio: -150, policy: 'accept' } },
		{ rule: { family: 'inet', table: 'miclash', chain: 'prerouting',
			expr: [ { jump: { target: 'prerouting_g_def456def456' } } ] } }
	] }) }
}));
assert_equal(anchor_observation.generation, 'def456def456',
	'structured anchor observation identifies switched generation without stale table comments');
let unrelated = observe(runtime_with({
	'nft:-j list table inet miclash': { code: 0, stdout: sprintf('%J', { nftables: [
		{ chain: { family: 'inet', table: 'miclash', name: 'prerouting', type: 'filter',
			hook: 'prerouting', prio: -150, policy: 'accept' } },
		{ rule: { family: 'inet', table: 'miclash', chain: 'unrelated',
			expr: [ { jump: { target: 'prerouting_g_bad123bad123' } } ] } }
	] }) },
	'nft:list table inet miclash': { code: 0, stdout:
		'chain unrelated {\n jump prerouting_g_bad123bad123\n}\n' }
}));
assert_equal(unrelated.generation, null, 'unrelated JSON or text jump cannot identify active generation');
let text_observation = observe(runtime_with({
	'nft:-j list table inet miclash': { code: 1 },
	'nft:list table inet miclash': { code: 0, stdout:
		'table inet miclash {\n chain prerouting {\n  type filter hook prerouting priority mangle; policy accept;\n  jump prerouting_g_feed12feed12\n }\n}\n' }
}));
assert_equal(text_observation.generation, 'feed12feed12',
	'text fallback requires the exact stable base-chain block and its sole generation jump');
for (let ambiguous_text in [
	'table inet miclash {\n chain prerouting {\n  type filter hook prerouting priority mangle; policy accept;\n  jump prerouting_g_aaaaaaaaaaaa_extra\n }\n}\n',
	'table inet miclash {\n chain prerouting {\n  type filter hook prerouting priority mangle; policy accept;\n  jump prerouting_g_aaaaaaaaaaaa\n  accept\n }\n}\n',
	'table inet miclash {\n chain prerouting {\n  type filter hook prerouting priority mangle; policy accept;\n  jump prerouting_g_aaaaaaaaaaaa\n  jump prerouting_g_bbbbbbbbbbbb\n }\n}\n'
]) {
	let ambiguous = observe(runtime_with({
		'nft:-j list table inet miclash': { code: 1 },
		'nft:list table inet miclash': { code: 0, stdout: ambiguous_text }
	}));
	assert_equal(ambiguous.generation, null,
		'text stable anchor rejects prefix targets and every extra rule');
}
let capture_runtime = runtime_with({
	'nft:-j list table inet miclash': { code: 0 },
});
let capture_once = false;
capture_runtime.fs.popen = (command, mode) => ({
	read: () => capture_once++ ? '' : sprintf('%J', { nftables: [ { rule: { family: 'inet', table: 'miclash',
		chain: 'prerouting', expr: [ { jump: { target: 'prerouting_g_cab123cab123' } } ] } },
		{ chain: { family: 'inet', table: 'miclash', name: 'prerouting', type: 'filter',
			hook: 'prerouting', prio: -150, policy: 'accept' } } ] }),
	close: () => 0
});
assert_equal(observe(capture_runtime).generation, 'cab123cab123',
	'production observation captures nft output when process adapter returns status only');
let oversized = runtime_with({ 'nft:-j list table inet miclash': { code: 0 } });
let oversized_reads = 0;
oversized.fs.popen = () => ({
	read: () => oversized_reads++ < 5000 ? 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx' : '',
	close: () => 0
});
assert_throws(() => observe(oversized), 'INTERNAL', 'oversized nft capture fails explicitly');
let read_error = runtime_with({ 'nft:-j list table inet miclash': { code: 0 } });
read_error.fs.popen = () => ({ read: () => null, close: () => 0 });
assert_throws(() => observe(read_error), 'INTERNAL', 'nft capture read error fails explicitly');
let close_error = runtime_with({ 'nft:-j list table inet miclash': { code: 0 } });
close_error.fs.popen = () => ({ read: () => '', close: () => 1 });
assert_throws(() => observe(close_error), 'INTERNAL', 'nft capture close error fails explicitly');
let close_throw = runtime_with({ 'nft:-j list table inet miclash': { code: 0 } });
close_throw.fs.popen = () => ({ read: () => '', close: () => die('close failed') });
assert_throws(() => observe(close_throw), 'INTERNAL', 'nft capture close exception fails explicitly');

let compiled = compile(scenarios[0]);
for (let fail_at in [ 'open', 'nft', 'observe' ]) {
	let rt = runtime_with({});
	if (fail_at == 'open') rt.fs.fail_on = 'open';
	if (fail_at == 'nft') rt.process.replies['nft:-f /tmp/miclash/nft-' + compiled.generation + '-0000000000000001.batch'] = { code: 1 };
	if (fail_at == 'observe') rt.process.replies['nft:-f /tmp/miclash/nft-' + compiled.generation + '-0000000000000001.batch'] = { code: 0 };
	assert_throws(() => apply(rt, compiled), 'INTERNAL',
		'failure before/inside/after nft -f is surfaced');
	for (let path in rt.fs.files)
		assert_true(!match(path, /\/nft-.*\.batch$/), 'owned temp is always removed');
}

// Characterization: production already retried handle close during final cleanup.
for (let close_mode in [ 'return', 'throw' ]) {
	let close_rt = runtime_with({}), close_calls = 0;
	let original_close = close_rt.fs.close;
	close_rt.fs.close = (handle) => {
		close_calls++;
		if (close_calls == 1) {
			if (close_mode == 'throw') die('batch close failed');
			return null;
		}
		return original_close(handle);
	};
	assert_throws(() => apply(close_rt, compiled), 'INTERNAL',
		'batch-file close ' + close_mode + ' failure cannot report success');
	assert_true(close_calls >= 2, 'final cleanup retries batch-file close after ' + close_mode + ' failure');
	for (let candidate in close_rt.fs.files)
		assert_true(!match(candidate, /\/nft-.*\.batch$/),
			'batch-file close failure cleanup verifies owned temp absence');
}

let symlink_rt = runtime_with({});
let symlink_path = '/tmp/miclash/nft-' + compiled.generation + '-0000000000000001.batch';
symlink_rt.fs.files['/attacker-owned'] = 'unchanged';
symlink_rt.fs.set_symlink(symlink_path, '/attacker-owned');
assert_throws(() => apply(symlink_rt, compiled), 'INTERNAL',
	'exclusive creation rejects a pre-positioned batch symlink');
assert_equal(symlink_rt.fs.files['/attacker-owned'], 'unchanged',
	'symlink rejection does not write or unlink the attacker target');
assert_true(symlink_rt.fs.exists(symlink_path), 'foreign symlink remains outside owned-temp cleanup');

let ok = runtime_with({});
let path = '/tmp/miclash/nft-' + compiled.generation + '-0000000000000001.batch';
function active_reply(id) {
	return { code: 0, stdout: sprintf('%J', { nftables: [
		{ chain: { family: 'inet', table: 'miclash', name: 'prerouting', type: 'filter',
			hook: 'prerouting', prio: -150, policy: 'accept' } },
		{ rule: { family: 'inet', table: 'miclash', chain: 'prerouting',
			expr: [ { jump: { target: 'prerouting_g_' + id } } ] } }
	] }) };
};
ok.process.replies['nft:-f ' + path] = { code: 0 };
ok.process.replies['nft:-j list table inet miclash'] = active_reply(compiled.generation);
let cleanup_lstat = 0;
ok.fs.on_lstat = (candidate) => { if (candidate == path) cleanup_lstat++; };
assert_equal(apply(ok, compiled).generation, compiled.generation, 'apply verifies the active generation');
assert_equal(ok.fs.calls.open[0].perm, 0o600, 'batch is created mode 0600');
assert_true(!exists(ok.fs.files, path), 'successful apply removes its batch');
assert_true(cleanup_lstat > 0, 'successful apply verifies temp absence after unlink');

for (let unlink_mode in [ 'false', 'throw' ]) {
	let stuck = runtime_with({});
	stuck.process.replies['nft:-f ' + path] = { code: 0 };
	stuck.process.replies['nft:-j list table inet miclash'] = active_reply(compiled.generation);
	stuck.fs.unlink = (candidate) => {
		if (unlink_mode == 'throw') die('unlink failed');
		return null;
	};
	assert_throws(() => apply(stuck, compiled), 'INTERNAL',
		'apply cannot succeed when owned temp cleanup returns ' + unlink_mode);
	assert_true(stuck.fs.exists(path), 'failed cleanup remains visible and prevents success');
}

let clean = runtime_with({
	'nft:delete table inet miclash': { code: 0 },
	'nft:-j list table inet miclash': { code: 1 },
	'nft:list table inet miclash': { code: 1 }
});
assert_true(cleanup(clean, { preserve_guard: true }).clean, 'cleanup removes only main owned table');
assert_equal(sprintf('%J', clean.process.calls[0].args), sprintf('%J', [ 'delete', 'table', 'inet', 'miclash' ]), 'cleanup scope is exact');
