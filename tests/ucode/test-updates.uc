import * as operations from 'miclash.operations';
import * as updates from 'miclash.updates';
import { assert_equal, assert_throws, assert_true } from './testlib.uc';
import * as fakes from 'fakes';

const RELEASE_LATEST =
	'https://api.github.com/repos/MetaCubeX/mihomo/releases/latest';
const RELEASES =
	'https://api.github.com/repos/MetaCubeX/mihomo/releases?per_page=20';
const RELEASE_TAG =
	'https://api.github.com/repos/MetaCubeX/mihomo/releases/tags/v1.2.3';
const MICLASH_LATEST =
	'https://api.github.com/repos/ang3el7z/luci-app-miclash/releases/latest';
const MICLASH_RELEASES =
	'https://api.github.com/repos/ang3el7z/luci-app-miclash/releases?per_page=20';
const MICLASH_INSTALLER =
	'https://raw.githubusercontent.com/ang3el7z/luci-app-miclash/v9.9.9/install-miclash.sh';
const MICLASH_TAG =
	'https://api.github.com/repos/ang3el7z/luci-app-miclash/releases/tags/v9.9.9';
const MICLASH_CHECKSUM =
	'https://github.com/ang3el7z/luci-app-miclash/releases/download/v9.9.9/' +
	'install-miclash.sh.sha256';

function fixture(name) {
	return require('fs').readfile('tests/fixtures/releases/' + name);
};

function curl_request(filesystem, args) {
	let config_path = args[1], config = filesystem.readfile(config_path);
	let output = match(config, /output = "([^"]+)"/);
	let header = match(config, /dump-header = "([^"]+)"/);
	let url = match(config, /url = "([^"]+)"/);
	return { output: output?.[1], header: header?.[1], url: url?.[1] };
};

function assert_intent_unchanged(service_calls, label) {
	for (let call in service_calls)
		assert_true(call != 'enabled' && call != 'enable' && call != 'disable', label);
};

