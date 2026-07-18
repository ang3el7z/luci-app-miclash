import * as errors from 'miclash.errors';
import * as storage from 'miclash.storage';

const DAY = 86400 * 1000;
const MONTH = 30 * DAY;
const MAX_DATABASE_BYTES = 4 * 1024 * 1024;
const STATE_PATH = '/opt/clash/device-vendor-update.json';
const DATABASE_PATH = '/etc/miclash/device-vendors.db';
const DEFAULT_MANIFEST_URL = 'https://raw.githubusercontent.com/ang3el7z/luci-app-miclash/main/luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/device-vendors.manifest.json';
const DEFAULT_DATABASE_URL = 'https://raw.githubusercontent.com/ang3el7z/luci-app-miclash/main/luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/device-vendors.db';

function invalid() { errors.fail('INVALID_ARGUMENT'); };

function clone(value) {
	try { return json(sprintf('%J', value)); }
	catch (error) { errors.fail('INTERNAL'); }
};

function timestamp(value) {
	return type(value) == 'int' && value >= 0 && value <= 253402300799999;
};

export function next_check(now, success) {
	if (!timestamp(now) || type(success) != 'bool') invalid();
	return now + (success ? MONTH : DAY);
};

function initial_state(now) {
	return { version: 1, last_attempt: null, last_success: null,
		next_check: next_check(now, true), snapshot: null,
		last_result: null, last_error: null, observed_at: now };
};

function state(value) {
	if (type(value) != 'object' || value.version != 1 ||
		(value.last_attempt != null && !timestamp(value.last_attempt)) ||
		(value.last_success != null && !timestamp(value.last_success)) ||
		!timestamp(value.next_check) || !timestamp(value.observed_at) ||
		(value.snapshot != null && !match(value.snapshot, /^20[0-9]{2}-[0-9]{2}-[0-9]{2}$/)) ||
		(value.last_result != null && value.last_result != 'success' && value.last_result != 'failure') ||
		(value.last_error != null && (type(value.last_error) != 'string' || length(value.last_error) > 64)))
		errors.fail('CORRUPT_STATE');
	return value;
};

export function validate_manifest(value) {
	if (type(value) != 'object') errors.fail('INVALID_RESPONSE');
	let count = 0;
	for (let name in value) {
		if (name != 'version' && name != 'snapshot' && name != 'size' && name != 'sha256')
			errors.fail('INVALID_RESPONSE');
		count++;
	}
	if (count != 4 || value.version != 1 ||
		!match(value.snapshot, /^20[0-9]{2}-[0-9]{2}-[0-9]{2}$/) ||
		type(value.size) != 'int' || value.size < 64 || value.size > MAX_DATABASE_BYTES ||
		type(value.sha256) != 'string' || !match(value.sha256, /^[0-9a-f]{64}$/))
		errors.fail('INVALID_RESPONSE');
	return value;
};

export function validate_database(runtime, content, manifest) {
	validate_manifest(manifest);
	if (type(content) != 'string' || length(content) != manifest.size ||
		runtime.digest.sha256(content) != manifest.sha256)
		errors.fail('INVALID_RESPONSE');
	let lines = split(replace(content, /\r/g, ''), '\n');
	if (lines[0] != '# miclash-device-vendors-v1' ||
		lines[1] != '# snapshot=' + manifest.snapshot)
		errors.fail('INVALID_RESPONSE');
	let vendors = 0, prefixes = 0;
	for (let index = 2; index < length(lines); index++) {
		let line = lines[index];
		if (!length(line) || substr(line, 0, 1) == '#') continue;
		if (match(line, /^V\t[0-9A-Z]+\t[^\t\r\n]{1,160}$/)) vendors++;
		else if (match(line, /^P\t(24\t[0-9A-F]{6}|28\t[0-9A-F]{7}|36\t[0-9A-F]{9})\t[0-9A-Z]+$/)) prefixes++;
		else errors.fail('INVALID_RESPONSE');
	}
	if (vendors < 1 || prefixes < 1) errors.fail('INVALID_RESPONSE');
	return true;
};

