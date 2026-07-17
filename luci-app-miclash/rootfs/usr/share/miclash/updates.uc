import * as errors from 'miclash.errors';
import * as http from 'miclash.http';
import * as storage from 'miclash.storage';
import * as platform from 'miclash.platform';

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
const DECOMPRESS = '/usr/libexec/miclash/decompress-gzip';
const BUSYBOX = '/bin/busybox';
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

function same_object(left, right) {
	return left?.type != null && left.type == right?.type &&
	       left.inode == right?.inode && left.dev?.major == right.dev?.major &&
	       left.dev?.minor == right.dev?.minor;
};

function verify_authority(runtime, authority) {
	if (authority?.parent != null) verify_authority(runtime, authority.parent);
	let current = runtime.fs.lstat(authority.path);
	if (!same_object(authority.identity, current) || current?.type != 'directory' ||
	    runtime.fs.realpath(authority.path) != authority.path ||
	    (current.uid != null && current.uid != 0) ||
	    (current.mode != 0o700 && current.mode != 0o750 && current.mode != 0o755))
		errors.fail('INTERNAL');
	return current;
};

function trusted_directory(runtime, path, parent) {
	let identity = runtime.fs.lstat(path);
	let authority = { path, identity, parent };
	verify_authority(runtime, authority);
	return authority;
};

function binary_authority(runtime) {
	let root = trusted_directory(runtime, '/opt/clash', null);
	return trusted_directory(runtime, '/opt/clash/bin', root);
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
	return { path, identity: after };
};

function update_authority(runtime) {
	let parent = secure_directory(runtime, '/tmp/miclash');
	let root = secure_directory(runtime, UPDATE_ROOT);
	root.parent = parent;
	verify_authority(runtime, root);
	return root;
};

function trusted_file(runtime, path, authority, modes) {
	verify_authority(runtime, authority);
	let before = runtime.fs.lstat(path), accepted = false;
	for (let mode in modes)
		if (before?.mode == mode) accepted = true;
	if (before?.type != 'file' || before.nlink != 1 || !accepted ||
	    (before.uid != null && before.uid != 0) || runtime.fs.realpath(path) != path)
		errors.fail('INTERNAL');
	let hash = runtime.digest.sha256_file(path);
	let after = runtime.fs.lstat(path);
	verify_authority(runtime, authority);
	if (type(hash) != 'string' || !match(hash, /^[0-9a-f]{64}$/) ||
	    !same_node(before, after) || runtime.fs.realpath(path) != path ||
	    runtime.digest.sha256_file(path) != hash)
		errors.fail('INTERNAL');
	return { path, identity: after, hash, authority, mode: after.mode };
};

function helper_capability(runtime) {
	let usr = trusted_directory(runtime, '/usr', null);
	let libexec = trusted_directory(runtime, '/usr/libexec', usr);
	let parent = trusted_directory(runtime, '/usr/libexec/miclash', libexec);
	return trusted_file(runtime, DECOMPRESS, parent, [ 0o700, 0o755 ]);
};

function busybox_capability(runtime) {
	let parent = trusted_directory(runtime, '/bin', null);
	return trusted_file(runtime, BUSYBOX, parent, [ 0o700, 0o755 ]);
};

function verify_file(runtime, record, modes) {
	verify_authority(runtime, record.authority);
	let current = runtime.fs.lstat(record.path), accepted = false;
	for (let mode in modes)
		if (current?.mode == mode) accepted = true;
	if (!same_node(record.identity, current) || !accepted ||
	    (current.uid != null && current.uid != 0) ||
	    runtime.fs.realpath(record.path) != record.path ||
	    runtime.digest.sha256_file(record.path) != record.hash)
		errors.fail('INTERNAL');
	verify_authority(runtime, record.authority);
	return true;
};

