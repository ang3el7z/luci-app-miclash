# MiClash Client-Only Guard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make "Internet only through MiClash" protect only client/device forwarding traffic, while router-originated update and download operations continue to work without network repair.

**Architecture:** The firewall guard becomes a FORWARD-only fail-closed layer for client traffic. LuCI update/download flows stop calling guard repair/preflight logic. User-facing text is updated so the option clearly refers to client devices rather than all router traffic.

**Tech Stack:** POSIX shell for `clash-rules`, LuCI JavaScript modules, gettext `.po` translation files, PowerShell/rg for static verification, `sh -n` for shell syntax checks.

---

### File Structure

- Modify `luci-app-miclash/rootfs/opt/clash/bin/clash-rules`: remove guard OUTPUT chain handling and remove `repair_network_path`.
- Modify `luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/config.js`: remove guard preflight/skip logic from update and subscription flows.
- Delete `luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/guard.js`: old module only models router-update blocking and repair.
- Modify `luci-app-miclash/rootfs/po/ru/miclash.po`: replace/remove obsolete strings.
- Modify comments/log wording in `luci-app-miclash/rootfs/etc/init.d/clash` and `clash-rules` where they describe the guard as all router internet protection.

### Task 1: Make Shell Guard FORWARD-Only

**Files:**
- Modify: `luci-app-miclash/rootfs/opt/clash/bin/clash-rules`

- [ ] **Step 1: Run the current failing static guard check**

```powershell
if (rg -q 'MICLASH_GUARD_OUTPUT|repair_network_path|nft add chain inet "\$GUARD_NFT_TABLE" output|\-j "\$GUARD_OUTPUT_CHAIN"' luci-app-miclash\rootfs\opt\clash\bin\clash-rules) {
    Write-Error 'Old OUTPUT guard or repair_network_path is still present.'
    exit 1
}
```

Expected: command fails now with `Old OUTPUT guard or repair_network_path is still present.`

- [ ] **Step 2: Remove the output guard constant**

Delete this line:

```sh
readonly GUARD_OUTPUT_CHAIN="MICLASH_GUARD_OUTPUT"
```

Keep:

```sh
readonly GUARD_NFT_TABLE="miclash_guard"
readonly GUARD_FORWARD_CHAIN="MICLASH_GUARD_FORWARD"
```

- [ ] **Step 3: Replace `apply_nft_guard_rules` with FORWARD-only behavior**

Inside `apply_nft_guard_rules`, keep the table, `local4`, `local6`, and `forward` chain setup. Remove the `output` chain and every `nft add rule ... output ...` line.

The central part of the function should read:

```sh
nft add chain inet "$GUARD_NFT_TABLE" forward '{ type filter hook forward priority 1; policy accept; }' || return 1

nft add rule inet "$GUARD_NFT_TABLE" forward ct state established,related accept
nft add rule inet "$GUARD_NFT_TABLE" forward iifname "clash-tun" accept
nft add rule inet "$GUARD_NFT_TABLE" forward oifname "clash-tun" accept
nft add rule inet "$GUARD_NFT_TABLE" forward ct status dnat accept
nft add rule inet "$GUARD_NFT_TABLE" forward udp sport 67 udp dport 68 accept
nft add rule inet "$GUARD_NFT_TABLE" forward udp sport 68 udp dport 67 accept
nft add rule inet "$GUARD_NFT_TABLE" forward ip daddr @local4 accept
nft add rule inet "$GUARD_NFT_TABLE" forward ip6 daddr @local6 accept

if [ -n "$wan_interfaces" ]; then
    msg "Internet-only client guard external interfaces: $(echo "$wan_interfaces" | tr '\n' ' ')"
    echo "$wan_interfaces" | while IFS= read -r iface; do
        [ -n "$iface" ] || continue
        nft add rule inet "$GUARD_NFT_TABLE" forward oifname "$iface" drop comment "miclash-guard"
    done
else
    warn "Internet-only client guard could not detect WAN interfaces; falling back to blocking all non-local forwarding"
    nft add rule inet "$GUARD_NFT_TABLE" forward meta nfproto ipv4 drop comment "miclash-guard"
    nft add rule inet "$GUARD_NFT_TABLE" forward meta nfproto ipv6 drop comment "miclash-guard"
fi

msg "Internet-only client guard enabled (nftables)"
```

