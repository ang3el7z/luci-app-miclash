#!/bin/sh
# ================================================================
#  MiClash Auto-Installer for OpenWrt
#  Supported: 21.x / 23.05.x / 24.10.x / 25.12.x
#  Installs:
#  - MiClash package from GitHub Releases
#  - required dependencies
#  - latest Mihomo core matching the router architecture
# ================================================================

MICLASH_API="https://api.github.com/repos/ang3el7z/luci-app-miclash/releases/latest"
MIHOMO_BASE="https://github.com/MetaCubeX/mihomo/releases"
MIHOMO_API="https://api.github.com/repos/MetaCubeX/mihomo/releases/latest"
CLASH_BIN="/opt/clash/bin/clash"
MICLASH_APK_URL=""
MICLASH_IPK_URL=""
MICLASH_VER=""
MICLASH_INSTALLED_VER=""
MICLASH_RELEASE_NORM=""
MICLASH_INSTALLED_NORM=""
INSTALL_ACTION=""
PKG_UPDATED=0

if [ -t 1 ] && [ "${TERM:-dumb}" != "dumb" ]; then
    R=$(printf '\033[0;31m') G=$(printf '\033[0;32m') Y=$(printf '\033[1;33m')
    C=$(printf '\033[0;36m') B=$(printf '\033[1m') N=$(printf '\033[0m')
else
    R='' G='' Y='' C='' B='' N=''
fi

log()  { printf "%s[+]%s %s\n" "$G" "$N" "$*"; }
info() { printf "%s[i]%s %s\n" "$C" "$N" "$*"; }
warn() { printf "%s[!]%s %s\n" "$Y" "$N" "$*"; }
die()  { printf "%s[✗] %s%s\n" "$R" "$*" "$N" >&2; exit 1; }
sep()  { printf "%s%s%s\n" "$C" "────────────────────────────────────────" "$N"; }

normalize_version() {
    printf '%s' "$1" | sed 's/^v//; s/-r[0-9][0-9]*$//'
}

detect_openwrt() {
    [ -f /etc/openwrt_release ] || die "Не найден /etc/openwrt_release"
    . /etc/openwrt_release

    OW_RELEASE="${DISTRIB_RELEASE:-unknown}"
    OW_MAJOR=$(echo "$OW_RELEASE" | cut -d. -f1)
    ARCH_PKG="${DISTRIB_ARCH:-}"

    info "OpenWrt: ${B}${OW_RELEASE}${N}"
    info "DISTRIB_ARCH: ${B}${ARCH_PKG}${N}"

    # Detect the package manager by the actual installed binary. This is more
    # reliable than DISTRIB_RELEASE because modern SNAPSHOT builds can report
    # "SNAPSHOT" while already using apk.
    if command -v apk >/dev/null 2>&1; then
        PKG_MGR="apk"
    elif command -v opkg >/dev/null 2>&1; then
        PKG_MGR="opkg"
    elif [ "${OW_MAJOR:-0}" -ge 25 ] 2>/dev/null; then
        PKG_MGR="apk"
    else
        PKG_MGR="opkg"
    fi
    info "Package manager: ${B}${PKG_MGR}${N}"

    if [ "${OW_MAJOR:-0}" -le 21 ] 2>/dev/null; then
        TPROXY_PKG="iptables-mod-tproxy"
        NAT_PKG="kmod-ipt-nat"
    else
        TPROXY_PKG="kmod-nft-tproxy"
        NAT_PKG="kmod-nft-nat"
    fi

    info "Transparent proxy pkg: ${B}${TPROXY_PKG}${N}"
}

ensure_curl() {
    if command -v curl >/dev/null 2>&1; then
        info "curl: already installed"
        return 0
    fi

    warn "curl not found, installing..."
    if [ "$PKG_MGR" = "apk" ]; then
        apk update || die "apk update failed"
        apk add curl || die "curl install failed"
    else
        opkg update || die "opkg update failed"
        opkg install curl || die "curl install failed"
    fi
    command -v curl >/dev/null 2>&1 || die "curl still unavailable after install"
    PKG_UPDATED=1
}

pkg_update() {
    if [ "$PKG_UPDATED" = "1" ]; then
        info "Package index already updated"
        return 0
    fi

    log "Updating package index..."
    if [ "$PKG_MGR" = "apk" ]; then
        apk update || die "apk update failed"
    else
        opkg update || die "opkg update failed"
    fi
    PKG_UPDATED=1
}