function write_exclusive(runtime, path, data, mode, authority) {
	if (type(data) != 'string')
		invalid();
	verify_authority(runtime, authority);
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
	catch (error) {
		failure = errors.normalize(error).code;
	}
	if (runtime.fs.close(handle) != true)
		failure = 'INTERNAL';
	if (failure == null && runtime.fs.chmod(path, mode) != true)
		failure = 'INTERNAL';
	let current = runtime.fs.lstat(path);
	verify_authority(runtime, authority);
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
	return { path, identity: current, hash: runtime.digest.sha256(data), authority, mode };
};

function verify_owned(runtime, record) {
	return verify_file(runtime, record, [ record.mode ]);
};

function verify_snapshot(runtime, snapshot) {
	if (snapshot.authority != null) verify_authority(runtime, snapshot.authority);
	let current = runtime.fs.lstat(snapshot.path);
	return same_node(snapshot.identity, current) &&
	       (snapshot.required_mode == null || current.mode == snapshot.required_mode) &&
	       (current.uid == null || current.uid == 0) &&
	       runtime.fs.realpath(snapshot.path) == snapshot.path &&
	       runtime.digest.sha256_file(snapshot.path) == snapshot.hash;
};

function run_checked(runtime, executable, request, inputs) {
	verify_file(runtime, executable, [ executable.mode ]);
	for (let input in inputs ?? [])
		if (input.mode != null) verify_owned(runtime, input);
		else if (!verify_snapshot(runtime, input)) errors.fail('INTERNAL');
	let reply = runtime.process.run(request);
	verify_file(runtime, executable, [ executable.mode ]);
	for (let input in inputs ?? [])
		if (input.mode != null) verify_owned(runtime, input);
		else if (!verify_snapshot(runtime, input)) errors.fail('INTERNAL');
	return reply;
};

function remove_owned(runtime, record) {
	if (record == null)
		return;
	verify_authority(runtime, record.authority);
	let current = runtime.fs.lstat(record.path);
	if (current == null)
		return;
	if (!same_node(record.identity, current) || runtime.fs.realpath(record.path) != record.path ||
	    runtime.fs.unlink(record.path) != true)
		errors.fail('INTERNAL');
	verify_authority(runtime, record.authority);
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
	let manager = platform.detect_package_manager(runtime);
	if (manager == '')
		errors.fail('HEALTH_FAILED');
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
		let expected = platform.miclash_assets(manager, substr(tag, 1));
		let required = [ expected.package_name, expected.checksum_name,
			expected.installer_checksum_name, expected.manifest_name ];
		let present = {};
		if (type(release.assets) != 'array')
			errors.fail('INVALID_RESPONSE');
		let prefix = 'https://github.com/ang3el7z/luci-app-miclash/releases/download/' +
			tag + '/';
		for (let asset in release.assets) {
			if (index(required, asset?.name) < 0)
				continue;
			if (present[asset.name] != null ||
			    type(asset.browser_download_url) != 'string' ||
			    asset.browser_download_url != prefix + asset.name)
				errors.fail('INVALID_RESPONSE');
			present[asset.name] = true;
		}
		let ready = true;
		for (let name in required)
			if (present[name] !== true)
				ready = false;
		return { version: tag,
			installer_url: MICLASH_RAW + tag + '/install-miclash.sh',
			checksum_url: present[expected.installer_checksum_name] === true
				? prefix + expected.installer_checksum_name : null,
			ready, readiness: ready ? 'ready' : 'assets_pending' };
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
		errors.fail('INVALID_RESPONSE');
	let body = download(runtime, resolved.checksum_url, 65536);
	let found = match(trim(body), /^([0-9A-Fa-f]{64})[ \t]+\*?([^ \t\r\n]+)$/);
	if (found == null || found[2] != resolved.asset_name)
		errors.fail('INVALID_RESPONSE');
	if (lc(found[1]) != local_hash)
		errors.fail('VALIDATION_FAILED');
	return true;
};

