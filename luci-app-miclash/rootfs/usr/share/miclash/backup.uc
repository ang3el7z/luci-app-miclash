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
 *   open(path, { create, mode, uid }) -> directory handle
 *   open_at(dir, name, { create, mode, uid, expected? }) -> directory handle
 *   stat(dir, name) -> identity|null
 *   list(dir) -> [ immediate-name ]
 *   read(dir, name, { maximum, mode, uid, nlink, expected? })
 *       -> { content, identity }
 *   write(dir, name, content, { mode, uid, exclusive }) -> identity
 *   rename(dir, from, to, expected, { mode, uid, nlink }) -> identity
 *   unlink(dir, name, expected) -> true
 *   rmdir(dir, name, expected) -> true
 *
 * The module writes and parses strict USTAR itself.  No normalized archive
 * listing or extraction adapter is authoritative.
 */

const BACKUP_ROOT = '/etc/miclash/backups';
const IMPORT_ROOT = '/tmp/miclash/imports';
const INSPECT_ROOT = '/tmp/miclash/backup-inspected';
const INSPECTION_TTL = 900000;
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

function same_identity(left, right) {
	return left?.type == right?.type && left?.inode == right?.inode &&
		left?.dev?.major == right?.dev?.major && left?.dev?.minor == right?.dev?.minor &&
		left?.uid == right?.uid && left?.mode == right?.mode &&
		left?.nlink == right?.nlink;
};

function same_node(left, right) {
	return left?.type == right?.type && left?.inode == right?.inode &&
		left?.dev?.major == right?.dev?.major && left?.dev?.minor == right?.dev?.minor &&
		left?.uid == right?.uid && left?.nlink == right?.nlink;
};

function valid_identity(identity, kind, mode, size) {
	return type(identity) == 'object' && identity.type == kind &&
		type(identity.inode) == 'int' && type(identity.dev?.major) == 'int' &&
		type(identity.dev?.minor) == 'int' && identity.uid == 0 &&
		identity.mode == mode && identity.nlink == 1 &&
		(size == null || identity.size == size);
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
	for (let method in [ 'open', 'open_at', 'stat', 'list', 'read', 'write',
		'rename', 'unlink', 'rmdir' ])
		if (type(secure[method]) != 'function') internal();
	return { runtime, secure };
};

function open_dir(secure, path) {
	let handle = secure.open(path, { create: true, mode: 0o700, uid: 0 });
	if (type(handle) != 'object' || !valid_identity(handle.identity, 'directory', 0o700))
		internal();
	return handle;
};

function open_child_dir(secure, parent, name, create, expected) {
	let handle = secure.open_at(parent, name,
		{ create: create === true, mode: 0o700, uid: 0, expected });
	if (type(handle) != 'object' || !valid_identity(handle.identity, 'directory', 0o700) ||
	    (expected != null && !same_identity(handle.identity, expected))) internal();
	return handle;
};

function secure_read(env, directory, name, maximum, mode, expected) {
	let captured = env.secure.read(directory, name,
		{ maximum, mode, uid: 0, nlink: 1, expected });
	if (type(captured?.content) != 'string' ||
	    !valid_identity(captured?.identity, 'file', mode, length(captured.content)) ||
	    length(captured.content) > maximum ||
	    (expected != null && !same_identity(captured.identity, expected))) internal();
	let digest = env.runtime.digest.sha256(captured.content);
	if (type(digest) != 'string' || !match(digest, /^[0-9a-f]{64}$/)) internal();
	return {
		content: captured.content, size: length(captured.content), sha256: digest,
		identity: captured.identity
	};
};

