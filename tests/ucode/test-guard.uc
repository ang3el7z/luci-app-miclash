import { assert_equal, assert_true, assert_throws } from './testlib.uc';
import * as guard from 'miclash.guard';

let fs = require('fs');

function fixture_json(name) {
	let content = fs.readfile('tests/fixtures/network/' + name);
	assert_true(content != null, 'missing fixture: ' + name);
	return json(content);
};

function snapshot(state) {
	return {
		desired_on: state.desired_on,
		bootstrap_installed: state.bootstrap_installed,
		main_rules_present: state.main_rules_present,
		protected_direct: !(state.bootstrap_installed || state.main_rules_present)
	};
};

function simulate(old, plan) {
	let state = { ...old };
	let intermediate = [];
	for (let primitive in plan) {
		if (primitive == 'install_bootstrap')
			state.bootstrap_installed = true;
		else if (primitive == 'remove_bootstrap')
			state.bootstrap_installed = false;
		else if (primitive == 'remove_main_rules')
			state.main_rules_present = false;
		else if (primitive == 'install_main_rules')
			state.main_rules_present = true;
		else if (primitive == 'daemon_exit' || primitive == 'replace_package')
			state.main_rules_present = false;
		else if (primitive == 'persist_on')
			state.desired_on = true;
		else if (primitive == 'persist_off')
			state.desired_on = false;
		else if (primitive != 'verify_bootstrap')
			die('unknown primitive: ' + primitive);
		push(intermediate, snapshot(state));
	}
	return { intermediate, final: snapshot(state) };
};

let transitions = fixture_json('guard-transitions.json');
assert_equal(length(transitions), 8, 'Guard lifecycle matrix must cover every required transition');
for (let transition in transitions) {
	let plan = guard.transition_plan(transition.old, transition.next);
	assert_equal(sprintf('%J', plan), sprintf('%J', transition.expected_plan), transition.name);
	let model = simulate(transition.old, plan);
	for (let state in model.intermediate)
		if (state.desired_on)
			assert_equal(state.protected_direct, false, transition.name);
	assert_equal(model.final.desired_on, transition.next.desired_on, transition.name + ': desired state');
	assert_equal(model.final.main_rules_present, transition.next.main_rules_present,
		transition.name + ': main rules state');
};

assert_equal(guard.desired({ guard: { enabled: true } }, {}).enabled, true,
	'valid settings enable Guard');
assert_equal(guard.desired({ guard: { enabled: false } }, {}).enabled, false,
	'valid settings allow explicit disable');
assert_equal(guard.desired({ guard: { enabled: false } }, {
	installed: { verified: true, enabled: true }
}).enabled, true, 'an uncoordinated default false cannot remove a verified installed Guard');
assert_equal(guard.desired({ guard: { enabled: false } }, {
	installed: { verified: false, enabled: true, occupied: true }
}).enabled, true, 'an occupied corrupt reserved table must trigger fail-closed repair');
assert_equal(guard.desired({ guard: { enabled: false } }, {
	persisted: { schema_version: 1, enabled: true }
}).enabled, true, 'an uncoordinated default false cannot override persisted Guard ON');
assert_equal(guard.desired({ guard: { enabled: false } }, {
	legacy_enabled: true
}).enabled, true, 'first package upgrade preserves the legacy Guard setting');
assert_equal(guard.desired(null, {
	installed: { verified: true, enabled: true },
	persisted: { schema_version: 1, enabled: false }
}).enabled, true, 'verified installed Guard wins when settings are unreadable');
assert_equal(guard.desired(null, {
	installed: { verified: false },
	persisted: { schema_version: 1, enabled: true }
}).enabled, true, 'persisted last desired state survives a missing runtime table');
assert_equal(guard.desired(null, {
	installed: { verified: false },
	persisted: { schema_version: 99, enabled: false }
}).enabled, true, 'corrupt persisted state fails closed');
assert_equal(guard.desired(null, {}).enabled, true, 'missing state fails closed');

let calls = [];
let installed = false;
let runtime = {
	observers: {
		guard: {
			verify: (wanted) => {
				push(calls, 'verify:' + wanted.enabled);
				return wanted.enabled ? installed : !installed;
			},
			install: () => { push(calls, 'install'); installed = true; return true; },
			remove: () => { push(calls, 'remove'); installed = false; return true; },
			persist: (wanted) => { push(calls, 'persist:' + wanted.enabled); return true; },
			record_status: (status) => {
				push(calls, 'status:' + status.enabled + ':' + status.installed);
				return true;
			}
		}
	}
};

