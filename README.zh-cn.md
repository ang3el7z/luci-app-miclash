<p align="right">
阅读语言：<a href="README.md">English</a> | <a href="README.ru.md">Русский</a> | <strong>中文</strong>
</p>

<img width="881" height="889" alt="MiClash 截图" src="https://github.com/user-attachments/assets/c53492ae-5318-4f34-802e-393306c109f3" />

# MiClash

MiClash 是用于管理 Mihomo 的 LuCI 应用，在同一界面中提供订阅、路由、Guard、诊断、更新、通知和恢复功能。

**要求：** 使用 firewall4 的 OpenWrt 24.10+。OpenWrt 25.12+ 使用 APK，OpenWrt 24.10 使用 opkg。

## 安装

安装器会检测软件包管理器，检查最新 20 个稳定版本，并选择第一个文件和校验和均已完整发布的版本。如果新 tag 仍在构建，则安装上一个已就绪版本。安装器会验证 `.sha256`，在需要时修复不匹配的 `zlib`/`libcurl4`；如果已安装 MiClash，还可选择更新、重新安装、删除或退出。LuCI 内的更新**不会回退**：它会等待最新版本的文件发布，然后再次检查。

使用 `wget`：

```sh
wget --no-proxy -qO- https://raw.githubusercontent.com/ang3el7z/luci-app-miclash/main/install-miclash.sh | ash
```

<details>
<summary><strong>改用 curl</strong></summary>

```sh
curl -fsSL https://raw.githubusercontent.com/ang3el7z/luci-app-miclash/main/install-miclash.sh | ash
```

</details>

<details>
<summary><strong>🔵 无法从 GitHub 下载？显示备用命令</strong></summary>

通过 `gh-proxy.com`：

```sh
wget --no-proxy -qO- https://gh-proxy.com/https://raw.githubusercontent.com/ang3el7z/luci-app-miclash/main/install-miclash.sh | ash
curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/ang3el7z/luci-app-miclash/main/install-miclash.sh | ash
```

通过 jsDelivr：

```sh
wget --no-proxy -qO- https://cdn.jsdelivr.net/gh/ang3el7z/luci-app-miclash@main/install-miclash.sh | ash
curl -fsSL https://cdn.jsdelivr.net/gh/ang3el7z/luci-app-miclash@main/install-miclash.sh | ash
```

这些是第三方下载方式。更新后，jsDelivr 可能会在短时间内提供缓存的 `main` 版本。

</details>

<details>
<summary><strong>从 v0.9.x 升级到 v2.x</strong></summary>

已安装 v0.9.x 的设备应只运行一次独立的过渡脚本：

```sh
wget --no-proxy -qO- https://raw.githubusercontent.com/ang3el7z/luci-app-miclash/main/install-miclash-upgrade-0-9-x-to-2.x.x.sh | ash
```

<details>
<summary><strong>改用 curl</strong></summary>

```sh
curl -fsSL https://raw.githubusercontent.com/ang3el7z/luci-app-miclash/main/install-miclash-upgrade-0-9-x-to-2.x.x.sh | ash
```

</details>

<details>
<summary><strong>🔵 无法从 GitHub 下载？显示备用命令</strong></summary>

通过 `gh-proxy.com`：

```sh
wget --no-proxy -qO- https://gh-proxy.com/https://raw.githubusercontent.com/ang3el7z/luci-app-miclash/main/install-miclash-upgrade-0-9-x-to-2.x.x.sh | ash
curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/ang3el7z/luci-app-miclash/main/install-miclash-upgrade-0-9-x-to-2.x.x.sh | ash
```

通过 jsDelivr：

```sh
wget --no-proxy -qO- https://cdn.jsdelivr.net/gh/ang3el7z/luci-app-miclash@main/install-miclash-upgrade-0-9-x-to-2.x.x.sh | ash
curl -fsSL https://cdn.jsdelivr.net/gh/ang3el7z/luci-app-miclash@main/install-miclash-upgrade-0-9-x-to-2.x.x.sh | ash
```

这些是第三方下载方式。更新后，jsDelivr 可能会在短时间内提供缓存的 `main` 版本。

</details>