function secure_write(env, directory, name, content, mode, exclusive) {
	if (type(content) != 'string') internal();
	let identity = env.secure.write(directory, name, content,
		{ mode, uid: 0, exclusive: exclusive === true });
	if (!valid_identity(identity, 'file', mode, length(content))) internal();
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
	return length(name) >= 5 && match(name, /^[a-z0-9][a-z0-9_-]*\.txt$/);
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
		zeroes(32) + zeroes(32) + zeroes(8) + zeroes(8) + zeroes(155) + zeroes(12);
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
		if (!canonical_member_name(name) || seen[name] || mode == null || uid == null ||
		    gid == null || size == null || mtime == null || stored == null ||
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

function source_record(app, source_id) {
	let env = validate_app(app), path;
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

function remove_tree(env, parent, name, expected) {
	let directory;
	try { directory = open_child_dir(env.secure, parent, name, false, expected); }
	catch (error) { return false; }
	let names;
	try { names = safe_names(env.secure, directory, MAX_FILES * 3 + 16); }
	catch (error) { return false; }
	let failed = false;
	for (let child_name in names) {
		let identity = env.secure.stat(directory, child_name);
		if (identity?.type == 'directory') {
			if (!remove_tree(env, directory, child_name, identity)) failed = true;
		}
		else if (identity?.type == 'file' || identity?.type == 'link') {
			try { if (env.secure.unlink(directory, child_name, identity) !== true) failed = true; }
			catch (error) { failed = true; }
		}
		else failed = true;
	}
	if (failed) return false;
	try { return env.secure.rmdir(parent, name, directory.identity) === true; }
	catch (error) { return false; }
};

function list_records(app) {
	let env = validate_app(app), root = open_dir(env.secure, BACKUP_ROOT);
	let names = safe_names(env.secure, root, MAX_FILES * 4 + 64), output = [];
	for (let name in names) {
		let found = match(name, /^(b-[0-9]{13}-[0-9a-f]{32})\.json$/);
		if (found == null) continue;
		try {
			let record = source_record(app, found[1]);
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
	try { return list_records(app); }
	catch (error) { errors.fail(errors.normalize(error).code); }
};

function create_impl(app, options, source) {
	options = validate_options(options, { include_secrets: true });
	if (options.include_secrets != null && type(options.include_secrets) != 'bool') invalid();
	if (source != null && !exists({ luci: true, telegram: true, auto: true, system: true }, source))
		invalid();
	let env = validate_app(app);
	if (type(app.settings?.load) != 'function' ||
	    type(app.settings?.validate_patch) != 'function') invalid();
	let root = open_dir(env.secure, BACKUP_ROOT), include_secrets = options.include_secrets === true;
	let now = env.runtime.clock.now(), nonce = env.runtime.random.hex(16);
	if (type(now) != 'int' || now < 0 || !match(nonce, /^[0-9a-f]{32}$/)) internal();
	let id = sprintf('b-%013d-%s', now, nonce), files = [], contents = {};
	let temp_name = '.' + id + '.tar.tmp', temp_identity = null;
	let side_name = id + '.json', side_identity = null, archive_identity = null;
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
		let temp = secure_write(env, root, temp_name, archive_bytes, 0o600, true);
		temp_identity = temp.identity;
		let sidecar = { schema: 1, id, created_at: now, app_version: app.app_version,
			includes, file_count: length(files), size: temp.size, sha256: temp.sha256 };
		let side = secure_write(env, root, side_name, sprintf('%J\n', sidecar), 0o600, true);
		side_identity = side.identity;
		archive_identity = env.secure.rename(root, temp_name, id + '.tar', temp_identity,
			{ mode: 0o600, uid: 0, nlink: 1 });
		if (!valid_identity(archive_identity, 'file', 0o600, length(archive_bytes))) internal();
		temp_identity = null;
		let published = secure_read(env, root, id + '.tar', MAX_ARCHIVE, 0o600, archive_identity);
		let published_side = secure_read(env, root, side_name, MAX_MANIFEST, 0o600, side_identity);
		if (published.sha256 != sidecar.sha256 || published_side.content != sprintf('%J\n', sidecar))
			internal();
		return clone(sidecar);
	}
	catch (error) {
		if (temp_identity != null) {
			try { env.secure.unlink(root, temp_name, temp_identity); }
			catch (ignore) {
				try {
					let moved = env.secure.stat(root, id + '.tar');
					if (same_node(temp_identity, moved))
						env.secure.unlink(root, id + '.tar', moved);
				}
				catch (ignored) {}
			}
		}
		if (archive_identity != null)
			try { env.secure.unlink(root, id + '.tar', archive_identity); } catch (ignore) {}
		if (side_identity != null)
			try { env.secure.unlink(root, side_name, side_identity); } catch (ignore) {}
		let code = errors.normalize(error).code;
		errors.fail(code == 'RESPONSE_TOO_LARGE' || code == 'INVALID_ARGUMENT' ? code : 'INTERNAL');
	}
};

export function create(app, options, source) {
	try { return create_impl(app, options, source); }
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

function inspect_impl(app, source_id, options) {
	validate_options(options, {});
	let source = source_record(app, source_id), decoded;
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
	let staging = open_child_dir(source.env.secure, root, id, true), keep = false;
	try {
		let captured = [];
		for (let file in manifest.files) {
			let parts = split(file.path, '/'), directory = staging;
			let leaf = pop(parts);
			for (let part in parts) directory = open_child_dir(source.env.secure, directory, part, true);
			let written = secure_write(source.env, directory, leaf,
				decoded.parsed.by_name[file.path].content, 0o400, true);
			push(captured, { path: file.path, size: file.size, sha256: file.sha256,
				secret: file.secret, inode: written.identity.inode,
				dev_major: written.identity.dev.major, dev_minor: written.identity.dev.minor });
		}
		let manifest_written = secure_write(source.env, staging, 'manifest.json',
			decoded.parsed.by_name['manifest.json'].content, 0o400, true);
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
		secure_write(source.env, staging, '.inspection.json', sprintf('%J\n', report), 0o600, true);
		keep = true;
		return { id, source_id, created_at: manifest.created_at, inspected_at: now,
			expires_at: report.expires_at, app_version: manifest.app_version,
			includes: clone(manifest.includes), files: clone(manifest.files) };
	}
	catch (error) {
		if (!keep) remove_tree(source.env, root, id, staging.identity);
		let code = errors.normalize(error).code;
		errors.fail(code == 'RESPONSE_TOO_LARGE' || code == 'VALIDATION_FAILED' ? code : 'CORRUPT_STATE');
	}
};

export function inspect(app, source_id, options) {
	try { return inspect_impl(app, source_id, options); }
	catch (error) { errors.fail(errors.normalize(error).code); }
};

function inspection_record(app, inspected_id) {
	let env = validate_app(app);
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
		remove_tree(env, root, inspected_id, staging.identity);
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
		nlink: 1, dev: { major: report.manifest_dev_major, minor: report.manifest_dev_minor } };
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
			nlink: 1, dev: { major: captured.dev_major, minor: captured.dev_minor } };
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

export function restore(app, inspected_id, options, source) {
	validate_options(options, {});
	if (!valid_id(inspected_id, 'x')) invalid();
	source ??= 'system';
	if (!exists({ luci: true, telegram: true, auto: true, system: true }, source)) invalid();
	validate_restore_app(app);
	try {
		return app.operations.submit('backup.restore', source, { inspection_id: inspected_id },
			(ctx) => app.lock.with_lock(app.runtime, { barrier: 'normal', wait_ms: 0 }, () => {
				ctx.stage('validating', 10, 'Validating backup');
				let inspected = inspection_record(app, inspected_id);
				let settings_patch = validate_restore_contents(app, ctx, inspected);
				ctx.stage('snapshot', 30, 'Creating recovery snapshot');
				let snapshot = create_impl(app, { include_secrets: true }, 'system');
				ctx.stage('committing', 60, 'Committing configuration');
				let clash = open_dir(inspected.env.secure, '/opt/clash');
				let rules = open_child_dir(inspected.env.secure, clash, 'lst', true);
				for (let file in inspected.manifest.files) {
					if (substr(file.path, 0, 8) == 'configs/')
						secure_write(inspected.env, clash, substr(file.path, 8),
							inspected.contents[file.path], 0o600, false);
					else if (substr(file.path, 0, 9) == 'rulesets/')
						secure_write(inspected.env, rules, substr(file.path, 9),
							inspected.contents[file.path], 0o600, false);
				}
				app.settings.save(app.runtime, settings_patch);
				ctx.stage('reconcile', 90, 'Scheduling reconciliation');
				let reconciliation = app.reconcile.run('backup_restore');
				ctx.stage('complete', 100, 'Restore committed');
				return { snapshot_id: snapshot.id, reconciliation };
			}));
	}
	catch (error) { errors.fail(errors.normalize(error).code); }
};

function prune_impl(app, options) {
	options = validate_options(options, { retain: true });
	let env = validate_app(app), retain = options.retain;
	if (retain == null) {
		if (type(app.settings?.load) != 'function') invalid();
		retain = app.settings.load(env.runtime)?.backup?.retention;
	}
	if (type(retain) != 'int' || retain < 1 || retain > 100) invalid();
	let records = list_records(app), root = open_dir(env.secure, BACKUP_ROOT), removed = [];
	while (length(records) > retain) {
		let item = shift(records), current = source_record(app, item.id);
		let side_tomb = '.prune-' + item.id + '.json', archive_tomb = '.prune-' + item.id + '.tar';
		if (env.secure.stat(root, side_tomb) != null || env.secure.stat(root, archive_tomb) != null)
			internal();
		let moved_side = env.secure.rename(root, item.id + '.json', side_tomb,
			current.sidecar_capture.identity, { mode: 0o600, uid: 0, nlink: 1 });
		let moved_archive;
		try {
			moved_archive = env.secure.rename(root, item.id + '.tar', archive_tomb,
				current.archive.identity, { mode: 0o600, uid: 0, nlink: 1 });
		}
		catch (error) {
			try { env.secure.rename(root, side_tomb, item.id + '.json', moved_side,
				{ mode: 0o600, uid: 0, nlink: 1 }); } catch (ignore) {}
			errors.fail(errors.normalize(error).code);
		}
		if (env.secure.unlink(root, archive_tomb, moved_archive) !== true ||
		    env.secure.unlink(root, side_tomb, moved_side) !== true) internal();
		push(removed, item.id);
	}
	let retained = [];
	for (let item in records) push(retained, item.id);
	return { removed, retained };
};

export function prune(app, options) {
	try { return prune_impl(app, options); }
	catch (error) { errors.fail(errors.normalize(error).code); }
};
