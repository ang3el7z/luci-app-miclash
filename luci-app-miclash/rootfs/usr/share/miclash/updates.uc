import * as errors from 'miclash.errors';
import * as http from 'miclash.http';
import * as storage from 'miclash.storage';

const MIHOMO_LATEST =
	'https://api.github.com/repos/MetaCubeX/mihomo/releases/latest';
const MIHOMO_RELEASES =
	'https://api.github.com/repos/MetaCubeX/mihomo/releases?per_page=20';
const MICLASH_LATEST =
	'https://api.github.com/repos/ang3el7z/luci-app-miclash/releases/latest';
const MICLASH_RELEASES =
	'https://api.github.com/repos/ang3el7z/luci-app-miclash/releases?per_page=20';
const MICLASH_RAW =
	'https://raw.githubusercontent.com/ang3el7z/luci-app-miclash/';
const BINARY = '/opt/clash/bin/clash';
const ACTIVE = '/opt/clash/config.yaml';
const UPDATE_ROOT = '/tmp/miclash/updates';
const PREVIOUS_ROOT = '/opt/clash/bin/previous';
const KERNEL_DOWNLOAD_LIMIT = 16777216;
const DEFAULT_KERNEL_LIMIT = 67108864;

function invalid() { errors.fail('INVALID_ARGUMENT'); };

function exact(value, fields) {
	if (type(value) != 'object')
		invalid();
	for (let name in value)
		if (!exists(fields, name))
			invalid();
	return value;
};

function response_ok(reply) {
	let count = 0;
	if (type(reply) == 'object')
		for (let name in reply) {
			if (name != 'code' && name != 'stdout' && name != 'stderr')
				errors.fail('INTERNAL');
			count++;
		}
	if (type(reply) != 'object' || count != 3 || type(reply.code) != 'int' ||
	    reply.stdout != null || reply.stderr != null)
		errors.fail('INTERNAL');
	return reply.code == 0;
};

function same_node(left, right) {
	return left?.type == 'file' && right?.type == 'file' && left.nlink == 1 &&
	       right.nlink == 1 && left.inode == right.inode &&
	       left.dev?.major == right.dev?.major && left.dev?.minor == right.dev?.minor;
};

function secure_directory(runtime, path) {
	let before = runtime.fs.lstat(path);
	if (before == null) {
		if (runtime.fs.mkdir(path) != true)
			errors.fail('INTERNAL');
		before = runtime.fs.lstat(path);
	}
	if (before?.type != 'directory' || runtime.fs.realpath(path) != path ||
	    (before.uid != null && before.uid != 0) || runtime.fs.chmod(path, 0o700) != true)
		errors.fail('INTERNAL');
	let after = runtime.fs.lstat(path);
	if (after?.type != 'directory' || after.inode != before.inode ||
	    after.dev?.major != before.dev?.major || after.dev?.minor != before.dev?.minor ||
	    after.mode != 0o700 || (after.uid != null && after.uid != 0) ||
	    runtime.fs.realpath(path) != path)
		errors.fail('INTERNAL');
	return after;
};

function write_exclusive(runtime, path, data, mode) {
	if (type(data) != 'string')
		invalid();
	let handle = runtime.fs.open(path, 'wx', 0o600);
	if (handle == null)
		errors.fail('INTERNAL');
	let opened = runtime.fs.fstat(handle), offset = 0, failure = null;
	try {
		while (offset < length(data)) {
			let amount = runtime.fs.write(handle, substr(data, offset));
			if (type(amount) != 'int' || amount < 1 || amount > length(data) - offset)
				errors.fail('INTERNAL');
			offset += amount;
		}
		if (runtime.fs.flush(handle) != true)
			errors.fail('INTERNAL');
	}
	catch (error) { failure = errors.normalize(error).code; }
	if (runtime.fs.close(handle) != true)
		failure = 'INTERNAL';
	if (failure == null && runtime.fs.chmod(path, mode) != true)
		failure = 'INTERNAL';
	let current = runtime.fs.lstat(path);
	if (failure == null && (!same_node(opened, current) ||
	    runtime.fs.realpath(path) != path || current.mode != mode ||
	    (current.uid != null && current.uid != 0) || current.size != length(data) ||
	    runtime.digest.sha256_file(path) != runtime.digest.sha256(data)))
		failure = 'INTERNAL';
	if (failure != null) {
		try {
			if (same_node(opened, runtime.fs.lstat(path)) && runtime.fs.realpath(path) == path)
				runtime.fs.unlink(path);
		}
		catch (cleanup_error) {}
		errors.fail(failure);
	}
	return { path, identity: current, hash: runtime.digest.sha256(data) };
};