function environment(options) {
	options ??= {};
	let old = options.old ?? 'old mihomo binary';
	let filesystem = fakes.fs({
		'/etc/openwrt_release': "DISTRIB_ARCH='" +
			(options.arch ?? 'aarch64_cortex-a53') + "'\n",
		'/opt/clash/bin/clash': old,
		'/opt/clash/config.yaml': 'mixed-port: 7890\n',
		'/usr/libexec/miclash/decompress-gzip': 'trusted helper',
		'/bin/busybox': 'trusted busybox'
	});
	for (let directory in [ '/tmp', '/tmp/miclash', '/var', '/var/run',
		'/var/run/miclash', '/opt/clash/bin/previous' ])
		if (filesystem.lstat(directory) == null)
			filesystem.mkdir(directory);
	if (options.previous_device != null)
		filesystem.set_device('/opt/clash/bin/previous', options.previous_device);
	for (let path, content in options.extra_files ?? {}) {
		filesystem.writefile(path, content);
		filesystem.chmod(path, options.extra_modes?.[path] ?? 0o700);
	}
	filesystem.chmod('/opt/clash/bin/clash', 0o700);
	for (let target in options.extra_binary_links ?? [])
		filesystem.link('/opt/clash/bin/clash', target);
	if (options.fail_startup_link_cleanup)
		filesystem.fail_unlink_once_matching =
			'/opt/clash/bin/previous/mihomo-';
	filesystem.chmod('/usr/libexec/miclash/decompress-gzip', 0o755);
	filesystem.chmod('/bin/busybox', 0o755);
	if (options.foreign_bin_parent) filesystem.set_uid('/opt/clash/bin', 1000);
	if (options.foreign_helper_parent)
		filesystem.set_uid('/usr/libexec/miclash', 1000);
	if (options.fail_binary_write) filesystem.fail_rename_once_to = '/opt/clash/bin/clash';
	if (options.partial_binary_write)
		filesystem.throw_after_rename_once_to = '/opt/clash/bin/clash';
	let clock = fakes.clock(1700000000000);
	let manager = options.manager ?? 'opkg';
	if (manager == 'apk') {
		filesystem.writefile('/usr/bin/apk', 'trusted apk');
		filesystem.chmod('/usr/bin/apk', 0o755);
	}
	else if (manager == 'opkg') {
		filesystem.writefile('/bin/opkg', 'trusted opkg');
		filesystem.chmod('/bin/opkg', 0o755);
	}
	let process = fakes.process({
		'/usr/bin/apk:--version': { code: manager == 'apk' ? 0 : 127 },
		'/bin/apk:--version': { code: 127 },
		'/bin/opkg:--version': { code: manager == 'opkg' ? 0 : 127 },
		'/usr/bin/opkg:--version': { code: 127 }
	});
	if (options.stale_handoff) {
		filesystem.on_lstat = (path, count) => {
			if (count == 1 && match(path, /\/handoff-.*\.status$/)) {
				filesystem.writefile(path,
					'protocol=miclash-update-status-v1\ntoken=' +
					'0123456789abcdef0123456789abcdef\nstate=success\n' +
					'phase=done\ntarget_version=v9.9.9\nupdated_at=1\n');
				filesystem.chmod(path, 0o600);
			}
		};
	}
	let gzip_body = options.gzip_body ?? 'GZIP:new mihomo binary';
	let mihomo_digest = options.mihomo_digest ?? require('digest').sha256(gzip_body);
	let mihomo_release = json(fixture('mihomo-release.json'));
	let mihomo_prereleases = json(fixture('mihomo-prereleases.json'));
	for (let release in [ mihomo_release, ...mihomo_prereleases ]) {
		for (let asset in release.assets ?? []) {
			if (match(asset?.name, /^mihomo-linux-.*\.gz$/) &&
			    options.mihomo_without_digest !== true)
				asset.digest = 'sha256:' + (asset.name ==
					'mihomo-linux-arm64-v1.2.3.gz' ? mihomo_digest : sprintf('%064x', 0));
		}
	}
	let responses = {
		[RELEASE_LATEST]: sprintf('%J', mihomo_release),
		[RELEASES]: sprintf('%J', mihomo_prereleases),
		[RELEASE_TAG]: sprintf('%J', mihomo_release),
		[MICLASH_LATEST]: fixture('miclash-release.json'),
		[MICLASH_TAG]: fixture('miclash-release.json'),
		[MICLASH_RELEASES]: '[' + replace(fixture('miclash-release.json'),
			'"prerelease": false', '"prerelease": true') + ']',
		[MICLASH_INSTALLER]: options.installer ?? '#!/bin/sh\nexit 0\n',
		[MICLASH_CHECKSUM]: require('digest').sha256(
			options.installer ?? '#!/bin/sh\nexit 0\n') + '  install-miclash.sh\n'
	};
	for (let url, body in options.responses ?? {})
		responses[url] = body;
	let asset_url =
		'https://github.com/MetaCubeX/mihomo/releases/download/v1.2.3/' +
		'mihomo-linux-arm64-v1.2.3.gz';
	responses[asset_url] = gzip_body;
	let service_calls = [], wait_calls = [], curl_urls = [], running = options.running === true,
		enabled = options.enabled === true, start_count = 0;
	let stop_count = 0, stopped_wait_failed = false;
	let unknown_after_stop = options.unknown_after_stop === true, observe_count = 0;
	let readiness = [ ...(options.readiness ?? []) ], wait_count = 0;
	let service = {
		observe: () => {
			observe_count++;
			if (options.unknown_observe_at == observe_count)
				return { state: 'unknown', running: false };
			if (!running && stop_count > 0 && unknown_after_stop) {
				unknown_after_stop = false;
				return { state: 'unknown', running: false };
			}
			if (!running && options.hardlink_reports_missing_kernel &&
			    filesystem.lstat('/opt/clash/bin/clash')?.nlink == 2)
				return { state: 'missing_kernel', running: false };
			return { state: running ? 'running' : 'stopped', running };
		},
		enabled: () => { push(service_calls, 'enabled'); return enabled; },
		enable: () => { push(service_calls, 'enable'); enabled = true; },
		disable: () => { push(service_calls, 'disable'); enabled = false; },
		stop: () => {
			push(service_calls, 'stop'); stop_count++;
			if (!(options.stop_stays_running_once && stop_count == 1))
				running = false;
			if (options.restore_write_fail && stop_count == 2)
				filesystem.fail_rename_once = true;
			if (options.stop_throw_once && stop_count == 1) die('HEALTH_FAILED');
		},
		start: () => {
			push(service_calls, 'start'); running = true; start_count++;
			if (options.new_start_throw && start_count == 1) die('HEALTH_FAILED');
			if (options.old_start_throw && start_count == 2) die('HEALTH_FAILED');
		},
		wait_ready: (deadline, profile, wait_options) => {
			push(wait_calls, { deadline, profile, options: wait_options ?? {} });
			wait_count++;
			if (wait_options?.stopped === true &&
			    options.hardlink_reports_missing_kernel &&
			    filesystem.lstat('/opt/clash/bin/clash')?.nlink == 2)
				return { ok: false, timed_out: true, components: [] };
			if (options.wait_stopped_fail_once && wait_options?.stopped === true &&
			    !stopped_wait_failed) {
				stopped_wait_failed = true;
				return { ok: false, timed_out: true, components: [] };
			}
			let ok = length(readiness) ? shift(readiness) : true;
			if (ok && options.tamper_binary_after_new_ready &&
			    wait_options?.stopped !== true && start_count == 1)
				filesystem.writefile('/opt/clash/bin/clash', 'tampered after readiness');
			if (ok && options.fail_kernel_cleanup && wait_options?.stopped !== true &&
			    start_count == 1)
				filesystem.fail_unlink_once_matching = '/tmp/miclash/updates/';
			return { ok, timed_out: !ok, components: [] };
		}
	};
	process.on_run = (request) => {
	if (request.command == '/usr/bin/curl') {
			let curl = curl_request(filesystem, request.args);
			push(curl_urls, curl.url);
			let body = responses[curl.url];
			if (body == null) {
				process.replies[request.command + ':' + join(' ', request.args)] = { code: 22 };
				body = '';
			}
			filesystem.writefile(curl.output, body);
			filesystem.writefile(curl.header, 'HTTP/1.1 200 OK\r\nContent-Length: ' +
				length(body) + '\r\n\r\n');
		}
		else if (request.command == '/bin/gzip' ||
		    request.command == '/usr/libexec/miclash/decompress-gzip') {
			let compressed = request.command == '/bin/gzip' ?
				request.args[length(request.args) - 1] : request.args[0];
			let output = request.command == '/bin/gzip' ?
				substr(compressed, 0, length(compressed) - 3) : request.args[1];
			let body = filesystem.readfile(compressed);
			if (substr(body, 0, 5) == 'GZIP:') {
				filesystem.writefile(output, substr(body, 5));
				if (request.command == '/bin/gzip') filesystem.unlink(compressed);
				if (options.replace_helper_during_unpack &&
				    request.command == '/usr/libexec/miclash/decompress-gzip')
					filesystem.bump_inode('/usr/libexec/miclash/decompress-gzip');
			}
			else
				process.replies[request.command + ':' + join(' ', request.args)] = { code: 1 };
		}
		else if (substr(request.command, 0, length('/tmp/miclash/updates/')) ==
		    '/tmp/miclash/updates/' ||
		    substr(request.command, 0, length('/opt/clash/bin/previous/')) ==
		    '/opt/clash/bin/previous/') {
			if (options.fail_version && request.args[0] == '-v' ||
			    options.fail_config && request.args[0] == '-d' ||
			    options.fail_rollback_version &&
			      substr(request.command, 0, length('/opt/clash/bin/previous/')) ==
			      '/opt/clash/bin/previous/' && request.args[0] == '-v')
				process.replies[request.command + ':' + join(' ', request.args)] = { code: 1 };
		}
		else if (request.command == '/bin/busybox') {
			let key = request.command + ':' + join(' ', request.args);
			if (request.args[0] == 'ln') {
				if (filesystem.link(request.args[1], request.args[2]) != true)
					process.replies[key] = { code: 1 };
				else if (options.link_reports_failure)
					process.replies[key] = { code: 1 };
				else if (options.link_throws_after_create)
					die('INTERNAL');
			}
			else if (request.args[0] == 'ash' && request.args[1] == '-n') {
				if (options.fail_installer_syntax)
					process.replies[key] = { code: 2 };
				if (options.replace_ash_during_syntax) filesystem.bump_inode('/bin/busybox');
			}
			else {
				if (options.installer_starts_service) running = true;
				let status_path = request.args[index(request.args, '--status-file') + 1];
				let token = request.args[index(request.args, '--token') + 1];
				let service_was_running =
					request.args[index(request.args, '--service-was-running') + 1];
				filesystem.writefile(status_path,
					'protocol=miclash-update-status-v1\n' +
					'token=' + (options.forged_handoff ?
						'fedcba9876543210fedcba9876543210' : token) + '\n' +
					'state=success\nphase=done\n' +
					'target_version=v9.9.9\n' +
					'service_was_running=' + service_was_running + '\n' +
					'postcheck=pending\nupdated_at=' +
					(options.stale_timestamp ? '1' : '1700000000') + '\n' +
					(options.extra_handoff_field ? 'unexpected=value\n' : ''));
				if (options.weak_handoff) filesystem.chmod(status_path, 0o644);
				if (options.fail_handoff_cleanup)
					filesystem.fail_unlink_once_matching = 'handoff-';
				if (options.fail_installer_cleanup)
					filesystem.fail_unlink_once_matching = '.sh';
				if (options.fail_installer_run)
					process.replies[key] = { code: 1 };
			}
		}
	};
	let digest = fakes.digest(filesystem);
	let runtime = {
		fs: filesystem, clock, process, digest,
		random: fakes.entropy(), paths: { tmp: '/tmp/miclash' },
		update_options: options.update_options ?? { max_kernel_bytes: 1024 }
	};
	let ops = operations.create(runtime);
	let app = {
		runtime, operations: ops, service,
		settings: { get: () => ({ updates: {
			mihomo_release_channel: options.channel ?? 'release',
			miclash_release_channel: options.miclash_channel ?? 'release'
		} }) }
	};
	return { filesystem, clock, process, digest, ops, service_calls, wait_calls, curl_urls,
		updater: updates.create(app) };
};

assert_equal(type(updates.create), 'function');
let stable = environment();
for (let method in [ 'release_info', 'update_mihomo', 'rollback_mihomo',
	'update_miclash', 'update_miclash_scheduled', 'status' ])
assert_equal(type(stable.updater[method]), 'function', method + ' is exported');

let orphan_token = '0123456789abcdef0123456789abcdef';
let orphan_hash = sprintf('%064d', 1);
let orphan_handoff =
	'/tmp/miclash/updates/handoff-1700000000000-00000001-0123456789abcdef.status';
let orphan_atomic = '/opt/clash/bin/previous/.mihomo-' + orphan_hash +
	'.miclash.1700000000000-1.abcdef01';
let orphaned = environment({ extra_files: {
	['/tmp/miclash/updates/' + orphan_token]: 'decompressed orphan',
	['/tmp/miclash/updates/' + orphan_token + '.gz']: 'compressed orphan',
	[orphan_handoff]: 'handoff orphan',
	[orphan_atomic]: 'partial previous snapshot',
	'/tmp/miclash/updates/administrator-note': 'keep',
	'/opt/clash/bin/previous/administrator-note': 'keep'
}, extra_modes: {
	['/tmp/miclash/updates/' + orphan_token + '.gz']: 0o600,
	[orphan_handoff]: 0o600,
	[orphan_atomic]: 0o600
} });
assert_equal(orphaned.filesystem.exists('/tmp/miclash/updates/' + orphan_token), false);
assert_equal(orphaned.filesystem.exists('/tmp/miclash/updates/' + orphan_token + '.gz'), false);
assert_equal(orphaned.filesystem.exists(orphan_handoff), false);
assert_equal(orphaned.filesystem.exists(orphan_atomic), false);
assert_equal(orphaned.filesystem.readfile('/tmp/miclash/updates/administrator-note'), 'keep');
assert_equal(orphaned.filesystem.readfile(
	'/opt/clash/bin/previous/administrator-note'), 'keep');

