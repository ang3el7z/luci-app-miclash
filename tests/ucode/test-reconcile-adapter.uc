import { assert_equal, assert_throws } from 'testlib';
import * as adapter from 'miclash.reconcile-adapter';

let records = [], events = [], operational_logs = [], ready = false,
	guard_enabled = true, now = 1700000000000;
let guard_latched = false, guard_physical = true, guard_persist_fails = false;
let guard_latch_clear_fails = false;
let guard_disable_failures = 0, guard_verify_off_failures = 0;
let service_restarts = 0, service_repairs = 0,
	service_state = 'running', service_starts = 0, service_stops = 0;
let network_applies = 0, network_cleanups = 0, network_fails = false;
let network_guard_protected = [];
let network_cleanup_failures = 0;
let network_clean = false;
let proxy_mode = 'tproxy', wait_options = [], wait_deadlines = [];
let sequence = 0;
let reconciler = adapter.create({
	operations: { submit: (kind, source, context, worker) => {
		let record = { id: 'operation-' + (++sequence), kind, source, context };
		try { record.result = worker({ stage: () => true }); record.state = 'success'; }
		catch (error) { record.state = 'failure'; record.error = error?.code ?? error?.message; }
		push(records, record); return record;
	} },
	service: { observe: () => ({ state: service_state }),
		start: () => { service_starts++; service_state = 'running'; return true; },
		stop: () => { service_stops++; service_state = 'stopped'; return true; },
		restart_service: () => { service_restarts++; service_state = 'running'; return true; },
		recover: () => { service_repairs++; service_state = 'running'; return {
			ok: ready, stage: ready ? 'reload' : 'restart_service', ready: { ok: ready,
				components: ready ? [
					{ component: 'process', ready: true }, { component: 'api', ready: true },
					{ component: 'dns', ready: true, observed_at: now },
					{ component: 'forward', ready: true, observed_at: now },
					{ component: 'guard', ready: true, observed_at: now,
						enabled: guard_enabled, generation: 7 }
				] : [] }
		}; },
		wait_ready: (deadline, profile, options) => { push(wait_deadlines, deadline); push(wait_options, options); return { ok: ready, components: ready ? [
			{ component: 'process', ready: true }, { component: 'api', ready: true },
			{ component: 'dns', ready: true, observed_at: now },
			{ component: 'forward', ready: true, observed_at: now },
			{ component: 'guard', ready: true, observed_at: now,
				enabled: guard_enabled, generation: 7 }
		] : [] }; } },
	network: { is_clean: () => network_clean, apply: () => {
		network_applies++;
		push(network_guard_protected, guard_physical);
		if (network_fails) die('INTERNAL');
		return true;
	}, cleanup: () => {
		network_cleanups++;
		if (network_cleanup_failures > 0) { network_cleanup_failures--; die('INTERNAL'); }
		return true;
	} },
	settings: {
		get: () => ({ core: { proxy_mode }, guard: { enabled: guard_enabled } }),
		set: (patch) => {
			if (guard_persist_fails) die('INTERNAL');
			guard_enabled = patch.guard.enabled;
			return { core: { proxy_mode }, guard: { enabled: guard_enabled } };
		}
	},
	guard: {
		is_latched: () => guard_latched,
		latch_set: () => { guard_latched = true; return true; },
		protect: () => { guard_physical = true; return true; },
		verify_protected: () => guard_physical,
		disable: () => {
			if (guard_disable_failures > 0) { guard_disable_failures--; return false; }
			guard_physical = false; return true;
		},
		verify: (enabled) => {
			if (!enabled && guard_verify_off_failures > 0) {
				guard_verify_off_failures--; return false;
			}
			return enabled ? guard_enabled && guard_physical : !guard_physical;
		},
		latch_clear: () => {
			guard_latched = false;
			return !guard_latch_clear_fails;
		}
	},
	clock: { now: () => now },
	logger: {
		info: (message) => push(operational_logs, { level: 'info', message }),
		error: (message) => push(operational_logs, { level: 'error', message })
	},
	events: { emit: (type_name, data) => { push(events, { type: type_name, data }); return true; } }
});

assert_equal(reconciler.run('automatic').state, 'failure');
assert_equal(service_repairs, 1,
	'production reconciliation did not invoke bounded Mihomo recovery');
assert_equal(events[0].type, 'failure');
assert_equal(events[0].data.component, 'mihomo');
assert_equal(events[1].type, 'fail_closed');
assert_equal(events[1].data.failure_id, events[0].data.failure_id);
assert_equal(network_applies, 1, 'native network lifecycle not invoked before readiness');
assert_equal(operational_logs[0].message,
	'reconcile: started reason=automatic action=repair');
assert_equal(operational_logs[1].message,
	'reconcile: network state applied components=dns,firewall,routing');
assert_equal(operational_logs[2].level, 'error');
assert_equal(operational_logs[2].message,
	'reconcile: failed component=mihomo reason=automatic code=HEALTH_FAILED');