function remove_owned(runtime, record) {
	if (record == null)
		return;
	let current = runtime.fs.lstat(record.path);
	if (current == null)
		return;
	if (!same_node(record.identity, current) || runtime.fs.realpath(record.path) != record.path ||
	    runtime.fs.unlink(record.path) != true)
		errors.fail('INTERNAL');
};

function architecture(runtime) {
	let release = runtime.fs.readfile('/etc/openwrt_release');
	let found = type(release) == 'string' ?
		match(release, /(^|\n)DISTRIB_ARCH='([^']+)'(\n|$)/) : null;
	if (found == null)
		invalid();
	let value = found[2];
	if (match(value, /^aarch64(_|$)/)) return 'arm64';
	if (match(value, /^x86_64(_|$)/)) return 'amd64';
	if (match(value, /^arm(_|$)/)) return 'armv7';
	if (match(value, /^mipsel(_|$)/)) return 'mipsle-softfloat';
	if (match(value, /^mips(_|$)/)) return 'mips-softfloat';
	invalid();
};

function version(value) {
	if (type(value) != 'string' || !match(value,
	    /^v?[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z][0-9A-Za-z.-]*)?$/))
		invalid();
	return substr(value, 0, 1) == 'v' ? value : 'v' + value;
};

function channel(value) {
	if (value != 'release' && value != 'prerelease')
		invalid();
	return value;
};

function github_json(runtime, url) {
	let response = http.request(runtime, {
		url, managed: true, max_bytes: 1048576, max_redirects: 3,
		headers: { Accept: 'application/vnd.github+json',
			'X-GitHub-Api-Version': '2022-11-28' }
	});
	try { return json(response.body); }
	catch (error) { errors.fail('INVALID_RESPONSE'); }
};

function choose_release(runtime, selected_channel, requested) {
	let payload = github_json(runtime,
		requested != null ?
			'https://api.github.com/repos/MetaCubeX/mihomo/releases/tags/' + requested :
			(selected_channel == 'release' ? MIHOMO_LATEST : MIHOMO_RELEASES));
	let releases = requested != null || selected_channel == 'release' ? [ payload ] : payload;
	if (type(releases) != 'array' || !length(releases))
		errors.fail('INVALID_RESPONSE');
	for (let release in releases) {
		if (type(release) != 'object' || release.draft === true ||
		    (selected_channel == 'prerelease' && release.prerelease !== true) ||
		    (selected_channel == 'release' && release.prerelease === true))
			continue;
		let tag;
		try { tag = version(release.tag_name); }
		catch (error) { continue; }
		if (requested != null && tag != requested)
			continue;
		return { release, version: tag };
	}
	errors.fail('NOT_FOUND');
};

function asset_url(asset, tag, name) {
	if (type(asset?.browser_download_url) != 'string' ||
	    asset.browser_download_url !=
	      'https://github.com/MetaCubeX/mihomo/releases/download/' + tag + '/' + name)
		errors.fail('INVALID_RESPONSE');
	return asset.browser_download_url;
};

