import * as errors from 'miclash.errors';
import * as redact from 'miclash.redact';
import * as schema from 'miclash.schema';

/*
 * Deliberately unwired Task 7 domain.
 *
 * app.secure_fs is the sole filesystem authority.  It must implement
 * dirfd-relative, no-follow, handle/inode-bound operations.  Each mutating
 * primitive authenticates the supplied expected identity in the same
 * operation; there is intentionally no runtime.fs pathname fallback.
 *
 *   open(path, { create, mode, uid }) -> opaque directory handle
 *   open_at(dir, name, { create, mode, uid, expected? }) -> opaque directory handle
 *       (handles and identities carry a persistent capability-owned,
 *        unforgeable 256-bit directory generation; inode metadata is only
 *        supplemental and never establishes directory ownership)
 *   stat(dir, name) -> identity|null
 *   list(dir) -> [ immediate-name ]
 *   read(dir, name, { maximum, mode, uid, nlink, expected? })
 *       -> { content, identity }
 *   create_exclusive(dir, name, bytes, { mode, uid }) -> identity
 *       (nofollow hidden temp, complete write, file fsync, atomic no-replace
 *        publication, parent fsync; on every failure the destination is
 *        absent or complete and no hidden temp remains)
 *   replace_atomic(dir, name, expected|null, bytes, { mode, uid, nlink }) -> identity
 *       (CAS current identity/must-not-exist, distinct nofollow temp, temp
 *        fsync, atomic replace, parent fsync; on every failure the destination
 *        is the complete old or complete new file and no hidden temp remains)
 *   with_transaction_lease(callback) -> callback(opaque_lease) result
 *   rename_noreplace(dir, from, to, expected, { mode, uid, nlink }) -> identity
 *       (identity-bound source, absent destination, atomic rename, parent fsync)
 *   unlink_durable(dir, name, expected) -> true
 *       (identity-bound unlink and parent fsync)
 *   rmdir_durable(dir, name, expected) -> true
 *       (identity-bound empty-directory removal and parent fsync)
 *
 * The module writes and parses strict USTAR itself.  No normalized archive
 * listing or extraction adapter is authoritative.
 */

const BACKUP_ROOT = '/etc/miclash/backups';
const IMPORT_ROOT = '/tmp/miclash/imports';
const INSPECT_ROOT = '/tmp/miclash/backup-inspected';
const TRANSACTION_ROOT = '/tmp/miclash/backup-transactions';
const INSPECTION_TTL = 900000;
const MAX_TRANSACTIONS = 64;
const MAX_ARCHIVE = 16777216;
const MAX_MEMBER = 4194304;
const MAX_MANIFEST = 65536;
const MAX_REPORT = 262144;
const MAX_FILES = 1024;

const PROFILES = [ 'config.yaml', 'config2.yaml', 'config3.yaml' ];
const NUL = sprintf('%c', 0);

function invalid() { errors.fail('INVALID_ARGUMENT'); };
function internal() { errors.fail('INTERNAL'); };

function clone(value) {
	try { return json(sprintf('%J', value)); }
	catch (error) { internal(); }
};

function exact_fields(value, allowed) {
	if (type(value) != 'object') return false;
	for (let name in value) if (!exists(allowed, name)) return false;
	for (let name in allowed) if (!exists(value, name)) return false;
	return true;
};

function valid_version(value) {
	return type(value) == 'string' && length(value) >= 1 && length(value) <= 64 &&
		match(value, /^[A-Za-z0-9][A-Za-z0-9._+-]*$/);
};

function valid_id(value, prefix) {
	return type(value) == 'string' &&
		match(value, prefix == 'b' ? /^b-[0-9]{13}-[0-9a-f]{32}$/ :
			(prefix == 'i' ? /^i-[0-9]{13}-[0-9a-f]{32}$/ :
			 /^x-[0-9]{13}-[0-9a-f]{32}$/));
};

function validate_options(options, allowed) {
	if (options == null) return {};
	if (type(options) != 'object') invalid();
	for (let name in options) if (!exists(allowed, name)) invalid();
	return options;
};

function same_file_identity(left, right) {
	return left?.type == 'file' && right?.type == 'file' && left?.inode == right?.inode &&
		left?.dev?.major == right?.dev?.major && left?.dev?.minor == right?.dev?.minor &&
		left?.uid == right?.uid && left?.mode == right?.mode &&
		left?.nlink == right?.nlink && left?.size == right?.size;
};

function same_directory_identity(left, right) {
	return left?.type == 'directory' && right?.type == 'directory' &&
		left?.inode == right?.inode &&
		left?.dev?.major == right?.dev?.major && left?.dev?.minor == right?.dev?.minor &&
		left?.uid == right?.uid && left?.mode == right?.mode &&
		left?.generation == right?.generation;
};

function valid_file_identity(identity, mode, size) {
	return type(identity) == 'object' && identity.type == 'file' &&
		type(identity.inode) == 'int' && type(identity.dev?.major) == 'int' &&
		type(identity.dev?.minor) == 'int' && identity.uid == 0 &&
		identity.mode == mode && identity.nlink == 1 &&
		(size == null || identity.size == size);
};

function valid_directory_identity(identity, mode) {
	return type(identity) == 'object' && identity.type == 'directory' &&
		type(identity.inode) == 'int' && type(identity.dev?.major) == 'int' &&
		type(identity.dev?.minor) == 'int' && identity.uid == 0 && identity.mode == mode &&
		type(identity.generation) == 'string' && match(identity.generation, /^[0-9a-f]{64}$/);
};

function validate_app(app) {
	let runtime = app?.runtime, secure = app?.secure_fs;
	if (type(app) != 'object' || type(runtime) != 'object') invalid();
	if (type(runtime?.digest?.sha256) != 'function' ||
	    type(runtime?.clock?.now) != 'function' ||
	    type(runtime?.random?.hex) != 'function' ||
	    runtime.paths?.etc != '/etc/miclash' || runtime.paths?.tmp != '/tmp/miclash' ||
	    !valid_version(app?.app_version)) invalid();
	if (type(secure) != 'object') internal();
	for (let method in [ 'open', 'open_at', 'stat', 'list', 'read',
		'create_exclusive', 'replace_atomic', 'with_transaction_lease',
		'rename_noreplace', 'unlink_durable', 'rmdir_durable' ])
		if (type(secure[method]) != 'function') internal();
	return { runtime, secure };
};

function open_dir(secure, path) {
	let handle = secure.open(path, { create: true, mode: 0o700, uid: 0 });
	if (type(handle) != 'object' || !valid_directory_identity(handle.identity, 0o700))
		internal();
	return handle;
};

function open_child_dir(secure, parent, name, create, expected) {
	let handle = secure.open_at(parent, name,
		{ create: create === true, mode: 0o700, uid: 0, expected });
	if (type(handle) != 'object' || !valid_directory_identity(handle.identity, 0o700) ||
	    (expected != null && !same_directory_identity(handle.identity, expected))) internal();
	return handle;
};

function secure_read(env, directory, name, maximum, mode, expected) {
	let captured = env.secure.read(directory, name,
		{ maximum, mode, uid: 0, nlink: 1, expected });
	if (type(captured?.content) != 'string' ||
	    !valid_file_identity(captured?.identity, mode, length(captured.content)) ||
	    length(captured.content) > maximum ||
	    (expected != null && !same_file_identity(captured.identity, expected))) internal();
	let digest = env.runtime.digest.sha256(captured.content);
	if (type(digest) != 'string' || !match(digest, /^[0-9a-f]{64}$/)) internal();
	return {
		content: captured.content, size: length(captured.content), sha256: digest,
		identity: captured.identity
	};
};

function secure_create(env, directory, name, content, mode) {
	if (type(content) != 'string') internal();
	let identity = env.secure.create_exclusive(directory, name, content, { mode, uid: 0 });
	if (!valid_file_identity(identity, mode, length(content))) internal();
	return secure_read(env, directory, name, length(content), mode, identity);
};

function secure_replace(env, directory, name, expected, content, mode) {
	if (type(content) != 'string') internal();
	let identity = env.secure.replace_atomic(directory, name, expected, content,
		{ mode, uid: 0, nlink: 1 });
	if (!valid_file_identity(identity, mode, length(content))) internal();
	return secure_read(env, directory, name, length(content), mode, identity);
};

