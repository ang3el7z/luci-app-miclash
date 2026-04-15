# Copyright 2024-2026 ZeroChaos (https://github.com/zerolabnet/SSClash)
# This is free software, licensed under the GNU General Public License v2.

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-miclash
PKG_VERSION:=0.1.2
PKG_RELEASE:=1
PKG_MAINTAINER:=ang3el7z

LUCI_TITLE:=LuCI Support for MiClash
LUCI_DEPENDS:=+luci-base +coreutils-base64 +kmod-tun
LUCI_PKGARCH:=all

PKG_CONFIG_DEPENDS:= \
	CONFIG_PACKAGE_$(PKG_NAME)_Iptables_Transparent_Proxy \
	CONFIG_PACKAGE_$(PKG_NAME)_Nftables_Transparent_Proxy

PKG_BUILD_DEPENDS:=luci-base/host

include $(INCLUDE_DIR)/package.mk

define Package/$(PKG_NAME)
	SECTION:=luci
	CATEGORY:=LuCI
	SUBMENU:=3. Applications
	TITLE:=$(LUCI_TITLE)
	DEPENDS:=$(LUCI_DEPENDS)
	PKGARCH:=$(LUCI_PKGARCH)
endef

define Package/$(PKG_NAME)/config
choice
	prompt "Transparent Proxy Backend for MiClash"
	default PACKAGE_$(PKG_NAME)_Iptables_Transparent_Proxy if !PACKAGE_firewall4
	default PACKAGE_$(PKG_NAME)_Nftables_Transparent_Proxy if PACKAGE_firewall4

config PACKAGE_$(PKG_NAME)_Iptables_Transparent_Proxy
	bool "Iptables Transparent Proxy"
	select PACKAGE_iptables-mod-tproxy

config PACKAGE_$(PKG_NAME)_Nftables_Transparent_Proxy
	bool "Nftables Transparent Proxy"
	select PACKAGE_kmod-nft-tproxy

endchoice
endef

define Package/$(PKG_NAME)/description
	LuCI interface for MiClash, a tool for managing and configuring Clash.
endef

define Build/Prepare
	# No preparation steps required
endef

define Build/Compile
	@mkdir -p $(PKG_BUILD_DIR)/po/ru
	@if [ -f "./rootfs/po/ru/miclash.po" ]; then \
		$(STAGING_DIR_HOSTPKG)/bin/po2lmo \
			"./rootfs/po/ru/miclash.po" \
			"$(PKG_BUILD_DIR)/po/ru/miclash.lmo"; \
	fi
endef

define Package/$(PKG_NAME)/conffiles
/opt/clash/config.yaml
endef

define Package/$(PKG_NAME)/install
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./rootfs/etc/init.d/clash $(1)/etc/init.d/

	$(INSTALL_DIR) $(1)/etc/hotplug.d/iface
	$(INSTALL_BIN) ./rootfs/etc/hotplug.d/iface/40-clash $(1)/etc/hotplug.d/iface/
	$(INSTALL_DIR) $(1)/etc/hotplug.d/net
	$(INSTALL_BIN) ./rootfs/etc/hotplug.d/net/99-clash-tun $(1)/etc/hotplug.d/net/

	$(INSTALL_DIR) $(1)/opt/clash/bin
	$(INSTALL_BIN) ./rootfs/opt/clash/bin/clash-rules $(1)/opt/clash/bin/

	$(INSTALL_DIR) $(1)/opt/clash
	$(INSTALL_DATA) ./rootfs/opt/clash/config.yaml $(1)/opt/clash/

	$(INSTALL_DIR) $(1)/opt/clash/ui
	$(CP) ./rootfs/opt/clash/ui/* $(1)/opt/clash/ui/

	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DATA) ./rootfs/usr/share/luci/menu.d/luci-app-miclash.json $(1)/usr/share/luci/menu.d/

	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./rootfs/usr/share/rpcd/acl.d/luci-app-miclash.json $(1)/usr/share/rpcd/acl.d/

	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/miclash
	$(CP) ./rootfs/www/luci-static/resources/view/miclash/* $(1)/www/luci-static/resources/view/miclash/

	$(INSTALL_DIR) $(1)/opt/clash/lst

ifdef CONFIG_USE_APK
	$(INSTALL_DIR) $(1)/etc/apk/protected_paths.d
	$(INSTALL_DATA) ./rootfs/etc/apk/protected_paths.d/miclash.list $(1)/etc/apk/protected_paths.d/
endif

	@if [ -f "$(PKG_BUILD_DIR)/po/ru/miclash.lmo" ]; then \
		$(INSTALL_DIR) $(1)/usr/lib/lua/luci/i18n; \
		$(INSTALL_DATA) "$(PKG_BUILD_DIR)/po/ru/miclash.lmo" \
			"$(1)/usr/lib/lua/luci/i18n/miclash.ru.lmo"; \
	fi
endef

define Package/$(PKG_NAME)/preinst
#!/bin/sh
[ -f /opt/clash/config.yaml ] && cp -p /opt/clash/config.yaml /tmp/miclash_config.yaml.bak
exit 0
endef

define Package/$(PKG_NAME)/postinst
#!/bin/sh
if [ -f /tmp/miclash_config.yaml.bak ]; then
	mv /tmp/miclash_config.yaml.bak /opt/clash/config.yaml
fi
[ -n "$$IPKG_INSTROOT" ] || {
	/etc/init.d/rpcd reload
	rm -f /tmp/luci-*

	# Ensure periodic clash-rules update cron job exists
	CRON_FILE="/etc/crontabs/root"
	CRON_LINE="*/30 * * * * /opt/clash/bin/clash-rules update >/dev/null 2>&1"

	[ -f "$$CRON_FILE" ] || touch "$$CRON_FILE"
	if ! grep -Fq "/opt/clash/bin/clash-rules update" "$$CRON_FILE" 2>/dev/null; then
		echo "$$CRON_LINE" >> "$$CRON_FILE"
		/etc/init.d/cron restart >/dev/null 2>&1 || true
	fi
}
exit 0
endef

define Package/$(PKG_NAME)/postrm
#!/bin/sh
[ -n "$$IPKG_INSTROOT" ] || {
	# Clean up cron job for clash-rules update, if present
	CRON_FILE="/etc/crontabs/root"
	if [ -f "$$CRON_FILE" ]; then
		sed -i '\|/opt/clash/bin/clash-rules update|d' "$$CRON_FILE" 2>/dev/null || true
		/etc/init.d/cron restart >/dev/null 2>&1 || true
	fi

	rm -rf /opt/clash/ui
	rm -f /opt/clash/ruleset
	rm -rf /tmp/clash
	rm -rf /www/luci-static/resources/view/miclash
	rm -f /usr/lib/lua/luci/i18n/miclash.*.lmo
	rm -f /etc/hotplug.d/iface/40-clash
	rm -f /etc/hotplug.d/net/99-clash-tun
	rm -f /etc/apk/protected_paths.d/miclash.list
}
endef

$(eval $(call BuildPackage,$(PKG_NAME)))
