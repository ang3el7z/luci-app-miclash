import { fail } from 'miclash.errors';

const ROOT = '/var/run/miclash';
const LOCK = ROOT + '/mutation.lock';
const TAKEOVER = ROOT + '/mutation.lock.takeover';
const PARTICIPANTS = 'participants';
const OWNER = 'owner';
const BARRIER = ROOT + '/package-removal';
const MAX_RECORD = 768;
const INIT_GRACE_MS = 5000;

function busy() { fail('BUSY'); };

function has(values, wanted) {
	for (let value in values) if (value == wanted) return true;
	return false;
};

function exact_fields(value, allowed) {
	if (type(value) != 'object') return false;
	for (let name in value) if (!allowed[name]) return false;
	for (let name in allowed) if (!exists(value, name)) return false;
	return true;
};

function process_start(text, expected_pid) {
	if (type(text) != 'string' || length(text) > 4096) return null;
	let close = rindex(text, ')');
	if (close < 3) return null;
	let prefix = substr(text, 0, index(text, ' '));
	if (!match(prefix, /^[0-9]+$/) || int(prefix) != expected_pid) return null;
	let fields = split(trim(substr(text, close + 1)), /[ \t]+/);
	if (length(fields) < 20 || !match(fields[19], /^[0-9]+$/)) return null;
	return int(fields[19]);
};

function boot_id(runtime) {
	let value = trim(runtime.fs.readfile('/proc/sys/kernel/random/boot_id'));
	if (!match(value, /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/))
		fail('INTERNAL');
	return value;
};

function self_identity(runtime) {
	let injected = runtime.mutation_lock_self;
	if (injected != null) {
		if (!exact_fields(injected, { boot: true, pid: true, start: true }) ||
		    injected.boot != boot_id(runtime) || type(injected.pid) != 'int' ||
		    injected.pid < 1 || type(injected.start) != 'int' || injected.start < 1)
			fail('INTERNAL');
		return injected;
	}
	let text = runtime.fs.readfile('/proc/self/stat');
	if (type(text) != 'string') fail('INTERNAL');
	let first = index(text, ' '), pid = first > 0 ? int(substr(text, 0, first)) : null;
	let started = pid != null ? process_start(text, pid) : null;
	if (pid == null || pid < 1 || started == null) fail('INTERNAL');
	return { boot: boot_id(runtime), pid, start: started };
};

function identity_live(runtime, identity) {
	if (identity?.boot != boot_id(runtime) || type(identity.pid) != 'int' ||
	    type(identity.start) != 'int') return false;
	let text = runtime.fs.readfile('/proc/' + identity.pid + '/stat');
	return process_start(text, identity.pid) == identity.start;
};

function token(identity) {
	return identity.boot + ':' + identity.pid + ':' + identity.start + ':' + identity.nonce;
};

function encode_owner(identity) {
	return 'version=1\nboot=' + identity.boot + '\npid=' + identity.pid +
		'\nstart=' + identity.start + '\nnonce=' + identity.nonce + '\n';
};

function encode_participant(owner_token, identity) {
	return 'version=1\nowner=' + owner_token + '\nboot=' + identity.boot +
		'\npid=' + identity.pid + '\nstart=' + identity.start +
		'\nnonce=' + identity.nonce + '\n';
};

function parse_lines(text) {
	if (type(text) != 'string' || !length(text) || length(text) > MAX_RECORD ||
	    substr(text, length(text) - 1) != '\n') return null;
	let result = {};
	for (let line in split(substr(text, 0, length(text) - 1), '\n')) {
		let at = index(line, '=');
		if (at < 1) return null;
		let name = substr(line, 0, at), value = substr(line, at + 1);
		if (exists(result, name)) return null;
		result[name] = value;
	}
	return result;
};