function safe_names(secure, directory, limit) {
	let names = secure.list(directory);
	if (type(names) != 'array' || length(names) > limit) internal();
	let seen = {};
	for (let name in names) {
		if (type(name) != 'string' || !length(name) || name == '.' || name == '..' ||
		    index(name, '/') >= 0 || index(name, '\\') >= 0 || index(name, NUL) >= 0 ||
		    seen[name]) internal();
		seen[name] = true;
	}
	return names;
};

function canonical_member_name(name) {
	if (type(name) != 'string' || length(name) < 1 || length(name) > 99 ||
	    !match(name, /^[A-Za-z0-9._\/-]+$/) || substr(name, 0, 1) == '/' ||
	    substr(name, -1) == '/' || index(name, '//') >= 0 || index(name, '\\') >= 0 ||
	    match(name, /^[A-Za-z]:/)) return false;
	for (let part in split(name, '/'))
		if (!length(part) || part == '.' || part == '..') return false;
	return true;
};

function safe_ruleset_name(name) {
	try { schema.archive_name(name); }
	catch (error) { return false; }
	if (length(name) < 5 || !match(name, /^[a-z0-9][a-z0-9_-]*\.txt$/)) return false;
	// Strict no-prefix USTAR allows 99 bytes; "rulesets/" consumes nine.
	if (length(name) > 90) invalid();
	return true;
};

function sorted(values) {
	let output = [ ...values ];
	sort(output, (left, right) => left == right ? 0 : (left < right ? -1 : 1));
	return output;
};

function settings_walk(value, omit_secrets, budget, depth) {
	if (depth > 16 || --budget.remaining < 0) errors.fail('RESPONSE_TOO_LARGE');
	if (type(value) == 'array') {
		let output = [];
		for (let item in value) push(output,
			settings_walk(item, omit_secrets, budget, depth + 1));
		return output;
	}
	if (type(value) == 'object') {
		let output = {};
		for (let name, item in value) {
			if (omit_secrets && redact.secret_name(name)) continue;
			output[name] = settings_walk(item, omit_secrets, budget, depth + 1);
		}
		return output;
	}
	if (value == null || type(value) == 'string' || type(value) == 'bool' ||
	    type(value) == 'int' || type(value) == 'double') return value;
	errors.fail('VALIDATION_FAILED');
};

function sanitized_settings(value) {
	if (type(value) != 'object') errors.fail('VALIDATION_FAILED');
	return settings_walk(value, true, { remaining: 4096 }, 0);
};

function settings_has_secret(value, budget, depth) {
	if (depth > 16 || --budget.remaining < 0) errors.fail('RESPONSE_TOO_LARGE');
	if (type(value) == 'array') {
		for (let item in value)
			if (settings_has_secret(item, budget, depth + 1)) return true;
		return false;
	}
	if (type(value) == 'object') {
		for (let name, item in value) {
			if (redact.secret_name(name)) return true;
			if (settings_has_secret(item, budget, depth + 1)) return true;
		}
		return false;
	}
	if (value == null || type(value) == 'string' || type(value) == 'bool' ||
	    type(value) == 'int' || type(value) == 'double') return false;
	errors.fail('VALIDATION_FAILED');
};

function settings_document(content, secret) {
	let value;
	try { value = json(content); }
	catch (error) { errors.fail('VALIDATION_FAILED'); }
	if (type(value) != 'object' || content != sprintf('%J\n', value))
		errors.fail('VALIDATION_FAILED');
	if (secret === false && settings_has_secret(value, { remaining: 4096 }, 0))
		errors.fail('VALIDATION_FAILED');
	// Traverse explicit-secret documents too so depth, size, and value kinds are closed.
	if (secret === true) settings_walk(value, false, { remaining: 4096 }, 0);
	return value;
};

function zeroes(count) {
	let output = '';
	for (let i = 0; i < count; i++) output += NUL;
	return output;
};

function tar_field(text, width) {
	if (length(text) > width) internal();
	return text + zeroes(width - length(text));
};

function tar_header(name, size) {
	if (!canonical_member_name(name) || type(size) != 'int' || size < 0 || size > MAX_MEMBER)
		internal();
	let header = tar_field(name, 100) + sprintf('%07o', 0o600) + NUL +
		sprintf('%07o', 0) + NUL + sprintf('%07o', 0) + NUL +
		sprintf('%011o', size) + NUL + sprintf('%011o', 0) + NUL +
		'        ' + '0' + zeroes(100) + 'ustar' + NUL + '00' +
		zeroes(32) + zeroes(32) + sprintf('%07o', 0) + NUL +
		sprintf('%07o', 0) + NUL + zeroes(155) + zeroes(12);
	if (length(header) != 512) internal();
	let checksum = 0;
	for (let i = 0; i < 512; i++) checksum += ord(header, i);
	header = substr(header, 0, 148) + sprintf('%06o', checksum) + NUL + ' ' +
		substr(header, 156);
	return header;
};

function ustar_write(members) {
	let output = '', total = 0, seen = {};
	if (type(members) != 'array' || length(members) < 2 || length(members) > MAX_FILES + 1)
		internal();
	for (let member in members) {
		if (!exact_fields(member, { name: true, content: true }) ||
		    !canonical_member_name(member.name) || seen[member.name] ||
		    type(member.content) != 'string' || length(member.content) > MAX_MEMBER)
			internal();
		seen[member.name] = true;
		total += length(member.content);
		if (total > MAX_ARCHIVE) errors.fail('RESPONSE_TOO_LARGE');
		output += tar_header(member.name, length(member.content)) + member.content;
		let padding = (512 - (length(member.content) % 512)) % 512;
		output += zeroes(padding);
		if (length(output) + 1024 > MAX_ARCHIVE) errors.fail('RESPONSE_TOO_LARGE');
	}
	return output + zeroes(1024);
};

function all_zero(value) {
	for (let i = 0; i < length(value); i++) if (ord(value, i) != 0) return false;
	return true;
};

function nul_field(block, offset, width) {
	let field = substr(block, offset, width), end = index(field, NUL);
	if (end < 0) return null;
	for (let i = end; i < width; i++) if (ord(field, i) != 0) return null;
	return substr(field, 0, end);
};

function octal_field(block, offset, width) {
	let value = 0, digit = false, ended = false;
	for (let i = 0; i < width; i++) {
		let byte = ord(block, offset + i);
		if (!ended && byte >= 48 && byte <= 55) {
			digit = true;
			if (value > 0x1fffffff) return null;
			value = value * 8 + byte - 48;
		}
		else if (byte == 0 || byte == 32) ended = true;
		else return null;
	}
	return digit ? value : null;
};

function ustar_parse(bytes) {
	if (type(bytes) != 'string' || length(bytes) < 2048 ||
	    length(bytes) > MAX_ARCHIVE || length(bytes) % 512 != 0)
		errors.fail('VALIDATION_FAILED');
	let offset = 0, total = 0, seen = {}, members = [], by_name = {};
	while (offset + 512 <= length(bytes)) {
		let block = substr(bytes, offset, 512);
		if (all_zero(block)) {
			if (offset + 1024 != length(bytes) ||
			    !all_zero(substr(bytes, offset + 512, 512)))
				errors.fail('VALIDATION_FAILED');
			if (length(members) < 2) errors.fail('VALIDATION_FAILED');
			return { members, by_name };
		}
		if (length(members) >= MAX_FILES + 1 ||
		    substr(block, 257, 6) != 'ustar' + NUL || substr(block, 263, 2) != '00' ||
		    !all_zero(substr(block, 345, 155)) || !all_zero(substr(block, 157, 100)))
			errors.fail('VALIDATION_FAILED');
		let name = nul_field(block, 0, 100), mode = octal_field(block, 100, 8);
		let uid = octal_field(block, 108, 8), gid = octal_field(block, 116, 8);
		let size = octal_field(block, 124, 12), mtime = octal_field(block, 136, 12);
		let stored = octal_field(block, 148, 8), typeflag = ord(block, 156);
		let uname = nul_field(block, 265, 32), gname = nul_field(block, 297, 32);
		let dev_major = octal_field(block, 329, 8), dev_minor = octal_field(block, 337, 8);
		if (!canonical_member_name(name) || seen[name] || mode == null || uid == null ||
		    gid == null || size == null || mtime == null || stored == null ||
		    mode > 0o7777 || uname == null || gname == null ||
		    !match(uname, /^[A-Za-z0-9._-]*$/) || !match(gname, /^[A-Za-z0-9._-]*$/) ||
		    dev_major == null || dev_minor == null || !all_zero(substr(block, 500, 12)) ||
		    (typeflag != 0 && typeflag != 48) || size > MAX_MEMBER ||
		    (name == 'manifest.json' && size > MAX_MANIFEST))
			errors.fail(size != null && size > MAX_MEMBER ? 'RESPONSE_TOO_LARGE' : 'VALIDATION_FAILED');
		let checksum = 0;
		for (let i = 0; i < 512; i++)
			checksum += i >= 148 && i < 156 ? 32 : ord(block, i);
		if (checksum != stored) errors.fail('VALIDATION_FAILED');
		let data_offset = offset + 512, padded = size + ((512 - (size % 512)) % 512);
		if (data_offset + padded + 1024 > length(bytes)) errors.fail('VALIDATION_FAILED');
		let content = substr(bytes, data_offset, size);
		if (!all_zero(substr(bytes, data_offset + size, padded - size)))
			errors.fail('VALIDATION_FAILED');
		total += size;
		if (total > MAX_ARCHIVE) errors.fail('RESPONSE_TOO_LARGE');
		let member = { name, size, content };
		push(members, member); by_name[name] = member; seen[name] = true;
		offset = data_offset + padded;
	}
	errors.fail('VALIDATION_FAILED');
};