function file_snapshot(runtime, path, authority, required_mode) {
	if (authority != null) verify_authority(runtime, authority);
	let before = runtime.fs.lstat(path);
	if (before?.type != 'file' || before.nlink != 1 ||
	    (required_mode != null && before.mode != required_mode) ||
	    (before.uid != null && before.uid != 0) || runtime.fs.realpath(path) != path)
		errors.fail(before == null ? 'NOT_FOUND' : 'INTERNAL');
	let content = runtime.fs.readfile(path);
	let after = runtime.fs.lstat(path);
	if (type(content) != 'string' || !same_node(before, after) ||
	    (required_mode != null && after.mode != required_mode) ||
	    runtime.fs.realpath(path) != path ||
	    runtime.digest.sha256_file(path) != runtime.digest.sha256(content))
		errors.fail('INTERNAL');
	if (authority != null) verify_authority(runtime, authority);
	return { path, identity: after, content, hash: runtime.digest.sha256(content),
		authority, required_mode };
};

function validate_kernel_candidate(runtime, kernel) {
	verify_owned(runtime, kernel);
	if (!response_ok(run_checked(runtime, kernel, { command: kernel.path,
		args: [ '-v' ], timeout_ms: 10000 }, [])))
		errors.fail('VALIDATION_FAILED');
	let active_authority = trusted_directory(runtime, '/opt/clash', null);
	let active = file_snapshot(runtime, ACTIVE, active_authority, null);
	if (!response_ok(run_checked(runtime, kernel, { command: kernel.path,
		args: [ '-d', '/opt/clash', '-f', ACTIVE, '-t' ], timeout_ms: 30000 },
		[ active ])))
		errors.fail('VALIDATION_FAILED');
	verify_owned(runtime, kernel);
	if (!verify_snapshot(runtime, active)) errors.fail('INTERNAL');
	return true;
};

function prepare_kernel(runtime, resolved) {
	let authority = update_authority(runtime);
	let compressed = download(runtime, resolved.asset_url, KERNEL_DOWNLOAD_LIMIT);
	let compressed_hash = runtime.digest.sha256(compressed);
	let verified = published_hash(runtime, resolved, compressed, compressed_hash);
	let maximum = runtime.update_options?.max_kernel_bytes ?? DEFAULT_KERNEL_LIMIT;
	if (type(maximum) != 'int' || maximum < 64 || maximum > DEFAULT_KERNEL_LIMIT)
		errors.fail('INTERNAL');
	let token = runtime.random.hex(16);
	if (type(token) != 'string' || !match(token, /^[0-9a-f]{32}$/))
		errors.fail('INTERNAL');
	let gz = write_exclusive(runtime, UPDATE_ROOT + '/' + token + '.gz', compressed,
		0o600, authority);
	let kernel_path = substr(gz.path, 0, length(gz.path) - 3), kernel = null;
	let failure = null;
	try {
		let helper = helper_capability(runtime);
		if (runtime.fs.lstat(kernel_path) != null)
			errors.fail('INTERNAL');
		if (!response_ok(run_checked(runtime, helper, {
			command: DECOMPRESS,
			args: [ gz.path, kernel_path, sprintf('%d', maximum) ], timeout_ms: 60000
		}, [ gz ])))
			errors.fail('VALIDATION_FAILED');
		verify_owned(runtime, gz);
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
			hash: runtime.digest.sha256(content), published_checksum_verified: verified,
			authority, mode: 0o700 };
		validate_kernel_candidate(runtime, kernel);
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

function previous_authority(runtime, bin_authority) {
	let authority = secure_directory(runtime, PREVIOUS_ROOT);
	authority.parent = bin_authority;
	verify_authority(runtime, authority);
	return authority;
};

function preserve(runtime, snapshot, bin_authority) {
	let authority = previous_authority(runtime, bin_authority);
	let id = 'mihomo-' + snapshot.hash;
	let path = PREVIOUS_ROOT + '/' + id;
	let current = runtime.fs.lstat(path);
	if (current == null)
		storage.atomic_write(runtime, path, snapshot.content, 0o700);
	else {
		let existing = file_snapshot(runtime, path, authority, 0o700);
		if (existing.hash != snapshot.hash)
			errors.fail('INTERNAL');
	}
	return id;
};

function prune_previous(runtime, protected_id, bin_authority) {
	let authority = previous_authority(runtime, bin_authority);
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
		let snapshot = file_snapshot(runtime, PREVIOUS_ROOT + '/' + victim,
			authority, 0o700);
		if ('mihomo-' + snapshot.hash != victim ||
		    runtime.fs.unlink(snapshot.path) != true)
			errors.fail('INTERNAL');
	}
};

