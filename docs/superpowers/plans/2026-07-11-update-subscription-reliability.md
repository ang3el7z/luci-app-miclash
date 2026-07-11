# MiClash Update and Subscription Reliability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make MiClash package, Mihomo kernel, and subscription operations reliable and independent from the client forwarding guard and Clash service state, while leaving a hard reinstall stopped and without a kernel.

**Architecture:** Keep LuCI as a thin job launcher. `miclash-update` directly resolves and installs release assets through one bounded downloader, while `miclash-subscription` becomes the only manual and scheduled subscription engine. OpenWrt lifecycle markers suppress package-manager autostart, and `miclash-autoupdate` owns only interval scheduling and optional hot reload.

**Tech Stack:** POSIX/BusyBox `sh`, OpenWrt `opkg` and `apk`, procd init scripts, LuCI JavaScript, gettext `.po`, Node.js repository checks.

## Global Constraints

- Never stop or restart the live router's Clash service during development or verification.
- The client forwarding guard remains client-only and is never disabled by download code.
- A hard reinstall removes `/opt/clash/bin/clash`; a normal version update preserves it.
- Package installation, package update, and hard reinstall leave Clash and `miclash-autoupdate` stopped and disabled.
- Subscription application requires an installed Mihomo kernel but not a running Clash service.
- A failed scheduled attempt consumes the configured update interval exactly like a successful attempt.
- No required download path may depend on a third-party GitHub proxy.
- User-facing success text must not mention Remnawave or `/mihomo` fallback internals.
- All new behavior follows red-green-refactor: add a failing check, observe the expected failure, implement the minimum change, then rerun the focused and complete suites.

---

## File Map

- `luci-app-miclash/rootfs/opt/clash/bin/miclash-update`: release lookup, resilient artifact download, app/kernel install jobs, lifecycle marker creation, specific error propagation.
- `install-miclash.sh`: standalone first-install downloader; reuse the same retry semantics without being called by LuCI.
- `luci-app-miclash/rootfs/opt/clash/bin/miclash-subscription`: canonical subscription normalization, fallback, transform, validation, and atomic replacement.
- `luci-app-miclash/rootfs/opt/clash/bin/miclash-autoupdate`: interval state and delegation to `miclash-subscription`.
- `luci-app-miclash/rootfs/opt/clash/bin/miclash-service`: kernel preflight before service enable/start.
- `luci-app-miclash/rootfs/etc/init.d/clash`: consume the one-shot package no-autostart marker.
- `luci-app-miclash/rootfs/etc/init.d/miclash-autoupdate`: consume its one-shot package no-autostart marker.
- `luci-app-miclash/Makefile`: remove duplicate lifecycle actions and distinguish hard reinstall from normal update/full removal.
- `luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/config.js`: actionable kernel text and fallback-neutral success text.
- `luci-app-miclash/rootfs/po/ru/miclash.po`: Russian copy.
- `luci-app-miclash/rootfs/po/zh-cn/miclash.po`: Chinese copy.
- `tools/check-curl-repair-flow.mjs`: direct app install and resilient downloader regression coverage.
- `tools/check-config-hot-reload-autoupdate.mjs`: failed-attempt interval and shared subscription-engine coverage.
- `tools/check-subscription-helper-flow.mjs`: saved-settings/Base64/Remnawave behavior coverage.
- `tools/check-service-readiness-update-flow.mjs`: missing-kernel and lifecycle marker coverage.
- `tools/check-operation-status-expansion.mjs`: normalize CRLF so the existing CSS baseline check is portable.
- `tools/check-translations.mjs`: existing translation completeness gate.

---

### Task 1: Make the existing regression harness portable

**Files:**
- Modify: `tools/check-curl-repair-flow.mjs:1-170`
- Modify: `tools/check-operation-status-expansion.mjs:1-8`

**Interfaces:**
- Consumes: Node.js `process.platform`, `existsSync`, `spawnSync`.
- Produces: `shellExecutable` and `shellPath(path)` used by the curl shell harness; LF-normalized source strings for static checks.

- [ ] **Step 1: Record the baseline failures**

Run on Windows:

```powershell
& 'C:\Users\Ang3el\.cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe' tools/check-curl-repair-flow.mjs
& 'C:\Users\Ang3el\.cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe' tools/check-operation-status-expansion.mjs
```