function valid_logical_path(path, secret) {
	if (!canonical_member_name(path) || path == 'manifest.json') return false;
	if (path == 'settings/settings.json') return true;
	if (substr(path, 0, 8) == 'configs/') {
		let profile = substr(path, 8), valid = false;
		for (let candidate in PROFILES) if (candidate == profile) valid = true;
		return valid && secret === true;
	}
	if (substr(path, 0, 9) == 'rulesets/')
		return safe_ruleset_name(substr(path, 9)) && secret === false;
	return false;
};

function validate_manifest(manifest, archive, digest) {
	let manifest_fields = {
		schema: true, created_at: true, app_version: true, includes: true, files: true
	};
	let file_fields = { path: true, size: true, sha256: true, secret: true };
	if (!exact_fields(manifest, manifest_fields) || manifest.schema != 1 ||
	    type(manifest.created_at) != 'int' || manifest.created_at < 0 ||
	    !valid_version(manifest.app_version) || type(manifest.includes) != 'array' ||
	    length(manifest.includes) < 1 || length(manifest.includes) > 3 ||
	    type(manifest.files) != 'array' || length(manifest.files) < 1 ||
	    length(manifest.files) > MAX_FILES)
		errors.fail('VALIDATION_FAILED');
	let includes = {}, previous_include = null;
	for (let include in manifest.includes) {
		if (!exists({ configs: true, rulesets: true, settings: true }, include) ||
		    includes[include] || (previous_include != null && include <= previous_include))
			errors.fail('VALIDATION_FAILED');
		includes[include] = true; previous_include = include;
	}
	let seen = {}, previous_path = null, derived = {}, settings_seen = false;
	for (let file in manifest.files) {
		let member = archive.by_name[file?.path];
		if (!exact_fields(file, file_fields) || type(file.secret) != 'bool' ||
		    !valid_logical_path(file.path, file.secret) || seen[file.path] ||
		    (previous_path != null && file.path <= previous_path) ||
		    type(file.size) != 'int' || file.size < 0 || file.size > MAX_MEMBER ||
		    type(file.sha256) != 'string' || !match(file.sha256, /^[0-9a-f]{64}$/) ||
		    member == null || member.size != file.size)
			errors.fail('VALIDATION_FAILED');
		if (digest(member.content) != file.sha256) errors.fail('VALIDATION_FAILED');
		seen[file.path] = true; previous_path = file.path;
		if (file.path == 'settings/settings.json') settings_seen = true;
		derived[split(file.path, '/')[0]] = true;
	}
	for (let member in archive.members)
		if (member.name != 'manifest.json' && !seen[member.name])
			errors.fail('VALIDATION_FAILED');
	if (!settings_seen || length(archive.members) != length(manifest.files) + 1 ||
	    sprintf('%J', sorted(keys(derived))) != sprintf('%J', manifest.includes))
		errors.fail('VALIDATION_FAILED');
	return clone(manifest);
};

function sidecar_valid(value, id) {
	let fields = {
		schema: true, id: true, created_at: true, app_version: true, includes: true,
		file_count: true, size: true, sha256: true
	};
	if (!exact_fields(value, fields) || value.schema != 1 || value.id != id ||
	    (!valid_id(value.id, 'b') && !valid_id(value.id, 'i')) ||
	    type(value.created_at) != 'int' || value.created_at < 0 ||
	    !valid_version(value.app_version) || type(value.includes) != 'array' ||
	    length(value.includes) < 1 || length(value.includes) > 3 ||
	    type(value.file_count) != 'int' || value.file_count < 1 || value.file_count > MAX_FILES ||
	    type(value.size) != 'int' || value.size < 1 || value.size > MAX_ARCHIVE ||
	    !match(value.sha256, /^[0-9a-f]{64}$/)) return false;
	let seen = {};
	for (let include in value.includes) {
		if (!exists({ configs: true, rulesets: true, settings: true }, include) || seen[include])
			return false;
		seen[include] = true;
	}
	return sprintf('%J', value.includes) == sprintf('%J', sorted(value.includes));
};

function source_record(app, source_id, env) {
	if (type(env?.lease) != 'object') internal();
	let path;
	if (valid_id(source_id, 'b')) path = BACKUP_ROOT;
	else if (valid_id(source_id, 'i')) path = IMPORT_ROOT;
	else invalid();
	let root = open_dir(env.secure, path);
	if (env.secure.stat(root, source_id + '.json') == null ||
	    env.secure.stat(root, source_id + '.tar') == null) errors.fail('NOT_FOUND');
	let sidecar_capture, archive, sidecar;
	try {
		sidecar_capture = secure_read(env, root, source_id + '.json', MAX_MANIFEST, 0o600);
		sidecar = json(sidecar_capture.content);
		archive = secure_read(env, root, source_id + '.tar', MAX_ARCHIVE, 0o600);
	}
	catch (error) { errors.fail('CORRUPT_STATE'); }
	if (sidecar_capture.content != sprintf('%J\n', sidecar) ||
	    !sidecar_valid(sidecar, source_id) || archive.size != sidecar.size ||
	    archive.sha256 != sidecar.sha256) errors.fail('CORRUPT_STATE');
	return { env, root, sidecar, sidecar_capture, archive };
};

function remove_tree(env, parent, name, expected, registered, registered_directories, relative) {
	if (type(registered) != 'array' || type(registered_directories) != 'array') internal();
	let directory;
	try { directory = open_child_dir(env.secure, parent, name, false, expected); }
	catch (error) { return false; }
	let names;
	try { names = safe_names(env.secure, directory, MAX_FILES * 3 + 16); }
	catch (error) { return false; }
	let failed = false;
	for (let child_name in names) {
		let identity = env.secure.stat(directory, child_name);
		let child_path = length(relative ?? '') ? relative + '/' + child_name : child_name;
		if (identity?.type == 'directory') {
			let registration = null;
			for (let item in registered_directories)
				if (item.path == child_path) registration = item;
			let expected_directory = null;
			if (registration?.identity != null) {
				let value = registration.identity;
				expected_directory = {
					type: value.type, inode: value.inode,
					dev: { major: value.dev_major, minor: value.dev_minor },
					uid: value.uid, mode: value.mode, generation: value.generation
				};
			}
			if (expected_directory == null ||
			    !same_directory_identity(expected_directory, identity) ||
			    !remove_tree(env, directory, child_name, expected_directory,
				    registered, registered_directories, child_path)) failed = true;
		}
		else if (identity?.type == 'file') {
			let registration = null;
			for (let file in registered) if (file.path == child_path) registration = file;
			let registered_identity = null;
			if (registration != null && registration.identity != null) {
				let value = registration.identity;
				registered_identity = {
					type: value.type, inode: value.inode,
					dev: { major: value.dev_major, minor: value.dev_minor },
					uid: value.uid, mode: value.mode, nlink: value.nlink, size: value.size
				};
			}
			if (registration == null || identity.mode != registration.mode || identity.uid != 0 ||
			    identity.nlink != 1 || identity.size != registration.size ||
			    (registered_identity != null && !same_file_identity(registered_identity, identity))) {
				failed = true; continue;
			}
			try {
				let captured = secure_read(env, directory, child_name, registration.size,
					registration.mode, identity);
				if (captured.size != registration.size || captured.sha256 != registration.sha256 ||
			    env.secure.unlink_durable(directory, child_name, captured.identity) !== true)
					failed = true;
			}
			catch (error) { failed = true; }
		}
		else failed = true;
	}
	if (failed) return false;
	try { return env.secure.rmdir_durable(parent, name, expected) === true; }
	catch (error) { return false; }
};

