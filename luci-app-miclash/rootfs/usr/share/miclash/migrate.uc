import { fail } from 'miclash.errors';
import { atomic_write } from 'miclash.storage';
import * as settings from 'miclash.settings';
import * as guard_latch from 'miclash.guard-latch';
import { with_lock } from 'miclash.mutation_lock';

const JOURNAL = '/etc/miclash/migration-v1.json';
const LEGACY_SETTINGS = '/opt/clash/settings';
const CANONICAL_MARKER = '/etc/miclash/canonical-preexisting';
const DAEMON_READY = '/tmp/miclash/daemon-ready.json';
const PHASES = { prepared: 1, applying: 2, applied: 3, verified: 4, complete: 5 };

function invalid() { fail('INVALID_ARGUMENT'); };
function internal() { fail('INTERNAL'); };

export function daemon_ready(runtime) {
	if (type(runtime?.fs?.readfile) != 'function' || type(runtime?.fs?.lstat) != 'function' ||
	    type(runtime?.ubus?.connect) != 'function')
		return false;
	let marker;
	try {
		let stat = runtime.fs.lstat(DAEMON_READY);
		let text = runtime.fs.readfile(DAEMON_READY);
		if (stat?.type != 'file' || (stat.uid != null && stat.uid != 0) ||
		    (stat.mode != null && stat.mode != 0o600) || type(text) != 'string' ||
		    !length(text) || length(text) > 4096)
			return false;
		marker = json(text);
		if (type(marker) != 'object' || marker.schema_version != 1 ||
		    marker.startup_reconciled !== true || type(marker.ready_at_ms) != 'int')
			return false;
	}
	catch (error) { return false; }
	let connection = null, healthy = false;
	try {
		connection = runtime.ubus.connect();
		if (type(connection?.call) == 'function') {
			let reply = connection.call('service', 'list', { name: 'miclashd', verbose: true });
			let running = false;
			for (let name, instance in reply?.miclashd?.instances ?? {})
				if (instance?.running === true) { running = true; break; }
			if (running) {
				let health = connection.call('miclash', 'health', {});
				healthy = type(health) == 'object' && health.error == null;
			}
		}
	}
	catch (error) { healthy = false; }
	try { connection?.disconnect?.(); } catch (error) {}
	return healthy;
};

function default_adapters(runtime) {
	function daemon_verify() {
		let deadline = runtime.clock.now() + 5000;
		while (true) {
			if (daemon_ready(runtime)) return true;
			if (runtime.clock.now() >= deadline) return false;
			runtime.clock.sleep(min(100, deadline - runtime.clock.now()));
		}
	};
	return {
		legacy_patch: settings.legacy_patch,
		load: () => settings.load(runtime),
		commit_patch: (expected, patch) => with_lock(runtime, { barrier: 'normal', wait_ms: 0 }, () => {
			// Marker and the complete canonical document are checked while holding
			// the same writer lease used by every UCI mutation. A user edit or
			// schema upgrade that lands after prepare always wins.
			if (runtime.fs.lstat(CANONICAL_MARKER) != null ||
			    !same(settings.load(runtime), expected)) return null;
			if (patch?.guard?.enabled === true && !guard_latch.is_set(runtime) &&
			    guard_latch.set(runtime) !== true) internal();
			return settings.save(runtime, patch);
		}),
		latch_is_set: () => guard_latch.is_set(runtime),
		latch_set: () => guard_latch.set(runtime),
		guard_verify: (enabled) => runtime.guard_control.verify(enabled),
		daemon_verify,
		write: (path, value) => atomic_write(runtime, path, value, 0o600)
	};
};

function read_journal(runtime) {
	let text = runtime.fs.readfile(JOURNAL);
	if (text == null) return null;
	if (type(text) != 'string' || length(text) > 131072) internal();
	let value;
	try { value = json(text); } catch (error) { internal(); }
	if (type(value) != 'object' || value.schema_version != 1 || !PHASES[value.phase] ||
	    type(value.canonical_preexisting) != 'bool' || type(value.had_legacy_settings) != 'bool' ||
	    type(value.canonical_prepared) != 'object')
		internal();
	return value;
};

function persist(runtime, adapters, journal) {
	let text = sprintf('%J\n', journal);
	let result = type(adapters.write) == 'function'
		? adapters.write(JOURNAL, text)
		: runtime.fs.writefile(JOURNAL, text);
	if (result !== true) internal();
	return journal;
};

function require_phase(journal, minimum) {
	if (journal == null || PHASES[journal.phase] < PHASES[minimum]) invalid();
};

