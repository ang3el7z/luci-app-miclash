<p align="right">
Читать на: <a href="README.md">English</a> | <strong>Русский</strong> | <a href="README.zh-cn.md">中文</a>
</p>

<img width="881" height="889" alt="Снимок экрана MiClash" src="https://github.com/user-attachments/assets/c53492ae-5318-4f34-802e-393306c109f3" />

# MiClash

MiClash — LuCI-приложение для управления Mihomo на OpenWrt. В одном интерфейсе собраны конфигурации, подписки, маршрутизация, защита Guard, диагностика, обновления, уведомления и восстановление.

Поддерживаемая платформа: **OpenWrt 24.10+ с firewall4**.

- В стабильной OpenWrt 25.12 используется APK.
- В old-stable OpenWrt 24.10 используется opkg.

## Архитектура и безопасность

`miclashd` — единственный управляющий backend MiClash. LuCI и Telegram используют один типизированный `ubus` API; браузер не запускает shell, пакетный менеджер и произвольные файловые операции. Настройки хранятся в `UCI` (`/etc/config/miclash`), а профили, rulesets и ядро Mihomo — в `/opt/clash`.

При включённом Guard система работает по принципу fail-closed. Ранний Guard safety latch защищает выбранный трафик ещё до готовности `miclashd` и Mihomo. Падение демона, отсутствие ядра, неудачное обновление или ремонт не должны незаметно выпустить защищённый трафик напрямую. Снять latch может только явное отключение Guard. Политики устройств не отменяют это правило.

## Автоматическая установка

Bootstrap скачивает установщик из тега во временный приватный каталог и проверяет опубликованную контрольную сумму до запуска (`wget` работает, даже если установленный `curl` сломан):

```sh
set -eu
umask 077
work=$(mktemp -d /tmp/miclash-bootstrap.XXXXXX)
trap 'rm -rf "$work"' EXIT HUP INT TERM
release=$(wget --no-proxy -qO- https://api.github.com/repos/ang3el7z/luci-app-miclash/releases/latest | grep '"tag_name"' | head -n1 | cut -d '"' -f4)
printf '%s\n' "$release" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z][0-9A-Za-z.-]*)?$'
wget --no-proxy -qO "$work/install-miclash.sh" "https://raw.githubusercontent.com/ang3el7z/luci-app-miclash/${release}/install-miclash.sh"
wget --no-proxy -qO "$work/install-miclash.sh.sha256" "https://github.com/ang3el7z/luci-app-miclash/releases/download/${release}/install-miclash.sh.sha256"
(cd "$work" && sha256sum -c install-miclash.sh.sha256)
ash "$work/install-miclash.sh"
```

Установщик проверяет запуск `curl` и при необходимости восстанавливает несовместимые `zlib`/`libcurl4`. Для установленного MiClash он предложит update, reinstall, removal или skip.

## Ручная установка

### OpenWrt 25.12 (APK)

```sh
set -eu
apk update
apk add zlib libcurl4 curl kmod-nft-tproxy kmod-tun coreutils-base64
curl --version >/dev/null 2>&1 || apk fix zlib libcurl4 curl
curl --version >/dev/null 2>&1 || exit 1
release=$(curl -fsSL https://api.github.com/repos/ang3el7z/luci-app-miclash/releases/latest | grep '"tag_name"' | head -n1 | cut -d '"' -f4)
printf '%s\n' "$release" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z][0-9A-Za-z.-]*)?$'
umask 077; work=$(mktemp -d /tmp/miclash-install.XXXXXX); trap 'rm -rf "$work"' EXIT HUP INT TERM
package="luci-app-miclash-${release#v}.apk"
curl -fL "https://github.com/ang3el7z/luci-app-miclash/releases/download/${release}/${package}" -o "$work/$package"
curl -fL "https://github.com/ang3el7z/luci-app-miclash/releases/download/${release}/${package}.sha256" -o "$work/$package.sha256"
(cd "$work" && sha256sum -c "$package.sha256")
apk add "$work/$package" --allow-untrusted
```

### OpenWrt 24.10+ (opkg)

```sh
set -eu
opkg update
opkg install --force-reinstall zlib libcurl4 curl
opkg install kmod-nft-tproxy kmod-tun coreutils-base64
curl --version >/dev/null 2>&1 || exit 1
release=$(curl -fsSL https://api.github.com/repos/ang3el7z/luci-app-miclash/releases/latest | grep '"tag_name"' | head -n1 | cut -d '"' -f4)
printf '%s\n' "$release" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z][0-9A-Za-z.-]*)?$'
umask 077; work=$(mktemp -d /tmp/miclash-install.XXXXXX); trap 'rm -rf "$work"' EXIT HUP INT TERM
package="luci-app-miclash_${release#v}_all.ipk"
curl -fL "https://github.com/ang3el7z/luci-app-miclash/releases/download/${release}/${package}" -o "$work/$package"
curl -fL "https://github.com/ang3el7z/luci-app-miclash/releases/download/${release}/${package}.sha256" -o "$work/$package.sha256"
(cd "$work" && sha256sum -c "$package.sha256")
opkg install "$work/$package"
```

В релизе рядом с каждым пакетом публикуется `.sha256` и общий `miclash-release-manifest.json`. Манифест содержит tag, SHA исходного тега, SHA синхронизированной сборки, версию/target SDK OpenWrt, тип пакета, размер и SHA-256.

## Первая настройка

Откройте **LuCI → Службы → MiClash**.

