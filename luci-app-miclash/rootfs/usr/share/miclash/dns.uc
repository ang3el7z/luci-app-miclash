import { fail } from 'miclash.errors';
import { write_json } from 'miclash.storage';
import { assert_held, with_lock } from 'miclash.mutation_lock';

const MANIFEST_PATH = '/etc/miclash/dns-ownership.json';
const LEGACY_PATH = '/opt/clash/.dns_backup';
const PACKAGE_BARRIER = '/var/run/miclash/package-removal';
const TARGET = '127.0.0.1#7874';
const MAX_MANIFEST = 16384;
const MAX_LEGACY = 128;

function exact_fields(value, allowed) {
	if (type(value) != 'object' || type(value) == 'array') return false;
	for (let name in value) if (!exists(allowed, name)) return false;
	for (let name in allowed) if (!exists(value, name)) return false;
	return true;
};

function clone(value) { return value == null ? value : json(sprintf('%J', value)); };
function same(left, right) { return sprintf('%J', left) == sprintf('%J', right); };
function empty_object(value) { for (let name in value ?? {}) return false; return true; };
function count(values, wanted) {
	let result = 0;
	for (let value in values ?? []) if (value == wanted) result++;
	return result;
};

function owned_target_unambiguous(document, current) {
	if (document.target_preexisting) return true;
	if (count(current.server.value, TARGET) != 1) return false;
	let target_index = -1;
	for (let i = 0; i < length(current.server.value); i++)
		if (current.server.value[i] == TARGET) target_index = i;
	let offset = 0;
	for (let original in document.original.server.value) {
		let found = -1;
		for (let i = offset; i < target_index; i++)
			if (current.server.value[i] == original) { found = i; break; }
		if (found < 0) return false;
		offset = found + 1;
	}
	return true;
};

function option(value, list) {
	if (value == null) return { present: false, value: list ? [] : null };
	if (list) {
		if (type(value) == 'string') value = [ value ];
		if (type(value) != 'array') return null;
		for (let item in value) if (type(item) != 'string') return null;
		return { present: true, value: [ ...value ] };
	}
	return type(value) == 'string' ? { present: true, value } : null;
};

function snapshot(section) {
	let server = option(section?.server, true);
	let cachesize = option(section?.cachesize, false);
	let noresolv = option(section?.noresolv, false);
	return server == null || cachesize == null || noresolv == null ? null :
		{ server, cachesize, noresolv };
};

function validate_option(value, list) {
	if (!exact_fields(value, { present: true, value: true }) || type(value.present) != 'bool')
		return null;
	if (list) {
		if (type(value.value) != 'array' || (!value.present && length(value.value))) return null;
		for (let item in value.value) if (type(item) != 'string') return null;
	}
	else if ((value.present && type(value.value) != 'string') || (!value.present && value.value != null))
		return null;
	return clone(value);
};

function validate_snapshot(value) {
	if (!exact_fields(value, { server: true, cachesize: true, noresolv: true })) return null;
	let server = validate_option(value.server, true), cachesize = validate_option(value.cachesize, false),
		noresolv = validate_option(value.noresolv, false);
	return server == null || cachesize == null || noresolv == null ? null :
		{ server, cachesize, noresolv };
};

function same_device(left, right) {
	return left?.dev?.major != null && left.dev.major == right?.dev?.major &&
		left.dev.minor == right?.dev?.minor;
};
function same_identity(left, right) {
	return left?.type == right?.type && left?.inode != null && left.inode == right?.inode &&
		left.nlink == right?.nlink && left.size == right?.size && same_device(left, right);
};

function secure_parent(runtime, path, parents) {
	for (let parent in parents) {
		let stat = runtime.fs.lstat(parent);
		if (stat?.type != 'directory' || stat.uid != 0 || (stat.mode & 0o022) != 0 ||
		    runtime.fs.realpath(parent) != parent)
			return false;
	}
	return runtime.fs.realpath(path) == path;
};

