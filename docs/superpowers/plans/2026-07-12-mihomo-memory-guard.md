# Mihomo Memory Guard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build an opt-in, router-independent monitor that detects sustained abnormal Mihomo RSS growth under system memory pressure and executes the approved reload → internal restart → full service restart recovery ladder.

**Architecture:** A dedicated POSIX shell monitor runs under its own procd service, reads process and system metrics from `/proc`, and delegates serialized recovery operations to `miclash-service`. The existing LuCI settings page persists one boolean setting and synchronizes the monitor service immediately after save.

**Tech Stack:** OpenWrt procd/rc.common, BusyBox-compatible POSIX shell, LuCI JavaScript, rpcd file ACLs, Node.js source-level regression checks.

## Global Constraints

- `ENABLE_MEMORY_GUARD` defaults to `false` and exposes no manual thresholds in the first release.
- Detection is router-independent: reserve is `clamp(10% of MemTotal, 16 MiB, 64 MiB)`.
- Mihomo anomaly requires RSS at least 150% of baseline and growth of at least 16 MiB.
- Pressure must persist for five one-minute samples; PSI is diagnostic and optional.
- Recovery order is soft reload, internal Mihomo restart, then at most one full Clash service restart.
- Success cooldown is six hours; terminal failure cooldown is 24 hours and rearms only after 30 minutes of normal headroom.
- The guard never reboots the router, kills unrelated processes, changes VM settings, clears global caches, or modifies swap/zram.

---

## File map

- Create `luci-app-miclash/rootfs/opt/clash/bin/miclash-memory-guard`: metric collection, baseline learning, detection, recovery ladder, status/log output, and `sync` command.
- Create `luci-app-miclash/rootfs/etc/init.d/miclash-memory-guard`: independent procd wrapper for the monitor.
- Modify `luci-app-miclash/rootfs/opt/clash/bin/miclash-service`: authenticated generic Mihomo API calls and serialized `guard-reload` / `guard-core-restart` actions.
- Modify `luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/settings-model.js`: persist `ENABLE_MEMORY_GUARD`.
- Modify `luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/config.js`: render, collect, save, and synchronize the checkbox.
- Modify `luci-app-miclash/rootfs/usr/share/rpcd/acl.d/luci-app-miclash.json`: allow LuCI to execute the guard synchronizer.
- Modify `luci-app-miclash/rootfs/po/ru/miclash.po` and `luci-app-miclash/rootfs/po/zh-cn/miclash.po`: translations.
- Modify `luci-app-miclash/Makefile`: install, restore, stop, disable, and remove the guard.
- Create `tools/check-memory-guard.mjs`: executable behavioral and structural regression checks.

---

### Task 1: Detector calculations and runtime state

**Files:**
- Create: `tools/check-memory-guard.mjs`
- Create: `luci-app-miclash/rootfs/opt/clash/bin/miclash-memory-guard`

**Interfaces:**
- Produces CLI: `miclash-memory-guard reserve MEMTOTAL_KB` prints reserve KB.
- Produces CLI: `miclash-memory-guard anomaly BASELINE_KB RSS_KB` returns 0 only for an anomaly.
- Produces CLI: `miclash-memory-guard decreased BEFORE_KB AFTER_KB` returns 0 only for a material decrease.
- Produces daemon entry: `miclash-memory-guard run`.

- [ ] **Step 1: Write failing calculation tests**

Create a Node check that uses Git Bash on Windows and `/bin/sh` elsewhere:

```js
const sh = process.platform === 'win32' ? 'C:/Program Files/Git/bin/sh.exe' : '/bin/sh';
function guard(args) {
	return spawnSync(sh, [guardPath, ...args.map(String)], { encoding: 'utf8' });
}
assert.equal(guard(['reserve', 65536]).stdout.trim(), '16384');
assert.equal(guard(['reserve', 262144]).stdout.trim(), '26214');
assert.equal(guard(['reserve', 2097152]).stdout.trim(), '65536');
assert.equal(guard(['anomaly', 60000, 90000]).status, 0);
assert.notEqual(guard(['anomaly', 60000, 85000]).status, 0);
assert.equal(guard(['decreased', 100000, 80000]).status, 0);
assert.notEqual(guard(['decreased', 100000, 95000]).status, 0);
```