let info = stable.updater.release_info({ kind: 'mihomo' });
assert_equal(info.version, 'v1.2.3');
assert_equal(info.architecture, 'arm64');
assert_equal(info.asset_name, 'mihomo-linux-arm64-v1.2.3.gz');
assert_equal(info.published_checksum_available, true);
assert_true(index(sprintf('%J', info), 'github.com') < 0,
	'release_info does not expose persisted transport URLs');

let prerelease = environment({ channel: 'prerelease' });
assert_equal(prerelease.updater.release_info({ kind: 'mihomo' }).version,
	'v2.0.0-beta.1');
let amd64 = environment({ arch: 'x86_64' });
assert_equal(amd64.updater.release_info({ kind: 'mihomo' }).architecture, 'amd64');
assert_throws(() => environment({ arch: 'riscv64_generic' }).updater
	.release_info({ kind: 'mihomo' }), 'INVALID_ARGUMENT');

let verified = environment();
let verified_op = verified.updater.update_mihomo({ version: 'v1.2.3' }, 'luci');
verified.clock.advance(0);
assert_equal(verified.ops.get(verified_op.id).state, 'success');
assert_equal(verified.updater.status().published_checksum_verified, true);
assert_equal(length(verified.service_calls), 0);
let bounded_unpack = [];
for (let call in verified.process.calls) {
	assert_true(call.command != '/bin/gzip', 'raw gzip cannot expand without a byte ceiling');
	if (call.command == '/usr/libexec/miclash/decompress-gzip')
		push(bounded_unpack, call);
}
assert_equal(length(bounded_unpack), 1);
assert_equal(length(bounded_unpack[0].args), 3);
assert_equal(bounded_unpack[0].args[2], '1024');

// A 256 MB router cannot afford full ucode strings for both the old and new
// Mihomo binaries. Large executables must only move through bounded fs reads.
let bounded_memory = environment();
bounded_memory.filesystem.on_readfile = (path) => {
	if (path == '/opt/clash/bin/clash' ||
	    (substr(path, 0, length('/tmp/miclash/updates/')) ==
	      '/tmp/miclash/updates/' && substr(path, -3) != '.gz') ||
	    substr(path, 0, length('/opt/clash/bin/previous/')) ==
	      '/opt/clash/bin/previous/')
		die('large binary readfile is forbidden');
};
let bounded_memory_op = bounded_memory.updater.update_mihomo(
	{ version: 'v1.2.3' }, 'luci');
bounded_memory.clock.advance(0);
assert_equal(bounded_memory.ops.get(bounded_memory_op.id).state, 'success');
assert_equal(bounded_memory.filesystem.files['/opt/clash/bin/clash'],
	'new mihomo binary');
assert_true(length(bounded_memory.filesystem.calls.read) >= 3,
	'candidate, snapshot and install use streamed reads');
for (let call in bounded_memory.filesystem.calls.read)
	assert_true(call.amount <= 65536, 'Mihomo stream exceeded the memory bound');

let without_digest_release = json(fixture('mihomo-release.json'));
let without_digest = environment({ responses: {
	[RELEASE_TAG]: sprintf('%J', without_digest_release)
} });
let local_op = without_digest.updater.update_mihomo({ version: 'v1.2.3' }, 'luci');
without_digest.clock.advance(0);
assert_equal(without_digest.ops.get(local_op.id).state, 'failure');
assert_equal(without_digest.ops.get(local_op.id).error.code, 'INVALID_RESPONSE');
assert_equal(join(',', without_digest.curl_urls), RELEASE_TAG,
	'Mihomo release without a GitHub digest does not request its asset');
assert_equal(length(without_digest.service_calls), 0,
	'Mihomo release without a GitHub digest fails before service stop');

let metadata_checksum_release = json(fixture('mihomo-release.json'));
metadata_checksum_release.assets = [ metadata_checksum_release.assets[0] ];
metadata_checksum_release.assets[0].digest = 'sha256:' +
	require('digest').sha256('GZIP:new mihomo binary');
let metadata_checksum = environment({ responses: {
	[RELEASE_TAG]: sprintf('%J', metadata_checksum_release)
} });
let metadata_checksum_op = metadata_checksum.updater.update_mihomo(
	{ version: 'v1.2.3' }, 'luci');
metadata_checksum.clock.advance(0);
assert_equal(metadata_checksum.ops.get(metadata_checksum_op.id).state, 'success');
assert_equal(metadata_checksum.updater.status().published_checksum_verified, true);
assert_equal(length(metadata_checksum.service_calls), 0,
	'GitHub asset digest verifies Mihomo without a sidecar checksum file');

let mismatch = environment({ mihomo_digest: sprintf('%064d', 0) });
let mismatch_op = mismatch.updater.update_mihomo({ version: 'v1.2.3' }, 'luci');
mismatch.clock.advance(0);
assert_equal(mismatch.ops.get(mismatch_op.id).state, 'failure');
assert_equal(mismatch.ops.get(mismatch_op.id).error.code, 'VALIDATION_FAILED');
assert_equal(length(mismatch.service_calls), 0,
	'checksum mismatch fails before service stop');

// Corrupt/oversized gzip and both offline candidate executions fail before the
// currently active service or binary is touched.
for (let scenario in [
	{ gzip_body: 'truncated' },
	{ gzip_body: 'GZIP:' + sprintf('%065d', 1), update_options: { max_kernel_bytes: 64 } },
	{ fail_version: true },
	{ fail_config: true }
]) {
	let rejected = environment({ ...scenario, running: true });
	let old_hash = rejected.filesystem.readfile('/opt/clash/bin/clash');
	let operation = rejected.updater.update_mihomo({ version: 'v1.2.3' }, 'luci');
	rejected.clock.advance(0);
	assert_equal(rejected.ops.get(operation.id).state, 'failure');
	assert_equal(length(rejected.service_calls), 0);
	assert_equal(rejected.filesystem.readfile('/opt/clash/bin/clash'), old_hash);
}

// A stopped service stays stopped; a running service is stopped only after all
// offline checks, then restarted. The exact old bytes are preserved by hash.
let stopped = environment();
let stopped_update = stopped.updater.update_mihomo({ version: 'v1.2.3' }, 'luci');
stopped.clock.advance(0);
assert_equal(stopped.ops.get(stopped_update.id).state, 'success');
assert_equal(length(stopped.service_calls), 0);
assert_equal(stopped.filesystem.readfile('/opt/clash/bin/clash'), 'new mihomo binary');
let old_hash = require('digest').sha256('old mihomo binary');
let previous_id = 'mihomo-' + old_hash;
assert_equal(stopped.filesystem.readfile('/opt/clash/bin/previous/' + previous_id),
	'old mihomo binary');
assert_equal(stopped.updater.status().previous_id, previous_id);
assert_equal(length(stopped.filesystem.calls.link), 1,
	'old Mihomo snapshot uses one same-filesystem hardlink');
for (let call in stopped.filesystem.calls.read)
	assert_true(call.path != '/opt/clash/bin/clash',
		'preserving Mihomo must not write a second full old-binary copy');

let cross_device_snapshot = environment({ running: true, previous_device: 2 });
let cross_device_op = cross_device_snapshot.updater.update_mihomo(
	{ version: 'v1.2.3' }, 'luci');
cross_device_snapshot.clock.advance(0);
assert_equal(cross_device_snapshot.ops.get(cross_device_op.id).state, 'failure',
	'preservation rejects a previous directory on another filesystem');
