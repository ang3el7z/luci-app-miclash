# Установка miclash на OpenWrt

1. Скачать свежую https://github.com/ang3el7z/luci-app-miclash/releases
2. Веб интерфейс -> `Software` -> `Update lists` -> `Upload Package` установить скачанный файл `.ipk`
3. Там же в фильтре ищем `kmod-nft-tproxy` для OpenWrt 23-24 или `iptables-mod-tproxy` для древних OpenWrt и ставим его.
4. Выходим из админки `Log out` и заходим снова, появляется меню `Services` -> `SSClash`
5. `SSClash` -> `Settings` -> внизу скачать ядро Mihomo `Download Core`
6. Вместо `TPROXY` лучше выбрать `Mixed (TCP+UDP)`
7. Если используете подписки с модемом на белых списках, лучше отключить `Store rules and proxy providers in RAM (tmpfs)`
8. По [мануалу](https://www.notion.so/Mihomo-15989188f6b480c2a883ece08af50ae1?pvs=21) настраиваем, а всё, что ниже, можно не читать.

# Если не сработало, работаем клавиатурой:

Для выполнения команд, подключитесь к вашему роутеру по SSH (например, через [Termius](https://termius.com/), [Putty](https://www.putty.org/) или командную строку Windows). Установите ваш часовой пояс и синхронизируйте время на роутере.

[Что такое SSH?](https://www.notion.so/SSH-15f89188f6b480bcb64aea8cdc941d67?pvs=21)

# OpenWrt 25.12.x

```bash
apk update
apk add curl kmod-nft-tproxy kmod-tun coreutils-base64
release=$(curl -s https://api.github.com/repos/ang3el7z/luci-app-miclash/releases/latest | grep '"tag_name"' | head -n1 | cut -d '"' -f4)
curl -L "https://github.com/ang3el7z/luci-app-miclash/releases/download/${release}/luci-app-miclash-${release#v}-r1.apk" -o /tmp/luci-app-miclash.apk
apk add /tmp/luci-app-miclash.apk --allow-untrusted && rm -rf /tmp/*.apk
```

# OpenWRT 23.05.x - 24.10.x

```bash
opkg update && opkg install curl kmod-nft-tproxy kmod-tun coreutils-base64
release=$(curl -s https://api.github.com/repos/ang3el7z/luci-app-miclash/releases/latest | grep '"tag_name"' | head -n1 | cut -d '"' -f4)
curl -L "https://github.com/ang3el7z/luci-app-miclash/releases/download/${release}/luci-app-miclash_${release#v}-r1_all.ipk" -o /tmp/luci-app-miclash.ipk && opkg install /tmp/luci-app-miclash.ipk && rm -rf /tmp/*.ipk
```

*Для OpenWrt 21.x вместо `kmod-nft-tproxy` нужен `iptables-mod-tproxy`*

# Ядро [Mihomo](https://github.com/MetaCubeX/mihomo)

**ARM64** (Mediatek Filogic: Xiaomi AX3000T, Routerich AX3000, RAX3000Me, Cudy TR3000, gl.inet GL-MT3000, MT6000 и др):

```bash
releasemihomo=$(curl -s -L https://github.com/MetaCubeX/mihomo/releases/latest | grep "title>Release" | cut -d " " -f 4)
curl -L https://github.com/MetaCubeX/mihomo/releases/download/$releasemihomo/mihomo-linux-arm64-$releasemihomo.gz -o /tmp/clash.gz
gunzip -c /tmp/clash.gz > /opt/clash/bin/clash
chmod +x /opt/clash/bin/clash
rm -rf /tmp/clash.gz
```

**mipsel_24kc** (Almond 3S, Netis N6 и подобные):

```bash
releasemihomo=$(curl -s -L https://github.com/MetaCubeX/mihomo/releases/latest | grep "title>Release" | cut -d " " -f 4)
curl -L https://github.com/MetaCubeX/mihomo/releases/download/$releasemihomo/mihomo-linux-mipsle-softfloat-$releasemihomo.gz -o /tmp/clash.gz
gunzip -c /tmp/clash.gz > /opt/clash/bin/clash
chmod +x /opt/clash/bin/clash
rm -rf /tmp/clash.gz
```

**AMD64** (x86 сборки OpenWrt для мини ПК):

```bash
releasemihomo=$(curl -s -L https://github.com/MetaCubeX/mihomo/releases/latest | grep "title>Release" | cut -d " " -f 4)
curl -L https://github.com/MetaCubeX/mihomo/releases/download/$releasemihomo/mihomo-linux-amd64-compatible-$releasemihomo.gz -o /tmp/clash.gz
gunzip -c /tmp/clash.gz > /opt/clash/bin/clash
chmod +x /opt/clash/bin/clash
rm -rf /tmp/clash.gz
```

**Ядра для других архитектур:** [https://github.com/MetaCubeX/mihomo/releases](https://4pda.to/stat/go?u=https%3A%2F%2Fgithub.com%2FMetaCubeX%2Fmihomo%2Freleases&e=132278268)

*Чтобы в админке вашего роутера появилась новая менюшка с Super Simple Clash, после установки нужно один раз из админки выйти (log out), если вы сейчас в ней, и зайти заново (log in).*

Стандартный конфиг Clash нужно отредактировать, прописав хотя бы один рабочий сервер, а затем применить **`Save & Apply`**. Если в конфиге нет ошибок, Clash запустится и загорится зелёная надпись Clash is running, если есть ошибки, останется красная надпись Clash stopped, а в соседней вкладке `Log` можно почитать, что ему не нравится и попробовать исправить. Чтобы увидеть больше информации в логах, стартуйте Clash из консоли:

```bash
service clash start
```