function file_identity_record(identity) {
	if (identity == null) return null;
	return {
		type: identity.type, inode: identity.inode,
		dev_major: identity.dev?.major, dev_minor: identity.dev?.minor,
		uid: identity.uid, mode: identity.mode, nlink: identity.nlink, size: identity.size
	};
};

function directory_identity_record(identity) {
	if (identity == null) return null;
	return {
		type: identity.type, inode: identity.inode,
		dev_major: identity.dev?.major, dev_minor: identity.dev?.minor,
		uid: identity.uid, mode: identity.mode, generation: identity.generation
	};
};

function record_file_identity(record) {
	if (record == null) return null;
	return {
		type: record.type, inode: record.inode,
		dev: { major: record.dev_major, minor: record.dev_minor },
		uid: record.uid, mode: record.mode, nlink: record.nlink, size: record.size
	};
};

function record_directory_identity(record) {
	if (record == null) return null;
	return {
		type: record.type, inode: record.inode,
		dev: { major: record.dev_major, minor: record.dev_minor },
		uid: record.uid, mode: record.mode, generation: record.generation
	};
};

function valid_file_identity_record(record) {
	return record == null || (exact_fields(record, {
		type: true, inode: true, dev_major: true, dev_minor: true,
		uid: true, mode: true, nlink: true, size: true
	}) && record.type == 'file' && type(record.inode) == 'int' &&
		type(record.dev_major) == 'int' && type(record.dev_minor) == 'int' &&
		record.uid == 0 && record.nlink == 1 && type(record.mode) == 'int' &&
		type(record.size) == 'int' && record.size >= 0);
};

function valid_directory_identity_record(record) {
	return record == null || (exact_fields(record, {
		type: true, inode: true, dev_major: true, dev_minor: true,
		uid: true, mode: true, generation: true
	}) && record.type == 'directory' && type(record.inode) == 'int' &&
		type(record.dev_major) == 'int' && type(record.dev_minor) == 'int' &&
		record.uid == 0 && type(record.mode) == 'int' &&
		type(record.generation) == 'string' && match(record.generation, /^[0-9a-f]{64}$/));
};

const JOURNAL_FIELDS = {
	schema: true, id: true, kind: true, created_at: true, phase: true,
	backup_id: true, temp_name: true, archive_name: true, sidecar_name: true,
	archive_size: true, archive_sha256: true, sidecar_size: true, sidecar_sha256: true,
	temp_identity: true, archive_identity: true, sidecar_identity: true,
	inspection_id: true, expires_at: true, stage_identity: true, directories: true,
	files: true, cursor: true,
	prune_id: true, archive_tomb: true, sidecar_tomb: true
};

function journal_base(id, kind, created_at) {
	return {
		schema: 1, id, kind, created_at, phase: 'planned',
		backup_id: null, temp_name: null, archive_name: null, sidecar_name: null,
		archive_size: null, archive_sha256: null, sidecar_size: null, sidecar_sha256: null,
		temp_identity: null, archive_identity: null, sidecar_identity: null,
		inspection_id: null, expires_at: null, stage_identity: null, directories: null,
		files: null, cursor: 0,
		prune_id: null, archive_tomb: null, sidecar_tomb: null
	};
};

function valid_journal_file(file) {
	let maximum = file?.path == '.inspection.json' ? MAX_REPORT :
		(file?.path == 'manifest.json' ? MAX_MANIFEST : MAX_MEMBER);
	return exact_fields(file, { path: true, size: true, sha256: true, mode: true,
		identity: true }) && canonical_member_name(file.path) &&
		type(file.size) == 'int' && file.size >= 0 && file.size <= maximum &&
		match(file.sha256, /^[0-9a-f]{64}$/) &&
		(file.mode == 0o400 || file.mode == 0o600) &&
		valid_file_identity_record(file.identity);
};

function valid_journal_directory(directory) {
	return exact_fields(directory, { path: true, identity: true }) &&
		canonical_member_name(directory.path) && directory.identity != null &&
		valid_directory_identity_record(directory.identity);
};

function valid_journal(record, name) {
	if (!exact_fields(record, JOURNAL_FIELDS) || record.schema != 1 ||
	    name != record.id + '.json' ||
	    !match(record.id, /^t-[0-9]{13}-[0-9a-f]{32}$/) ||
	    type(record.created_at) != 'int' || record.created_at < 0 ||
	    type(record.phase) != 'string' || type(record.cursor) != 'int' || record.cursor < 0)
		return false;
	if (!valid_file_identity_record(record.temp_identity) ||
	    !valid_file_identity_record(record.archive_identity) ||
	    !valid_file_identity_record(record.sidecar_identity) ||
	    !valid_directory_identity_record(record.stage_identity)) return false;
	if (record.kind == 'create')
		return valid_id(record.backup_id, 'b') &&
			match(record.temp_name, /^\.b-[0-9]{13}-[0-9a-f]{32}\.tar\.tmp$/) &&
			record.archive_name == record.backup_id + '.tar' &&
			record.sidecar_name == record.backup_id + '.json' &&
			type(record.archive_size) == 'int' && record.archive_size > 0 &&
			record.archive_size <= MAX_ARCHIVE && match(record.archive_sha256, /^[0-9a-f]{64}$/) &&
			type(record.sidecar_size) == 'int' && record.sidecar_size > 0 &&
			record.sidecar_size <= MAX_MANIFEST && match(record.sidecar_sha256, /^[0-9a-f]{64}$/) &&
			exists({ planned: true, temp: true, side_planned: true, side: true,
				publish_planned: true, published: true, complete: true }, record.phase) &&
			record.inspection_id == null && record.expires_at == null &&
			record.stage_identity == null && record.directories == null &&
			record.files == null && record.cursor == 0 &&
			record.prune_id == null && record.archive_tomb == null && record.sidecar_tomb == null;
	if (record.kind == 'inspect') {
		if (!valid_id(record.inspection_id, 'x') || type(record.expires_at) != 'int' ||
		    record.expires_at - record.created_at != INSPECTION_TTL ||
		    type(record.files) != 'array' || length(record.files) < 2 ||
		    type(record.directories) != 'array' || length(record.directories) > MAX_FILES ||
		    length(record.files) > MAX_FILES + 2 || record.backup_id != null ||
		    record.temp_name != null || record.archive_name != null || record.sidecar_name != null ||
		    record.archive_size != null || record.archive_sha256 != null ||
		    record.sidecar_size != null || record.sidecar_sha256 != null ||
		    record.temp_identity != null || record.archive_identity != null ||
		    record.sidecar_identity != null || record.prune_id != null ||
		    record.archive_tomb != null || record.sidecar_tomb != null ||
		    !exists({ planned: true, staging: true,
			    report_planned: true, ready: true, preview: true }, record.phase)) return false;
		let seen = {};
		for (let file in record.files) {
			if (!valid_journal_file(file) || seen[file.path]) return false;
			seen[file.path] = true;
		}
		let seen_directories = {};
		for (let directory in record.directories) {
			if (!valid_journal_directory(directory) || seen_directories[directory.path])
				return false;
			seen_directories[directory.path] = true;
		}
		return record.cursor <= length(record.files);
	}
	if (record.kind == 'prune')
		return valid_id(record.prune_id, 'b') && record.archive_name == record.prune_id + '.tar' &&
			record.sidecar_name == record.prune_id + '.json' &&
			record.archive_tomb == '.prune-' + record.prune_id + '.tar' &&
			record.sidecar_tomb == '.prune-' + record.prune_id + '.json' &&
			type(record.archive_size) == 'int' && record.archive_size > 0 &&
			match(record.archive_sha256, /^[0-9a-f]{64}$/) &&
			type(record.sidecar_size) == 'int' && record.sidecar_size > 0 &&
			match(record.sidecar_sha256, /^[0-9a-f]{64}$/) &&
			record.archive_identity != null && record.sidecar_identity != null &&
			valid_file_identity_record(record.archive_identity) &&
			valid_file_identity_record(record.sidecar_identity) &&
			exists({ planned: true, side_moved: true, archive_moved: true,
				deleting: true }, record.phase) && record.inspection_id == null &&
			record.expires_at == null && record.stage_identity == null &&
			record.directories == null && record.files == null && record.cursor == 0 &&
			record.backup_id == null &&
			record.temp_name == null && record.temp_identity == null;
	return false;
};