assert_equal(length(cross_device_snapshot.service_calls), 0);

// A prior rollback snapshot with the same hash is replaced by a hardlink
// before install, releasing its duplicate flash blocks on small overlays.
let reused_snapshot = environment();
reused_snapshot.filesystem.writefile('/opt/clash/bin/previous/' + previous_id,
	'old mihomo binary');
reused_snapshot.filesystem.chmod('/opt/clash/bin/previous/' + previous_id, 0o700);
let reused_snapshot_op = reused_snapshot.updater.update_mihomo(
	{ version: 'v1.2.3' }, 'luci');
reused_snapshot.clock.advance(0);
assert_equal(reused_snapshot.ops.get(reused_snapshot_op.id).state, 'success');
assert_equal(length(reused_snapshot.filesystem.calls.link), 1);
assert_equal(reused_snapshot.filesystem.readfile(
	'/opt/clash/bin/previous/' + previous_id), 'old mihomo binary');

let interrupted_link = environment({ extra_binary_links: [
	'/opt/clash/bin/previous/' + previous_id
] });
assert_equal(interrupted_link.filesystem.lstat('/opt/clash/bin/clash').nlink, 1,
	'updater startup normalizes an exact interrupted preservation link');
assert_equal(interrupted_link.filesystem.lstat(
	'/opt/clash/bin/previous/' + previous_id), null,
	'updater startup removes only the exact previous name after interruption');
assert_throws(() => environment({
	extra_binary_links: [ '/opt/clash/bin/previous/' + previous_id ],
	fail_startup_link_cleanup: true
}), 'INTERNAL');
let interrupted_link_op = interrupted_link.updater.update_mihomo(
	{ version: 'v1.2.3' }, 'luci');
interrupted_link.clock.advance(0);
assert_equal(interrupted_link.ops.get(interrupted_link_op.id).state, 'success',
	'interrupted hardlink snapshot is normalized before the next update');

let running = environment({ running: true });
let running_update = running.updater.update_mihomo({ version: 'v1.2.3' }, 'luci');
running.clock.advance(0);
assert_equal(running.ops.get(running_update.id).state, 'success');
assert_equal(join(',', running.service_calls), 'stop,start');
assert_equal(running.filesystem.readfile('/opt/clash/bin/clash'), 'new mihomo binary');
assert_intent_unchanged(running.service_calls,
	'Mihomo update must restore runtime without changing durable enable state');

// The service observer rejects nlink=2 as missing_kernel while the old binary
// is hardlinked for a storage-free snapshot. Stop confirmation must rely only
// on the process no longer running until atomic install restores nlink=1.
let linked_stop = environment({ running: true, hardlink_reports_missing_kernel: true });
let linked_stop_update = linked_stop.updater.update_mihomo(
	{ version: 'v1.2.3' }, 'luci');
linked_stop.clock.advance(0);
assert_equal(linked_stop.ops.get(linked_stop_update.id).state, 'success',
	'nlink=2 missing_kernel observation is a valid stopped transition');
assert_equal(join(',', linked_stop.service_calls), 'stop,start');

let unknown_stop = environment({ running: true, unknown_after_stop: true });
let unknown_stop_update = unknown_stop.updater.update_mihomo(
	{ version: 'v1.2.3' }, 'luci');
unknown_stop.clock.advance(0);
assert_equal(unknown_stop.ops.get(unknown_stop_update.id).state, 'failure',
	'unknown observation does not prove the process stopped');
assert_equal(unknown_stop.filesystem.readfile('/opt/clash/bin/clash'),
	'old mihomo binary');

// Failed readiness restores the exact old binary and proves it starts. A
// failure of that restoration is a distinct INTERNAL terminal state.
let unhealthy = environment({ running: true, readiness: [ false, true, true ] });
let unhealthy_update = unhealthy.updater.update_mihomo({ version: 'v1.2.3' }, 'luci');
unhealthy.clock.advance(0);
assert_equal(unhealthy.ops.get(unhealthy_update.id).state, 'failure');
assert_equal(unhealthy.ops.get(unhealthy_update.id).error.code, 'HEALTH_FAILED');
assert_equal(unhealthy.filesystem.readfile('/opt/clash/bin/clash'), 'old mihomo binary');
assert_equal(join(',', unhealthy.service_calls), 'stop,start,stop,start');
let restored_from_previous = false;
for (let call in unhealthy.filesystem.calls.rename)
	if (substr(call.from, 0, length('/opt/clash/bin/previous/mihomo-')) ==
	    '/opt/clash/bin/previous/mihomo-' && call.to == '/opt/clash/bin/clash')
		restored_from_previous = true;
assert_equal(restored_from_previous, true,
	'failed readiness atomically moves the preserved inode back over BINARY');

let restore_failed = environment({ running: true,
	readiness: [ false, true ], restore_write_fail: true });
let restore_failed_update = restore_failed.updater.update_mihomo(
	{ version: 'v1.2.3' }, 'luci');
restore_failed.clock.advance(0);
assert_equal(restore_failed.ops.get(restore_failed_update.id).state, 'failure');
assert_equal(restore_failed.ops.get(restore_failed_update.id).error.code, 'INTERNAL');
assert_true(restore_failed.filesystem.lstat('/opt/clash/bin/clash') != null,
	'failed atomic rollback never leaves the kernel path absent');

let stopped_unknown_recovery = environment({
	fail_binary_write: true, unknown_observe_at: 3
});
let stopped_unknown_op = stopped_unknown_recovery.updater.update_mihomo(
	{ version: 'v1.2.3' }, 'luci');
stopped_unknown_recovery.clock.advance(0);
assert_equal(stopped_unknown_recovery.ops.get(stopped_unknown_op.id).state, 'failure');
assert_equal(stopped_unknown_recovery.updater.status().recovery_state, 'failed',
	'unknown observation cannot prove a stopped-service recovery');

// Explicit rollback consumes only the opaque previous id and itself uses the
// same stopped/running atomic transaction without touching durable intent.
let stopped_rollback = environment({ old: 'current binary' });
stopped_rollback.filesystem.writefile('/opt/clash/bin/previous/' + previous_id,
	'old mihomo binary');
stopped_rollback.filesystem.chmod('/opt/clash/bin/previous/' + previous_id, 0o700);
let stopped_rollback_op = stopped_rollback.updater.rollback_mihomo(
	{ id: previous_id }, 'luci');
stopped_rollback.clock.advance(0);
assert_equal(stopped_rollback.ops.get(stopped_rollback_op.id).state, 'success');
assert_equal(stopped_rollback.filesystem.readfile('/opt/clash/bin/clash'),
	'old mihomo binary');
assert_intent_unchanged(stopped_rollback.service_calls,
	'Mihomo stopped rollback must preserve runtime and durable enable state');
assert_equal(length(stopped_rollback.service_calls), 0);
assert_equal(stopped_rollback.updater.status().service_was_running, false);
assert_equal(stopped_rollback.updater.status().postcheck, 'stopped');

let noop_rollback = environment({ running: true });
noop_rollback.filesystem.writefile('/opt/clash/bin/previous/' + previous_id,
	'old mihomo binary');
noop_rollback.filesystem.chmod('/opt/clash/bin/previous/' + previous_id, 0o700);
let noop_rollback_op = noop_rollback.updater.rollback_mihomo(
	{ id: previous_id }, 'luci');
noop_rollback.clock.advance(0);
assert_equal(noop_rollback.ops.get(noop_rollback_op.id).state, 'success',
	'rollback to the already active hash is a verified no-op');
assert_equal(length(noop_rollback.service_calls), 0);
assert_equal(noop_rollback.filesystem.readfile('/opt/clash/bin/clash'),
	'old mihomo binary');

let rollback = environment({ old: 'current binary', running: true });
rollback.filesystem.writefile('/opt/clash/bin/previous/' + previous_id,
	'old mihomo binary');
