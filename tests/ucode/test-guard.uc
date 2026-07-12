import { assert_equal, assert_true } from './testlib.uc';
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

let init = fs.readfile('luci-app-miclash/rootfs/etc/init.d/miclash-guard');
let makefile = fs.readfile('luci-app-miclash/Makefile');
let bootstrap = fs.readfile('luci-app-miclash/rootfs/usr/share/miclash/guard-bootstrap.uc');
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
	index(bootstrap, 'meta nfproto ipv4 drop') >= 0 &&
	index(bootstrap, 'meta nfproto ipv6 drop') >= 0,
	'bootstrap must install both family-wide drops in one nft batch');
assert_true(index(bootstrap, "grep -Fq 'meta nfproto ipv4 drop'") >= 0 &&
	index(bootstrap, "grep -Fq 'meta nfproto ipv6 drop'") >= 0,
	'bootstrap verification must prove both terminal family drops remain installed');
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
