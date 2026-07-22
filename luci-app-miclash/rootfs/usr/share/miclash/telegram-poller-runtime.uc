import * as errors from 'miclash.errors';

function invalid() { errors.fail('INVALID_ARGUMENT'); };

export function create(app) {
	if (type(app) != 'object' || type(app.load_settings) != 'function' ||
	    type(app.connect) != 'function' || type(app.transport?.prepare_poll) != 'function' ||
	    type(app.http?.begin) != 'function' || type(app.poll_timeout_seconds) != 'function' ||
	    type(app.retry_delay_ms) != 'function' || type(app.timer) != 'function' ||
	    type(app.process) != 'function' || type(app.signal_process) != 'function' ||
	    type(app.end) != 'function')
		invalid();

	let failures = 0, stopping = false, ended = false;
	let timer = null, kill_timer = null, child = null, session = null, connection = null;
	let cycle;

	function cancel_timer(handle) {
		if (handle == null)
			return;
		try { handle.cancel(); } catch (error) {}
	};

	function disconnect() {
		if (connection == null)
			return;
		let current = connection;
		connection = null;
		try { current.disconnect(); } catch (error) {}
	};

	function finish() {
		if (ended)
			return;
		ended = true;
		cancel_timer(timer);
		cancel_timer(kill_timer);
		timer = null;
		kill_timer = null;
		disconnect();
		app.end();
	};

	function schedule(delay, callback) {
		if (stopping)
			return finish();
		cancel_timer(timer);
		timer = app.timer(delay, () => {
			timer = null;
			if (!stopping)
				callback();
			else
				finish();
		});
		if (timer == null)
			errors.fail('INTERNAL');
	};

	function warn(error) {
		let code = errors.normalize(error).code;
		try { app.logger?.warn('Telegram poll failed: ' + code); } catch (ignored) {}
	};

	function retry(error, delay) {
		if (session != null) {
			try { session.abort(); } catch (ignored) {}
			session = null;
		}
		disconnect();
		if (stopping)
			return finish();
		failures++;
		warn(error);
		schedule(delay ?? app.retry_delay_ms(failures), cycle);
	};

	function process_complete(code, plan) {
		let completed = session;
		session = null;
		child = null;
		cancel_timer(kill_timer);
		kill_timer = null;
		if (stopping) {
			try { completed?.abort(); } catch (error) {}
			disconnect();
			return finish();
		}
		try {
			let response = completed.complete(code);
			let reply = plan.complete(response);
			if (reply.retry_after_ms > 0) {
				disconnect();
				failures++;
				return schedule(reply.retry_after_ms, cycle);
			}
			for (let update in reply.updates) {
				let ingested = connection.call('miclash', 'telegram_ingest', { update });
				if (ingested?.retryable === true)
					errors.fail('INTERNAL');
			}
			failures = 0;
			disconnect();
			schedule(0, cycle);
		}
		catch (error) { retry(error); }
	};

	cycle = () => {
		if (stopping)
			return finish();
		try {
			let configured = app.load_settings()?.telegram;
			if (configured?.enabled !== true || type(configured.token) != 'string' ||
			    !length(configured.token) || type(configured.user_id) != 'string' ||
			    !length(configured.user_id)) {
				failures = 0;
				return schedule(1000, cycle);
			}
			connection = app.connect();
			if (connection == null)
				return schedule(1000, cycle);
			let status = connection.call('miclash', 'telegram_status', {});
			let offset = status?.last_update_id;
			if (type(offset) != 'int' || offset < -1)
				errors.fail('INTERNAL');
			let plan = app.transport.prepare_poll(configured, offset,
				app.poll_timeout_seconds(configured));
			session = app.http.begin(app.runtime, plan.request);
			let launched = app.process(session.command, session.args,
				(code) => process_complete(code, plan));
			if (type(launched) != 'object' || type(launched.pid) != 'int' || launched.pid < 2)
				errors.fail('INTERNAL');
			child = launched;
		}
		catch (error) { retry(error); }
	};

	function shutdown() {
		if (stopping)
			return;
		stopping = true;
		cancel_timer(timer);
		timer = null;
		if (child == null)
			return finish();
		let target = child;
		try { app.signal_process(target.pid, 'TERM'); } catch (error) {}
		kill_timer = app.timer(1000, () => {
			kill_timer = null;
			if (child === target)
				try { app.signal_process(target.pid, 'KILL'); } catch (error) {}
		});
	};

	return { start: cycle, shutdown };
};