- [ ] **Step 2: Run the check and confirm RED**

Run: `node tools/check-memory-guard.mjs`

Expected: FAIL because `miclash-memory-guard` does not exist.

- [ ] **Step 3: Implement the calculation primitives**

Start the guard with exact constants and integer-only helpers:

```sh
SAMPLE_INTERVAL_SEC=60
PRESSURE_SAMPLES_REQUIRED=5
WARMUP_SEC=900
BASELINE_SAMPLES_REQUIRED=6
MIN_RESERVE_KB=16384
MAX_RESERVE_KB=65536
MIN_GROWTH_KB=16384
SUCCESS_MIN_DROP_KB=8192
SUCCESS_COOLDOWN_SEC=21600
FAILURE_COOLDOWN_SEC=86400
REARM_NORMAL_SEC=1800

calc_reserve_kb() {
	value=$(($1 / 10))
	[ "$value" -lt "$MIN_RESERVE_KB" ] && value="$MIN_RESERVE_KB"
	[ "$value" -gt "$MAX_RESERVE_KB" ] && value="$MAX_RESERVE_KB"
	printf '%s\n' "$value"
}

is_anomaly() {
	baseline="$1" current="$2"
	[ "$baseline" -gt 0 ] || return 1
	[ "$current" -ge $((baseline + MIN_GROWTH_KB)) ] || return 1
	[ $((current * 100)) -ge $((baseline * 150)) ]
}

memory_decreased() {
	before="$1" after="$2" drop=$((before - after))
	[ "$drop" -ge "$SUCCESS_MIN_DROP_KB" ] || return 1
	[ $((drop * 100)) -ge $((before * 10)) ]
}
```

Add `/proc` readers, atomic `key=value` status writes, PID-change reset, six-sample median baseline calculation, five-sample pressure gating, cooldown timestamps, syslog helpers, and the CLI dispatch for `reserve`, `anomaly`, `decreased`, and `run`.

- [ ] **Step 4: Run calculation tests and shell syntax**

Run:

```powershell
node tools/check-memory-guard.mjs
& 'C:\Program Files\Git\bin\sh.exe' -n luci-app-miclash/rootfs/opt/clash/bin/miclash-memory-guard
```

Expected: calculation checks pass and shell syntax exits 0.

- [ ] **Step 5: Commit detector foundation**

```powershell
git add tools/check-memory-guard.mjs luci-app-miclash/rootfs/opt/clash/bin/miclash-memory-guard
git commit -m "feat: add adaptive Mihomo memory detector"
```

---

### Task 2: Serialized soft and internal recovery actions

**Files:**
- Modify: `luci-app-miclash/rootfs/opt/clash/bin/miclash-service`
- Modify: `luci-app-miclash/rootfs/opt/clash/bin/miclash-memory-guard`
- Modify: `tools/check-memory-guard.mjs`

**Interfaces:**
- Consumes: existing `acquire_lock`, `wait_ready`, `config_value`, and `config_port` helpers.
- Produces command: `miclash-service guard-reload`.
- Produces command: `miclash-service guard-core-restart`.
- Guard calls existing `miclash-service restart` only as the one full-service fallback.

- [ ] **Step 1: Extend tests with exact recovery ordering**

Add assertions that the guard source contains one recovery function with this call order and one full-restart guard:

```js
const reloadAt = recovery.indexOf("run_recovery_action guard-reload");
const coreAt = recovery.indexOf("run_recovery_action guard-core-restart");
const fullAt = recovery.indexOf("run_full_restart_once");
assert.ok(reloadAt >= 0 && reloadAt < coreAt && coreAt < fullAt);
assert.match(recovery, /FULL_RESTART_ATTEMPTED=1/);
assert.match(service, /guard-core-restart[\s\S]*restart_mihomo_api[\s\S]*wait_ready/);
```

