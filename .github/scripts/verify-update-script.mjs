import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

const scriptPath = path.join(
	process.cwd(),
	'luci-app-miclash',
	'rootfs',
	'opt',
	'clash',
	'bin',
	'miclash-update'
);

const shell = process.env.SHELL_CHECK_BIN || 'sh';
const lockDir = '/tmp/miclash-update.lock';
const shellEnv = { ...process.env };

if (path.isAbsolute(shell)) {
	const shellBin = path.dirname(shell);
	shellEnv.PATH = `${shellBin}${path.delimiter}${shellEnv.PATH || ''}`;
}

function rmLock() {
	spawnSync(shell, ['-c', `rm -rf '${lockDir}'`], { encoding: 'utf8', env: shellEnv });
}

function run(args) {
	return spawnSync(shell, [scriptPath, ...args], {
		encoding: 'utf8',
		env: shellEnv,
		timeout: 10000
	});
}

function fail(message, result) {
	if (result) {
		console.error(result.stdout || '');
		console.error(result.stderr || '');
	}
	throw new Error(message);
}

function expectFail(args, pattern, label) {
	const result = run(args);
	if (result.status === 0) {
		fail(`${label}: expected non-zero exit`, result);
	}
	const text = `${result.stdout || ''}\n${result.stderr || ''}`;
	if (!pattern.test(text)) {
		fail(`${label}: output did not match ${pattern}`, result);
	}
}

function shellCommand(command) {
	return spawnSync(shell, ['-c', command], {
		encoding: 'utf8',
		env: shellEnv,
		timeout: 10000
	});
}

function startShellSleeper() {
	const result = shellCommand('sleep 30 >/dev/null 2>&1 & echo $!');
	if (result.status !== 0 || !String(result.stdout || '').trim()) {
		fail('failed to start shell sleeper for lock test', result);
	}
	return String(result.stdout || '').trim();
}

function writeLockPid(pid) {
	const result = shellCommand(`mkdir -p '${lockDir}' && printf %s '${pid}' > '${lockDir}/pid'`);
	if (result.status !== 0) {
		fail(`failed to write lock pid ${pid}`, result);
	}
}

function lockExists() {
	return shellCommand(`[ -e '${lockDir}' ]`).status === 0;
}

rmLock();

expectFail(
	['app', '--url', 'https://example.invalid/pkg.ipk', '--mode', 'broken'],
	/unsupported app mode: broken/,
	'invalid app mode'
);
if (lockExists()) {
	fail('invalid app mode: lock was not cleaned up');
}

const activePid = startShellSleeper();
try {
	writeLockPid(activePid);
	expectFail(
		['app', '--url', 'https://example.invalid/pkg.ipk'],
		new RegExp(`another MiClash update is already running \\(pid ${activePid}\\)`),
		'active lock'
	);
	if (!lockExists()) {
		fail('active lock: lock owned by another process was removed');
	}
} finally {
	shellCommand(`kill '${activePid}' >/dev/null 2>&1 || true`);
}

writeLockPid('999999');
expectFail(
	['app', '--url', 'https://example.invalid/pkg.ipk', '--mode', 'broken'],
	/unsupported app mode: broken/,
	'stale lock cleanup'
);
if (lockExists()) {
	fail('stale lock cleanup: lock was not cleaned up');
}

rmLock();

console.log(`MiClash update script behavior verified on ${os.platform()}`);
