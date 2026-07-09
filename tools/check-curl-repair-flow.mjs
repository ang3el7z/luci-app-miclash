import { mkdtempSync, readFileSync, rmSync, writeFileSync, chmodSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';

const installerPath = 'install-miclash.sh';
const updatePath = 'luci-app-miclash/rootfs/opt/clash/bin/miclash-update';

const installer = readFileSync(installerPath, 'utf8');
const update = readFileSync(updatePath, 'utf8');

let failed = false;

function check(condition, message) {
	if (!condition) {
		console.error(message);
		failed = true;
	}
}

function scriptWithoutMain(source) {
	return source.replace(/\nmain "\$@"\s*$/, '');
}

function scriptWithoutDispatch(source) {
	const dispatchStart = source.indexOf('\ncase "${1:-}" in');
	return dispatchStart >= 0 ? source.slice(0, dispatchStart) : source;
}

function writeExecutable(path, content) {
	writeFileSync(path, content);
	chmodSync(path, 0o755);
}

function runShell(source, body) {
	const dir = mkdtempSync(join(tmpdir(), 'miclash-curl-test-'));
	try {
		const bin = join(dir, 'bin');
		const state = join(dir, 'curl-state');
		const log = join(dir, 'opkg.log');
		spawnSync('mkdir', ['-p', bin], { check: true });
		writeFileSync(state, 'broken');
		writeFileSync(log, '');

		writeExecutable(join(bin, 'curl'), `#!/bin/sh
if [ "$(cat "${state}")" = "fixed" ]; then
	exit 0
fi
echo "Error loading shared library libz.so.1: No such file or directory (needed by /usr/bin/curl)" >&2
echo "Error relocating /usr/bin/curl: curl_multi_notify_enable: symbol not found" >&2
exit 127
`);

		writeExecutable(join(bin, 'opkg'), `#!/bin/sh
printf '%s\\n' "$*" >> "${log}"
args=" $* "
case "$args" in *" update "*) exit 0 ;; esac
case "$args" in *" --force-reinstall "*) force=1 ;; *) force=0 ;; esac
case "$args" in *" install "*) install=1 ;; *) install=0 ;; esac
case "$args" in *" zlib "*) has_zlib=1 ;; *) has_zlib=0 ;; esac
case "$args" in *" libcurl4 "*) has_libcurl=1 ;; *) has_libcurl=0 ;; esac
case "$args" in *" curl "*) has_curl=1 ;; *) has_curl=0 ;; esac
if [ "$force" = "1" ] && [ "$install" = "1" ] && [ "$has_zlib" = "1" ] && [ "$has_libcurl" = "1" ] && [ "$has_curl" = "1" ]; then
	echo fixed > "${state}"
fi
exit 0
`);

		const script = `${source}
${body}
`;
		const result = spawnSync('/bin/sh', ['-s'], {
			input: script,
			encoding: 'utf8',
			env: { ...process.env, PATH: `${bin}:${process.env.PATH}` }
		});
		return {
			code: result.status,
			stdout: result.stdout,
			stderr: result.stderr,
			opkgLog: readFileSync(log, 'utf8')
		};
	} finally {
		rmSync(dir, { recursive: true, force: true });
	}
}

const installerResult = runShell(scriptWithoutMain(installer), `
PKG_MGR=opkg
PKG_UPDATED=0
ensure_curl
curl --version
`);

check(installerResult.code === 0,
	`install-miclash ensure_curl must repair a broken existing curl before continuing: ${installerResult.stderr || installerResult.stdout}`);
check(/--force-reinstall/.test(installerResult.opkgLog) &&
	/zlib/.test(installerResult.opkgLog) &&
	/libcurl4/.test(installerResult.opkgLog) &&
	/curl/.test(installerResult.opkgLog),
	'install-miclash ensure_curl must force-reinstall zlib/libcurl4/curl when the existing curl cannot run.');

const updateResult = runShell(scriptWithoutDispatch(update), `
PKG_MGR="$(detect_pkg_manager)"
ensure_curl_available "$PKG_MGR"
curl --version
`);

check(update.includes('ensure_curl_available()'),
	'miclash-update must expose a shared curl repair helper for release/app/kernel flows.');
check(updateResult.code === 0,
	`miclash-update curl helper must repair a broken existing curl before downloads: ${updateResult.stderr || updateResult.stdout}`);
check(/--force-reinstall/.test(updateResult.opkgLog) &&
	/zlib/.test(updateResult.opkgLog) &&
	/libcurl4/.test(updateResult.opkgLog) &&
	/curl/.test(updateResult.opkgLog),
	'miclash-update curl helper must force-reinstall zlib/libcurl4/curl when the existing curl cannot run.');

if (failed) process.exit(1);
console.log('curl repair flow check passed');