ready = true; now++;
assert_equal(reconciler.run('scheduled').state, 'success');
assert_equal(events[2].type, 'internet_restored');
assert_equal(events[2].data.failure_id, events[0].data.failure_id);
assert_equal(events[2].data.recovery_of, 'fail-closed/' + events[0].data.failure_id);
assert_equal(events[2].data.guard.enabled, true);
assert_equal(events[2].data.network.path, 'proxy');
assert_equal(events[3].type, 'recovery');
assert_equal(events[3].data.failure_id, events[0].data.failure_id);
assert_equal(operational_logs[length(operational_logs) - 1].message,
	'reconcile: ready components=mihomo,dns,firewall,routing guard=enabled');

// A healthy run without an active outage is not an Internet-restored event.
assert_equal(reconciler.run('scheduled').state, 'success');
assert_equal(length(events), 4);

let restart_now = now;
assert_equal(reconciler.restart('luci-restart'), true);
assert_equal(wait_deadlines[length(wait_deadlines) - 1], restart_now + 30000,
	'a healthy router restart was allowed only the legacy five-second readiness window');

// Native network repair is a hard readiness prerequisite. A failure happens
// before the service restart and, with Guard ON, preserves physical fail-close.
let restarts_before_network_failure = service_restarts;
network_fails = true; ready = true; guard_enabled = true; now++;
assert_equal(reconciler.run('automatic').state, 'failure');
assert_equal(service_restarts, restarts_before_network_failure);
assert_equal(guard_latched, true);
assert_equal(guard_physical, true);
network_fails = false; now++;
assert_equal(reconciler.run('scheduled').state, 'success');
assert_equal(guard_latched, false);

// Guard OFF still uses physical bootstrap protection as a temporary handoff
// owner. A failed multi-component network transaction must leave that owner
// armed and must not expose direct traffic between partial repair steps.
guard_enabled = false; guard_latched = false; guard_physical = false;
network_fails = true; ready = true; now++;
let off_failure_restarts = service_restarts;
assert_equal(reconciler.run('automatic').state, 'failure');
assert_equal(network_guard_protected[length(network_guard_protected) - 1], true,
	'network mutation began without temporary Guard protection');
assert_equal(guard_physical, true,
	'failed Guard-OFF network mutation released temporary protection');
assert_equal(service_restarts, off_failure_restarts,
	'failed Guard-OFF network mutation proceeded to Mihomo restart');
network_fails = false;

// Without Guard, the restoration closes the failure itself and is emitted once.
ready = false; guard_enabled = false; now++;
assert_equal(reconciler.run('automatic').state, 'failure');
let direct_failure = events[length(events) - 1].data.failure_id;
ready = true; now++;
assert_equal(reconciler.run('scheduled').state, 'success');
assert_equal(events[length(events) - 1].type, 'internet_restored');
assert_equal(events[length(events) - 1].data.recovery_of, 'failure/' + direct_failure);
assert_equal(events[length(events) - 1].data.network.path, 'proxy');

// A durable safety latch is reconciled through the real adapter. Persistent
// UCI failure keeps protection and the latch; later recovery repairs UCI ON
// before clearing it and does not spin autonomously.
guard_enabled = false; guard_latched = true; guard_physical = false;
guard_persist_fails = true; ready = true; now++;
let records_before_latch = length(records), restarts_before_latch = service_restarts;
assert_equal(reconciler.run('guard-transition').state, 'failure');
assert_equal(guard_latched, true);
assert_equal(guard_physical, true);
assert_equal(guard_enabled, false);
assert_equal(service_restarts, restarts_before_latch,
	'latch repair failure proceeded into an unsafe service restart');
assert_equal(length(records), records_before_latch + 1, 'latch failure created a busy reconcile loop');

guard_persist_fails = false; guard_latch_clear_fails = true; now++;
assert_equal(reconciler.run('scheduled').state, 'failure');
assert_equal(guard_latched, true, 'failed latch release was not durably re-armed');
assert_equal(guard_physical, true);

guard_latch_clear_fails = false; now++;
assert_equal(reconciler.run('scheduled').state, 'success');
assert_equal(guard_enabled, true);
assert_equal(guard_physical, true);
assert_equal(guard_latched, false);
assert_equal(length(records), records_before_latch + 3);

// Startup recovery invokes only the latch-aware Guard transaction. It must
// repair canonical/state intent and release the latch without waiting for or
// restarting a disabled/unready Clash service.
guard_enabled = false; guard_latched = true; guard_physical = false; ready = false; now++;
let restarts_before_startup = service_restarts;
assert_equal(reconciler.recover_guard('startup-guard'), true);
assert_equal(guard_enabled, true);
assert_equal(guard_physical, true);
assert_equal(guard_latched, false);
assert_equal(service_restarts, restarts_before_startup);

