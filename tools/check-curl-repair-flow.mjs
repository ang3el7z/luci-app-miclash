import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';

const installerPath = 'install-miclash.sh';
const updatePath = 'luci-app-miclash/rootfs/opt/clash/bin/miclash-update';

const installer = readFileSync(installerPath, 'utf8');
const update = readFileSync(updatePath, 'utf8');

let failed = false;

const shellCandidates = process.platform === 'win32'
	? [
		process.env.MICLASH_TEST_SHELL,
		'C:/Program Files/Git/bin/sh.exe',
		'C:/Program Files/Git/usr/bin/sh.exe'
	].filter(Boolean)
	: [process.env.MICLASH_TEST_SHELL, '/bin/sh'].filter(Boolean);
const shellExecutable = shellCandidates.find((candidate) => existsSync(candidate));

function shellPath(path) {
	const normalized = String(path).replace(/\\/g, '/');
	if (process.platform !== 'win32') return normalized;
	return normalized.replace(/^([A-Za-z]):/, (_, drive) => '/' + drive.toLowerCase());
}

if (!shellExecutable) {
	throw new Error('No POSIX shell found. Set MICLASH_TEST_SHELL to a BusyBox-compatible sh.');
}

function check(condition, message) {
	if (!condition) {
		console.error(message);
		failed = true;
	}
}