function parse_identity(values, participant) {
	let allowed = participant
		? { version: true, owner: true, boot: true, pid: true, start: true, nonce: true }
		: { version: true, boot: true, pid: true, start: true, nonce: true };
	if (!exact_fields(values, allowed) || values.version != '1' ||
	    !match(values.boot, /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/) ||
	    !match(values.pid, /^[1-9][0-9]*$/) || !match(values.start, /^[1-9][0-9]*$/) ||
	    !match(values.nonce, /^[0-9a-f]{32}$/)) return null;
	let result = { boot: values.boot, pid: int(values.pid), start: int(values.start), nonce: values.nonce };
	if (participant) result.owner = values.owner;
	return result;
};

function read_record(runtime, path, participant) {
	let info = runtime.fs.lstat(path);
	if (info?.type != 'file' || info.uid != 0 || info.nlink != 1 ||
	    (info.mode & 0o177) != 0 || info.size < 1 || info.size > MAX_RECORD)
		return null;
	return parse_identity(parse_lines(runtime.fs.readfile(path)), participant);
};

function write_record(runtime, path, data) {
	let handle = runtime.fs.open(path, 'wx', 0o600);
	if (handle == null) fail('INTERNAL');
	let offset = 0, closed = false;
	try {
		while (offset < length(data)) {
			let written = runtime.fs.write(handle, substr(data, offset));
			if (type(written) != 'int' || written < 1) fail('INTERNAL');
			offset += written;
		}
		if (runtime.fs.flush(handle) != true || runtime.fs.close(handle) != true)
			fail('INTERNAL');
		closed = true;
	}
	catch (error) {
		if (!closed) try { runtime.fs.close(handle); } catch (close_error) {}
		try { runtime.fs.unlink(path); } catch (unlink_error) {}
		fail(error?.code ?? error?.message ?? 'INTERNAL');
	}
	if (runtime.fs.chmod(path, 0o600) != true) fail('INTERNAL');
	let info = runtime.fs.lstat(path);
	if (info?.type != 'file' || info.uid != 0 || info.nlink != 1 ||
	    info.mode != 0o600 || info.size != length(data)) fail('INTERNAL');
};

function secure_root(runtime) {
	let info = runtime?.fs?.lstat(ROOT);
	if (info == null) {
		if (runtime?.fs?.mkdir(ROOT) != true || runtime.fs.chmod(ROOT, 0o700) != true)
			fail('INTERNAL');
		info = runtime.fs.lstat(ROOT);
	}
	let canonical = runtime?.fs?.realpath(ROOT);
	if (info?.type != 'directory' || info.uid != 0 || (info.mode & 0o077) != 0 ||
	    !has([ ROOT, '/run/miclash', '/tmp/run/miclash' ], canonical)) fail('INTERNAL');
	return canonical;
};

function barrier_active(runtime) {
	return runtime.fs.lstat(BARRIER) != null;
};

function barrier_allowed(runtime, mode) {
	let active = barrier_active(runtime);
	if (mode == 'normal') return !active;
	if (mode == 'package') return active;
	return false;
};

function owner_at(runtime, directory) {
	let identity = read_record(runtime, directory + '/' + OWNER, false);
	if (identity == null) return null;
	identity.token = token(identity);
	return identity;
};

function participant_names(runtime, directory) {
	let path = directory + '/' + PARTICIPANTS;
	let info = runtime.fs.lstat(path);
	if (info?.type != 'directory' || info.uid != 0 || (info.mode & 0o077) != 0)
		return null;
	return runtime.fs.lsdir(path) ?? [];
};

function live_participant(runtime, directory, owner_token) {
	let names = participant_names(runtime, directory);
	if (names == null) return true;
	for (let name in names) {
		if (!match(name, /^[1-9][0-9]*\.[1-9][0-9]*\.[0-9a-f]{32}$/)) return true;
		let item = read_record(runtime, directory + '/' + PARTICIPANTS + '/' + name, true);
		if (item == null || item.owner != owner_token) return true;
		if (identity_live(runtime, item)) return true;
	}
	return false;
};