function resolve_mihomo(runtime, selected_channel, requested) {
	let selected = choose_release(runtime, selected_channel, requested);
	let arch = architecture(runtime);
	let name = 'mihomo-linux-' + arch + '-' + selected.version + '.gz';
	let binary = null, checksum = null;
	if (type(selected.release.assets) != 'array')
		errors.fail('INVALID_RESPONSE');
	for (let asset in selected.release.assets) {
		if (asset?.name == name) {
			if (binary != null) errors.fail('INVALID_RESPONSE');
			binary = asset_url(asset, selected.version, name);
		}
		else if (asset?.name == name + '.sha256') {
			if (checksum != null) errors.fail('INVALID_RESPONSE');
			checksum = asset_url(asset, selected.version, name + '.sha256');
		}
	}
	if (binary == null)
		errors.fail('NOT_FOUND');
	return { version: selected.version, architecture: arch, asset_name: name,
		asset_url: binary, checksum_url: checksum };
};

function choose_miclash(runtime, selected_channel, requested) {
	let payload = github_json(runtime,
		requested != null ?
			'https://api.github.com/repos/ang3el7z/luci-app-miclash/releases/tags/' + requested :
			(selected_channel == 'release' ? MICLASH_LATEST : MICLASH_RELEASES));
	let releases = requested != null || selected_channel == 'release' ? [ payload ] : payload;
	if (type(releases) != 'array' || !length(releases))
		errors.fail('INVALID_RESPONSE');
	for (let release in releases) {
		if (type(release) != 'object' || release.draft === true ||
		    (selected_channel == 'prerelease' && release.prerelease !== true) ||
		    (selected_channel == 'release' && release.prerelease === true))
			continue;
		let tag;
		try { tag = version(release.tag_name); }
		catch (error) { continue; }
		if (requested != null && tag != requested)
			continue;
		let checksum = null;
		if (type(release.assets) != 'array')
			errors.fail('INVALID_RESPONSE');
		for (let asset in release.assets)
			if (asset?.name == 'install-miclash.sh.sha256') {
				if (checksum != null) errors.fail('INVALID_RESPONSE');
				if (type(asset.browser_download_url) != 'string' ||
				    asset.browser_download_url !=
				      'https://github.com/ang3el7z/luci-app-miclash/releases/download/' +
				      tag + '/install-miclash.sh.sha256')
					errors.fail('INVALID_RESPONSE');
				checksum = asset.browser_download_url;
			}
		return { version: tag,
			installer_url: MICLASH_RAW + tag + '/install-miclash.sh',
			checksum_url: checksum };
	}
	errors.fail('NOT_FOUND');
};

function public_release(resolved, selected_channel) {
	return {
		kind: 'mihomo', channel: selected_channel, version: resolved.version,
		architecture: resolved.architecture, asset_name: resolved.asset_name,
		published_checksum_available: resolved.checksum_url != null
	};
};

function download(runtime, url, maximum) {
	return http.download(runtime, {
		url, managed: true, max_bytes: maximum, max_redirects: 3,
		headers: { Accept: 'application/octet-stream' }
	}).body;
};

function published_hash(runtime, resolved, compressed, local_hash) {
	if (resolved.checksum_url == null)
		return false;
	let body = download(runtime, resolved.checksum_url, 65536);
	let found = match(trim(body), /^([0-9A-Fa-f]{64})[ \t]+\*?([^ \t\r\n]+)$/);
	if (found == null || found[2] != resolved.asset_name)
		errors.fail('INVALID_RESPONSE');
	if (lc(found[1]) != local_hash)
		errors.fail('VALIDATION_FAILED');
	return true;
};

