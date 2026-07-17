import { assert_equal } from 'testlib';
import * as legacy from 'miclash.legacy-network';

let calls = [], guard = false, legacy_present = true, fail_at = null;
let runtime = { guard_control: {
	protect: () => { push(calls, 'protect'); guard = true; return true; },
	verify_protected: () => { push(calls, 'verify-protected'); return guard; }
} };
let app = {
	with_lock: (runtime, options, worker) => { push(calls, 'lock'); return worker(); },
	present: () => legacy_present,
	cleanup_firewall: () => { push(calls, 'firewall'); if (fail_at == 'firewall') die('INTERNAL'); return true; },
	cleanup_routes: () => { push(calls, 'routing'); if (fail_at == 'routing') die('INTERNAL'); return true; },
	cleanup_dns: () => { push(calls, 'dns'); if (fail_at == 'dns') die('INTERNAL'); return true; },
	cleanup_artifacts: () => { push(calls, 'artifacts'); if (fail_at == 'artifacts') die('INTERNAL'); return true; },
	verify: () => { push(calls, 'verify'); return fail_at != 'verify'; }
};

let result = legacy.handoff(runtime, app);
assert_equal(result.changed, true);
assert_equal(result.guard_retained, true, 'canonical OFF handoff released temporary Guard');
assert_equal(guard, true, 'handoff left a direct-traffic gap before native startup');
assert_equal(sprintf('%J', calls), sprintf('%J', [
	'lock', 'protect', 'verify-protected', 'firewall', 'routing', 'dns', 'artifacts', 'verify'
]), 'legacy ownership was not retired under one protected handoff');

for (let stage in [ 'firewall', 'routing', 'dns', 'artifacts', 'verify' ]) {
	calls = []; guard = false; fail_at = stage;
	let failed = false;
	try { legacy.handoff(runtime, app); } catch (error) { failed = true; }
	assert_equal(failed, true, 'legacy ' + stage + ' failure accepted');
	assert_equal(guard, true, 'legacy ' + stage + ' failure released Guard');
}

calls = []; guard = false; fail_at = null; legacy_present = false;
result = legacy.handoff(runtime, app);
assert_equal(result.changed, false);
assert_equal(length(calls), 0, 'clean install entered migration handoff');

// The legacy fake-IP whitelist is a global kernel owner too. A one-jump
// migration must detect and destroy it under the same protected handoff.
let ipset_present = true, ipset_calls = [];
let ipset_runtime = {
	guard_control: {
		protect: () => true,
		verify_protected: () => true
	},
	fs: {
		lstat: () => null,
		popen: () => {
			let read = false;
			return { read: () => { if (read) return ''; read = true; return ''; }, close: () => 0 };
		}
	},
	process: { run: (request) => {
		push(ipset_calls, request.command + ' ' + join(' ', request.args));
		if (request.command != 'ipset') return { code: 1 };
		if (request.args[0] == 'list') return { code: ipset_present ? 0 : 1 };
		if (request.args[0] == 'destroy') { ipset_present = false; return { code: 0 }; }
		return { code: 1 };
	} },
	uci: { cursor: () => ({ get_all: () => null }) }
};
assert_equal(legacy.present(ipset_runtime), true,
	'legacy fake-IP ipset was invisible to migration discovery');
let ipset_result = legacy.handoff(ipset_runtime, {
	with_lock: (runtime, options, worker) => worker()
});
assert_equal(ipset_result.changed, true);
assert_equal(ipset_present, false, 'legacy fake-IP ipset survived migration handoff');

print('ok - legacy network handoff\n');