Expected: the first check fails because `spawnSync('/bin/sh')` cannot start; the second fails its exact LF CSS substring against a CRLF checkout.

- [ ] **Step 2: Add portable shell and newline helpers**

Change the imports and helper declarations in `check-curl-repair-flow.mjs` to include this complete logic:

```js
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
```

Within `runShell`, convert `dir`, `bin`, `state`, `log`, `curlLog`, `installerLog`, `statusFile`, `releasePath`, and `tagInstallerPath` through `shellPath()` before interpolating them into shell source. Launch `shellExecutable` instead of `/bin/sh`, and construct `PATH` with `shellPath(bin)`.

Normalize the two source strings in `check-operation-status-expansion.mjs`:

```js
const config = readFileSync(configPath, 'utf8').replace(/\r\n/g, '\n');
const style = readFileSync(stylePath, 'utf8').replace(/\r\n/g, '\n');
```

- [ ] **Step 3: Verify the baseline checks pass**

Run the two commands from Step 1.

Expected:

```text
curl repair flow check passed
operation status expansion check passed
```

- [ ] **Step 4: Commit the harness fix**

```bash
git add tools/check-curl-repair-flow.mjs tools/check-operation-status-expansion.mjs
git commit -m "test: make shell checks portable"
```

---

### Task 2: Replace the nested installer with direct resilient artifact downloads

**Files:**
- Modify: `tools/check-curl-repair-flow.mjs:170-270`
- Modify: `luci-app-miclash/rootfs/opt/clash/bin/miclash-update:13-22,207-350`
- Modify: `install-miclash.sh:1-20,220-255,353-385`

**Interfaces:**
- Consumes: `miclash-update app --target-tag TAG --mode install|update|reinstall`, GitHub release JSON, `curl`, `opkg` or `apk`.
- Produces: `download_file URL TARGET LABEL [FALLBACK_URL]`, `resolve_miclash_asset TAG MANAGER`, and precise failed job status.

- [ ] **Step 1: Rewrite the app-flow assertions to describe direct installation**

Replace the nested-installer expectations in `check-curl-repair-flow.mjs` with these assertions:

```js
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
```

Extend the fake curl with `CURL_FAIL_COUNT` and `CURL_FINAL_ERROR` environment-controlled state. Add assertions that two timeouts followed by success return zero, while exhausted attempts preserve `curl: (28) Connection timed out` in the job status.

- [ ] **Step 2: Run the focused test and observe RED**

```powershell
& 'C:\Users\Ang3el\.cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe' tools/check-curl-repair-flow.mjs
```

Expected: FAIL because `miclash-update` still downloads and runs `install-miclash.sh` and replaces its error with `failed to run MiClash installer`.

- [ ] **Step 3: Implement one bounded downloader in `miclash-update`**

Replace the single curl call in `download_file()` with the following interface and control flow:

```sh
download_file() {
	url="$1"
	target="$2"
	label="$3"
	fallback_url="${4:-}"
	error_file="/tmp/miclash-download-error-$$"
	TMP_FILES="$TMP_FILES $error_file"

	prepare_curl_download || fail "curl is not available"
	write_status running download "Downloading $label"
	rm -f "$target" "$error_file"

	for family in "" "" "-4"; do
		if curl $family -L -fsS \
			--connect-timeout "$CURL_CONNECT_TIMEOUT" \
			--max-time "$CURL_MAX_TIME" \
			"$url" -o "$target" 2>"$error_file" && [ -s "$target" ]; then
			return 0
		fi
		rm -f "$target"
		sleep 1
	done

	if [ -n "$fallback_url" ]; then
		if curl -4 -L -fsS \
			--connect-timeout "$CURL_CONNECT_TIMEOUT" \
			--max-time "$CURL_MAX_TIME" \
			"$fallback_url" -o "$target" 2>"$error_file" && [ -s "$target" ]; then
			return 0
		fi
	fi

	detail="$(tail -n 3 "$error_file" 2>/dev/null | tr '\r\n' '  ')"
	fail "failed to download $label: ${detail:-download returned an empty file}"
}
```

Do not use `curl --retry-all-errors`, because older supported OpenWrt curl builds may not implement it.

- [ ] **Step 4: Implement direct release resolution and package installation**

Add `resolve_miclash_asset()` that fetches `https://api.github.com/repos/ang3el7z/luci-app-miclash/releases/tags/$target_tag`, extracts the `.ipk` or `.apk` `browser_download_url`, and fails with the exact tag/package type when no asset exists.