// Daemon startup uses the same real native transaction synchronously; normal
// observation cannot arm until network state and Mihomo readiness are proven.
guard_persist_fails = false; guard_latched = false; guard_enabled = false;
guard_physical = false; ready = true; network_fails = false; now++;
let startup_network_before = network_applies, startup_restarts_before = service_restarts;
assert_equal(reconciler.startup('daemon-startup'), true);
assert_equal(network_applies, startup_network_before + 1);
assert_equal(service_restarts, startup_restarts_before,
	'daemon startup restarted an already-running Mihomo instance');

network_fails = true; now++;
let startup_network_failed = false;
try { reconciler.startup('daemon-startup'); } catch (error) { startup_network_failed = true; }
assert_equal(startup_network_failed, true);
assert_equal(service_restarts, startup_restarts_before,
	'failed startup network repair proceeded to service restart');

guard_enabled = false; guard_latched = true; guard_physical = false;
guard_persist_fails = true; now++;
let startup_failed = false;
try { reconciler.recover_guard('startup-guard'); }
catch (error) { startup_failed = true; }
assert_equal(startup_failed, true);
assert_equal(guard_enabled, false);
assert_equal(guard_physical, true);
assert_equal(guard_latched, true);
assert_equal(service_restarts, startup_restarts_before);

service_state = 'stopped'; network_fails = false; ready = true; now++;
let cleanup_before = network_cleanups;
assert_equal(reconciler.startup('daemon-startup'), true);
assert_equal(network_cleanups, cleanup_before + 1,
	'stopped daemon startup retained stale proxy ownership');
assert_equal(service_starts, 0, 'daemon startup started an explicitly stopped service');

// A clean, intentionally stopped installation is observation-only: do not
// install a temporary Guard owner or sweep components that have no ownership.
network_clean = true; guard_physical = false; cleanup_before = network_cleanups;
assert_equal(reconciler.startup('daemon-startup'), true);
assert_equal(network_cleanups, cleanup_before,
	'clean stopped startup ran an unnecessary network cleanup');
assert_equal(guard_physical, false,
	'clean Guard-OFF startup installed temporary fail-closed state');
network_clean = false;

// Explicit Guard-OFF stop is a protected transaction. If cleanup cannot
// complete after Mihomo stops, restore native network ownership and the core
// before reporting the failed stop request; never leave stale redirects with
// no consumer and no physical Guard.
service_state = 'running'; guard_enabled = false; guard_latched = false;
guard_physical = false; ready = true; network_cleanup_failures = 1; now++;
proxy_mode = 'mixed';
let stop_failed = false, starts_before_stop_fault = service_starts;
try { reconciler.stop('luci-stop'); } catch (error) { stop_failed = true; }
assert_equal(stop_failed, true, 'cleanup-failed stop falsely reported success');
assert_equal(service_state, 'running', 'cleanup-failed stop left Mihomo stopped');
assert_equal(service_starts, starts_before_stop_fault + 1,
	'cleanup-failed stop did not restore Mihomo');
assert_equal(wait_options[length(wait_options) - 1].proxy_mode, 'mixed');
assert_equal(wait_options[length(wait_options) - 1].tun_required, true,
	'mixed-mode restoration omitted the canonical TUN/dataplane readiness contract');
assert_equal(guard_physical, false,
	'restored Guard-OFF stop retained temporary protection after recovery');

// Releasing temporary Guard is part of the same stop transaction. A transient
// disable failure after clean network teardown restores the network+core, then
// retries release only after readiness instead of leaving a router-wide block.
service_state = 'running'; guard_physical = false; ready = true;
proxy_mode = 'tproxy';
guard_disable_failures = 1; now++;
let disable_fault_starts = service_starts;
stop_failed = false;
try { reconciler.stop('luci-stop'); } catch (error) { stop_failed = true; }
assert_equal(stop_failed, true);
assert_equal(service_state, 'running');
assert_equal(service_starts, disable_fault_starts + 1);
assert_equal(guard_physical, false);

// A daemon startup that discovers an intentionally stopped core may retry a
// stale-state cleanup, but must never silently start Mihomo as error recovery.
service_state = 'stopped'; guard_physical = false; ready = true;
network_cleanup_failures = 1; now++;
let starts_before_startup_fault = service_starts;
assert_throws(() => reconciler.startup('daemon-startup'), 'INTERNAL');
assert_equal(service_state, 'stopped');
assert_equal(service_starts, starts_before_startup_fault,
	'stopped-startup cleanup fault unexpectedly started Mihomo');

// A failed OFF verification may happen after disable already changed physical
// state. Startup reports the fault for retry without starting the stopped core.
service_state = 'stopped'; guard_physical = false; ready = true;
guard_verify_off_failures = 1; now++;
let verify_fault_applies = network_applies;
assert_throws(() => reconciler.startup('daemon-startup'), 'HEALTH_FAILED');
assert_equal(service_state, 'stopped');
assert_equal(network_applies, verify_fault_applies,
	'stopped startup recovery unexpectedly applied proxy network ownership');
assert_equal(guard_physical, false);