rollback.filesystem.chmod('/opt/clash/bin/previous/' + previous_id, 0o700);
let rollback_op = rollback.updater.rollback_mihomo({ id: previous_id }, 'luci');
rollback.clock.advance(0);
assert_equal(rollback.ops.get(rollback_op.id).state, 'success',
	sprintf('%J', rollback.ops.get(rollback_op.id)));
assert_equal(rollback.filesystem.readfile('/opt/clash/bin/clash'), 'old mihomo binary');
assert_equal(join(',', rollback.service_calls), 'stop,start');
assert_intent_unchanged(rollback.service_calls,
	'Mihomo rollback must restore runtime without changing durable enable state');

// Exact architecture suffix selection is closed over known OpenWrt targets;
// duplicate matching release assets are never resolved by array order.
for (let mapping in [
	[ 'arm_cortex-a7_neon-vfpv4', 'armv7' ],
	[ 'mipsel_24kc', 'mipsle-softfloat' ],
	[ 'mips_24kc', 'mips-softfloat' ]
]) {
	let release = json(fixture('mihomo-release.json'));
	let name = 'mihomo-linux-' + mapping[1] + '-v1.2.3.gz';
	push(release.assets, { name,
		browser_download_url: 'https://github.com/MetaCubeX/mihomo/releases/download/v1.2.3/' + name,
		digest: 'sha256:' + sprintf('%064x', 0) });
	let mapped = environment({ arch: mapping[0], responses: {
		[RELEASE_LATEST]: sprintf('%J', release)
	} });
	assert_equal(mapped.updater.release_info({ kind: 'mihomo' }).architecture, mapping[1]);
}
let duplicate_release = json(fixture('mihomo-release.json'));
push(duplicate_release.assets, duplicate_release.assets[0]);
assert_throws(() => environment({ responses: {
	[RELEASE_LATEST]: sprintf('%J', duplicate_release)
} }).updater.release_info({ kind: 'mihomo' }), 'INVALID_RESPONSE');
let wrong_asset_release = json(fixture('mihomo-release.json'));
wrong_asset_release.assets[0].browser_download_url =
	'https://github.com/MetaCubeX/mihomo/releases/download/v0.0.1/' +
	wrong_asset_release.assets[0].name;
assert_throws(() => environment({ responses: {
	[RELEASE_LATEST]: sprintf('%J', wrong_asset_release)
} }).updater.release_info({ kind: 'mihomo' }), 'INVALID_RESPONSE');

// Candidate and Active identities are rechecked around each offline execution.
// A path substitution cannot cause a replaced executable or config to run.
let candidate_race = environment({ running: true });
candidate_race.process.on_run = ((original) => (request) => {
	original(request);
	if (substr(request.command, 0, length('/tmp/miclash/updates/')) ==
	    '/tmp/miclash/updates/' && request.args[0] == '-v')
		candidate_race.filesystem.bump_inode(request.command);
})(candidate_race.process.on_run);
let candidate_race_op = candidate_race.updater.update_mihomo({ version: 'v1.2.3' }, 'luci');
candidate_race.clock.advance(0);
assert_equal(candidate_race.ops.get(candidate_race_op.id).state, 'failure');
assert_equal(length(candidate_race.service_calls), 0);
let candidate_execs = 0;
for (let call in candidate_race.process.calls)
	if (substr(call.command, 0, length('/tmp/miclash/updates/')) ==
	    '/tmp/miclash/updates/') candidate_execs++;
assert_equal(candidate_execs, 1, 'replaced candidate is never executed a second time');
let active_race = environment({ running: true });
active_race.process.on_run = ((original) => (request) => {
	original(request);
	if (substr(request.command, 0, length('/tmp/miclash/updates/')) ==
	    '/tmp/miclash/updates/' && request.args[0] == '-d')
		active_race.filesystem.writefile('/opt/clash/config.yaml', 'changed\n');
})(active_race.process.on_run);
let active_race_op = active_race.updater.update_mihomo({ version: 'v1.2.3' }, 'luci');
active_race.clock.advance(0);
assert_equal(active_race.ops.get(active_race_op.id).state, 'failure');
assert_equal(length(active_race.service_calls), 0);
let linked_root = environment({ running: true });
linked_root.filesystem.set_symlink('/tmp/miclash/updates', '/opt/clash');
let linked_root_op = linked_root.updater.update_mihomo({ version: 'v1.2.3' }, 'luci');
linked_root.clock.advance(0);
assert_equal(linked_root.ops.get(linked_root_op.id).state, 'failure');
assert_equal(length(linked_root.service_calls), 0);

// Previous binaries use opaque content ids, retain a bounded set, and never
// delete foreign names from the same root-owned directory.
let retained = environment({ update_options: { max_kernel_bytes: 1024,
	previous_retention: 3 } });
for (let content in [ 'one', 'two', 'three', 'four' ]) {
	let id = 'mihomo-' + require('digest').sha256(content);
	retained.filesystem.writefile('/opt/clash/bin/previous/' + id, content);
	retained.filesystem.chmod('/opt/clash/bin/previous/' + id, 0o700);
}
retained.filesystem.writefile('/opt/clash/bin/previous/administrator-note', 'keep');
let retained_op = retained.updater.update_mihomo({ version: 'v1.2.3' }, 'luci');
retained.clock.advance(0);
assert_equal(retained.ops.get(retained_op.id).state, 'success');
let retained_count = 0;
for (let name in retained.filesystem.lsdir('/opt/clash/bin/previous'))
	if (match(name, /^mihomo-[0-9a-f]{64}$/)) retained_count++;
assert_equal(retained_count, 3);
assert_equal(retained.filesystem.readfile('/opt/clash/bin/previous/administrator-note'), 'keep');

// MiClash is fetched from an internally constructed, tag-pinned official URL,
// checked with ash -n, then receives a one-use token handoff. Neither transport
// URLs nor the token survive in public status or the central operation record.
let app_update = environment();
let app_info = app_update.updater.release_info({ kind: 'miclash' });
assert_equal(app_info.version, 'v9.9.9');
assert_equal(app_info.channel, 'release');
assert_equal(app_info.ready, true);
assert_equal(app_info.readiness, 'ready');
let apk_info = environment({ manager: 'apk' }).updater.release_info({ kind: 'miclash' });
assert_equal(apk_info.ready, true);
assert_equal(apk_info.readiness, 'ready');
let apk_rc_release = replace(fixture('miclash-release.json'), /v9\.9\.9/g, 'v2.5.2_rc1');
apk_rc_release = replace(apk_rc_release, /9\.9\.9/g, '2.5.2_rc1');
apk_rc_release = replace(apk_rc_release, '"prerelease": false', '"prerelease": true');
let apk_rc = environment({ manager: 'apk', miclash_channel: 'prerelease', responses: {
	[MICLASH_RELEASES]: '[' + apk_rc_release + ']'
} });
let apk_rc_info = apk_rc.updater.release_info({ kind: 'miclash' });
assert_equal(apk_rc_info.version, 'v2.5.2_rc1');
assert_equal(apk_rc_info.ready, true);
assert_equal(apk_rc_info.readiness, 'ready');

let pending_release = fixture('miclash-release-incomplete.json');
let pending = environment({ responses: { [MICLASH_LATEST]: pending_release } });
let pending_info = pending.updater.release_info({ kind: 'miclash' });
assert_equal(pending_info.ready, false);
assert_equal(pending_info.readiness, 'assets_pending');
let pending_op = pending.updater.update_miclash(
	{ version: null, channel: 'release' }, 'luci');
pending.clock.advance(0);
assert_equal(pending.ops.get(pending_op.id).state, 'failure');
assert_equal(pending.ops.get(pending_op.id).error.code, 'NOT_FOUND');
for (let call in pending.process.calls)
	assert_true(call.command != '/bin/busybox',
		'incomplete release reached installer validation or execution');