Replace the body of `install_app()` after argument parsing with this state machine:

```sh
case "$mode" in
	install|update|reinstall) ;;
	*) fail "unsupported app mode: $mode" ;;
esac

manager="$(detect_pkg_manager)"
install_deps "$manager"
asset_url="$(resolve_miclash_asset "$target_tag" "$manager")"
case "$manager" in
	apk) package_file="/tmp/miclash-update-$$.apk" ;;
	opkg) package_file="/tmp/miclash-update-$$.ipk" ;;
esac
TMP_FILES="$TMP_FILES $package_file /tmp/miclash-package-no-autostart-clash /tmp/miclash-package-no-autostart-autoupdate /tmp/miclash-hard-reinstall"
download_file "$asset_url" "$package_file" "MiClash package"

touch /tmp/miclash-package-no-autostart-clash
touch /tmp/miclash-package-no-autostart-autoupdate
[ "$mode" = "reinstall" ] && touch /tmp/miclash-hard-reinstall

write_status running install "Installing MiClash package"
case "$manager:$mode" in
	apk:reinstall) apk add --force-reinstall --allow-untrusted "$package_file" ;;
	apk:*) apk add --allow-untrusted "$package_file" ;;
	opkg:reinstall) opkg install --force-reinstall "$package_file" ;;
	opkg:*) opkg install "$package_file" ;;
esac || fail "failed to install MiClash package"

write_status success done "MiClash package installed; services remain stopped"
```

Remove `MICLASH_INSTALLER_RAW_BASE` and every tagged-installer download/launch branch from `miclash-update`.

- [ ] **Step 5: Apply the same retry semantics to the standalone installer**

Add a standalone `download_artifact URL TARGET LABEL` function to `install-miclash.sh` with the same three attempts (`default`, `default`, `-4`), non-empty target check, and final curl detail. Use it for `.ipk`, `.apk`, and Mihomo downloads. Keep `install-miclash.sh` independent from `/opt/clash/bin/miclash-update` so first installation still works.

- [ ] **Step 6: Verify GREEN and commit**

```powershell
& 'C:\Users\Ang3el\.cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe' tools/check-curl-repair-flow.mjs
```

Expected: `curl repair flow check passed`.

```bash
git add tools/check-curl-repair-flow.mjs install-miclash.sh luci-app-miclash/rootfs/opt/clash/bin/miclash-update
git commit -m "fix: make release downloads resilient"
```

---

### Task 3: Make package lifecycle intent explicit and suppress autostart

**Files:**
- Modify: `tools/check-service-readiness-update-flow.mjs:1-210`
- Modify: `luci-app-miclash/Makefile:136-248`
- Modify: `luci-app-miclash/rootfs/etc/init.d/clash:297-310`
- Modify: `luci-app-miclash/rootfs/etc/init.d/miclash-autoupdate:7-12`

**Interfaces:**
- Consumes: marker files created by Task 2.
- Produces: one-shot skip behavior in both init scripts and explicit hard-reinstall kernel removal.

- [ ] **Step 1: Add failing lifecycle assertions**

Extend `check-service-readiness-update-flow.mjs` to extract the Makefile `postinst`, `prerm`, and `postrm` blocks and assert:

```js
check(!prermBlock.includes('/etc/init.d/clash stop'),
	'Package prerm must let default_prerm stop Clash exactly once.');
check(!postinstBlock.includes('/etc/init.d/miclash-autoupdate start'),
	'Package postinst must not start auto-update before default_postinst.');
check(clashInit.includes('/tmp/miclash-package-no-autostart-clash'),
	'Clash init must consume its package no-autostart marker.');
check(autoUpdateInit.includes('/tmp/miclash-package-no-autostart-autoupdate'),
	'Auto-update init must consume its package no-autostart marker.');
check(postrmBlock.includes('/tmp/miclash-hard-reinstall'),
	'Package postrm must remove the kernel only for explicit hard reinstall or full removal.');
```

- [ ] **Step 2: Run the focused test and observe RED**

```powershell
& 'C:\Users\Ang3el\.cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe' tools/check-service-readiness-update-flow.mjs
```

Expected: FAIL on duplicate stop, explicit auto-update start, and missing markers.

- [ ] **Step 3: Remove duplicate lifecycle work from the package scripts**

