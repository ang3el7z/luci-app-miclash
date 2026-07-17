import { assert_equal, assert_throws, assert_true } from './testlib.uc';
import { observe, desired, apply, cleanup, recover } from 'miclash.dns';
import { acquire } from 'miclash.mutation_lock';
import * as fakes from './fakes.uc';

const MANIFEST = '/etc/miclash/dns-ownership.json';
const TARGET = '127.0.0.1#7874';
const BOOT = '12345678-1234-1234-1234-123456789abc';

function encoded(value) { return sprintf('%J', value); };
function snapshot(server, cachesize, noresolv) {
	return {
		server: { present: server != null, value: server ?? [] },
		cachesize: { present: cachesize != null, value: cachesize },
		noresolv: { present: noresolv != null, value: noresolv }
	};
};
function document(original, preexisting, state, transition) {
	return sprintf('%J\n', {
		version: 1, owner: 'miclash', section: 'main', original,
		target_preexisting: preexisting, state, transition: transition ?? null,
		clean: state == 'clean' ? original : null
	});
};
function runtime(options) {
	let filesystem = fakes.fs({
		'/proc/sys/kernel/random/boot_id': BOOT + '\n',
		'/proc/7331/stat': '7331 (dns test) S ' +
			join(' ', [ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 321 ]) + '\n'
	});
	for (let path in [ '/etc', '/etc/miclash', '/var', '/var/run', '/var/run/miclash' ])
		if (filesystem.lstat(path) == null) filesystem.mkdir(path);
	filesystem.set_mode('/etc', 0o755);
	filesystem.set_mode('/etc/miclash', 0o700);
	filesystem.set_mode('/var/run/miclash', 0o700);
	let cursor = fakes.uci(options?.uci ?? { dhcp: {
		main: { '.type': 'dnsmasq', server: [ '1.1.1.1' ], cachesize: '1000' }
	} });
	let process = fakes.process(options?.process);
	let value = {
		fs: filesystem,
		digest: fakes.digest(filesystem),
		clock: fakes.clock(1000), random: fakes.entropy(), process,
		uci: cursor,
		mutation_lock_self: { boot: BOOT, pid: 7331, start: 321 },
		paths: { etc: '/etc/miclash', run: '/var/run/miclash' }
	};
	value.uci_fake = cursor;
	return value;
};
function seed(value, source) { value.fs.writefile(MANIFEST, source); return value; };

let observed = observe(runtime());
assert_equal(observed.section, 'main', 'observation resolves the first dnsmasq section name');
assert_equal(encoded(observed.current), encoded(snapshot([ '1.1.1.1' ], '1000', null)),
	'observation preserves ordered server arrays and absent scalar state');
assert_equal(observed.ownership.status, 'absent', 'missing authority is distinguished from corruption');

let empty_scalar = observe(runtime({ uci: { dhcp: {
	main: { '.type': 'dnsmasq', cachesize: '', noresolv: '' }
} } }));
assert_true(empty_scalar.current.cachesize.present && empty_scalar.current.cachesize.value == '',
	'observation distinguishes an empty scalar from an absent scalar');

let multiple = observe(runtime({ uci: { dhcp: {
	one: { '.type': 'dnsmasq' }, two: { '.type': 'dnsmasq' }
} } }));
assert_true(length(multiple.conflicts) > 0, 'multiple dnsmasq sections are ambiguous');
let none = observe(runtime({ uci: { dhcp: { lan: { '.type': 'dhcp' } } } }));
assert_true(length(none.conflicts) > 0, 'a missing dnsmasq section is ambiguous');
let pending = runtime();
pending.uci_fake.pending_changes.dhcp = { main: { cachesize: '0' } };
assert_true(length(observe(pending).conflicts) > 0, 'pending dhcp deltas block observation');
let corrupt = seed(runtime(), '{"owner":"other"}\n');
assert_equal(observe(corrupt).ownership.status, 'invalid', 'corrupt authority is not trusted');
assert_true(length(observe(corrupt).conflicts) > 0, 'corrupt authority is a conflict');
let hostile = seed(runtime(), document(snapshot([ '1.1.1.1' ], '1000', null), false, 'active'));
hostile.fs.set_mode(MANIFEST, 0o644);
assert_true(length(observe(hostile).conflicts) > 0, 'world-readable authority is rejected');
let metadata_race = seed(runtime(),
	document(snapshot([ '1.1.1.1' ], '1000', null), false, 'clean'));
