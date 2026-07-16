import { fail } from 'miclash.errors';

const RETRY_DELAYS = [ 1000, 5000, 10000, 60000 ];

export function create(app) {
	if (type(app?.clock?.set_timeout) != 'function' ||
	    type(app?.clock?.set_fallback_timeout) != 'function' ||
	    type(app?.guard?.is_latched) != 'function' ||
	    type(app?.guard?.latch_set) != 'function' ||
	    type(app?.guard?.protect) != 'function' ||
	    type(app?.guard?.verify_protected) != 'function' ||
	    type(app?.reconcile?.recover_guard) != 'function')
		fail('INVALID_ARGUMENT');

	let closed = false, timer = null, generation = 0, failures = 0;
	let attempt;

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
		if (closed) return false;
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
		return false;
	};

	function exact_protection() {
		return app.guard.protect() === true && app.guard.verify_protected() === true;
	};

	attempt = () => {
		if (closed) return false;
		if (app.guard.is_latched() !== true) {
			failures = 0;
			cancel_timer();
			return true;
		}

		let protected = false;
		try {
			if (!exact_protection()) fail('HEALTH_FAILED');
			protected = true;
			if (app.reconcile.recover_guard('startup-guard') !== true ||
			    app.guard.is_latched() === true)
				fail('HEALTH_FAILED');
			failures = 0;
			cancel_timer();
			return true;
		}
		catch (error) {
			// A failed Guard reconciliation may have reached latch release. Re-arm
			// it before retry; a failed initial protect already retains the latch.
			if (protected) {
				try { app.guard.latch_set(); } catch (latch_error) {}
				try { exact_protection(); } catch (protect_error) {}
			}
			failures++;
			return schedule_retry();
		}
	};

	return {
		start: () => attempt(),
		close: () => {
			if (closed) return false;
			closed = true;
			cancel_timer();
			return true;
		}
	};
};
