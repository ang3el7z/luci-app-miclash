import * as errors from 'miclash.errors';
import * as schema from 'miclash.schema';
import * as storage from 'miclash.storage';

const PROFILES = [ 'config.yaml', 'config2.yaml', 'config3.yaml' ];
const VALIDATION_HELPER = '/usr/libexec/miclash/validate-config.uc';

function same_node(left, right) {
	return left?.type != null && left.type == right?.type && left.inode == right?.inode &&
	       left.dev?.major == right.dev?.major && left.dev?.minor == right.dev?.minor;
};

function same_identity(left, right) {
	return left?.type == 'file' && right?.type == 'file' && left.nlink == 1 &&
	       right.nlink == 1 && left.size == right.size && same_node(left, right);
};

function ensure_directory(runtime, path) {
	let stat = runtime.fs.lstat(path);
	if (stat == null && runtime.fs.mkdir(path) != true)
		errors.fail('INTERNAL');
	stat = runtime.fs.lstat(path);
	if (stat?.type != 'directory' || runtime.fs.realpath(path) != path ||
	    runtime.fs.chmod(path, 0o700) != true)
		errors.fail('INTERNAL');
};

function healthy(service, profile) {
	try {
		let reloaded = service.reload(profile);
		if (reloaded !== true && reloaded?.ok !== true)
			return false;
		let ready = service.health(profile);
		return ready === true || ready?.ok === true;
	}
	catch (error) {
		return false;
	}
};

