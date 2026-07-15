import * as errors from 'miclash.errors';
import * as schema from 'miclash.schema';
import * as storage from 'miclash.storage';

/*
 * app.archive is an injected, bounded archive adapter. Its exact contract is:
 *   create({ archive, root, members }) -> true
 *   list({ archive }) -> [{ name, type, size, linkname, sparse, pax }]
 *   extract({ archive, destination, members }) -> true
 * extract() must create requested regular files directly with mode 0400 and
 * must not create links; the module verifies that contract without chmodding
 * any adapter-controlled path.
 * Every path and member passed to it is generated here. Adapter output is
 * untrusted and closed-validated before extraction, then the extracted tree is
 * authenticated and rehashed. The public API never accepts any of these paths.
 */

const BACKUP_ROOT = '/etc/miclash/backups';
const IMPORT_ROOT = '/tmp/miclash/imports';
const CREATE_ROOT = '/tmp/miclash/backup-create';
const INSPECT_ROOT = '/tmp/miclash/backup-inspected';
const INSPECTION_TTL = 900000;
const MAX_ARCHIVE = 16777216;
const MAX_MEMBER = 4194304;
const MAX_MANIFEST = 65536;
const MAX_REPORT = 262144;
const MAX_FILES = 1024;

const PROFILES = [ 'config.yaml', 'config2.yaml', 'config3.yaml' ];

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

function same_node(left, right) {
	return left?.type == right?.type && left?.inode == right?.inode &&
		left?.dev?.major == right?.dev?.major && left?.dev?.minor == right?.dev?.minor;
};

