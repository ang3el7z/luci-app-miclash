import * as test from 'testlib';
import * as fakes from 'fakes';
import * as startup_guard from 'miclash.startup-guard';

let clock = fakes.clock(1000);
let calls = [], latched = true, physical = false, canonical = false;
let protect_failures = 0, reconcile_failures = 0;
let ready_count = 0;

function dependencies() {
	return {
		clock,
		on_ready: () => { ready_count++; return true; },
		guard: {
			is_latched: () => latched,
			latch_set: () => { push(calls, 'latch_set'); latched = true; return true; },
			protect: () => {
				push(calls, 'protect');
				if (protect_failures > 0) { protect_failures--; return false; }
				physical = true;
				return true;
			},
			verify_protected: () => { push(calls, 'verify_protected'); return physical; }
		},
		reconcile: {
			recover_guard: (reason) => {
				push(calls, 'reconcile:' + reason);
				if (reconcile_failures > 0) { reconcile_failures--; die('HEALTH_FAILED'); }
				if (!physical || !latched) die('HEALTH_FAILED');
				canonical = true;
				latched = false;
				return true;
			}
		}
	};
};

let startup = startup_guard.create(dependencies());
test.assert_true(startup.start());
test.assert_equal(sprintf('%J', calls), sprintf('%J', [ 'protect', 'verify_protected', 'reconcile:startup-guard' ]));
test.assert_true(physical);
test.assert_true(canonical);
test.assert_true(!latched);
test.assert_equal(ready_count, 1);
test.assert_true(startup.start());
test.assert_equal(ready_count, 1, 'ready callback was not one-shot');
test.assert_equal(length(filter(clock.timers, (timer) => timer.active)), 0);

// Missing physical protection is repaired synchronously before any timer or
// normal daemon observation. A failed attempt owns one bounded retry timer.
calls = []; latched = true; physical = false; canonical = false; protect_failures = 1; ready_count = 0;
startup = startup_guard.create(dependencies());
test.assert_true(!startup.start());
test.assert_true(latched);
test.assert_true(!physical);
test.assert_equal(length(filter(clock.timers, (timer) => timer.active)), 1);
let stale_retry = filter(clock.timers, (timer) => timer.active)[0];
clock.advance(999);
test.assert_equal(sprintf('%J', calls), sprintf('%J', [ 'protect' ]));
test.assert_equal(ready_count, 0, 'normal lifecycle armed before exact protection');
clock.advance(1);
test.assert_true(physical);
test.assert_true(canonical);
test.assert_true(!latched);
test.assert_equal(ready_count, 1);
stale_retry.callback();
test.assert_true(startup.start());
test.assert_equal(ready_count, 1, 'stale/repeated recovery duplicated normal lifecycle');
test.assert_equal(length(filter(clock.timers, (timer) => timer.active)), 0);

// Reconcile failure is re-armed fail-closed before retry. There is no Clash
// service dependency, so a disabled core cannot block canonical Guard repair.
calls = []; latched = true; physical = false; canonical = false; reconcile_failures = 1; ready_count = 0;
startup = startup_guard.create(dependencies());
test.assert_true(!startup.start());
test.assert_true(latched);
test.assert_true(physical);
test.assert_equal(sprintf('%J', calls), sprintf('%J', [
	'protect', 'verify_protected', 'reconcile:startup-guard',
	'latch_set', 'protect', 'verify_protected'
]));
test.assert_equal(length(filter(clock.timers, (timer) => timer.active)), 1);
clock.advance(1000);
test.assert_true(canonical);
test.assert_true(!latched);
test.assert_equal(ready_count, 1);

// A separately bound scheduler is mandatory when the primary binding fails.
// Closing invalidates and cancels the only retry.
let primary = clock.set_timeout, fallback_calls = 0;
clock.set_timeout = () => die('INTERNAL');
clock.set_fallback_timeout = (delay, callback) => { fallback_calls++; return primary(delay, callback); };
calls = []; latched = true; physical = false; canonical = false; protect_failures = 1; ready_count = 0;
startup = startup_guard.create(dependencies());
test.assert_true(!startup.start());
test.assert_equal(fallback_calls, 1);
test.assert_equal(length(filter(clock.timers, (timer) => timer.active)), 1);
test.assert_true(startup.close());
clock.advance(60000);
test.assert_equal(sprintf('%J', calls), sprintf('%J', [ 'protect' ]));
test.assert_equal(length(filter(clock.timers, (timer) => timer.active)), 0);
test.assert_equal(ready_count, 0, 'closed startup armed normal lifecycle');
test.assert_true(!startup.close());

// No latch means no mutation and no timer.
clock.set_timeout = primary;
clock.set_fallback_timeout = primary;
calls = []; latched = false; physical = false; canonical = false; ready_count = 0;
startup = startup_guard.create(dependencies());
test.assert_true(startup.start());
test.assert_equal(length(calls), 0);
test.assert_equal(ready_count, 1);
test.assert_equal(length(filter(clock.timers, (timer) => timer.active)), 0);

let failed_ready = startup_guard.create({ ...dependencies(), on_ready: () => false });
test.assert_throws(() => failed_ready.start(), 'INTERNAL');
test.assert_equal(length(filter(clock.timers, (timer) => timer.active)), 0,
	'observation setup failure became a Guard retry loop');