metadata_race.fs.on_lstat = (path, calls) => {
	if (path == MANIFEST && calls == 2) metadata_race.fs.set_mode(path, 0o644);
};
assert_true(length(observe(metadata_race).conflicts) > 0,
	'manifest mode changes during a stable read are rejected');

let clean_runtime = runtime();
let plan = desired(observe(clean_runtime));
assert_equal(encoded(plan.after), encoded(snapshot([ '1.1.1.1', TARGET ], '0', '1')),
	'active plan appends one target and sets exact scalars');
let preexisting_runtime = runtime({ uci: { dhcp: {
	main: { '.type': 'dnsmasq', server: [ TARGET, '9.9.9.9' ], cachesize: '1000' }
} } });
let preexisting_plan = desired(observe(preexisting_runtime));
assert_equal(encoded(preexisting_plan.after.server.value), encoded([ TARGET, '9.9.9.9' ]),
	'planning retains an original target without duplication');

let active = runtime();
let applied = apply(active, desired(observe(active)));
assert_true(applied.changed && applied.state == 'active', 'apply reports committed active state');
let active_observed = observe(active);
assert_equal(encoded(active_observed.current.server.value), encoded([ '1.1.1.1', TARGET ]),
	'apply preserves foreign servers');
assert_equal(active_observed.ownership.state, 'active', 'apply collapses the transition');
assert_equal(active.process.calls[0].command, '/etc/init.d/dnsmasq', 'restart uses a fixed command path');
assert_equal(join(' ', active.process.calls[0].args), 'restart', 'restart uses fixed argv');
assert_equal(join(' ', active.process.calls[1].args), 'running', 'dnsmasq running is verified');
let first_set = -1, manifest_rename = -1;
for (let i = 0; i < length(active.uci_fake.calls); i++)
	if (active.uci_fake.calls[i].operation == 'set') { first_set = i; break; }
assert_true(length(active.fs.calls.rename) >= 2 && first_set >= 0,
	'journal is durably written before UCI mutation and finalized afterward: renames=' +
	length(active.fs.calls.rename) + ' first_set=' + first_set);

let no_op = apply(active, desired(observe(active)));
assert_true(!no_op.changed, 'reconciling an already active owner is a no-op');

function committed_active() {
	let value = runtime();
	apply(value, desired(observe(value)));
	return value;
};
let committed_drift = committed_active();
committed_drift.uci_fake.values.dhcp.main.cachesize = '77';
assert_throws(() => recover(committed_drift, 'active'), 'CORRUPT_STATE',
	'committed active recovery refuses scalar drift');
let committed_pending = committed_active();
committed_pending.uci_fake.pending_changes.dhcp = { external: true };
assert_throws(() => recover(committed_pending, 'active'), 'CORRUPT_STATE',
	'committed active recovery refuses pending UCI deltas');
let committed_section = committed_active();
committed_section.uci_fake.values.dhcp.other = committed_section.uci_fake.values.dhcp.main;
delete committed_section.uci_fake.values.dhcp.main;
assert_throws(() => recover(committed_section, 'active'), 'CORRUPT_STATE',
	'committed active recovery refuses dnsmasq section replacement');

function preexisting_active() {
	let value = runtime({ uci: { dhcp: {
		main: { '.type': 'dnsmasq', server: [ TARGET, '9.9.9.9' ], cachesize: '1000' }
	} } });
	apply(value, desired(observe(value)));
	return value;
};
let missing_preexisting = preexisting_active();
missing_preexisting.uci_fake.values.dhcp.main.server = [ '9.9.9.9' ];
assert_true(length(observe(missing_preexisting).conflicts) > 0,
	'missing preexisting target is external ownership drift');
assert_throws(() => desired(observe(missing_preexisting)), 'INVALID_ARGUMENT',
	'planning never re-adds a missing foreign target occurrence');
assert_throws(() => recover(missing_preexisting, 'active'), 'CORRUPT_STATE',
	'recovery never re-adds a missing foreign target occurrence');
assert_equal(encoded(missing_preexisting.uci_fake.values.dhcp.main.server), encoded([ '9.9.9.9' ]),
	'refused recovery leaves the foreign server list unchanged');
let reordered_preexisting = preexisting_active();
reordered_preexisting.uci_fake.values.dhcp.main.server = [ '9.9.9.9', TARGET ];
assert_true(length(observe(reordered_preexisting).conflicts) > 0,
	'reordered preexisting target authority is external ownership drift');
assert_throws(() => recover(reordered_preexisting, 'active'), 'CORRUPT_STATE',
	'recovery refuses reordered preexisting target authority');
