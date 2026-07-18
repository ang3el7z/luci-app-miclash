import { assert_equal, assert_true } from './testlib.uc';
import * as activation from 'miclash.daemon-activation';

function clock() {
	let current = 0, timers = [];
	function arm(delay, callback) {
		let timer = { active: true, due: current + delay, callback };
		timer.cancel = () => timer.active = false;
		push(timers, timer);
		return timer;
	};
	return {
		timers,
		set_timeout: arm,
		set_fallback_timeout: arm,
		advance: (delay) => {
			current += delay;
			for (let timer in timers)
				if (timer.active && timer.due <= current) {
					timer.active = false;
					timer.callback();
				}
		}
	};
};

let scheduler = clock(), attempts = 0, observations = 0;
function active_count() {
	let count = 0;
	for (let timer in scheduler.timers)
		if (timer.active) count++;
	return count;
};
let gate = activation.create({
	clock: scheduler,
	activate: () => {
		attempts++;
		if (attempts < 2) die('HEALTH_FAILED');
		return true;
	},
	observe: () => { observations++; return true; }
});

assert_equal(gate.start(), true,
	'a failed data-plane reconciliation stopped the management lifecycle');
assert_equal(attempts, 1);
assert_equal(observations, 1, 'degraded startup did not begin state observation');
assert_equal(active_count(), 1,
	'degraded startup did not schedule one bounded retry');

scheduler.advance(30000);
assert_equal(attempts, 2, 'readiness reconciliation was not retried');
assert_equal(active_count(), 0,
	'successful reconciliation retained a retry timer');
assert_true(gate.ready(), 'successful retry did not publish the ready state');

assert_true(gate.close());
assert_equal(gate.close(), false, 'repeated close was not idempotent');
