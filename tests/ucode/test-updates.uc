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

function environment(options) {
	options ??= {};
	let old = options.old ?? 'old mihomo binary';
	let filesystem = fakes.fs({
		'/etc/openwrt_release': "DISTRIB_ARCH='" +
			(options.arch ?? 'aarch64_cortex-a53') + "'\n",
		'/opt/clash/bin/clash': old,
		'/opt/clash/config.yaml': 'mixed-port: 7890\n'
	});
	for (let directory in [ '/tmp', '/tmp/miclash', '/var', '/var/run',
		'/var/run/miclash', '/opt/clash/bin/previous' ])
		if (filesystem.lstat(directory) == null)
			filesystem.mkdir(directory);
	let clock = fakes.clock(1700000000000);
	let process = fakes.process();
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
	let responses = {
		[RELEASE_LATEST]: fixture('mihomo-release.json'),
		[RELEASES]: fixture('mihomo-prereleases.json'),
		[RELEASE_TAG]: fixture('mihomo-release.json'),
		[MICLASH_LATEST]: fixture('miclash-release.json'),
		[MICLASH_TAG]: fixture('miclash-release.json'),
		[MICLASH_RELEASES]: '[' + replace(fixture('miclash-release.json'),
			'"prerelease": false', '"prerelease": true') + ']',
		[MICLASH_INSTALLER]: options.installer ?? '#!/bin/sh\nexit 0\n'
	};
	for (let url, body in options.responses ?? {})
		responses[url] = body;
	let gzip_body = options.gzip_body ?? 'GZIP:new mihomo binary';
	let asset_url =
		'https://github.com/MetaCubeX/mihomo/releases/download/v1.2.3/' +
		'mihomo-linux-arm64-v1.2.3.gz';
	responses[asset_url] = gzip_body;
	let checksum_url = asset_url + '.sha256';
	responses[checksum_url] = options.checksum ??
		require('digest').sha256(gzip_body) +
		'  mihomo-linux-arm64-v1.2.3.gz\n';
	let service_calls = [], running = options.running === true, start_count = 0;
	let readiness = [ ...(options.readiness ?? []) ], wait_count = 0;
	let service = {
		observe: () => ({ state: running ? 'running' : 'stopped', running }),
		stop: () => { push(service_calls, 'stop'); running = false; },
		start: () => {
			push(service_calls, 'start'); running = true; start_count++;
			if (options.new_start_throw && start_count == 1) die('HEALTH_FAILED');
		},
		wait_ready: () => {
			wait_count++;
			if (options.restore_write_fail && wait_count == 3)
				filesystem.fail_rename_once = true;
			let ok = length(readiness) ? shift(readiness) : true;
			return { ok, timed_out: !ok, components: [] };
		}
	};
	process.on_run = (request) => {
		if (request.command == '/usr/bin/curl') {
			let output = request.args[index(request.args, '--output') + 1];
			let header = request.args[index(request.args, '--dump-header') + 1];
			let url = request.args[length(request.args) - 1];
			let body = responses[url];
			if (body == null) {
				process.replies[request.command + ':' + join(' ', request.args)] = { code: 22 };
				body = '';
			}
			filesystem.writefile(output, body);
			filesystem.writefile(header, 'HTTP/1.1 200 OK\r\nContent-Length: ' +
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
				filesystem.unlink(compressed);
			}
			else
				process.replies[request.command + ':' + join(' ', request.args)] = { code: 1 };
		}
		else if (substr(request.command, 0, length('/tmp/miclash/updates/')) ==
		    '/tmp/miclash/updates/') {
			if (options.fail_version && request.args[0] == '-v' ||
			    options.fail_config && request.args[0] == '-d')
				process.replies[request.command + ':' + join(' ', request.args)] = { code: 1 };
		}
		else if (request.command == '/bin/ash') {
			let key = request.command + ':' + join(' ', request.args);
			if (request.args[0] == '-n') {
				if (options.fail_installer_syntax)
					process.replies[key] = { code: 2 };
			}
			else {
				let status_path = request.args[index(request.args, '--status-file') + 1];
				let token = request.args[index(request.args, '--token') + 1];
				filesystem.writefile(status_path,
					'protocol=miclash-update-status-v1\n' +
					'token=' + (options.forged_handoff ?
						'fedcba9876543210fedcba9876543210' : token) + '\n' +
					'state=success\nphase=done\n' +
					'target_version=v9.9.9\nupdated_at=' +
					(options.stale_timestamp ? '1' : '1700000000') + '\n' +
					(options.extra_handoff_field ? 'unexpected=value\n' : ''));
				if (options.weak_handoff) filesystem.chmod(status_path, 0o644);
				if (options.fail_installer_run)
					process.replies[key] = { code: 1 };
			}
		}
	};
	let runtime = {
		fs: filesystem, clock, process, digest: fakes.digest(filesystem),
		random: fakes.entropy(), paths: { tmp: '/tmp/miclash' },
		update_options: options.update_options ?? { max_kernel_bytes: 1024 }
	};
	let ops = operations.create(runtime);
	let app = {
		runtime, operations: ops, service,
		settings: { get: () => ({ updates: {
			mihomo_release_channel: options.channel ?? 'release',
			miclash_release_channel: 'release'
		} }) }
	};
	return { filesystem, clock, process, ops, service_calls,
		updater: updates.create(app) };
};