function secure_read(runtime, path, maximum, parents) {
	let leaf = runtime.fs.lstat(path);
	if (leaf == null) return { status: 'absent', source: null };
	if (!secure_parent(runtime, path, parents) || leaf.type != 'file' || leaf.uid != 0 ||
	    leaf.mode != 0o600 || leaf.nlink != 1 || leaf.size <= 0 || leaf.size > maximum)
		return { status: 'invalid', source: null };
	let handle = null, source = '', result = { status: 'invalid', source: null };
	try {
		handle = runtime.fs.open(path, 're');
		if (handle != null) {
			let before = runtime.fs.fstat(handle), valid = same_identity(leaf, before) &&
				before.uid == 0 && before.mode == 0o600 && before.nlink == 1;
			while (valid && length(source) <= maximum) {
				let chunk = runtime.fs.read(handle, 4096);
				if (type(chunk) != 'string') { valid = false; break; }
				if (!length(chunk)) break;
				source += chunk;
			}
			let after = runtime.fs.fstat(handle), verified = runtime.fs.lstat(path);
			valid = valid && length(source) == leaf.size && length(source) <= maximum &&
				same_identity(before, after) && same_identity(leaf, verified) &&
				after.uid == 0 && after.mode == 0o600 && after.nlink == 1 &&
				verified.uid == 0 && verified.mode == 0o600 && verified.nlink == 1 &&
				secure_parent(runtime, path, parents);
			if (valid) result = { status: 'read', source };
		}
	}
	catch (error) {}
	if (handle != null) try { if (runtime.fs.close(handle) != true) result = { status: 'invalid', source: null }; }
	catch (error) { result = { status: 'invalid', source: null }; }
	return result;
};

function validate_manifest(value) {
	if (!exact_fields(value, { version: true, owner: true, section: true, original: true,
	    target_preexisting: true, state: true, transition: true, clean: true }) || value.version != 1 ||
	    value.owner != 'miclash' || type(value.section) != 'string' || !length(value.section) ||
	    type(value.target_preexisting) != 'bool' ||
	    (value.state != 'active' && value.state != 'clean')) return null;
	let original = validate_snapshot(value.original);
	if (original == null) return null;
	let transition = null;
	if (value.transition != null) {
		if (!exact_fields(value.transition, { intent: true, before: true, after: true }) ||
		    (value.transition.intent != 'apply' && value.transition.intent != 'cleanup')) return null;
		let before = validate_snapshot(value.transition.before), after = validate_snapshot(value.transition.after);
		if (before == null || after == null) return null;
		transition = { intent: value.transition.intent, before, after };
	}
	let clean = value.clean == null ? null : validate_snapshot(value.clean);
	if ((value.state == 'clean' && (transition != null || clean == null)) ||
	    (value.state == 'active' && clean != null)) return null;
	return { version: 1, owner: 'miclash', section: value.section, original,
		target_preexisting: value.target_preexisting, state: value.state, transition, clean };
};

function load_manifest(runtime) {
	let captured = secure_read(runtime, MANIFEST_PATH, MAX_MANIFEST, [ '/etc', '/etc/miclash' ]);
	if (captured.status == 'absent') return { status: 'absent', trusted: false, document: null };
	if (captured.status != 'read') return { status: 'invalid', trusted: false, document: null };
	try {
		let document = validate_manifest(json(captured.source));
		return document == null ? { status: 'invalid', trusted: false, document: null } :
			{ status: 'trusted', trusted: true, document };
	}
	catch (error) { return { status: 'invalid', trusted: false, document: null }; }
};

function barrier_state(runtime) {
	let leaf = runtime.fs.lstat(PACKAGE_BARRIER);
	if (leaf == null) return 'absent';
	let parent = runtime.fs.lstat('/var/run/miclash');
	let canonical = runtime.fs.realpath(PACKAGE_BARRIER);
	if (parent?.type != 'directory' || parent.uid != 0 || (parent.mode & 0o077) != 0 ||
	    leaf.type != 'directory' || leaf.uid != 0 || (leaf.mode & 0o077) != 0 ||
	    (canonical != PACKAGE_BARRIER && canonical != '/run/miclash/package-removal' &&
	     canonical != '/tmp/run/miclash/package-removal'))
		return 'invalid';
	return 'active';
};