let duplicate_release = json(fixture('miclash-release.json'));
push(duplicate_release.assets, duplicate_release.assets[0]);
assert_throws(() => environment({ responses: {
	[MICLASH_LATEST]: sprintf('%J', duplicate_release)
} }).updater.release_info({ kind: 'miclash' }), 'INVALID_RESPONSE');
let forged_release = json(fixture('miclash-release.json'));
forged_release.assets[1].browser_download_url =
	'https://github.com/ang3el7z/luci-app-miclash/releases/download/v0.0.1/' +
	'miclash-release-manifest.json';
assert_throws(() => environment({ responses: {
	[MICLASH_LATEST]: sprintf('%J', forged_release)
} }).updater.release_info({ kind: 'miclash' }), 'INVALID_RESPONSE');
assert_throws(() => environment({ manager: 'unknown' }).updater.release_info(
	{ kind: 'miclash' }), 'HEALTH_FAILED');

let scheduled = environment(), queued_record = null;
let scheduled_op = scheduled.updater.update_miclash_scheduled(
	{ version: 'v9.9.9', channel: 'release' }, 'auto',
	(record) => queued_record = record);
assert_equal(queued_record.id, scheduled_op.id);
assert_equal(queued_record.state, 'queued');
let app_op = app_update.updater.update_miclash({ version: 'v9.9.9' }, 'luci');
app_update.clock.advance(0);
assert_equal(app_update.ops.get(app_op.id).state, 'success');
assert_equal(app_update.updater.status().kind, 'miclash');
assert_equal(app_update.updater.status().expected_version, 'v9.9.9');
assert_equal(app_update.updater.status().service_was_running, false);
assert_equal(app_update.updater.status().postcheck, 'stopped');
assert_true(match(app_update.updater.status().sha256, /^[0-9a-f]{64}$/));
assert_true(index(sprintf('%J', app_update.updater.status()), 'github') < 0);
assert_true(index(sprintf('%J', app_update.ops.get(app_op.id)), '--token') < 0);
let ash_calls = [];
for (let call in app_update.process.calls)
	if (call.command == '/bin/busybox') push(ash_calls, call);
assert_equal(length(ash_calls), 2);
assert_equal(ash_calls[0].args[1], '-n');
assert_true(index(ash_calls[1].args, '--target-tag') >= 0);
assert_true(index(ash_calls[1].args, '--service-was-running') >= 0);
for (let name in app_update.filesystem.lsdir('/tmp/miclash/updates'))
	assert_true(index(name, 'handoff') < 0, 'handoff is consumed and removed');

let running_app_update = environment({ running: true });
let running_app_op = running_app_update.updater.update_miclash(
	{ version: 'v9.9.9' }, 'telegram');
running_app_update.clock.advance(0);
assert_equal(running_app_update.ops.get(running_app_op.id).state, 'success');
assert_equal(running_app_update.updater.status().service_was_running, true);
assert_equal(running_app_update.updater.status().postcheck, 'ready');
assert_true(length(running_app_update.wait_calls) > 0,
	'running app update requires a fresh readiness check');
assert_intent_unchanged(running_app_update.service_calls,
	'running MiClash update must leave durable intent to package recovery');

let stopped_app_started = environment({ installer_starts_service: true });
let stopped_app_op = stopped_app_started.updater.update_miclash(
	{ version: 'v9.9.9' }, 'telegram');
stopped_app_started.clock.advance(0);
assert_equal(stopped_app_started.ops.get(stopped_app_op.id).state, 'success');
assert_intent_unchanged(stopped_app_started.service_calls,
	'stopped MiClash update must leave durable intent to package recovery');
assert_equal(stopped_app_started.service_calls[0], 'stop');
assert_equal(stopped_app_started.updater.status().postcheck, 'stopped');

let syntax_failed = environment({ fail_installer_syntax: true });
let syntax_op = syntax_failed.updater.update_miclash({ version: 'v9.9.9' }, 'luci');
syntax_failed.clock.advance(0);
assert_equal(syntax_failed.ops.get(syntax_op.id).state, 'failure');
let syntax_ash = [];
for (let call in syntax_failed.process.calls)
	if (call.command == '/bin/busybox') push(syntax_ash, call);
assert_equal(length(syntax_ash), 1, 'invalid syntax is never executed');
let forged = environment({ forged_handoff: true });
let forged_op = forged.updater.update_miclash({ version: 'v9.9.9' }, 'luci');
forged.clock.advance(0);
assert_equal(forged.ops.get(forged_op.id).state, 'failure');
assert_equal(forged.ops.get(forged_op.id).error.code, 'INTERNAL');
for (let protocol_failure in [
	{ stale_handoff: true }, { stale_timestamp: true }, { extra_handoff_field: true }
]) {
	let rejected_handoff = environment(protocol_failure);
	let rejected_handoff_op = rejected_handoff.updater.update_miclash(
		{ version: 'v9.9.9' }, 'luci');
	rejected_handoff.clock.advance(0);
	assert_equal(rejected_handoff.ops.get(rejected_handoff_op.id).state, 'failure');
}
let weak_handoff = environment({ weak_handoff: true });
let weak_handoff_op = weak_handoff.updater.update_miclash(
	{ version: 'v9.9.9' }, 'luci');
weak_handoff.clock.advance(0);
assert_equal(weak_handoff.ops.get(weak_handoff_op.id).state, 'failure');

let ambiguous_process = environment({ running: true });
let ordinary_run = ambiguous_process.process.run;
ambiguous_process.process.run = (request) => {
	let result = ordinary_run(request);
	return request.command == '/usr/libexec/miclash/decompress-gzip' ?
		{ ...result, extra: 'untrusted' } : result;
};
let ambiguous_op = ambiguous_process.updater.update_mihomo(
	{ version: 'v1.2.3' }, 'luci');
ambiguous_process.clock.advance(0);
assert_equal(ambiguous_process.ops.get(ambiguous_op.id).state, 'failure');
assert_equal(length(ambiguous_process.service_calls), 0);

let manifest_release = json(fixture('miclash-release.json'));
let installer_body = '#!/bin/sh\nexit 0\n';
let checksumless_release = json(fixture('miclash-release.json'));
checksumless_release.assets = [];
let checksumless_installer = environment({ installer: installer_body, responses: {
	[MICLASH_TAG]: sprintf('%J', checksumless_release)
} });
let checksumless_installer_op = checksumless_installer.updater.update_miclash(
	{ version: 'v9.9.9' }, 'luci');
checksumless_installer.clock.advance(0);
assert_equal(checksumless_installer.ops.get(checksumless_installer_op.id).state,
	'failure');
let checksumless_ash = [];
for (let call in checksumless_installer.process.calls)
	if (call.command == '/bin/busybox') push(checksumless_ash, call);
assert_equal(length(checksumless_ash), 0,
	'checksumless installer fails before syntax check or execution');
let manifest = environment({ installer: installer_body, responses: {
	[MICLASH_TAG]: sprintf('%J', manifest_release),
	[MICLASH_CHECKSUM]: require('digest').sha256(installer_body) +
		'  install-miclash.sh\n'
} });
let manifest_op = manifest.updater.update_miclash({ version: 'v9.9.9' }, 'luci');
manifest.clock.advance(0);
assert_equal(manifest.ops.get(manifest_op.id).state, 'success');
assert_equal(manifest.updater.status().published_checksum_verified, true);
let manifest_mismatch = environment({ installer: installer_body, responses: {
	[MICLASH_TAG]: sprintf('%J', manifest_release),
	[MICLASH_CHECKSUM]: sprintf('%064d', 0) + '  install-miclash.sh\n'
} });
let manifest_mismatch_op = manifest_mismatch.updater.update_miclash(
	{ version: 'v9.9.9' }, 'luci');
manifest_mismatch.clock.advance(0);
assert_equal(manifest_mismatch.ops.get(manifest_mismatch_op.id).state, 'failure');
let mismatch_ash = [];
for (let call in manifest_mismatch.process.calls)
	if (call.command == '/bin/busybox') push(mismatch_ash, call);
