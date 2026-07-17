import assert from 'node:assert/strict';
import { chmodSync, existsSync, mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import os from 'node:os';
import path from 'node:path';

const guardPath = 'luci-app-miclash/rootfs/opt/clash/bin/miclash-memory-guard';
const servicePath = 'luci-app-miclash/rootfs/opt/clash/bin/miclash-service';
const sh = process.platform === 'win32'
	? 'C:/Program Files/Git/bin/sh.exe'
	: '/bin/sh';
const mutationHarness = mkdtempSync(path.join(os.tmpdir(), 'miclash-mutation-stub-'));
const mutationHelper = path.join(mutationHarness, 'mutation-lock-helper');
writeFileSync(mutationHelper, '#!/bin/sh\nmiclash_mutation_lock_enter() { return 0; }\nmiclash_mutation_lock_leave() { return 0; }\n');
chmodSync(mutationHelper, 0o755);
const shellMutationHelper = mutationHelper.replace(/\\/g, '/');
function isolatedCopy(sourcePath, name) {
	const destination = path.join(mutationHarness, name);
	writeFileSync(destination, readFileSync(sourcePath, 'utf8')
		.replaceAll('/usr/share/miclash/mutation-lock.sh', shellMutationHelper));
	chmodSync(destination, 0o755);
	return destination;
}
const guardExecutable = isolatedCopy(guardPath, 'miclash-memory-guard');
const serviceExecutable = isolatedCopy(servicePath, 'miclash-service');
process.on('exit', () => rmSync(mutationHarness, { recursive: true, force: true }));

function guard(args, env = {}) {
	return spawnSync(sh, [guardExecutable, ...args.map(String)], {
		encoding: 'utf8',
		env: { ...process.env, ...env }
	});
}

assert.ok(existsSync(guardPath), `missing memory guard: ${guardPath}`);
assert.equal(guard(['reserve', 65536]).stdout.trim(), '16384');
assert.equal(guard(['reserve', 262144]).stdout.trim(), '26214');
assert.equal(guard(['reserve', 2097152]).stdout.trim(), '65536');
assert.equal(guard(['anomaly', 60000, 90000]).status, 0);
assert.notEqual(guard(['anomaly', 60000, 85000]).status, 0);
assert.equal(guard(['decreased', 100000, 80000]).status, 0);
assert.notEqual(guard(['decreased', 100000, 95000]).status, 0);
assert.equal(guard(['median', 10, 40, 20, 60, 30, 50]).stdout.trim(), '35');
assert.notEqual(guard(['anomaly', 0, 90000]).status, 0);

const lockHarness = mkdtempSync(path.join(os.tmpdir(), 'miclash-service-lock-'));
try {
	const lockDir = path.join(lockHarness, 'lock');
	const statusDir = path.join(lockHarness, 'status');
	const fakeInit = path.join(lockHarness, 'clash-init');
	mkdirSync(lockDir);
	mkdirSync(statusDir);
	writeFileSync(path.join(statusDir, 'status'), 'state=running\nphase=restart\n');
	writeFileSync(fakeInit, '#!/bin/sh\n[ "$1" = stop ] && sleep 0.2\nexit 0\n');
	chmodSync(fakeInit, 0o755);
	const env = {
		MICLASH_SERVICE_LOCK_DIR: lockDir,
		MICLASH_SERVICE_STATUS_DIR: statusDir,
		MICLASH_CLASH_INIT: fakeInit
	};
	const liveHarness = path.join(lockHarness, 'live.sh');
	writeFileSync(liveHarness, '#!/bin/sh\nprintf "%s\\n" "$$" > "$1/pid"\n"$2" stop\n');
	chmodSync(liveHarness, 0o755);
	const liveBusy = spawnSync(sh, [liveHarness, lockDir, serviceExecutable], {
		encoding: 'utf8', env: { ...process.env, ...env }
	});
	assert.equal(liveBusy.status, 75, liveBusy.stderr);
	assert.equal(readFileSync(path.join(statusDir, 'status'), 'utf8'), 'state=running\nphase=restart\n',
		'busy contender must not overwrite status owned by the lock holder');

	rmSync(path.join(lockDir, 'pid'));
	const pidlessBusy = spawnSync(sh, [serviceExecutable, 'stop'], {
		encoding: 'utf8', env: { ...process.env, ...env }
	});
	assert.equal(pidlessBusy.status, 75, pidlessBusy.stderr);
	assert.match(pidlessBusy.stderr, /initializing its lock/);

	const contenderScript = path.join(lockHarness, 'contend.sh');
	writeFileSync(contenderScript,
		'#!/bin/sh\n"$1" stop >"$2" 2>"$3" & a=$!\n"$1" stop >"$4" 2>"$5" & b=$!\nwait "$a"; ra=$?\nwait "$b"; rb=$?\nprintf "%s %s\\n" "$ra" "$rb"\n');
	chmodSync(contenderScript, 0o755);
	for (let attempt = 0; attempt < 5; attempt += 1) {
		mkdirSync(lockDir, { recursive: true });
		writeFileSync(path.join(lockDir, 'pid'), '99999999');
		const race = spawnSync(sh, [contenderScript, serviceExecutable,
			path.join(lockHarness, 'a.out'), path.join(lockHarness, 'a.err'),
			path.join(lockHarness, 'b.out'), path.join(lockHarness, 'b.err')], {
			encoding: 'utf8', env: { ...process.env, ...env }
		});
		assert.equal(race.status, 0, race.stderr);
		assert.match(race.stdout.trim(), /^(0 75|75 0)$/,
			`exactly one stale-lock contender must run; got ${race.stdout.trim()}`);
	}
} finally {
	rmSync(lockHarness, { recursive: true, force: true });
}

const fakeProc = mkdtempSync(path.join(os.tmpdir(), 'miclash-memory-guard-'));
try {
	mkdirSync(path.join(fakeProc, 'pressure'));
	writeFileSync(path.join(fakeProc, 'pressure', 'memory'), 'some avg10=0.00 avg60=0.00 avg300=0.00 total=0\n');
	writeFileSync(path.join(fakeProc, 'meminfo'), 'MemTotal:       262144 kB\nMemAvailable:    20000 kB\n');
	const snapshot = guard(['snapshot'], { MICLASH_PROC_ROOT: fakeProc });
	assert.equal(snapshot.status, 0);
	assert.match(snapshot.stdout, /mem_total_kb=262144/);
	assert.match(snapshot.stdout, /mem_available_kb=20000/);
	assert.match(snapshot.stdout, /psi_full_avg10=unavailable/);

	writeFileSync(path.join(fakeProc, 'meminfo'), 'MemTotal:       262144 kB\n');
	assert.notEqual(guard(['snapshot'], { MICLASH_PROC_ROOT: fakeProc }).status, 0);
} finally {
	rmSync(fakeProc, { recursive: true, force: true });
}

const source = readFileSync(guardPath, 'utf8');
const service = readFileSync(servicePath, 'utf8');
const initPath = 'luci-app-miclash/rootfs/etc/init.d/miclash-memory-guard';
const makefile = readFileSync('luci-app-miclash/Makefile', 'utf8');
const packageRemoval = readFileSync('luci-app-miclash/rootfs/usr/share/miclash/package-remove', 'utf8');
const acl = readFileSync('luci-app-miclash/rootfs/usr/share/rpcd/acl.d/luci-app-miclash.json', 'utf8');
const settingsModel = readFileSync('luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/settings-model.js', 'utf8');
const config = readFileSync('luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/config.js', 'utf8');
const ruPo = readFileSync('luci-app-miclash/rootfs/po/ru/miclash.po', 'utf8');
const zhPo = readFileSync('luci-app-miclash/rootfs/po/zh-cn/miclash.po', 'utf8');
for (const marker of [
	'SAMPLE_INTERVAL_SEC=60',
	'PRESSURE_SAMPLES_REQUIRED=5',
	'WARMUP_SEC=900',
	'BASELINE_SAMPLES_REQUIRED=6',
	'SUCCESS_COOLDOWN_SEC=21600',
	'FAILURE_COOLDOWN_SEC=86400',
	'REARM_NORMAL_SEC=1800',
	'read_mihomo_rss_kb()',
	'read_memory_metrics()',
	'read_memory_psi()',
	'reset_baseline()',
	'collect_baseline_sample()',
	'load_runtime_state()',
	'failure_rearm_ready()',
	'write_status()',
	'run_monitor()'
]) {
	assert.ok(source.includes(marker), `missing guard runtime marker: ${marker}`);
}
for (const field of [
	'phase',
	'baseline_rss_kb',
	'current_rss_kb',
	'mem_available_kb',
	'reserve_kb',
	'last_action',
	'last_result',
	'cooldown_until'
]) {
	assert.ok(source.includes(`printf '${field}=%s\\n'`), `missing status field: ${field}`);
}

const recoveryStart = source.indexOf('recover_memory()');
const recoveryEnd = source.indexOf('\nrun_monitor()', recoveryStart);
const recovery = recoveryStart >= 0 && recoveryEnd > recoveryStart
	? source.slice(recoveryStart, recoveryEnd)
	: '';
const reloadAt = recovery.indexOf('run_recovery_action guard-reload');
const coreAt = recovery.indexOf('run_recovery_action guard-core-restart');
const fullAt = recovery.indexOf('run_full_restart_once');
assert.ok(reloadAt >= 0 && reloadAt < coreAt && coreAt < fullAt,
	'recovery order must be reload, internal restart, full restart');
assert.match(source, /run_full_restart_once\(\)[\s\S]*FULL_RESTART_ATTEMPTED=1/);
assert.match(recovery, /run_full_restart_once\n\tfull_result="\$\?"\n\t\[ "\$full_result" -eq 0 \] && return 0/);
assert.match(source, /finish_recovery_success\(\)[\s\S]*recovered_rss="\$CURRENT_RSS"[\s\S]*reset_baseline[\s\S]*CURRENT_RSS="\$recovered_rss"/);
assert.match(source, /failure_rearm_ready\(\)[\s\S]*REARM_NORMAL_SEC/);
assert.match(source, /run_monitor\(\)[\s\S]*load_runtime_state/);
assert.match(service, /guard-core-restart[\s\S]*restart_mihomo_api[\s\S]*wait_ready/);
assert.match(service, /guard-reload[\s\S]*hot_reload_config[\s\S]*wait_ready/);
assert.match(service, /busy\(\)[\s\S]*exit 75/);
assert.doesNotMatch(service.match(/busy\(\) \{[\s\S]*?\n\}/)?.[0] || '', /write_status/);
assert.match(service, /busy "another MiClash service operation is already running/);
assert.match(service, /mv "\$LOCK_DIR" "\$stale_lock"/);
assert.match(service, /LOCK_OWNER_GRACE_SEC=5/);
assert.match(service, /stat -c %Y "\$LOCK_DIR"/);
assert.ok(!source.includes('if [ -d /tmp/miclash-service.lock ]'),
	'guard must let miclash-service distinguish live and stale locks');
assert.match(source, /ACTION_BUSY_EXIT=75/);
assert.match(source, /\[ "\$code" -eq "\$ACTION_BUSY_EXIT" \][\s\S]*return "\$ACTION_BUSY_EXIT"/);
assert.match(source, /defer_busy_recovery\(\)/);
assert.match(service, /record_manual_operation\(\)/);
assert.match(service, /MANUAL_OPERATION_FILE="\$STATUS_DIR\/manual-operation"/);
assert.match(service, /record_manual_operation\(\)[\s\S]*MICLASH_MEMORY_GUARD_ACTION/);
assert.match(source, /MICLASH_MEMORY_GUARD_ACTION=1 "\$SERVICE_BIN" "\$action"/);
assert.match(service, /reload\)[\s\S]*hot_reload_config[\s\S]*wait_ready[\s\S]*record_manual_operation/);
assert.match(source, /detect_manual_operation\(\)/);
assert.match(source, /MANUAL_OPERATION_FILE="\/tmp\/miclash-service\/manual-operation"/);
assert.ok(existsSync(initPath), `missing init service: ${initPath}`);
const init = existsSync(initPath) ? readFileSync(initPath, 'utf8') : '';
assert.match(init, /procd_set_param command \/opt\/clash\/bin\/miclash-memory-guard run/);
assert.match(init, /ENABLE_MEMORY_GUARD=true/);
assert.match(source, /sync_guard_service\(\)/);
assert.match(source, /"\$SERVICE_INIT" running[\s\S]*"\$SERVICE_INIT" start/);
assert.match(makefile, /rootfs\/etc\/init\.d\/miclash-memory-guard/);
assert.match(makefile, /rootfs\/opt\/clash\/bin\/miclash-memory-guard/);
assert.match(makefile, /miclash-memory-guard sync/);
assert.match(packageRemoval, /stop_disable miclash-memory-guard/);
assert.match(makefile, /rm -rf \/tmp\/miclash-memory-guard/);
const prermStart = makefile.indexOf('define Package/$(PKG_NAME)/prerm');
const prermEnd = makefile.indexOf('endef', prermStart);
const prerm = prermStart >= 0 && prermEnd > prermStart ? makefile.slice(prermStart, prermEnd) : '';
assert.match(prerm, /package-remove/);
assert.match(packageRemoval, /stop_disable miclash-memory-guard/);
assert.match(acl, /"memory_reset_baseline"/);
assert.match(acl, /"guard_transition"/);
assert.doesNotMatch(acl, /miclash-memory-guard": \[ "exec" \]/);
assert.match(settingsModel, /enableMemoryGuard: false/);
assert.match(settingsModel, /settings\.enableMemoryGuard = memory\.enabled === true/);
assert.match(settingsModel, /api\.settings_get\(\)/);
assert.doesNotMatch(settingsModel, /settings\.ENABLE_MEMORY_GUARD = enableMemoryGuard/,
	'the legacy serializer must not own Memory Guard writes');
assert.doesNotMatch(config, /id="sbox-memory-guard"|id="sbox-auto-hide-notifications"/,
	'the legacy form must not duplicate management controls');
assert.doesNotMatch(config, /fs\.exec\('\/opt\/clash\/bin\/miclash-memory-guard', \['sync'\]\)|formState\.enableMemoryGuard/,
	'the legacy save path must not synchronize Memory Guard');
assert.match(source, /usage: \$0[^"]*snapshot[^"]*run[^"]*sync/);
for (const forbidden of ['reboot', 'drop_caches', 'swapon', 'swapoff']) {
	assert.ok(!source.includes(forbidden), `memory guard must not invoke ${forbidden}`);
}
assert.ok(!/AX3000T|router model|device model/i.test(source),
	'memory guard must not contain router-model-specific behavior');
for (const catalog of [ruPo, zhPo]) {
	assert.ok(catalog.includes('msgid "Monitor abnormal Mihomo memory usage"'));
	assert.ok(catalog.includes('msgid "Learns normal Mihomo memory use and applies staged recovery only during sustained system memory pressure."'));
}

console.log('memory guard check passed');
