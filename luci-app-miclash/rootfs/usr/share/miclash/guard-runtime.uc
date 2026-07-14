#!/usr/bin/ucode

import * as guard from 'miclash.guard';
import * as runtime_guard from 'miclash.guard_runtime';
import * as runtime_module from 'miclash.runtime';
import { acquire, assert_held, release } from 'miclash.mutation_lock';
import { atomic_write } from 'miclash.storage';
import { fail } from 'miclash.errors';

const EMERGENCY = 'miclash_guard_emergency_v1';
const PRIMARY = 'miclash_guard_bootstrap_v1';
const BARRIER = '/var/run/miclash/package-removal';
const BATCH = '/tmp/miclash/guard-runtime.nft';

function trusted_package_barrier(runtime) {
	let root = runtime.fs.lstat('/var/run/miclash'), leaf = runtime.fs.lstat(BARRIER);
	let canonical = runtime.fs.realpath(BARRIER);
	return root?.type == 'directory' && root.uid == 0 && (root.mode & 0o077) == 0 &&
		leaf?.type == 'directory' && leaf.uid == 0 && (leaf.mode & 0o077) == 0 &&
		(canonical == BARRIER || canonical == '/run/miclash/package-removal' ||
		 canonical == '/tmp/run/miclash/package-removal');
};
function nft_binary(runtime) {
	for (let path in [ '/usr/sbin/nft', '/sbin/nft', '/usr/bin/nft' ])
		if (runtime.fs.lstat(path)?.type == 'file') return path;
	return null;
};
function capture(command) {
	let pipe = require('fs').popen(command + ' 2>/dev/null', 'r');
	if (pipe == null) return null;
	let output = pipe.read('all');
	return pipe.close() == 0 ? output : null;
};
function inventory(nft) { return guard.owned_nft_tables(capture(nft + ' -j list tables')); };
function verified(nft, table) {
	return guard.verify_nft_table(capture(nft + ' -j list table inet ' + table), table);
};
function mutate(runtime, lease, nft, batch) {
	assert_held(runtime, lease);
	for (let path in [ runtime.paths.tmp, runtime.paths.run ])
		if (runtime.process.run({ command: '/bin/mkdir', args: [ '-p', path ] }).code != 0)
			return false;
	atomic_write(runtime, BATCH, batch, 0o600);
	let ok = runtime.process.run({ command: nft, args: [ '-f', BATCH ] }).code == 0;
	assert_held(runtime, lease);
	return ok;
};
function mutate_terminal(runtime, lease, nft, batch) {
	assert_held(runtime, lease);
	for (let path in [ runtime.paths.tmp, runtime.paths.run ])
		if (runtime.process.run({ command: '/bin/mkdir', args: [ '-p', path ] }).code != 0)
			return false;
	atomic_write(runtime, BATCH, batch, 0o600);
	// This assertion is deliberately immediately before the one atomic nft
	// mutation. Once nft succeeds, no later lease operation may flip success.
	assert_held(runtime, lease);
	return runtime.process.run({ command: nft, args: [ '-f', BATCH ] }).code == 0;
};
function ensure_table(runtime, lease, nft, table) {
	let present = inventory(nft);
	if (present == null) return false;
	let occupied = false;
	for (let item in present) if (item == table) occupied = true;
	if (!verified(nft, table) &&
	    !mutate(runtime, lease, nft, guard.nft_ruleset(table, occupied)))
		return false;
	assert_held(runtime, lease);
	return verified(nft, table);
};
function protect(runtime, lease, nft) { return ensure_table(runtime, lease, nft, EMERGENCY); };
function release_emergency(runtime, lease, nft) {
	// Enabled runtime release must never consume the independent crash owner.
	// Prove/repair primary while emergency still protects direct traffic.
	if (!ensure_table(runtime, lease, nft, PRIMARY)) return false;
	let present = inventory(nft);
	if (present == null) return false;
	let occupied = false;
	for (let table in present) if (table == EMERGENCY) occupied = true;
	if (!occupied) return true;
	if (!mutate(runtime, lease, nft, 'delete table inet ' + EMERGENCY + '\n')) return false;
	present = inventory(nft);
	if (present == null) return false;
	for (let table in present) if (table == EMERGENCY) return false;
	return verified(nft, PRIMARY);
};
function disable_bootstrap(runtime, lease, nft) {
	let present = inventory(nft);
	if (present == null) return false;
	if (!length(present)) return true;
	let lines = [];
	for (let table in present) push(lines, 'delete table inet ' + table);
	push(lines, '');
	if (!mutate_terminal(runtime, lease, nft, join('\n', lines))) return false;
	// The batch is atomic. A successful nft invocation is the terminal proof;
	// another inventory could only convert committed success into an unsafe
	// failure after all bootstrap protection has already been removed.
	return true;
};
function stdin() { return require('fs').readfile('/dev/stdin'); };

function main() {
	if (length(ARGV) < 1 || length(ARGV) > 2 ||
	    (ARGV[0] != 'protect' && ARGV[0] != 'release' && ARGV[0] != 'disable' && ARGV[0] != 'verify-nft' &&
	     ARGV[0] != 'verify-iptables4' && ARGV[0] != 'verify-iptables6'))
		die('usage: guard-runtime.uc {protect|release|disable|verify-nft|verify-iptables4|verify-iptables6} [interfaces]\n');
	let runtime = runtime_module.create();
	runtime.mutation_lock_token = getenv('MICLASH_MUTATION_LOCK_TOKEN');
	if (runtime.mutation_lock_token == null || !length(runtime.mutation_lock_token)) die('BUSY\n');
	let package_mode = getenv('MICLASH_MUTATION_LOCK_PACKAGE') == '1';
	if (package_mode && !trusted_package_barrier(runtime)) die('BUSY\n');
	let lease = acquire(runtime, { barrier: package_mode ? 'package' : 'normal', wait_ms: 0 });
	let ok = false, thrown = null, terminal_success = false;
	try {
		assert_held(runtime, lease);
		if (ARGV[0] == 'protect' || ARGV[0] == 'release' || ARGV[0] == 'disable') {
			let nft = nft_binary(runtime);
			if (nft == null) fail('INTERNAL');
			if (ARGV[0] == 'protect') ok = protect(runtime, lease, nft);
			else if (ARGV[0] == 'release') ok = release_emergency(runtime, lease, nft);
			else {
				ok = disable_bootstrap(runtime, lease, nft);
				terminal_success = ok;
			}
		}
		else {
			let expected = runtime_guard.interfaces(ARGV[1] ?? '');
			ok = ARGV[0] == 'verify-nft' ? runtime_guard.verify_nft(stdin(), expected) :
				runtime_guard.verify_iptables(stdin(), ARGV[0] == 'verify-iptables4' ? 'ipv4' : 'ipv6', expected);
		}
		if (!terminal_success) assert_held(runtime, lease);
	}
	catch (error) { thrown = error; }
	try { release(runtime, lease); }
	catch (error) { if (!terminal_success && thrown == null) thrown = error; }
	if (thrown != null || !ok) die((thrown?.code ?? thrown?.message ?? 'INTERNAL') + '\n');
};

main();