assert_equal(length(mismatch_ash), 0, 'manifest mismatch fails before syntax or execution');
let wrong_manifest_release = json(sprintf('%J', manifest_release));
wrong_manifest_release.assets[0].browser_download_url =
	'https://github.com/ang3el7z/luci-app-miclash/releases/download/v0.0.1/' +
	'install-miclash.sh.sha256';
assert_throws(() => environment({ responses: {
	[MICLASH_LATEST]: sprintf('%J', wrong_manifest_release)
} }).updater.release_info({ kind: 'miclash' }), 'INVALID_RESPONSE');

// Once the new bytes are installed, every start/readiness exception enters the
// same automatic restore path rather than leaving an unready new kernel behind.
let start_throw = environment({ running: true, new_start_throw: true,
	readiness: [ true, true ] });
let start_throw_op = start_throw.updater.update_mihomo({ version: 'v1.2.3' }, 'luci');
start_throw.clock.advance(0);
assert_equal(start_throw.ops.get(start_throw_op.id).state, 'failure');
assert_equal(start_throw.ops.get(start_throw_op.id).error.code, 'HEALTH_FAILED');
assert_equal(start_throw.filesystem.readfile('/opt/clash/bin/clash'), 'old mihomo binary');

// Public method arity and option schemas are exact; callers cannot supply an
// executable path, URL, or ignored trailing authority.
for (let invalid_call in [
	() => stable.updater.release_info({ kind: 'mihomo' }, 'extra'),
	() => stable.updater.update_mihomo({ version: 'v1.2.3', url: 'https://evil.test' }, 'luci'),
	() => stable.updater.update_mihomo({}, 'luci', 'extra'),
	() => stable.updater.rollback_mihomo({ id: previous_id, path: '/tmp/x' }, 'luci'),
	() => stable.updater.update_miclash({ version: 'v9.9.9' }, 'luci', 'extra')
])
	assert_throws(invalid_call, 'INVALID_ARGUMENT');

let empty_installer = environment({ installer: '' });
let empty_installer_op = empty_installer.updater.update_miclash(
	{ version: 'v9.9.9' }, 'luci');
empty_installer.clock.advance(0);
assert_equal(empty_installer.ops.get(empty_installer_op.id).state, 'failure');
let empty_ash = [];
for (let call in empty_installer.process.calls)
	if (call.command == '/bin/busybox') push(empty_ash, call);
assert_equal(length(empty_ash), 0, 'empty installer is never syntax-checked or executed');

// The recovery transaction starts at the first stop/write attempt. Even when
// stop, stopped observation, or atomic replacement throws after mutation, the
// exact old bytes are restored and the originally running service is proven.
for (let recovery_case in [
	{ stop_throw_once: true },
	{ stop_stays_running_once: true, hardlink_reports_missing_kernel: true },
	{ fail_binary_write: true },
	{ partial_binary_write: true }
]) {
	let recovered = environment({ ...recovery_case, running: true });
	let recovered_op = recovered.updater.update_mihomo({ version: 'v1.2.3' }, 'luci');
	recovered.clock.advance(0);
	assert_equal(recovered.ops.get(recovered_op.id).state, 'failure');
	assert_equal(recovered.filesystem.readfile('/opt/clash/bin/clash'),
		'old mihomo binary');
	assert_true(index(recovered.service_calls, 'start') >= 0,
		'recovery restarts the previously running old kernel');
	assert_equal(recovered.updater.status().applied, false);
	assert_equal(recovered.updater.status().recovery_state, 'restored');
}

// applied is a proven destination-byte state, not a service-health state. Once
// exact old bytes are restored it remains false even if their start/readiness
// fails; an exception after the restore rename but before proof remains unknown.
for (let recovery_kind in [ 'update', 'rollback' ]) {
	for (let recovery_proof in [
		{ name: 'old start throws', options: { old_start_throw: true,
			readiness: [ false ] }, applied: false },
		{ name: 'old readiness fails', options: {
			readiness: [ false, false ] }, applied: false },
		{ name: 'old verification throws', options: {
			readiness: [ false ] }, applied: null, verify_throw: true },
		{ name: 'old restore rename throws', options: {
			readiness: [ false ] }, applied: null, rename_throw: true }
	]) {
		let recovery_options = { ...recovery_proof.options, running: true };
		if (recovery_kind == 'rollback') recovery_options.old = 'current binary';
		let proof = environment(recovery_options), destination_renames = 0;
		let restored_hash = require('digest').sha256(
			recovery_kind == 'rollback' ? 'current binary' : 'old mihomo binary');
		if (recovery_kind == 'rollback') {
			proof.filesystem.writefile('/opt/clash/bin/previous/' + previous_id,
				'old mihomo binary');
			proof.filesystem.chmod('/opt/clash/bin/previous/' + previous_id, 0o700);
		}
		let throw_verification = false;
		proof.filesystem.on_rename = (from, to) => {
			if (to != '/opt/clash/bin/clash') return;
			destination_renames++;
			if (destination_renames != 2) return;
			if (recovery_proof.verify_throw) throw_verification = true;
			if (recovery_proof.rename_throw)
				proof.filesystem.throw_after_rename_once_to = '/opt/clash/bin/clash';
		};
		proof.filesystem.on_lstat = (path) => {
			if (throw_verification && path == '/opt/clash/bin/clash') {
				throw_verification = false;
				die('INTERNAL');
			}
		};
		let proof_op = recovery_kind == 'rollback' ?
			proof.updater.rollback_mihomo({ id: previous_id }, 'luci') :
			proof.updater.update_mihomo({ version: 'v1.2.3' }, 'luci');
		proof.clock.advance(0);
		let proof_operation = proof.ops.get(proof_op.id), proof_status = proof.updater.status();
		let label = recovery_kind + ': ' + recovery_proof.name;
		assert_equal(proof_operation.state, 'failure', label);
		assert_equal(proof_operation.error.code, 'INTERNAL', label);
		assert_equal(proof_status.state, 'failure', label);
		assert_equal(proof_status.error_code, 'INTERNAL', label);
		assert_equal(proof_status.recovery_state, 'failed', label);
		assert_equal(proof_status.applied, recovery_proof.applied, label);
		assert_equal(proof_status.sha256,
			recovery_proof.applied === false ? restored_hash : null, label);
	}
}

// Destination authority includes the root-owned parent hierarchy. Every
// successful stopped update authenticates the final executable mode/hash; a
// post-readiness substitution is recovered rather than reported as success.
let foreign_bin = environment({ foreign_bin_parent: true, running: true });
let foreign_bin_op = foreign_bin.updater.update_mihomo({ version: 'v1.2.3' }, 'luci');
foreign_bin.clock.advance(0);
assert_equal(foreign_bin.ops.get(foreign_bin_op.id).state, 'failure');
assert_equal(length(foreign_bin.service_calls), 0);
assert_equal(stopped.filesystem.lstat('/opt/clash/bin/clash').mode, 0o700);
assert_equal(stopped.filesystem.realpath('/opt/clash/bin/clash'), '/opt/clash/bin/clash');
let tampered_ready = environment({ running: true,
	tamper_binary_after_new_ready: true });
let tampered_ready_op = tampered_ready.updater.update_mihomo(
	{ version: 'v1.2.3' }, 'luci');
tampered_ready.clock.advance(0);
assert_equal(tampered_ready.ops.get(tampered_ready_op.id).state, 'failure');
assert_equal(tampered_ready.filesystem.readfile('/opt/clash/bin/clash'),
	'old mihomo binary');