function file_snapshot(runtime, path) {
	let before = runtime.fs.lstat(path);
	if (before?.type != 'file' || before.nlink != 1 ||
	    (before.uid != null && before.uid != 0) || runtime.fs.realpath(path) != path)
		errors.fail(before == null ? 'NOT_FOUND' : 'INTERNAL');
	let content = runtime.fs.readfile(path);
	let after = runtime.fs.lstat(path);
	if (type(content) != 'string' || !same_node(before, after) ||
	    runtime.fs.realpath(path) != path ||
	    runtime.digest.sha256_file(path) != runtime.digest.sha256(content))
		errors.fail('INTERNAL');
	return { path, identity: after, content, hash: runtime.digest.sha256(content) };
};

function verify_snapshot(runtime, snapshot) {
	let current = runtime.fs.lstat(snapshot.path);
	return same_node(snapshot.identity, current) &&
	       runtime.fs.realpath(snapshot.path) == snapshot.path &&
	       runtime.digest.sha256_file(snapshot.path) == snapshot.hash;
};

function prepare_kernel(runtime, resolved) {
	secure_directory(runtime, UPDATE_ROOT);
	let compressed = download(runtime, resolved.asset_url, KERNEL_DOWNLOAD_LIMIT);
	let compressed_hash = runtime.digest.sha256(compressed);
	let verified = published_hash(runtime, resolved, compressed, compressed_hash);
	let maximum = runtime.update_options?.max_kernel_bytes ?? DEFAULT_KERNEL_LIMIT;
	if (type(maximum) != 'int' || maximum < 64 || maximum > DEFAULT_KERNEL_LIMIT)
		errors.fail('INTERNAL');
	let token = runtime.random.hex(16);
	if (type(token) != 'string' || !match(token, /^[0-9a-f]{32}$/))
		errors.fail('INTERNAL');
	let gz = write_exclusive(runtime, UPDATE_ROOT + '/' + token + '.gz', compressed, 0o600);
	let kernel_path = substr(gz.path, 0, length(gz.path) - 3), kernel = null;
	let failure = null;
	try {
		if (!response_ok(runtime.process.run({
			command: '/usr/libexec/miclash/decompress-gzip',
			args: [ gz.path, kernel_path, sprintf('%d', maximum) ], timeout_ms: 60000
		})))
			errors.fail('VALIDATION_FAILED');
		let identity = runtime.fs.lstat(kernel_path);
		if (identity?.type != 'file' || identity.nlink != 1 ||
		    (identity.uid != null && identity.uid != 0) || identity.size < 1 ||
		    identity.size > maximum || runtime.fs.realpath(kernel_path) != kernel_path ||
		    runtime.fs.chmod(kernel_path, 0o700) != true)
			errors.fail('VALIDATION_FAILED');
		identity = runtime.fs.lstat(kernel_path);
		let content = runtime.fs.readfile(kernel_path);
		if (identity?.mode != 0o700 || type(content) != 'string' ||
		    runtime.digest.sha256_file(kernel_path) != runtime.digest.sha256(content))
			errors.fail('INTERNAL');
		kernel = { path: kernel_path, identity, content,
			hash: runtime.digest.sha256(content), published_checksum_verified: verified };
		if (!response_ok(runtime.process.run({ command: kernel_path,
			args: [ '-v' ], timeout_ms: 10000 })))
			errors.fail('VALIDATION_FAILED');
		if (!same_node(kernel.identity, runtime.fs.lstat(kernel.path)) ||
		    runtime.fs.realpath(kernel.path) != kernel.path ||
		    runtime.digest.sha256_file(kernel.path) != kernel.hash)
			errors.fail('INTERNAL');
		let active = file_snapshot(runtime, ACTIVE);
		if (!response_ok(runtime.process.run({ command: kernel_path,
			args: [ '-d', '/opt/clash', '-f', ACTIVE, '-t' ], timeout_ms: 30000 })))
			errors.fail('VALIDATION_FAILED');
		if (!verify_snapshot(runtime, active) ||
		    !same_node(kernel.identity, runtime.fs.lstat(kernel.path)) ||
		    runtime.digest.sha256_file(kernel.path) != kernel.hash)
			errors.fail('INTERNAL');
	}
	catch (error) { failure = errors.normalize(error).code; }
	try { remove_owned(runtime, gz); }
	catch (cleanup_error) { failure = 'INTERNAL'; }
	if (failure != null) {
		try { remove_owned(runtime, kernel); } catch (cleanup_error) {}
		errors.fail(failure);
	}
	return kernel;
};