- [ ] **Step 4: Replace iptables guard cleanup with FORWARD-only cleanup**

Update `remove_iptables_guard_for_cmd` so it only detaches and removes the forward chain:

```sh
remove_iptables_guard_for_cmd() {
    local cmd="$1"

    command -v "$cmd" >/dev/null 2>&1 || return 0

    while $cmd -t filter -D FORWARD -j "$GUARD_FORWARD_CHAIN" 2>/dev/null; do :; done
    $cmd -t filter -F "$GUARD_FORWARD_CHAIN" 2>/dev/null
    $cmd -t filter -X "$GUARD_FORWARD_CHAIN" 2>/dev/null
}
```

- [ ] **Step 5: Replace iptables guard application with FORWARD-only rules**

Update `apply_iptables_guard_for_cmd` so it no longer creates or populates an OUTPUT chain. The function body after command availability should be:

```sh
remove_iptables_guard_for_cmd "$cmd"
ensure_iptables_guard_chain "$cmd" FORWARD "$GUARD_FORWARD_CHAIN" || return 1

$cmd -t filter -A "$GUARD_FORWARD_CHAIN" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
$cmd -t filter -A "$GUARD_FORWARD_CHAIN" -i clash-tun -j RETURN
$cmd -t filter -A "$GUARD_FORWARD_CHAIN" -o clash-tun -j RETURN
[ "$family" = "ipv4" ] && $cmd -t filter -A "$GUARD_FORWARD_CHAIN" -m conntrack --ctstate DNAT -j RETURN 2>/dev/null
$cmd -t filter -A "$GUARD_FORWARD_CHAIN" -p udp --sport 67 --dport 68 -j RETURN 2>/dev/null
$cmd -t filter -A "$GUARD_FORWARD_CHAIN" -p udp --sport 68 --dport 67 -j RETURN 2>/dev/null

for network in $reserved_networks; do
    $cmd -t filter -A "$GUARD_FORWARD_CHAIN" -d "$network" -j RETURN 2>/dev/null
done

if [ -n "$wan_interfaces" ]; then
    echo "$wan_interfaces" | while IFS= read -r iface; do
        [ -n "$iface" ] || continue
        $cmd -t filter -A "$GUARD_FORWARD_CHAIN" -o "$iface" -j DROP
    done
else
    $cmd -t filter -A "$GUARD_FORWARD_CHAIN" -j DROP
fi

$cmd -t filter -A "$GUARD_FORWARD_CHAIN" -j RETURN
```

- [ ] **Step 6: Update iptables guard log wording**

Change:

```sh
warn "Internet-only guard could not detect WAN interfaces; falling back to blocking all non-local forwarding/output"
msg "Internet-only guard enabled (iptables)"
```

To:

```sh
warn "Internet-only client guard could not detect WAN interfaces; falling back to blocking all non-local forwarding"
msg "Internet-only client guard enabled (iptables)"
```

- [ ] **Step 7: Remove network path repair helpers and entry point**

Delete the complete `traffic_rules_exist()` function and the complete `repair_network_path()` function.

Delete this `case` arm:

```sh
    repair_network_path)
        if repair_network_path; then
            msg "Network path repaired successfully"
            exit 0
        else
            warn "Network path repair failed"
            exit 1
        fi
        ;;
```

Update usage text from:

```sh
echo "Usage: $0 {start|stop|restart|update|update-ip-whitelist|guard_start|guard_stop|guard_refresh|full_cleanup|tun_route_setup|tun_route_watch|validate_policy|repair_policy|repair_network_path|validate_forward|repair_forward_rules}"
```

To:

```sh
echo "Usage: $0 {start|stop|restart|update|update-ip-whitelist|guard_start|guard_stop|guard_refresh|full_cleanup|tun_route_setup|tun_route_watch|validate_policy|repair_policy|validate_forward|repair_forward_rules}"
```

- [ ] **Step 8: Run shell guard static check**

```powershell
if (rg -q 'MICLASH_GUARD_OUTPUT|repair_network_path|nft add chain inet "\$GUARD_NFT_TABLE" output|\-j "\$GUARD_OUTPUT_CHAIN"' luci-app-miclash\rootfs\opt\clash\bin\clash-rules) {
    Write-Error 'Old OUTPUT guard or repair_network_path is still present.'
    exit 1
}
```

Expected: no output, exit code `0`.

- [ ] **Step 9: Commit shell guard change**

```powershell
git add -- luci-app-miclash/rootfs/opt/clash/bin/clash-rules
git commit -m "fix: make internet-only guard client-only"
```

Expected: commit succeeds and includes only `clash-rules`.

### Task 2: Remove UI Network Repair And Skip Flow

**Files:**
- Modify: `luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/config.js`
- Delete: `luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/guard.js`

- [ ] **Step 1: Run the current failing UI static check**

```powershell
if (rg -q 'view_miclash_guard|prepareNetworkUpdate|shouldSkipSubscriptionDownload|skippedSubscriptionMessage|Network path repair failed|Download skipped' luci-app-miclash\rootfs\www\luci-static\resources\view\miclash) {
    Write-Error 'Old UI guard repair/skip flow is still present.'
    exit 1
}
```

Expected: command fails now with `Old UI guard repair/skip flow is still present.`

- [ ] **Step 2: Remove the guard module require**

Delete this line from `config.js`:

```js
'require view.miclash.guard';
```

- [ ] **Step 3: Delete the old guard module**

Delete:

```text
luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/guard.js
```

- [ ] **Step 4: Remove update preflight calls from package/kernel/subscription flows**

In `installMiClashFromSettings`, remove:

```js
await prepareNetworkUpdate();
```

In `downloadMihomoKernel`, change:

```js
async function downloadMihomoKernel(downloadUrl, version, arch, options) {
	if (!(options && options.skipNetworkPrepare)) {
		await prepareNetworkUpdate();
	}

	try {
```

To:

```js
async function downloadMihomoKernel(downloadUrl, version, arch) {
	try {
```

In `installKernelFromSettings`, remove:

```js
await prepareNetworkUpdate();
```

And change:

```js
const ok = await downloadMihomoKernel(asset.browser_download_url, release.version, arch, { skipNetworkPrepare: true });
```

To:

```js
const ok = await downloadMihomoKernel(asset.browser_download_url, release.version, arch);
```

In `fetchSubscriptionAsYaml`, remove:

```js
await prepareNetworkUpdate();
```

- [ ] **Step 5: Inline `isInternetOnlyEnabled` and remove stale helper functions**

Replace:

```js
function isInternetOnlyEnabled() {
	return view_miclash_guard.isInternetOnlyEnabled(appState.settings);
}

async function prepareNetworkUpdate() {
	const serviceRunning = await getServiceStatus();
	appState.serviceRunning = !!serviceRunning;
	updateHeaderAndControlDom();

	const result = await view_miclash_guard.prepareNetworkUpdate(appState.settings, appState.serviceRunning);
	if (result && result.warning) {
		notify('warning', _('Network path repair failed, continuing update: %s').format(result.warning));
	}
	return result;
}

function isNetworkUpdateBlocked() {
	return view_miclash_guard.isNetworkUpdateBlocked(appState.settings, appState.serviceRunning);
}

function shouldSkipSubscriptionDownload() {
	return view_miclash_guard.shouldSkipSubscriptionDownload(appState.settings, appState.serviceRunning);
}
```

With:

```js
function isInternetOnlyEnabled() {
	return !!(appState.settings && appState.settings.internetOnlyMiclash);
}
```

- [ ] **Step 6: Remove subscription skip branch**

Delete this block from the save-and-update subscription click handler:

```js
if (shouldSkipSubscriptionDownload()) {
	notify('warning', view_miclash_guard.skippedSubscriptionMessage());
	return;
}
```

Keep the surrounding service status refresh:

```js
appState.serviceRunning = await getServiceStatus();
updateHeaderAndControlDom();

await ensureMihomoKernelInstalled();
await logUiAction('info', 'Subscription update started for ' + getConfigLabel(selectedConfig));
```

- [ ] **Step 7: Run UI static check**

```powershell
if (rg -q 'view_miclash_guard|prepareNetworkUpdate|shouldSkipSubscriptionDownload|skippedSubscriptionMessage|Network path repair failed|Download skipped' luci-app-miclash\rootfs\www\luci-static\resources\view\miclash) {
    Write-Error 'Old UI guard repair/skip flow is still present.'
    exit 1
}
```

Expected: no output, exit code `0`.

- [ ] **Step 8: Commit UI flow cleanup**

```powershell
git add -- luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/config.js luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/guard.js
git commit -m "fix: remove guard repair from update flow"
```

Expected: commit succeeds and includes the `config.js` modification plus `guard.js` deletion.

### Task 3: Clarify User-Facing Guard Text

**Files:**
- Modify: `luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/config.js`
- Modify: `luci-app-miclash/rootfs/po/ru/miclash.po`
- Modify: `luci-app-miclash/rootfs/etc/init.d/clash`
- Modify: `luci-app-miclash/rootfs/opt/clash/bin/clash-rules`

- [ ] **Step 1: Run the current failing text check**

```powershell
if (rg -q 'Network access is blocked by "Internet only through MiClash"|Subscription URL saved\. Download skipped|Network path repair failed|Internet only through MiClash' luci-app-miclash\rootfs\www\luci-static\resources\view\miclash luci-app-miclash\rootfs\po\ru\miclash.po luci-app-miclash\rootfs\etc\init.d\clash luci-app-miclash\rootfs\opt\clash\bin\clash-rules) {
    Write-Error 'Old guard text is still present.'
    exit 1
}
```

Expected: command fails now with `Old guard text is still present.`

- [ ] **Step 2: Change the settings checkbox and header tooltip text**

In `config.js`, replace each user-facing use of:

```js
_('Internet only through MiClash')
```

With:

```js
_('Client devices only through MiClash')
```

This affects the settings checkbox label and the guard pill title.

- [ ] **Step 3: Update Russian translations**

In `luci-app-miclash/rootfs/po/ru/miclash.po`, replace:

```po
msgid "Internet only through MiClash"
msgstr "Интернет только через MiClash"
```

With:

```po
msgid "Client devices only through MiClash"
msgstr "Устройства только через MiClash"
```

Delete these obsolete entries:

```po
msgid "Network access is blocked by \"Internet only through MiClash\". Start the service or disable this option in Settings to update."
msgstr "Сетевой доступ заблокирован опцией \"Интернет только через MiClash\". Запустите службу или отключите эту опцию в настройках, чтобы обновить."

msgid "Network path repair failed."
msgstr "Не удалось восстановить сетевой путь."

msgid "Network path repair failed, continuing update: %s"
msgstr "Не удалось восстановить сетевой путь, продолжаю обновление: %s"

msgid "Subscription URL saved. Download skipped because \"Internet only through MiClash\" is enabled while the service is stopped."
msgstr "URL подписки сохранён. Загрузка пропущена: включена защита \"Интернет только через MiClash\", а служба остановлена."
```

- [ ] **Step 4: Update comments that still imply router-wide guard scope**

In `luci-app-miclash/rootfs/etc/init.d/clash`, change:

```sh
# Keep the guard active only when "Internet only through MiClash" is enabled.
```

To:

```sh
# Keep the client forwarding guard active only when enabled.
```

In `luci-app-miclash/rootfs/opt/clash/bin/clash-rules`, change:

```sh
[ -n "$INTERNET_ONLY_MICLASH" ] && settings_part="$settings_part, Internet only through MiClash: $INTERNET_ONLY_MICLASH"
```

To:

```sh
[ -n "$INTERNET_ONLY_MICLASH" ] && settings_part="$settings_part, Client guard: $INTERNET_ONLY_MICLASH"
```

- [ ] **Step 5: Run text static check**

```powershell
if (rg -q 'Network access is blocked by "Internet only through MiClash"|Subscription URL saved\. Download skipped|Network path repair failed|Internet only through MiClash' luci-app-miclash\rootfs\www\luci-static\resources\view\miclash luci-app-miclash\rootfs\po\ru\miclash.po luci-app-miclash\rootfs\etc\init.d\clash luci-app-miclash\rootfs\opt\clash\bin\clash-rules) {
    Write-Error 'Old guard text is still present.'
    exit 1
}
```

Expected: no output, exit code `0`.

- [ ] **Step 6: Commit text cleanup**

```powershell
git add -- luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/config.js luci-app-miclash/rootfs/po/ru/miclash.po luci-app-miclash/rootfs/etc/init.d/clash luci-app-miclash/rootfs/opt/clash/bin/clash-rules
git commit -m "chore: clarify client guard wording"
```

Expected: commit succeeds and includes only files changed in this task.

### Task 4: Final Verification

**Files:**
- Verify: `luci-app-miclash/rootfs/opt/clash/bin/clash-rules`
- Verify: `luci-app-miclash/rootfs/etc/init.d/clash`
- Verify: `luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/config.js`
- Verify: `luci-app-miclash/rootfs/po/ru/miclash.po`

- [ ] **Step 1: Run shell syntax checks**

```powershell
sh -n luci-app-miclash/rootfs/opt/clash/bin/clash-rules
sh -n luci-app-miclash/rootfs/etc/init.d/clash
```

Expected: no output, exit code `0` for both commands.

- [ ] **Step 2: Run complete stale-reference scan**

```powershell
rg -n 'repair_network_path|MICLASH_GUARD_OUTPUT|shouldSkipSubscriptionDownload|skippedSubscriptionMessage|Network path repair failed|Subscription URL saved\. Download skipped|Network access is blocked by "Internet only through MiClash"' luci-app-miclash --glob '!rootfs/opt/clash/ui/assets/**'
```

Expected: no matches.

- [ ] **Step 3: Verify guard still has FORWARD drops**

```powershell
rg -n 'forward oifname "\$iface" drop|FORWARD -j "\$GUARD_FORWARD_CHAIN"|\$cmd -t filter -A "\$GUARD_FORWARD_CHAIN" -o "\$iface" -j DROP' luci-app-miclash\rootfs\opt\clash\bin\clash-rules
```

Expected: matches for nftables and iptables FORWARD guard paths.

- [ ] **Step 4: Verify guard entry points still exist**

```powershell
rg -n 'guard_start\)|guard_stop\)|guard_refresh\)' luci-app-miclash\rootfs\opt\clash\bin\clash-rules
```

Expected: one match each for `guard_start)`, `guard_stop)`, and `guard_refresh)`.

- [ ] **Step 5: Verify guard no longer hooks OUTPUT**

```powershell
rg -n 'miclash_guard.*output|"\$GUARD_NFT_TABLE" output|GUARD_OUTPUT|MICLASH_GUARD_OUTPUT|"\$GUARD_OUTPUT_CHAIN"' luci-app-miclash\rootfs\opt\clash\bin\clash-rules
```

Expected: no matches.

- [ ] **Step 6: Review final diff**

```powershell
git diff --stat HEAD~3..HEAD
git diff --check HEAD~3..HEAD
git log --oneline -3
```

Expected:

```text
git diff --check exits 0
three implementation commits are present
no whitespace errors are reported
```

- [ ] **Step 7: Report result**

Summarize:

- Guard is FORWARD-only.
- Router-originated update/download flow no longer calls repair or skip logic.
- Old repair/skip strings are removed.
- Shell syntax and stale-reference checks passed.
