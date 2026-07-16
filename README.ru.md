<p align="right">
Читать на: <a href="README.md">English</a> | <strong>Русский</strong> | <a href="README.zh-cn.md">中文</a>
</p>

<img width="881" height="889" alt="MiClash screenshot" src="https://github.com/user-attachments/assets/c53492ae-5318-4f34-802e-393306c109f3" />

# MiClash

LuCI-приложение для управления Mihomo/Clash на OpenWrt.

Поддерживаемая платформа: OpenWrt 24.10+ с firewall4.

## Автоустановка

Рекомендуемый вариант (`wget`, работает даже если установленный `curl` сломан):

```sh
wget --no-proxy -qO- https://raw.githubusercontent.com/ang3el7z/luci-app-miclash/main/install-miclash.sh | ash
```

Альтернативный вариант (`curl`):

```sh
curl -fsSL https://raw.githubusercontent.com/ang3el7z/luci-app-miclash/main/install-miclash.sh | ash
```

Автоустановщик проверяет, что `curl` действительно запускается. Если бинарь `curl` уже есть, но падает из-за отсутствующего или несовместимого `zlib`/`libcurl4`, скрипт сам восстановит эти пакеты перед загрузкой релизов MiClash.

Если `luci-app-miclash` уже установлен, скрипт в интерактивном режиме предложит `update / reinstall / delete / skip`.
При запуске через `wget ... | ash` или `curl ... | ash` без TTY удаление не выполняется автоматически: скрипт выберет безопасный `update` или `skip`.

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

После установки откройте LuCI -> Services -> MiClash -> Settings -> Kernel и установите ядро Mihomo из интерфейса.
MiClash определит архитектуру, скачает подходящий архив, заменит `/opt/clash/bin/clash` и перезапустит службу, если она была запущена.

Ручная установка тоже возможна:

```sh
mkdir -p /opt/clash/bin
release=$(curl -s -L https://github.com/MetaCubeX/mihomo/releases/latest | grep "title>Release" | cut -d " " -f 4)
curl -L "https://github.com/MetaCubeX/mihomo/releases/download/${release}/mihomo-linux-arm64-${release}.gz" -o /tmp/clash.gz
gunzip -c /tmp/clash.gz > /opt/clash/bin/clash
chmod 0755 /opt/clash/bin/clash
rm -f /tmp/clash.gz
```

Для других архитектур выберите файл на странице релизов Mihomo: <https://github.com/MetaCubeX/mihomo/releases>.

## Основные возможности

- Нативная LuCI-страница MiClash без отдельного кастомного переключателя темы.
- Управление службой Clash: start, stop, restart, reload.
- Редактор YAML-конфига с проверкой перед применением.
- Загрузка подписки в `/opt/clash/config.yaml`.
- Локальные rulesets в `/opt/clash/lst`.
- Настройки TPROXY/TUN/MIXED, интерфейсов, QUIC block, tmpfs для rules/providers.
- Обновление MiClash и Mihomo через router-side скрипты, чтобы LuCI не держал долгие операции в UI.

## Удаление

```sh
# OpenWrt 25.x:
apk del luci-app-miclash

# OpenWrt 24.10+ (opkg):
opkg remove luci-app-miclash

rm -rf /opt/clash
```
