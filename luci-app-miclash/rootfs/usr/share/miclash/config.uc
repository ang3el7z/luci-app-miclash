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

function healthy(service, profile, controller_config) {
	try {
		if (type(service.recover) == 'function')
			return service.recover(profile, controller_config)?.ok === true;
		let reloaded = service.reload(profile, controller_config);
		if (reloaded !== true && reloaded?.ok !== true)
			return false;
		let ready = service.health(profile);
		return ready === true || ready?.ok === true;
	}
	catch (error) {
		return false;
	}
};

export function create(runtime, operations) {
	if (type(runtime?.fs) != 'object' || type(runtime?.process?.run) != 'function' ||
	    type(runtime?.digest?.sha256) != 'function' ||
	    type(runtime?.digest?.sha256_file) != 'function' ||
	    type(runtime?.service?.reload) != 'function' ||
	    type(runtime?.service?.health) != 'function' || type(operations?.submit) != 'function' ||
	    type(operations?.is_context) != 'function')
		errors.fail('INVALID_ARGUMENT');

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
	function tracking_path(profile) {
		return '/opt/clash/.miclash-active-' + schema.profile_name(profile) + '.json';
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
		storage.write_json(runtime, tracking_path(profile), {
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
	function activation(ctx, profile, content) {
		return with_candidate(ctx, profile, content, (candidate, candidate_hash) => {
			let previous = read_active_state(profile);
			assert_active_state(profile, previous);
			storage.atomic_write(runtime, active_path(profile), candidate, 0o600);
			record_active(profile, candidate_hash, ctx.id);
			if (!healthy(runtime.service, profile, previous.content)) {
				let rolled_back = false;
				try {
					storage.atomic_write(runtime, active_path(profile), previous.content, 0o600);
					record_active(profile, previous.hash, ctx.id);
					rolled_back = healthy(runtime.service, profile, candidate);
				}
				catch (rollback_error) { rolled_back = false; }
				return {
					ok: false,
					activated: true,
					reload_ok: false,
					error: errors.new(rolled_back ? 'HEALTH_FAILED' : 'INTERNAL',
						rolled_back ? 'HEALTH_FAILED' : 'INTERNAL', { profile })
				};
			}
			return { ok: true, activated: true, reload_ok: true };
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
	function operation_context(ctx) {
		if (operations.is_context(ctx) !== true)
			errors.fail('INVALID_ARGUMENT');
		return ctx;
	};

	let api = {};
	api.list_profiles = () => [ ...PROFILES ];
	api.read_active = read_active;
	api.validate_in_operation = (ctx, profile, content) => {
		operation_context(ctx);
		return with_candidate(ctx, profile, content, () => ({ ok: true }));
	};
	api.apply_in_operation = (ctx, profile, content) => {
		operation_context(ctx);
		return activation(ctx, profile, content);
	};
	api.apply_transaction_in_operation = (ctx, profile, content, source, extra, transaction) => {
		operation_context(ctx);
		profile = schema.profile_name(profile);
		if (type(transaction) != 'object' || length(keys(transaction)) != 3 ||
		    type(transaction.prepare) != 'function' || type(transaction.commit) != 'function' ||
		    type(transaction.rollback) != 'function') errors.fail('INVALID_ARGUMENT');
		return with_candidate(ctx, profile, content, (candidate, candidate_hash) => {
			let previous = read_active_state(profile);
			let prepared;
			ctx.stage('transaction-prepare', 78, 'Preparing coupled durable state');
			try { prepared = transaction.prepare(); }
			catch (error) {
				let failed = false;
				try { if (transaction.rollback(prepared) !== true) failed = true; }
				catch (rollback_error) { failed = true; }
				return { ok: false, activated: false, reload_ok: false,
					error: errors.new(failed ? 'INTERNAL' : errors.normalize(error).code) };
			}
			let activated = false;
			function rollback(code) {
				let failed = false;
				if (activated) {
					try {
						storage.atomic_write(runtime, active_path(profile), previous.content, 0o600);
						record_active(profile, previous.hash, ctx.id);
					}
					catch (error) { failed = true; }
				}
				try { if (transaction.rollback(prepared) !== true) failed = true; }
				catch (error) { failed = true; }
				if (activated && !failed && !healthy(runtime.service, profile, candidate))
					failed = true;
				return errors.new(failed ? 'INTERNAL' : code, failed ? 'INTERNAL' : code, { profile });
			};
			try {
				ctx.stage('transaction-activate', 82, 'Activating coupled configuration');
				assert_active_state(profile, previous);
				storage.atomic_write(runtime, active_path(profile), candidate, 0o600);
				record_active(profile, candidate_hash, ctx.id);
				activated = true;
			}
			catch (error) {
				let failure = rollback(errors.normalize(error).code);
				return { ok: false, activated, reload_ok: false, error: failure };
			}
			if (!healthy(runtime.service, profile, previous.content)) {
				let failure = rollback('HEALTH_FAILED');
				return { ok: false, activated: true, reload_ok: false, error: failure };
			}
			try {
				ctx.stage('transaction-finalize', 90, 'Finalizing coupled durable state');
				if (transaction.commit(prepared) !== true) errors.fail('INTERNAL');
				ctx.stage('transaction-finalized', 91, 'Coupled durable state finalized');
			}
			catch (error) {
				let failure = rollback(errors.normalize(error).code);
				return { ok: false, activated: true, reload_ok: false, error: failure };
			}
			ctx.stage('transaction-committed', 92, 'Coupled transaction committed');
			return { ok: true, activated: true, reload_ok: true };
		});
	};
	api.validate = (profile, content, source) => submit(
		'config.validate', source, profile, (ctx) => complete_result(ctx,
			api.validate_in_operation(ctx, profile, content)));
	api.apply = (profile, content, source) => submit(
		'config.apply', source, profile, (ctx) => complete_result(ctx,
			api.apply_in_operation(ctx, profile, content, source)));
	api.apply_operational = (profile, content, source, transaction) => {
		if (type(transaction) != 'object' || length(keys(transaction)) != 3 ||
		    type(transaction.prepare) != 'function' ||
		    type(transaction.commit) != 'function' ||
		    type(transaction.rollback) != 'function')
			errors.fail('INVALID_ARGUMENT');
		return submit('settings.apply', source, profile, (ctx) => {
			return complete_result(ctx, with_candidate(ctx, profile, content,
				(candidate, candidate_hash) => {
					let previous = read_active_state(profile);
					let prepared = transaction.prepare();
					assert_active_state(profile, previous);
					storage.atomic_write(runtime, active_path(profile), candidate, 0o600);
					record_active(profile, candidate_hash, ctx.id);
					let failure = null;
					try {
						if (transaction.commit(prepared) !== true)
							errors.fail('INTERNAL');
					}
					catch (error) { failure = errors.normalize(error).code; }
					let rollback = () => {
						let failed = false;
						try {
							storage.atomic_write(runtime, active_path(profile), previous.content, 0o600);
							record_active(profile, previous.hash, ctx.id);
						}
						catch (error) { failed = true; }
						// Commit may have changed persistent state before throwing, so
						// rollback is required for both complete and partial commits.
						try {
							if (transaction.rollback(prepared) !== true) failed = true;
						}
						catch (error) { failed = true; }
						return !failed;
					};
					if (failure != null) {
						let rolled_back = rollback();
						return { ok: false, activated: true, reload_ok: false,
							error: errors.new(rolled_back ? failure : 'INTERNAL',
								rolled_back ? failure : 'INTERNAL', { profile }) };
					}
					if (!healthy(runtime.service, profile, previous.content)) {
						let rolled_back = rollback();
						if (rolled_back) healthy(runtime.service, profile, candidate);
						return { ok: false, activated: true, reload_ok: false,
							error: errors.new(rolled_back ? 'HEALTH_FAILED' : 'INTERNAL',
								rolled_back ? 'HEALTH_FAILED' : 'INTERNAL', { profile }) };
					}
					return { ok: true, activated: true, reload_ok: true };
				}));
		});
	};
	api.swap = (profile, source, transaction) => {
		profile = schema.profile_name(profile);
		if (profile == 'config.yaml')
			errors.fail('INVALID_ARGUMENT');
		if (transaction != null && (type(transaction) != 'object' ||
		    length(keys(transaction)) != 3 || type(transaction.prepare) != 'function' ||
		    type(transaction.commit) != 'function' ||
		    type(transaction.rollback) != 'function'))
			errors.fail('INVALID_ARGUMENT');
		return operations.submit('config.swap', source, {
			profile: 'config.yaml', selected_profile: profile
		}, (ctx) => {
			let main = read_active_state('config.yaml');
			let selected = read_active_state(profile);
			let checked = with_candidate(ctx, 'config.yaml', selected.content,
				() => ({ ok: true }));
			if (!complete_result(ctx, checked))
				return false;
			checked = with_candidate(ctx, profile, main.content, () => ({ ok: true }));
			if (!complete_result(ctx, checked))
				return false;
			let transaction_state = transaction != null ? transaction.prepare() : null;

			assert_active_state('config.yaml', main);
			assert_active_state(profile, selected);

			let transaction_attempted = false;
			let rollback = () => {
				let failed = false;
				try {
					storage.atomic_write(runtime, active_path('config.yaml'), main.content, 0o600);
					record_active('config.yaml', main.hash, ctx.id);
					storage.atomic_write(runtime, active_path(profile), selected.content, 0o600);
					record_active(profile, selected.hash, ctx.id);
				}
				catch (error) { failed = true; }
				if (transaction_attempted)
					try {
						if (transaction.rollback(transaction_state) !== true) failed = true;
					}
					catch (error) { failed = true; }
				return !failed;
			};
			let write_failed = false;
			try {
				storage.atomic_write(runtime, active_path(profile), main.content, 0o600);
				record_active(profile, main.hash, ctx.id);
				assert_active_state('config.yaml', main);
				storage.atomic_write(runtime, active_path('config.yaml'), selected.content, 0o600);
				record_active('config.yaml', selected.hash, ctx.id);
				if (transaction != null) {
					transaction_attempted = true;
					if (transaction.commit(transaction_state) !== true)
						errors.fail('INTERNAL');
				}
			}
			catch (error) {
				write_failed = true;
			}
			if (write_failed) {
				let rolled_back = rollback();
				errors.fail('INTERNAL');
			}

			let reload = true;
			if (type(runtime.service.observe) == 'function') {
				try {
					let observed = runtime.service.observe('config.yaml');
					reload = observed?.state != 'stopped' && observed?.state != 'missing_kernel';
				}
				catch (error) { reload = true; }
			}
			if (reload && !healthy(runtime.service, 'config.yaml', main.content)) {
				let rolled_back = rollback();
				if (rolled_back)
					healthy(runtime.service, 'config.yaml', selected.content);
				ctx.complete(errors.new(rolled_back ? 'HEALTH_FAILED' : 'INTERNAL',
					rolled_back ? 'HEALTH_FAILED' : 'INTERNAL', {
					profile: 'config.yaml', selected_profile: profile
				}));
				return false;
			}
			return true;
		});
	};
	api.detect_external = (profile) => {
		profile = schema.profile_name(profile);
		let content = read_active(profile);
		let hash = runtime.digest.sha256(content);
		let tracked = null;
		try { tracked = storage.read_json(runtime, tracking_path(profile)); }
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
					let converged = false;
					try {
						converged = type(runtime.reconcile?.external) == 'function'
							? runtime.reconcile.external('external-config-adopt') === true
							: healthy(runtime.service, profile, external.content);
					}
					catch (error) { converged = false; }
					if (!converged) errors.fail('HEALTH_FAILED');
					assert_active_state(profile, external);
					record_active(profile, external.hash, ctx.id);
					return { ok: true };
				}));
		});

	return api;
};