function journal_text(record) {
	let content = sprintf('%J\n', record);
	if (length(content) > MAX_REPORT) errors.fail('RESPONSE_TOO_LARGE');
	return content;
};

function journal_store(env, transaction) {
	let written = secure_replace(env, transaction.root, transaction.name, transaction.identity,
		journal_text(transaction.record), 0o600);
	transaction.identity = written.identity;
	return true;
};

function journal_finish(env, transaction) {
	if (env.secure.unlink_durable(transaction.root, transaction.name, transaction.identity) !== true)
		internal();
	return true;
};

function registered_file(env, directory, name, size, digest, recorded) {
	let current = env.secure.stat(directory, name);
	if (current == null) return null;
	if (current.type != 'file' || current.uid != 0 || current.nlink != 1 ||
	    current.size != size || (recorded != null &&
	    !same_file_identity(record_file_identity(recorded), current))) internal();
	let captured = secure_read(env, directory, name, size, current.mode, current);
	if (captured.size != size || captured.sha256 != digest) internal();
	return captured;
};

function recover_create(env, transaction) {
	let record = transaction.record, root = open_dir(env.secure, BACKUP_ROOT);
	let temp = registered_file(env, root, record.temp_name, record.archive_size,
		record.archive_sha256, record.temp_identity);
	let archive = registered_file(env, root, record.archive_name, record.archive_size,
		record.archive_sha256, record.archive_identity ?? record.temp_identity);
	let sidecar = registered_file(env, root, record.sidecar_name, record.sidecar_size,
		record.sidecar_sha256, record.sidecar_identity);
	if (temp != null && archive != null) internal();
	if (record.phase == 'complete') {
		if (temp != null || archive == null || sidecar == null ||
		    archive.identity.mode != 0o600 || sidecar.identity.mode != 0o600) internal();
		journal_finish(env, transaction); return true;
	}
	for (let item in [ [ record.temp_name, temp ], [ record.archive_name, archive ],
		[ record.sidecar_name, sidecar ] ])
		if (item[1] != null) env.secure.unlink_durable(root, item[0], item[1].identity);
	journal_finish(env, transaction);
	return true;
};

function expected_prefix(files, path) {
	for (let file in files)
		if (file.path == path || substr(file.path, 0, length(path) + 1) == path + '/')
			return true;
	return false;
};

function authenticate_stage(env, directory, relative, files, directories, seen, seen_directories) {
	for (let name in safe_names(env.secure, directory, MAX_FILES + 8)) {
		let path = length(relative) ? relative + '/' + name : name;
		let identity = env.secure.stat(directory, name);
		if (identity?.type == 'directory') {
			let registration = null;
			for (let item in directories) if (item.path == path) registration = item;
			if (!expected_prefix(files, path) || registration?.identity == null) internal();
			let expected = record_directory_identity(registration.identity);
			if (!same_directory_identity(expected, identity)) internal();
			let child = open_child_dir(env.secure, directory, name, false, expected);
			seen_directories[path] = true;
			authenticate_stage(env, child, path, files, directories, seen, seen_directories);
		}
		else if (identity?.type == 'file') {
			let expected = null;
			for (let file in files) if (file.path == path) expected = file;
			if (expected == null) internal();
			let captured = registered_file(env, directory, name, expected.size,
				expected.sha256, expected.identity);
			if (captured.identity.mode != expected.mode) internal();
			seen[path] = true;
		}
		else internal();
	}
};

function recover_inspect(env, transaction, now) {
	let record = transaction.record, root = open_dir(env.secure, INSPECT_ROOT);
	let stat = env.secure.stat(root, record.inspection_id);
	if (stat == null) { journal_finish(env, transaction); return true; }
	if (record.stage_identity == null) internal();
	let stage_expected = record_directory_identity(record.stage_identity);
	if (!same_directory_identity(stage_expected, stat)) internal();
	let stage = open_child_dir(env.secure, root, record.inspection_id, false, stage_expected);
	let seen = {}, seen_directories = {};
	authenticate_stage(env, stage, '', record.files, record.directories, seen, seen_directories);
	for (let file in record.files)
		if (file.identity != null && !seen[file.path]) internal();
	for (let directory in record.directories)
		if (!seen_directories[directory.path]) internal();
	if (record.phase == 'preview' && now <= record.expires_at) return true;
	if (!remove_tree(env, root, record.inspection_id, stage_expected,
	    record.files, record.directories, '')) internal();
	journal_finish(env, transaction);
	return true;
};

function prune_candidate(env, root, original, tomb, size, digest, recorded) {
	let left = registered_file(env, root, original, size, digest, recorded);
	let right = registered_file(env, root, tomb, size, digest, recorded);
	if (left != null && right != null) internal();
	return left != null ? { name: original, capture: left } :
		(right != null ? { name: tomb, capture: right } : null);
};

function recover_prune(env, transaction) {
	let record = transaction.record, root = open_dir(env.secure, BACKUP_ROOT);
	let archive = prune_candidate(env, root, record.archive_name, record.archive_tomb,
		record.archive_size, record.archive_sha256, record.archive_identity);
	let sidecar = prune_candidate(env, root, record.sidecar_name, record.sidecar_tomb,
		record.sidecar_size, record.sidecar_sha256, record.sidecar_identity);
	if (archive != null) env.secure.unlink_durable(root, archive.name, archive.capture.identity);
	if (sidecar != null) env.secure.unlink_durable(root, sidecar.name, sidecar.capture.identity);
	journal_finish(env, transaction);
	return true;
};

function recover_transactions_locked(env) {
	if (type(env?.lease) != 'object') internal();
	let root = open_dir(env.secure, TRANSACTION_ROOT);
	let names = sorted(safe_names(env.secure, root, MAX_TRANSACTIONS + 1));
	if (length(names) > MAX_TRANSACTIONS) internal();
	let now = env.runtime.clock.now(), transactions = [];
	if (type(now) != 'int' || now < 0) internal();
	// Validate every journal before mutating anything.
	for (let name in names) {
		if (!match(name, /^t-[0-9]{13}-[0-9a-f]{32}\.json$/)) internal();
		let captured = secure_read(env, root, name, MAX_REPORT, 0o600), record;
		try { record = json(captured.content); }
		catch (error) { internal(); }
		if (captured.content != sprintf('%J\n', record) || !valid_journal(record, name))
			internal();
		push(transactions, { root, name, record, identity: captured.identity });
	}
	for (let transaction in transactions) {
		if (transaction.record.kind == 'create') recover_create(env, transaction);
		else if (transaction.record.kind == 'inspect')
			recover_inspect(env, transaction, now);
		else recover_prune(env, transaction);
	}
	return true;
};

function with_transaction_lease(env, worker) {
	return env.secure.with_transaction_lease((lease) => {
		if (type(lease) != 'object') internal();
		return worker({ runtime: env.runtime, secure: env.secure, lease });
	});
};

function journal_begin(env, kind, created_at, initial) {
	if (type(env?.lease) != 'object') internal();
	recover_transactions_locked(env);
	let root = open_dir(env.secure, TRANSACTION_ROOT);
	if (length(safe_names(env.secure, root, MAX_TRANSACTIONS)) >= MAX_TRANSACTIONS)
		errors.fail('BUSY');
	let nonce = env.runtime.random.hex(16);
	if (!match(nonce, /^[0-9a-f]{32}$/)) internal();
	let id = sprintf('t-%013d-%s', created_at, nonce);
	let record = journal_base(id, kind, created_at);
	for (let name, value in initial ?? {}) {
		if (!exists(JOURNAL_FIELDS, name)) internal();
		record[name] = value;
	}
	let written = secure_create(env, root, id + '.json', journal_text(record), 0o600);
	return { root, name: id + '.json', record, identity: written.identity };
};

function list_records(app, env) {
	if (type(env?.lease) != 'object') internal();
	let root = open_dir(env.secure, BACKUP_ROOT);
	let names = safe_names(env.secure, root, MAX_FILES * 4 + 64), output = [];
	for (let name in names) {
		let found = match(name, /^(b-[0-9]{13}-[0-9a-f]{32})\.json$/);
		if (found == null) continue;
		try {
			let record = source_record(app, found[1], env);
			push(output, clone(record.sidecar));
		}
		catch (error) {
			if (errors.normalize(error).code == 'CORRUPT_STATE')
				errors.fail('CORRUPT_STATE');
		}
	}
	sort(output, (left, right) => left.id == right.id ? 0 : (left.id < right.id ? -1 : 1));
	return output;
};

