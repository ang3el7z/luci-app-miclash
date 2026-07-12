import * as errors from 'miclash.errors';
import * as redact from 'miclash.redact';
import * as schema from 'miclash.schema';
import * as storage from 'miclash.storage';

const PROFILES = [ 'config.yaml', 'config2.yaml', 'config3.yaml' ];
const MIHOMO = '/opt/clash/bin/clash';
const VALIDATION_TIMEOUT = 30000;

function same_identity(left, right) {
	return left?.type == 'file' && right?.type == 'file' && left.nlink == 1 &&
	       right.nlink == 1 && left.inode == right.inode && left.size == right.size &&
	       left.dev?.major == right.dev?.major && left.dev?.minor == right.dev?.minor;
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

function safe_validation_output(output) {
	if (type(output) != 'string')
		return '';
	let safe = [];
	for (let line in split(output, '\n')) {
		let lowered = lc(line);
		if (match(lowered, /(secret|token|password|passwd|credential|authorization|cookie|bearer|api[-_ ]?key|access[-_ ]?key|private[-_ ]?key|subscription|proxy|username)/))
			push(safe, '[REDACTED]');
		else
			push(safe, redact.text(line));
	}
	return join('\n', safe);
};

export function create(runtime, operations, history) {
	if (type(runtime?.fs) != 'object' || type(runtime?.process?.run) != 'function' ||
	    type(runtime?.digest?.sha256) != 'function' ||
	    type(runtime?.digest?.sha256_file) != 'function' ||
	    type(runtime?.service?.reload) != 'function' ||
	    type(runtime?.service?.health) != 'function' || type(operations?.submit) != 'function' ||
	    type(history?.snapshot) != 'function' || type(history?.list) != 'function')
		errors.fail('INVALID_ARGUMENT');

	ensure_directory(runtime, '/opt/clash/history');
	ensure_directory(runtime, '/opt/clash/history/drafts');

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
	function record_active(profile, hash, operation_id) {
		storage.write_json(runtime, revision_path(profile), {
			profile,
			hash,
			operation_id,
			updated_at: runtime.clock.now()
		}, 0o600);
	};
	function validation_error(response) {
		return errors.new('VALIDATION_FAILED', 'VALIDATION_FAILED', {
			output: safe_validation_output(response.stdout),
			truncated: response.truncated === true
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
		if (runtime.fs.chmod(directory, 0o700) != true ||
		    runtime.fs.lstat(directory)?.type != 'directory' ||
		    runtime.fs.realpath(directory) != directory)
			errors.fail('INTERNAL');
		let candidate = directory + '/config.yaml';
		let outcome = null;
		let failure = null;
		try {
			storage.atomic_write(runtime, candidate, content, 0o600);
			let identity = runtime.fs.lstat(candidate);
			let hash = runtime.digest.sha256(content);
			if (identity?.type != 'file' || identity.nlink != 1 ||
			    runtime.fs.realpath(candidate) != candidate ||
			    runtime.digest.sha256_file(candidate) != hash)
				errors.fail('INTERNAL');
			let response = runtime.process.run({
				command: MIHOMO,
				args: [ '-d', '/opt/clash', '-f', candidate, '-t' ],
				timeout_ms: VALIDATION_TIMEOUT,
				capture_limit: 8192
			});
			if (response.code != 0)
				outcome = { ok: false, error: validation_error(response) };
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
			if (runtime.fs.unlink(candidate) != true)
				cleanup_failed = true;
		}
		catch (unlink_error) { cleanup_failed = true; }
		try {
			if (runtime.fs.rmdir(directory) != true)
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
			let external = read_active(profile);
			let external_hash = runtime.digest.sha256(external);
			return complete_result(ctx, with_candidate(ctx, profile, external,
				(candidate, candidate_hash) => {
					let current = read_active(profile);
					if (runtime.digest.sha256(current) != external_hash ||
					    candidate_hash != external_hash)
						errors.fail('INTERNAL');
					history.snapshot(profile, 'external', {
						validation_result: 'success',
						activation_result: 'adopted',
						operation_id: ctx.id
					});
					record_active(profile, external_hash, ctx.id);
					return { ok: true };
				}));
		});

	return api;
};