function directory_age(runtime, path) {
	let modified = runtime.fs.stat(path)?.mtime;
	if (type(modified) != 'int' && type(modified) != 'double') return null;
	let milliseconds = modified > 100000000000 ? modified : modified * 1000;
	return runtime.clock.now() - milliseconds;
};

function directory_stale(runtime, path) {
	let owner = owner_at(runtime, path);
	if (owner == null) {
		let age = directory_age(runtime, path);
		return age != null && age >= INIT_GRACE_MS;
	}
	if (identity_live(runtime, owner)) return false;
	return !live_participant(runtime, path, owner.token);
};

function remove_stale_directory(runtime, path) {
	let owner = owner_at(runtime, path), names = participant_names(runtime, path);
	if (names == null) busy();
	for (let name in names) {
		let item = read_record(runtime, path + '/' + PARTICIPANTS + '/' + name, true);
		if (item == null || (owner != null && item.owner != owner.token) || identity_live(runtime, item)) busy();
		if (runtime.fs.unlink(path + '/' + PARTICIPANTS + '/' + name) != true) fail('INTERNAL');
	}
	if (runtime.fs.rmdir(path + '/' + PARTICIPANTS) != true) fail('INTERNAL');
	if (runtime.fs.lstat(path + '/' + OWNER) != null && runtime.fs.unlink(path + '/' + OWNER) != true)
		fail('INTERNAL');
	if (runtime.fs.rmdir(path) != true) fail('INTERNAL');
};

function settle_takeover(runtime) {
	if (runtime.fs.lstat(TAKEOVER) == null) return true;
	if (!directory_stale(runtime, TAKEOVER)) {
		if (runtime.fs.lstat(LOCK) == null) runtime.fs.rename(TAKEOVER, LOCK);
		busy();
	}
	remove_stale_directory(runtime, TAKEOVER);
	return true;
};

function takeover(runtime) {
	if (!directory_stale(runtime, LOCK)) busy();
	if (runtime.fs.lstat(TAKEOVER) != null) { settle_takeover(runtime); return false; }
	if (runtime.fs.rename(LOCK, TAKEOVER) != true) return false;
	// Revalidate the directory after the atomic rename before discarding it.
	if (!directory_stale(runtime, TAKEOVER)) {
		if (runtime.fs.lstat(LOCK) == null && runtime.fs.rename(TAKEOVER, LOCK) == true) busy();
		busy();
	}
	remove_stale_directory(runtime, TAKEOVER);
	return true;
};

function create_owner(runtime) {
	if (runtime.fs.mkdir(LOCK) != true) return null;
	// A stale-owner recovery may have published the takeover sentinel after
	// our first check. Do not publish a second owner in that vacancy.
	if (runtime.fs.lstat(TAKEOVER) != null) {
		if (runtime.fs.rmdir(LOCK) != true) fail('INTERNAL');
		return null;
	}
	if (runtime.fs.chmod(LOCK, 0o700) != true ||
	    runtime.fs.mkdir(LOCK + '/' + PARTICIPANTS) != true ||
	    runtime.fs.chmod(LOCK + '/' + PARTICIPANTS, 0o700) != true)
		fail('INTERNAL');
	let base = self_identity(runtime);
	let nonce = runtime.random.hex(16);
	if (!match(nonce, /^[0-9a-f]{32}$/)) fail('INTERNAL');
	let identity = { ...base, nonce };
	write_record(runtime, LOCK + '/' + OWNER, encode_owner(identity));
	let published = owner_at(runtime, LOCK);
	if (published == null || published.token != token(identity)) fail('INTERNAL');
	return { kind: 'owner', token: published.token, identity };
};