- [ ] **Step 2: Run the check and confirm RED**

Run: `node tools/check-memory-guard.mjs`

Expected: FAIL for missing recovery actions.

- [ ] **Step 3: Refactor Mihomo API access and add internal restart**

In `miclash-service`, factor the existing curl construction into:

```sh
mihomo_api_request() {
	method="$1" endpoint="$2" body="${3:-}"
	ec="$(config_value "external-controller")"
	ec_tls="$(config_value "external-controller-tls")"
	secret="$(config_value "secret")"
	scheme="http"
	port="$(config_port "$ec" "9090")"
	[ -n "$ec_tls" ] && scheme="https" && port="$(config_port "$ec_tls" "9090")"
	url="$scheme://127.0.0.1:$port$endpoint"
	set -- -fsS --connect-timeout 2 --max-time 8 -X "$method" -H "Content-Type: application/json"
	[ "$scheme" = "https" ] && set -- "$@" -k
	[ -n "$secret" ] && set -- "$@" -H "Authorization: Bearer $secret"
	[ -n "$body" ] && set -- "$@" -d "$body"
	curl "$@" "$url"
}

restart_mihomo_api() {
	write_status running api "Restarting Mihomo kernel through API"
	output="$(mihomo_api_request POST /restart '{"path":"'"$CONFIG_FILE"'"}' 2>&1)"
	[ "$?" -eq 0 ] || fail "failed to restart Mihomo kernel: $output"
}
```

Keep normal UI `reload` behavior unchanged. Add direct locked cases:

```sh
guard-reload)
	hot_reload_config
	wait_ready
	;;
guard-core-restart)
	restart_mihomo_api
	wait_ready
	;;
```

- [ ] **Step 4: Implement the recovery ladder in the guard**

Implement `recover_memory()` so each stage captures RSS before action, waits for helper readiness plus 60 seconds, remeasures, and stops only when `memory_decreased` succeeds. `run_full_restart_once` must set `FULL_RESTART_ATTEMPTED=1` before invoking `miclash-service restart`, and every terminal path writes status plus the six-hour or 24-hour cooldown.

- [ ] **Step 5: Run focused checks**

Run:

```powershell
node tools/check-memory-guard.mjs
& 'C:\Program Files\Git\bin\sh.exe' -n luci-app-miclash/rootfs/opt/clash/bin/miclash-service
& 'C:\Program Files\Git\bin\sh.exe' -n luci-app-miclash/rootfs/opt/clash/bin/miclash-memory-guard
```

Expected: all commands exit 0.

- [ ] **Step 6: Commit recovery actions**

```powershell
git add tools/check-memory-guard.mjs luci-app-miclash/rootfs/opt/clash/bin/miclash-service luci-app-miclash/rootfs/opt/clash/bin/miclash-memory-guard
git commit -m "feat: add staged Mihomo memory recovery"
```

---

### Task 3: procd service and package lifecycle

**Files:**
- Create: `luci-app-miclash/rootfs/etc/init.d/miclash-memory-guard`
- Modify: `luci-app-miclash/rootfs/opt/clash/bin/miclash-memory-guard`
- Modify: `luci-app-miclash/Makefile`
- Modify: `luci-app-miclash/rootfs/usr/share/rpcd/acl.d/luci-app-miclash.json`
- Modify: `tools/check-memory-guard.mjs`

**Interfaces:**
- Produces init service `/etc/init.d/miclash-memory-guard`.
- Produces `miclash-memory-guard sync`, which reads `ENABLE_MEMORY_GUARD` and performs enable/start or stop/disable.

- [ ] **Step 1: Add failing lifecycle and ACL assertions**

Assert the Makefile installs both files, post-install runs `miclash-memory-guard sync`, post-remove stops/disables the service and removes `/tmp/miclash-memory-guard`, and ACL grants exec to `/opt/clash/bin/miclash-memory-guard`.

- [ ] **Step 2: Run checks and confirm RED**