// The exact old destination and its parent authority are re-proven before the
// first service transition or destination write. A race removes only the
// hardlink created by this operation and leaves the running service untouched.
for (let old_race in [ 'replacement', 'hash', 'mode', 'authority' ]) {
	let raced_old = environment({ running: true }), armed = true;
	raced_old.filesystem.on_link = (from, to) => {
		if (!armed || substr(to, 0, length('/opt/clash/bin/previous/mihomo-')) !=
		    '/opt/clash/bin/previous/mihomo-') return;
		if (old_race == 'replacement')
			raced_old.filesystem.bump_inode('/opt/clash/bin/clash');
		else if (old_race == 'hash')
			raced_old.filesystem.writefile('/opt/clash/bin/clash', 'raced old bytes');
		else if (old_race == 'mode')
			raced_old.filesystem.set_mode('/opt/clash/bin/clash', 0o600);
		armed = old_race == 'authority';
	};
	if (old_race == 'authority') {
		raced_old.filesystem.on_lstat = (path) => {
			if (armed && path == '/opt/clash/bin/clash') {
				armed = false;
				raced_old.filesystem.set_uid('/opt/clash/bin', 1000);
			}
		};
	}
	let raced_old_op = raced_old.updater.update_mihomo(
		{ version: 'v1.2.3' }, 'luci');
	raced_old.clock.advance(0);
	assert_equal(raced_old.ops.get(raced_old_op.id).state, 'failure', old_race);
	assert_equal(length(raced_old.service_calls), 0,
		old_race + ' race fails before stop: ' +
		sprintf('%J', raced_old.service_calls));
	if (old_race != 'authority')
		assert_equal(raced_old.filesystem.lstat(
			'/opt/clash/bin/previous/' + previous_id), null,
			old_race + ' removes the exact hardlink created by the failed operation');
	let destination_writes = 0;
	for (let rename in raced_old.filesystem.calls.rename)
		if (rename.to == '/opt/clash/bin/clash') destination_writes++;
	assert_equal(destination_writes, 0,
		old_race + ' race fails before destination write');
}

// Failure to persist the transition stage happens after preservation but
// before service stop. The operation must remove its exact hardlink so the
// normal service observer does not remain stuck in missing_kernel.
let transition_journal_failure = environment({ running: true });
transition_journal_failure.filesystem.on_link = (from, to) => {
	if (substr(to, 0, length('/opt/clash/bin/previous/mihomo-')) ==
	    '/opt/clash/bin/previous/mihomo-')
		transition_journal_failure.filesystem.fail_open_once_matching =
			'/tmp/miclash/operations/';
		transition_journal_failure.filesystem.fail_open_matching_count = 16;
};
let transition_journal_op = transition_journal_failure.updater.update_mihomo(
	{ version: 'v1.2.3' }, 'luci');
transition_journal_failure.clock.advance(0);
assert_equal(transition_journal_failure.ops.get(transition_journal_op.id).state,
	'failure');
assert_equal(length(transition_journal_failure.service_calls), 0);
assert_equal(transition_journal_failure.filesystem.lstat(
	'/opt/clash/bin/previous/' + previous_id), null,
	'failed transition journal removes the exact created hardlink');
assert_equal(transition_journal_failure.filesystem.lstat(
	'/opt/clash/bin/clash').nlink, 1);

// A process wrapper may report failure or throw after ln has already created
// the hardlink. Both outcomes clean only that exact link before service stop.
for (let link_failure in [ 'reply', 'throw' ]) {
	let failed_link = environment({
		link_reports_failure: link_failure == 'reply',
		link_throws_after_create: link_failure == 'throw',
		running: true
	});
	let failed_link_op = failed_link.updater.update_mihomo(
		{ version: 'v1.2.3' }, 'luci');
	failed_link.clock.advance(0);
	assert_equal(failed_link.ops.get(failed_link_op.id).state, 'failure',
		link_failure);
	assert_equal(length(failed_link.service_calls), 0, link_failure);
	assert_equal(failed_link.filesystem.lstat(
		'/opt/clash/bin/previous/' + previous_id), null, link_failure);
	assert_equal(failed_link.filesystem.lstat('/opt/clash/bin/clash').nlink, 1,
		link_failure);
}

// Rollback runs the same candidate -v and Active -t pipeline before its first
// stop, and its provenance is not falsely labelled as a published checksum.
let validated_rollback = environment({ old: 'current binary', running: true });
validated_rollback.filesystem.writefile('/opt/clash/bin/previous/' + previous_id,
	'old mihomo binary');
validated_rollback.filesystem.chmod('/opt/clash/bin/previous/' + previous_id, 0o700);
let validated_rollback_op = validated_rollback.updater.rollback_mihomo(
	{ id: previous_id }, 'luci');
validated_rollback.clock.advance(0);
let rollback_execs = [];
for (let call in validated_rollback.process.calls)
	if (substr(call.command, 0, length('/opt/clash/bin/previous/')) ==
	    '/opt/clash/bin/previous/') push(rollback_execs, call);
assert_equal(length(rollback_execs), 2);
assert_equal(rollback_execs[0].args[0], '-v');
assert_equal(rollback_execs[1].args[0], '-d');
assert_equal(validated_rollback.updater.status().published_checksum_verified, null);
let rejected_rollback = environment({ old: 'current binary', running: true,
	fail_rollback_version: true });
rejected_rollback.filesystem.writefile('/opt/clash/bin/previous/' + previous_id,
	'old mihomo binary');
rejected_rollback.filesystem.chmod('/opt/clash/bin/previous/' + previous_id, 0o700);
let rejected_rollback_op = rejected_rollback.updater.rollback_mihomo(
	{ id: previous_id }, 'luci');
rejected_rollback.clock.advance(0);
assert_equal(rejected_rollback.ops.get(rejected_rollback_op.id).state, 'failure');
assert_equal(length(rejected_rollback.service_calls), 0);

// Fixed helpers/interpreters and their root-owned parents are capabilities,
// revalidated across process execution. Replacing either fails before stop or
// before executing the installer body.
for (let helper_case in [
	{ foreign_helper_parent: true }, { replace_helper_during_unpack: true }
]) {
	let rejected_helper = environment({ ...helper_case, running: true });
	let rejected_helper_op = rejected_helper.updater.update_mihomo(
		{ version: 'v1.2.3' }, 'luci');
	rejected_helper.clock.advance(0);
	assert_equal(rejected_helper.ops.get(rejected_helper_op.id).state, 'failure');
	assert_equal(length(rejected_helper.service_calls), 0);
}
let replaced_ash = environment({ replace_ash_during_syntax: true });
let replaced_ash_op = replaced_ash.updater.update_miclash(
	{ version: 'v9.9.9' }, 'luci');
replaced_ash.clock.advance(0);
assert_equal(replaced_ash.ops.get(replaced_ash_op.id).state, 'failure');
let replaced_ash_calls = [];
for (let call in replaced_ash.process.calls)
	if (call.command == '/bin/busybox') push(replaced_ash_calls, call);
assert_equal(length(replaced_ash_calls), 1);

// Success is published only after cleanup. If cleanup fails after an applied
// update, central operation and status both report cleanup failure plus the
// truthful applied state.
let kernel_cleanup = environment({ running: true, fail_kernel_cleanup: true });
let kernel_cleanup_op = kernel_cleanup.updater.update_mihomo(
	{ version: 'v1.2.3' }, 'luci');
kernel_cleanup.clock.advance(0);
assert_equal(kernel_cleanup.ops.get(kernel_cleanup_op.id).state, 'failure');
assert_equal(kernel_cleanup.updater.status().state, 'failure');
assert_equal(kernel_cleanup.updater.status().stage, 'cleanup');
assert_equal(kernel_cleanup.updater.status().applied, true);
for (let cleanup_case in [
	{ fail_handoff_cleanup: true }, { fail_installer_cleanup: true }
]) {
	let app_cleanup = environment(cleanup_case);
	let app_cleanup_op = app_cleanup.updater.update_miclash(
		{ version: 'v9.9.9' }, 'luci');
	app_cleanup.clock.advance(0);
	assert_equal(app_cleanup.ops.get(app_cleanup_op.id).state, 'failure');
	assert_equal(app_cleanup.updater.status().state, 'failure');
	assert_equal(app_cleanup.updater.status().stage, 'cleanup');
	assert_equal(app_cleanup.updater.status().applied, true);
}

print('ok - verified update release contracts\n');
