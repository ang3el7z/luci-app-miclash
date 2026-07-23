<p align="right">
Read in: <strong>English</strong> | <a href="README.ru.md">Русский</a> | <a href="README.zh-cn.md">中文</a>
</p>

<img width="881" height="889" alt="MiClash screenshot" src="https://github.com/user-attachments/assets/c53492ae-5318-4f34-802e-393306c109f3" />

# MiClash

MiClash is a LuCI application for managing Mihomo: subscriptions, routing, Guard, diagnostics, updates, notifications and recovery in one interface.

**Requirements:** OpenWrt 24.10+ with firewall4. OpenWrt 25.12+ uses APK; OpenWrt 24.10 uses opkg.

## Installation

The installer detects the package manager, checks the newest 20 stable releases, and selects the first one with complete artifacts and checksums. If a new tag is still building, it installs the previous ready release. It verifies `.sha256`, repairs mismatched `zlib`/`libcurl4` when necessary, and offers update, reinstall, removal or exit for an existing MiClash installation. The LuCI updater does **not** fall back: it waits for the newest version's artifacts and checks again later.

With `wget`:

```sh
wget --no-proxy -qO- https://raw.githubusercontent.com/ang3el7z/luci-app-miclash/main/install-miclash.sh | ash
```

<details>
<summary><strong>🔵 GitHub download unavailable? Show alternative commands</strong></summary>

Via `gh-proxy.com`:

```sh
wget --no-proxy -qO- https://gh-proxy.com/https://raw.githubusercontent.com/ang3el7z/luci-app-miclash/main/install-miclash.sh | ash
```

Via jsDelivr:

```sh
wget --no-proxy -qO- https://cdn.jsdelivr.net/gh/ang3el7z/luci-app-miclash@main/install-miclash.sh | ash
```

These are third-party download paths. jsDelivr may briefly serve a cached copy of `main` after an update.

</details>

<details>
<summary><strong>🟡 Use curl instead</strong></summary>

```sh
curl -fsSL https://raw.githubusercontent.com/ang3el7z/luci-app-miclash/main/install-miclash.sh | ash
```

<blockquote>
<details>
<summary><strong>🔵 GitHub download unavailable? Show alternative commands</strong></summary>

Via `gh-proxy.com`:

```sh
curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/ang3el7z/luci-app-miclash/main/install-miclash.sh | ash
```

Via jsDelivr:

```sh
curl -fsSL https://cdn.jsdelivr.net/gh/ang3el7z/luci-app-miclash@main/install-miclash.sh | ash
```

These are third-party download paths. jsDelivr may briefly serve a cached copy of `main` after an update.

</details>
</blockquote>

</details>

<details>
<summary><strong>🔴 Upgrading from v0.9.x to v2.x</strong></summary>

Run the separate transition script once on an installed v0.9.x system:

```sh
wget --no-proxy -qO- https://raw.githubusercontent.com/ang3el7z/luci-app-miclash/main/install-miclash-upgrade-0-9-x-to-2.x.x.sh | ash
```

<blockquote>
<details>
<summary><strong>🔵 GitHub download unavailable? Show alternative commands</strong></summary>

Via `gh-proxy.com`:

```sh
wget --no-proxy -qO- https://gh-proxy.com/https://raw.githubusercontent.com/ang3el7z/luci-app-miclash/main/install-miclash-upgrade-0-9-x-to-2.x.x.sh | ash
```

Via jsDelivr:

```sh
wget --no-proxy -qO- https://cdn.jsdelivr.net/gh/ang3el7z/luci-app-miclash@main/install-miclash-upgrade-0-9-x-to-2.x.x.sh | ash
```

These are third-party download paths. jsDelivr may briefly serve a cached copy of `main` after an update.

</details>
</blockquote>

<blockquote>
<details>
<summary><strong>🟡 Use curl instead</strong></summary>

```sh
curl -fsSL https://raw.githubusercontent.com/ang3el7z/luci-app-miclash/main/install-miclash-upgrade-0-9-x-to-2.x.x.sh | ash
```

<blockquote>
<details>
<summary><strong>🔵 GitHub download unavailable? Show alternative commands</strong></summary>

Via `gh-proxy.com`:

```sh
curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/ang3el7z/luci-app-miclash/main/install-miclash-upgrade-0-9-x-to-2.x.x.sh | ash
```

Via jsDelivr:

