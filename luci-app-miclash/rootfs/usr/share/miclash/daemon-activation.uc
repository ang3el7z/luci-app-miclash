import { fail } from 'miclash.errors';

const RETRY_DELAYS = [ 30000, 60000, 120000, 300000 ];

export function create(app) {
	if (type(app?.clock?.set_timeout) != 'function' ||
	    type(app?.clock?.set_fallback_timeout) != 'function' ||
	    type(app?.activate) != 'function' || type(app?.observe) != 'function')
		fail('INVALID_ARGUMENT');

	let closed = false, started = false, active = false, timer = null;
	let generation = 0, failures = 0, attempt;

	function cancel_timer() {
		generation++;
		if (timer == null) return false;
		let previous = timer;
		timer = null;
		try { previous.cancel(); } catch (error) {}
		return true;
	};

	function arm(delay, callback) {
		let candidate = null;
		try { candidate = app.clock.set_timeout(delay, callback); }
		catch (error) {}
		if (candidate == null || type(candidate.cancel) != 'function') {
			try { candidate = app.clock.set_fallback_timeout(delay, callback); }
			catch (error) { candidate = null; }
		}
		if (candidate == null || type(candidate.cancel) != 'function')
			fail('INTERNAL');
		return candidate;
	};

	function schedule_retry() {
		if (closed || active) return false;
		cancel_timer();
		let token = generation;
		let delay = RETRY_DELAYS[min(max(failures - 1, 0), length(RETRY_DELAYS) - 1)];
		let candidate;
		candidate = arm(delay, () => {
			if (closed || token != generation || timer !== candidate) return;
			timer = null;
			attempt();
		});
		timer = candidate;
		return true;
	};

	attempt = () => {
		if (closed || active) return active;
		try {
			if (app.activate() !== true) fail('HEALTH_FAILED');
			active = true;
			failures = 0;
			cancel_timer();
			return true;
		}
		catch (error) {
			failures++;
			schedule_retry();
			return false;
		}
	};

	return {
		start: () => {
			if (closed) return false;
			if (!started) {
				if (app.observe() !== true) fail('INTERNAL');
				started = true;
			}
			attempt();
			return true;
		},
		ready: () => active,
		close: () => {
			if (closed) return false;
			closed = true;
			cancel_timer();
			return true;
		}
	};
};