function assert_mutation_allowed(runtime, package_cleanup) {
	let state = barrier_state(runtime);
	if (state == 'absent' && !package_cleanup) return;
	if (state == 'active' && package_cleanup && runtime.package_removal_cleanup === true) return;
	fail('BUSY');
};

function raw_observe(runtime, supplied_cursor) {
	let cursor = supplied_cursor ?? runtime?.uci?.cursor?.();
	if (cursor == null) fail('INTERNAL');
	let conflicts = [];
	if (!empty_object(cursor.changes('dhcp'))) push(conflicts, 'PENDING_CHANGES');
	let sections = cursor.get_all('dhcp') ?? {}, names = [];
	for (let name, value in sections) if (value?.['.type'] == 'dnsmasq') push(names, name);
	let first = cursor.get_first('dhcp', 'dnsmasq');
	if (length(names) != 1 || first == null || names[0] != first) push(conflicts, 'SECTION_IDENTITY');
	let current = first == null ? null : snapshot(cursor.get_all('dhcp', first));
	if (current == null) push(conflicts, 'INVALID_UCI');
	return { section: first, current, conflicts };
};

export function observe(runtime) {
	let result = raw_observe(runtime), loaded = load_manifest(runtime);
	let ownership = { trusted: loaded.trusted, status: loaded.status, state: null,
		transition: null, transition_state: null, original: null, target_preexisting: null };
	if (loaded.status == 'invalid') push(result.conflicts, 'INVALID_MANIFEST');
	if (loaded.trusted) {
		let document = loaded.document;
		ownership = { trusted: true, status: 'trusted', state: document.state,
			transition: document.transition, transition_state: null,
			original: clone(document.original), target_preexisting: document.target_preexisting,
			clean: clone(document.clean),
			document: clone(document) };
		if (result.section != document.section) push(result.conflicts, 'SECTION_IDENTITY');
		if (document.transition != null && result.current != null) {
			if (same(result.current, document.transition.before)) ownership.transition_state = 'before';
			else if (same(result.current, document.transition.after)) ownership.transition_state = 'after';
			else push(result.conflicts, 'THIRD_STATE');
		}
		else if (document.state == 'active' && result.current != null) {
			if (!owned_target_unambiguous(document, result.current))
				push(result.conflicts, 'TARGET_AMBIGUOUS');
			if (!result.current.cachesize.present || result.current.cachesize.value != '0' ||
			    !result.current.noresolv.present || result.current.noresolv.value != '1')
				push(result.conflicts, 'SCALAR_DRIFT');
		}
	}
	else if (loaded.status == 'absent' && result.current != null &&
	         count(result.current.server.value, TARGET) > 0 &&
	         result.current.cachesize.present && result.current.cachesize.value == '0' &&
	         result.current.noresolv.present && result.current.noresolv.value == '1')
		push(result.conflicts, 'AMBIGUOUS_ACTIVE');
	result.ownership = ownership;
	return result;
};

export function desired(observed) {
	if (type(observed) != 'object' || observed.current == null || length(observed.conflicts ?? []))
		fail('INVALID_ARGUMENT');
	let ownership = observed.ownership, original, target_preexisting, authority_state;
	if (ownership.trusted) {
		if (ownership.state != 'active' || ownership.transition != null) fail('INVALID_ARGUMENT');
		original = clone(ownership.original);
		target_preexisting = ownership.target_preexisting;
		authority_state = 'active';
	}
	else {
		if (ownership.status != 'absent') fail('INVALID_ARGUMENT');
		original = clone(observed.current);
		target_preexisting = count(observed.current.server.value, TARGET) > 0;
		authority_state = 'absent';
	}
	let after = clone(observed.current);
	if (!count(after.server.value, TARGET)) push(after.server.value, TARGET);
	after.server.present = true;
	after.cachesize = { present: true, value: '0' };
	after.noresolv = { present: true, value: '1' };
	return { version: 1, action: 'apply', section: observed.section,
		before: clone(observed.current), after, original, target_preexisting, authority_state };
};