function previous(runtime, id) {
	if (type(id) != 'string' || !match(id, /^mihomo-[0-9a-f]{64}$/))
		invalid();
	let authority = previous_authority(runtime, binary_authority(runtime));
	let snapshot = file_snapshot(runtime, PREVIOUS_ROOT + '/' + id, authority, 0o700);
	if ('mihomo-' + snapshot.hash != id)
		errors.fail('CORRUPT_STATE');
	snapshot.mode = 0o700;
	return snapshot;
};

function binary_snapshot(runtime, authority) {
	verify_authority(runtime, authority);
	let current = runtime.fs.lstat(BINARY);
	if (current?.type != 'file' || current.nlink != 1 ||
	    (current.uid != null && current.uid != 0) || runtime.fs.realpath(BINARY) != BINARY ||
	    runtime.fs.chmod(BINARY, 0o700) != true)
		errors.fail(current == null ? 'NOT_FOUND' : 'INTERNAL');
	return file_snapshot(runtime, BINARY, authority, 0o700);
};

function verify_binary(runtime, authority, expected_hash) {
	verify_authority(runtime, authority);
	let current = file_snapshot(runtime, BINARY, authority, 0o700);
	if (current.hash != expected_hash)
		errors.fail('INTERNAL');
	verify_authority(runtime, authority);
	return current;
};

function observed_service(app) {
	let observed = app.service.observe('config.yaml');
	if (type(observed) != 'object' || type(observed.running) != 'bool' ||
	    (observed.state != 'running' && observed.state != 'stopped'))
		errors.fail('HEALTH_FAILED');
	return observed;
};

function recover_kernel(app, authority, old, was_running, transaction) {
	let runtime = app.runtime;
	transaction.stage = 'recovery';
	let observed = observed_service(app);
	if (observed.running) {
		app.service.stop('config.yaml');
		if (app.service.wait_ready(runtime.clock.now() + 5000,
		    'config.yaml', { stopped: true })?.ok !== true)
			errors.fail('INTERNAL');
	}
	let exact_old = false;
	try {
		exact_old = verify_binary(runtime, authority, old.hash)?.hash == old.hash;
		if (exact_old) {
			transaction.applied = false;
			transaction.sha256 = old.hash;
		}
	}
	catch (error) {
		transaction.applied = null;
		transaction.sha256 = null;
		exact_old = false;
	}
	if (!exact_old) {
		transaction.applied = null;
		transaction.sha256 = null;
		storage.atomic_write(runtime, BINARY, old.content, 0o700);
		verify_binary(runtime, authority, old.hash);
		transaction.applied = false;
		transaction.sha256 = old.hash;
	}
	if (was_running) {
		app.service.start('config.yaml');
		if (app.service.wait_ready(runtime.clock.now() + 15000,
		    'config.yaml', {})?.ok !== true)
			errors.fail('INTERNAL');
		try { verify_binary(runtime, authority, old.hash); }
		catch (error) {
			transaction.applied = null;
			transaction.sha256 = null;
			errors.fail(errors.normalize(error).code);
		}
	}
	else if (observed_service(app).running)
		errors.fail('INTERNAL');
	transaction.recovery_state = 'restored';
};