assert_equal(type(updates.create), 'function');
let stable = environment();
for (let method in [ 'release_info', 'update_mihomo', 'rollback_mihomo',
	'update_miclash', 'status' ])
	assert_equal(type(stable.updater[method]), 'function', method + ' is exported');

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

let without_checksum_release = json(fixture('mihomo-release.json'));
without_checksum_release.assets = [ without_checksum_release.assets[0] ];
let without_checksum = environment({ responses: {
	[RELEASE_TAG]: sprintf('%J', without_checksum_release)
} });
let local_op = without_checksum.updater.update_mihomo({ version: 'v1.2.3' }, 'luci');
without_checksum.clock.advance(0);
assert_equal(without_checksum.ops.get(local_op.id).state, 'success');
assert_equal(without_checksum.updater.status().published_checksum_verified, false);
assert_true(match(without_checksum.updater.status().sha256, /^[0-9a-f]{64}$/));

let mismatch = environment({ checksum: sprintf('%064d', 0) +
	'  mihomo-linux-arm64-v1.2.3.gz\n' });
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

let running = environment({ running: true });
let running_update = running.updater.update_mihomo({ version: 'v1.2.3' }, 'luci');
running.clock.advance(0);
assert_equal(running.ops.get(running_update.id).state, 'success');
assert_equal(join(',', running.service_calls), 'stop,start');
assert_equal(running.filesystem.readfile('/opt/clash/bin/clash'), 'new mihomo binary');

// Failed readiness restores the exact old binary and proves it starts. A
// failure of that restoration is a distinct INTERNAL terminal state.
let unhealthy = environment({ running: true, readiness: [ true, false, true, true ] });
let unhealthy_update = unhealthy.updater.update_mihomo({ version: 'v1.2.3' }, 'luci');
unhealthy.clock.advance(0);
assert_equal(unhealthy.ops.get(unhealthy_update.id).state, 'failure');
assert_equal(unhealthy.ops.get(unhealthy_update.id).error.code, 'HEALTH_FAILED');
assert_equal(unhealthy.filesystem.readfile('/opt/clash/bin/clash'), 'old mihomo binary');
assert_equal(join(',', unhealthy.service_calls), 'stop,start,stop,start');

let restore_failed = environment({ running: true,
	readiness: [ true, false, true ], restore_write_fail: true });
let restore_failed_update = restore_failed.updater.update_mihomo(
	{ version: 'v1.2.3' }, 'luci');
restore_failed.clock.advance(0);
assert_equal(restore_failed.ops.get(restore_failed_update.id).state, 'failure');
assert_equal(restore_failed.ops.get(restore_failed_update.id).error.code, 'INTERNAL');

// Explicit rollback consumes only the opaque previous id and itself uses the
// same stopped/running atomic transaction.
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
		browser_download_url: 'https://github.com/MetaCubeX/mihomo/releases/download/v1.2.3/' + name });
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
let app_op = app_update.updater.update_miclash({ version: 'v9.9.9' }, 'luci');
app_update.clock.advance(0);
assert_equal(app_update.ops.get(app_op.id).state, 'success');
assert_equal(app_update.updater.status().kind, 'miclash');
assert_true(match(app_update.updater.status().sha256, /^[0-9a-f]{64}$/));
assert_true(index(sprintf('%J', app_update.updater.status()), 'github') < 0);
assert_true(index(sprintf('%J', app_update.ops.get(app_op.id)), '--token') < 0);
let ash_calls = [];
for (let call in app_update.process.calls)
	if (call.command == '/bin/ash') push(ash_calls, call);
assert_equal(length(ash_calls), 2);
assert_equal(ash_calls[0].args[0], '-n');
assert_true(index(ash_calls[1].args, '--target-tag') >= 0);
for (let name in app_update.filesystem.lsdir('/tmp/miclash/updates'))
	assert_true(index(name, 'handoff') < 0, 'handoff is consumed and removed');

let syntax_failed = environment({ fail_installer_syntax: true });
let syntax_op = syntax_failed.updater.update_miclash({ version: 'v9.9.9' }, 'luci');
syntax_failed.clock.advance(0);
assert_equal(syntax_failed.ops.get(syntax_op.id).state, 'failure');
let syntax_ash = [];
for (let call in syntax_failed.process.calls)
	if (call.command == '/bin/ash') push(syntax_ash, call);
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
manifest_release.assets = [ { name: 'install-miclash.sh.sha256',
	browser_download_url: MICLASH_CHECKSUM } ];
let installer_body = '#!/bin/sh\nexit 0\n';
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
	if (call.command == '/bin/ash') push(mismatch_ash, call);
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
	readiness: [ true, true, true ] });
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
	if (call.command == '/bin/ash') push(empty_ash, call);
assert_equal(length(empty_ash), 0, 'empty installer is never syntax-checked or executed');

print('ok - verified update release contracts\n');