let wanted = guard.desired({ guard: { enabled: true } }, {});
assert_equal(guard.verify(runtime, wanted), false, 'missing bootstrap is not verified');
assert_equal(guard.install_bootstrap(runtime, wanted), true, 'bootstrap install succeeds');
assert_equal(sprintf('%J', calls), sprintf('%J', [
	'verify:true', 'verify:true', 'install', 'verify:true', 'persist:true', 'status:true:true'
]), 'Guard ON must install and verify before persisting the desired state');

calls = [];
wanted = guard.desired({ guard: { enabled: false } }, {});
assert_equal(guard.install_bootstrap(runtime, wanted), true, 'explicit bootstrap removal succeeds');
assert_equal(sprintf('%J', calls), sprintf('%J', [
	'verify:false', 'remove', 'verify:false', 'persist:false', 'status:false:false'
]), 'Guard OFF must persist only after verified removal');

const PRIMARY_TABLE = 'miclash_guard_bootstrap_v1';
const EMERGENCY_TABLE = 'miclash_guard_emergency_v1';
let valid_nft = fs.readfile('tests/fixtures/network/guard-nft-valid.json');
assert_true(valid_nft != null, 'missing real nft JSON fixture');

function cloned_document(text) {
	return json(sprintf('%J', json(text)));
};

function changed_chain(text, changes) {
	let document = cloned_document(text);
	for (let entry in document.nftables)
		if (entry.chain != null)
			for (let key, value in changes)
				entry.chain[key] = value;
	return sprintf('%J', document);
};

function with_earlier_accept(text) {
	let document = cloned_document(text);
	let entries = [];
	let inserted = false;
	for (let entry in document.nftables) {
		if (!inserted && entry.rule != null) {
			push(entries, { rule: {
				family: 'inet', table: PRIMARY_TABLE, chain: 'protected_direct_drop_v1',
				expr: [ { accept: null } ]
			} });
			inserted = true;
		}
		push(entries, entry);
	}
	document.nftables = entries;
	return sprintf('%J', document);
};

function with_extra_verdict(text, verdict) {
	let document = cloned_document(text);
	let entries = [];
	let inserted = false;
	for (let entry in document.nftables) {
		if (!inserted && entry.rule != null) {
			let action = {};
			action[verdict] = null;
			push(entries, { rule: {
				family: 'inet', table: PRIMARY_TABLE, chain: 'protected_direct_drop_v1',
				expr: [ action ]
			} });
			inserted = true;
		}
		push(entries, entry);
	}
	document.nftables = entries;
	return sprintf('%J', document);
};

function with_duplicate_chain(text) {
	let document = cloned_document(text);
	for (let entry in [ ...document.nftables ])
		if (entry.chain != null)
			push(document.nftables, json(sprintf('%J', entry)));
	return sprintf('%J', document);
};

assert_equal(guard.verify_nft_table(valid_nft, PRIMARY_TABLE), true,
	'real nft JSON topology verifies');
assert_equal(guard.verify_nft_table(changed_chain(valid_nft, { hook: null }), PRIMARY_TABLE), false,
	'unhooked chain must fail verification');
assert_equal(guard.verify_nft_table(changed_chain(valid_nft, { prio: -309 }), PRIMARY_TABLE), false,
	'wrong hook priority must fail verification');
assert_equal(guard.verify_nft_table(changed_chain(valid_nft, { policy: 'drop' }), PRIMARY_TABLE), false,
	'wrong base-chain policy must fail verification');
assert_equal(guard.verify_nft_table(with_earlier_accept(valid_nft), PRIMARY_TABLE), false,
	'earlier unconditional accept must fail verification');
assert_equal(guard.verify_nft_table(with_extra_verdict(valid_nft, 'return'), PRIMARY_TABLE), false,
	'extra earlier verdict must fail verification');
assert_equal(guard.verify_nft_table(with_duplicate_chain(valid_nft), PRIMARY_TABLE), false,
	'duplicate ambiguous base-chain objects must fail verification');
assert_equal(guard.verify_nft_table('{ malformed nft JSON', PRIMARY_TABLE), false,
	'malformed nft JSON must fail verification');
