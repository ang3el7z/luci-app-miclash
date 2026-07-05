<p align="right">
Читать на: <a href="README.md">English</a> | <strong>Русский</strong> | <a href="README.zh-cn.md">中文</a>
</p>

# MiClash

LuCI-приложение для управления Mihomo/Clash на OpenWrt.

## Автоустановка

```sh
wget --no-proxy -qO- https://raw.githubusercontent.com/ang3el7z/luci-app-miclash/main/install-miclash.sh | ash
```

Если `luci-app-miclash` уже установлен, скрипт в интерактивном режиме предложит `update / reinstall / delete / skip`.
При запуске через `wget ... | ash` без TTY удаление не выполняется автоматически: скрипт выберет безопасный `update` или `skip`.

## OpenWrt 25.x

```sh
apk update
apk add zlib libcurl4 curl kmod-nft-tproxy kmod-tun coreutils-base64
release=$(curl -s https://api.github.com/repos/ang3el7z/luci-app-miclash/releases/latest | grep '"tag_name"' | head -n1 | cut -d '"' -f4)
curl -L "https://github.com/ang3el7z/luci-app-miclash/releases/download/${release}/luci-app-miclash-${release#v}.apk" -o /tmp/luci-app-miclash.apk
apk add /tmp/luci-app-miclash.apk --allow-untrusted
rm -f /tmp/luci-app-miclash.apk
```

## OpenWrt 23.05.x - 24.10.x

```sh
opkg update
opkg install zlib libcurl4 curl kmod-nft-tproxy kmod-tun coreutils-base64
release=$(curl -s https://api.github.com/repos/ang3el7z/luci-app-miclash/releases/latest | grep '"tag_name"' | head -n1 | cut -d '"' -f4)
curl -L "https://github.com/ang3el7z/luci-app-miclash/releases/download/${release}/luci-app-miclash_${release#v}_all.ipk" -o /tmp/luci-app-miclash.ipk
opkg install /tmp/luci-app-miclash.ipk
rm -f /tmp/luci-app-miclash.ipk
```

Для старых сборок OpenWrt с `firewall3` вместо `kmod-nft-tproxy` нужен `iptables-mod-tproxy`.

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

# OpenWrt 23.05.x - 24.10.x:
opkg remove luci-app-miclash

rm -rf /opt/clash
```
