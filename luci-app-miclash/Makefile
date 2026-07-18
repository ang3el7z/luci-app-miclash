# Copyright 2024-2026 ZeroChaos (https://github.com/zerolabnet/SSClash)
# This is free software, licensed under the GNU General Public License v2.

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-miclash
PKG_VERSION:=2.0.2
PKG_RELEASE:=1
PKG_MAINTAINER:=ang3el7z

LUCI_TITLE:=LuCI Support for MiClash
LUCI_DEPENDS:=+luci-base +zlib +libcurl +curl +coreutils-base64 +coreutils-stat +ip-full +kmod-tun +kmod-nft-tproxy \
	+nftables +coreutils-timeout +ucode +ucode-mod-fs +ucode-mod-math \
	+ucode-mod-digest +ucode-mod-socket +ucode-mod-ubus +ucode-mod-uci +ucode-mod-uloop
LUCI_PKGARCH:=all

PKG_CONFIG_DEPENDS:= \
	CONFIG_PACKAGE_$(PKG_NAME)_Iptables_Transparent_Proxy \
	CONFIG_PACKAGE_$(PKG_NAME)_Nftables_Transparent_Proxy

PKG_BUILD_DEPENDS:=luci-base/host

MICLASH_PACKAGE_UCODE:=$(wildcard ./rootfs/usr/share/miclash/*.uc)
MICLASH_PACKAGE_FIREWALL_UCODE:=$(wildcard ./rootfs/usr/share/miclash/firewall/*.uc)

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
/etc/config/miclash
endef

define Package/$(PKG_NAME)/install
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./rootfs/etc/init.d/clash $(1)/etc/init.d/
	$(INSTALL_BIN) ./rootfs/etc/init.d/miclash-guard $(1)/etc/init.d/
	$(INSTALL_BIN) ./rootfs/etc/init.d/miclashd $(1)/etc/init.d/
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./rootfs/etc/config/miclash $(1)/etc/config/
	chmod 0600 $(1)/etc/config/miclash
	$(INSTALL_DIR) $(1)/etc/iproute2/rt_protos.d
	$(INSTALL_DATA) ./rootfs/etc/iproute2/rt_protos.d/miclash.conf $(1)/etc/iproute2/rt_protos.d/
	$(INSTALL_DIR) $(1)/etc/iproute2/rt_tables.d
	$(INSTALL_DATA) ./rootfs/etc/iproute2/rt_tables.d/miclash.conf $(1)/etc/iproute2/rt_tables.d/

	$(INSTALL_DIR) $(1)/opt/clash
	$(INSTALL_DATA) ./rootfs/opt/clash/config.yaml $(1)/opt/clash/

	$(INSTALL_DIR) $(1)/opt/clash/ui
	$(CP) ./rootfs/opt/clash/ui/* $(1)/opt/clash/ui/

	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DATA) ./rootfs/usr/share/luci/menu.d/luci-app-miclash.json $(1)/usr/share/luci/menu.d/

	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./rootfs/usr/share/rpcd/acl.d/luci-app-miclash.json $(1)/usr/share/rpcd/acl.d/
	$(INSTALL_DIR) $(1)/usr/share/miclash
	$(INSTALL_DATA) $(MICLASH_PACKAGE_UCODE) $(1)/usr/share/miclash/
	printf '%s\n' '$(PKG_VERSION)' > $(1)/usr/share/miclash/version
	chmod 0644 $(1)/usr/share/miclash/version
	$(INSTALL_DIR) $(1)/usr/share/miclash/firewall
	$(INSTALL_DATA) $(MICLASH_PACKAGE_FIREWALL_UCODE) $(1)/usr/share/miclash/firewall/
	$(INSTALL_DIR) $(1)/etc/miclash
	chmod 0700 $(1)/etc/miclash
	$(INSTALL_DATA) ./rootfs/usr/share/miclash/mutation-lock.sh $(1)/usr/share/miclash/
	$(INSTALL_BIN) ./rootfs/usr/share/miclash/package-remove $(1)/usr/share/miclash/
	$(INSTALL_BIN) ./rootfs/usr/share/miclash/package-release $(1)/usr/share/miclash/
	$(INSTALL_DIR) $(1)/usr/libexec/miclash
	$(INSTALL_BIN) ./rootfs/usr/libexec/miclash/validate-config.uc $(1)/usr/libexec/miclash/
	$(INSTALL_BIN) ./rootfs/usr/libexec/miclash/decompress-gzip $(1)/usr/libexec/miclash/
	$(INSTALL_BIN) ./rootfs/usr/libexec/miclash/mihomo-https.uc $(1)/usr/libexec/miclash/
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) ./rootfs/usr/sbin/miclashd $(1)/usr/sbin/

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
ROOT="$${IPKG_INSTROOT:-}"
mkdir -p "$$ROOT/opt/clash" 2>/dev/null || true
mkdir -p "$$ROOT/etc/miclash" 2>/dev/null || exit 1
chmod 0700 "$$ROOT/etc/miclash" 2>/dev/null || exit 1
[ -f "$$ROOT/opt/clash/config.yaml" ] && cp -p "$$ROOT/opt/clash/config.yaml" \
	"$$ROOT/opt/clash/.config.yaml.upgrade.bak"
exit 0
endef

define Package/$(PKG_NAME)/postinst
#!/bin/sh
ROOT="$${IPKG_INSTROOT:-}"
if [ -f "$$ROOT/opt/clash/.config.yaml.upgrade.bak" ]; then
	mv "$$ROOT/opt/clash/.config.yaml.upgrade.bak" "$$ROOT/opt/clash/config.yaml"
	FIRST_INSTALL=0
else
	FIRST_INSTALL=1
fi
[ ! -f "$$ROOT/etc/config/miclash" ] || chmod 0600 "$$ROOT/etc/config/miclash" || exit 1
[ -n "$$IPKG_INSTROOT" ] || {
	/etc/init.d/rpcd reload
	/etc/init.d/miclash-guard enable 2>/dev/null || true
	/etc/init.d/miclash-guard start || exit 1
	/etc/init.d/miclashd enable || exit 1
	/etc/init.d/miclashd start || exit 1
	# Drop LuCI server-side caches so updated MiClash assets are used immediately.
	rm -rf /tmp/luci-indexcache* /tmp/luci-modulecache*

	# On first install the default config.yaml is just a usable example
	# (no real proxies configured). Prevent auto-start on next boot so the
	# user can edit /opt/clash/config.yaml first. "Start Service" in LuCI
	# re-enables it via `/etc/init.d/clash enable`.
	if [ "$$FIRST_INSTALL" = "1" ]; then
		/etc/init.d/clash disable 2>/dev/null || true
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
	HARD_REINSTALL_MARKER=/tmp/miclash-hard-reinstall
	if [ -e "$$HARD_REINSTALL_MARKER" ] || [ -L "$$HARD_REINSTALL_MARKER" ]; then
		if [ ! -L "$$HARD_REINSTALL_MARKER" ] && [ -f "$$HARD_REINSTALL_MARKER" ] && \
		   [ "$$(stat -c '%u:%a:%h' "$$HARD_REINSTALL_MARKER" 2>/dev/null)" = 0:600:1 ] && \
		   [ "$$(readlink -f "$$HARD_REINSTALL_MARKER" 2>/dev/null)" = "$$HARD_REINSTALL_MARKER" ]; then
			rm -f "$$HARD_REINSTALL_MARKER" || exit 1
			HARD_REINSTALL=1
		else
			rm -f "$$HARD_REINSTALL_MARKER" 2>/dev/null || true
			echo "Ignoring untrusted MiClash hard-reinstall marker" >&2
		fi
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
	rm -rf /tmp/clash
	rm -rf /www/luci-static/resources/view/miclash
	rm -f /usr/lib/lua/luci/i18n/miclash.*.lmo
	rm -f /opt/clash/.config.yaml.upgrade.bak
	rm -f /etc/init.d/clash
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

			valid_dns_release_proof() {
				[ ! -L "$$1" ] && [ -f "$$1" ] && \
					[ "$$(stat -c '%u:%a' "$$1" 2>/dev/null)" = '0:600' ] && \
					grep -Eq '"version"[[:space:]]*:[[:space:]]*1' "$$1" && \
					grep -Eq '"owner"[[:space:]]*:[[:space:]]*"miclash"' "$$1" && \
					grep -Eq '"state"[[:space:]]*:[[:space:]]*"clean"' "$$1" && \
					grep -Eq '"transition"[[:space:]]*:[[:space:]]*null' "$$1" && \
					grep -Eq '"clean"[[:space:]]*:[[:space:]]*\{' "$$1"
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
						valid_dns_release_proof "$$RELEASE_CLEANUP/dns-ownership.json" || return 1
					fi
					for item in "$$RELEASE_CLEANUP"/*; do
						[ -e "$$item" ] || [ -L "$$item" ] || continue
						case "$$item" in
							"$$RELEASE_CLEANUP/complete"|"$$RELEASE_CLEANUP/helper"|\
							"$$RELEASE_CLEANUP/pending"|"$$RELEASE_CLEANUP/barrier-complete.hold"|\
							"$$RELEASE_CLEANUP/dns-ownership.json") ;;
							*) return 1 ;;
						esac
					done
					if [ ! -e "$$RELEASE_DONE" ] && [ ! -L "$$RELEASE_DONE" ]; then
						# Commit the durable terminal proof before any fallible local
						# debris deletion. A retry can then finish from RELEASE_DONE.
						mv "$$RELEASE_CLEANUP/complete" "$$RELEASE_DONE" || return 1
					fi
					rm -f "$$RELEASE_CLEANUP/pending" "$$RELEASE_CLEANUP/helper" \
						"$$RELEASE_CLEANUP/barrier-complete.hold" \
						"$$RELEASE_CLEANUP/dns-ownership.json" || return 1
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
				valid_dns_release_proof "$$RELEASE_DIR/dns-ownership.json" && \
				[ ! -e /var/run/miclash/routing-ownership.json ] && [ ! -L /var/run/miclash/routing-ownership.json ] && \
				[ ! -e /etc/miclash/dns-ownership.json ] && [ ! -L /etc/miclash/dns-ownership.json ] && \
				[ ! -e /etc/init.d/clash ] && [ ! -L /etc/init.d/clash ] && \
				[ ! -e /etc/init.d/miclashd ] && [ ! -L /etc/init.d/miclashd ] && \
				[ ! -e /usr/sbin/miclashd ] && [ ! -L /usr/sbin/miclashd ] && \
				[ ! -e /etc/init.d/miclash-guard ] && [ ! -L /etc/init.d/miclash-guard ] && \
				[ ! -e /usr/share/miclash/routing.uc ] && [ ! -L /usr/share/miclash/routing.uc ] && \
				[ ! -e /usr/share/miclash/routing-cleanup.uc ] && [ ! -L /usr/share/miclash/routing-cleanup.uc ] && \
				[ ! -e /usr/share/miclash/dns.uc ] && [ ! -L /usr/share/miclash/dns.uc ] && \
				[ ! -e /usr/share/miclash/dns-control.uc ] && [ ! -L /usr/share/miclash/dns-control.uc ] && \
				[ ! -e /usr/share/miclash/dns-cleanup.uc ] && [ ! -L /usr/share/miclash/dns-cleanup.uc ] && \
				[ ! -e /usr/share/miclash/guard.uc ] && [ ! -L /usr/share/miclash/guard.uc ] && \
				[ ! -e /usr/share/miclash/guard-bootstrap.uc ] && [ ! -L /usr/share/miclash/guard-bootstrap.uc ] && \
				[ ! -e /usr/share/miclash/guard_runtime.uc ] && [ ! -L /usr/share/miclash/guard_runtime.uc ] && \
				[ ! -e /usr/share/miclash/guard-runtime.uc ] && [ ! -L /usr/share/miclash/guard-runtime.uc ] && \
				[ ! -e /usr/share/miclash/package-remove ] && [ ! -L /usr/share/miclash/package-remove ] && \
				[ ! -e /usr/share/miclash/package-release ] && [ ! -L /usr/share/miclash/package-release ]; then
					"$$RELEASE_DIR/helper" "$$RELEASE_DIR" || {
						echo "MiClash package removal barrier remains active; retry postrm" >&2
						exit 1
					}
					[ ! -e "$$BARRIER" ] && [ ! -L "$$BARRIER" ] || exit 1
					rm -f /etc/miclash/guard-bootstrap.json /var/run/miclash/guard-bootstrap.json \
						/etc/miclash/guard-safety-latch || exit 1
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
