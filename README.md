<p align="right">
Read in: <strong>English</strong> | <a href="README.ru.md">Русский</a> | <a href="README.zh-cn.md">中文</a>
</p>

<img width="881" height="889" alt="MiClash screenshot" src="https://github.com/user-attachments/assets/c53492ae-5318-4f34-802e-393306c109f3" />

# MiClash

LuCI application for managing Mihomo/Clash on OpenWrt.

Supported platform: OpenWrt 24.10+ with firewall4.

## Auto Install

Recommended (`wget`, works even when the installed `curl` is broken):

```sh
wget --no-proxy -qO- https://raw.githubusercontent.com/ang3el7z/luci-app-miclash/main/install-miclash.sh | ash
```

Alternative (`curl`):

```sh
curl -fsSL https://raw.githubusercontent.com/ang3el7z/luci-app-miclash/main/install-miclash.sh | ash
```

The auto-installer checks that `curl` can actually start. If an existing OpenWrt `curl` binary is broken because `zlib` or `libcurl4` is missing or mismatched, it repairs those packages before fetching MiClash releases.

If `luci-app-miclash` is already installed, the interactive installer will offer `update / reinstall / delete / skip`.
When started through `wget ... | ash` or `curl ... | ash` without a TTY, deletion is not performed automatically: the script will choose the safe `update` or `skip` path.

## OpenWrt 25.x

```sh
apk update
apk add zlib libcurl4 curl kmod-nft-tproxy kmod-tun coreutils-base64
curl --version >/dev/null 2>&1 || apk fix zlib libcurl4 curl
curl --version >/dev/null 2>&1 || exit 1
release=$(curl -fsSL https://api.github.com/repos/ang3el7z/luci-app-miclash/releases/latest | grep '"tag_name"' | head -n1 | cut -d '"' -f4)
curl -L "https://github.com/ang3el7z/luci-app-miclash/releases/download/${release}/luci-app-miclash-${release#v}.apk" -o /tmp/luci-app-miclash.apk
apk add /tmp/luci-app-miclash.apk --allow-untrusted
rm -f /tmp/luci-app-miclash.apk
```

## OpenWrt 24.10+ (opkg)

```sh
opkg update
opkg install --force-reinstall zlib libcurl4 curl
opkg install kmod-nft-tproxy kmod-tun coreutils-base64
curl --version >/dev/null 2>&1 || exit 1
release=$(curl -fsSL https://api.github.com/repos/ang3el7z/luci-app-miclash/releases/latest | grep '"tag_name"' | head -n1 | cut -d '"' -f4)
curl -L "https://github.com/ang3el7z/luci-app-miclash/releases/download/${release}/luci-app-miclash_${release#v}_all.ipk" -o /tmp/luci-app-miclash.ipk
opkg install /tmp/luci-app-miclash.ipk
rm -f /tmp/luci-app-miclash.ipk
```

## Mihomo

After installing MiClash, open LuCI -> Services -> MiClash -> Settings -> Kernel and install the Mihomo core from the interface.
MiClash detects the router architecture, downloads the matching archive, replaces `/opt/clash/bin/clash`, and restarts the service if it was running.

Manual installation is also possible:

```sh
mkdir -p /opt/clash/bin
release=$(curl -s -L https://github.com/MetaCubeX/mihomo/releases/latest | grep "title>Release" | cut -d " " -f 4)
curl -L "https://github.com/MetaCubeX/mihomo/releases/download/${release}/mihomo-linux-arm64-${release}.gz" -o /tmp/clash.gz
gunzip -c /tmp/clash.gz > /opt/clash/bin/clash
chmod 0755 /opt/clash/bin/clash
rm -f /tmp/clash.gz
```

For other architectures, choose the matching file on the Mihomo releases page: <https://github.com/MetaCubeX/mihomo/releases>.

## Features

- Native MiClash LuCI page without a separate custom theme switcher.
- Clash service controls: start, stop, restart, reload.
- YAML config editor with validation before applying changes.
- Subscription download into `/opt/clash/config.yaml`.
- Local rulesets in `/opt/clash/lst`.
- TPROXY/TUN/MIXED modes, interface selection, QUIC blocking, tmpfs for rules/providers.
- MiClash and Mihomo updates through router-side scripts so LuCI does not keep long operations in the UI.

## Removal

```sh
# OpenWrt 25.x:
apk del luci-app-miclash

# OpenWrt 24.10+ (opkg):
opkg remove luci-app-miclash

rm -rf /opt/clash
```