Reduce `Package/luci-app-miclash/prerm` to:

```sh
#!/bin/sh
# OpenWrt default_prerm stops packaged init scripts exactly once.
exit 0
```

Remove the explicit `miclash-autoupdate enable/start` block from `postinst`; `default_postinst` will attempt both init scripts and the one-shot markers will suppress those attempts.

Change the kernel removal branch in `postrm` to:

```sh
HARD_REINSTALL_MARKER="/tmp/miclash-hard-reinstall"
if [ -f "$HARD_REINSTALL_MARKER" ]; then
	rm -f "$HARD_REINSTALL_MARKER"
	rm -f /opt/clash/bin/clash
else
	case "$1" in
		upgrade|update) ;;
		*) is_pkg_installed || rm -f /opt/clash/bin/clash ;;
	esac
fi
```

- [ ] **Step 4: Consume one marker per init script**

At the beginning of `clash` `start_service()` add:

```sh
NO_AUTOSTART_MARKER="/tmp/miclash-package-no-autostart-clash"
if [ -f "$NO_AUTOSTART_MARKER" ]; then
	rm -f "$NO_AUTOSTART_MARKER"
	/etc/init.d/clash disable >/dev/null 2>&1 || true
	msg "Package installation left Clash stopped"
	return 0
fi
```

At the beginning of `miclash-autoupdate` `start_service()` add:

```sh
NO_AUTOSTART_MARKER="/tmp/miclash-package-no-autostart-autoupdate"
if [ -f "$NO_AUTOSTART_MARKER" ]; then
	rm -f "$NO_AUTOSTART_MARKER"
	/etc/init.d/miclash-autoupdate disable >/dev/null 2>&1 || true
	return 0
fi
```

- [ ] **Step 5: Verify GREEN and commit**

Run `check-service-readiness-update-flow.mjs` and expect `service readiness and update flow check passed`.

```bash
git add tools/check-service-readiness-update-flow.mjs luci-app-miclash/Makefile luci-app-miclash/rootfs/etc/init.d/clash luci-app-miclash/rootfs/etc/init.d/miclash-autoupdate
git commit -m "fix: leave services stopped after package install"
```

---

### Task 4: Unify manual and automatic subscription application

**Files:**
- Modify: `tools/check-subscription-helper-flow.mjs:1-260`
- Modify: `tools/check-config-hot-reload-autoupdate.mjs:1-160`
- Modify: `luci-app-miclash/rootfs/opt/clash/bin/miclash-subscription:1-500`
- Modify: `luci-app-miclash/rootfs/opt/clash/bin/miclash-autoupdate:1-345`

**Interfaces:**
- Consumes: `/opt/clash/settings`, saved `SUBSCRIPTION_URL_CONFIG_YAML`, Mihomo binary.
- Produces: `miclash-subscription apply-saved-main`, key/value result fields, `last_attempt`, and optional service reload.

- [ ] **Step 1: Add failing saved-settings and scheduler tests**

Extend `check-subscription-helper-flow.mjs` with a shell fixture where the primary response is Base64 and the derived `/mihomo` response is valid YAML. Invoke:

```sh
miclash-subscription apply-saved-main
```

Assert that the helper requests both URLs, validates the YAML candidate, atomically replaces `config.yaml`, and prints:

```text
ok=1
mode=remnawave-client-path
target=config.yaml
message=Subscription downloaded and applied.
```

Extend `check-config-hot-reload-autoupdate.mjs` to assert that the daemon invokes `miclash-subscription apply-saved-main`, records `last_attempt` before invocation, and does not become due again until `AUTO_UPDATE_INTERVAL_HOURS * 3600` after a failed invocation.

- [ ] **Step 2: Run focused tests and observe RED**

Run:

```powershell
& 'C:\Users\Ang3el\.cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe' tools/check-subscription-helper-flow.mjs
& 'C:\Users\Ang3el\.cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe' tools/check-config-hot-reload-autoupdate.mjs
```

Expected: both fail because `apply-saved-main` and `last_attempt` do not exist and auto-update still has its own curl/validation pipeline.

- [ ] **Step 3: Add saved-settings mode to `miclash-subscription`**

Make the helper paths testable without changing production defaults:

