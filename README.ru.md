<p align="right">
Читать на: <a href="README.md">English</a> | <strong>Русский</strong> | <a href="README.zh-cn.md">中文</a>
</p>

<img width="881" height="889" alt="Снимок экрана MiClash" src="https://github.com/user-attachments/assets/c53492ae-5318-4f34-802e-393306c109f3" />

# MiClash

MiClash — LuCI-приложение для управления Mihomo: подписки, маршрутизация, Guard, диагностика, обновления, уведомления и восстановление в одном интерфейсе.

**Требования:** OpenWrt 24.10+ с firewall4. OpenWrt 25.12+ использует APK, OpenWrt 24.10 — opkg.

## Установка

Установщик определяет пакетный менеджер, проверяет 20 новейших стабильных релизов и выбирает первый с полностью опубликованными файлами и контрольными суммами. Если новый тег ещё собирается, будет установлена предыдущая готовая версия. Установщик проверяет `.sha256`, при необходимости чинит несовместимые `zlib`/`libcurl4`, а для установленного MiClash предлагает обновление, переустановку, удаление или выход. Обновление из LuCI **не откатывается** на старый релиз: оно ждёт файлы самой новой версии и повторяет проверку позже.

Через `wget`:

```sh
wget --no-proxy -qO- https://raw.githubusercontent.com/ang3el7z/luci-app-miclash/main/install-miclash.sh | ash
```

<details>
<summary><strong>🔵 GitHub не открывается? Показать альтернативные команды</strong></summary>

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

<details>
<summary><strong>🟡 Использовать curl</strong></summary>

```sh
curl -fsSL https://raw.githubusercontent.com/ang3el7z/luci-app-miclash/main/install-miclash.sh | ash
```

<blockquote>
<details>
<summary><strong>🔵 GitHub не открывается? Показать альтернативные команды</strong></summary>

Через `gh-proxy.com`:

```sh
curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/ang3el7z/luci-app-miclash/main/install-miclash.sh | ash
```

Через jsDelivr:

```sh
curl -fsSL https://cdn.jsdelivr.net/gh/ang3el7z/luci-app-miclash@main/install-miclash.sh | ash
```

Это сторонние способы загрузки. После обновления jsDelivr некоторое время может отдавать закэшированную версию `main`.

</details>
</blockquote>

</details>

## Быстрый старт

Откройте **LuCI → Службы → MiClash**.

1. Терминальный установщик устанавливает Mihomo автоматически.
2. Добавьте подписку или отредактируйте YAML-профиль.
3. Проверьте YAML — это не изменяет рабочую маршрутизацию.
4. Примените его, чтобы сделать конфигурацию активной.
5. Выберите TPROXY, TUN или MIXED и нужные интерфейсы.
6. Проверьте защищаемые устройства и только затем включите Guard.

Невалидная конфигурация не применяется, а предыдущая активная конфигурация продолжает работать.

## Основные возможности

- **Конфигурации:** прямое редактирование YAML, валидация и атомарное применение.
- **Подписки и обновления:** три URL, ручное и плановое обновление, безопасное обновление MiClash и ядра Mihomo.
- **Маршрутизация:** TPROXY, TUN, MIXED, включения/исключения интерфейсов, авто LAN/WAN, QUIC и локальные rulesets.
- **Диагностика:** состояние Mihomo, DNS, firewall, routing и Guard, очищенный diagnostic report и route test.
- **Самовосстановление:** исправление drift и ступени `reload → restart ядра → restart службы`.
- **Уведомления (notification):** ошибки, восстановление Интернета, обновления, Guard и Memory Guard в LuCI или Telegram.
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

Бот использует только исходящий HTTPS long polling, принимает разрешённые private chat, проверяет sender/chat ID, отклоняет группы, каналы, изменения и дубликаты. `/start` и `/menu` открывают локализованную панель управления в одном сообщении; в списке команд показывается только `/menu`, а все действия выполняются кнопками. Опасные действия требуют подтверждения. Результаты операций и автоматические уведомления сохраняются до подтверждённой доставки Telegram. Логи скачиваются как тот же ограниченный необработанный снимок, который показан в LuCI. Диагностика доступна в режимах Silent, Lite и Full.

```text
/start /menu
```

## Диагностика

Для обычной диагностики откройте **MiClash → Настройки → Компоненты → Диагностика**:

- **Silent** содержит только минимальные сведения о состоянии системы и подходит для публичных обращений.
- **Lite** содержит очищенную диагностику, сводку конфигурации и недавние события. Используйте его для большинства обращений.
- **Full** может содержать приватную конфигурацию и секреты. Передавайте его только доверенной поддержке.

Если LuCI недоступен, выполните по SSH:

```sh
/etc/init.d/miclashd status
/etc/init.d/clash status
ubus call miclash status '{}'
ubus call miclash health '{}'
logread | grep -E '(miclash|mihomo|clash)'
```

Для проверки выбранного пути используйте **Проверку маршрутизации** в карточке «Маршрутизация». При включённом Guard не удаляйте вручную его правила nftables/routing или защитную блокировку.

## Удаление (removal)

```sh
# OpenWrt 25.12+:
apk del luci-app-miclash

# OpenWrt 24.10:
opkg remove luci-app-miclash
```

Удаление сначала останавливает службы и восстанавливает принадлежащие MiClash настройки DNS/firewall/routing. Каталог `/opt/clash` сохраняется; после копирования нужных файлов его можно необратимо удалить вручную:

```sh
rm -rf /opt/clash
```