function preserve(runtime, snapshot) {
	secure_directory(runtime, PREVIOUS_ROOT);
	let id = 'mihomo-' + snapshot.hash;
	let path = PREVIOUS_ROOT + '/' + id;
	let current = runtime.fs.lstat(path);
	if (current == null)
		storage.atomic_write(runtime, path, snapshot.content, 0o700);
	else {
		let existing = file_snapshot(runtime, path);
		if (existing.hash != snapshot.hash)
			errors.fail('INTERNAL');
	}
	return id;
};

function prune_previous(runtime, protected_id) {
	let maximum = runtime.update_options?.previous_retention ?? 3;
	if (type(maximum) != 'int' || maximum < 1 || maximum > 10)
		errors.fail('INTERNAL');
	let entries = runtime.fs.lsdir(PREVIOUS_ROOT);
	if (type(entries) != 'array')
		errors.fail('INTERNAL');
	let owned = [];
	for (let name in entries)
		if (match(name, /^mihomo-[0-9a-f]{64}$/))
			push(owned, name);
	sort(owned);
	while (length(owned) > maximum) {
		let victim = shift(owned);
		if (victim == protected_id) {
			push(owned, victim);
			continue;
		}
		let snapshot = file_snapshot(runtime, PREVIOUS_ROOT + '/' + victim);
		if ('mihomo-' + snapshot.hash != victim ||
		    runtime.fs.unlink(snapshot.path) != true)
			errors.fail('INTERNAL');
	}
};

function previous(runtime, id) {
	if (type(id) != 'string' || !match(id, /^mihomo-[0-9a-f]{64}$/))
		invalid();
	let snapshot = file_snapshot(runtime, PREVIOUS_ROOT + '/' + id);
	if ('mihomo-' + snapshot.hash != id)
		errors.fail('CORRUPT_STATE');
	return snapshot;
};

function install_kernel(app, candidate, resolved, ctx, set_status) {
	let runtime = app.runtime, old = file_snapshot(runtime, BINARY);
	ctx.stage('preserve', 50, 'preserve');
	let previous_id = preserve(runtime, old);
	ctx.stage('transition', 55, 'transition');
	if (!verify_snapshot(runtime, old) ||
	    !same_node(candidate.identity, runtime.fs.lstat(candidate.path)) ||
	    runtime.digest.sha256_file(candidate.path) != candidate.hash)
		errors.fail('INTERNAL');
	let observed = app.service.observe('config.yaml');
	if (type(observed) != 'object' || type(observed.running) != 'bool')
		errors.fail('HEALTH_FAILED');
	ctx.stage('install', 75, 'install');
	if (observed.running) {
		app.service.stop('config.yaml');
		let stopped = app.service.wait_ready(runtime.clock.now() + 5000,
			'config.yaml', { stopped: true });
		if (stopped?.ok !== true)
			errors.fail('HEALTH_FAILED');
	}
	storage.atomic_write(runtime, BINARY, candidate.content, 0o700);
	if (observed.running) {
		let new_failure = null;
		try {
			app.service.start('config.yaml');
			let ready = app.service.wait_ready(runtime.clock.now() + 15000,
				'config.yaml', {});
			if (ready?.ok !== true)
				new_failure = 'HEALTH_FAILED';
		}
		catch (error) { new_failure = errors.normalize(error).code; }
		if (new_failure != null) {
			let restore_failed = false;
			try {
				let now = app.service.observe('config.yaml');
				if (now?.running === true) {
					app.service.stop('config.yaml');
					if (app.service.wait_ready(runtime.clock.now() + 5000,
					    'config.yaml', { stopped: true })?.ok !== true)
						errors.fail('INTERNAL');
				}
				storage.atomic_write(runtime, BINARY, old.content, 0o700);
				app.service.start('config.yaml');
				if (app.service.wait_ready(runtime.clock.now() + 15000,
				    'config.yaml', {})?.ok !== true)
					errors.fail('INTERNAL');
			}
			catch (error) { restore_failed = true; }
			if (restore_failed)
				errors.fail('INTERNAL');
			errors.fail(new_failure);
		}
	}
	prune_previous(runtime, previous_id);
	set_status({ state: 'success', kind: 'mihomo', stage: 'done',
		operation_id: ctx.id, version: resolved.version, sha256: candidate.hash,
		published_checksum_verified: candidate.published_checksum_verified,
		previous_id, error_code: null, updated_at: runtime.clock.now() });
};

