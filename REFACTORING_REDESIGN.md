# Refactoring Redesign Plan

Goal: keep MiClash UI/UX and local features, but make future upstream syncs from
`zerolabnet/SSClash` predictable and readable.

## Current baseline

- Working branch: `refactoring-redesign`
- Upstream remote: `upstream/main`
- Current upstream head checked during branch creation: `f8990bc`
- Current MiClash main checked during this pass: `a785b41`
- Existing audit: `UPSTREAM_AUDIT_2026-07-03.md`

## Keep

- MiClash package name, release artifacts, install script, and GitHub endpoints.
- Current MiClash visual design.
- Russian locale.
- MiClash-only behavior:
  - internet-only guard
  - multi-config profiles
  - MiClash installer flow
  - custom LuCI control/settings layout

## Align with upstream

- Runtime scripts:
  - `rootfs/etc/init.d/clash`
  - `rootfs/opt/clash/bin/clash-rules`
  - hotplug scripts
- LuCI service behavior:
  - detached start/stop/restart
  - chunked config writes
  - full `clash -t` and syslog error display
- OpenWrt package behavior:
  - `Makefile` install/uninstall hooks
  - apk/opkg compatibility
  - protected paths
  - minimal dependency drift from SSClash unless MiClash needs extra deps

## Diff strategy

Future work should avoid mixing upstream sync, MiClash branding, and UI redesign in
one commit.

Recommended stack:

1. `sync-upstream/*`
   - merge or cherry-pick pure SSClash changes
   - keep commit payload close to upstream
   - no UI redesign edits

2. `refactor/openwrt-layout`
   - OpenWrt packaging/rules compatibility only
   - package name remains `luci-app-miclash`
   - no visual changes

3. `refactor/ui-adapter`
   - isolate MiClash UI as thin adapter over upstream-compatible helpers
   - shared helpers should stay close to SSClash names and behavior
   - MiClash-specific panels should be clearly marked in file/module names

4. `feature/miclash-local`
   - internet-only guard, profiles, installer, endpoints
   - local changes kept outside upstream-equivalent blocks where possible

## Practical rules

- When upstream changes a file, first port upstream behavior with minimal rename
  noise, then add MiClash-specific changes in a separate commit.
- Keep helper APIs upstream-shaped unless MiClash needs a real extension.
- Prefer additive MiClash helpers over editing upstream-equivalent logic inline.
- Do not copy SSClash docs, screenshots, or branding unless adapted.
- Do not add Chinese locale unless MiClash intentionally supports it.

## First implementation pass

1. Compare current `Makefile` with `upstream/main:luci-app-ssclash/Makefile`.
2. Normalize OpenWrt package hooks where MiClash diverged without need.
3. Split LuCI `config.js` into:
   - upstream-compatible utility/service functions
   - MiClash visual/layout layer
   - MiClash-only feature layer
4. Re-check runtime scripts against upstream after each upstream fetch.
5. Add narrow verification:
   - shell syntax checks for scripts
   - package file list check
   - LuCI JS parse/build check if available

## Remaining split boundaries

`config.js` is now smaller and should stay as the MiClash adapter layer. Further
splits should be feature-driven, not mechanical.

Keep `config.js` as the MiClash adapter layer: page state, current visual layout,
and event binding.

## Progress

- Created `refactoring-redesign` from the current MiClash upstream-sync branch.
- Added this refactoring plan as the branch contract.
- Changed LuCI menu shape to match upstream:
  - root entry is an alias
  - child pages are `config`, `settings`, `rulesets`, and `log`
- Preserved current MiClash single-page design through thin view wrappers:
  - `settings.js`
  - `rulesets.js`
  - `log.js`
- Added route selection to `config.js`, so upstream-shaped LuCI pages open the
  matching MiClash tab/modal.
- Reordered ACL entries upstream-first while keeping the permission set
  unchanged.
- Kept MiClash tag-based release workflow, but added upstream-style release
  notes generation from commits since the previous tag.
- Split route/page selection out of `config.js` into `route.js`, keeping the
  current MiClash UI as the rendered layer.
