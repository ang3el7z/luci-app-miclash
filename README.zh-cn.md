<p align="right">
阅读语言：<a href="README.md">English</a> | <a href="README.ru.md">Русский</a> | <strong>中文</strong>
</p>

<img width="881" height="889" alt="MiClash 截图" src="https://github.com/user-attachments/assets/c53492ae-5318-4f34-802e-393306c109f3" />

# MiClash

MiClash 是在 OpenWrt 上管理 Mihomo 的 LuCI 应用。配置、订阅、路由、Guard 防护、诊断、更新、通知和恢复都集中在同一界面中。

支持的平台：**带有 firewall4 的 OpenWrt 24.10+**。

- 稳定版 OpenWrt 25.12 使用 APK。
- old-stable OpenWrt 24.10 使用 opkg。

## 架构与安全

`miclashd` 是 MiClash 唯一的管理 backend。LuCI 与 Telegram 使用同一个类型化 `ubus` API；浏览器不会执行 shell、软件包管理器或任意文件操作。设置保存在 `UCI` 的 `/etc/config/miclash`，配置文件、rulesets 与 Mihomo 内核位于 `/opt/clash`。

启用 Guard 后系统采用 fail-closed。早期启动的 Guard safety latch 会在 `miclashd` 或 Mihomo 就绪前保护选定流量。daemon 崩溃、内核缺失、升级失败或修复失败时，受保护流量不能悄悄直连。只有明确关闭 Guard 才能解除 latch，device policy 也不能覆盖该约束。

## 终端安装

维护中的安装器会自动检测 `apk` 或 `opkg`，检查最新 20 个稳定 release，并选择 manifest、软件包及 checksum 均已发布的第一个版本。如果 CI 仍在构建最新 tag，终端安装会提示并选择上一个已就绪的稳定 release。

### 一次性 v0.9.x → v2.x 过渡

`install-miclash.sh` 用于全新安装和同一 major 版本内的常规更新。已安装 v0.9.x 的设备应只运行一次独立的 clean-upgrade 脚本。它会把 profiles、已安装的 Mihomo core、rules/providers 和旧 settings 保存到 `/root/miclash-v09-backup-*`，完整删除 v0.9，安装选定的 v2 release，再恢复用户文件。它不提供自动 rollback 或 journal。安装后会恢复原来的 Guard 和服务状态；如果安装失败，backup 会保留以便手动恢复。在短暂的 clean-replacement 期间 Guard 不工作；如果担心流量直连，请从本地网络运行该命令。

请从第一个已就绪的稳定 v2 release 下载独立安装器：如果 tag 缺少脚本或 checksum，命令会跳过它；只会校验同一 tag 的本地 asset 后再执行。不要把 clean-upgrade 脚本直接 pipe 到 `ash`：

```sh
(
umask 077
work="$(mktemp -d /tmp/miclash-v09-clean.XXXXXX)" || exit 1
trap 'rm -rf "$work"' EXIT INT TERM
asset='install-miclash-upgrade-0-9-x-to-2.x.x.sh'
checksum_name="$asset.sha256"
catalog="$work/releases.json"
wget --no-proxy -qO "$catalog" 'https://api.github.com/repos/ang3el7z/luci-app-miclash/releases?per_page=20' || exit 1
jsonfilter -i "$catalog" -e '@[*].tag_name' > "$work/tags" || exit 1
count=0
while IFS= read -r tag; do
  [ "$count" -lt 20 ] || break
  count=$((count + 1))
  printf '%s\n' "$tag" | grep -Eq '^v2\.[0-9]+\.[0-9]+$' || continue
  candidate="$work/$tag"
  mkdir "$candidate" || exit 1
  metadata="$candidate/release.json"
  wget --no-proxy -qO "$metadata" "https://api.github.com/repos/ang3el7z/luci-app-miclash/releases/tags/$tag" || { rm -rf "$candidate"; continue; }
  [ "$(jsonfilter -i "$metadata" -e '@.tag_name')" = "$tag" ] && \
    [ "$(jsonfilter -i "$metadata" -e '@.draft')" = false ] && \
    [ "$(jsonfilter -i "$metadata" -e '@.prerelease')" = false ] || { rm -rf "$candidate"; continue; }
  script="$candidate/$asset"
  checksum="$candidate/$checksum_name"
  wget --no-proxy -qO "$checksum" "https://github.com/ang3el7z/luci-app-miclash/releases/download/$tag/$checksum_name" || { rm -rf "$candidate"; continue; }
  wget --no-proxy -qO "$script" "https://github.com/ang3el7z/luci-app-miclash/releases/download/$tag/$asset" || { rm -rf "$candidate"; continue; }
  awk -v asset="$asset" '
    NF == 2 {
      name = $2
      sub(/^\*/, "", name)
      if (length($1) == 64 && $1 ~ /^[[:xdigit:]]+$/ && name == asset) matches++
    }
    END { exit !(NR == 1 && matches == 1) }
  ' "$checksum" || exit 1
  ( cd "$candidate" && sha256sum -c "$checksum" ) || exit 1
  ash "$script" --release-tag "$tag"
  exit $?
done < "$work/tags"
printf '%s\n' 'No ready stable v2 transition installer was published in the newest 20 releases.' >&2
exit 1
)
```

使用 `wget`（即使已安装的 `curl` 损坏也可工作）：

```sh
wget --no-proxy -qO- https://raw.githubusercontent.com/ang3el7z/luci-app-miclash/main/install-miclash.sh | ash
```

等效的 `curl` 命令：

