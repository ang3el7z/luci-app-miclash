<p align="right">
阅读语言：<a href="README.md">English</a> | <a href="README.ru.md">Русский</a> | <strong>中文</strong>
</p>

<img width="881" height="889" alt="MiClash screenshot" src="https://github.com/user-attachments/assets/c53492ae-5318-4f34-802e-393306c109f3" />

# MiClash

用于在 OpenWrt 上管理 Mihomo/Clash 的 LuCI 应用。

## 自动安装

推荐方式（`wget`，即使已安装的 `curl` 损坏也可以使用）：

```sh
wget --no-proxy -qO- https://raw.githubusercontent.com/ang3el7z/luci-app-miclash/main/install-miclash.sh | ash
```

备用方式（`curl`）：

```sh
curl -fsSL https://raw.githubusercontent.com/ang3el7z/luci-app-miclash/main/install-miclash.sh | ash
```

自动安装脚本会检查 `curl` 是否真的可以启动。如果系统中已有的 `curl` 因为缺少或不匹配的 `zlib`/`libcurl4` 而无法运行，脚本会在获取 MiClash release 前自动修复这些软件包。

如果已经安装了 `luci-app-miclash`，交互式安装脚本会提供 `update / reinstall / delete / skip` 选项。
通过 `wget ... | ash` 或 `curl ... | ash` 且没有 TTY 运行时，脚本不会自动删除软件包；它会选择更安全的 `update` 或 `skip`。

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

## OpenWrt 23.05.x - 24.10.x

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

对于使用 `firewall3` 的旧版 OpenWrt，请安装 `iptables-mod-tproxy`，而不是 `kmod-nft-tproxy`。

## Mihomo

安装 MiClash 后，打开 LuCI -> Services -> MiClash -> Settings -> Kernel，并在界面中安装 Mihomo 内核。
MiClash 会检测路由器架构，下载匹配的压缩包，替换 `/opt/clash/bin/clash`，并在服务已运行时重启服务。

也可以手动安装：

```sh
mkdir -p /opt/clash/bin
release=$(curl -s -L https://github.com/MetaCubeX/mihomo/releases/latest | grep "title>Release" | cut -d " " -f 4)
curl -L "https://github.com/MetaCubeX/mihomo/releases/download/${release}/mihomo-linux-arm64-${release}.gz" -o /tmp/clash.gz
gunzip -c /tmp/clash.gz > /opt/clash/bin/clash
chmod 0755 /opt/clash/bin/clash
rm -f /tmp/clash.gz
```

其他架构请在 Mihomo releases 页面选择对应文件：<https://github.com/MetaCubeX/mihomo/releases>。

## 功能

- 原生 MiClash LuCI 页面，不需要单独的自定义主题开关。
- Clash 服务控制：start、stop、restart、reload。
- YAML 配置编辑器，应用前会进行验证。
- 将订阅下载到 `/opt/clash/config.yaml`。
- 本地 rulesets 存放在 `/opt/clash/lst`。
- 支持 TPROXY/TUN/MIXED、接口选择、QUIC 阻断、rules/providers 使用 tmpfs。
- 通过路由器端脚本更新 MiClash 和 Mihomo，避免 LuCI 在 UI 中长时间等待操作完成。

## 卸载

```sh
# OpenWrt 25.x:
apk del luci-app-miclash

# OpenWrt 23.05.x - 24.10.x:
opkg remove luci-app-miclash

rm -rf /opt/clash
```
