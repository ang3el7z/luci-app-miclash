import * as errors from 'miclash.errors';
import * as schema from 'miclash.schema';
import * as storage from 'miclash.storage';
import * as local_time_module from 'miclash.local-time';
import * as wan_activity_module from 'miclash.wan-activity';

const STATE_PATH = '/opt/clash/app-update-scheduler.json';
const STATE_PARENT = '/opt/clash';
const MINUTE = 60000;
const MAX_TIMESTAMP = 253402300799999;
const STATE_FIELDS = {
	version: true, last_scheduled_local_date: true, last_check: true, next_check: true,
	publication_retry_tag: true, publication_retry_count: true, latest_version: true,
	readiness: true, pending_target: true, pending_operation_id: true,
	traffic_deferral_count: true, last_error_code: true, observed_at: true,
	clock_ceiling: true
};

function invalid() { errors.fail('INVALID_ARGUMENT'); };
function corrupt() { errors.fail('CORRUPT_STATE'); };

function stable_version(value) {
	let found = match(value ?? '', /^([0-9]+)\.([0-9]+)\.([0-9]+)$/);
	if (found == null) return null;
	return [ int(found[1]), int(found[2]), int(found[3]) ];
};

function normalize_tag(value) {
	if (type(value) != 'string') return null;
	return substr(value, 0, 1) == 'v' ? substr(value, 1) : value;
};

function compare_version(left, right) {
	let a = stable_version(normalize_tag(left)), b = stable_version(normalize_tag(right));
	if (a == null || b == null) return null;
	for (let index = 0; index < 3; index++) {
		if (a[index] < b[index]) return -1;
		if (a[index] > b[index]) return 1;
	}
	return 0;
};

export function automatic_major(installed, candidate, ready, channel) {
	if (ready !== true || channel != 'release') return false;
	let current = stable_version(installed), wanted = stable_version(candidate);
	return current != null && wanted != null && wanted[0] > current[0];
};

export function publication_retry_delay_ms(count) {
	if (type(count) != 'int' || count < 1) invalid();
	return count == 1 ? 30 * MINUTE : (count == 2 ? 60 * MINUTE : 120 * MINUTE);
};

function timestamp(value) {
	return value == null || (type(value) == 'int' && value >= 0 && value <= MAX_TIMESTAMP);
};

function safe_text(value) {
	return value == null || (type(value) == 'string' && length(value) >= 1 &&
		length(value) <= 64 && match(value, /^[A-Za-z0-9._-]+$/));
};

function operation_id(value) {
	if (value == null) return null;
	return schema.operation_id(value);
};

function same_node(left, right) {
	return left?.type != null && left.type == right?.type && left.inode == right?.inode &&
		left.dev?.major == right.dev?.major && left.dev?.minor == right.dev?.minor;
};

function same_identity(left, right) {
	return same_node(left, right) && left.nlink == right.nlink &&
		left.size == right.size && left.mode == right.mode && left.uid == right.uid;
};

function secure_parent(runtime) {
	let value = runtime.fs.lstat(STATE_PARENT);
	if (value?.type != 'directory' || runtime.fs.realpath(STATE_PARENT) != STATE_PARENT ||
	    type(value.mode) != 'int' || (value.mode & 0o022) != 0 ||
	    (value.uid != null && value.uid != 0)) corrupt();
	return value;
};

function secure_read(runtime) {
	let parent_before = secure_parent(runtime), before = runtime.fs.lstat(STATE_PATH);
	if (before == null) {
		if (!same_identity(parent_before, secure_parent(runtime))) corrupt();
		return null;
	}
	if (before.type != 'file' || before.nlink != 1 || before.mode != 0o600 ||
	    before.size > 16384 || (before.uid != null && before.uid != 0) ||
	    runtime.fs.realpath(STATE_PATH) != STATE_PATH) corrupt();
	let content = runtime.fs.readfile(STATE_PATH), after = runtime.fs.lstat(STATE_PATH);
	let content_hash = type(content) == 'string' ? runtime.digest.sha256(content) : null;
	let file_hash = runtime.digest.sha256_file(STATE_PATH), final = runtime.fs.lstat(STATE_PATH);
	if (type(content) != 'string' || length(content) != before.size || content_hash == null ||
	    content_hash != file_hash || !same_identity(before, after) ||
	    !same_identity(after, final) || !same_identity(parent_before, secure_parent(runtime)) ||
	    runtime.fs.realpath(STATE_PATH) != STATE_PATH) corrupt();
	try { return json(content); } catch (error) { corrupt(); }
};