function same_file(left, right) {
	return left?.type == 'file' && right?.type == 'file' && left.nlink == 1 &&
		right.nlink == 1 && left.size == right.size && same_node(left, right);
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

function validate_app(app, archive_methods) {
	let runtime = app?.runtime;
	if (type(runtime?.fs?.lstat) != 'function' || type(runtime.fs.realpath) != 'function' ||
	    type(runtime.fs.mkdir) != 'function' || type(runtime.fs.chmod) != 'function' ||
	    type(runtime.fs.lsdir) != 'function' || type(runtime.fs.readfile) != 'function' ||
	    type(runtime.fs.unlink) != 'function' || type(runtime.fs.rmdir) != 'function' ||
	    type(runtime.fs.rename) != 'function' ||
	    type(runtime.digest?.sha256) != 'function' ||
	    type(runtime.digest?.sha256_file) != 'function' ||
	    type(runtime.clock?.now) != 'function' || type(runtime.random?.hex) != 'function' ||
	    runtime.paths?.etc != '/etc/miclash' || runtime.paths?.tmp != '/tmp/miclash' ||
	    !valid_version(app?.app_version) || type(app?.archive) != 'object')
		invalid();
	for (let method in archive_methods)
		if (type(app.archive[method]) != 'function') invalid();
	return runtime;
};

function ensure_directory(runtime, path) {
	let before = runtime.fs.lstat(path);
	if (before == null && runtime.fs.mkdir(path) != true) internal();
	before = runtime.fs.lstat(path);
	if (before?.type != 'directory' || runtime.fs.realpath(path) != path ||
	    (before.uid != null && before.uid != 0) || runtime.fs.chmod(path, 0o700) != true)
		internal();
	let after = runtime.fs.lstat(path);
	if (!same_node(before, after) || after?.mode != 0o700 ||
	    runtime.fs.realpath(path) != path || (after.uid != null && after.uid != 0))
		internal();
	return after;
};

function secure_read(runtime, path, maximum) {
	let before = runtime.fs.lstat(path);
	if (before?.type != 'file' || before.nlink != 1 || before.size < 0 ||
	    before.size > maximum || runtime.fs.realpath(path) != path ||
	    (before.uid != null && before.uid != 0) ||
	    (before.mode != null && (before.mode & 0o022) != 0))
		internal();
	let content = runtime.fs.readfile(path);
	let after = runtime.fs.lstat(path);
	if (type(content) != 'string' || length(content) != before.size ||
	    !same_file(before, after) || runtime.fs.realpath(path) != path)
		internal();
	let digest = runtime.digest.sha256(content);
	if (!match(digest, /^[0-9a-f]{64}$/) ||
	    runtime.digest.sha256_file(path) != digest)
		internal();
	return { content, size: length(content), sha256: digest, identity: after };
};

function safe_ruleset_name(name) {
	try { schema.archive_name(name); }
	catch (error) { return false; }
	return length(name) >= 5 &&
		match(name, /^[a-z0-9][a-z0-9_-]*\.txt$/);
};

function sorted(values) {
	let output = [ ...values ];
	sort(output, (left, right) => left == right ? 0 : (left < right ? -1 : 1));
	return output;
};

function sanitized_settings(value) {
	let output = clone(value);
	for (let name in [ 'subscription_url', 'subscription_url_config_yaml',
		'subscription_url_config2_yaml', 'subscription_url_config3_yaml' ])
		if (output.core != null) delete output.core[name];
	if (output.telegram != null) delete output.telegram.token;
	return output;
};

function stage_file(runtime, root, relative, content, files, secret) {
	if (type(content) != 'string' || length(content) > MAX_MEMBER) errors.fail('RESPONSE_TOO_LARGE');
	let record = { path: relative };
	push(files, record);
	let parts = split(relative, '/'), directory = root;
	pop(parts);
	for (let part in parts) {
		directory += '/' + part;
		ensure_directory(runtime, directory);
	}
	storage.atomic_write(runtime, root + '/' + relative, content, 0o600);
	let captured = secure_read(runtime, root + '/' + relative, MAX_MEMBER);
	record.size = captured.size;
	record.sha256 = captured.sha256;
	record.secret = secret;
};

function remove_staging(runtime, root, files, expected_root) {
	let root_stat;
	try { root_stat = runtime.fs.lstat(root); }
	catch (error) { return false; }
	if (root_stat == null) return true;
	if (root_stat.type != 'directory' || runtime.fs.realpath(root) != root ||
	    (root_stat.uid != null && root_stat.uid != 0) ||
	    (expected_root != null && !same_node(root_stat, expected_root))) return false;
	let budget = { remaining: MAX_FILES * 4 + 64 }, failed = false;
	function sweep(directory) {
		let names;
		try { names = runtime.fs.lsdir(directory); }
		catch (error) { failed = true; return; }
		if (type(names) != 'array') { failed = true; return; }
		for (let name in names) {
			if (--budget.remaining < 0 || type(name) != 'string' || !length(name) ||
			    name == '.' || name == '..' || index(name, '/') >= 0 ||
			    index(name, sprintf('%c', 0)) >= 0) { failed = true; continue; }
			let path = directory + '/' + name, current;
			try { current = runtime.fs.lstat(path); }
			catch (error) { failed = true; continue; }
			if (current == null) continue;
			if (current.type == 'directory') {
				if (runtime.fs.realpath(path) != path ||
				    current.dev?.major != root_stat.dev?.major ||
				    current.dev?.minor != root_stat.dev?.minor ||
				    (current.uid != null && current.uid != 0)) { failed = true; continue; }
				sweep(path);
				try { if (length(runtime.fs.lsdir(path) ?? []) || runtime.fs.rmdir(path) != true)
					failed = true; }
				catch (error) { failed = true; }
			}
			else
				try { if (runtime.fs.unlink(path) != true) failed = true; }
				catch (error) { failed = true; }
		}
	};
	sweep(root);
	try { if (length(runtime.fs.lsdir(root) ?? []) || runtime.fs.rmdir(root) != true) failed = true; }
	catch (error) { failed = true; }
	return !failed;
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
	let runtime = validate_app(app, []), root;
	if (valid_id(source_id, 'b')) root = BACKUP_ROOT;
	else if (valid_id(source_id, 'i')) root = IMPORT_ROOT;
	else invalid();
	ensure_directory(runtime, root);
	let sidecar_path = root + '/' + source_id + '.json';
	let archive_path = root + '/' + source_id + '.tar';
	if (runtime.fs.lstat(sidecar_path) == null || runtime.fs.lstat(archive_path) == null)
		errors.fail('NOT_FOUND');
	let sidecar_capture, sidecar, archive;
	try {
		sidecar_capture = secure_read(runtime, sidecar_path, MAX_MANIFEST);
		sidecar = json(sidecar_capture.content);
		archive = secure_read(runtime, archive_path, MAX_ARCHIVE);
	}
	catch (error) { errors.fail('CORRUPT_STATE'); }
	if (sidecar_capture.content != sprintf('%J\n', sidecar) ||
	    !sidecar_valid(sidecar, source_id) || archive.size != sidecar.size ||
	    archive.sha256 != sidecar.sha256) errors.fail('CORRUPT_STATE');
	return { root, sidecar, sidecar_capture, sidecar_path, archive, archive_path };
};

function same_capture(left, right) {
	return left?.size == right?.size && left?.sha256 == right?.sha256 &&
		same_file(left?.identity, right?.identity);
};

function canonical_member_name(name) {
	if (type(name) != 'string' || length(name) < 1 || length(name) > 192 ||
	    !match(name, /^[A-Za-z0-9._\/-]+$/) || substr(name, 0, 1) == '/' ||
	    substr(name, -1) == '/' || index(name, '//') >= 0 || index(name, '\\') >= 0 ||
	    match(name, /^[A-Za-z]:/)) return false;
	for (let part in split(name, '/'))
		if (!length(part) || part == '.' || part == '..') return false;
	return true;
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

function validate_entries(entries) {
	let fields = {
		name: true, type: true, size: true, linkname: true, sparse: true, pax: true
	};
	if (type(entries) != 'array' || length(entries) < 2) errors.fail('VALIDATION_FAILED');
	if (length(entries) > MAX_FILES + 1) errors.fail('RESPONSE_TOO_LARGE');
	let seen = {}, total = 0, output = {};
	for (let entry in entries) {
		if (!exact_fields(entry, fields) || !canonical_member_name(entry.name) ||
		    seen[entry.name] || type(entry.type) != 'string' || entry.type != 'file' ||
		    type(entry.size) != 'int' || entry.size < 0 ||
		    entry.linkname != null || entry.sparse !== false || entry.pax !== false)
			errors.fail('VALIDATION_FAILED');
		if (entry.size > MAX_MEMBER ||
		    (entry.name == 'manifest.json' && entry.size > MAX_MANIFEST))
			errors.fail('RESPONSE_TOO_LARGE');
		total += entry.size;
		if (total > MAX_ARCHIVE) errors.fail('RESPONSE_TOO_LARGE');
		seen[entry.name] = true;
		output[entry.name] = entry;
	}
	if (!seen['manifest.json']) errors.fail('VALIDATION_FAILED');
	return output;
};

function validate_manifest(manifest, headers) {
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
	let seen = {}, previous_path = null, derived = {};
	for (let file in manifest.files) {
		if (!exact_fields(file, file_fields) || type(file.secret) != 'bool' ||
		    !valid_logical_path(file.path, file.secret) || seen[file.path] ||
		    (previous_path != null && file.path <= previous_path) ||
		    type(file.size) != 'int' || file.size < 0 || file.size > MAX_MEMBER ||
		    type(file.sha256) != 'string' || !match(file.sha256, /^[0-9a-f]{64}$/) ||
		    headers[file.path] == null || headers[file.path].size != file.size)
			errors.fail('VALIDATION_FAILED');
		seen[file.path] = true; previous_path = file.path;
		derived[split(file.path, '/')[0]] = true;
	}
	for (let name in headers)
		if (name != 'manifest.json' && !seen[name]) errors.fail('VALIDATION_FAILED');
	if (length(keys(headers)) != length(manifest.files) + 1) errors.fail('VALIDATION_FAILED');
	if (sprintf('%J', sorted(keys(derived))) != sprintf('%J', manifest.includes))
		errors.fail('VALIDATION_FAILED');
	return clone(manifest);
};

function tree_files(runtime, root, relative, output, budget) {
	let path = length(relative) ? root + '/' + relative : root;
	let stat = runtime.fs.lstat(path);
	if (stat?.type != 'directory' || runtime.fs.realpath(path) != path ||
	    (stat.uid != null && stat.uid != 0) || stat.mode != 0o700)
		errors.fail('CORRUPT_STATE');
	let names = runtime.fs.lsdir(path);
	if (type(names) != 'array') errors.fail('CORRUPT_STATE');
	for (let name in names) {
		if (!canonical_member_name(name) || index(name, '/') >= 0 || --budget.remaining < 0)
			errors.fail('CORRUPT_STATE');
		let child_relative = length(relative) ? relative + '/' + name : name;
		let child = root + '/' + child_relative, child_stat = runtime.fs.lstat(child);
		if (child_stat?.type == 'directory')
			tree_files(runtime, root, child_relative, output, budget);
		else if (child_stat?.type == 'file') push(output, child_relative);
		else errors.fail('CORRUPT_STATE');
	}
};

function capture_file(runtime, root, file) {
	let path = root + '/' + file.path;
	let captured;
	try { captured = secure_read(runtime, path, MAX_MEMBER); }
	catch (error) { errors.fail('CORRUPT_STATE'); }
	if (captured.size != file.size || captured.sha256 != file.sha256 ||
	    captured.identity.mode != 0o400) errors.fail('VALIDATION_FAILED');
	return {
		path: file.path, size: file.size, sha256: file.sha256, secret: file.secret,
		inode: captured.identity.inode,
		dev_major: captured.identity.dev?.major,
		dev_minor: captured.identity.dev?.minor
	};
};

function recover_prunes(runtime) {
	let names;
	try { names = runtime.fs.lsdir(BACKUP_ROOT); }
	catch (error) { return false; }
	if (type(names) != 'array' || length(names) > MAX_FILES * 4) return false;
	for (let name in names) {
		let found = match(name, /^\.prune-(b-[0-9]{13}-[0-9a-f]{32})\.json$/);
		if (found == null) continue;
		let id = found[1], sidecar_path = BACKUP_ROOT + '/' + name;
		let archive_path = BACKUP_ROOT + '/' + id + '.tar';
		let tomb_archive = BACKUP_ROOT + '/.prune-' + id + '.tar';
		let sidecar_capture, sidecar;
		try {
			sidecar_capture = secure_read(runtime, sidecar_path, MAX_MANIFEST);
			sidecar = json(sidecar_capture.content);
		}
		catch (error) { continue; }
		if (sidecar_capture.content != sprintf('%J\n', sidecar) ||
		    !sidecar_valid(sidecar, id)) continue;
		if (runtime.fs.lstat(tomb_archive) == null && runtime.fs.lstat(archive_path) != null) {
			let archive;
			try { archive = secure_read(runtime, archive_path, MAX_ARCHIVE); }
			catch (error) { continue; }
			if (archive.size != sidecar.size || archive.sha256 != sidecar.sha256 ||
			    runtime.fs.rename(archive_path, tomb_archive) != true) continue;
		}
		if (runtime.fs.lstat(tomb_archive) != null) {
			let archive;
			try { archive = secure_read(runtime, tomb_archive, MAX_ARCHIVE); }
			catch (error) { continue; }
			if (archive.size != sidecar.size || archive.sha256 != sidecar.sha256) continue;
			try { if (runtime.fs.unlink(tomb_archive) != true) continue; }
			catch (error) { continue; }
		}
		try {
			if (same_file(sidecar_capture.identity, runtime.fs.lstat(sidecar_path)))
				runtime.fs.unlink(sidecar_path);
		}
		catch (error) {}
	}
	return true;
};

function list_records(app) {
	let runtime = validate_app(app, []);
	ensure_directory(runtime, BACKUP_ROOT);
	recover_prunes(runtime);
	let names = runtime.fs.lsdir(BACKUP_ROOT);
	if (type(names) != 'array' || length(names) > MAX_FILES * 2) internal();
	let output = [];
	for (let name in names) {
		let found = match(name, /^(b-[0-9]{13}-[0-9a-f]{32})\.json$/);
		if (found == null) continue;
		let id = found[1], sidecar, sidecar_capture;
		try {
			sidecar_capture = secure_read(runtime, BACKUP_ROOT + '/' + name, MAX_MANIFEST);
			sidecar = json(sidecar_capture.content);
		}
		catch (error) { continue; }
		if (sidecar_capture.content != sprintf('%J\n', sidecar) ||
		    !sidecar_valid(sidecar, id)) continue;
		let archive;
		try { archive = secure_read(runtime, BACKUP_ROOT + '/' + id + '.tar', MAX_ARCHIVE); }
		catch (error) { continue; }
		if (archive.size != sidecar.size || archive.sha256 != sidecar.sha256) continue;
		push(output, clone(sidecar));
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
	let runtime = validate_app(app, [ 'create' ]);
	if (type(app.settings?.load) != 'function' ||
	    type(app.settings?.validate_patch) != 'function') invalid();
	ensure_directory(runtime, BACKUP_ROOT);
	ensure_directory(runtime, CREATE_ROOT);
	let now = runtime.clock.now(), nonce = runtime.random.hex(16);
	if (type(now) != 'int' || now < 0 || !match(nonce, /^[0-9a-f]{32}$/)) internal();
	let id = sprintf('b-%013d-%s', now, nonce);
	let staging = CREATE_ROOT + '/' + id;
	if (runtime.fs.lstat(staging) != null) internal();
	let staging_identity = ensure_directory(runtime, staging);
	let files = [], staged = [], archive_temp = null, archive_temp_identity = null;
	let sidecar_path = null, sidecar_identity = null;
	let published_archive = false;
	let include_secrets = options.include_secrets === true;
	try {
		if (include_secrets)
			for (let profile in PROFILES) {
				let path = '/opt/clash/' + profile;
				if (runtime.fs.lstat(path) == null) continue;
				let item = secure_read(runtime, path, MAX_MEMBER);
				stage_file(runtime, staging, 'configs/' + profile, item.content, files, true);
			}

		let ruleset_names = runtime.fs.lsdir('/opt/clash/lst') ?? [];
		if (type(ruleset_names) != 'array' || length(ruleset_names) > MAX_FILES) internal();
		for (let name in sorted(ruleset_names)) {
			if (!safe_ruleset_name(name)) continue;
			let item = secure_read(runtime, '/opt/clash/lst/' + name, MAX_MEMBER);
			stage_file(runtime, staging, 'rulesets/' + name, item.content, files, false);
		}

		let desired = app.settings.load(runtime);
		desired = include_secrets ? desired : sanitized_settings(desired);
		desired = app.settings.validate_patch(desired);
		stage_file(runtime, staging, 'settings/settings.json', sprintf('%J\n', desired),
			files, include_secrets);

		sort(files, (left, right) => left.path == right.path ? 0 : (left.path < right.path ? -1 : 1));
		let includes = [];
		for (let file in files) {
			let include = split(file.path, '/')[0];
			let present = false;
			for (let value in includes) if (value == include) present = true;
			if (!present) push(includes, include);
		}
		includes = sorted(includes);
		let manifest = {
			schema: 1, created_at: now, app_version: app.app_version,
			includes, files: clone(files)
		};
		let manifest_text = sprintf('%J\n', manifest);
		if (length(manifest_text) > MAX_MANIFEST) errors.fail('RESPONSE_TOO_LARGE');
		stage_file(runtime, staging, 'manifest.json', manifest_text, staged, false);
		let members = [];
		for (let file in files) push(members, file.path);
		push(members, 'manifest.json');
		let suffix = runtime.random.hex(4);
		if (!match(suffix, /^[0-9a-f]{8}$/)) internal();
		archive_temp = sprintf('%s/.%s.tar.miclash.%d-1.%s',
			BACKUP_ROOT, id, now, suffix);
		if (app.archive.create({ archive: archive_temp, root: staging, members }) !== true)
			internal();
		let archive = secure_read(runtime, archive_temp, MAX_ARCHIVE);
		archive_temp_identity = archive.identity;
		let sidecar = {
			schema: 1, id, created_at: now, app_version: app.app_version,
			includes, file_count: length(files), size: archive.size, sha256: archive.sha256
		};
		sidecar_path = BACKUP_ROOT + '/' + id + '.json';
		storage.write_json(runtime, sidecar_path, sidecar, 0o600);
		sidecar_identity = runtime.fs.lstat(sidecar_path);
		storage.atomic_replace(runtime, archive_temp, BACKUP_ROOT + '/' + id + '.tar');
		archive_temp = null;
		published_archive = true;
		let published = list_records(app);
		let visible = null;
		for (let item in published) if (item.id == id) visible = item;
		if (visible == null) internal();
		if (!remove_staging(runtime, staging, [ ...files, ...staged ], staging_identity)) internal();
		return visible;
	}
	catch (error) {
		if (archive_temp != null)
			try {
				let current = runtime.fs.lstat(archive_temp);
				let authenticated = archive_temp_identity != null ?
					same_file(archive_temp_identity, current) :
					(current?.type == 'file' && current.nlink == 1 && current.mode == 0o600 &&
					 (current.uid == null || current.uid == 0));
				if (authenticated && runtime.fs.realpath(archive_temp) == archive_temp)
					runtime.fs.unlink(archive_temp);
			}
			catch (ignore) {}
		if (!published_archive && sidecar_path != null && sidecar_identity != null)
			try {
				if (same_file(sidecar_identity, runtime.fs.lstat(sidecar_path)) &&
				    runtime.fs.realpath(sidecar_path) == sidecar_path)
					runtime.fs.unlink(sidecar_path);
			}
			catch (ignore) {}
		remove_staging(runtime, staging, [ ...files, ...staged ], staging_identity);
		let code = errors.normalize(error).code;
		errors.fail(code == 'RESPONSE_TOO_LARGE' || code == 'INVALID_ARGUMENT' ? code : 'INTERNAL');
	}
};

export function create(app, options, source) {
	try { return create_impl(app, options, source); }
	catch (error) { errors.fail(errors.normalize(error).code); }
};

function inspection_record(app, inspected_id) {
	let runtime = validate_app(app, []);
	if (!valid_id(inspected_id, 'x')) invalid();
	let root = INSPECT_ROOT + '/' + inspected_id;
	let root_stat = runtime.fs.lstat(root);
	if (root_stat == null) errors.fail('NOT_FOUND');
	if (root_stat.type != 'directory' || runtime.fs.realpath(root) != root ||
	    root_stat.mode != 0o700 || (root_stat.uid != null && root_stat.uid != 0))
		errors.fail('CORRUPT_STATE');
	let report_capture, report;
	try {
		report_capture = secure_read(runtime, root + '/.inspection.json', MAX_REPORT);
		report = json(report_capture.content);
	}
	catch (error) { errors.fail('CORRUPT_STATE'); }
	let fields = {
		schema: true, id: true, source_id: true, inspected_at: true, expires_at: true,
		archive_size: true, archive_sha256: true, archive_inode: true,
		archive_dev_major: true, archive_dev_minor: true, manifest: true, files: true
	};
	let file_fields = {
		path: true, size: true, sha256: true, secret: true,
		inode: true, dev_major: true, dev_minor: true
	};
	if (report_capture.content != sprintf('%J\n', report) ||
	    !exact_fields(report, fields) || report.schema != 1 || report.id != inspected_id ||
	    (!valid_id(report.source_id, 'b') && !valid_id(report.source_id, 'i')) ||
	    type(report.inspected_at) != 'int' || report.inspected_at < 0 ||
	    type(report.expires_at) != 'int' || report.expires_at <= report.inspected_at ||
	    report.expires_at - report.inspected_at != INSPECTION_TTL ||
	    type(report.archive_size) != 'int' || report.archive_size < 1 ||
	    report.archive_size > MAX_ARCHIVE ||
	    type(report.archive_sha256) != 'string' ||
	    !match(report.archive_sha256, /^[0-9a-f]{64}$/) ||
	    type(report.archive_inode) != 'int' || type(report.archive_dev_major) != 'int' ||
	    type(report.archive_dev_minor) != 'int' || type(report.files) != 'array')
		errors.fail('CORRUPT_STATE');
	let headers = { 'manifest.json': { size: 0 } };
	for (let file in report.manifest?.files ?? []) headers[file.path] = { size: file.size };
	let manifest;
	try { manifest = validate_manifest(report.manifest, headers); }
	catch (error) { errors.fail('CORRUPT_STATE'); }
	if (length(report.files) != length(manifest.files)) errors.fail('CORRUPT_STATE');
	if (runtime.clock.now() > report.expires_at) {
		let cleanup = [ { path: '.inspection.json' }, { path: 'manifest.json' } ];
		for (let file in manifest.files) push(cleanup, { path: file.path });
		remove_staging(runtime, root, cleanup, root_stat);
		errors.fail('NOT_FOUND');
	}
	let staged_manifest;
	try { staged_manifest = secure_read(runtime, root + '/manifest.json', MAX_MANIFEST); }
	catch (error) { errors.fail('CORRUPT_STATE'); }
	let decoded_manifest;
	try { decoded_manifest = json(staged_manifest.content); }
	catch (error) { errors.fail('CORRUPT_STATE'); }
	if (staged_manifest.identity.mode != 0o400 ||
	    sprintf('%J', decoded_manifest) != sprintf('%J', manifest))
		errors.fail('CORRUPT_STATE');
	let contents = {}, expected = [ '.inspection.json', 'manifest.json' ];
	for (let index, captured in report.files) {
		let file = manifest.files[index];
		if (!exact_fields(captured, file_fields) || captured.path != file.path ||
		    captured.size != file.size || captured.sha256 != file.sha256 ||
		    captured.secret !== file.secret || type(captured.inode) != 'int' ||
		    type(captured.dev_major) != 'int' || type(captured.dev_minor) != 'int')
			errors.fail('CORRUPT_STATE');
		let current;
		try { current = secure_read(runtime, root + '/' + file.path, MAX_MEMBER); }
		catch (error) { errors.fail('CORRUPT_STATE'); }
		if (current.size != captured.size || current.sha256 != captured.sha256 ||
		    current.identity.mode != 0o400 || current.identity.inode != captured.inode ||
		    current.identity.dev?.major != captured.dev_major ||
		    current.identity.dev?.minor != captured.dev_minor)
			errors.fail('CORRUPT_STATE');
		contents[file.path] = current.content;
		push(expected, file.path);
	}
	let found = [];
	tree_files(runtime, root, '', found, { remaining: MAX_FILES * 2 + 8 });
	if (sprintf('%J', sorted(found)) != sprintf('%J', sorted(expected)))
		errors.fail('CORRUPT_STATE');
	return { root, report, manifest, contents };
};

function validate_restore_app(app) {
	validate_app(app, [ 'create', 'list', 'extract' ]);
	if (type(app.config?.validate_in_operation) != 'function' ||
	    type(app.rulesets?.validate) != 'function' ||
	    type(app.settings?.validate_patch) != 'function' ||
	    type(app.settings?.save) != 'function' || type(app.settings?.load) != 'function' ||
	    type(app.operations?.submit) != 'function' ||
	    type(app.lock?.with_lock) != 'function' || type(app.reconcile?.run) != 'function')
		invalid();
};

function validate_restore_contents(app, ctx, inspected) {
	let settings_patch = null;
	for (let file in inspected.manifest.files) {
		let content = inspected.contents[file.path];
		if (substr(file.path, 0, 8) == 'configs/') {
			let profile = substr(file.path, 8);
			let result = app.config.validate_in_operation(ctx, profile, content);
			if (result?.ok !== true) errors.fail('VALIDATION_FAILED');
		}
		else if (substr(file.path, 0, 9) == 'rulesets/') {
			let name = substr(file.path, 9);
			if (app.rulesets.validate(name, content) !== true)
				errors.fail('VALIDATION_FAILED');
		}
		else if (file.path == 'settings/settings.json') {
			try { settings_patch = json(content); }
			catch (error) { errors.fail('VALIDATION_FAILED'); }
			if (content != sprintf('%J\n', settings_patch))
				errors.fail('VALIDATION_FAILED');
			try { settings_patch = app.settings.validate_patch(settings_patch); }
			catch (error) { errors.fail('VALIDATION_FAILED'); }
		}
		else errors.fail('VALIDATION_FAILED');
	}
	return settings_patch;
};

function inspect_impl(app, source_id, options) {
	validate_options(options, {});
	let runtime = validate_app(app, [ 'list', 'extract' ]);
	let source = source_record(app, source_id), entries, headers;
	try { entries = app.archive.list({ archive: source.archive_path }); }
	catch (error) { errors.fail('CORRUPT_STATE'); }
	headers = validate_entries(entries);
	let after_listing;
	try { after_listing = secure_read(runtime, source.archive_path, MAX_ARCHIVE); }
	catch (error) { errors.fail('CORRUPT_STATE'); }
	if (!same_capture(source.archive, after_listing)) errors.fail('CORRUPT_STATE');

	ensure_directory(runtime, INSPECT_ROOT);
	let now = runtime.clock.now(), nonce = runtime.random.hex(16);
	if (type(now) != 'int' || now < 0 || !match(nonce, /^[0-9a-f]{32}$/)) internal();
	let id = sprintf('x-%013d-%s', now, nonce), staging = INSPECT_ROOT + '/' + id;
	if (runtime.fs.lstat(staging) != null) internal();
	let staging_identity = ensure_directory(runtime, staging);
	let cleanup = [], keep = false;
	try {
		push(cleanup, { path: 'manifest.json' });
		try {
			if (app.archive.extract({
				archive: source.archive_path, destination: staging,
				members: [ 'manifest.json' ]
			}) !== true) errors.fail('CORRUPT_STATE');
		}
		catch (error) { errors.fail('CORRUPT_STATE'); }
		let manifest_capture;
		try { manifest_capture = secure_read(runtime, staging + '/manifest.json', MAX_MANIFEST); }
		catch (error) { errors.fail('CORRUPT_STATE'); }
		if (manifest_capture.size != headers['manifest.json'].size)
			errors.fail('VALIDATION_FAILED');
		let manifest;
		try { manifest = json(manifest_capture.content); }
		catch (error) { errors.fail('VALIDATION_FAILED'); }
		if (manifest_capture.content != sprintf('%J\n', manifest))
			errors.fail('VALIDATION_FAILED');
		manifest = validate_manifest(manifest, headers);
		if (source.sidecar.created_at != manifest.created_at ||
		    source.sidecar.app_version != manifest.app_version ||
		    source.sidecar.file_count != length(manifest.files) ||
		    sprintf('%J', source.sidecar.includes) != sprintf('%J', manifest.includes))
			errors.fail('VALIDATION_FAILED');

		let names = [];
		for (let file in manifest.files) {
			push(names, file.path);
			push(cleanup, { path: file.path });
		}
		try {
			if (app.archive.extract({
				archive: source.archive_path, destination: staging, members: names
			}) !== true) errors.fail('CORRUPT_STATE');
		}
		catch (error) { errors.fail('CORRUPT_STATE'); }
		let after_extract;
		try { after_extract = secure_read(runtime, source.archive_path, MAX_ARCHIVE); }
		catch (error) { errors.fail('CORRUPT_STATE'); }
		if (!same_capture(source.archive, after_extract)) errors.fail('CORRUPT_STATE');

		let expected = [ 'manifest.json' ], captured = [];
		for (let file in manifest.files) {
			push(expected, file.path);
			push(captured, capture_file(runtime, staging, file));
		}
		let manifest_locked = secure_read(runtime, staging + '/manifest.json', MAX_MANIFEST);
		if (manifest_locked.identity.mode != 0o400 ||
		    manifest_locked.sha256 != manifest_capture.sha256)
			errors.fail('CORRUPT_STATE');
		let found = [];
		tree_files(runtime, staging, '', found, { remaining: MAX_FILES * 2 + 8 });
		if (sprintf('%J', sorted(found)) != sprintf('%J', sorted(expected)))
			errors.fail('CORRUPT_STATE');

		let report = {
			schema: 1, id, source_id, inspected_at: now, expires_at: now + INSPECTION_TTL,
			archive_size: source.archive.size, archive_sha256: source.archive.sha256,
			archive_inode: source.archive.identity.inode,
			archive_dev_major: source.archive.identity.dev?.major,
			archive_dev_minor: source.archive.identity.dev?.minor,
			manifest, files: captured
		};
		storage.write_json(runtime, staging + '/.inspection.json', report, 0o600);
		push(cleanup, { path: '.inspection.json' });
		keep = true;
		return {
			id, source_id, created_at: manifest.created_at, inspected_at: now,
			expires_at: report.expires_at, app_version: manifest.app_version,
			includes: clone(manifest.includes), files: clone(manifest.files)
		};
	}
	catch (error) {
		if (!keep) remove_staging(runtime, staging, cleanup, staging_identity);
		let code = errors.normalize(error).code;
		if (code == 'RESPONSE_TOO_LARGE' || code == 'VALIDATION_FAILED') errors.fail(code);
		errors.fail(code == 'NOT_FOUND' || code == 'INVALID_ARGUMENT' ? code : 'CORRUPT_STATE');
	}
};

export function inspect(app, source_id, options) {
	try { return inspect_impl(app, source_id, options); }
	catch (error) { errors.fail(errors.normalize(error).code); }
};

export function restore(app, inspected_id, options, source) {
	validate_options(options, {});
	if (!valid_id(inspected_id, 'x')) invalid();
	source ??= 'system';
	if (!exists({ luci: true, telegram: true, auto: true, system: true }, source)) invalid();
	validate_restore_app(app);
	try {
		return app.operations.submit('backup.restore', source,
			{ inspection_id: inspected_id }, (ctx) => app.lock.with_lock(
				app.runtime, { barrier: 'normal', wait_ms: 0 }, () => {
					ctx.stage('validating', 10, 'Validating backup');
					let inspected = inspection_record(app, inspected_id);
					let settings_patch = validate_restore_contents(app, ctx, inspected);
					ctx.stage('snapshot', 30, 'Creating recovery snapshot');
					let snapshot = create(app, { include_secrets: true }, 'system');
					ctx.stage('committing', 60, 'Committing configuration');
					ensure_directory(app.runtime, '/opt/clash/lst');
					for (let file in inspected.manifest.files) {
						let destination = null;
						if (substr(file.path, 0, 8) == 'configs/')
							destination = '/opt/clash/' + substr(file.path, 8);
						else if (substr(file.path, 0, 9) == 'rulesets/')
							destination = '/opt/clash/lst/' + substr(file.path, 9);
						if (destination != null)
							storage.atomic_write(app.runtime, destination,
								inspected.contents[file.path], 0o600);
					}
					if (settings_patch != null) app.settings.save(app.runtime, settings_patch);
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
	let runtime = validate_app(app, []), retain = options.retain;
	if (retain == null) {
		if (type(app.settings?.load) != 'function') invalid();
		retain = app.settings.load(runtime)?.backup?.retention;
	}
	if (type(retain) != 'int' || retain < 1 || retain > 100) invalid();
	let records = list_records(app), removed = [];
	while (length(records) > retain) {
		let item = shift(records), current = source_record(app, item.id);
		let archive_path = BACKUP_ROOT + '/' + item.id + '.tar';
		let sidecar_path = BACKUP_ROOT + '/' + item.id + '.json';
		let tomb_archive = BACKUP_ROOT + '/.prune-' + item.id + '.tar';
		let tomb_sidecar = BACKUP_ROOT + '/.prune-' + item.id + '.json';
		if (runtime.fs.lstat(tomb_archive) != null || runtime.fs.lstat(tomb_sidecar) != null)
			internal();
		let before_archive = runtime.fs.lstat(archive_path);
		let before_sidecar = runtime.fs.lstat(sidecar_path);
		if (!same_file(before_archive, current.archive.identity) ||
		    !same_file(before_sidecar, current.sidecar_capture.identity) ||
		    runtime.fs.realpath(archive_path) != archive_path ||
		    runtime.fs.realpath(sidecar_path) != sidecar_path)
			errors.fail('CORRUPT_STATE');
		if (runtime.fs.rename(sidecar_path, tomb_sidecar) != true) internal();
		if (runtime.fs.rename(archive_path, tomb_archive) != true) internal();
		let moved_sidecar = runtime.fs.lstat(tomb_sidecar);
		let moved_archive = runtime.fs.lstat(tomb_archive);
		if (!same_file(before_sidecar, moved_sidecar) || !same_file(before_archive, moved_archive) ||
		    runtime.fs.realpath(tomb_sidecar) != tomb_sidecar ||
		    runtime.fs.realpath(tomb_archive) != tomb_archive)
			errors.fail('CORRUPT_STATE');
		try {
			if (runtime.fs.unlink(tomb_archive) == true)
				runtime.fs.unlink(tomb_sidecar);
		}
		catch (error) {}
		push(removed, item.id);
	}
	recover_prunes(runtime);
	let retained = [];
	for (let item in records) push(retained, item.id);
	return { removed, retained };
};

export function prune(app, options) {
	try { return prune_impl(app, options); }
	catch (error) { errors.fail(errors.normalize(error).code); }
};
