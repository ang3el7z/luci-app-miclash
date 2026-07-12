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

console.log('memory guard check passed');