function persist(runtime, section, original, target_preexisting, state, transition, clean) {
	assert_held(runtime, runtime.mutation_lock_lease);
	write_json(runtime, MANIFEST_PATH, { version: 1, owner: 'miclash', section,
		original: clone(original), target_preexisting, state, transition: clone(transition),
		clean: clone(clean) }, 0o600);
};

function set_option(cursor, section, name, value) {
	let ok = value.present ? cursor.set('dhcp', section, name, clone(value.value)) :
		cursor.delete('dhcp', section, name);
	if (value.present && ok != true) fail('INTERNAL');
	if (!value.present && ok != true && cursor.get('dhcp', section, name) != null) fail('INTERNAL');
};

function commit_snapshot(runtime, section, expected_before, value) {
	let cursor = runtime.uci.cursor(), commit_started = false;
	let same_cursor = raw_observe(runtime, cursor);
	if (length(same_cursor.conflicts) || same_cursor.section != section ||
	    !same(same_cursor.current, expected_before))
		fail('CORRUPT_STATE');
	try {
		set_option(cursor, section, 'server', value.server);
		set_option(cursor, section, 'cachesize', value.cachesize);
		set_option(cursor, section, 'noresolv', value.noresolv);
		assert_held(runtime, runtime.mutation_lock_lease);
		commit_started = true;
		if (cursor.commit('dhcp') != true) fail('INTERNAL');
	}
	catch (error) {
		if (!commit_started) try { cursor.revert('dhcp'); } catch (revert_error) {}
		fail(error?.code ?? error?.message ?? 'INTERNAL');
	}
	let verified = raw_observe(runtime);
	if (length(verified.conflicts) || verified.section != section || !same(verified.current, value))
		fail('INTERNAL');
};

function restart_and_verify(runtime, section, expected) {
	assert_held(runtime, runtime.mutation_lock_lease);
	if (runtime.process.run({ command: '/etc/init.d/dnsmasq', args: [ 'restart' ] })?.code != 0)
		fail('HEALTH_FAILED');
	if (runtime.process.run({ command: '/etc/init.d/dnsmasq', args: [ 'running' ] })?.code != 0)
		fail('HEALTH_FAILED');
	let verified = raw_observe(runtime);
	if (length(verified.conflicts) || verified.section != section || !same(verified.current, expected))
		fail('INTERNAL');
};

function exact_plan(plan, fresh) {
	let expected;
	try { expected = desired(fresh); }
	catch (error) { return false; }
	return same(plan, expected);
};

function prove_clean(runtime, document) {
	if (document?.state != 'clean' || document.transition != null || document.clean == null)
		fail('CORRUPT_STATE');
	let observed = raw_observe(runtime);
	if (length(observed.conflicts) || observed.section != document.section ||
	    !same(observed.current, document.clean))
		fail('CORRUPT_STATE');
	return true;
};

function finish_transition(runtime, document, intent) {
	let observed = observe(runtime), transition = document.transition;
	if (transition == null || transition.intent != intent ||
	    (observed.ownership.transition_state != 'before' && observed.ownership.transition_state != 'after'))
		fail('CORRUPT_STATE');
	if (observed.ownership.transition_state == 'before')
		commit_snapshot(runtime, document.section, transition.before, transition.after);
	restart_and_verify(runtime, document.section, transition.after);
	let state = intent == 'apply' ? 'active' : 'clean';
	persist(runtime, document.section, document.original, document.target_preexisting, state, null,
		state == 'clean' ? transition.after : null);
	if (state == 'clean') prove_clean(runtime, load_manifest(runtime).document);
	return { changed: true, state };
};

