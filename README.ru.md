<p align="right">
Читать на: <a href="README.md">English</a> | <strong>Русский</strong> | <a href="README.zh-cn.md">中文</a>
</p>

<img width="881" height="889" alt="Снимок экрана MiClash" src="https://github.com/user-attachments/assets/c53492ae-5318-4f34-802e-393306c109f3" />

# MiClash

MiClash — LuCI-приложение для управления Mihomo: подписки, маршрутизация, Guard, диагностика, обновления, уведомления и восстановление в одном интерфейсе.

**Требования:** OpenWrt 24.10+ с firewall4. OpenWrt 25.12+ использует APK, OpenWrt 24.10 — opkg.

## Установка

Установщик определяет пакетный менеджер, проверяет 20 новейших стабильных релизов и выбирает первый с полностью опубликованными файлами и контрольными суммами. Если новый тег ещё собирается, будет установлена предыдущая готовая версия.

Через `wget`:

```sh
wget --no-proxy -qO- https://raw.githubusercontent.com/ang3el7z/luci-app-miclash/main/install-miclash.sh | ash
```

Или через `curl`:

```sh
curl -fsSL https://raw.githubusercontent.com/ang3el7z/luci-app-miclash/main/install-miclash.sh | ash
```

<details>
<summary>GitHub не открывается? Показать альтернативные команды</summary>

Через `gh-proxy.com`:

```sh
wget --no-proxy -qO- https://gh-proxy.com/https://raw.githubusercontent.com/ang3el7z/luci-app-miclash/main/install-miclash.sh | ash
```

Через jsDelivr:

```sh
wget --no-proxy -qO- https://cdn.jsdelivr.net/gh/ang3el7z/luci-app-miclash@main/install-miclash.sh | ash
```

Это сторонние способы загрузки. После обновления jsDelivr некоторое время может отдавать закэшированную версию `main`.

</details>

Установщик проверяет `.sha256`, при необходимости чинит несовместимые `zlib`/`libcurl4`, а для установленного MiClash предлагает обновление, переустановку, удаление или выход. Обновление из LuCI **не откатывается** на старый релиз: оно ждёт файлы самой новой версии и повторяет проверку позже.

## Переход с v0.9.x на v2.x

Для установленной v0.9.x один раз запустите отдельный переходный скрипт:

```sh
wget --no-proxy -qO- https://raw.githubusercontent.com/ang3el7z/luci-app-miclash/main/install-miclash-upgrade-0-9-x-to-2.x.x.sh | ash
```

<details>
<summary>GitHub не открывается? Показать альтернативные команды</summary>

Через `gh-proxy.com`:

```sh
wget --no-proxy -qO- https://gh-proxy.com/https://raw.githubusercontent.com/ang3el7z/luci-app-miclash/main/install-miclash-upgrade-0-9-x-to-2.x.x.sh | ash
```

Через jsDelivr:

```sh
wget --no-proxy -qO- https://cdn.jsdelivr.net/gh/ang3el7z/luci-app-miclash@main/install-miclash-upgrade-0-9-x-to-2.x.x.sh | ash
```

Это сторонние способы загрузки. После обновления jsDelivr некоторое время может отдавать закэшированную версию `main`.

</details>

Скрипт проверит готовый стабильный релиз v2, сохранит профили, ядро Mihomo, rules/providers и настройки в `/root/miclash-v09-backup-*`, удалит v0.9, установит v2 и восстановит данные. Автоматического rollback и journal нет; при ошибке backup останется для ручного восстановления.

Во время короткой замены Guard не работает. Если прямой выход защищённого трафика недопустим, запускайте переход из локальной сети.

## Быстрый старт

Откройте **LuCI → Службы → MiClash**.

1. Терминальный установщик устанавливает Mihomo автоматически.
2. Добавьте подписку или отредактируйте YAML-профиль.
3. Проверьте Draft — это не изменяет рабочую маршрутизацию.
4. Примените Draft, чтобы сделать его Active.
5. Выберите TPROXY, TUN или MIXED и нужные интерфейсы.
6. Проверьте защищаемые устройства и только затем включите Guard.

Невалидный Draft не применяется, а предыдущая Active-конфигурация продолжает работать.

## Основные возможности

- **Конфигурации:** Draft/Active, валидация, атомарное применение, история (history), diff, restore и recovery snapshot.
- **Подписки и обновления:** три URL, ручное и плановое обновление, безопасное обновление MiClash и ядра Mihomo.
- **Маршрутизация:** TPROXY, TUN, MIXED, включения/исключения интерфейсов, авто LAN/WAN, QUIC и локальные rulesets.
- **Диагностика:** состояние Mihomo, DNS, firewall, routing и Guard, очищенный diagnostic report и route test.
- **Самовосстановление:** исправление drift и ступени `reload → restart ядра → restart службы`.
- **Уведомления (notification):** ошибки, восстановление Интернета, обновления, Guard и Memory Guard в LuCI или Telegram.
- **Backup/restore:** preview перед импортом, предупреждение о secrets и recovery snapshot.
- **Политики устройств (device policies):** расписания и действия inherit/proxy/direct/block; Guard всегда имеет приоритет.

## Guard и восстановление

`miclashd` — единый backend MiClash; LuCI и Telegram используют типизированный `ubus` API. Настройки UCI находятся в `/etc/config/miclash`, а профили, rulesets и ядро — в `/opt/clash`.

- Guard работает по принципу fail-closed и защищает выбранный трафик до готовности Mihomo.
- Сбой службы, ядра, обновления или ремонта не отключает защиту; снять latch можно только явным выключением Guard.
- Конфигурация сначала проходит проверку, а частичные изменения DNS/firewall/routing откатываются.
- Обновление Mihomo выполняется через staging с возможностью вернуть предыдущее ядро.
- Memory Guard действует только при аномальном росте Mihomo и давлении памяти, проверяет результат каждой ступени и после общей неудачи включает длительный cooldown.

Храните `/etc/config/miclash` доступным только root: файл может содержать URL подписок и Telegram token.

## Управление через Telegram

В **Настройки → Telegram** включите интеграцию, укажите token от **BotFather** и свой числовой user ID. Token хранится как секрет и не возвращается в LuCI; пустое поле не заменяет уже сохранённый token.

Бот использует только исходящий HTTPS long polling, принимает private chat ровно от одного user ID, проверяет sender/chat ID, отклоняет группы, каналы, изменения и дубликаты. Логи и диагностика ограничены, очищены и защищены rate limit/backoff.

```text
/status /health /memory /diagnostics /logs /help
/start /stop /restart /reload /reboot
/subscription URL /update_subscription /update_miclash /update_mihomo
/guard_on /guard_off /backup
```

`/reboot` перезагружает роутер сразу после проверки пользователя, без дополнительного подтверждения.

## Диагностика

```sh
/etc/init.d/miclashd status
/etc/init.d/clash status
ubus call miclash status '{}'
ubus call miclash health '{}'
logread -e miclashd
```

Для обращения за помощью скачайте диагностический отчёт, а для проверки пути используйте route test. При включённом Guard не удаляйте вручную его nftables/routing rules или latch.

## Удаление (removal)

```sh
# OpenWrt 25.12+:
apk del luci-app-miclash

# OpenWrt 24.10:
opkg remove luci-app-miclash
```

Удаление сначала останавливает службы и восстанавливает принадлежащие MiClash настройки DNS/firewall/routing. Каталог `/opt/clash` сохраняется; после создания backup его можно необратимо удалить вручную:

```sh
rm -rf /opt/clash
```
