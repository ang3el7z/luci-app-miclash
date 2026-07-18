<p align="right">
Read in: <strong>English</strong> | <a href="README.ru.md">Русский</a> | <a href="README.zh-cn.md">中文</a>
</p>

<img width="881" height="889" alt="MiClash screenshot" src="https://github.com/user-attachments/assets/c53492ae-5318-4f34-802e-393306c109f3" />

# MiClash

MiClash is a LuCI application for managing Mihomo on OpenWrt. It combines configuration, subscriptions, routing, Guard protection, diagnostics, updates, notifications and recovery in one interface.

Supported platform: **OpenWrt 24.10+ with firewall4**.

- OpenWrt 25.12 stable uses APK.
- OpenWrt 24.10 old-stable uses opkg.

## Architecture and safety

`miclashd` is the only MiClash management backend. LuCI and Telegram call the same typed `ubus` API; the browser does not run shell commands, package managers or arbitrary file operations. Settings are stored in `UCI` at `/etc/config/miclash`, while profiles, rulesets and the Mihomo core live under `/opt/clash`.

When Guard is enabled, MiClash is fail-closed. An early-boot Guard safety latch protects selected traffic before `miclashd` or Mihomo is ready. A daemon crash, missing core, failed upgrade or unsuccessful repair must not silently expose protected traffic directly. Only an explicit Guard disable transition may clear the latch. Device policies never override this invariant.

## Terminal installation

The maintained installer detects `apk` or `opkg`, checks the newest 20 stable releases and installs the newest one whose manifest, package and published checksums are complete. If CI is still building the newest tag, terminal installation reports the fallback and uses the previous ready stable release.

### One-time v0.9.x → v2.x transition

`install-miclash.sh` is for clean installs and ordinary same-major updates. An installed v0.9.x system must run the standalone clean-upgrade script once. It copies profiles, the installed Mihomo core, rules/providers and legacy settings to `/root/miclash-v09-backup-*`, removes v0.9 completely, installs the selected v2 release and restores those user files. There is no automatic rollback or journal. The previous Guard and service state is restored after installation; the backup is kept for manual recovery if installation fails. Guard is not active during the short clean-replacement interval, so run the command from the local network when direct traffic exposure is a concern.

The script itself selects the newest complete stable v2 release from the newest 20 releases and verifies its installer, checksum and publication manifest before removing v0.9.x:

```sh
wget --no-proxy -qO- https://raw.githubusercontent.com/ang3el7z/luci-app-miclash/main/install-miclash-upgrade-0-9-x-to-2.x.x.sh | ash
```

With `wget` (also works when the installed `curl` is broken):

```sh
wget --no-proxy -qO- https://raw.githubusercontent.com/ang3el7z/luci-app-miclash/main/install-miclash.sh | ash
```

Equivalent `curl` form:

```sh
curl -fsSL https://raw.githubusercontent.com/ang3el7z/luci-app-miclash/main/install-miclash.sh | ash
```

The installer verifies that `curl` can start, repairs mismatched `zlib`/`libcurl4`, derives the exact manager-specific filename from the validated tag and verifies its `.sha256` before package installation. On an existing installation it offers update, reinstall, removal or skip.

The updater inside the installed plugin deliberately does **not** fall back to an older version: it keeps the newest tag authoritative, hides the update action while its artifacts are incomplete and retries after CI publication.

## First setup

Open **LuCI → Services → MiClash**.

1. Install the Mihomo core in **Settings → Kernel**. MiClash detects the architecture, downloads and verifies the selected release, stages the replacement, then keeps or restores the previous core if activation fails.
2. Add a subscription or edit a YAML profile.
3. Validate the Draft. Validation never changes live routing.
4. Apply it to make that revision Active.
5. Select TPROXY, TUN or MIXED mode and the included/excluded interfaces.
6. Enable Guard only after reviewing which devices/interfaces it protects.

An invalid profile remains Draft and is not applied. The previous Active configuration continues running, so repeated editing does not lose the user’s work.

## Main functions