export function list(app, options) {
	validate_options(options, {});
	try {
		let env = validate_app(app);
		return with_transaction_lease(env, (leased) => {
			recover_transactions_locked(leased);
			return list_records(app, leased);
		});
	}
	catch (error) { errors.fail(errors.normalize(error).code); }
};

function create_impl(app, options, source, env) {
	options = validate_options(options, { include_secrets: true });
	if (options.include_secrets != null && type(options.include_secrets) != 'bool') invalid();
	if (source != null && !exists({ luci: true, telegram: true, auto: true, system: true }, source))
		invalid();
	if (type(env?.lease) != 'object') internal();
	if (type(app.settings?.load) != 'function' ||
	    type(app.settings?.validate_patch) != 'function') invalid();
	let root = open_dir(env.secure, BACKUP_ROOT), include_secrets = options.include_secrets === true;
	let now = env.runtime.clock.now(), nonce = env.runtime.random.hex(16);
	if (type(now) != 'int' || now < 0 || !match(nonce, /^[0-9a-f]{32}$/)) internal();
	let id = sprintf('b-%013d-%s', now, nonce), files = [], contents = {};
	let temp_name = '.' + id + '.tar.tmp', temp_identity = null;
	let side_name = id + '.json', side_identity = null, archive_identity = null;
	let transaction = null;
	try {
		let clash = open_dir(env.secure, '/opt/clash');
		if (include_secrets)
			for (let profile in PROFILES) {
				if (env.secure.stat(clash, profile) == null) continue;
				let captured = secure_read(env, clash, profile, MAX_MEMBER, 0o600);
				let path = 'configs/' + profile;
				contents[path] = captured.content;
				push(files, { path, size: captured.size, sha256: captured.sha256, secret: true });
			}
		let rules = open_child_dir(env.secure, clash, 'lst', true);
		for (let name in sorted(safe_names(env.secure, rules, MAX_FILES))) {
			if (!safe_ruleset_name(name)) continue;
			let captured = secure_read(env, rules, name, MAX_MEMBER, 0o600);
			let path = 'rulesets/' + name;
			contents[path] = captured.content;
			push(files, { path, size: captured.size, sha256: captured.sha256, secret: false });
		}
		let desired = app.settings.load(env.runtime);
		desired = include_secrets ?
			settings_walk(desired, false, { remaining: 4096 }, 0) : sanitized_settings(desired);
		desired = app.settings.validate_patch(desired);
		if (!include_secrets && settings_has_secret(desired, { remaining: 4096 }, 0))
			internal();
		let settings_text = sprintf('%J\n', desired), settings_path = 'settings/settings.json';
		if (length(settings_text) > MAX_MEMBER) errors.fail('RESPONSE_TOO_LARGE');
		contents[settings_path] = settings_text;
		push(files, { path: settings_path, size: length(settings_text),
			sha256: env.runtime.digest.sha256(settings_text), secret: include_secrets });
		sort(files, (left, right) => left.path == right.path ? 0 : (left.path < right.path ? -1 : 1));
		let includes = [];
		for (let file in files) {
			let include = split(file.path, '/')[0];
			if (index(includes, include) < 0) push(includes, include);
		}
		includes = sorted(includes);
		let manifest = { schema: 1, created_at: now, app_version: app.app_version,
			includes, files: clone(files) };
		let manifest_text = sprintf('%J\n', manifest);
		if (length(manifest_text) > MAX_MANIFEST) errors.fail('RESPONSE_TOO_LARGE');
		let members = [];
		for (let file in files) push(members, { name: file.path, content: contents[file.path] });
		push(members, { name: 'manifest.json', content: manifest_text });
		let archive_bytes = ustar_write(members);
		let archive_digest = env.runtime.digest.sha256(archive_bytes);
		let sidecar = { schema: 1, id, created_at: now, app_version: app.app_version,
			includes, file_count: length(files), size: length(archive_bytes),
			sha256: archive_digest };
		let sidecar_text = sprintf('%J\n', sidecar);
		transaction = journal_begin(env, 'create', now, {
			backup_id: id, temp_name, archive_name: id + '.tar', sidecar_name: side_name,
			archive_size: length(archive_bytes), archive_sha256: archive_digest,
			sidecar_size: length(sidecar_text), sidecar_sha256: env.runtime.digest.sha256(sidecar_text)
		});
		let temp = secure_create(env, root, temp_name, archive_bytes, 0o600);
		temp_identity = temp.identity;
		transaction.record.temp_identity = file_identity_record(temp.identity);
		transaction.record.phase = 'temp'; journal_store(env, transaction);
		transaction.record.phase = 'side_planned'; journal_store(env, transaction);
		let side = secure_create(env, root, side_name, sidecar_text, 0o600);
		side_identity = side.identity;
		transaction.record.sidecar_identity = file_identity_record(side.identity);
		transaction.record.phase = 'side'; journal_store(env, transaction);
		transaction.record.phase = 'publish_planned'; journal_store(env, transaction);
		archive_identity = env.secure.rename_noreplace(root, temp_name, id + '.tar', temp_identity,
			{ mode: 0o600, uid: 0, nlink: 1 });
		if (!valid_file_identity(archive_identity, 0o600, length(archive_bytes))) internal();
		temp_identity = null;
		transaction.record.temp_identity = null;
		transaction.record.archive_identity = file_identity_record(archive_identity);
		transaction.record.phase = 'published'; journal_store(env, transaction);
		let published = secure_read(env, root, id + '.tar', MAX_ARCHIVE, 0o600, archive_identity);
		let published_side = secure_read(env, root, side_name, MAX_MANIFEST, 0o600, side_identity);
		if (published.sha256 != sidecar.sha256 || published_side.content != sidecar_text)
			internal();
		transaction.record.phase = 'complete'; journal_store(env, transaction);
		journal_finish(env, transaction); transaction = null;
		return clone(sidecar);
	}
	catch (error) {
		if (transaction != null)
			try { recover_transactions_locked(env); } catch (ignore) {}
		let code = errors.normalize(error).code;
		errors.fail(code == 'RESPONSE_TOO_LARGE' || code == 'INVALID_ARGUMENT' || code == 'BUSY' ?
			code : 'INTERNAL');
	}
};

export function create(app, options, source) {
	try {
		let env = validate_app(app);
		return with_transaction_lease(env, (leased) => {
			recover_transactions_locked(leased);
			return create_impl(app, options, source, leased);
		});
	}
	catch (error) { errors.fail(errors.normalize(error).code); }
};

function manifest_from_archive(env, archive) {
	let parsed = ustar_parse(archive.content), manifest_member = parsed.by_name['manifest.json'];
	if (manifest_member == null || length(manifest_member.content) > MAX_MANIFEST)
		errors.fail('VALIDATION_FAILED');
	let manifest;
	try { manifest = json(manifest_member.content); }
	catch (error) { errors.fail('VALIDATION_FAILED'); }
	if (manifest_member.content != sprintf('%J\n', manifest)) errors.fail('VALIDATION_FAILED');
	manifest = validate_manifest(manifest, parsed, env.runtime.digest.sha256);
	for (let file in manifest.files)
		if (file.path == 'settings/settings.json')
			settings_document(parsed.by_name[file.path].content, file.secret);
	return { manifest, parsed };
};