function install_kernel(app, candidate, resolved, ctx, transaction) {
	let runtime = app.runtime, authority = binary_authority(runtime);
	let old = binary_snapshot(runtime, authority);
	transaction.applied = false;
	transaction.sha256 = old.hash;
	ctx.stage('preserve', 50, 'preserve');
	let previous_id = preserve(runtime, old, authority);
	ctx.stage('transition', 55, 'transition');
	try {
		if (!verify_snapshot(runtime, old)) errors.fail('INTERNAL');
		verify_authority(runtime, authority);
	}
	catch (error) {
		transaction.applied = null;
		transaction.sha256 = null;
		errors.fail(errors.normalize(error).code);
	}
	verify_owned(runtime, candidate);
	let observed = observed_service(app), began = false;
	transaction.stage = 'transition';
	transaction.recovery_state = 'not_needed';
	try {
		ctx.stage('install', 75, 'install');
		if (observed.running) {
			began = true;
			app.service.stop('config.yaml');
			if (app.service.wait_ready(runtime.clock.now() + 5000,
			    'config.yaml', { stopped: true })?.ok !== true)
				errors.fail('HEALTH_FAILED');
		}
		began = true;
		verify_authority(runtime, authority);
		verify_owned(runtime, candidate);
		transaction.applied = null;
		transaction.sha256 = null;
		storage.atomic_write(runtime, BINARY, candidate.content, 0o700);
		verify_binary(runtime, authority, candidate.hash);
		transaction.applied = true;
		transaction.sha256 = candidate.hash;
		if (observed.running) {
			verify_binary(runtime, authority, candidate.hash);
			app.service.start('config.yaml');
			if (app.service.wait_ready(runtime.clock.now() + 15000,
			    'config.yaml', {})?.ok !== true)
				errors.fail('HEALTH_FAILED');
			verify_binary(runtime, authority, candidate.hash);
		}
		else {
			if (observed_service(app).running)
				errors.fail('HEALTH_FAILED');
			verify_binary(runtime, authority, candidate.hash);
		}
		prune_previous(runtime, previous_id, authority);
		return { previous_id, sha256: candidate.hash };
	}
	catch (error) {
		let original = errors.normalize(error).code;
		if (began) {
			try { recover_kernel(app, authority, old, observed.running, transaction); }
			catch (recovery_error) {
				transaction.recovery_state = 'failed';
				errors.fail('INTERNAL');
			}
		}
		errors.fail(original);
	}
};

function parse_installer_checksum(runtime, resolved, installer, local_hash) {
	if (resolved.checksum_url == null)
		errors.fail('INVALID_RESPONSE');
	let body = download(runtime, resolved.checksum_url, 65536);
	let found = match(trim(body), /^([0-9A-Fa-f]{64})[ \t]+\*?install-miclash\.sh$/);
	if (found == null)
		errors.fail('INVALID_RESPONSE');
	if (lc(found[1]) != local_hash)
		errors.fail('VALIDATION_FAILED');
	return true;
};

function prepare_installer(runtime, resolved) {
	let authority = update_authority(runtime);
	let body = download(runtime, resolved.installer_url, 1048576);
	if (type(body) != 'string' || length(body) < 10 ||
	    substr(body, 0, 10) != '#!/bin/sh\n' || index(body, sprintf('%c', 0)) >= 0)
		errors.fail('VALIDATION_FAILED');
	let hash = runtime.digest.sha256(body);
	let published = parse_installer_checksum(runtime, resolved, body, hash);
	let token = runtime.random.hex(16);
	if (type(token) != 'string' || !match(token, /^[0-9a-f]{32}$/))
		errors.fail('INTERNAL');
	let candidate = write_exclusive(runtime, UPDATE_ROOT + '/' + token + '.sh', body,
		0o700, authority);
	candidate.published_checksum_verified = published;
	let shell = busybox_capability(runtime);
	if (!response_ok(run_checked(runtime, shell, { command: BUSYBOX,
		args: [ 'ash', '-n', candidate.path ], timeout_ms: 30000 }, [ candidate ]))) {
		remove_owned(runtime, candidate);
		errors.fail('VALIDATION_FAILED');
	}
	verify_owned(runtime, candidate);
	candidate.shell = shell;
	return candidate;
};