function initial_state(now) {
	return {
		version: 1, last_scheduled_local_date: null, last_check: null, next_check: null,
		publication_retry_tag: null, publication_retry_count: 0,
		latest_version: null, readiness: 'unknown', pending_target: null,
		pending_operation_id: null, traffic_deferral_count: 0,
		last_error_code: null, observed_at: now, clock_ceiling: now
	};
};

function validate_state(value) {
	if (type(value) != 'object' || type(value) == 'array') corrupt();
	let fields = 0;
	for (let name in value) { if (!exists(STATE_FIELDS, name)) corrupt(); fields++; }
	if (fields != 14 || value.version != 1 || !timestamp(value.last_check) ||
	    !timestamp(value.next_check) || !timestamp(value.observed_at) ||
	    !timestamp(value.clock_ceiling) || value.observed_at == null ||
	    value.clock_ceiling == null || value.observed_at > value.clock_ceiling ||
	    (value.last_scheduled_local_date != null &&
	    !match(value.last_scheduled_local_date, /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/)) ||
	    !safe_text(value.publication_retry_tag) || !safe_text(value.latest_version) ||
	    !safe_text(value.pending_target) || !safe_text(value.last_error_code) ||
	    type(value.publication_retry_count) != 'int' || value.publication_retry_count < 0 ||
	    value.publication_retry_count > 1000000 ||
	    type(value.traffic_deferral_count) != 'int' || value.traffic_deferral_count < 0 ||
	    value.traffic_deferral_count > 1000000 ||
	    index([ 'unknown', 'ready', 'assets_pending', 'error' ], value.readiness) < 0 ||
	    (value.publication_retry_count == 0) != (value.publication_retry_tag == null))
		corrupt();
	if (value.last_check != null && value.last_check > value.clock_ceiling) corrupt();
	try { operation_id(value.pending_operation_id); } catch (error) { corrupt(); }
	return value;
};

function clone(value) {
	try { return json(sprintf('%J', value)); }
	catch (error) { errors.fail('INTERNAL'); }
};