function same(left, right) {
	try { return sprintf('%J', left) == sprintf('%J', right); }
	catch (error) { internal(); }
};

function apply_patch_safely(adapters, journal) {
	if (journal.canonical_preexisting || journal.patch == null) return false;
	let committed;
	if (type(adapters.commit_patch) == 'function')
		committed = adapters.commit_patch(journal.canonical_before, journal.patch);
	else {
		if (!same(adapters.load(), journal.canonical_before)) return false;
		if (journal.patch?.guard?.enabled === true && !adapters.latch_is_set() &&
		    adapters.latch_set() !== true) internal();
		committed = adapters.save(journal.patch);
	}
	if (committed == null) return false;
	journal.canonical_after = committed;
	return true;
};

export function run(runtime, injected, action) {
	if (type(runtime) != 'object' || type(runtime.fs) != 'object' ||
	    index([ 'prepare', 'apply', 'verify', 'cleanup', 'status' ], action) < 0)
		invalid();
	let adapters = injected ?? default_adapters(runtime);
	let journal = read_journal(runtime);
	if (action == 'status') return journal;

	if (action == 'prepare') {
		if (journal != null) return journal;
		let legacy = runtime.fs.readfile(LEGACY_SETTINGS);
		let patch = null;
		if (legacy != null) patch = adapters.legacy_patch(legacy);
		journal = {
			schema_version: 1, phase: 'prepared', prepared_at_ms: runtime.clock.now(),
			canonical_preexisting: runtime.fs.lstat(CANONICAL_MARKER) != null,
			canonical_prepared: adapters.load(),
			had_legacy_settings: legacy != null,
			legacy_settings: legacy,
			patch
		};
		return persist(runtime, adapters, journal);
	}

	require_phase(journal, 'prepared');
	if (action == 'apply') {
		if (PHASES[journal.phase] >= PHASES.applied) return journal;
		if (journal.phase == 'applying') {
			// A crash may happen after UCI commit but before the next journal write.
			// Replay only when canonical state is still exactly the pre-commit state.
			// Any change may be a user edit and therefore wins.
			if (runtime.fs.lstat(CANONICAL_MARKER) == null &&
			    same(adapters.load(), journal.canonical_before))
				journal.patch_applied = apply_patch_safely(adapters, journal);
			journal.phase = 'applied';
			journal.recovered_interrupted_apply = true;
			return persist(runtime, adapters, journal);
		}
		let current = adapters.load();
		if (runtime.fs.lstat(CANONICAL_MARKER) != null ||
		    !same(current, journal.canonical_prepared)) {
			journal.canonical_preexisting = true;
			journal.user_edit_preserved = true;
		}
		journal.canonical_before = current;
		journal.phase = 'applying';
		persist(runtime, adapters, journal);
		journal.patch_applied = apply_patch_safely(adapters, journal);
		if (!journal.patch_applied && journal.patch != null && !journal.canonical_preexisting)
			journal.user_edit_preserved = true;
		journal.phase = 'applied';
		journal.applied_at_ms = runtime.clock.now();
		return persist(runtime, adapters, journal);
	}

	require_phase(journal, 'applied');
	if (action == 'verify') {
		if (PHASES[journal.phase] >= PHASES.verified) return journal;
		let current = adapters.load();
		if (type(current) != 'object' || adapters.guard_verify(current?.guard?.enabled === true) !== true ||
		    (type(adapters.daemon_verify) == 'function' && adapters.daemon_verify() !== true))
			fail('HEALTH_FAILED');
		journal.phase = 'verified';
		journal.verified_at_ms = runtime.clock.now();
		return persist(runtime, adapters, journal);
	}

	require_phase(journal, 'verified');
	if (journal.phase == 'complete') {
		if (runtime.fs.lstat(CANONICAL_MARKER) != null &&
		    runtime.fs.unlink(CANONICAL_MARKER) !== true) internal();
		return journal;
	}
	if (journal.had_legacy_settings && runtime.fs.lstat(LEGACY_SETTINGS) != null &&
	    runtime.fs.unlink(LEGACY_SETTINGS) !== true) internal();
	if (runtime.fs.lstat(CANONICAL_MARKER) != null && runtime.fs.unlink(CANONICAL_MARKER) !== true)
		internal();
	journal.phase = 'complete';
	journal.completed_at_ms = runtime.clock.now();
	journal.legacy_settings = null;
	journal.patch = null;
	return persist(runtime, adapters, journal);
};
