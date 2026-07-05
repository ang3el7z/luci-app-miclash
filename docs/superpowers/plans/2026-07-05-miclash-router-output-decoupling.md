# MiClash Router OUTPUT Decoupling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the remaining coupling where the client/device guard setting changes router-originated OUTPUT routing.

**Architecture:** Keep client guard enforcement in FORWARD only. Restore router OUTPUT handling to normal MiClash behavior regardless of `INTERNET_ONLY_MICLASH`, while preserving existing ordinary OUTPUT fake-ip/marking behavior and stale legacy OUTPUT guard cleanup.

**Tech Stack:** POSIX shell for OpenWrt firewall rules, nftables, iptables, LuCI JavaScript syntax check for touched UI-adjacent package state.

---

### Task 1: Remove Client Guard Coupling From OUTPUT Helpers

**Files:**
- Modify: `luci-app-miclash/rootfs/opt/clash/bin/clash-rules`

- [ ] **Step 1: Run failing guard-policy scan**

Run:

```powershell
rg -n 'apply_nft_output_redirect_rules|apply_iptables_output_redirect_rules|output_redir|CLASH_OUTPUT_REDIRECT|client guard policy enabled|client forwarding guard option is active|INTERNET_ONLY_MICLASH.*output|root traffic flows through Clash' luci-app-miclash/rootfs/opt/clash/bin/clash-rules
```

Expected before implementation: matches in OUTPUT helper code.

- [ ] **Step 2: Remove nftables redirect helper and call**

Delete the complete `apply_nft_output_redirect_rules()` function.

Delete this call from `apply_nft_rules()`:

```sh
apply_nft_output_redirect_rules "$server_ips" || return 1
```

- [ ] **Step 3: Restore normal nftables OUTPUT exclusions**

In `apply_nft_clash_exclusions_output()`, remove the `INTERNET_ONLY_MICLASH` branch and always add the root bypass:

```sh
nft add rule inet clash output meta skuid 0 return
nft add rule inet clash output tcp sport {7890, 7891, 7892, 7893, 7894} return
nft add rule inet clash output udp sport {7890, 7891, 7892, 7893, 7894} return
msg "Clash process and ports excluded from proxy in output"
```

In `apply_nft_output_rules()`, always call:

```sh
apply_nft_interface_exclusion_output "$excluded_interfaces"
```

Do not log `client guard policy enabled` from OUTPUT logic.

- [ ] **Step 4: Restore normal nftables OUTPUT marking branch**

In `apply_nft_output_rules()`, remove branches where `INTERNET_ONLY_MICLASH=true` changes TCP/UDP marking. When `fake_ip_range` is empty, keep the ordinary behavior:

```sh
nft add rule inet clash output meta mark 0 meta l4proto tcp meta mark set "$MARK_TPROXY"
nft add rule inet clash output meta mark 0 meta l4proto udp meta mark set "$output_udp_mark"
msg "OUTPUT: Marking applied for all traffic"
```

- [ ] **Step 5: Remove iptables redirect helper and call**

Delete the complete `apply_iptables_output_redirect_rules()` function.

Delete this call from `apply_iptables_rules()`:

```sh
apply_iptables_output_redirect_rules "$server_ips" || return 1
```

- [ ] **Step 6: Restore normal iptables OUTPUT exclusions and marking**

In `apply_iptables_output_rules()`, always call:

```sh
apply_iptables_interface_exclusion_output "$excluded_interfaces"
```

Remove branches where `INTERNET_ONLY_MICLASH=true` changes TCP/UDP marking. Keep the existing fake-ip branch and ordinary all-traffic marking branch, with the ordinary log:

```sh
msg "OUTPUT: Marking applied for all traffic"
```

- [ ] **Step 7: Run guard-policy scan again**

Run:

```powershell
rg -n 'apply_nft_output_redirect_rules|apply_iptables_output_redirect_rules|output_redir|CLASH_OUTPUT_REDIRECT|client guard policy enabled|client forwarding guard option is active|root traffic flows through Clash' luci-app-miclash/rootfs/opt/clash/bin/clash-rules
```

Expected after implementation: no matches.

### Task 2: Verify And Commit

**Files:**
- Verify: `luci-app-miclash/rootfs/opt/clash/bin/clash-rules`
- Verify: `luci-app-miclash/rootfs/etc/init.d/clash`
- Verify: `luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/config.js`

- [ ] **Step 1: Run shell syntax checks**

Run:

```powershell
& 'C:\Program Files\Git\usr\bin\sh.exe' -n 'luci-app-miclash/rootfs/opt/clash/bin/clash-rules'
& 'C:\Program Files\Git\usr\bin\sh.exe' -n 'luci-app-miclash/rootfs/etc/init.d/clash'
```

Expected: both commands exit 0.

- [ ] **Step 2: Run LuCI JavaScript syntax check**

Run:

```powershell
node --check 'luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/config.js'
```

Expected: exit 0.

- [ ] **Step 3: Confirm client guard remains FORWARD-only**

Run:

```powershell
rg -n 'MICLASH_GUARD_FORWARD|hook forward|FORWARD' luci-app-miclash/rootfs/opt/clash/bin/clash-rules
rg -n 'MICLASH_GUARD_OUTPUT|cleanup_legacy_guard_output|guard output|chain output|hook output' luci-app-miclash/rootfs/opt/clash/bin/clash-rules
```

Expected: FORWARD guard rules are present; `MICLASH_GUARD_OUTPUT` appears only in removal-only legacy cleanup if present.

- [ ] **Step 4: Confirm diff hygiene**

Run:

```powershell
git diff --check
git status --short
```

Expected: `git diff --check` exits 0; status shows only intended files before commit and clean after commit.

- [ ] **Step 5: Commit**

Run:

```powershell
git add -- docs/superpowers/plans/2026-07-05-miclash-router-output-decoupling.md luci-app-miclash/rootfs/opt/clash/bin/clash-rules
git commit -m 'fix: decouple client guard from router output'
```