function parse_installer_checksum(runtime, resolved, installer, local_hash) {
	if (resolved.checksum_url == null)
		return false;
	let body = download(runtime, resolved.checksum_url, 65536);
	let found = match(trim(body), /^([0-9A-Fa-f]{64})[ \t]+\*?install-miclash\.sh$/);
	if (found == null)
		errors.fail('INVALID_RESPONSE');
	if (lc(found[1]) != local_hash)
		errors.fail('VALIDATION_FAILED');
	return true;
};

function prepare_installer(runtime, resolved) {
	secure_directory(runtime, UPDATE_ROOT);
	let body = download(runtime, resolved.installer_url, 1048576);
	if (type(body) != 'string' || length(body) < 10 ||
	    substr(body, 0, 10) != '#!/bin/sh\n' || index(body, sprintf('%c', 0)) >= 0)
		errors.fail('VALIDATION_FAILED');
	let hash = runtime.digest.sha256(body);
	let published = parse_installer_checksum(runtime, resolved, body, hash);
	let token = runtime.random.hex(16);
	if (type(token) != 'string' || !match(token, /^[0-9a-f]{32}$/))
		errors.fail('INTERNAL');
	let candidate = write_exclusive(runtime, UPDATE_ROOT + '/' + token + '.sh', body, 0o700);
	candidate.published_checksum_verified = published;
	if (!response_ok(runtime.process.run({ command: '/bin/ash',
		args: [ '-n', candidate.path ], timeout_ms: 30000 }))) {
		remove_owned(runtime, candidate);
		errors.fail('VALIDATION_FAILED');
	}
	if (!same_node(candidate.identity, runtime.fs.lstat(candidate.path)) ||
	    runtime.fs.realpath(candidate.path) != candidate.path ||
	    runtime.digest.sha256_file(candidate.path) != candidate.hash) {
		try { remove_owned(runtime, candidate); } catch (cleanup_error) {}
		errors.fail('INTERNAL');
	}
	return candidate;
};

function consume_handoff(runtime, path, token, expected_version, started_at) {
	let before = runtime.fs.lstat(path);
	if (before?.type != 'file' || before.nlink != 1 ||
	    before.mode != 0o600 || (before.uid != null && before.uid != 0) ||
	    runtime.fs.realpath(path) != path)
		errors.fail('INTERNAL');
	let body = runtime.fs.readfile(path), after = runtime.fs.lstat(path);
	if (type(body) != 'string' || !same_node(before, after) ||
	    after.mode != 0o600 || (after.uid != null && after.uid != 0) ||
	    runtime.fs.realpath(path) != path)
		errors.fail('INTERNAL');
	let lines = split(body, '\n');
	if (length(lines) != 7 || lines[6] != '' ||
	    lines[0] != 'protocol=miclash-update-status-v1' ||
	    lines[1] != 'token=' + token || lines[2] != 'state=success' ||
	    lines[3] != 'phase=done' || lines[4] != 'target_version=' + expected_version)
		errors.fail('INTERNAL');
	let found = match(lines[5], /^updated_at=([0-9]+)$/);
	let updated = found == null ? null : int(found[1]);
	let now = int(runtime.clock.now() / 1000);
	if (updated == null || updated < started_at || updated > now + 300)
		errors.fail('INTERNAL');
	return { path, identity: after };
};