```sh
curl -fsSL https://cdn.jsdelivr.net/gh/ang3el7z/luci-app-miclash@main/install-miclash-upgrade-0-9-x-to-2.x.x.sh | ash
```

These are third-party download paths. jsDelivr may briefly serve a cached copy of `main` after an update.

</details>
</blockquote>

</details>
</blockquote>

The script verifies a ready stable v2 release, temporarily saves config profiles, subscription URLs and compatible UI settings to `/root/miclash-v09-backup-*`, then installs v2 and a fresh Mihomo core. Provider/runtime caches are rebuilt by v2 and are not migrated. There is no automatic rollback or journal; the temporary backup remains available only if installation fails.

Guard is inactive during the short replacement interval. Run the transition from the local network if protected traffic must never leave directly.

</details>

## Quick start

Open **LuCI → Services → MiClash**.

1. Mihomo is installed automatically by the terminal installer.
2. Add a subscription or edit a YAML profile.
3. Validate the YAML without changing live routing.
4. Apply it to make the configuration active.
5. Select TPROXY, TUN or MIXED and the required interfaces.
6. Review protected devices, then enable Guard.

An invalid configuration is not applied, and the previous active configuration keeps running.

## Main features

- **Configuration:** direct YAML editing, validation and atomic apply.
- **Subscriptions and updates:** three URLs, manual and scheduled refresh, safe MiClash and Mihomo updates.
- **Routing:** TPROXY, TUN, MIXED, interface inclusion/exclusion, automatic LAN/WAN, QUIC and local rulesets.
- **Diagnostics:** Mihomo, DNS, firewall, routing and Guard health, a redacted report and route test.
- **Self-healing:** drift repair and staged `reload → core restart → service restart` recovery.
- **Notifications:** failures, Internet recovery, updates, Guard and Memory Guard in LuCI or Telegram.
- **Device policies:** schedules and inherit/proxy/direct/block actions; Guard always takes priority.

## Guard and recovery

`miclashd` is the single MiClash backend; LuCI and Telegram use its typed `ubus` API. Settings live in `/etc/config/miclash`, while profiles, rulesets and the core live under `/opt/clash`.

- Guard is fail-closed and protects selected traffic before Mihomo is ready.
- Service, core, update or repair failures do not disable protection; only an explicit Guard disable may clear the latch.
- Configuration is validated first, and partial DNS/firewall/routing changes are rolled back.
- Mihomo updates use staging and can restore the previous core.
- Memory Guard acts only on abnormal Mihomo growth plus memory pressure, verifies every recovery stage and enters a long cooldown after total failure.

Keep `/etc/config/miclash` readable only by root because it may contain subscription URLs and the Telegram token.

## Telegram control

Enable Telegram under **Settings → Telegram**, then enter the token from **BotFather** and your numeric user ID. The token is stored as a secret and never returned to LuCI; an empty field keeps the saved token.

The bot uses outbound HTTPS long polling only, accepts authorized private chats, verifies sender/chat IDs, and rejects groups, channels, edits and duplicates. `/start` and `/menu` open a localized single-message control panel; only `/menu` is advertised, and all actions use its buttons. Dangerous actions ask for confirmation. Operation results and automatic notifications are queued durably until Telegram confirms delivery. Logs are downloaded as the same bounded raw snapshot shown in LuCI. Diagnostics are available as privacy-preserving Silent, Lite, or Full reports.

```text
/start /menu
```

## Diagnostics

For normal troubleshooting, open **MiClash → Settings → Components → Diagnostics**:

- **Silent** contains only minimal system health information and is suitable for public issue reports.
- **Lite** contains redacted diagnostics, a configuration summary, and recent events. Use it for most support requests.
- **Full** may contain private configuration and secrets. Share it only with trusted support.

If LuCI is unavailable, use these commands over SSH:

```sh
/etc/init.d/miclashd status
/etc/init.d/clash status
ubus call miclash status '{}'
ubus call miclash health '{}'
logread | grep -E '(miclash|mihomo|clash)'
```

Use **Route test** in the Routing card to inspect the selected path. When Guard is enabled, do not manually delete its nftables/routing rules or safety latch.

## Removal

```sh
# OpenWrt 25.12+:
apk del luci-app-miclash

# OpenWrt 24.10:
opkg remove luci-app-miclash
```

Removal stops the services and restores MiClash-owned DNS/firewall/routing settings first. `/opt/clash` is preserved; after copying any files you need, it can be deleted irreversibly:

```sh
rm -rf /opt/clash
```