脚本会验证已就绪的稳定 v2 版本，将配置文件、Mihomo 内核、rules/providers 和设置保存到 `/root/miclash-v09-backup-*`，删除 v0.9，安装 v2 并恢复数据。脚本不提供自动 rollback 或 journal；安装失败时 backup 会保留，供手动恢复。

在短暂的替换期间 Guard 不工作。如果受保护流量绝不能直连，请从本地网络执行升级。

</details>

## 快速开始

打开 **LuCI → 服务 → MiClash**。

1. 终端安装脚本会自动安装 Mihomo。
2. 添加订阅或编辑 YAML 配置。
3. 验证 Draft；此操作不会更改当前路由。
4. 应用 Draft，使其成为 Active。
5. 选择 TPROXY、TUN 或 MIXED，并设置所需接口。
6. 检查受保护设备，然后启用 Guard。

无效 Draft 不会被应用，之前的 Active 配置会继续运行。

## 主要功能

- **配置：** Draft/Active、验证、原子应用、历史（history）、diff、restore 和 recovery snapshot。
- **订阅与更新：** 三个 URL、手动或定时刷新，以及安全的 MiClash 和 Mihomo 更新。
- **路由：** TPROXY、TUN、MIXED、接口包含/排除、自动 LAN/WAN、QUIC 和本地 rulesets。
- **诊断：** Mihomo、DNS、firewall、routing 和 Guard 状态、脱敏报告以及 route test。
- **自恢复：** 修复 drift，并按 `reload → 内核 restart → 服务 restart` 逐级恢复。
- **通知（notification）：** 在 LuCI 或 Telegram 中显示故障、Internet 恢复、更新、Guard 和 Memory Guard 事件。
- **Backup/restore：** 导入 preview、secrets 警告和 recovery snapshot。
- **设备策略（device policies）：** 计划任务以及 inherit/proxy/direct/block；Guard 始终优先。

## Guard 与恢复

`miclashd` 是 MiClash 唯一的 backend；LuCI 和 Telegram 使用其类型化 `ubus` API。UCI 设置位于 `/etc/config/miclash`，配置文件、rulesets 和内核位于 `/opt/clash`。

- Guard 采用 fail-closed，在 Mihomo 就绪前保护所选流量。
- 服务、内核、更新或修复失败不会关闭保护；只有明确关闭 Guard 才能解除 latch。
- 配置会先验证，失败时 rollback 部分 DNS/firewall/routing 修改。
- Mihomo 更新使用 staging，并可恢复上一个内核。
- Memory Guard 只在 Mihomo 异常增长且存在内存压力时动作，检查每个恢复阶段，并在全部失败后进入长 cooldown。

`/etc/config/miclash` 可能包含订阅 URL 和 Telegram token，应只允许 root 读取。

## Telegram 控制

在 **设置 → Telegram** 中启用集成，填写 **BotFather** 提供的 token 和你的数字 user ID。Token 按 secret 保存且不会返回 LuCI；留空会保留已有 token。

Bot 仅使用出站 HTTPS long polling，只接受一个 user ID 的 private chat，校验 sender/chat ID，并拒绝 group、channel、edited message 和重复消息。Logs/diagnostics 有大小限制并脱敏，同时受 rate limit 和 backoff 保护。

```text
/status /health /memory /diagnostics /logs /help
/start /stop /restart /reload /reboot
/subscription URL /update_subscription /update_miclash /update_mihomo
/guard_on /guard_off /backup
```

`/reboot` 在用户验证后立即重启路由器，不再二次确认。

## 诊断

```sh
/etc/init.d/miclashd status
/etc/init.d/clash status
ubus call miclash status '{}'
ubus call miclash health '{}'
logread -e miclashd
```

请求支持时请下载诊断报告，并使用 route test 检查所选路径。Guard 启用时不要手动删除其 nftables/routing rules 或 latch。

## 删除（removal）

```sh
# OpenWrt 25.12+：
apk del luci-app-miclash

# OpenWrt 24.10：
opkg remove luci-app-miclash
```

删除时会先停止服务，并恢复 MiClash 管理的 DNS/firewall/routing 设置。`/opt/clash` 会保留；创建 backup 后可手动永久删除：

```sh
rm -rf /opt/clash
```