1. В **Настройки → Ядро** установите Mihomo. MiClash определит архитектуру, скачает и проверит релиз, подготовит замену и сохранит либо восстановит предыдущее ядро при неудачной активации.
2. Добавьте подписку или отредактируйте YAML-профиль.
3. Проверьте Draft. Валидация не меняет рабочую маршрутизацию.
4. Примените его, чтобы ревизия стала Active.
5. Выберите TPROXY, TUN или MIXED и нужные включённые/исключённые интерфейсы.
6. Включайте Guard после проверки списка защищаемых устройств и интерфейсов.

Невалидный профиль остаётся Draft и не применяется. Предыдущий Active продолжает работать, поэтому последовательные правки пользователя не теряются.

## Возможности

- **Draft / Active:** отдельная сохранённая черновая и активная ревизия, проверка, атомарное применение и rollback при ошибке.
- **История (history):** метаданные и безопасный diff, открытие старой ревизии как Draft, явный restore и recovery snapshot перед откатом.
- **Подписки и update:** три URL профилей, ручное и плановое обновление подписки, обновление MiClash, проверенное обновление Mihomo и rollback ядра.
- **Маршрутизация:** TPROXY, TUN, MIXED, режим включений/исключений, автоопределение LAN/WAN, блокировка QUIC и локальные rulesets.
- **Диагностика:** состояние Mihomo, DNS, firewall, routing и Guard; очищенный diagnostic report; пошаговый route test для домена/IP и выбранного устройства/интерфейса.
- **Саморемонт и memory recovery:** исправление drift и ступени `reload → внутренний restart ядра → restart службы` с проверками и длительным cooldown после неудачи.
- **Уведомления (notification):** ошибки, восстановление Интернета, update, Guard и Memory Guard в LuCI и, при желании, в Telegram.
- **Backup / restore:** ограниченный экспорт/импорт, предупреждение о secrets, обязательное preview и recovery snapshot перед восстановлением.
- **Device policies:** найденные клиенты, расписания и действия inherit/proxy/direct/block; Guard всегда имеет приоритет.

## Управление через Telegram

В **Настройки → Telegram** включите интеграцию, укажите token от **BotFather** и свой числовой Telegram user ID. Token хранится как секрет и не возвращается в LuCI. Пустое поле при следующем сохранении не заменяет уже сохранённый token.

Модель безопасности:

- только исходящий HTTPS long polling, входной порт на роутере не открывается;
- разрешён ровно один user ID;
- только private chat, sender ID и chat ID должны совпасть;
- подтверждение и одноразовый token не используются;
- группы, каналы, edited messages, дубликаты и неизвестные команды отклоняются;
- logs/diagnostics ограничены и очищены, действует rate limit и backoff.

Полный список команд:

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

`/reboot` сразу перезагружает роутер после авторизации — подтверждения намеренно нет.

## Настройки UCI

Рекомендуется изменять их через LuCI. Для просмотра:

```sh
uci show miclash
ubus call miclash status '{}'
ubus call miclash health '{}'
```

Основные секции UCI: `core`, `interfaces`, `guard`, `memory`, `updates`, `telegram`, `notifications`, `backup` и `meta`. Файл `/etc/config/miclash` должен быть доступен только root: в нём могут находиться URL подписок и Telegram token.

## Одноразовая миграция с v0.9.2

Первое обновление с v0.9.2 выполняет журналируемую и идемпотентную миграцию. Сохраняются профили, совместимые настройки UCI, rulesets, подписки, ядро Mihomo, желаемое состояние Guard и данные восстановления DNS. Старые cron/hotplug/backend-скрипты удаляются только после регистрации `miclashd`, успешной сверки состояния и проверки миграции.

Если проверка не прошла, пакет завершит установку ошибкой, а не покажет ложный успех. При Guard ON safety latch останется защищённым; исправьте указанную причину и повторите конфигурацию пакета.

## Безопасное обновление и recovery

- Применение конфига сначала выполняет validation и откатывает частично изменённые DNS/firewall/routing.
- Обновление Mihomo использует staging и сохраняет кандидата для rollback.
- Автоматический и ручной update сериализуются с другими изменениями.
- Health reconcile чинит только принадлежащие MiClash DNS/firewall/routing объекты и не присваивает чужие правила.
- Memory Guard реагирует на аномальный рост Mihomo вместе с давлением памяти, после каждой ступени проверяет снижение RSS и при общей неудаче уходит в cooldown.
- События восстановления Интернета и ремонта попадают в notification и Telegram.

Перед крупными изменениями создайте backup без secrets; включайте secrets только для защищённого локального архива.

## Диагностика неполадок

```sh
/etc/init.d/miclashd status
/etc/init.d/clash status
ubus call miclash status '{}'
ubus call miclash health '{}'
logread -e miclashd
```

Для обращения за помощью используйте **Скачать diagnostic report**, а для объяснения пути — **route test**. Если операция упала, посмотрите stage/error и не запускайте новую мутацию, пока предыдущая не завершилась.

При включённом Guard не удаляйте вручную nftables/routing rules и latch. Восстановите службу через LuCI, переустановите пакет либо явно отключите Guard, только если прямой трафик допустим.

## Безопасное удаление (removal)

```sh
# OpenWrt 25.12:
apk del luci-app-miclash

# OpenWrt 24.10+:
opkg remove luci-app-miclash
```

Протокол удаления сначала сохраняет защиту Guard, останавливает службы, восстанавливает принадлежащие MiClash DNS/firewall/routing настройки и лишь затем удаляет backend. Неудачная очистка остаётся retryable и не маскируется успешным результатом.

Интерактивный установщик дополнительно предлагает удалить `/opt/clash`. В неинтерактивном режиме runtime/config каталог сохраняется. После успешного удаления пакета его можно стереть вручную:

```sh
rm -rf /opt/clash
```

Этот final purge необратим — сначала экспортируйте backup.