function scriptWithoutMain(source) {
	const dispatchStart = source.indexOf('\nif [ "${1:-}" = "app" ]; then');
	if (dispatchStart >= 0) return source.slice(0, dispatchStart);
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

function readIfExists(path) {
	return existsSync(path) ? readFileSync(path, 'utf8') : '';
}

function runShell(source, body, options = {}) {
	const dir = mkdtempSync(join(tmpdir(), 'miclash-curl-test-'));
	try {
		const bin = join(dir, 'bin');
		const state = join(dir, 'curl-state');
		const log = join(dir, 'opkg.log');
		const curlLog = join(dir, 'curl.log');
		const installerLog = join(dir, 'installer.log');
		const statusFile = join(dir, 'status');
		const curlAttempts = join(dir, 'curl-attempts');
		const shellBin = shellPath(bin);
		const shellState = shellPath(state);
		const shellLog = shellPath(log);
		const shellCurlLog = shellPath(curlLog);
		const shellInstallerLog = shellPath(installerLog);
		const shellStatusFile = shellPath(statusFile);
		const shellCurlAttempts = shellPath(curlAttempts);
		mkdirSync(bin, { recursive: true });
		writeFileSync(state, 'broken');
		writeFileSync(log, '');
		writeFileSync(curlLog, '');
		writeFileSync(installerLog, '');
		writeFileSync(curlAttempts, '0');

		const releaseJson = options.releaseJson || `{
	"tag_name": "v1.2.3",
	"assets": [
		{ "name": "luci-app-miclash_1.2.3_all.ipk", "browser_download_url": "https://example.test/luci-app-miclash_1.2.3_all.ipk" },
		{ "name": "luci-app-miclash-1.2.3.apk", "browser_download_url": "https://example.test/luci-app-miclash-1.2.3.apk" }
	]
}`;
		const tagInstaller = options.tagInstaller || `#!/bin/sh
printf '%s\\n' "$*" > "${shellInstallerLog}"
while [ "$#" -gt 0 ]; do
	case "$1" in
		--status-file)
			status_file="$2"
			shift 2
			;;
		--token)
			token="$2"
			shift 2
			;;
		*)
			shift
			;;
	esac
done
{
	printf 'state=success\\n'
	printf 'phase=done\\n'
	printf 'token=%s\\n' "$token"
	printf 'message=tag installer ran\\n'
	printf 'updated_at=1\\n'
} > "$status_file"
echo "tag installer ran"
`;
		const releasePath = join(dir, 'release.json');
		const tagInstallerPath = join(dir, 'tag-installer.sh');
		const shellReleasePath = shellPath(releasePath);
		const shellTagInstallerPath = shellPath(tagInstallerPath);
		writeFileSync(releasePath, releaseJson);
		writeFileSync(tagInstallerPath, tagInstaller);

		writeExecutable(join(bin, 'curl'), `#!/bin/sh
if [ "$(cat "${shellState}")" = "fixed" ]; then
	printf '%s\\n' "$*" >> "${shellCurlLog}"
	case " $* " in
		*" --version "*) echo "curl 8.0.0"; exit 0 ;;
	esac
out=""
prev=""
url=""
for arg in "$@"; do
	if [ "$prev" = "-o" ]; then out="$arg"; fi
	case "$arg" in
		http://*|https://*) url="$arg" ;;
	esac
	prev="$arg"
done
if [ -n "$out" ]; then
	attempt="$(cat "${shellCurlAttempts}")"
	if [ "$attempt" -lt "\${CURL_FAIL_COUNT:-0}" ]; then
		attempt=$((attempt + 1))
		echo "$attempt" > "${shellCurlAttempts}"
		echo "\${CURL_FINAL_ERROR:-curl: (28) Connection timed out}" >&2
		exit 28
	fi
	case "$url" in
		*api.github.com*) cp "${shellReleasePath}" "$out" ;;
		*install-miclash.sh) cp "${shellTagInstallerPath}" "$out" ;;
		*) printf 'package-data\\n' > "$out" ;;
	esac
	exit 0
fi
case "$url" in
	*api.github.com*) cat "${shellReleasePath}"; exit 0 ;;
esac
	exit 0
fi
echo "Error loading shared library libz.so.1: No such file or directory (needed by /usr/bin/curl)" >&2
echo "Error relocating /usr/bin/curl: curl_multi_notify_enable: symbol not found" >&2
exit 127
`);

		writeExecutable(join(bin, 'opkg'), `#!/bin/sh
printf '%s\\n' "$*" >> "${shellLog}"
args=" $* "
case "$args" in *" update "*) exit 0 ;; esac
case "$args" in *" --force-reinstall "*) force=1 ;; *) force=0 ;; esac
case "$args" in *" install "*) install=1 ;; *) install=0 ;; esac
case "$args" in *" zlib "*) has_zlib=1 ;; *) has_zlib=0 ;; esac
case "$args" in *" libcurl4 "*) has_libcurl=1 ;; *) has_libcurl=0 ;; esac
case "$args" in *" curl "*) has_curl=1 ;; *) has_curl=0 ;; esac
if [ "$force" = "1" ] && [ "$install" = "1" ] && [ "$has_zlib" = "1" ] && [ "$has_libcurl" = "1" ] && [ "$has_curl" = "1" ]; then
	echo fixed > "${shellState}"
fi
exit 0
`);

		const script = `PATH="${shellBin}:/usr/bin:/bin"
export PATH
${source}
TEST_STATUS_FILE="${shellStatusFile}"
${body}
`;
		const result = spawnSync(shellExecutable, ['-s'], {
			input: script,
			encoding: 'utf8',
			env: {
				...process.env,
				...options.env,
				PATH: process.platform === 'win32'
					? `${bin};${process.env.PATH || ''}`
					: `${shellBin}:${process.env.PATH || ''}`
			}
		});
		return {
			code: result.status,
			stdout: result.stdout,
			stderr: result.stderr || result.error?.message || '',
			opkgLog: readFileSync(log, 'utf8'),
			curlLog: readFileSync(curlLog, 'utf8'),
			installerLog: readFileSync(installerLog, 'utf8'),
			status: readIfExists(statusFile).trim(),
			statusFile
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

const installerAppResult = runShell(scriptWithoutMain(installer), `
detect_openwrt() {
	OW_RELEASE=24.10.2
	OW_MAJOR=24
	ARCH_PKG=aarch64_cortex-a53
	PKG_MGR=opkg
	TPROXY_PKG=kmod-nft-tproxy
}
openwrt_major() { echo 24; }
detect_arch() { MIHOMO_ARCH=arm64; }
detect_installed_miclash() { MICLASH_INSTALLED_VER=1.0.0; MICLASH_INSTALLED_NORM=1.0.0; }
run_app_mode --target-tag v1.2.3 --mode update --status-file "$TEST_STATUS_FILE" --token test-token >/dev/null
`, {
	releaseJson: `{
		"tag_name": "v1.2.3",
		"assets": [
			{ "name": "luci-app-miclash_1.2.3_all.ipk", "browser_download_url": "https://example.test/luci-app-miclash_1.2.3_all.ipk" }
		]
	}`
});

check(installer.includes('run_app_mode()'),
	'install-miclash must expose a non-interactive app mode.');
check(installerAppResult.code === 0,
	`install-miclash app mode must install the target release package: ${installerAppResult.stderr || installerAppResult.stdout}`);
check(/releases\/tags\/v1\.2\.3/.test(installerAppResult.curlLog),
	'install-miclash app mode must fetch release metadata for the requested target tag.');
check(/luci-app-miclash_1\.2\.3_all\.ipk/.test(installerAppResult.curlLog),
	'install-miclash app mode must download the package asset selected from the target release.');
check(/state=success/.test(installerAppResult.status) &&
	/phase=done/.test(installerAppResult.status) &&
	/token=test-token/.test(installerAppResult.status),
	'install-miclash app mode must write success operation status with the provided token.');

const updateAppResult = runShell(scriptWithoutDispatch(update), `
STATUS_FILE="$TEST_STATUS_FILE"
CURRENT_TOKEN="test-token"
install_app --target-tag v1.2.3 --mode update
`);
const updateInstallAppStart = update.indexOf('\ninstall_app()');
const updateInstallKernelStart = update.indexOf('\ninstall_kernel()');
const updateInstallAppBlock = updateInstallAppStart >= 0 && updateInstallKernelStart > updateInstallAppStart
	? update.slice(updateInstallAppStart, updateInstallKernelStart)
	: '';

check(update.includes('--target-tag'),
	'miclash-update app mode must accept --target-tag.');
check(!/missing --url/.test(updateInstallAppBlock),
	'miclash-update app mode must not require a package URL from LuCI.');
check(updateAppResult.code === 0,
	`miclash-update app mode must install the release asset directly: ${updateAppResult.stderr || updateAppResult.stdout}`);
check(/releases\/tags\/v1\.2\.3/.test(updateAppResult.curlLog),
	'miclash-update app mode must resolve the requested release tag.');
check(/luci-app-miclash_1\.2\.3_all\.ipk/.test(updateAppResult.curlLog),
	'miclash-update app mode must download the selected package asset.');
check(!/raw\.githubusercontent\.com.*install-miclash\.sh/.test(updateAppResult.curlLog),
	'miclash-update app mode must not download the standalone installer.');
check(/install .*luci-app-miclash.*\.ipk/.test(updateAppResult.opkgLog),
	'miclash-update app mode must invoke opkg for the downloaded package.');
check(/state=success/.test(updateAppResult.status) &&
	/phase=done/.test(updateAppResult.status) &&
	/token=test-token/.test(updateAppResult.status),
	'miclash-update app mode must write successful operation status.');

const retryResult = runShell(scriptWithoutDispatch(update), `
STATUS_FILE="$TEST_STATUS_FILE"
CURRENT_TOKEN="retry-token"
install_app --target-tag v1.2.3 --mode update
`, { env: { CURL_FAIL_COUNT: '2' } });
check(retryResult.code === 0,
	`miclash-update downloads must recover after two timeouts: ${retryResult.stderr || retryResult.stdout}`);

const exhaustedResult = runShell(scriptWithoutDispatch(update), `
STATUS_FILE="$TEST_STATUS_FILE"
CURRENT_TOKEN="failed-token"
install_app --target-tag v1.2.3 --mode update
`, {
	env: {
		CURL_FAIL_COUNT: '5',
		CURL_FINAL_ERROR: 'curl: (28) Connection timed out'
	}
});
check(exhaustedResult.code !== 0,
	'miclash-update downloads must fail after the bounded attempts are exhausted.');
check(/curl: \(28\) Connection timed out/.test(exhaustedResult.status),
	'miclash-update must preserve the final curl error in operation status.');

if (failed) process.exit(1);
console.log('curl repair flow check passed');