let inserted_preexisting = preexisting_active();
inserted_preexisting.uci_fake.values.dhcp.main.server = [ '8.8.8.8', TARGET, '9.9.9.9' ];
assert_equal(recover(inserted_preexisting, 'active').state, 'active',
	'ordered preexisting authority permits inserted foreign non-target servers');

let stale = runtime();
let stale_plan = desired(observe(stale));
stale.uci_fake.values.dhcp.main.server = [ '8.8.8.8' ];
assert_throws(() => apply(stale, stale_plan), 'INVALID_ARGUMENT', 'stale plan is refused');

let commit_failure = runtime();
commit_failure.uci_fake.fail_commit = true;
assert_throws(() => apply(commit_failure, desired(observe(commit_failure))), 'INTERNAL',
	'commit failure is reported');
assert_true(json(commit_failure.fs.files[MANIFEST]).transition != null &&
	commit_failure.uci_fake.calls[length(commit_failure.uci_fake.calls) - 1].operation == 'commit',
	'possibly successful commit failure retains authority and does not claim cursor rollback');
let set_failure = runtime();
set_failure.uci_fake.fail_set_at = 2;
assert_throws(() => apply(set_failure, desired(observe(set_failure))), 'INTERNAL',
	'pre-commit set failure is reported');
assert_true(json(set_failure.fs.files[MANIFEST]).transition != null &&
	set_failure.uci_fake.calls[length(set_failure.uci_fake.calls) - 1].operation == 'revert',
	'pre-commit failure retains transition authority and reverts cursor deltas');

let restart_failure = runtime({ process: {
	'/etc/init.d/dnsmasq:restart': { code: 1 }
} });
assert_throws(() => apply(restart_failure, desired(observe(restart_failure))), 'HEALTH_FAILED',
	'restart failure is reported');
assert_true(json(restart_failure.fs.files[MANIFEST]).transition != null,
	'post-commit failure retains transition authority');
restart_failure.process.replies['/etc/init.d/dnsmasq:restart'] = { code: 0 };
let recovered = recover(restart_failure, 'active');
assert_equal(recovered.state, 'active', 'an exact post-state transition can be recovered');

active.uci_fake.values.dhcp.main.cachesize = '55';
assert_true(length(observe(active).conflicts) > 0, 'scalar drift while active is a conflict');
let cleanup_result = cleanup(active);
assert_true(cleanup_result.clean, 'cleanup completes despite external scalar edit');
let cleaned = active.uci_fake.cursor().get_all('dhcp', 'main');
assert_equal(encoded(cleaned.server), encoded([ '1.1.1.1' ]), 'cleanup removes only the owned target occurrence');
assert_equal(cleaned.cachesize, '55', 'cleanup preserves an externally edited scalar');
assert_equal(cleaned.noresolv, null, 'cleanup restores an originally absent owned scalar');
assert_true(active.fs.lstat(MANIFEST) == null, 'ordinary cleanup removes the verified clean tombstone');

let package_cleanup = runtime();
apply(package_cleanup, desired(observe(package_cleanup)));
package_cleanup.mutation_lock_lease = acquire(package_cleanup, { barrier: 'normal', wait_ms: 0 });
package_cleanup.fs.mkdir('/var/run/miclash/package-removal');
package_cleanup.fs.set_mode('/var/run/miclash/package-removal', 0o700);
package_cleanup.package_removal_cleanup = true;
package_cleanup.package_removal_preserve_manifest = true;
let package_result = cleanup(package_cleanup);
assert_true(package_result.clean && package_cleanup.fs.lstat(MANIFEST)?.type == 'file',
	'package cleanup retains a clean proof');
assert_equal(json(package_cleanup.fs.files[MANIFEST]).state, 'clean',
	'package proof is an exact clean tombstone');
package_cleanup.uci_fake.values.dhcp.main.cachesize = '77';
assert_throws(() => cleanup(package_cleanup), 'CORRUPT_STATE',
	'stale package clean proof is refused after UCI drift');

let ambiguous = runtime({ uci: { dhcp: {
	main: { '.type': 'dnsmasq', server: [ TARGET ], cachesize: '0', noresolv: '1' }
} } });
assert_true(length(observe(ambiguous).conflicts) > 0,
	'MiClash-shaped active UCI without authority is ambiguous');

let running_failure = runtime({ process: {
	'/etc/init.d/dnsmasq:running': { code: 1 }
} });
assert_throws(() => apply(running_failure, desired(observe(running_failure))), 'HEALTH_FAILED',
	'dnsmasq running failure is reported');
assert_true(json(running_failure.fs.files[MANIFEST]).transition != null,
	'running failure retains retry authority');