install_deps() {
    log "Installing dependencies..."
    if [ "$PKG_MGR" = "apk" ]; then
        apk add zlib libcurl4 curl "$TPROXY_PKG" "$NAT_PKG" kmod-tun coreutils-base64 \
            || die "Dependency installation failed"
    else
        opkg install zlib libcurl4 curl "$TPROXY_PKG" "$NAT_PKG" kmod-tun coreutils-base64 \
            || die "Dependency installation failed"
    fi
}

detect_arch() {
    ARCH_RAW=$(uname -m)
    MIHOMO_ARCH=""

    case "$ARCH_PKG" in
        aarch64_*)      MIHOMO_ARCH="arm64" ;;
        x86_64)         MIHOMO_ARCH="amd64-compatible" ;;
        i386_*)         MIHOMO_ARCH="386" ;;
        riscv64_*)      MIHOMO_ARCH="riscv64" ;;
        loongarch64_*)  MIHOMO_ARCH="loong64" ;;
        arm_*)
            case "$ARCH_PKG" in
                *cortex-a*)      MIHOMO_ARCH="armv7" ;;
                *_neon-vfp*)     MIHOMO_ARCH="armv7" ;;
                *_neon*|*_vfp*)  MIHOMO_ARCH="armv6" ;;
                *)               MIHOMO_ARCH="armv5" ;;
            esac
            ;;
        mips64el_*)     MIHOMO_ARCH="mips64le" ;;
        mips64_*)       MIHOMO_ARCH="mips64" ;;
        mipsel_*)
            case "$ARCH_PKG" in
                *hardfloat*) MIHOMO_ARCH="mipsle-hardfloat" ;;
                *)           MIHOMO_ARCH="mipsle-softfloat" ;;
            esac
            ;;
        mips_*)
            case "$ARCH_PKG" in
                *hardfloat*) MIHOMO_ARCH="mips-hardfloat" ;;
                *)           MIHOMO_ARCH="mips-softfloat" ;;
            esac
            ;;
    esac

    if [ -z "$MIHOMO_ARCH" ]; then
        case "$ARCH_RAW" in
            aarch64)         MIHOMO_ARCH="arm64" ;;
            armv7l)          MIHOMO_ARCH="armv7" ;;
            armv6l)          MIHOMO_ARCH="armv6" ;;
            armv5l|armv5tel) MIHOMO_ARCH="armv5" ;;
            x86_64)          MIHOMO_ARCH="amd64-compatible" ;;
            i686|i386)       MIHOMO_ARCH="386" ;;
            riscv64)         MIHOMO_ARCH="riscv64" ;;
            loongarch64)     MIHOMO_ARCH="loong64" ;;
            mips64el)        MIHOMO_ARCH="mips64le" ;;
            mips64)          MIHOMO_ARCH="mips64" ;;
            mipsel)          MIHOMO_ARCH="mipsle-softfloat" ;;
            mips)            MIHOMO_ARCH="mips-softfloat" ;;
        esac
    fi

    [ -n "$MIHOMO_ARCH" ] || die "Не удалось определить архитектуру Mihomo"
    info "Mihomo arch: ${B}${MIHOMO_ARCH}${N}"
}

