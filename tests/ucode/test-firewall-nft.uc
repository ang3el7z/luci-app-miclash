import { assert_equal, assert_throws, assert_true } from './testlib.uc';
import { compile, observe, apply, cleanup } from 'miclash.firewall.nft';
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

for (let desired in scenarios) {
	let compiled = compile(desired);
	let golden = filesystem.readfile(root + '/nft/' + desired.expected.nft);
	assert_equal(compiled.model.normalized, compiler_projection(golden),
		desired.name + ': exact normalized compiler-owned projection of full nft golden');
	assert_true(!!match(compiled.generation, /^[0-9a-f]{12}$/), desired.name + ': deterministic generation id');
	assert_equal(compile(desired).batch, compiled.batch, desired.name + ': deterministic batch');
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
}

let open = compile(scenarios[1]);
assert_true(index(open.model.normalized, 'proxy ip daddr @proxy_servers4 return') <
	index(open.model.normalized, 'meta l4proto tcp tproxy'),
	'client proxy-server bypass precedes redirect when Guard is off');

for (let invalid in [
	{ ...scenarios[0], lan: [ 'br-lan\"; delete table inet miclash_guard_bootstrap_v1' ] },
	{ ...scenarios[0], server_ips: [ '999.1.1.1' ] },
	{ ...scenarios[0], fakeip_cidrs: [ '10.0.0.0/99' ] },
	{ ...scenarios[0], set_names: { local4: 'user-controlled-set' } },
	{ ...scenarios[0], generation: 'bad-name' }
])
	assert_throws(() => compile(invalid), 'INVALID_ARGUMENT', 'invalid nft input rejected');

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
	}) }
}));
assert_equal(observation.generation, 'abc123abc123', 'structured observation identifies active generation');
let anchor_observation = observe(runtime_with({
	'nft:-j list table inet miclash': { code: 0, stdout: sprintf('%J', { nftables: [
		{ chain: { family: 'inet', table: 'miclash', name: 'prerouting' } },
		{ rule: { family: 'inet', table: 'miclash', chain: 'prerouting',
			expr: [ { jump: { target: 'prerouting_g_def456def456' } } ] } }
	] }) }
}));
assert_equal(anchor_observation.generation, 'def456def456',
	'structured anchor observation identifies switched generation without stale table comments');
let capture_runtime = runtime_with({
	'nft:-j list table inet miclash': { code: 0 },
});
capture_runtime.fs.popen = (command, mode) => ({
	read: () => sprintf('%J', { nftables: [ { rule: { family: 'inet', table: 'miclash',
		chain: 'prerouting', expr: [ { jump: { target: 'prerouting_g_cab123cab123' } } ] } } ] }),
	close: () => 0
});
assert_equal(observe(capture_runtime).generation, 'cab123cab123',
	'production observation captures nft output when process adapter returns status only');

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
ok.process.replies['nft:-f ' + path] = { code: 0 };
ok.process.replies['nft:-j list table inet miclash'] = { code: 0, stdout: sprintf('%J', {
	nftables: [ { table: { family: 'inet', name: 'miclash', comment:
		'miclash:schema=1;generation=' + compiled.generation } } ]
}) };
assert_equal(apply(ok, compiled).generation, compiled.generation, 'apply verifies the active generation');
assert_equal(ok.fs.calls.open[0].perm, 0o600, 'batch is created mode 0600');
assert_true(!exists(ok.fs.files, path), 'successful apply removes its batch');

let clean = runtime_with({
	'nft:delete table inet miclash': { code: 0 },
	'nft:-j list table inet miclash': { code: 1 }
});
assert_true(cleanup(clean, { preserve_guard: true }).clean, 'cleanup removes only main owned table');
assert_equal(sprintf('%J', clean.process.calls[0].args), sprintf('%J', [ 'delete', 'table', 'inet', 'miclash' ]), 'cleanup scope is exact');