Run: `node tools/check-memory-guard.mjs`

Expected: FAIL for missing init, package, and ACL integration.

- [ ] **Step 3: Add the independent procd service**

Create:

```sh
#!/bin/sh /etc/rc.common
START=22
STOP=78
USE_PROCD=1

start_service() {
	grep -q '^ENABLE_MEMORY_GUARD=true$' /opt/clash/settings 2>/dev/null || return 0
	procd_open_instance
	procd_set_param command /opt/clash/bin/miclash-memory-guard run
	procd_set_param respawn 3600 5 5
	procd_set_param stdout 1
	procd_set_param stderr 1
	procd_close_instance
}
```

Implement `sync` with idempotent enable/start and stop/disable behavior.

- [ ] **Step 4: Wire package and ACL lifecycle**

Install both executables in the Makefile; call `sync` after restored settings in `postinst`; stop/disable in `postrm`; remove runtime state; add read/write exec ACL entries for the guard executable.

- [ ] **Step 5: Run lifecycle, ACL, JSON, and syntax checks**

Run:

```powershell
node tools/check-memory-guard.mjs
node tools/check-luci-acl-coverage.mjs
Get-Content -Raw luci-app-miclash/rootfs/usr/share/rpcd/acl.d/luci-app-miclash.json | ConvertFrom-Json | Out-Null
& 'C:\Program Files\Git\bin\sh.exe' -n luci-app-miclash/rootfs/etc/init.d/miclash-memory-guard
```

Expected: every command exits 0.

- [ ] **Step 6: Commit service lifecycle**

```powershell
git add luci-app-miclash/Makefile luci-app-miclash/rootfs/etc/init.d/miclash-memory-guard luci-app-miclash/rootfs/opt/clash/bin/miclash-memory-guard luci-app-miclash/rootfs/usr/share/rpcd/acl.d/luci-app-miclash.json tools/check-memory-guard.mjs
git commit -m "feat: package Mihomo memory guard service"
```

---

### Task 4: Opt-in LuCI setting

**Files:**
- Modify: `luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/settings-model.js`
- Modify: `luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/config.js`
- Modify: `luci-app-miclash/rootfs/po/ru/miclash.po`
- Modify: `luci-app-miclash/rootfs/po/zh-cn/miclash.po`
- Modify: `tools/check-memory-guard.mjs`

**Interfaces:**
- Consumes: `miclash-memory-guard sync` and its ACL from Task 3.
- Produces setting property `enableMemoryGuard: boolean` and persisted key `ENABLE_MEMORY_GUARD`.

- [ ] **Step 1: Add failing UI persistence assertions**

Assert all of the following:

```js
assert.match(settingsModel, /enableMemoryGuard: false/);
assert.match(settingsModel, /case 'ENABLE_MEMORY_GUARD': settings\.enableMemoryGuard = value === 'true'/);
assert.match(settingsModel, /settings\.ENABLE_MEMORY_GUARD = enableMemoryGuard/);
assert.match(config, /id="sbox-memory-guard"/);
assert.match(config, /fs\.exec\('\/opt\/clash\/bin\/miclash-memory-guard', \['sync'\]\)/);
```

- [ ] **Step 2: Run checks and confirm RED**

Run: `node tools/check-memory-guard.mjs`

Expected: FAIL for missing setting and checkbox.

- [ ] **Step 3: Thread the setting through the settings model**

Add `enableMemoryGuard` immediately after `useTmpfsRules` in defaults, parsing, save function parameters, and `settings.ENABLE_MEMORY_GUARD` assignment. Update every caller in `config.js`, including header proxy-mode saves, so unrelated saves preserve the current value.

- [ ] **Step 4: Render, collect, save, and sync the checkbox**

Render in the Additional block:

```js
'<label class="sbox-checkbox-row">' +
	'<input type="checkbox" id="sbox-memory-guard"' + (s.enableMemoryGuard ? ' checked' : '') + ' />' +
	'<span>' + safeText(_('Monitor abnormal Mihomo memory usage')) + '</span>' +
'</label>' +
'<div class="sbox-muted sbox-settings-help">' +
	safeText(_('Learns normal Mihomo memory use and applies staged recovery only during sustained system memory pressure.')) +
'</div>'
```