function inspect_impl(app, source_id, options, env) {
	validate_options(options, {});
	if (type(env?.lease) != 'object') internal();
	let source = source_record(app, source_id, env), decoded;
	try { decoded = manifest_from_archive(source.env, source.archive); }
	catch (error) {
		let code = errors.normalize(error).code;
		errors.fail(code == 'RESPONSE_TOO_LARGE' ? code : 'VALIDATION_FAILED');
	}
	let manifest = decoded.manifest;
	if (source.sidecar.created_at != manifest.created_at ||
	    source.sidecar.app_version != manifest.app_version ||
	    source.sidecar.file_count != length(manifest.files) ||
	    sprintf('%J', source.sidecar.includes) != sprintf('%J', manifest.includes))
		errors.fail('VALIDATION_FAILED');
	let root = open_dir(source.env.secure, INSPECT_ROOT), now = source.env.runtime.clock.now();
	let nonce = source.env.runtime.random.hex(16);
	if (type(now) != 'int' || now < 0 || !match(nonce, /^[0-9a-f]{32}$/)) internal();
	let id = sprintf('x-%013d-%s', now, nonce);
	if (source.env.secure.stat(root, id) != null) internal();
	let journal_files = [];
	for (let file in manifest.files)
		push(journal_files, { path: file.path, size: file.size, sha256: file.sha256,
			mode: 0o400, identity: null });
	let manifest_content = decoded.parsed.by_name['manifest.json'].content;
	push(journal_files, { path: 'manifest.json', size: length(manifest_content),
		sha256: source.env.runtime.digest.sha256(manifest_content), mode: 0o400, identity: null });
	let transaction = journal_begin(source.env, 'inspect', now, {
		inspection_id: id, expires_at: now + INSPECTION_TTL,
		directories: [], files: journal_files
	});
	let staging = null;
	try {
		staging = open_child_dir(source.env.secure, root, id, true);
		transaction.record.stage_identity = directory_identity_record(staging.identity);
		transaction.record.phase = 'staging'; journal_store(source.env, transaction);
		let captured = [];
		for (let index, file in manifest.files) {
			transaction.record.cursor = index; journal_store(source.env, transaction);
			let parts = split(file.path, '/'), directory = staging;
			let leaf = pop(parts);
			let relative = '';
			for (let part in parts) {
				relative = length(relative) ? relative + '/' + part : part;
				let registration = null;
				for (let item in transaction.record.directories)
					if (item.path == relative) registration = item;
				if (registration == null) {
					if (source.env.secure.stat(directory, part) != null) internal();
					directory = open_child_dir(source.env.secure, directory, part, true);
					push(transaction.record.directories, {
						path: relative, identity: directory_identity_record(directory.identity)
					});
					journal_store(source.env, transaction);
				}
				else {
					let expected = record_directory_identity(registration.identity);
					directory = open_child_dir(source.env.secure, directory, part, false, expected);
				}
			}
			let written = secure_create(source.env, directory, leaf,
				decoded.parsed.by_name[file.path].content, 0o400);
			transaction.record.files[index].identity = file_identity_record(written.identity);
			transaction.record.cursor = index + 1; journal_store(source.env, transaction);
			push(captured, { path: file.path, size: file.size, sha256: file.sha256,
				secret: file.secret, inode: written.identity.inode,
				dev_major: written.identity.dev.major, dev_minor: written.identity.dev.minor });
		}
		let manifest_index = length(manifest.files);
		transaction.record.cursor = manifest_index; journal_store(source.env, transaction);
		let manifest_written = secure_create(source.env, staging, 'manifest.json',
			manifest_content, 0o400);
		transaction.record.files[manifest_index].identity = file_identity_record(manifest_written.identity);
		transaction.record.cursor = manifest_index + 1; journal_store(source.env, transaction);
		let report = {
			schema: 1, id, source_id, inspected_at: now, expires_at: now + INSPECTION_TTL,
			archive_size: source.archive.size, archive_sha256: source.archive.sha256,
			archive_inode: source.archive.identity.inode,
			archive_dev_major: source.archive.identity.dev.major,
			archive_dev_minor: source.archive.identity.dev.minor,
			manifest_inode: manifest_written.identity.inode,
			manifest_dev_major: manifest_written.identity.dev.major,
			manifest_dev_minor: manifest_written.identity.dev.minor,
			manifest, files: captured
		};
		let report_content = sprintf('%J\n', report);
		push(transaction.record.files, { path: '.inspection.json', size: length(report_content),
			sha256: source.env.runtime.digest.sha256(report_content), mode: 0o600, identity: null });
		transaction.record.phase = 'report_planned';
		transaction.record.cursor = length(transaction.record.files) - 1;
		journal_store(source.env, transaction);
		let report_written = secure_create(source.env, staging, '.inspection.json',
			report_content, 0o600);
		transaction.record.files[length(transaction.record.files) - 1].identity =
			file_identity_record(report_written.identity);
		transaction.record.cursor = length(transaction.record.files);
		transaction.record.phase = 'ready'; journal_store(source.env, transaction);
		transaction.record.phase = 'preview'; journal_store(source.env, transaction);
		return { id, source_id, created_at: manifest.created_at, inspected_at: now,
			expires_at: report.expires_at, app_version: manifest.app_version,
			includes: clone(manifest.includes), files: clone(manifest.files) };
	}
	catch (error) {
		try { recover_transactions_locked(source.env); } catch (ignore) {}
		let code = errors.normalize(error).code;
		errors.fail(code == 'RESPONSE_TOO_LARGE' || code == 'VALIDATION_FAILED' || code == 'BUSY' ?
			code : 'CORRUPT_STATE');
	}
};

export function inspect(app, source_id, options) {
	try {
		let env = validate_app(app);
		return with_transaction_lease(env, (leased) => {
			recover_transactions_locked(leased);
			return inspect_impl(app, source_id, options, leased);
		});
	}
	catch (error) { errors.fail(errors.normalize(error).code); }
};

function inspection_record(app, inspected_id, env) {
	if (type(env?.lease) != 'object') internal();
	if (!valid_id(inspected_id, 'x')) invalid();
	let root = open_dir(env.secure, INSPECT_ROOT), stat = env.secure.stat(root, inspected_id);
	if (stat == null) errors.fail('NOT_FOUND');
	let staging;
	try { staging = open_child_dir(env.secure, root, inspected_id, false, stat); }
	catch (error) { errors.fail('CORRUPT_STATE'); }
	let report_capture, report;
	try {
		report_capture = secure_read(env, staging, '.inspection.json', MAX_REPORT, 0o600);
		report = json(report_capture.content);
	}
	catch (error) { errors.fail('CORRUPT_STATE'); }
	let fields = {
		schema: true, id: true, source_id: true, inspected_at: true, expires_at: true,
		archive_size: true, archive_sha256: true, archive_inode: true,
		archive_dev_major: true, archive_dev_minor: true, manifest_inode: true,
		manifest_dev_major: true, manifest_dev_minor: true, manifest: true, files: true
	};
	let file_fields = { path: true, size: true, sha256: true, secret: true,
		inode: true, dev_major: true, dev_minor: true };
	if (report_capture.content != sprintf('%J\n', report) || !exact_fields(report, fields) ||
	    report.schema != 1 || report.id != inspected_id ||
	    (!valid_id(report.source_id, 'b') && !valid_id(report.source_id, 'i')) ||
	    type(report.inspected_at) != 'int' || type(report.expires_at) != 'int' ||
	    report.expires_at - report.inspected_at != INSPECTION_TTL ||
	    type(report.files) != 'array') errors.fail('CORRUPT_STATE');
	if (env.runtime.clock.now() > report.expires_at) {
		errors.fail('NOT_FOUND');
	}
	let pseudo = { members: [ { name: 'manifest.json' } ], by_name: {} };
	for (let file in report.manifest?.files ?? []) {
		push(pseudo.members, { name: file.path });
		pseudo.by_name[file.path] = { size: file.size, content: '' };
	}
	// Validate closed manifest structure here; actual staged hashes follow.
	let manifest = report.manifest;
	if (type(manifest?.files) != 'array') errors.fail('CORRUPT_STATE');
	let contents = {}, expected_top = { '.inspection.json': true, 'manifest.json': true };
	let manifest_expected = { type: 'file', inode: report.manifest_inode, uid: 0, mode: 0o400,
		nlink: 1, size: length(sprintf('%J\n', report.manifest)),
		dev: { major: report.manifest_dev_major, minor: report.manifest_dev_minor } };
	let staged_manifest;
	try { staged_manifest = secure_read(env, staging, 'manifest.json', MAX_MANIFEST, 0o400,
		manifest_expected); }
	catch (error) { errors.fail('CORRUPT_STATE'); }
	let decoded_manifest;
	try { decoded_manifest = json(staged_manifest.content); }
	catch (error) { errors.fail('CORRUPT_STATE'); }
	if (staged_manifest.content != sprintf('%J\n', decoded_manifest) ||
	    sprintf('%J', decoded_manifest) != sprintf('%J', manifest)) errors.fail('CORRUPT_STATE');
	if (length(report.files) != length(manifest.files)) errors.fail('CORRUPT_STATE');
	for (let index, captured in report.files) {
		let file = manifest.files[index];
		if (!exact_fields(captured, file_fields) || captured.path != file.path ||
		    captured.size != file.size || captured.sha256 != file.sha256 ||
		    captured.secret !== file.secret) errors.fail('CORRUPT_STATE');
		let parts = split(file.path, '/'), directory = staging, leaf = pop(parts);
		for (let part in parts) {
			expected_top[part] = true;
			let child = env.secure.stat(directory, part);
			try { directory = open_child_dir(env.secure, directory, part, false, child); }
			catch (error) { errors.fail('CORRUPT_STATE'); }
		}
		let expected = { type: 'file', inode: captured.inode, uid: 0, mode: 0o400,
			nlink: 1, size: captured.size,
			dev: { major: captured.dev_major, minor: captured.dev_minor } };
		let current;
		try { current = secure_read(env, directory, leaf, MAX_MEMBER, 0o400, expected); }
		catch (error) { errors.fail('CORRUPT_STATE'); }
		if (current.size != file.size || current.sha256 != file.sha256)
			errors.fail('CORRUPT_STATE');
		contents[file.path] = current.content;
	}
	for (let name in safe_names(env.secure, staging, MAX_FILES + 8))
		if (!expected_top[name]) errors.fail('CORRUPT_STATE');
	let staged_archive = {
		members: [ { name: 'manifest.json', size: staged_manifest.size,
			content: staged_manifest.content } ],
		by_name: { 'manifest.json': { name: 'manifest.json', size: staged_manifest.size,
			content: staged_manifest.content } }
	};
	for (let file in manifest.files) {
		let member = { name: file.path, size: length(contents[file.path]),
			content: contents[file.path] };
		push(staged_archive.members, member); staged_archive.by_name[file.path] = member;
	}
	try { manifest = validate_manifest(manifest, staged_archive, env.runtime.digest.sha256); }
	catch (error) { errors.fail('CORRUPT_STATE'); }
	return { env, root, staging, report, manifest, contents };
};