assert_equal(guard.verify_nft_table(sprintf('%J', {
	nftables: [ { chain: {
		family: 'inet', table: PRIMARY_TABLE, name: 'protected_direct_drop_v1',
		type: 'filter', hook: 'forward', prio: -310, policy: 'accept'
	} }, { comment: 'meta nfproto ipv4 drop meta nfproto ipv6 drop' } ]
}), PRIMARY_TABLE), false, 'drop text in comments is not semantic protection');

function table_listing(state, malformed) {
	if (malformed)
		return '{ malformed table listing';
	let entries = [ { metainfo: { json_schema_version: 1 } } ];
	for (let name in state)
		push(entries, { table: { family: 'inet', name } });
	return sprintf('%J', { nftables: entries });
};

function valid_for(table) {
	return replace(valid_nft, /miclash_guard_bootstrap_v1/g, table);
};

function fake_nft(initial, options) {
	let state = { ...initial };
	let calls = [];
	let io = {
		list_tables: () => table_listing(state, options?.malformed_listing),
		list_table: (table) => state[table] ?? null,
		apply: (table, batch) => {
			push(calls, { action: 'apply', table, batch });
			if (options?.fail_repair)
				return false;
			state[table] = valid_for(table);
			return true;
		},
		remove: (tables, batch) => {
			push(calls, { action: 'remove', tables: [ ...tables ], batch });
			if (options?.fail_remove)
				return false;
			for (let table in tables)
				delete state[table];
			return true;
		}
	};
	return { backend: guard.create_nft_backend(io), state, calls };
};

let unhooked = changed_chain(valid_nft, { hook: null });
let occupied = fake_nft({
	[PRIMARY_TABLE]: unhooked,
	[EMERGENCY_TABLE]: '{ corrupt occupied emergency table'
});
assert_equal(occupied.backend.installed(), false, 'corrupt occupied tables are not installed protection');
assert_equal(occupied.backend.install(), true, 'corrupt occupied tables are atomically repaired');
assert_equal(occupied.calls[0].action, 'apply', 'repair must use an atomic batch');
assert_true(index(occupied.calls[0].batch,
	'delete table inet ' + PRIMARY_TABLE + '\nadd table inet ' + PRIMARY_TABLE) == 0,
	'repair batch must replace the occupied table in one transaction');
assert_equal(occupied.backend.installed(), true, 'repaired topology verifies structurally');

let mixed = fake_nft({
	[PRIMARY_TABLE]: valid_nft,
	[EMERGENCY_TABLE]: '{ corrupt occupied emergency table'
});
assert_equal(mixed.backend.installed(), false,
	'any corrupt reserved table keeps the owned bootstrap topology unverified');
assert_equal(mixed.backend.install(), true,
	'a corrupt sibling is repaired even while another table already protects traffic');
assert_equal(mixed.calls[0].table, EMERGENCY_TABLE,
	'repair targets the corrupt sibling without replacing verified protection');

let failed_repair = fake_nft({
	[PRIMARY_TABLE]: unhooked,
	[EMERGENCY_TABLE]: '{ corrupt occupied emergency table'
}, { fail_repair: true });
assert_equal(failed_repair.backend.install(), false, 'failed repairs stay unverified and fail closed');
assert_equal(length(failed_repair.calls), 2, 'both reserved names are attempted without destructive pre-delete');

let malformed_listing = fake_nft({}, { malformed_listing: true });
assert_equal(malformed_listing.backend.installed(), false, 'malformed table listing cannot verify ON');
assert_equal(malformed_listing.backend.install(), false, 'malformed table listing cannot drive repair');
assert_equal(malformed_listing.backend.remove(), false, 'malformed table listing cannot verify removal');
let partial_io = {
	list_tables: () => sprintf('%J', { nftables: [
		{ metainfo: { json_schema_version: 1 } }, { table: { family: 'inet' } }
	] }),
	list_table: () => null,
	apply: () => true,
	remove: () => true
};
let partial_backend = guard.create_nft_backend(partial_io);
assert_equal(partial_backend.installed(), false, 'partial table inventory cannot verify ON');
assert_equal(partial_backend.remove(), false, 'partial table inventory cannot verify OFF');
let ambiguous_persist_calls = 0;
let ambiguous_runtime = { observers: { guard: {
	verify: (wanted) => wanted.enabled ? malformed_listing.backend.installed() : malformed_listing.backend.absent(),
	install: () => malformed_listing.backend.install(),
	remove: () => malformed_listing.backend.remove(),
	persist: () => { ambiguous_persist_calls++; return true; },
	record_status: () => true
} } };
assert_throws(() => guard.install_bootstrap(ambiguous_runtime,
	{ enabled: false, explicit_disable: true }), 'INTERNAL');