export function create(dependencies) {
	if (type(dependencies?.runtime?.fs) != 'object' ||
	    type(dependencies?.runtime?.clock?.now) != 'function' ||
	    type(dependencies?.runtime?.clock?.set_timeout) != 'function' ||
	    type(dependencies?.runtime?.digest?.sha256) != 'function' ||
	    type(dependencies?.runtime?.digest?.sha256_file) != 'function' ||
	    type(dependencies?.runtime?.app_version) != 'string' ||
	    type(dependencies?.operations?.get) != 'function' ||
	    type(dependencies?.operations?.list) != 'function' ||
	    type(dependencies?.operations?.subscribe) != 'function' ||
	    type(dependencies?.updates?.release_info) != 'function' ||
	    type(dependencies?.updates?.update_miclash_scheduled) != 'function' ||
	    type(dependencies?.settings?.get) != 'function') invalid();
	let app = dependencies, runtime = app.runtime;
	let local_time = app.local_time ?? local_time_module.create(runtime);
	let wan_activity = app.wan_activity ?? wan_activity_module.create({ runtime,
		interface: () => app.settings.get()?.interfaces?.detected_wan });
	if (type(local_time?.observe) != 'function' || type(wan_activity?.sample) != 'function')
		invalid();
	let now = runtime.clock.now();
	if (!timestamp(now) || now == null) errors.fail('INTERNAL');
	let stored = secure_read(runtime);
	let state = stored == null ? initial_state(now) : validate_state(stored);
	let started = false, closed = false, timer = null, unsubscribe = null, api = {};
	let traffic = { valid: false, quiet: false, samples: 0,
		bytes_per_second: null, packets_per_second: null, reason: 'not_sampled' };

	function persist() {
		validate_state(state);
		let existing = secure_read(runtime);
		if (existing != null) validate_state(existing);
		storage.write_json(runtime, STATE_PATH, state, 0o600);
		let verified = validate_state(secure_read(runtime));
		if (sprintf('%J', verified) != sprintf('%J', state)) errors.fail('INTERNAL');
	};

	function enabled() {
		try { return app.settings.get()?.updates?.auto_major_miclash === true; }
		catch (error) { return false; }
	};

	function observe_clock() {
		let current = runtime.clock.now();
		if (!timestamp(current) || current == null) errors.fail('INTERNAL');
		if (current < state.observed_at && state.next_check != null) {
			let remaining = max(MINUTE, state.next_check - state.observed_at);
			state.next_check = current + remaining;
		}
		state.observed_at = current;
		if (current > state.clock_ceiling) state.clock_ceiling = current;
		return current;
	};

	function clear_publication_retry() {
		state.publication_retry_tag = null;
		state.publication_retry_count = 0;
	};

	function local_for(current) {
		try { return local_time.observe(current); }
		catch (error) { return { valid: false, in_window: false, before_cutoff: false,
			local_date: null, next_window: null }; }
	};

	function schedule_timer() {
		if (!started || closed) return;
		if (timer != null) { timer.cancel(); timer = null; }
		if (!enabled()) return;
		let current = runtime.clock.now(), delay = 0;
		if (state.next_check != null) {
			let remaining = max(0, state.next_check - current);
			let local = local_for(current);
			delay = local.valid === true && local.in_window === true
				? min(MINUTE, remaining) : remaining;
		}
		timer = runtime.clock.set_timeout(delay, () => { timer = null; api.tick(); });
		if (timer == null || type(timer.cancel) != 'function') errors.fail('INTERNAL');
	};

	function set_next_night(local, reset_target) {
		if (reset_target) state.pending_target = null;
		state.next_check = local.valid === true ? local.next_window : null;
		state.last_error_code = null;
	};

	function bounded_increment(name) {
		state[name]++;
		if (state[name] > 1000000) state[name] = 1000000;
	};

	function retry_deadline(current, local, delay) {
		let wanted = current + delay, observed = local_for(wanted);
		return observed.valid === true && observed.in_window === true &&
			observed.local_date == local.local_date ? wanted : local.next_window;
	};

	function publication_retry(tag, code, current, local) {
		let safe_tag = safe_text(tag) && tag != null ? tag :
			(state.publication_retry_tag ?? state.pending_target ?? state.latest_version ?? 'transport');
		if (state.publication_retry_tag != safe_tag) {
			state.publication_retry_tag = safe_tag;
			state.publication_retry_count = 0;
		}
		bounded_increment('publication_retry_count');
		state.last_error_code = code ?? 'ASSETS_PENDING';
		state.next_check = retry_deadline(current, local,
			publication_retry_delay_ms(state.publication_retry_count));
	};

	function traffic_defer(current, local, code) {
		bounded_increment('traffic_deferral_count');
		state.last_error_code = code;
		state.next_check = retry_deadline(current, local, 30 * MINUTE);
	};

	function busy() {
		try {
			return length(app.operations.list({ state: 'running' })) > 0 ||
				length(app.operations.list({ state: 'queued' })) > 0;
		}
		catch (error) { return true; }
	};

	function finish_operation(record) {
		let finished = record.finished_at ?? record.updated_at ?? runtime.clock.now();
		if (!timestamp(finished) || finished == null) corrupt();
		state.pending_operation_id = null;
		state.observed_at = finished;
		if (finished > state.clock_ceiling) state.clock_ceiling = finished;
		let local = local_for(finished);
		if (record.state == 'success') {
			state.pending_target = null;
			state.traffic_deferral_count = 0;
			clear_publication_retry();
			state.last_error_code = null;
			state.next_check = local.valid === true ? local.next_window : null;
			return;
		}
		publication_retry(state.pending_target, record.state == 'interrupted' ?
			'INTERRUPTED' : (record.error?.code ?? 'INTERNAL'), finished,
			local.valid === true ? local : { local_date: null, next_window: null });
	};

	function operation_event(record) {
		if (state.pending_operation_id == null || record?.id != state.pending_operation_id ||
		    record.kind != 'updates.miclash' || record.source != 'auto') {
			if (record?.state == 'success' || record?.state == 'failure' ||
			    record?.state == 'interrupted') {
				if (!enabled()) state.next_check = null;
				persist(); schedule_timer();
			}
			return;
		}
		if (record.state != 'success' && record.state != 'failure' &&
		    record.state != 'interrupted') return;
		finish_operation(record);
		persist();
		schedule_timer();
	};

	function attach() {
		if (unsubscribe == null) unsubscribe = app.operations.subscribe(operation_event);
	};

	function recover_pending(current) {
		if (state.pending_target != null) {
			let compared = compare_version(runtime.app_version, state.pending_target);
			if (compared != null && compared >= 0) {
				state.pending_target = null;
				state.pending_operation_id = null;
				state.traffic_deferral_count = 0;
				clear_publication_retry();
			}
		}
		if (state.pending_operation_id == null) return;
		let record = null;
		try { record = app.operations.get(state.pending_operation_id); } catch (error) {}
		if (record?.kind == 'updates.miclash' && record.source == 'auto' &&
		    (record.state == 'queued' || record.state == 'running')) return;
		if (record?.kind == 'updates.miclash' && record.source == 'auto' &&
		    (record.state == 'success' || record.state == 'failure' ||
		    record.state == 'interrupted')) finish_operation(record);
		else {
			state.pending_operation_id = null;
			let local = local_for(current);
			if (local.valid === true) publication_retry(state.pending_target,
				'INTERRUPTED', current, local);
			else { state.next_check = null; state.last_error_code = 'INTERRUPTED'; }
		}
	};

	recover_pending(now);
	persist();
	attach();

	api.start = (...args) => {
		if (length(args)) invalid();
		if (closed || started) return false;
		started = true; attach(); recover_pending(runtime.clock.now()); schedule_timer();
		return true;
	};
	api.stop = (...args) => {
		if (length(args)) invalid();
		if (!started && timer == null) return false;
		started = false;
		if (timer != null) { timer.cancel(); timer = null; }
		return true;
	};
	api.close = (...args) => {
		if (length(args)) invalid();
		if (closed) return false;
		api.stop();
		if (unsubscribe != null) { unsubscribe(); unsubscribe = null; }
		closed = true;
		return true;
	};
	api.tick = (...args) => {
		if (length(args)) invalid();
		if (closed) errors.fail('HEALTH_FAILED');
		let current = observe_clock();
		recover_pending(current);
		if (!enabled()) {
			state.next_check = null; state.pending_target = null;
			state.pending_operation_id = null; clear_publication_retry();
			state.last_error_code = null; persist(); schedule_timer(); return api.status();
		}
		if (state.pending_operation_id != null) {
			persist(); schedule_timer(); return api.status();
		}
		let local = local_for(current);
		if (local.valid !== true) {
			state.last_error_code = 'CLOCK_INVALID'; state.next_check = current + 30 * MINUTE;
			persist(); schedule_timer(); return api.status();
		}
		try { traffic = wan_activity.sample(current); }
		catch (error) { traffic = { valid: false, quiet: false, samples: 0,
			bytes_per_second: null, packets_per_second: null, reason: 'sample_failed' }; }
		if (!local.in_window) {
			state.next_check = local.next_window; persist(); schedule_timer(); return api.status();
		}
		if (state.next_check != null && state.next_check > current) {
			persist(); schedule_timer(); return api.status();
		}
		if (busy()) {
			publication_retry(state.pending_target ?? state.latest_version ?? 'busy',
				'BUSY', current, local);
			persist(); schedule_timer(); return api.status();
		}
		let release;
		try {
			release = app.updates.release_info({ kind: 'miclash', channel: 'release',
				version: null });
		}
		catch (error) {
			state.last_check = current; state.last_scheduled_local_date = local.local_date;
			state.readiness = 'error';
			publication_retry(null, errors.normalize(error).code, current, local);
			persist(); schedule_timer(); return api.status();
		}
		state.last_check = current;
		state.last_scheduled_local_date = local.local_date;
		state.latest_version = safe_text(release?.version) ? release.version : null;
		state.readiness = index([ 'ready', 'assets_pending' ], release?.readiness) >= 0 ?
			release.readiness : (release?.ready === true ? 'ready' : 'error');
		let candidate = normalize_tag(release?.version);
		let is_major = automatic_major(runtime.app_version, candidate, true, 'release');
		if (release?.ready !== true) {
			if (!is_major) {
				clear_publication_retry(); set_next_night(local, true);
			}
			else publication_retry(release.version, 'ASSETS_PENDING', current, local);
			persist(); schedule_timer(); return api.status();
		}
		if (!automatic_major(runtime.app_version, candidate, true, 'release')) {
			clear_publication_retry(); set_next_night(local, true);
			persist(); schedule_timer(); return api.status();
		}
		clear_publication_retry();
		state.pending_target = release.version;
		if (!local.before_cutoff || traffic.valid !== true || traffic.quiet !== true) {
			traffic_defer(current, local, traffic.valid === true ? 'TRAFFIC_BUSY' :
				'TRAFFIC_UNAVAILABLE');
			persist(); schedule_timer(); return api.status();
		}
		let fresh;
		try { fresh = app.updates.release_info({ kind: 'miclash', channel: 'release', version: null }); }
		catch (error) {
			publication_retry(state.pending_target, errors.normalize(error).code, current, local);
			persist(); schedule_timer(); return api.status();
		}
		state.latest_version = safe_text(fresh?.version) ? fresh.version : null;
		state.readiness = index([ 'ready', 'assets_pending' ], fresh?.readiness) >= 0 ?
			fresh.readiness : (fresh?.ready === true ? 'ready' : 'error');
		if (fresh?.ready !== true || fresh.version != state.pending_target ||
		    !automatic_major(runtime.app_version, normalize_tag(fresh?.version), true, 'release')) {
			if (automatic_major(runtime.app_version, normalize_tag(fresh?.version), true, 'release'))
				publication_retry(fresh.version, fresh?.ready === true ? 'INVALID_RESPONSE' :
					'ASSETS_PENDING', current, local);
			else { clear_publication_retry(); set_next_night(local, true); }
			persist(); schedule_timer(); return api.status();
		}
		state.next_check = retry_deadline(current, local, 30 * MINUTE);
		state.last_error_code = null;
		persist();
		let hooked = false;
		try {
			app.updates.update_miclash_scheduled({ version: fresh.version, channel: 'release' },
				'auto', (queued) => {
					let id = operation_id(queued?.id);
					if (id == null || queued.kind != 'updates.miclash' ||
					    queued.source != 'auto' || queued.state != 'queued') corrupt();
					state.pending_operation_id = id; persist(); hooked = true;
				});
			if (!hooked) publication_retry(state.pending_target, 'INTERNAL', current, local);
		}
		catch (error) {
			if (state.pending_operation_id == null)
				publication_retry(state.pending_target, errors.normalize(error).code, current, local);
		}
		persist(); schedule_timer(); return api.status();
	};
	api.run_now = (...args) => {
		if (length(args)) invalid();
		state.next_check = runtime.clock.now(); persist(); return api.tick();
	};
	api.status = (...args) => {
		if (length(args)) invalid();
		let local = local_for(runtime.clock.now());
		return clone({
			running: started, enabled: enabled(), local_time_valid: local.valid === true,
			in_maintenance_window: local.valid === true && local.in_window === true,
			last_scheduled_local_date: state.last_scheduled_local_date,
			last_check: state.last_check, next_check: state.next_check,
			publication_retry_tag: state.publication_retry_tag,
			publication_retry_count: state.publication_retry_count,
			latest_version: state.latest_version, readiness: state.readiness,
			pending_target: state.pending_target,
			pending_operation_id: state.pending_operation_id,
			traffic_samples: traffic.samples ?? 0,
			traffic_quiet: traffic.valid === true && traffic.quiet === true,
			traffic_deferral_count: state.traffic_deferral_count,
			last_error_code: state.last_error_code
		});
	};

	return api;
};