function apply_locked(runtime, plan) {
	assert_mutation_allowed(runtime, false);
	let fresh = observe(runtime);
	if (length(fresh.conflicts) || !exact_plan(plan, fresh)) fail('INVALID_ARGUMENT');
	if (fresh.ownership.trusted && same(plan.before, plan.after))
		return { changed: false, state: 'active' };
	let transition = { intent: 'apply', before: clone(plan.before), after: clone(plan.after) };
	persist(runtime, plan.section, plan.original, plan.target_preexisting, 'active', transition, null);
	let document = load_manifest(runtime).document;
	return finish_transition(runtime, document, 'apply');
};

export function apply(runtime, plan) {
	return with_lock(runtime, { barrier: 'normal', wait_ms: 0 }, () => apply_locked(runtime, plan));
};

function without_owned_target(values) {
	let last = -1, result = [];
	for (let i = 0; i < length(values); i++) if (values[i] == TARGET) last = i;
	for (let i = 0; i < length(values); i++) if (i != last) push(result, values[i]);
	return result;
};

function cleanup_after(document, current) {
	let after = clone(current);
	if (!document.target_preexisting) {
		if (!owned_target_unambiguous(document, current)) fail('CORRUPT_STATE');
		after.server.value = without_owned_target(after.server.value);
		after.server.present = length(after.server.value) > 0 || document.original.server.present;
	}
	if (after.cachesize.present && after.cachesize.value == '0')
		after.cachesize = clone(document.original.cachesize);
	if (after.noresolv.present && after.noresolv.value == '1')
		after.noresolv = clone(document.original.noresolv);
	return after;
};

function secure_unlink_manifest(runtime) {
	let loaded = load_manifest(runtime);
	if (!loaded.trusted || loaded.document.state != 'clean' || loaded.document.transition != null)
		fail('CORRUPT_STATE');
	prove_clean(runtime, loaded.document);
	if (runtime.fs.unlink(MANIFEST_PATH) != true || runtime.fs.lstat(MANIFEST_PATH) != null)
		fail('INTERNAL');
};

function parse_legacy(source) {
	let matched = match(source, /^CACHESIZE=([^\n]*)\nNORESOLV=([^\n]*)\n$/);
	if (!matched || (length(matched[1]) && !match(matched[1], /^(0|[1-9][0-9]{0,9})$/)) ||
	    !match(matched[2], /^(|0|1)$/)) return null;
	if (length(matched[1]) && int(matched[1]) > 2147483647) return null;
	return {
		cachesize: { present: length(matched[1]) > 0, value: length(matched[1]) ? matched[1] : null },
		noresolv: { present: length(matched[2]) > 0, value: length(matched[2]) ? matched[2] : null }
	};
};

function migrate_legacy(runtime) {
	let captured = secure_read(runtime, LEGACY_PATH, MAX_LEGACY, [ '/opt', '/opt/clash' ]);
	if (captured.status == 'absent') return false;
	if (captured.status != 'read') fail('CORRUPT_STATE');
	let legacy = parse_legacy(captured.source);
	if (legacy == null) fail('CORRUPT_STATE');
	if (!legacy.cachesize.present && !legacy.noresolv.present) fail('CORRUPT_STATE');
	let observed = raw_observe(runtime);
	if (length(observed.conflicts) || observed.current == null ||
	    count(observed.current.server.value, TARGET) < 1 ||
	    !observed.current.cachesize.present || observed.current.cachesize.value != '0' ||
	    !observed.current.noresolv.present || observed.current.noresolv.value != '1')
		fail('CORRUPT_STATE');
	let loaded = load_manifest(runtime);
	if (loaded.status == 'invalid') fail('CORRUPT_STATE');
	if (loaded.status == 'absent') {
		let servers = without_owned_target(observed.current.server.value);
		let original = { server: { present: length(servers) > 0, value: servers },
			cachesize: legacy.cachesize, noresolv: legacy.noresolv };
		persist(runtime, observed.section, original, false, 'active', null, null);
	}
	else if (loaded.document.section != observed.section || loaded.document.state != 'active' ||
	         loaded.document.transition != null || loaded.document.target_preexisting ||
	         !same(loaded.document.original.cachesize, legacy.cachesize) ||
	         !same(loaded.document.original.noresolv, legacy.noresolv))
		fail('CORRUPT_STATE');
	let verified = load_manifest(runtime);
	if (!verified.trusted || verified.document.state != 'active') fail('CORRUPT_STATE');
	if (runtime.fs.unlink(LEGACY_PATH) != true || runtime.fs.lstat(LEGACY_PATH) != null)
		fail('INTERNAL');
	return true;
};