export function create(app) {
	if (type(app?.runtime?.clock?.now) != 'function' ||
		type(app?.runtime?.clock?.set_timeout) != 'function' ||
		type(app?.runtime?.digest?.sha256) != 'function' ||
		type(app?.runtime?.fs) != 'object' || type(app?.http?.request) != 'function')
		invalid();
	let runtime = app.runtime, manifest_url = app.manifest_url ?? DEFAULT_MANIFEST_URL,
		database_url = app.database_url ?? DEFAULT_DATABASE_URL;
	let current;
	try { current = state(storage.read_json(runtime, STATE_PATH)); }
	catch (error) {
		if (errors.normalize(error).code != 'NOT_FOUND')
			try { runtime.logger?.warn('Device vendor update state was reset'); } catch (ignored) {}
		current = initial_state(runtime.clock.now());
	}
	let started = false, closed = false, timer = null, api = {};

	function persist() {
		current.observed_at = runtime.clock.now();
		state(current);
		storage.write_json(runtime, STATE_PATH, current, 0o600);
	};

	function cancel_timer() {
		if (timer == null) return false;
		let active = timer; timer = null;
		try { active.cancel(); } catch (error) {}
		return true;
	};

	function schedule() {
		cancel_timer();
		if (!started || closed) return false;
		let delay = min(DAY, max(0, current.next_check - runtime.clock.now()));
		timer = runtime.clock.set_timeout(delay, () => { timer = null; api.tick(); });
		if (timer == null || type(timer.cancel) != 'function') errors.fail('INTERNAL');
		return true;
	};

	function body(reply, maximum) {
		if (type(reply) != 'object' || reply.status < 200 || reply.status >= 300 ||
			type(reply.body) != 'string' || length(reply.body) > maximum)
			errors.fail('INVALID_RESPONSE');
		return reply.body;
	};

	function refresh() {
		let manifest_content = body(app.http.request(runtime, {
			url: manifest_url, managed: true, connect_timeout_ms: 8000,
			timeout_ms: 30000, max_redirects: 3, max_bytes: 4096
		}), 4096);
		let manifest;
		try { manifest = validate_manifest(json(manifest_content)); }
		catch (error) { errors.fail(errors.normalize(error).code == 'INVALID_RESPONSE'
			? 'INVALID_RESPONSE' : 'INVALID_RESPONSE'); }
		if (current.snapshot != null && manifest.snapshot < current.snapshot)
			errors.fail('INVALID_RESPONSE');
		if (manifest.snapshot != current.snapshot) {
			let database = body(app.http.request(runtime, {
				url: database_url, managed: true, connect_timeout_ms: 8000,
				timeout_ms: 180000, max_redirects: 3, max_bytes: manifest.size
			}), manifest.size);
			validate_database(runtime, database, manifest);
			storage.atomic_write(runtime, DATABASE_PATH, database, 0o644);
		}
		current.snapshot = manifest.snapshot;
		return true;
	};

	api.tick = () => {
		if (closed || !started) return clone(current);
		let now = runtime.clock.now();
		if (now < current.next_check) { schedule(); return clone(current); }
		current.last_attempt = now;
		try {
			refresh();
			current.last_success = now; current.last_result = 'success'; current.last_error = null;
			current.next_check = next_check(now, true);
		}
		catch (error) {
			current.last_result = 'failure'; current.last_error = errors.normalize(error).code;
			current.next_check = next_check(now, false);
		}
		persist(); schedule(); return clone(current);
	};
	api.start = () => {
		if (closed || started) return false;
		started = true; persist(); schedule(); return true;
	};
	api.status = () => clone(current);
	api.close = () => {
		if (closed) return false;
		closed = true; started = false; cancel_timer(); return true;
	};
	return api;
};
