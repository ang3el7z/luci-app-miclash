import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';

const guardPath = 'luci-app-miclash/rootfs/opt/clash/bin/miclash-memory-guard';
const sh = process.platform === 'win32'
	? 'C:/Program Files/Git/bin/sh.exe'
	: '/bin/sh';

function guard(args) {
	return spawnSync(sh, [guardPath, ...args.map(String)], { encoding: 'utf8' });
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

const source = readFileSync(guardPath, 'utf8');
const servicePath = 'luci-app-miclash/rootfs/opt/clash/bin/miclash-service';
const service = readFileSync(servicePath, 'utf8');
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

console.log('memory guard check passed');