- Split service status/action dispatch out of `config.js` into `service.js`;
  UI code now calls a shared service helper instead of owning init.d polling.
- Split config profile, settings map, and subscription URL storage helpers out
  of `config.js` into `store.js`.
- Split version parsing, release lookup, and release asset matching helpers out
  of `config.js` into `release.js`.
- Split package-manager detection, dependency installation, curl repair, and
  OpenWrt release detection helpers out of `config.js` into `package.js`.
- Split logread access and syslog/clash log line normalization out of
  `config.js` into `logs.js`.
- Started `subscription.js` with URI/base64/YAML detection, subscription client
  profile, and Remnawave `/mihomo` URL normalization.
- Moved subscription device headers, curl download, and temporary subscription
  cleanup into `subscription.js`.
- Moved config test/write helper into `subscription.js`, with `config.js`
  passing kernel availability as a callback.
- Added `.github/scripts/verify-luci-js.mjs` and wired it into the build
  workflow, so split LuCI modules are syntax-checked and missing
  `view.miclash.*` dependencies fail CI before SDK build.
- Extended the LuCI verifier to check that every `view_miclash_*` helper global
  used by a module has a matching `'require view.miclash.*'` declaration, so
  module splits cannot leave runtime-only missing imports.
- Extended the verifier to check LuCI menu `view` paths and ACL object naming,
  so upstream-shaped menu entries cannot point at missing MiClash view files.
- Extended the verifier to check literal absolute `fs.exec/read/write/remove/stat/list`
  paths against rpcd ACL file permissions, so future LuCI helper splits cannot
  accidentally add OpenWrt RPC calls without matching ACL coverage.
- Extended the same ACL verifier to cover known relative `fs.exec()` commands
  (`ls`, `ip`, `opkg`, `apk`) against their OpenWrt absolute binary ACL paths.
- Added `.github/scripts/verify-openwrt-shell.mjs` and wired it into the build
  workflow, so package install/init/hotplug/firewall shell scripts get `sh -n`
  validation before SDK builds.
- Added `.github/scripts/verify-package-layout.mjs` and wired it into the build
  workflow, so required OpenWrt package files, Makefile install snippets,
  protected APK paths, and LuCI route wrapper modules are checked before SDK
  builds.
- Added `.gitattributes` LF policy for OpenWrt shell scripts, Makefiles,
  workflow files, LuCI JS/JSON, locale, and docs so Windows checkouts cannot
  silently rewrite package/runtime scripts to CRLF.
- Fast-forwarded `refactoring-redesign` onto current `origin/main` (`a785b41`)
  after fetch; `origin/master` does not exist in this repository.
- Split ruleset listing/read/write/delete and fake-ip whitelist detection into
  `rulesets-model.js`; `config.js` keeps only the MiClash modal/UI wiring.
- Split operational settings load/save, interface detection, HWID config
  transform, and proxy-mode config transform into `settings-model.js`.
- Started `ui-shell.js` with generic modal rendering and button busy-state
  helpers; `config.js` keeps thin wrappers so existing MiClash event wiring does
  not churn.
- Moved theme normalization, Ace theme application, theme persistence, and
  root theme class/button updates into `ui-shell.js`.
- Moved tab binding and generic interval start/stop helpers into `ui-shell.js`;
  `config.js` keeps only MiClash state updates and side-effect callbacks.
- Aligned OpenWrt transparent-proxy dependency declarations with upstream:
  package metadata, install script, web self-repair, and README now avoid direct
  NAT package drift. `zlib` and `libcurl4` remain explicit MiClash dependencies
  because previous router installs needed them for reliable curl/runtime repair.
- Audited runtime script drift against `upstream/main`: hotplug function layout
  still matches upstream; `init.d/clash` and `clash-rules` differ where MiClash
  owns internet-only guard, subscription-safe transparent ports, router-output
  handling, package delete, and full cleanup behavior.

## Non-goals

- Renaming MiClash back to SSClash.
- Dropping current MiClash design.
- Removing MiClash-only features just to reduce diff.
- Replacing bundled `/opt/clash/ui` assets without a separate UI asset decision.