assert_equal(ambiguous_persist_calls, 0, 'ambiguous removal must not persist OFF');

let malformed_removal = fake_nft({
	[PRIMARY_TABLE]: '{ malformed owned table JSON',
	[EMERGENCY_TABLE]: changed_chain(valid_for(EMERGENCY_TABLE), { prio: 0 })
});
assert_equal(malformed_removal.backend.remove(), true,
	'explicit removal deletes malformed owned tables without trusting ON verification');
assert_equal(length(keys(malformed_removal.state)), 0, 'all reserved owned tables are removed');
assert_equal(malformed_removal.backend.absent(), true, 'removal verifies reserved names are absent');

let failed_removal = fake_nft({ [PRIMARY_TABLE]: '{ malformed owned table JSON' }, { fail_remove: true });
assert_equal(failed_removal.backend.remove(), false, 'failed removal cannot persist OFF');
assert_equal(failed_removal.backend.absent(), false, 'failed removal remains observably occupied');
let failed_persist_calls = 0;
let removal_runtime = { observers: { guard: {
	verify: (wanted) => wanted.enabled ? failed_removal.backend.installed() : failed_removal.backend.absent(),
	install: () => failed_removal.backend.install(),
	remove: () => failed_removal.backend.remove(),
	persist: () => { failed_persist_calls++; return true; },
	record_status: () => true
} } };
assert_throws(() => guard.install_bootstrap(removal_runtime,
	{ enabled: false, explicit_disable: true }), 'INTERNAL');
assert_equal(failed_persist_calls, 0, 'failed removal must not persist OFF');

let init = fs.readfile('luci-app-miclash/rootfs/etc/init.d/miclash-guard');
let makefile = fs.readfile('luci-app-miclash/Makefile');
let bootstrap = fs.readfile('luci-app-miclash/rootfs/usr/share/miclash/guard-bootstrap.uc');
let guard_source = fs.readfile('luci-app-miclash/rootfs/usr/share/miclash/guard.uc');
let start_match = match('\n' + (init ?? ''), /\nSTART=([0-9]+)\n/);
assert_true(start_match != null && int(start_match[1]) < 21,
	'Guard bootstrap must start before Clash');
assert_true(match(init, /guard-bootstrap\.uc install/), 'init must install bootstrap at start');
assert_true(!match(init, /stop_service[\s\S]*guard-bootstrap\.uc (disable|remove)/),
	'ordinary service stop must not remove Guard');
assert_true(index(makefile, 'miclash-guard') >= 0 && index(makefile, 'guard-bootstrap.uc') >= 0,
	'package must install and enable the Guard bootstrap');
assert_true(index(makefile, '+nftables') >= 0,
	'atomic dual-stack bootstrap requires nftables on every package backend');
assert_true(index(bootstrap, "[ '-f', BATCH_PATH ]") >= 0 &&
	index(guard_source, 'meta nfproto ipv4 drop') >= 0 &&
	index(guard_source, 'meta nfproto ipv6 drop') >= 0,
	'bootstrap must install both family-wide drops in one nft batch');
assert_true(index(bootstrap, '-j list tables') >= 0 &&
	index(guard_source, 'verify_nft_table') >= 0,
	'bootstrap verification must use structural nft JSON parsing');
assert_true(index(bootstrap, "'/opt/clash/settings'") >= 0 &&
	index(bootstrap, 'INTERNET_ONLY_MICLASH') >= 0,
	'first upgrade must observe the legacy Guard setting before canonical state exists');
assert_true(index(makefile, '/etc/init.d/miclash-guard start || exit 1') >= 0,
	'package installation must fail closed when an enabled bootstrap cannot be installed');
assert_true(index(bootstrap, "ARGV[0] != 'disable'") >= 0 &&
	index(bootstrap, "'explicit_disable'") >= 0,
	'explicit Guard disable must have a distinct, deliberate bootstrap removal command');
assert_true(index(makefile, 'guard-bootstrap.uc remove') >= 0,
	'package removal must use its distinct bootstrap removal command');
assert_true(!match(makefile, /INSTALL_BIN[^\n]*rootfs\/etc\/init\.d\/miclashd/),
	'Task 2 must not ship the unfinished main daemon');