export function create(runtime, operations, history) {
	if (type(runtime?.fs) != 'object' || type(runtime?.process?.run) != 'function' ||
	    type(runtime?.digest?.sha256) != 'function' ||
	    type(runtime?.digest?.sha256_file) != 'function' ||
	    type(runtime?.service?.reload) != 'function' ||
	    type(runtime?.service?.health) != 'function' || type(operations?.submit) != 'function' ||
	    type(history?.snapshot) != 'function' || type(history?.snapshot_bytes) != 'function' ||
	    type(history?.list) != 'function')
		errors.fail('INVALID_ARGUMENT');

	ensure_directory(runtime, '/opt/clash/history');
	ensure_directory(runtime, '/opt/clash/history/drafts');
	ensure_directory(runtime, runtime.paths.tmp + '/candidates');
	let candidates = runtime.paths.tmp + '/candidates';
	let stale_names = runtime.fs.lsdir(candidates);
	if (type(stale_names) != 'array')
		errors.fail('INTERNAL');
	for (let name in stale_names) {
		try { schema.operation_id(name); }
		catch (error) { continue; }
		let directory = candidates + '/' + name;
		let stat = runtime.fs.lstat(directory);
		if (stat?.type != 'directory' || runtime.fs.realpath(directory) != directory)
			continue;
		let entries = runtime.fs.lsdir(directory);
		if (type(entries) != 'array')
			errors.fail('INTERNAL');
		if (length(entries) != 1 || entries[0] != 'config.yaml')
			continue;
		let candidate = directory + '/config.yaml';
		let candidate_stat = runtime.fs.lstat(candidate);
		if (candidate_stat?.type != 'file' || candidate_stat.nlink != 1 ||
		    runtime.fs.realpath(candidate) != candidate)
			continue;
		let current_directory = runtime.fs.lstat(directory);
		let current_candidate = runtime.fs.lstat(candidate);
		if (!same_node(stat, current_directory) ||
		    !same_identity(candidate_stat, current_candidate) ||
		    runtime.fs.realpath(directory) != directory ||
		    runtime.fs.realpath(candidate) != candidate)
			errors.fail('INTERNAL');
		if (runtime.fs.unlink(candidate) != true)
			errors.fail('INTERNAL');
		current_directory = runtime.fs.lstat(directory);
		entries = runtime.fs.lsdir(directory);
		if (!same_node(stat, current_directory) ||
		    runtime.fs.realpath(directory) != directory ||
		    type(entries) != 'array' || length(entries) != 0 ||
		    runtime.fs.rmdir(directory) != true)
			errors.fail('INTERNAL');
	}

	function active_path(profile) {
		return '/opt/clash/' + schema.profile_name(profile);
	};
	function draft_path(profile) {
		return '/opt/clash/history/drafts/' + schema.profile_name(profile);
	};
	function revision_path(profile) {
		return '/opt/clash/history/active-' + schema.profile_name(profile) + '.json';
	};
	function read_active(profile) {
		let path = active_path(profile);
		let stat = runtime.fs.lstat(path);
		let content = runtime.fs.readfile(path);
		if (stat?.type != 'file' || stat.nlink != 1 || runtime.fs.realpath(path) != path ||
		    type(content) != 'string')
			errors.fail('NOT_FOUND');
		return content;
	};
	function read_active_state(profile) {
		let path = active_path(profile);
		let before = runtime.fs.lstat(path);
		let content = runtime.fs.readfile(path);
		let after = runtime.fs.lstat(path);
		let hash = type(content) == 'string' ? runtime.digest.sha256(content) : null;
		if (!same_identity(before, after) || runtime.fs.realpath(path) != path ||
		    hash == null || runtime.digest.sha256_file(path) != hash)
			errors.fail('INTERNAL');
		return { identity: after, content, hash };
	};
	function assert_active_state(profile, expected) {
		let current;
		try { current = read_active_state(profile); }
		catch (error) { errors.fail('INTERNAL'); }
		if (!same_identity(expected.identity, current.identity) || expected.hash != current.hash)
			errors.fail('INTERNAL');
	};
	function record_active(profile, hash, operation_id) {
		storage.write_json(runtime, revision_path(profile), {
			profile,
			hash,
			operation_id,
			updated_at: runtime.clock.now()
		}, 0o600);
	};
	function validation_error(profile) {
		return errors.new('VALIDATION_FAILED', 'VALIDATION_FAILED', {
			profile
		});
	};
	function with_candidate(ctx, profile, content, callback) {
		if (type(content) != 'string' || !length(content))
			errors.fail('INVALID_ARGUMENT');
		profile = schema.profile_name(profile);
		ensure_directory(runtime, runtime.paths.tmp + '/candidates');
		let directory = runtime.paths.tmp + '/candidates/' + schema.operation_id(ctx.id);
		if (runtime.fs.lstat(directory) != null || runtime.fs.mkdir(directory) != true)
			errors.fail('INTERNAL');
		let directory_identity = runtime.fs.lstat(directory);
		if (runtime.fs.chmod(directory, 0o700) != true ||
		    directory_identity?.type != 'directory' ||
		    runtime.fs.realpath(directory) != directory)
			errors.fail('INTERNAL');
		let candidate = directory + '/config.yaml';
		let identity = null;
		let outcome = null;
		let failure = null;
		try {
			storage.atomic_write(runtime, candidate, content, 0o600);
			identity = runtime.fs.lstat(candidate);
			let hash = runtime.digest.sha256(content);
			if (identity?.type != 'file' || identity.nlink != 1 ||
			    runtime.fs.realpath(candidate) != candidate ||
			    runtime.digest.sha256_file(candidate) != hash)
				errors.fail('INTERNAL');
			let helper = runtime.fs.lstat(VALIDATION_HELPER);
			if (helper?.type != 'file' || helper.nlink != 1 ||
			    runtime.fs.realpath(VALIDATION_HELPER) != VALIDATION_HELPER)
				errors.fail('INTERNAL');
			let response = runtime.process.run({
				command: '/usr/bin/ucode',
				args: [ '--', VALIDATION_HELPER, candidate ],
				timeout_ms: 0
			});
			if (type(response?.code) != 'int' || response.code < 0 ||
			    response.code == 125 || response.code >= 254)
				errors.fail('INTERNAL');
			if (response.code != 0)
				outcome = { ok: false, error: validation_error(profile) };
			else {
				let current = runtime.fs.lstat(candidate);
				let verified = runtime.fs.readfile(candidate);
				if (!same_identity(identity, current) || runtime.fs.realpath(candidate) != candidate ||
				    type(verified) != 'string' || runtime.digest.sha256(verified) != hash ||
				    runtime.digest.sha256_file(candidate) != hash)
					errors.fail('INTERNAL');
				outcome = callback(verified, hash);
			}
		}
		catch (error) {
			failure = errors.normalize(error).code;
		}
		let cleanup_failed = false;
		try {
			let current = runtime.fs.lstat(candidate);
			if (current != null &&
			    (!same_identity(identity, current) ||
			     runtime.fs.realpath(candidate) != candidate ||
			     runtime.fs.unlink(candidate) != true))
				cleanup_failed = true;
		}
		catch (unlink_error) { cleanup_failed = true; }
		try {
			let current = runtime.fs.lstat(directory);
			let entries = runtime.fs.lsdir(directory);
			if (!same_node(directory_identity, current) ||
			    runtime.fs.realpath(directory) != directory ||
			    type(entries) != 'array' || length(entries) != 0 ||
			    runtime.fs.rmdir(directory) != true)
				cleanup_failed = true;
		}
		catch (rmdir_error) { cleanup_failed = true; }
		if (cleanup_failed)
			failure = 'INTERNAL';
		if (failure != null)
			errors.fail(failure);
		return outcome;
	};
	function activation(ctx, profile, content, source, extra) {
		return with_candidate(ctx, profile, content, (candidate, candidate_hash) => {
			let snapshot = history.snapshot(profile, source, {
				validation_result: 'success',
				activation_result: 'pending',
				operation_id: ctx.id,
				...(extra ?? {})
			});
			storage.atomic_write(runtime, active_path(profile), candidate, 0o600);
			record_active(profile, candidate_hash, ctx.id);
			if (!healthy(runtime.service, profile)) {
				history.mark_activation(profile, snapshot.revision, 'health_failed');
				return { ok: false, error: errors.new('HEALTH_FAILED', 'HEALTH_FAILED', {
					profile, revision: snapshot.revision
				}) };
			}
			history.mark_activation(profile, snapshot.revision, 'success');
			return { ok: true };
		});
	};
	function submit(kind, source, profile, worker) {
		profile = schema.profile_name(profile);
		return operations.submit(kind, source, { profile }, worker);
	};
	function complete_result(ctx, result) {
		if (result?.ok === false) {
			ctx.complete(result.error);
			return false;
		}
		return true;
	};

	let api = {};
	api.list_profiles = () => [ ...PROFILES ];
	api.read_active = read_active;
	api.read_draft = (profile) => {
		let content = runtime.fs.readfile(draft_path(profile));
		return type(content) == 'string' ? content : null;
	};
	api.save_draft = (profile, content, source) => submit(
		'config.save_draft', source, profile, (ctx) => {
			if (type(content) != 'string')
				errors.fail('INVALID_ARGUMENT');
			storage.atomic_write(runtime, draft_path(profile), content, 0o600);
		});
	api.validate = (profile, content, source) => submit(
		'config.validate', source, profile, (ctx) => complete_result(ctx,
			with_candidate(ctx, profile, content, () => ({ ok: true }))));
	api.apply = (profile, content, source) => submit(
		'config.apply', source, profile, (ctx) => complete_result(ctx,
			activation(ctx, profile, content, source)));
	api.restore = (profile, revision, source) => {
		revision = schema.operation_id(revision);
		return submit('history.restore', source, profile, (ctx) => complete_result(ctx,
			activation(ctx, profile, history.read(profile, revision), 'restore', {
				restored_revision: revision
			})));
	};
	api.detect_external = (profile) => {
		profile = schema.profile_name(profile);
		let content = read_active(profile);
		let hash = runtime.digest.sha256(content);
		let tracked = null;
		try { tracked = storage.read_json(runtime, revision_path(profile)); }
		catch (error) {
			if ((error?.code ?? error?.message) != 'NOT_FOUND')
				errors.fail(errors.normalize(error).code);
		}
		return {
			changed: tracked == null || tracked.hash != hash,
			hash,
			expected_hash: tracked?.hash ?? null
		};
	};
	api.adopt_external = (profile, source) => submit(
		'config.external_adopt', source, profile, (ctx) => {
			let external = read_active_state(profile);
			return complete_result(ctx, with_candidate(ctx, profile, external.content,
				(candidate, candidate_hash) => {
					if (candidate_hash != external.hash)
						errors.fail('INTERNAL');
					assert_active_state(profile, external);
					history.snapshot_bytes(profile, 'external', candidate, {
						validation_result: 'success',
						activation_result: 'adopted',
						operation_id: ctx.id
					});
					assert_active_state(profile, external);
					record_active(profile, external.hash, ctx.id);
					return { ok: true };
				}));
		});

	return api;
};
