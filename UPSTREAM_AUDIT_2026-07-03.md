# Upstream Audit 2026-07-03

## Final branch status

Final branch:
- `codex/sync-upstream-2026-07-03-finally`

Created from:
- `codex/sync-upstream-2026-07-03` at `ba8f393`

Upstream checked:
- `upstream/main` at `f8990bc` (`v4.7.0`)

Fork/divergence point:
- `aeb0220` (`v4.3.0`, `2026-04-30 09:43:02 +0300`)

Graph status:
- `HEAD..upstream/main` is empty
- `upstream/main` is already merged into the MiClash sync branch through `3f21426`
- no new upstream commits remained to merge after fetching on `2026-07-03`

Final decision:
- keep MiClash package/app names, paths, release endpoints, Russian locale, custom UI, internet-only guard, multi-config profiles, and MiClash installer
- keep upstream runtime/build behavior where it affects correctness
- keep SSClash docs, screenshots, Chinese locale, and `install-ssclash.sh` out of MiClash unless separately adapted later

Branch audited:
- `codex/sync-upstream-2026-07-03`

Compared against:
- merge parent 1: local `main` before sync
- merge parent 2: `upstream/main` at `f8990bc`
- historical upstream tail since old merge-base `aeb0220`

## Summary

This sync branch is not a 1:1 mirror of upstream.

Current status by category:
- Runtime shell/backend fixes: mostly ported
- Web UI bundled assets: ported
- LuCI JS behavior fixes: partially ported
- SSClash branding/docs/install extras: intentionally not ported
- Chinese translation: intentionally not ported
- Upstream CI workflow changes to removed files: intentionally not ported

## Fully or mostly ported

- `16904d6` `fix(clash): poll boot deps instead of fixed sleep at startup`
  - Ported into `luci-app-miclash/rootfs/etc/init.d/clash`

- `cb20d3d` `fix(clash-rules): resilient startup when WAN/DNS unavailable`
  - Ported into `luci-app-miclash/rootfs/opt/clash/bin/clash-rules`

- `842f31c` `fix: restore config before upgrade-triggered start`
  - Ported into package scripts and init script

- `7fcb53b` `fix: preserve fakeip whitelist on incomplete updates`
  - Ported into `clash-rules`

- `05aeb29` `fix: route local fake-ip output before root bypass`
  - Ported into `clash-rules`

- `0c8778f` `fix(settings): kernel download false "Access denied" after install`
  - Mostly ported
  - Evidence:
    - kernel status checks use `clash -v`
    - `fs.stat()` path present
    - ACL includes `/bin/rm`

- `964ab65` `release v4.6.0: UI rebuild and hardened mihomo installer`
  - Runtime/UI bundle effects mostly present
  - Bundled web UI assets updated

## Partially ported

- `f8990bc` `fix(luci): show full clash -t and syslog errors in web UI`
  - Ported:
    - log parsing/unwrap logic in `config.js`
    - helper functions in `utils.js`
  - Missing:
    - config save path still uses local `extractTestError()` instead of `formatClashTestError()`
    - result: full multiline `clash -t` parsing is not actually wired into save validation UI

- `08add6d` `fix(luci): save large configs via chunked base64 write`
  - Ported:
    - chunked `writeFile()` helper exists in `utils.js`
  - Missing:
    - current MiClash `config.js` still writes via `fs.write(...)`
    - result: large config save/browser RPC abort issue may still remain

- `b37992a` `fix(luci): detach clash restart to avoid XHR timeout on slow links`
  - Ported:
    - `execDetached()` helper exists in `utils.js`
    - wait/poll helper exists both in `utils.js` and local code
  - Missing:
    - current MiClash `config.js` still calls `/etc/init.d/clash` synchronously
    - start/stop/restart UX not switched to detached upstream pattern
    - result: slow-link restart timeout behavior may still differ from upstream

## Intentionally not ported

- `c99bda6` `feat: add Chinese UI translation`
  - `luci-app-ssclash/rootfs/po/zh-cn/ssclash.po` intentionally removed
  - Decision: do not port `zh-cn`
  - Reason: direct SSClash-branded locale payload was not adapted to MiClash packaging/naming

- `f08dd21` `Auto installation script`
  - `install-ssclash.sh` intentionally not kept as-is
  - Decision: build a MiClash-specific install script later, with MiClash dependencies and release endpoints

- `3404660`, `9cc78d3`, parts of `a21e611`
  - README/autoinstall/doc changes intentionally not mirrored 1:1
  - Reason: MiClash has different package/release/install endpoints

- upstream screenshots/logo assets under `.github/assets/images/*`
  - intentionally not kept
  - Decision: do not port SSClash screenshots/logo/docs
  - Reason: SSClash branding/docs assets

- upstream `build.yml` updates (`fb9824f`, `ea44f4d`)
  - not ported yet
  - Decision: compare workflow logic by behavior, not file name, and port relevant release/build changes into MiClash workflow if needed

## Preserved local divergence

- MiClash branding/package names/paths kept:
  - `luci-app-miclash`
  - `miclash.po`
  - `view/miclash/*`

- MiClash-specific UX/features kept:
  - internet-only guard
  - multi-config profiles
  - MiClash release endpoints
  - custom LuCI control/settings layout

## High-priority follow-up ports

1. Decide policy for `zh-cn`
   - decided: keep intentionally absent

2. Audit upstream workflow changes vs MiClash `.github/workflows/makefile.yml`
   - compare trigger/build/release behavior
   - port only meaningful logic, not SSClash naming/layout

## Closed after audit

- `f8990bc` full `clash -t` formatter is now wired into MiClash config validation flow
- `08add6d` chunked `utils.writeFile()` is now used for MiClash config/settings writes
- `b37992a` detached service action flow is now adapted into MiClash control/save/reload/restart paths

## Bottom line

This sync put MiClash much closer to upstream runtime behavior, and the main LuCI parity gaps identified during audit have now been closed in the working tree.

Main follow-up areas still open are:
- workflow-behavior comparison vs upstream historical `build.yml` changes
- decision and implementation of a MiClash-native install script

Everything else skipped in this merge was mostly docs/branding/install-surface divergence, not accidental runtime loss.