function consume_handoff(runtime, authority, path, token, expected_version, started_at) {
	verify_authority(runtime, authority);
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
	verify_authority(runtime, authority);
	return { path, identity: after, authority, mode: 0o600,
		hash: runtime.digest.sha256(body) };
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
		previous_id: null, error_code: null, applied: null, recovery_state: null,
		updated_at: app.runtime.clock.now() };
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
				ready: resolved.ready, readiness: resolved.readiness,
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
			let candidate = null, resolved = null, installed = null;
			let transaction = { applied: null, sha256: null,
				recovery_state: 'not_started', stage: 'verification' };
			try {
				ctx.stage('release', 10, 'release');
				resolved = resolve_mihomo(app.runtime, selected_channel, requested);
				ctx.stage('verification', 45, 'verification');
				candidate = prepare_kernel(app.runtime, resolved);
				installed = install_kernel(app, candidate, resolved, ctx, transaction);
				transaction.stage = 'cleanup';
				remove_owned(app.runtime, candidate);
				candidate = null;
				set_status({ state: 'success', kind: 'mihomo', stage: 'done',
					operation_id: ctx.id, version: resolved.version,
					sha256: installed.sha256,
					published_checksum_verified: candidate?.published_checksum_verified ??
						(resolved.checksum_url != null),
					previous_id: installed.previous_id, error_code: null,
					applied: true, recovery_state: 'not_needed',
					updated_at: app.runtime.clock.now() });
			}
			catch (error) {
				let normalized = errors.normalize(error);
				if (candidate != null) {
					try { remove_owned(app.runtime, candidate); }
					catch (cleanup_error) {
						normalized = errors.new('INTERNAL');
						transaction.stage = 'cleanup';
					}
					candidate = null;
				}
				set_status({ state: 'failure', kind: 'mihomo', stage: transaction.stage,
					operation_id: ctx.id, version: resolved?.version ?? requested,
					sha256: transaction.sha256,
					published_checksum_verified: null,
					previous_id: installed?.previous_id ?? null,
					error_code: normalized.code, applied: transaction.applied,
					recovery_state: transaction.recovery_state,
					updated_at: app.runtime.clock.now() });
				ctx.complete(normalized);
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
			let transaction = { applied: null, sha256: null,
				recovery_state: 'not_started', stage: 'verification' }, installed = null;
			try {
				ctx.stage('verification', 45, 'verification');
				let candidate = previous(app.runtime, id);
				candidate.published_checksum_verified = null;
				validate_kernel_candidate(app.runtime, candidate);
				installed = install_kernel(app, candidate, { version: null }, ctx, transaction);
				set_status({ state: 'success', kind: 'mihomo', stage: 'done',
					operation_id: ctx.id, version: null, sha256: installed.sha256,
					published_checksum_verified: null,
					previous_id: installed.previous_id, error_code: null,
					applied: true, recovery_state: 'not_needed',
					updated_at: app.runtime.clock.now() });
			}
			catch (error) {
				let normalized = errors.normalize(error);
				set_status({ state: 'failure', kind: 'mihomo', stage: transaction.stage,
					operation_id: ctx.id, version: null,
					sha256: transaction.sha256,
					published_checksum_verified: null, previous_id: id,
					error_code: normalized.code, applied: transaction.applied,
					recovery_state: transaction.recovery_state,
					updated_at: app.runtime.clock.now() });
				ctx.complete(normalized);
				return false;
			}
			return true;
		});
	};
	function submit_miclash(options, source, pre_enqueue) {
		exact(options, { version: true, channel: true });
		if (pre_enqueue != null && type(pre_enqueue) != 'function')
			invalid();
		let selected_channel = configured_channel('miclash', options.channel);
		let requested = options.version == null ? null : version(options.version);
		return app.operations.submit('updates.miclash', source, {}, (ctx) => {
			let candidate = null, handoff = null, resolved = null;
			let applied_hash = null, published = null;
			let transaction = { applied: false, recovery_state: 'not_started',
				stage: 'verification' };
			try {
				ctx.stage('release', 10, 'release');
				resolved = choose_miclash(app.runtime, selected_channel, requested);
				if (resolved.ready !== true)
					errors.fail('NOT_FOUND');
				ctx.stage('verification', 45, 'verification');
				candidate = prepare_installer(app.runtime, resolved);
				let token = app.runtime.random.hex(16);
				if (type(token) != 'string' || !match(token, /^[0-9a-f]{32}$/))
					errors.fail('INTERNAL');
				let handoff_path = UPDATE_ROOT + '/handoff-' + ctx.id + '.status';
				verify_authority(app.runtime, candidate.authority);
				if (app.runtime.fs.lstat(handoff_path) != null)
					errors.fail('INTERNAL');
				ctx.stage('install', 75, 'install');
				transaction.stage = 'install';
				transaction.applied = null;
				transaction.recovery_state = 'unavailable';
				let handoff_started = int(app.runtime.clock.now() / 1000);
				let reply = run_checked(app.runtime, candidate.shell,
					{ command: BUSYBOX, args: [
					'ash', candidate.path, 'app', '--target-tag', resolved.version,
					'--mode', 'update', '--status-file', handoff_path, '--token', token
				], timeout_ms: 600000 }, [ candidate ]);
				if (!response_ok(reply))
					errors.fail('HEALTH_FAILED');
				handoff = consume_handoff(app.runtime, candidate.authority,
					handoff_path, token,
					resolved.version, handoff_started);
				transaction.applied = true;
				transaction.stage = 'cleanup';
				applied_hash = candidate.hash;
				published = candidate.published_checksum_verified;
				remove_owned(app.runtime, handoff);
				handoff = null;
				remove_owned(app.runtime, candidate);
				candidate = null;
				set_status({ state: 'success', kind: 'miclash', stage: 'done',
					operation_id: ctx.id, version: resolved.version, sha256: applied_hash,
					published_checksum_verified: published,
					previous_id: null, error_code: null, applied: true,
					recovery_state: 'unavailable',
					updated_at: app.runtime.clock.now() });
			}
			catch (error) {
				let normalized = errors.normalize(error);
				if (handoff == null) {
					let candidate_path = UPDATE_ROOT + '/handoff-' + ctx.id + '.status';
					if (app.runtime.fs.lstat(candidate_path)?.type == 'file')
						try {
							handoff = file_snapshot(app.runtime, candidate_path,
								candidate?.authority ?? update_authority(app.runtime), 0o600);
							handoff.mode = 0o600;
						}
						catch (handoff_error) {
							normalized = errors.new('INTERNAL');
							transaction.stage = 'cleanup';
						}
				}
				for (let owned in [ handoff, candidate ])
					if (owned != null)
						try { remove_owned(app.runtime, owned); }
						catch (cleanup_error) {
							normalized = errors.new('INTERNAL');
							transaction.stage = 'cleanup';
						}
				set_status({ state: 'failure', kind: 'miclash', stage: transaction.stage,
					operation_id: ctx.id, version: resolved?.version ?? requested,
					sha256: candidate?.hash ?? null,
					published_checksum_verified:
						candidate?.published_checksum_verified ?? null,
					previous_id: null, error_code: normalized.code,
					applied: transaction.applied,
					recovery_state: transaction.recovery_state,
					updated_at: app.runtime.clock.now() });
				ctx.complete(normalized);
				return false;
			}
			return true;
		}, pre_enqueue);
	};
	function update_miclash(...args) {
		if (length(args) != 2) invalid();
		return submit_miclash(args[0], args[1], null);
	};
	function update_miclash_scheduled(...args) {
		if (length(args) != 3 || type(args[2]) != 'function') invalid();
		return submit_miclash(args[0], args[1], args[2]);
	};
	return {
		release_info, update_mihomo,
		rollback_mihomo,
		update_miclash, update_miclash_scheduled,
		status: (...args) => {
			if (length(args)) invalid();
			return json(sprintf('%J', last));
		}
	};
};
