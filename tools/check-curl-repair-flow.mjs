import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
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
		mkdirSync(bin, { recursive: true });
		writeFileSync(state, 'broken');
		writeFileSync(log, '');
		writeFileSync(curlLog, '');
		writeFileSync(installerLog, '');

		const releaseJson = options.releaseJson || `{
	"tag_name": "v1.2.3",
	"assets": [
		{ "name": "luci-app-miclash_1.2.3_all.ipk", "browser_download_url": "https://example.test/luci-app-miclash_1.2.3_all.ipk" },
		{ "name": "luci-app-miclash-1.2.3.apk", "browser_download_url": "https://example.test/luci-app-miclash-1.2.3.apk" }
	]
}`;
		const tagInstaller = options.tagInstaller || `#!/bin/sh
printf '%s\\n' "$*" > "${installerLog}"
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
		writeFileSync(releasePath, releaseJson);
		writeFileSync(tagInstallerPath, tagInstaller);

		writeExecutable(join(bin, 'curl'), `#!/bin/sh
if [ "$(cat "${state}")" = "fixed" ]; then
	printf '%s\\n' "$*" >> "${curlLog}"
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
	case "$url" in
		*install-miclash.sh) cp "${tagInstallerPath}" "$out" ;;
		*) printf 'package-data\\n' > "$out" ;;
	esac
	exit 0
fi
case "$url" in
	*api.github.com*) cat "${releasePath}"; exit 0 ;;
esac
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
TEST_STATUS_FILE="${statusFile}"
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
	`miclash-update app mode must run the target tag installer: ${updateAppResult.stderr || updateAppResult.stdout}`);
check(/raw\.githubusercontent\.com\/ang3el7z\/luci-app-miclash\/v1\.2\.3\/install-miclash\.sh/.test(updateAppResult.curlLog),
	'miclash-update app mode must download install-miclash.sh from the target release tag.');
check(/^app --target-tag v1\.2\.3 --mode update --status-file .* --token test-token$/.test(updateAppResult.installerLog.trim()),
	'miclash-update app mode must pass target tag, mode, status file, and token to the tag installer.');
check(/state=success/.test(updateAppResult.status) &&
	/phase=done/.test(updateAppResult.status) &&
	/token=test-token/.test(updateAppResult.status),
	'miclash-update app mode must preserve operation status from the tag installer.');

if (failed) process.exit(1);
console.log('curl repair flow check passed');