```sh
BASE_DIR="${MICLASH_BASE_DIR:-/opt/clash}"
CLASH_DATA_DIR="${MICLASH_CLASH_DATA_DIR:-$BASE_DIR}"
CLASH_BIN="${MICLASH_CLASH_BIN:-$BASE_DIR/bin/clash}"
SETTINGS_FILE="${MICLASH_SETTINGS_FILE:-$BASE_DIR/settings}"
```

Use `CLASH_DATA_DIR` for Mihomo's `-d` validation argument and `BASE_DIR` for configuration targets. Then add these saved-settings functions:

```sh
setting_value() {
	key="$1"
	fallback="${2:-}"
	value="$(sed -n "s/^${key}=//p" "$SETTINGS_FILE" 2>/dev/null | tail -n 1)"
	[ -n "$value" ] && printf '%s' "$value" || printf '%s' "$fallback"
}

derive_remnawave_fallback() {
	input="$1"
	case "$input" in *\?*) query="?${input#*\?}"; base="${input%%\?*}" ;; *) query=""; base="$input" ;; esac
	case "$base" in */mihomo) printf '%s%s' "$base" "$query"; return 0 ;; esac
	scheme="${base%%://*}"
	rest="${base#*://}"
	host="${rest%%/*}"
	[ "$host" != "$rest" ] && path="${rest#*/}" || path=""
	new_path="$(printf '%s\n' "$path" | awk -F/ '
		BEGIN { OFS="/" }
		{
			for (i = 1; i <= NF; i++) {
				if ($i == "sub" && i + 1 <= NF) {
					if (i + 2 <= NF && $(i + 2) != "") $(i + 2) = "mihomo"
					else $(++NF) = "mihomo"
					found = 1
					break
				}
			}
			if (!found) $(++NF) = "mihomo"
			print
		}')"
	printf '%s://%s/%s%s' "$scheme" "$host" "$new_path" "$query"
}

append_saved_device_headers() {
	device_os="$(setting_value HWID_DEVICE_OS OpenWrt)"
	printf 'x-device-os: %s\n' "$device_os" >> "$REQUEST_HEADERS_FILE"
	if [ -f /etc/openwrt_release ]; then
		. /etc/openwrt_release
		[ -n "${DISTRIB_RELEASE:-}" ] && printf 'x-ver-os: %s\n' "$DISTRIB_RELEASE" >> "$REQUEST_HEADERS_FILE"
	fi
	model="$(cat /tmp/sysinfo/model 2>/dev/null || true)"
	[ -n "$model" ] && printf 'x-device-model: %s\n' "$model" >> "$REQUEST_HEADERS_FILE"
	if [ "$(setting_value ENABLE_HWID false)" = "true" ]; then
		hwid="$(cat /sys/class/net/eth0/address 2>/dev/null | tr -d ':' | md5sum | cut -c1-14)"
		[ -n "$hwid" ] && printf 'x-hwid: %s\n' "$hwid" >> "$REQUEST_HEADERS_FILE"
	fi
}

load_saved_main_options() {
	URL="$(setting_value SUBSCRIPTION_URL_CONFIG_YAML)"
	[ -n "$URL" ] || URL="$(setting_value SUBSCRIPTION_URL)"
	[ -n "$URL" ] || fail "Subscription URL is empty."
	set_target_name config.yaml
	PROXY_MODE="$(normalize_proxy_mode "$(setting_value PROXY_MODE tproxy)")"
	TUN_STACK="$(normalize_tun_stack "$(setting_value TUN_STACK system)")"
	USER_AGENT="$(setting_value HWID_USER_AGENT MiClash)"
	append_saved_device_headers
	FALLBACK_URL="$(derive_remnawave_fallback "$URL")"
	FALLBACK_ON_ERROR=1
}
```

Before any apply download, enforce:

```sh
[ -x "$CLASH_BIN" ] || fail "Install the Mihomo kernel first."
```

Add dispatch:

```sh
apply-saved-main)
	ACTION="apply-saved-main"
	shift
	load_saved_main_options
	;;
```

Route both `apply` and `apply-saved-main` to the existing `apply_subscription` implementation. Keep `probe-interval` independent from the kernel so header probing can still work before kernel installation.

- [ ] **Step 4: Reduce `miclash-autoupdate` to scheduling and reload**

Add:

```sh
SUBSCRIPTION_BIN="/opt/clash/bin/miclash-subscription"
LAST_ATTEMPT_FILE="$STATE_DIR/last_attempt"
```

