# Copyright 2024-2026 ZeroChaos (https://github.com/zerolabnet/SSClash)
# This is free software, licensed under the GNU General Public License v2.

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-miclash
PKG_VERSION:=0.9.2
PKG_RELEASE:=1
PKG_MAINTAINER:=ang3el7z

LUCI_TITLE:=LuCI Support for MiClash
LUCI_DEPENDS:=+luci-base +zlib +libcurl +curl +coreutils-base64 +kmod-tun \
	+nftables +coreutils-timeout +ucode-mod-fs +ucode-mod-math +ucode-mod-digest +ucode-mod-socket
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
	@mkdir -p $(PKG_BUILD_DIR)/po/zh-cn
	@if [ -f "./rootfs/po/zh-cn/miclash.po" ]; then \
		$(STAGING_DIR_HOSTPKG)/bin/po2lmo \
			"./rootfs/po/zh-cn/miclash.po" \
			"$(PKG_BUILD_DIR)/po/zh-cn/miclash.lmo"; \
	fi
endef

define Package/$(PKG_NAME)/conffiles
/opt/clash/config.yaml
/opt/clash/settings
endef

define Package/$(PKG_NAME)/install
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./rootfs/etc/init.d/clash $(1)/etc/init.d/
	$(INSTALL_BIN) ./rootfs/etc/init.d/miclash-guard $(1)/etc/init.d/
	$(INSTALL_BIN) ./rootfs/etc/init.d/miclash-autoupdate $(1)/etc/init.d/
	$(INSTALL_BIN) ./rootfs/etc/init.d/miclash-memory-guard $(1)/etc/init.d/

	$(INSTALL_DIR) $(1)/etc/hotplug.d/iface
	$(INSTALL_BIN) ./rootfs/etc/hotplug.d/iface/40-clash $(1)/etc/hotplug.d/iface/
	$(INSTALL_DIR) $(1)/etc/hotplug.d/net
	$(INSTALL_BIN) ./rootfs/etc/hotplug.d/net/99-clash-tun $(1)/etc/hotplug.d/net/
	$(INSTALL_DIR) $(1)/etc/iproute2/rt_protos.d
	$(INSTALL_DATA) ./rootfs/etc/iproute2/rt_protos.d/miclash.conf $(1)/etc/iproute2/rt_protos.d/
	$(INSTALL_DIR) $(1)/etc/iproute2/rt_tables.d
	$(INSTALL_DATA) ./rootfs/etc/iproute2/rt_tables.d/miclash.conf $(1)/etc/iproute2/rt_tables.d/

	$(INSTALL_DIR) $(1)/opt/clash/bin
	$(INSTALL_BIN) ./rootfs/opt/clash/bin/clash-rules $(1)/opt/clash/bin/
	$(INSTALL_BIN) ./rootfs/opt/clash/bin/miclash-subscription $(1)/opt/clash/bin/
	$(INSTALL_BIN) ./rootfs/opt/clash/bin/miclash-update $(1)/opt/clash/bin/
	$(INSTALL_BIN) ./rootfs/opt/clash/bin/miclash-service $(1)/opt/clash/bin/
	$(INSTALL_BIN) ./rootfs/opt/clash/bin/miclash-autoupdate $(1)/opt/clash/bin/
	$(INSTALL_BIN) ./rootfs/opt/clash/bin/miclash-memory-guard $(1)/opt/clash/bin/

	$(INSTALL_DIR) $(1)/opt/clash
	$(INSTALL_DATA) ./rootfs/opt/clash/config.yaml $(1)/opt/clash/

	$(INSTALL_DIR) $(1)/opt/clash/ui
	$(CP) ./rootfs/opt/clash/ui/* $(1)/opt/clash/ui/

	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DATA) ./rootfs/usr/share/luci/menu.d/luci-app-miclash.json $(1)/usr/share/luci/menu.d/

	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./rootfs/usr/share/rpcd/acl.d/luci-app-miclash.json $(1)/usr/share/rpcd/acl.d/
	$(INSTALL_DIR) $(1)/usr/share/miclash
	$(INSTALL_DATA) ./rootfs/usr/share/miclash/*.uc $(1)/usr/share/miclash/
	$(INSTALL_DATA) ./rootfs/usr/share/miclash/mutation-lock.sh $(1)/usr/share/miclash/
	$(INSTALL_BIN) ./rootfs/usr/share/miclash/package-remove $(1)/usr/share/miclash/
	$(INSTALL_BIN) ./rootfs/usr/share/miclash/package-release $(1)/usr/share/miclash/
	$(INSTALL_DIR) $(1)/usr/libexec/miclash
	$(INSTALL_BIN) ./rootfs/usr/libexec/miclash/validate-config.uc $(1)/usr/libexec/miclash/
	$(INSTALL_BIN) ./rootfs/usr/libexec/miclash/mihomo-https.uc $(1)/usr/libexec/miclash/

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
	@if [ -f "$(PKG_BUILD_DIR)/po/zh-cn/miclash.lmo" ]; then \
		$(INSTALL_DIR) $(1)/usr/lib/lua/luci/i18n; \
		$(INSTALL_DATA) "$(PKG_BUILD_DIR)/po/zh-cn/miclash.lmo" \
			"$(1)/usr/lib/lua/luci/i18n/miclash.zh-cn.lmo"; \
	fi
endef

define Package/$(PKG_NAME)/preinst
#!/bin/sh
mkdir -p /opt/clash 2>/dev/null || true
[ -f /opt/clash/config.yaml ] && cp -p /opt/clash/config.yaml /opt/clash/.config.yaml.upgrade.bak
[ -f /opt/clash/settings ] && cp -p /opt/clash/settings /opt/clash/.settings.upgrade.bak
exit 0
endef

define Package/$(PKG_NAME)/postinst
#!/bin/sh
SETTINGS_RESTORED=0
if [ -f /opt/clash/.config.yaml.upgrade.bak ]; then
	mv /opt/clash/.config.yaml.upgrade.bak /opt/clash/config.yaml
	FIRST_INSTALL=0
else
	FIRST_INSTALL=1
fi
if [ -f /opt/clash/.settings.upgrade.bak ]; then
	mv /opt/clash/.settings.upgrade.bak /opt/clash/settings
	chmod 0644 /opt/clash/settings 2>/dev/null || true
	SETTINGS_RESTORED=1
fi
[ -n "$$IPKG_INSTROOT" ] || {
	/etc/init.d/rpcd reload
	/etc/init.d/miclash-guard enable 2>/dev/null || true
	/etc/init.d/miclash-guard start || exit 1
	# Drop LuCI server-side caches so updated MiClash assets are used immediately.
	rm -rf /tmp/luci-indexcache* /tmp/luci-modulecache*

	# On first install the default config.yaml is just a usable example
	# (no real proxies configured). Prevent auto-start on next boot so the
	# user can edit /opt/clash/config.yaml first. "Start Service" in LuCI
	# re-enables it via `/etc/init.d/clash enable`.
	if [ "$$FIRST_INSTALL" = "1" ]; then
		/etc/init.d/clash disable 2>/dev/null || true
	fi

	if [ "$$SETTINGS_RESTORED" = "1" ] && [ -x /opt/clash/bin/clash-rules ]; then
		CLASH_RULES_QUIET=1 /opt/clash/bin/clash-rules guard_refresh >/dev/null 2>&1 || true
	fi
	[ -x /opt/clash/bin/miclash-memory-guard ] && /opt/clash/bin/miclash-memory-guard sync >/dev/null 2>&1 || true

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

define Package/$(PKG_NAME)/prerm
#!/bin/sh
[ -n "$$IPKG_INSTROOT" ] || {
	case "$$1" in
		upgrade|update) ;;
		*)
			BARRIER="/var/run/miclash/package-removal"
			[ -x /usr/share/miclash/package-remove ] || {
				echo "MiClash package removal protocol unavailable" >&2
				exit 1
			}
			/usr/share/miclash/package-remove || exit 1
			;;
	esac
}
exit 0
endef

define Package/$(PKG_NAME)/postrm
#!/bin/sh
[ -n "$$IPKG_INSTROOT" ] || {
	HARD_REINSTALL=0
	if [ -f /tmp/miclash-hard-reinstall ]; then
		rm -f /tmp/miclash-hard-reinstall
		HARD_REINSTALL=1
	fi

	is_pkg_installed() {
		if [ -x /usr/bin/apk ] || [ -x /bin/apk ]; then
			APK_BIN="/usr/bin/apk"
			[ -x "$$APK_BIN" ] || APK_BIN="/bin/apk"
			"$$APK_BIN" info -e luci-app-miclash >/dev/null 2>&1 && return 0
		fi
		if [ -x /bin/opkg ] || [ -x /usr/bin/opkg ]; then
			OPKG_BIN="/bin/opkg"
			[ -x "$$OPKG_BIN" ] || OPKG_BIN="/usr/bin/opkg"
			"$$OPKG_BIN" list-installed luci-app-miclash >/dev/null 2>&1 && return 0
		fi
		return 1
	}

	rm -rf /opt/clash/ui
	rm -f /opt/clash/ruleset
	rm -f /opt/clash/.dns_backup
	rm -rf /tmp/clash
	rm -rf /tmp/miclash-autoupdate
	rm -rf /tmp/miclash-memory-guard
	rm -rf /www/luci-static/resources/view/miclash
	rm -f /usr/lib/lua/luci/i18n/miclash.*.lmo
	rm -f /opt/clash/.config.yaml.upgrade.bak
	rm -f /opt/clash/.settings.upgrade.bak
	rm -f /etc/hotplug.d/iface/40-clash
	rm -f /etc/hotplug.d/net/99-clash-tun
	rm -f /opt/clash/bin/clash-rules
	rm -f /etc/init.d/clash
	rm -f /etc/init.d/miclash-autoupdate
	rm -f /etc/init.d/miclash-memory-guard
	rm -f /etc/apk/protected_paths.d/miclash.list
	case "$$1" in
		upgrade|update) ;;
		*)
			BARRIER="/var/run/miclash/package-removal"
			RELEASE_DIR="/var/run/miclash/package-removal-release"
			RELEASE_CLEANUP="$$RELEASE_DIR.cleanup"
			RELEASE_DONE="$$RELEASE_DIR.done"

			valid_release_proof() {
				[ ! -L "$$1" ] && [ -f "$$1" ] && \
					[ "$$(stat -c '%u:%a' "$$1" 2>/dev/null)" = '0:600' ] && \
					[ "$$(cat "$$1" 2>/dev/null)" = complete ]
			}

			finish_release_cleanup() {
				if [ -e "$$RELEASE_CLEANUP" ] || [ -L "$$RELEASE_CLEANUP" ]; then
					[ ! -L "$$RELEASE_CLEANUP" ] && [ -d "$$RELEASE_CLEANUP" ] && \
						[ "$$(stat -c '%u:%a' "$$RELEASE_CLEANUP" 2>/dev/null)" = '0:700' ] || return 1
					if [ -e "$$RELEASE_DONE" ] || [ -L "$$RELEASE_DONE" ]; then
						valid_release_proof "$$RELEASE_DONE" || return 1
						[ ! -e "$$RELEASE_CLEANUP/complete" ] && [ ! -L "$$RELEASE_CLEANUP/complete" ] || return 1
					else
						valid_release_proof "$$RELEASE_CLEANUP/complete" || return 1
					fi
					for item in "$$RELEASE_CLEANUP"/*; do
						[ -e "$$item" ] || [ -L "$$item" ] || continue
						case "$$item" in
							"$$RELEASE_CLEANUP/complete"|"$$RELEASE_CLEANUP/helper"|\
							"$$RELEASE_CLEANUP/pending"|"$$RELEASE_CLEANUP/barrier-complete.hold") ;;
							*) return 1 ;;
						esac
					done
					rm -f "$$RELEASE_CLEANUP/pending" "$$RELEASE_CLEANUP/helper" \
						"$$RELEASE_CLEANUP/barrier-complete.hold" || return 1
					if [ ! -e "$$RELEASE_DONE" ] && [ ! -L "$$RELEASE_DONE" ]; then
						mv "$$RELEASE_CLEANUP/complete" "$$RELEASE_DONE" || return 1
					fi
					rmdir "$$RELEASE_CLEANUP" || return 1
				fi
				valid_release_proof "$$RELEASE_DONE"
			}

			if [ -e "$$RELEASE_CLEANUP" ] || [ -L "$$RELEASE_CLEANUP" ] || \
			   [ -e "$$RELEASE_DONE" ] || [ -L "$$RELEASE_DONE" ]; then
				finish_release_cleanup || {
					echo "MiClash package removal local cleanup remains retryable" >&2
					exit 1
				}
			else
				BARRIER_PROOF_OK=0
				if [ "$$(stat -c '%u:%a' "$$BARRIER" 2>/dev/null)" = '0:700' ]; then
					if valid_release_proof "$$BARRIER/complete" && \
					   [ ! -e "$$RELEASE_DIR/barrier-complete.hold" ] && [ ! -L "$$RELEASE_DIR/barrier-complete.hold" ]; then
						BARRIER_PROOF_OK=1
					elif [ ! -e "$$BARRIER/complete" ] && [ ! -L "$$BARRIER/complete" ] && \
					     valid_release_proof "$$RELEASE_DIR/barrier-complete.hold"; then
						BARRIER_PROOF_OK=1
					fi
				elif [ ! -e "$$BARRIER" ] && [ ! -L "$$BARRIER" ] && \
				     valid_release_proof "$$RELEASE_DIR/barrier-complete.hold"; then
					BARRIER_PROOF_OK=1
				fi
				if [ "$$BARRIER_PROOF_OK" = 1 ] && \
				[ "$$(stat -c '%u:%a' "$$RELEASE_DIR" 2>/dev/null)" = '0:700' ] && \
				[ "$$(stat -c '%u:%a' "$$RELEASE_DIR/complete" 2>/dev/null)" = '0:600' ] && \
				[ "$$(stat -c '%u:%a' "$$RELEASE_DIR/helper" 2>/dev/null)" = '0:700' ] && \
				[ ! -e /var/run/miclash/routing-ownership.json ] && \
				[ ! -e /opt/clash/bin/clash-rules ] && \
				[ ! -e /opt/clash/bin/miclash-update ] && \
				[ ! -e /opt/clash/bin/miclash-service ] && \
				[ ! -e /opt/clash/bin/miclash-autoupdate ] && \
				[ ! -e /opt/clash/bin/miclash-memory-guard ] && \
				[ ! -e /etc/init.d/clash ] && \
				[ ! -e /etc/init.d/miclash-autoupdate ] && \
				[ ! -e /etc/init.d/miclash-memory-guard ] && \
				[ ! -e /etc/init.d/miclash-guard ] && \
				[ ! -e /etc/hotplug.d/iface/40-clash ] && \
				[ ! -e /etc/hotplug.d/net/99-clash-tun ] && \
				[ ! -e /usr/share/miclash/routing.uc ] && \
				[ ! -e /usr/share/miclash/routing-cleanup.uc ] && \
				[ ! -e /usr/share/miclash/guard.uc ] && \
				[ ! -e /usr/share/miclash/guard-bootstrap.uc ] && \
				[ ! -e /usr/share/miclash/package-remove ] && \
				[ ! -e /usr/share/miclash/package-release ]; then
					"$$RELEASE_DIR/helper" "$$RELEASE_DIR" || {
						echo "MiClash package removal barrier remains active; retry postrm" >&2
						exit 1
					}
					[ ! -e "$$BARRIER" ] && [ ! -L "$$BARRIER" ] || exit 1
					rm -f /etc/miclash/guard-bootstrap.json /var/run/miclash/guard-bootstrap.json || exit 1
					[ ! -e "$$RELEASE_CLEANUP" ] && [ ! -L "$$RELEASE_CLEANUP" ] || exit 1
					mv "$$RELEASE_DIR" "$$RELEASE_CLEANUP" || {
						echo "MiClash package removal release authority remains retryable" >&2
						exit 1
					}
					finish_release_cleanup || {
						echo "MiClash package removal local cleanup remains retryable" >&2
						exit 1
					}
				else
					echo "MiClash package removal release proof is incomplete" >&2
					exit 1
				fi
			fi
			;;
	esac

	# Preserve the manually installed core on ordinary upgrades. An explicit
	# hard reinstall intentionally starts over without it.
	case "$$1" in
		upgrade|update)
			if [ "$$HARD_REINSTALL" = "1" ]; then
				rm -f /opt/clash/bin/clash || exit 1
			fi
			;;
		*)
			if [ "$$HARD_REINSTALL" = "1" ] || ! is_pkg_installed; then
				rm -f /opt/clash/bin/clash || exit 1
			fi
			;;
	esac

	# This is the terminal fallible operation for ordinary removal. Every prior
	# cleanup, including optional core removal, runs while the final proof is
	# retained. A failed unlink leaves the proof for the next actual postrm.
	case "$$1" in
		upgrade|update) ;;
		*)
			valid_release_proof "$$RELEASE_DONE" || exit 1
			rm -f "$$RELEASE_DONE" || exit 1
			;;
	esac
}
endef

$(eval $(call BuildPackage,$(PKG_NAME)))