running_failure.uci_fake.values.dhcp.main.cachesize = '77';
assert_throws(() => recover(running_failure, 'active'), 'CORRUPT_STATE',
	'a third UCI state may not resume an exact transition');

let retry_cleanup_unlink = runtime();
apply(retry_cleanup_unlink, desired(observe(retry_cleanup_unlink)));
retry_cleanup_unlink.fs.fail_unlink_once = true;
assert_throws(() => cleanup(retry_cleanup_unlink), 'INTERNAL',
	'ordinary clean tombstone unlink failure is reported');
assert_equal(json(retry_cleanup_unlink.fs.files[MANIFEST]).state, 'clean',
	'clean tombstone survives unlink failure');
assert_true(cleanup(retry_cleanup_unlink).clean && retry_cleanup_unlink.fs.lstat(MANIFEST) == null,
	'ordinary cleanup retries the terminal tombstone unlink idempotently');

let duplicate_target = runtime();
apply(duplicate_target, desired(observe(duplicate_target)));
push(duplicate_target.uci_fake.values.dhcp.main.server, TARGET);
assert_throws(() => cleanup(duplicate_target), 'CORRUPT_STATE',
	'cleanup refuses duplicate target occurrences when MiClash added exactly one');
let moved_target = runtime({ uci: { dhcp: {
	main: { '.type': 'dnsmasq', server: [ '1.1.1.1', '9.9.9.9' ], cachesize: '1000' }
} } });
apply(moved_target, desired(observe(moved_target)));
moved_target.uci_fake.values.dhcp.main.server = [ TARGET, '1.1.1.1', '9.9.9.9' ];
assert_throws(() => cleanup(moved_target), 'CORRUPT_STATE',
	'cleanup refuses target reordering that loses the appended ownership position');
let foreign_server = runtime();
apply(foreign_server, desired(observe(foreign_server)));
push(foreign_server.uci_fake.values.dhcp.main.server, '9.9.9.9');
assert_true(cleanup(foreign_server).clean, 'cleanup accepts an appended foreign non-target server');
assert_equal(encoded(foreign_server.uci_fake.cursor().get_all('dhcp', 'main').server),
	encoded([ '1.1.1.1', '9.9.9.9' ]), 'cleanup preserves foreign non-target servers');

let cursor_race = runtime();
cursor_race.uci_fake.on_cursor = (calls) => {
	if (calls == 4) cursor_race.uci_fake.values.dhcp.main.cachesize = '77';
};
assert_throws(() => apply(cursor_race, desired(observe(cursor_race))), 'CORRUPT_STATE',
	'the committing cursor refuses an external commit after the previous observation');
assert_equal(cursor_race.uci_fake.values.dhcp.main.cachesize, '77',
	'same-cursor freshness refusal preserves the external value');

function assert_crafted_plan_refused(mutator, message) {
	let value = runtime(), plan = desired(observe(value));
	mutator(plan);
	assert_throws(() => apply(value, plan), 'INVALID_ARGUMENT', message);
	assert_true(value.fs.lstat(MANIFEST) == null, message + ' before journaling');
};
assert_crafted_plan_refused((plan) => plan.after.cachesize.value = '55',
	'crafted apply after snapshot is refused');
assert_crafted_plan_refused((plan) => plan.original.cachesize.value = '55',
	'crafted original ownership snapshot is refused');
assert_crafted_plan_refused((plan) => plan.target_preexisting = true,
	'crafted target ownership flag is refused');

for (let partial in [
	{ server: [ TARGET ], cachesize: '1000' },
	{ server: [ '1.1.1.1' ], cachesize: '0' },
	{ server: [ '1.1.1.1' ], cachesize: '1000', noresolv: '1' }
]) {
	let partial_runtime = runtime({ uci: { dhcp: { main: { '.type': 'dnsmasq', ...partial } } } });
	assert_throws(() => cleanup(partial_runtime), 'CORRUPT_STATE',
		'manifest-absent partial MiClash DNS signature is ambiguous');
	assert_throws(() => recover(partial_runtime, 'clean'), 'CORRUPT_STATE',
		'manifest-absent clean recovery shares the partial-signature refusal');
}

let barrier_apply = runtime();
barrier_apply.fs.mkdir('/var/run/miclash/package-removal');
barrier_apply.fs.set_mode('/var/run/miclash/package-removal', 0o700);
assert_throws(() => apply(barrier_apply, desired(observe(barrier_apply))), 'BUSY',
	'active apply honors the package-removal barrier');

warn('dns reconciliation tests passed\n');
