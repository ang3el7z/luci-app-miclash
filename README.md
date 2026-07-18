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
<summary><strong>Use curl instead</strong></summary>

```sh
curl -fsSL https://raw.githubusercontent.com/ang3el7z/luci-app-miclash/main/install-miclash.sh | ash
```

</details>

<details>
<summary><strong>🔵 GitHub download unavailable? Show alternative commands</strong></summary>

**wget**

Via `gh-proxy.com`:

```sh
wget --no-proxy -qO- https://gh-proxy.com/https://raw.githubusercontent.com/ang3el7z/luci-app-miclash/main/install-miclash.sh | ash
```

Via jsDelivr:

```sh
wget --no-proxy -qO- https://cdn.jsdelivr.net/gh/ang3el7z/luci-app-miclash@main/install-miclash.sh | ash
```

**curl**

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

<details>
<summary><strong>Upgrading from v0.9.x to v2.x</strong></summary>

Run the separate transition script once on an installed v0.9.x system:

```sh
wget --no-proxy -qO- https://raw.githubusercontent.com/ang3el7z/luci-app-miclash/main/install-miclash-upgrade-0-9-x-to-2.x.x.sh | ash
```

<details>
<summary><strong>Use curl instead</strong></summary>

```sh
curl -fsSL https://raw.githubusercontent.com/ang3el7z/luci-app-miclash/main/install-miclash-upgrade-0-9-x-to-2.x.x.sh | ash
```

</details>

<details>
<summary><strong>🔵 GitHub download unavailable? Show alternative commands</strong></summary>

**wget**

Via `gh-proxy.com`:

```sh
wget --no-proxy -qO- https://gh-proxy.com/https://raw.githubusercontent.com/ang3el7z/luci-app-miclash/main/install-miclash-upgrade-0-9-x-to-2.x.x.sh | ash
```

Via jsDelivr:

```sh
wget --no-proxy -qO- https://cdn.jsdelivr.net/gh/ang3el7z/luci-app-miclash@main/install-miclash-upgrade-0-9-x-to-2.x.x.sh | ash
```

**curl**

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

The script verifies a ready stable v2 release, saves profiles, the Mihomo core, rules/providers and settings to `/root/miclash-v09-backup-*`, removes v0.9, installs v2 and restores the data. There is no automatic rollback or journal; the backup remains available for manual recovery if installation fails.

Guard is inactive during the short replacement interval. Run the transition from the local network if protected traffic must never leave directly.

</details>

## Quick start

Open **LuCI → Services → MiClash**.

1. Mihomo is installed automatically by the terminal installer.
2. Add a subscription or edit a YAML profile.
3. Validate the Draft without changing live routing.
4. Apply the Draft to make it Active.
5. Select TPROXY, TUN or MIXED and the required interfaces.
6. Review protected devices, then enable Guard.

An invalid Draft is not applied, and the previous Active configuration keeps running.

## Main features

- **Configuration:** Draft/Active, validation, atomic apply, history, diff, restore and recovery snapshots.
- **Subscriptions and updates:** three URLs, manual and scheduled refresh, safe MiClash and Mihomo updates.
- **Routing:** TPROXY, TUN, MIXED, interface inclusion/exclusion, automatic LAN/WAN, QUIC and local rulesets.
- **Diagnostics:** Mihomo, DNS, firewall, routing and Guard health, a redacted report and route test.
- **Self-healing:** drift repair and staged `reload → core restart → service restart` recovery.
- **Notifications:** failures, Internet recovery, updates, Guard and Memory Guard in LuCI or Telegram.
- **Backup/restore:** import preview, secrets warning and a recovery snapshot.
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

The bot uses outbound HTTPS long polling only, accepts private chat from exactly one user ID, verifies sender/chat IDs, and rejects groups, channels, edits and duplicates. Logs and diagnostics are bounded, redacted and protected by rate limits and backoff.

```text
/status /health /memory /diagnostics /logs /help
/start /stop /restart /reload /reboot
/subscription URL /update_subscription /update_miclash /update_mihomo
/guard_on /guard_off /backup
```

`/reboot` reboots the router immediately after authorization, without another confirmation.

## Diagnostics

```sh
/etc/init.d/miclashd status
/etc/init.d/clash status
ubus call miclash status '{}'
ubus call miclash health '{}'
logread -e miclashd
```

Download the diagnostic report when requesting support, and use route test to inspect the selected path. When Guard is enabled, do not manually delete its nftables/routing rules or latch.

## Removal

```sh
# OpenWrt 25.12+:
apk del luci-app-miclash

# OpenWrt 24.10:
opkg remove luci-app-miclash
```

Removal stops the services and restores MiClash-owned DNS/firewall/routing settings first. `/opt/clash` is preserved; after creating a backup, it can be deleted irreversibly:

```sh
rm -rf /opt/clash
```