function validate_restore_app(app) {
	validate_app(app);
	if (type(app.config?.validate_in_operation) != 'function' ||
	    type(app.rulesets?.validate) != 'function' ||
	    type(app.settings?.validate_patch) != 'function' ||
	    type(app.settings?.save) != 'function' || type(app.settings?.load) != 'function' ||
	    type(app.operations?.submit) != 'function' || type(app.lock?.with_lock) != 'function' ||
	    type(app.reconcile?.run) != 'function') invalid();
};

function validate_restore_contents(app, ctx, inspected) {
	let settings_patch = null;
	for (let file in inspected.manifest.files) {
		let content = inspected.contents[file.path];
		if (substr(file.path, 0, 8) == 'configs/') {
			if (app.config.validate_in_operation(ctx, substr(file.path, 8), content)?.ok !== true)
				errors.fail('VALIDATION_FAILED');
		}
		else if (substr(file.path, 0, 9) == 'rulesets/') {
			if (app.rulesets.validate(substr(file.path, 9), content) !== true)
				errors.fail('VALIDATION_FAILED');
		}
		else if (file.path == 'settings/settings.json') {
			settings_patch = settings_document(content, file.secret);
			try { settings_patch = app.settings.validate_patch(settings_patch); }
			catch (error) { errors.fail('VALIDATION_FAILED'); }
			if (file.secret === false &&
			    settings_has_secret(settings_patch, { remaining: 4096 }, 0))
				errors.fail('VALIDATION_FAILED');
		}
		else errors.fail('VALIDATION_FAILED');
	}
	if (settings_patch == null) errors.fail('VALIDATION_FAILED');
	return settings_patch;
};

function prepare_restore_targets(inspected) {
	let env = inspected.env, clash = open_dir(env.secure, '/opt/clash');
	let rules = null, targets = [];
	for (let file in inspected.manifest.files) {
		let directory, name;
		if (substr(file.path, 0, 8) == 'configs/') {
			directory = clash; name = substr(file.path, 8);
		}
		else if (substr(file.path, 0, 9) == 'rulesets/') {
			if (rules == null) {
				let identity = env.secure.stat(clash, 'lst');
				if (identity == null) internal();
				rules = open_child_dir(env.secure, clash, 'lst', false, identity);
			}
			directory = rules; name = substr(file.path, 9);
		}
		else continue;
		let expected = env.secure.stat(directory, name);
		if (expected != null && !valid_file_identity(expected, 0o600)) internal();
		push(targets, { directory, name, expected,
			content: inspected.contents[file.path] });
	}
	return targets;
};

function revalidate_restore_targets(env, targets) {
	for (let target in targets) {
		let current = env.secure.stat(target.directory, target.name);
		if (target.expected == null ? current != null :
		    !same_file_identity(current, target.expected)) internal();
	}
	return true;
};

export function restore(app, inspected_id, options, source) {
	validate_options(options, {});
	if (!valid_id(inspected_id, 'x')) invalid();
	source ??= 'system';
	if (!exists({ luci: true, telegram: true, auto: true, system: true }, source)) invalid();
	validate_restore_app(app);
	try {
		let env = validate_app(app);
		return with_transaction_lease(env, (leased) => {
			recover_transactions_locked(leased);
			return app.operations.submit('backup.restore', source, { inspection_id: inspected_id },
			(ctx) => app.lock.with_lock(app.runtime, { barrier: 'normal', wait_ms: 0 }, () => {
				ctx.stage('validating', 10, 'Validating backup');
				let inspected = inspection_record(app, inspected_id, leased);
				let settings_patch = validate_restore_contents(app, ctx, inspected);
				let targets = prepare_restore_targets(inspected);
				ctx.stage('snapshot', 30, 'Creating recovery snapshot');
				let snapshot = create_impl(app, { include_secrets: true }, 'system', leased);
				ctx.stage('committing', 60, 'Committing configuration');
				revalidate_restore_targets(inspected.env, targets);
				for (let target in targets)
					secure_replace(inspected.env, target.directory, target.name,
						target.expected, target.content, 0o600);
				app.settings.save(app.runtime, settings_patch);
				ctx.stage('reconcile', 90, 'Scheduling reconciliation');
				let reconciliation = app.reconcile.run('backup_restore');
				ctx.stage('complete', 100, 'Restore committed');
				return { snapshot_id: snapshot.id, reconciliation };
			}));
		});
	}
	catch (error) { errors.fail(errors.normalize(error).code); }
};

function prune_impl(app, options, env) {
	options = validate_options(options, { retain: true });
	if (type(env?.lease) != 'object') internal();
	let retain = options.retain;
	if (retain == null) {
		if (type(app.settings?.load) != 'function') invalid();
		retain = app.settings.load(env.runtime)?.backup?.retention;
	}
	if (type(retain) != 'int' || retain < 1 || retain > 100) invalid();
	let records = list_records(app, env), root = open_dir(env.secure, BACKUP_ROOT), removed = [];
	while (length(records) > retain) {
		let item = shift(records), current = source_record(app, item.id, env);
		let side_tomb = '.prune-' + item.id + '.json', archive_tomb = '.prune-' + item.id + '.tar';
		if (env.secure.stat(root, side_tomb) != null || env.secure.stat(root, archive_tomb) != null)
			internal();
		let transaction = journal_begin(env, 'prune', env.runtime.clock.now(), {
			prune_id: item.id, archive_name: item.id + '.tar', sidecar_name: item.id + '.json',
			archive_tomb, sidecar_tomb: side_tomb, archive_size: current.archive.size,
			archive_sha256: current.archive.sha256, sidecar_size: current.sidecar_capture.size,
			sidecar_sha256: current.sidecar_capture.sha256,
			archive_identity: file_identity_record(current.archive.identity),
			sidecar_identity: file_identity_record(current.sidecar_capture.identity)
		});
		try {
			let moved_side = env.secure.rename_noreplace(root, item.id + '.json', side_tomb,
				current.sidecar_capture.identity, { mode: 0o600, uid: 0, nlink: 1 });
			transaction.record.phase = 'side_moved'; journal_store(env, transaction);
			let moved_archive = env.secure.rename_noreplace(root, item.id + '.tar', archive_tomb,
				current.archive.identity, { mode: 0o600, uid: 0, nlink: 1 });
			transaction.record.phase = 'archive_moved'; journal_store(env, transaction);
			transaction.record.phase = 'deleting'; journal_store(env, transaction);
			if (env.secure.unlink_durable(root, archive_tomb, moved_archive) !== true ||
			    env.secure.unlink_durable(root, side_tomb, moved_side) !== true) internal();
			journal_finish(env, transaction);
		}
		catch (error) {
			try { recover_transactions_locked(env); } catch (ignore) {}
			errors.fail(errors.normalize(error).code);
		}
		push(removed, item.id);
	}
	let retained = [];
	for (let item in records) push(retained, item.id);
	return { removed, retained };
};

export function prune(app, options) {
	try {
		let env = validate_app(app);
		return with_transaction_lease(env, (leased) => {
			recover_transactions_locked(leased);
			return prune_impl(app, options, leased);
		});
	}
	catch (error) { errors.fail(errors.normalize(error).code); }
};
