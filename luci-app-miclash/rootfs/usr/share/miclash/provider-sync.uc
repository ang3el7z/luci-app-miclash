import * as errors from 'miclash.errors';
import * as storage from 'miclash.storage';
import * as firewall_common from 'miclash.firewall.common';

const STATE_PATH = '/opt/clash/provider-sync.json';
const INTERVAL = 30 * 60 * 1000;
const RETRY = 5 * 60 * 1000;

function clone(value) { return json(sprintf('%J', value)); };
function empty_snapshot() { return { server_ips: [], fakeip_cidrs: [] }; };
function validate_snapshot(value) {
	if (type(value) != 'object' || type(value.server_ips) != 'array' ||
	    type(value.fakeip_cidrs) != 'array' || length(value.server_ips) > 256 ||
	    length(value.fakeip_cidrs) > 256)
		errors.fail('CORRUPT_STATE');
	for (let ip in value.server_ips) if (!firewall_common.valid_ip(ip)) errors.fail('CORRUPT_STATE');
	for (let cidr in value.fakeip_cidrs) if (!firewall_common.valid_cidr(cidr)) errors.fail('CORRUPT_STATE');
	return value;
};
function same(left, right) { return sprintf('%J', left) == sprintf('%J', right); };
function same_file(left, right) {
	return left?.type == 'file' && right?.type == 'file' && left.inode == right.inode &&
		left.dev?.major == right.dev?.major && left.dev?.minor == right.dev?.minor &&
		left.uid == right.uid && left.mode == right.mode && left.nlink == right.nlink &&
		left.size == right.size;
};
function secure_read(runtime) {
	let before = runtime.fs.lstat(STATE_PATH);
	if (before == null) return null;
	if (before.type != 'file' || before.nlink != 1 || before.mode != 0o600 ||
	    (before.uid != null && before.uid != 0) || before.size > 65536 ||
	    runtime.fs.realpath(STATE_PATH) != STATE_PATH)
		errors.fail('CORRUPT_STATE');
	let content = runtime.fs.readfile(STATE_PATH), after = runtime.fs.lstat(STATE_PATH);
	if (type(content) != 'string' || length(content) != before.size ||
	    !same_file(before, after) || runtime.digest == null ||
	    runtime.digest.sha256(content) != runtime.digest.sha256_file(STATE_PATH) ||
	    runtime.fs.realpath(STATE_PATH) != STATE_PATH)
		errors.fail('CORRUPT_STATE');
	try { return json(content); }
	catch (error) { errors.fail('CORRUPT_STATE'); }
};

export function create(app) {
	if (type(app?.runtime?.clock?.set_timeout) != 'function' ||
	    type(app?.runtime?.clock?.now) != 'function' || type(app?.collect) != 'function' ||
	    type(app?.apply) != 'function' || type(app?.runtime?.fs?.lstat) != 'function' ||
	    type(app?.runtime?.fs?.realpath) != 'function' ||
	    type(app?.runtime?.digest?.sha256) != 'function' ||
	    type(app?.runtime?.digest?.sha256_file) != 'function')
		errors.fail('INVALID_ARGUMENT');
	let runtime = app.runtime, current = empty_snapshot(), started = false,
		timer = null, running = false, last_success = null, reason = 'pending', tick;
	function log(level, message) {
		try { app.logger?.[level]?.('provider-sync: ' + message); } catch (error) {}
	};
	let stored = secure_read(runtime);
	if (stored != null) current = validate_snapshot(stored);

	function arm(delay) {
		if (!started) return false;
		try { timer?.cancel?.(); } catch (error) {}
		timer = runtime.clock.set_timeout(delay, tick);
		if (timer == null) errors.fail('INTERNAL');
		return true;
	};
	tick = () => {
		if (!started || running) return false;
		running = true;
		try {
			let ready = type(app.ready) == 'function' ? app.ready() : true;
			if (ready !== true) {
				reason = 'waiting_for_mihomo';
				running = false; arm(RETRY); return false;
			}
			let previous_reason = reason;
			let candidate = validate_snapshot(app.collect());
			if (!same(candidate, current)) {
				if (app.apply(clone(candidate)) !== true) errors.fail('HEALTH_FAILED');
				storage.write_json(runtime, STATE_PATH, candidate, 0o600);
				if (!same(validate_snapshot(secure_read(runtime)), candidate))
					errors.fail('INTERNAL');
				current = clone(candidate);
				log('info', sprintf('synchronized endpoints=%d fakeip_cidrs=%d',
					length(current.server_ips), length(current.fakeip_cidrs)));
			}
			last_success = runtime.clock.now(); reason = 'synchronized';
			if (previous_reason != 'pending' && previous_reason != 'synchronized')
				log('info', 'recovered');
			running = false; arm(INTERVAL); return true;
		}
		catch (error) {
			let next_reason = errors.normalize(error).code;
			if (next_reason == 'NOT_FOUND') {
				reason = 'waiting_for_providers';
				running = false; arm(RETRY); return false;
			}
			if (reason != next_reason)
				log('warn', sprintf('failed code=%s', next_reason));
			reason = next_reason; running = false; arm(RETRY); return false;
		}
	};
	let api = {
		start: () => { if (started) return true; started = true; return arm(0); },
		refresh: () => { if (!started) return false; return arm(0); },
		stop: () => { if (!started) return false; started = false;
			try { timer?.cancel?.(); } catch (error) {} timer = null; return true; },
		current: () => clone(current),
		status: () => ({ running, reason, last_success })
	};
	return api;
};