fetch_miclash_release() {
    log "Fetching latest MiClash release..."

    RELEASE_JSON=$(curl -fsSL "$MICLASH_API") || die "Failed to fetch MiClash release data"
    [ -n "$RELEASE_JSON" ] || die "MiClash release API returned empty response"

    MICLASH_VER=$(printf '%s' "$RELEASE_JSON" \
        | grep '"tag_name"' | head -1 \
        | sed 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\([^"]*\)".*/\1/')
    [ -n "$MICLASH_VER" ] || die "Failed to parse MiClash version"

    MICLASH_APK_URL=$(printf '%s' "$RELEASE_JSON" \
        | grep '"browser_download_url"' \
        | grep 'luci-app-miclash-.*\.apk"' | head -1 \
        | sed 's/.*"browser_download_url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')

    MICLASH_IPK_URL=$(printf '%s' "$RELEASE_JSON" \
        | grep '"browser_download_url"' \
        | grep 'luci-app-miclash_.*\.ipk"' | head -1 \
        | sed 's/.*"browser_download_url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')

    info "Latest MiClash: ${B}v${MICLASH_VER}${N}"
    MICLASH_RELEASE_NORM=$(normalize_version "$MICLASH_VER")

    if [ "$PKG_MGR" = "apk" ]; then
        [ -n "$MICLASH_APK_URL" ] || die "No MiClash .apk asset found in latest release"
        info "Package asset: ${B}${MICLASH_APK_URL##*/}${N}"
    else
        [ -n "$MICLASH_IPK_URL" ] || die "No MiClash .ipk asset found in latest release"
        info "Package asset: ${B}${MICLASH_IPK_URL##*/}${N}"
    fi
}

detect_installed_miclash() {
    MICLASH_INSTALLED_VER=""

    if [ "$PKG_MGR" = "apk" ]; then
        if apk info -e luci-app-miclash >/dev/null 2>&1; then
            MICLASH_INSTALLED_VER=$(apk info -v luci-app-miclash 2>/dev/null \
                | sed -n '1s/^luci-app-miclash-//p')
        fi
    else
        MICLASH_INSTALLED_VER=$(opkg list-installed luci-app-miclash 2>/dev/null | awk 'NR==1 {print $3}')
    fi

    MICLASH_INSTALLED_NORM=$(normalize_version "$MICLASH_INSTALLED_VER")

    if [ -n "$MICLASH_INSTALLED_VER" ]; then
        info "Installed MiClash: ${B}${MICLASH_INSTALLED_VER}${N}"
    else
        info "Installed MiClash: ${B}not found${N}"
    fi
}

choose_install_action() {
    INSTALL_ACTION="install"

    [ -n "$MICLASH_INSTALLED_VER" ] || return 0

    if [ -t 0 ] && [ -t 1 ]; then
        echo ""
        warn "Обнаружена установленная MiClash: ${MICLASH_INSTALLED_VER}"
        printf "Выбери действие: [u]pdate [r]einstall [d]elete [s]kip (default: %s): " \
            "$( [ "$MICLASH_INSTALLED_NORM" = "$MICLASH_RELEASE_NORM" ] && printf 'skip' || printf 'update' )"
        read action

        case "${action:-}" in
            u|U) INSTALL_ACTION="update" ;;
            r|R) INSTALL_ACTION="reinstall" ;;
            d|D) INSTALL_ACTION="remove" ;;
            s|S) INSTALL_ACTION="skip" ;;
            "")
                if [ "$MICLASH_INSTALLED_NORM" = "$MICLASH_RELEASE_NORM" ]; then
                    INSTALL_ACTION="skip"
                else
                    INSTALL_ACTION="update"
                fi
                ;;
            *)
                warn "Неизвестный выбор, использую безопасный вариант"
                if [ "$MICLASH_INSTALLED_NORM" = "$MICLASH_RELEASE_NORM" ]; then
                    INSTALL_ACTION="skip"
                else
                    INSTALL_ACTION="update"
                fi
                ;;
        esac
    else
        if [ "$MICLASH_INSTALLED_NORM" = "$MICLASH_RELEASE_NORM" ]; then
            INSTALL_ACTION="skip"
        else
            INSTALL_ACTION="update"
        fi
        info "Non-interactive mode: action=${INSTALL_ACTION}"
    fi
}

remove_miclash() {
    log "Removing MiClash package..."

    if [ -x /etc/init.d/clash ]; then
        /etc/init.d/clash stop >/dev/null 2>&1 || warn "Failed to stop clash service"
        /etc/init.d/clash disable >/dev/null 2>&1 || warn "Failed to disable clash service"
    fi

    if [ "$PKG_MGR" = "apk" ]; then
        apk del luci-app-miclash || die "Failed to remove MiClash package"
    else
        opkg remove luci-app-miclash || die "Failed to remove MiClash package"
    fi

    if [ -t 0 ] && [ -t 1 ]; then
        printf "Удалить runtime/config dir /opt/clash тоже? [y/N]: "
        read purge_runtime
        case "${purge_runtime:-}" in
            y|Y)
                rm -rf /opt/clash
                log "Removed /opt/clash"
                ;;
            *)
                info "Kept /opt/clash"
                ;;
        esac
    else
        info "Kept /opt/clash (non-interactive mode)"
    fi
}