After `saveOperationalSettings` succeeds, execute `miclash-memory-guard sync`. Treat sync failure as a settings-application error and show its stderr.

- [ ] **Step 5: Add exact Russian and Chinese translations**

Russian:

```po
msgid "Monitor abnormal Mihomo memory usage"
msgstr "Контролировать аномальное потребление памяти Mihomo"

msgid "Learns normal Mihomo memory use and applies staged recovery only during sustained system memory pressure."
msgstr "Определяет нормальное потребление памяти Mihomo и применяет поэтапное восстановление только при длительном дефиците памяти в системе."
```

Add an accurate equivalent Chinese translation for both messages.

```po
msgid "Monitor abnormal Mihomo memory usage"
msgstr "监控 Mihomo 异常内存使用"

msgid "Learns normal Mihomo memory use and applies staged recovery only during sustained system memory pressure."
msgstr "学习 Mihomo 的正常内存占用，仅在系统持续内存压力下执行分阶段恢复。"
```

- [ ] **Step 6: Run UI regression and translation checks**

Run:

```powershell
node tools/check-memory-guard.mjs
node tools/check-settings-restart-feedback.mjs
node tools/check-luci-acl-coverage.mjs
node tools/check-translations.mjs
```

Expected: all checks pass.

- [ ] **Step 7: Commit UI setting**

```powershell
git add luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/settings-model.js luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/config.js luci-app-miclash/rootfs/po/ru/miclash.po luci-app-miclash/rootfs/po/zh-cn/miclash.po tools/check-memory-guard.mjs
git commit -m "feat: add Mihomo memory guard setting"
```

---

### Task 5: Full verification and documentation polish

**Files:**
- Modify: `tools/check-memory-guard.mjs`

**Interfaces:**
- Verifies all interfaces produced by Tasks 1–4.

- [ ] **Step 1: Add final invariants to the focused check**

Require that the guard status contains `phase`, `baseline_rss_kb`, `current_rss_kb`, `mem_available_kb`, `reserve_kb`, `last_action`, `last_result`, and `cooldown_until`; require that no command contains `reboot`, `drop_caches`, `swapon`, `swapoff`, or a generic `kill` of another PID.

- [ ] **Step 2: Run the complete repository check suite**

Run:

```powershell
Get-ChildItem tools/check-*.mjs | Sort-Object Name | ForEach-Object {
	node $_.FullName
	if ($LASTEXITCODE -ne 0) { throw "Failed: $($_.Name)" }
}
```

Expected: every check script reports success.

- [ ] **Step 3: Run all shell and data-format validation**

Run:

```powershell
$sh='C:\Program Files\Git\bin\sh.exe'
& $sh -n luci-app-miclash/rootfs/opt/clash/bin/miclash-memory-guard
& $sh -n luci-app-miclash/rootfs/opt/clash/bin/miclash-service
& $sh -n luci-app-miclash/rootfs/etc/init.d/miclash-memory-guard
& $sh -n luci-app-miclash/rootfs/etc/init.d/clash
Get-Content -Raw luci-app-miclash/rootfs/usr/share/rpcd/acl.d/luci-app-miclash.json | ConvertFrom-Json | Out-Null
git diff --check
```

Expected: every command exits 0 and `git diff --check` is clean.

- [ ] **Step 4: Inspect the final diff against the design**

Run: `git diff main...HEAD --stat` and `git diff main...HEAD -- luci-app-miclash tools`

Confirm the checkbox is off by default, recovery ordering is exact, full restart is single-shot, PSI is optional, and no router model appears in the implementation.

- [ ] **Step 5: Commit any final check or documentation changes**

```powershell
git add tools/check-memory-guard.mjs
git diff --cached --quiet || git commit -m "test: finalize Mihomo memory guard checks"
```