Change `is_due()` to read `LAST_ATTEMPT_FILE`. In `run_once()`, after acquiring the lock and before invoking the helper, write `now_sec` to `last_attempt`.

Replace `download_subscription`, `apply_proxy_mode`, `validate_downloaded_config`, and `install_downloaded_config` calls with:

```sh
result="$($SUBSCRIPTION_BIN apply-saved-main 2>&1)" || {
	log_warn "Main subscription update failed: $(printf '%s' "$result" | tr '\r\n' '  ')"
	release_lock
	return 1
}

hours="$(printf '%s\n' "$result" | sed -n 's/^profileUpdateIntervalHours=//p' | tail -n 1)"
case "$hours" in
	''|*[!0-9]*|0) ;;
	*) set_setting_value AUTO_UPDATE_INTERVAL_HOURS "$hours" ;;
esac
```

Retain the existing `is_service_running` branch: reload only when running; log and skip reload when stopped. Write `last_success` only after successful replacement.

- [ ] **Step 5: Verify GREEN and commit**

Run the two focused checks and expect both pass messages.

```bash
git add tools/check-subscription-helper-flow.mjs tools/check-config-hot-reload-autoupdate.mjs luci-app-miclash/rootfs/opt/clash/bin/miclash-subscription luci-app-miclash/rootfs/opt/clash/bin/miclash-autoupdate
git commit -m "fix: unify scheduled subscription updates"
```

---

### Task 5: Add actionable kernel preflight and neutral success copy

**Files:**
- Modify: `tools/check-service-readiness-update-flow.mjs`
- Modify: `tools/check-subscription-helper-flow.mjs`
- Modify: `luci-app-miclash/rootfs/opt/clash/bin/miclash-service:332-345`
- Modify: `luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/config.js:347-355,2815-2825`
- Modify: `luci-app-miclash/rootfs/po/ru/miclash.po`
- Modify: `luci-app-miclash/rootfs/po/zh-cn/miclash.po`

**Interfaces:**
- Consumes: `/opt/clash/bin/clash` executable state.
- Produces: consistent `Install the Mihomo kernel first.` error before service enable/start or subscription download.

- [ ] **Step 1: Add failing service ordering and copy assertions**

In `check-service-readiness-update-flow.mjs`, extract the `start)` case and assert the kernel check occurs before both `"$CLASH_INIT" enable` and `"$CLASH_INIT" start`:

```js
const kernelCheck = startAction.indexOf('[ -x "$CLASH_BIN" ]');
check(kernelCheck >= 0 &&
	kernelCheck < startAction.indexOf('"$CLASH_INIT" enable') &&
	kernelCheck < startAction.indexOf('"$CLASH_INIT" start'),
	'Service start must reject a missing kernel before changing enable or process state.');
```

In `check-subscription-helper-flow.mjs`, assert the apply preflight occurs before `download_primary_or_fallback`.

Add static assertions that `config.js` contains `Install the Mihomo kernel first.` and does not contain `Subscription downloaded and applied (Remnawave /mihomo fallback).`.

- [ ] **Step 2: Run focused checks and observe RED**

Run the service and subscription checks. Expected: missing service preflight and legacy fallback copy failures.

- [ ] **Step 3: Implement the service preflight**

Add `CLASH_BIN="/opt/clash/bin/clash"` near the existing service constants and this helper:

```sh
require_kernel() {
	[ -x "$CLASH_BIN" ] || fail "Install the Mihomo kernel first."
}
```

Call `require_kernel` as the first operation inside the `start)` branch, before enabling the service.

- [ ] **Step 4: Update LuCI copy and translations**

Change `ensureMihomoKernelInstalled()` to throw:

```js
throw new Error(_('Install the Mihomo kernel first.'));
```

Replace both fallback-specific success calls with the existing neutral message:

```js
await logUiAction('info', 'Subscription downloaded and applied');
setOperationSuccess(_('Subscription downloaded and applied.'));
notify('info', _('Subscription downloaded and applied.'));
```

Remove the unused fallback-specific msgid from Russian and Chinese catalogs and add translations for `Install the Mihomo kernel first.`:

```po
msgid "Install the Mihomo kernel first."
msgstr "Сначала установите ядро Mihomo."
```

Add the exact Chinese translation:

```po
msgid "Install the Mihomo kernel first."
msgstr "请先安装 Mihomo 内核。"
```