export function create(app) {
	if (type(app?.runtime?.fs) != 'object' || type(app?.runtime?.process?.run) != 'function' ||
	    type(app?.runtime?.digest?.sha256) != 'function' ||
	    type(app?.runtime?.random?.hex) != 'function' ||
	    type(app?.operations?.submit) != 'function' || type(app?.service?.observe) != 'function' ||
	    type(app?.settings?.get) != 'function')
		invalid();
	let last = { state: 'idle', kind: null, stage: 'idle', operation_id: null,
		version: null, sha256: null, published_checksum_verified: null,
		previous_id: null, error_code: null, updated_at: app.runtime.clock.now() };
	function set_status(value) { last = value; };
	function configured_channel(kind, requested) {
		if (requested != null)
			return channel(requested);
		let settings = app.settings.get();
		return channel(settings?.updates?.[kind + '_release_channel']);
	};
	function release_info(...args) {
		if (length(args) != 1) invalid();
		let options = args[0];
		exact(options, { kind: true, channel: true, version: true });
		if (options.kind != 'mihomo' && options.kind != 'miclash')
			invalid();
		let selected_channel = configured_channel(options.kind, options.channel);
		let requested = options.version == null ? null : version(options.version);
		if (options.kind == 'miclash') {
			let resolved = choose_miclash(app.runtime, selected_channel, requested);
			return { kind: 'miclash', channel: selected_channel,
				version: resolved.version,
				published_checksum_available: resolved.checksum_url != null };
		}
		return public_release(resolve_mihomo(app.runtime, selected_channel, requested),
			selected_channel);
	};
	function update_mihomo(...args) {
		if (length(args) != 2) invalid();
		let options = args[0], source = args[1];
		exact(options, { version: true, channel: true });
		let selected_channel = configured_channel('mihomo', options.channel);
		let requested = options.version == null ? null : version(options.version);
		return app.operations.submit('updates.mihomo', source, {}, (ctx) => {
			let candidate = null;
			try {
				ctx.stage('release', 10, 'release');
				let resolved = resolve_mihomo(app.runtime, selected_channel, requested);
				ctx.stage('verification', 45, 'verification');
				candidate = prepare_kernel(app.runtime, resolved);
				install_kernel(app, candidate, resolved, ctx, set_status);
			}
			catch (error) {
				let normalized = errors.normalize(error);
				if (candidate != null) {
					try { remove_owned(app.runtime, candidate); }
					catch (cleanup_error) { normalized = errors.new('INTERNAL'); }
					candidate = null;
				}
				set_status({ state: 'failure', kind: 'mihomo', stage: 'error',
					operation_id: ctx.id, version: requested, sha256: null,
					published_checksum_verified: null, previous_id: null,
					error_code: normalized.code, updated_at: app.runtime.clock.now() });
				ctx.complete(normalized);
				return false;
			}
			try { remove_owned(app.runtime, candidate); }
			catch (cleanup_error) {
				ctx.complete(errors.new('INTERNAL'));
				return false;
			}
			return true;
		});
	};
	function rollback_mihomo(...args) {
		if (length(args) != 2) invalid();
		let options = args[0], source = args[1];
		exact(options, { id: true });
		if (type(source) != 'string')
			invalid();
		let id = options.id;
		if (type(id) != 'string' || !match(id, /^mihomo-[0-9a-f]{64}$/))
			invalid();
		return app.operations.submit('updates.mihomo.rollback', source, {}, (ctx) => {
			try {
				ctx.stage('verification', 45, 'verification');
				let candidate = previous(app.runtime, id);
				candidate.published_checksum_verified = true;
				install_kernel(app, candidate, { version: null }, ctx, set_status);
			}
			catch (error) {
				let normalized = errors.normalize(error);
				set_status({ state: 'failure', kind: 'mihomo', stage: 'error',
					operation_id: ctx.id, version: null, sha256: null,
					published_checksum_verified: null, previous_id: id,
					error_code: normalized.code, updated_at: app.runtime.clock.now() });
				ctx.complete(normalized);
				return false;
			}
			return true;
		});
	};
	function update_miclash(...args) {
		if (length(args) != 2) invalid();
		let options = args[0], source = args[1];
		exact(options, { version: true, channel: true });
		let selected_channel = configured_channel('miclash', options.channel);
		let requested = options.version == null ? null : version(options.version);
		return app.operations.submit('updates.miclash', source, {}, (ctx) => {
			let candidate = null, handoff = null;
			try {
				ctx.stage('release', 10, 'release');
				let resolved = choose_miclash(app.runtime, selected_channel, requested);
				ctx.stage('verification', 45, 'verification');
				candidate = prepare_installer(app.runtime, resolved);
				let token = app.runtime.random.hex(16);
				if (type(token) != 'string' || !match(token, /^[0-9a-f]{32}$/))
					errors.fail('INTERNAL');
				let handoff_path = UPDATE_ROOT + '/handoff-' + ctx.id + '.status';
				if (app.runtime.fs.lstat(handoff_path) != null)
					errors.fail('INTERNAL');
				ctx.stage('install', 75, 'install');
				let handoff_started = int(app.runtime.clock.now() / 1000);
				let reply = app.runtime.process.run({ command: '/bin/ash', args: [
					candidate.path, 'app', '--target-tag', resolved.version,
					'--mode', 'update', '--status-file', handoff_path, '--token', token
				], timeout_ms: 600000 });
				if (!same_node(candidate.identity, app.runtime.fs.lstat(candidate.path)) ||
				    app.runtime.fs.realpath(candidate.path) != candidate.path ||
				    app.runtime.digest.sha256_file(candidate.path) != candidate.hash)
					errors.fail('INTERNAL');
				if (!response_ok(reply))
					errors.fail('HEALTH_FAILED');
				handoff = consume_handoff(app.runtime, handoff_path, token,
					resolved.version, handoff_started);
				remove_owned(app.runtime, handoff);
				handoff = null;
				set_status({ state: 'success', kind: 'miclash', stage: 'done',
					operation_id: ctx.id, version: resolved.version, sha256: candidate.hash,
					published_checksum_verified: candidate.published_checksum_verified,
					previous_id: null, error_code: null,
					updated_at: app.runtime.clock.now() });
			}
			catch (error) {
				let normalized = errors.normalize(error);
				if (handoff == null) {
					let candidate_path = UPDATE_ROOT + '/handoff-' + ctx.id + '.status';
					let identity = app.runtime.fs.lstat(candidate_path);
					if (identity?.type == 'file') handoff = { path: candidate_path, identity };
				}
				for (let owned in [ handoff, candidate ])
					if (owned != null)
						try { remove_owned(app.runtime, owned); }
						catch (cleanup_error) { normalized = errors.new('INTERNAL'); }
				set_status({ state: 'failure', kind: 'miclash', stage: 'error',
					operation_id: ctx.id, version: requested, sha256: null,
					published_checksum_verified: null, previous_id: null,
					error_code: normalized.code, updated_at: app.runtime.clock.now() });
				ctx.complete(normalized);
				return false;
			}
			remove_owned(app.runtime, candidate);
			return true;
		});
	};
	return {
		release_info, update_mihomo,
		rollback_mihomo,
		update_miclash,
		status: (...args) => {
			if (length(args)) invalid();
			return json(sprintf('%J', last));
		}
	};
};