- **Draft / Active configuration:** separate saved Draft and running Active revisions, validation, atomic activation and failure rollback.
- **Configuration history:** revision metadata and escaped diff, open an older revision as Draft, or perform an explicit history restore. A recovery snapshot is created before rollback.
- **Subscriptions and updates:** three profile URLs, manual and scheduled subscription update, MiClash update, verified Mihomo update and Mihomo rollback.
- **Routing:** TPROXY, TUN and MIXED modes, interface inclusion/exclusion, automatic LAN/WAN discovery, QUIC blocking and local rulesets.
- **Diagnostics:** component health for Mihomo, DNS, firewall, routing and Guard; a redacted diagnostic report; and an ordered route test for a domain/IP with optional device/interface.
- **Self-heal and memory recovery:** drift reconciliation and staged Mihomo recovery (`reload → internal core restart → service restart`) with health checks and a long failure cooldown.
- **Notifications:** in-app events for failures, Internet recovery, updates, Guard and memory actions; optional Telegram delivery.
- **Backup / restore:** bounded export/import, optional secrets warning, mandatory inspection preview and a recovery snapshot before restore.
- **Device policies:** discovered clients and schedules with inherit, proxy, direct or block actions. Guard remains authoritative.

## Telegram control

In **Settings → Telegram**, enable the integration and enter the token issued by **BotFather** plus your numeric Telegram user ID. The token is stored as a secret and is never returned to LuCI. Saving later with an empty token keeps the existing value.

Security model:

- outbound HTTPS long polling only; no inbound router port;
- exactly one configured user ID;
- private chats only, with sender ID and chat ID both matching;
- no confirmation or one-time token;
- duplicate updates, edited/channel/group messages and unknown commands are rejected;
- bounded logs/diagnostics, redacted audit data, rate limiting and retry backoff.

Approved commands:

```text
/status
/health
/memory
/diagnostics
/logs
/help
/start
/stop
/restart
/reload
/reboot
/subscription URL
/update_subscription
/update_miclash
/update_mihomo
/guard_on
/guard_off
/backup
```

`/reboot` reboots the router immediately after authorization; there is intentionally no confirmation prompt.

## UCI settings

The LuCI page is the recommended editor. For inspection:

```sh
uci show miclash
ubus call miclash status '{}'
ubus call miclash health '{}'
```

The main UCI sections are `core`, `interfaces`, `guard`, `memory`, `updates`, `telegram`, `notifications`, `backup` and `meta`. Keep `/etc/config/miclash` readable only by root because it may contain subscription URLs and the Telegram token.

## Safe update and recovery

- Config activation validates first and rolls back partial DNS/firewall/routing changes on failure.
- Mihomo update uses a staged artifact and preserves a rollback candidate.
- Auto-update and manual update are serialized with other mutations.
- Health reconciliation repairs owned DNS, firewall and routing drift; it does not adopt unrelated rules.
- Memory Guard acts only on abnormal Mihomo growth plus system memory pressure, checks whether memory actually fell after each stage, then enters cooldown instead of restarting forever.
- Internet-restored and repair events appear as notifications and can be sent to Telegram.

Before a major change, create a backup without secrets for routine support, or explicitly enable secrets only for a protected local archive.

## Troubleshooting

```sh
/etc/init.d/miclashd status
/etc/init.d/clash status
ubus call miclash status '{}'
ubus call miclash health '{}'
logread -e miclashd
```

Use **Download diagnostic report** for support and **route test** to explain the chosen path. If an operation fails, review its stage/error in LuCI and retry only after the previous operation is terminal.

When Guard is enabled, do not manually delete its nftables/routing rules or the Guard latch. Restore normal service through LuCI, reinstall the package, or explicitly disable Guard if direct traffic is acceptable.

## Safe removal

```sh
# OpenWrt 25.12:
apk del luci-app-miclash

# OpenWrt 24.10+:
opkg remove luci-app-miclash
```

The package removal protocol first protects Guard traffic, stops services, restores owned DNS/firewall/routing state and only then removes the backend. A failed cleanup remains retryable instead of leaving a false success.

The interactive installer can additionally purge `/opt/clash`. Non-interactive removal keeps the runtime/config directory. To erase it manually after successful package removal:

```sh
rm -rf /opt/clash
```

This final purge is irreversible; export a backup first.