- [ ] **Step 5: Verify GREEN and commit**

Run:

```powershell
& 'C:\Users\Ang3el\.cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe' tools/check-service-readiness-update-flow.mjs
& 'C:\Users\Ang3el\.cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe' tools/check-subscription-helper-flow.mjs
& 'C:\Users\Ang3el\.cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe' tools/check-translations.mjs
```

Expected: all three pass.

```bash
git add tools/check-service-readiness-update-flow.mjs tools/check-subscription-helper-flow.mjs luci-app-miclash/rootfs/opt/clash/bin/miclash-service luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/config.js luci-app-miclash/rootfs/po/ru/miclash.po luci-app-miclash/rootfs/po/zh-cn/miclash.po
git commit -m "fix: clarify missing kernel operations"
```

---

### Task 6: Full verification and safe router validation

**Files:**
- No planned production changes; any discovered defect returns to the focused task that owns its file and repeats that task's red-green cycle.

**Interfaces:**
- Consumes: completed Tasks 1-5.
- Produces: passing repository checks, shell syntax validation, a safe live-router evidence record, and a review-ready branch.

- [ ] **Step 1: Run every repository check**

```powershell
$node='C:\Users\Ang3el\.cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe'
$failed=@()
Get-ChildItem tools -Filter 'check-*.mjs' | Sort-Object Name | ForEach-Object {
	& $node $_.FullName
	if ($LASTEXITCODE -ne 0) { $failed += $_.Name }
}
if ($failed.Count) { throw "Failed checks: $($failed -join ', ')" }
```

Expected: 14 checks pass, zero failures.

- [ ] **Step 2: Validate all modified shell files with BusyBox-compatible `sh -n`**

Run with Git for Windows shell locally:

```powershell
& 'C:\Program Files\Git\bin\sh.exe' -n install-miclash.sh
& 'C:\Program Files\Git\bin\sh.exe' -n luci-app-miclash/rootfs/opt/clash/bin/miclash-update
& 'C:\Program Files\Git\bin\sh.exe' -n luci-app-miclash/rootfs/opt/clash/bin/miclash-subscription
& 'C:\Program Files\Git\bin\sh.exe' -n luci-app-miclash/rootfs/opt/clash/bin/miclash-autoupdate
& 'C:\Program Files\Git\bin\sh.exe' -n luci-app-miclash/rootfs/opt/clash/bin/miclash-service
& 'C:\Program Files\Git\bin\sh.exe' -n luci-app-miclash/rootfs/etc/init.d/clash
& 'C:\Program Files\Git\bin\sh.exe' -n luci-app-miclash/rootfs/etc/init.d/miclash-autoupdate
```

Expected: every command exits zero with no output.

- [ ] **Step 3: Perform non-disruptive router validation**

Over SSH, capture the Clash PID and guard state. Upload the candidate `miclash-subscription` only to `/tmp`, set `MICLASH_BASE_DIR` and `MICLASH_SETTINGS_FILE` to a temporary directory, set `MICLASH_CLASH_BIN=/opt/clash/bin/clash` and `MICLASH_CLASH_DATA_DIR=/opt/clash`, and verify:

- primary Base64 classification;
- `/mihomo` YAML fallback;
- Mihomo `-t` validation of the temporary file;
- no write to `/opt/clash/config.yaml`;
- unchanged Clash PID;
- guard remains enabled.

Do not invoke `opkg`, `apk`, `/etc/init.d/clash stop`, `/etc/init.d/clash restart`, kernel replacement, or package reinstall on the live router.

- [ ] **Step 4: Inspect diff and repository state**

```bash
git diff main...HEAD --check
git status --short
git log --oneline main..HEAD
```

Expected: no whitespace errors, no uncommitted files, and one focused commit per completed task plus the design/plan commits.

- [ ] **Step 5: Request code review, address verified findings, and re-run Steps 1-4**

Use `superpowers:requesting-code-review`. Apply only findings confirmed against the specification and rerun the complete verification gate after any change.

- [ ] **Step 6: Push and open a draft PR**

Use the `github:yeet` workflow to push `codex/fix-update-subscription-flow` and open a draft PR against `main`. The PR body must include:

- the four confirmed root causes;
- the hard-reinstall/no-autostart semantics;
- automated check results;
- safe router validation results;
- the explicit statement that live package reinstall and live service stop/start were not performed.