install_miclash() {
    case "$INSTALL_ACTION" in
        update)    log "Updating MiClash to v${MICLASH_VER}..." ;;
        reinstall) log "Reinstalling MiClash v${MICLASH_VER}..." ;;
        *)         log "Installing MiClash v${MICLASH_VER}..." ;;
    esac

    if [ "$PKG_MGR" = "apk" ]; then
        PKG_FILE="/tmp/luci-app-miclash.apk"
        curl -fL --retry 2 --connect-timeout 15 --max-time 300 \
            "$MICLASH_APK_URL" -o "$PKG_FILE" || die "Failed to download MiClash .apk"
        if [ "$INSTALL_ACTION" = "reinstall" ]; then
            apk add "$PKG_FILE" --allow-untrusted --force-overwrite \
                || die "Failed to reinstall MiClash .apk"
        else
            apk add "$PKG_FILE" --allow-untrusted || die "Failed to install MiClash .apk"
        fi
        rm -f "$PKG_FILE"
    else
        PKG_FILE="/tmp/luci-app-miclash.ipk"
        curl -fL --retry 2 --connect-timeout 15 --max-time 300 \
            "$MICLASH_IPK_URL" -o "$PKG_FILE" || die "Failed to download MiClash .ipk"
        if [ "$INSTALL_ACTION" = "reinstall" ]; then
            opkg install --force-reinstall "$PKG_FILE" || die "Failed to reinstall MiClash .ipk"
        else
            opkg install "$PKG_FILE" || die "Failed to install MiClash .ipk"
        fi
        rm -f "$PKG_FILE"
    fi
}

install_mihomo() {
    log "Fetching latest Mihomo release..."
    MIHOMO_JSON=$(curl -fsSL "$MIHOMO_API") || die "Failed to fetch Mihomo release data"
    [ -n "$MIHOMO_JSON" ] || die "Mihomo release API returned empty response"

    MIHOMO_VER=$(printf '%s' "$MIHOMO_JSON" \
        | grep '"tag_name"' | head -1 \
        | sed 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
    [ -n "$MIHOMO_VER" ] || die "Failed to parse Mihomo version"

    MIHOMO_URL="${MIHOMO_BASE}/download/${MIHOMO_VER}/mihomo-linux-${MIHOMO_ARCH}-${MIHOMO_VER}.gz"
    info "Latest Mihomo: ${B}${MIHOMO_VER}${N}"
    info "Kernel URL: ${MIHOMO_URL}"

    curl -fL --retry 2 --connect-timeout 15 --max-time 300 \
        "$MIHOMO_URL" -o /tmp/clash.gz || die "Failed to download Mihomo kernel"

    mkdir -p "$(dirname "$CLASH_BIN")"
    gunzip -c /tmp/clash.gz > "$CLASH_BIN" || die "Failed to unpack Mihomo kernel"
    chmod +x "$CLASH_BIN" || die "Failed to chmod Mihomo kernel"
    rm -f /tmp/clash.gz
    rm -f /opt/clash/bin/meta-backup 2>/dev/null

    VERSION_OUT=$("$CLASH_BIN" -v 2>/dev/null || true)
    if [ -n "$VERSION_OUT" ]; then
        log "Installed Mihomo: $VERSION_OUT"
    else
        log "Installed Mihomo core"
    fi
}

main() {
    sep
    printf "  %sMiClash Auto-Installer%s\n" "$B" "$N"
    sep

    detect_openwrt
    ensure_curl
    detect_arch
    fetch_miclash_release
    detect_installed_miclash
    choose_install_action
    sep

    if [ "$INSTALL_ACTION" = "skip" ]; then
        log "MiClash already up to date, nothing to do"
        exit 0
    fi

    if [ "$INSTALL_ACTION" = "remove" ]; then
        remove_miclash
        sep
        log "Removal complete"
        exit 0
    fi

    pkg_update
    sep

    install_deps
    sep

    CLASH_WAS_ENABLED=0
    if [ -x /etc/init.d/clash ] && /etc/init.d/clash enabled 2>/dev/null; then
        CLASH_WAS_ENABLED=1
        info "clash service was enabled before update"
    fi

    install_miclash

    if [ "$CLASH_WAS_ENABLED" = "1" ] && [ -x /etc/init.d/clash ]; then
        log "Restoring clash service enable state..."
        /etc/init.d/clash enable || warn "Failed to re-enable clash service"
    fi
    sep

    if [ -x /etc/init.d/clash ] && pidof clash >/dev/null 2>&1; then
        warn "Stopping running clash service before Mihomo install..."
        /etc/init.d/clash stop || warn "Failed to stop clash before Mihomo update"
    fi

    install_mihomo
    sep

    log "Installation complete"
    echo ""
    info "Next steps:"
    echo "  1. Open LuCI -> Services -> MiClash"
    echo "  2. Add your Mihomo/Clash config or subscription"
    echo "  3. Save config and start the service"
    echo ""
    info "If Mihomo arch detection failed in your environment:"
    info "  ${MIHOMO_BASE}/latest"
    sep
}

main "$@"
