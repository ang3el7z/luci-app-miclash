# OpenWrt 25.12.x

```bash
apk update
apk add curl kmod-nft-tproxy kmod-tun coreutils-base64
release=$(curl -s https://api.github.com/repos/ang3el7z/luci-app-miclash/releases/latest | grep '"tag_name"' | head -n1 | cut -d '"' -f4)
curl -L "https://github.com/ang3el7z/luci-app-miclash/releases/download/${release}/luci-app-miclash-${release#v}.apk" -o /tmp/luci-app-miclash.apk
apk add /tmp/luci-app-miclash.apk --allow-untrusted && rm -rf /tmp/*.apk
```

# OpenWRT 23.05.x - 24.10.x

```bash
opkg update && opkg install curl kmod-nft-tproxy kmod-tun coreutils-base64
release=$(curl -s https://api.github.com/repos/ang3el7z/luci-app-miclash/releases/latest | grep '"tag_name"' | head -n1 | cut -d '"' -f4)
curl -L "https://github.com/ang3el7z/luci-app-miclash/releases/download/${release}/luci-app-miclash_${release#v}_all.ipk" -o /tmp/luci-app-miclash.ipk && opkg install /tmp/luci-app-miclash.ipk && rm -rf /tmp/*.ipk
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