```sh
curl -fsSL https://raw.githubusercontent.com/ang3el7z/luci-app-miclash/main/install-miclash.sh | ash
```

安装器会验证 `curl`、修复不匹配的 `zlib`/`libcurl4`，根据已验证 tag 为检测到的软件包管理器构造精确文件名，并在安装前校验 `.sha256`。已有 MiClash 时可选择 update、reinstall、removal 或 skip。

已安装插件内的 updater 刻意**不会回退**到旧版本：最新 tag 始终是权威目标，在 CI 完整发布 artifacts 前隐藏更新操作，之后再重试检查。

## 首次设置

打开 **LuCI → 服务 → MiClash**。

1. 在 **设置 → 内核** 安装 Mihomo。MiClash 会检测架构、下载并验证 release、暂存替换；激活失败时保留或 restore 上一个内核。
2. 添加订阅或编辑 YAML 配置。
3. 验证 Draft。验证不会更改当前路由。
4. 应用后该 revision 才成为 Active。
5. 选择 TPROXY、TUN 或 MIXED，并配置包含/排除的接口。
6. 检查受保护设备与接口后再启用 Guard。

无效配置会保留为 Draft，不会应用；之前的 Active 继续工作，因此多次编辑不会丢失用户内容。

## 主要功能

- **Draft / Active：** 独立保存草稿与运行版本，支持 validation、原子激活以及失败 rollback。
- **配置 history：** revision 元数据与安全 diff；可将旧 revision 打开为 Draft，或明确 restore；rollback 前创建 recovery snapshot。
- **订阅与 update：** 三个 profile URL，手动/定时订阅更新，MiClash update，经过验证的 Mihomo update 与内核 rollback。
- **路由：** TPROXY、TUN、MIXED、接口包含/排除、LAN/WAN 自动检测、QUIC 阻断和本地 rulesets。
- **诊断：** Mihomo、DNS、firewall、routing、Guard 状态；脱敏 diagnostic report；按 domain/IP、device/interface 解释路径的 route test。
- **自修复与 memory recovery：** 修复 drift，并按 `reload → 内核内部 restart → 服务 restart` 逐级恢复；每步都有 health 检查，失败后进入长 cooldown。
- **通知（notification）：** LuCI 中显示故障、Internet 恢复、update、Guard 和内存事件，也可发送到 Telegram。
- **Backup / restore：** 有大小边界的导出/导入、secrets 警告、强制 inspection preview，以及 restore 前的 recovery snapshot。
- **Device policies：** 已发现客户端、计划任务和 inherit/proxy/direct/block；Guard 始终优先。

## Telegram 控制

在 **设置 → Telegram** 中启用集成，填写 **BotFather** 提供的 token 和你自己的数字 Telegram user ID。Token 按 secret 保存，永远不会回传到 LuCI；后续保存时留空不会覆盖已有 token。

安全模型：

- 只进行出站 HTTPS long polling，不开放路由器入站端口；
- 只允许一个精确 user ID；
- 只接受 private chat，sender ID 与 chat ID 都必须匹配；
- 不需要确认或一次性 token；
- group、channel、edited message、重复 update 和未知命令会被拒绝；
- logs/diagnostics 有边界并脱敏，同时有 rate limit 与 backoff。

完整命令：

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

`/reboot` 通过授权后立即重启路由器；设计上没有确认提示。

## UCI 设置

推荐通过 LuCI 修改。检查状态可使用：

```sh
uci show miclash
ubus call miclash status '{}'
ubus call miclash health '{}'
```

主要 UCI section 为 `core`、`interfaces`、`guard`、`memory`、`updates`、`telegram`、`notifications`、`backup` 与 `meta`。`/etc/config/miclash` 可能包含订阅 URL 和 Telegram token，应只允许 root 读取。

## 安全 update 与 recovery

- 配置激活先 validation；失败时 rollback 部分 DNS/firewall/routing 修改。
- Mihomo update 使用 staging，并保留可 rollback 的候选。
- 自动与手动 update 会同其他 mutation 串行执行。
- Health reconcile 只修复 MiClash 拥有的 DNS/firewall/routing 对象，不接管无关规则。
- Memory Guard 只有在 Mihomo 异常增长且系统存在内存压力时才动作；每一步都验证 RSS 是否下降，全部失败后进入 cooldown。
- Internet 恢复与 repair 事件显示为 notification，并可发送到 Telegram。

重大修改前建议创建不含 secrets 的 backup；只有受保护的本地 archive 才应显式包含 secrets。

## 故障排查

```sh
/etc/init.d/miclashd status
/etc/init.d/clash status
ubus call miclash status '{}'
ubus call miclash health '{}'
logread -e miclashd
```

寻求支持时使用 **下载 diagnostic report**，使用 **route test** 查看路径原因。操作失败时先查看 stage/error，并等当前 operation 终止后再重试。

Guard 启用时不要手工删除 nftables/routing rule 或 latch。应通过 LuCI 恢复服务、重新安装软件包，或仅在允许直连时明确关闭 Guard。

## 安全删除（removal）

```sh
# OpenWrt 25.12：
apk del luci-app-miclash

# OpenWrt 24.10+：
opkg remove luci-app-miclash
```

删除协议会先保持 Guard 防护，停止服务，restore 由 MiClash 管理的 DNS/firewall/routing 状态，最后才移除 backend。清理失败会保持 retryable，不会报告虚假成功。

交互式安装器还能选择 purge `/opt/clash`。非交互 removal 会保留 runtime/config 目录。软件包成功删除后，可手动清除：

```sh
rm -rf /opt/clash
```

此 final purge 不可恢复；请先导出 backup。