function recover_locked(runtime, intent) {
	let package_mode = runtime.package_removal_cleanup === true;
	assert_mutation_allowed(runtime, package_mode);
	migrate_legacy(runtime);
	let loaded = load_manifest(runtime);
	if (loaded.status == 'absent') {
		if (intent == 'clean') return { clean: true, changed: false, state: 'clean' };
		fail('NOT_FOUND');
	}
	if (!loaded.trusted) fail('CORRUPT_STATE');
	let document = loaded.document;
	if (document.transition == null) {
		if (document.state != intent) fail('CORRUPT_STATE');
		if (intent == 'clean') prove_clean(runtime, document);
		return intent == 'clean' ? { clean: true, changed: false, state: 'clean' } :
			{ changed: false, state: 'active' };
	}
	let transition_intent = intent == 'active' ? 'apply' : 'cleanup';
	let result = finish_transition(runtime, document, transition_intent);
	return intent == 'clean' ? { ...result, clean: true } : result;
};

export function recover(runtime, intent) {
	if (intent != 'active' && intent != 'clean') fail('INVALID_ARGUMENT');
	let package_mode = runtime.package_removal_cleanup === true;
	return with_lock(runtime, { barrier: package_mode ? 'package' : 'normal', wait_ms: 0 },
		() => recover_locked(runtime, intent));
};

function cleanup_locked(runtime) {
	let package_mode = runtime.package_removal_cleanup === true;
	assert_mutation_allowed(runtime, package_mode);
	migrate_legacy(runtime);
	let loaded = load_manifest(runtime);
	if (loaded.status == 'absent') {
		let observed = observe(runtime);
		if (length(observed.conflicts) || observed.current == null ||
		    count(observed.current.server.value, TARGET) > 0 ||
		    (observed.current.cachesize.present && observed.current.cachesize.value == '0') ||
		    (observed.current.noresolv.present && observed.current.noresolv.value == '1'))
			fail('CORRUPT_STATE');
		return { clean: true, changed: false };
	}
	if (!loaded.trusted) fail('CORRUPT_STATE');
	if (loaded.document.transition != null) {
		let wanted = loaded.document.transition.intent == 'apply' ? 'active' : 'clean';
		recover_locked(runtime, wanted);
		loaded = load_manifest(runtime);
	}
	if (loaded.document.state == 'clean') {
		prove_clean(runtime, loaded.document);
		if (!package_mode) secure_unlink_manifest(runtime);
		return { clean: true, changed: false };
	}
	let raw = raw_observe(runtime);
	if (length(raw.conflicts) || raw.section != loaded.document.section || raw.current == null)
		fail('CORRUPT_STATE');
	let after = cleanup_after(loaded.document, raw.current);
	let transition = { intent: 'cleanup', before: clone(raw.current), after };
	persist(runtime, raw.section, loaded.document.original, loaded.document.target_preexisting,
		'active', transition, null);
	finish_transition(runtime, load_manifest(runtime).document, 'cleanup');
	if (!package_mode) secure_unlink_manifest(runtime);
	return { clean: true, changed: !same(raw.current, after) };
};

export function cleanup(runtime) {
	let package_mode = runtime.package_removal_cleanup === true;
	return with_lock(runtime, { barrier: package_mode ? 'package' : 'normal', wait_ms: 0 },
		() => cleanup_locked(runtime));
};

export const paths = { manifest: MANIFEST_PATH, legacy: LEGACY_PATH };