function join_owner(runtime, inherited) {
	let owner = owner_at(runtime, LOCK);
	if (owner == null || owner.token != inherited || !identity_live(runtime, owner)) busy();
	let base = self_identity(runtime), nonce = runtime.random.hex(16);
	if (!match(nonce, /^[0-9a-f]{32}$/)) fail('INTERNAL');
	let identity = { ...base, nonce };
	let name = identity.pid + '.' + identity.start + '.' + identity.nonce;
	let path = LOCK + '/' + PARTICIPANTS + '/' + name;
	write_record(runtime, path, encode_participant(owner.token, identity));
	let published = read_record(runtime, path, true);
	if (published == null || published.owner != owner.token || !identity_live(runtime, published))
		fail('INTERNAL');
	return { kind: 'participant', token: owner.token, identity, path };
};

export function assert_held(runtime, lease) {
	if (lease?.kind == 'owner') {
		let owner = owner_at(runtime, LOCK);
		if (owner == null || owner.token != lease.token || !identity_live(runtime, owner)) busy();
		return true;
	}
	if (lease?.kind == 'participant') {
		let item = read_record(runtime, lease.path, true);
		if (item == null || item.owner != lease.token || token(item) != token(lease.identity) ||
		    !identity_live(runtime, item)) busy();
		return true;
	}
	busy();
};

export function acquire(runtime, options) {
	secure_root(runtime);
	let mode = options?.barrier ?? 'normal';
	let wait_ms = options?.wait_ms ?? 0;
	if (!has([ 'normal', 'package' ], mode) || type(wait_ms) != 'int' || wait_ms < 0 ||
	    type(runtime?.clock?.now) != 'function' || type(runtime?.clock?.sleep) != 'function' ||
	    type(runtime?.random?.hex) != 'function') fail('INVALID_ARGUMENT');
	if (!barrier_allowed(runtime, mode)) busy();
	let deadline = runtime.clock.now() + wait_ms;
	while (true) {
		let lease = null;
		try {
			settle_takeover(runtime);
			if (runtime.mutation_lock_token != null)
				lease = join_owner(runtime, runtime.mutation_lock_token);
			else {
				lease = create_owner(runtime);
				if (lease == null && runtime.fs.lstat(TAKEOVER) != null) {
					settle_takeover(runtime);
					lease = create_owner(runtime);
				}
				else if (lease == null && takeover(runtime)) lease = create_owner(runtime);
			}
		}
		catch (error) {
			let code = error?.code ?? error?.message ?? 'INTERNAL';
			if (code != 'BUSY') fail(code);
		}
		if (lease != null) {
			if (!barrier_allowed(runtime, mode)) {
				try { release(runtime, lease); } catch (error) {}
				busy();
			}
			return lease;
		}
		if (runtime.clock.now() >= deadline) busy();
		runtime.clock.sleep(min(50, deadline - runtime.clock.now()));
	}
};

export function release(runtime, lease) {
	assert_held(runtime, lease);
	if (lease.kind == 'participant') {
		if (runtime.fs.unlink(lease.path) != true) fail('INTERNAL');
		return true;
	}
	let names = participant_names(runtime, LOCK);
	if (names == null || length(names)) busy();
	if (runtime.fs.rmdir(LOCK + '/' + PARTICIPANTS) != true ||
	    runtime.fs.unlink(LOCK + '/' + OWNER) != true || runtime.fs.rmdir(LOCK) != true)
		fail('INTERNAL');
	return true;
};

export function with_lock(runtime, options, callback) {
	if (type(callback) != 'function') fail('INVALID_ARGUMENT');
	if (runtime.mutation_lock_lease != null) {
		assert_held(runtime, runtime.mutation_lock_lease);
		return callback();
	}
	let lease = acquire(runtime, options), result, thrown = null;
	runtime.mutation_lock_lease = lease;
	try { result = callback(); } catch (error) { thrown = error; }
	delete runtime.mutation_lock_lease;
	try { release(runtime, lease); }
	catch (error) { if (thrown == null) thrown = error; }
	if (thrown != null) fail(thrown?.code ?? thrown?.message ?? 'INTERNAL');
	return result;
};
