#!/bin/sh
# ================================================================
#  MiClash Auto-Installer for OpenWrt
#  Supported: OpenWrt 24.10 and newer, including modern SNAPSHOT builds
#  Installs:
#  - MiClash package from GitHub Releases
#  - required dependencies
#  - latest Mihomo core matching the router architecture
# ================================================================

MICLASH_RELEASES_API="https://api.github.com/repos/ang3el7z/luci-app-miclash/releases?per_page=20"
MICLASH_TAG_API="https://api.github.com/repos/ang3el7z/luci-app-miclash/releases/tags"
MIHOMO_BASE="https://github.com/MetaCubeX/mihomo/releases"
MIHOMO_API="https://api.github.com/repos/MetaCubeX/mihomo/releases/latest"
CLASH_BIN="/opt/clash/bin/clash"
MICLASH_APK_URL=""
MICLASH_IPK_URL=""
MICLASH_APK_SHA256_URL=""
MICLASH_IPK_SHA256_URL=""
MICLASH_VER=""
MICLASH_TAG_NAME=""
MICLASH_TARGET_TAG=""
MICLASH_CLEAN_INSTALL_PROTOCOL="miclash-clean-install-v2"
MICLASH_TEST_FIXTURE_DIR=""
MICLASH_CATALOG_FILE=""
MICLASH_FETCHED_FILE=""
MICLASH_INSTALLED_VER=""
MICLASH_RELEASE_NORM=""
MICLASH_INSTALLED_NORM=""
INSTALL_ACTION=""
PKG_UPDATED=0
STATUS_FILE=""
STATUS_TARGET_VERSION=""
CURRENT_TOKEN="${CURRENT_TOKEN:-}"
CURL_CONNECT_TIMEOUT=15
CURL_MAX_TIME=300
PKG_FILE=""
TEMP_FILES=""
TEMP_DIRS=""
WORK_DIR=""
OWNED_MARKERS=""
NO_AUTOSTART_CLASH_MARKER="/tmp/miclash-package-no-autostart-clash"
NO_AUTOSTART_AUTOUPDATE_MARKER="/tmp/miclash-package-no-autostart-autoupdate"
HARD_REINSTALL_MARKER="/tmp/miclash-hard-reinstall"
if [ -t 1 ] && [ "${TERM:-dumb}" != "dumb" ]; then
    R=$(printf '\033[0;31m') G=$(printf '\033[0;32m') Y=$(printf '\033[1;33m')
    C=$(printf '\033[0;36m') B=$(printf '\033[1m') N=$(printf '\033[0m')
else
    R='' G='' Y='' C='' B='' N=''
fi

log()  { printf "%s[+]%s %s\n" "$G" "$N" "$*"; }
info() { printf "%s[i]%s %s\n" "$C" "$N" "$*"; }
warn() { printf "%s[!]%s %s\n" "$Y" "$N" "$*"; }
die()  { write_status failed error "ERROR: $*" 2>/dev/null || true; printf "%s[✗] %s%s\n" "$R" "$*" "$N" >&2; exit 1; }
sep()  { printf "%s%s%s\n" "$C" "────────────────────────────────────────" "$N"; }

status_text() {
    printf '%s' "$*" | tr '\r\n' '  '
}

write_status() {
    [ -n "$STATUS_FILE" ] || return 0
    state="$1"
    phase="$2"
    case "$state:$phase" in
        running:queued|running:dependencies|running:download|running:install|success:done|failed:error) ;;
        *) return 1 ;;
    esac
    validate_status_authority || return 1
    updated_at="$(date +%s 2>/dev/null || true)"
    case "$updated_at" in ''|*[!0-9]*) return 1 ;; esac
    tmp="$STATUS_FILE.tmp.$$"
    [ ! -e "$tmp" ] && [ ! -L "$tmp" ] || return 1
    (
        umask 077
        set -C
        exec 3> "$tmp"
        printf 'protocol=miclash-update-status-v1\n' >&3
        printf 'token=%s\n' "$CURRENT_TOKEN" >&3
        printf 'state=%s\n' "$state" >&3
        printf 'phase=%s\n' "$phase" >&3
        printf 'target_version=%s\n' "$STATUS_TARGET_VERSION" >&3
        printf 'updated_at=%s\n' "$updated_at" >&3
        exec 3>&-
        chmod 0600 "$tmp"
    ) || { rm -f "$tmp" 2>/dev/null || true; return 1; }
    mv "$tmp" "$STATUS_FILE" || { rm -f "$tmp" 2>/dev/null || true; return 1; }
    [ ! -L "$STATUS_FILE" ] && [ -f "$STATUS_FILE" ] &&
        owned_file_0600 "$STATUS_FILE"
}

validate_status_authority() {
    [ -n "$STATUS_FILE" ] && [ -n "$CURRENT_TOKEN" ] &&
        [ -n "$STATUS_TARGET_VERSION" ] || return 1
    case "$STATUS_FILE" in /tmp/miclash/updates/handoff-*.status) ;; *) return 1 ;; esac
    status_dir="${STATUS_FILE%/*}"
    [ "$status_dir" = /tmp/miclash/updates ] || return 1
    [ ! -L "$status_dir" ] && [ -d "$status_dir" ] || return 1
    owned_directory_0700 "$status_dir" || return 1
    [ "$(readlink -f "$status_dir" 2>/dev/null)" = "$status_dir" ] || return 1
    status_name="${STATUS_FILE##*/}"
    operation="${status_name#handoff-}"
    operation="${operation%.status}"
    printf '%s\n' "$operation" | grep -Eq '^[0-9]{13}-[0-9]{8}-[0-9a-f]{16}$' || return 1
    printf '%s\n' "$CURRENT_TOKEN" | grep -Eq '^[0-9a-f]{32}$' || return 1
    printf '%s\n' "$STATUS_TARGET_VERSION" |
        grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z][0-9A-Za-z.-]*)?$' || return 1
    if [ -e "$STATUS_FILE" ] || [ -L "$STATUS_FILE" ]; then
        [ ! -L "$STATUS_FILE" ] && [ -f "$STATUS_FILE" ] || return 1
        owned_file_0600 "$STATUS_FILE" || return 1
        [ "$(readlink -f "$STATUS_FILE" 2>/dev/null)" = "$STATUS_FILE" ] || return 1
    fi
}

path_metadata() {
    if command -v stat >/dev/null 2>&1; then
        stat -c '%F:%u:%a:%h' "$1" 2>/dev/null && return 0
    fi
    LC_ALL=C ls -ldn "$1" 2>/dev/null |
        awk 'NR == 1 { print $1 ":" $3 ":" $2 }'
}

owned_directory_0700() {
    metadata="$(path_metadata "$1")" || return 1
    case "$metadata" in
        directory:0:700:*|drwx------:0:*) return 0 ;;
        *) return 1 ;;
    esac
}

owned_file_0600() {
    metadata="$(path_metadata "$1")" || return 1
    case "$metadata" in
        regular*:0:600:1|-rw-------:0:1) return 0 ;;
        *) return 1 ;;
    esac
}

validate_work_dir() {
    [ -n "$WORK_DIR" ] || return 1
    case "$WORK_DIR" in
        /tmp/miclash/updates) ;;
        /tmp/miclash-install.*)
            printf '%s\n' "${WORK_DIR#/tmp/miclash-install.}" |
                grep -Eq '^[A-Za-z0-9]{6,32}$' || return 1
            ;;
        *) return 1 ;;
    esac
    [ ! -L "$WORK_DIR" ] && [ -d "$WORK_DIR" ] || return 1
    owned_directory_0700 "$WORK_DIR" || return 1
    [ "$(readlink -f "$WORK_DIR" 2>/dev/null)" = "$WORK_DIR" ] || return 1
}

prepare_work_dir() {
    if [ -n "$STATUS_FILE" ]; then
        WORK_DIR="${STATUS_FILE%/*}"
    else
        umask 077
        WORK_DIR=$(mktemp -d /tmp/miclash-install.XXXXXX) || die "Failed to create installer workspace"
        chmod 0700 "$WORK_DIR" || die "Failed to secure installer workspace"
        TEMP_DIRS="$TEMP_DIRS $WORK_DIR"
    fi
    validate_work_dir || die "invalid installer workspace authority"
}

marker_owned() {
    marker="$1"
    [ ! -L "$marker" ] && [ -f "$marker" ] || return 1
    owned_file_0600 "$marker" || return 1
    [ "$(readlink -f "$marker" 2>/dev/null)" = "$marker" ] || return 1
}

create_marker() {
    marker="$1"
    [ ! -e "$marker" ] && [ ! -L "$marker" ] || return 1
    (umask 077; set -C; : > "$marker") 2>/dev/null || return 1
    if ! marker_owned "$marker"; then
        return 1
    fi
    OWNED_MARKERS="$OWNED_MARKERS $marker"
}

cleanup() {
    for file in $TEMP_FILES; do
        [ -n "$file" ] && rm -f "$file" 2>/dev/null || true
    done
    for marker in $OWNED_MARKERS; do
        marker_owned "$marker" && rm -f "$marker" 2>/dev/null || true
    done
    for directory in $TEMP_DIRS; do
        WORK_DIR="$directory"
        validate_work_dir && rm -rf "$directory" 2>/dev/null || true
    done
}

trap cleanup EXIT INT TERM

normalize_version() {
    printf '%s' "$1" | sed 's/^v//; s/-r[0-9][0-9]*$//'
}

installed_miclash_version() {
    case "$1" in
        apk)
            apk list -I 2>/dev/null | awk '
                $1 ~ /^luci-app-miclash-[0-9]/ {
                    sub(/^luci-app-miclash-/, "", $1)
                    print $1
                    exit
                }'
            ;;
        opkg)
            opkg list-installed luci-app-miclash 2>/dev/null |
                awk 'NR == 1 { print $3 }'
            ;;
        *) return 64 ;;
    esac
}

version_major() {
    normalized="$(normalize_version "$1")"
    printf '%s\n' "$normalized" |
        grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z][0-9A-Za-z.-]*)?$' || return 1
    printf '%s' "${normalized%%.*}"
}

cross_major_update() {
    installed="$1"
    target="$2"
    [ -n "$installed" ] || return 1
    installed_major="$(version_major "$installed")" || return 1
    target_major="$(version_major "$target")" || return 1
    [ "$installed_major" != "$target_major" ]
}

reject_unauthorized_cross_major() {
    if cross_major_update "$MICLASH_INSTALLED_VER" "$MICLASH_VER"; then
        die "Direct cross-major MiClash updates are refused; use the dedicated transition installer"
    fi
}

validate_openwrt_support() {
    release="$1"

    if [ "$release" != "SNAPSHOT" ]; then
        printf '%s\n' "$release" | grep -Eq '^[0-9]+(\.[0-9]+)*(-rc[0-9]+)?$' \
            || die "Неподдерживаемая версия OpenWrt: $release. Требуется OpenWrt 24.10 или новее"
        release_major="${release%%.*}"
        [ "$release_major" -ge 24 ] 2>/dev/null \
            || die "OpenWrt $release не поддерживается. Требуется OpenWrt 24.10 или новее"
    fi

    command -v fw4 >/dev/null 2>&1 \
        || die "Не найден firewall4 (fw4). Требуется OpenWrt 24.10 или новее"
    case "$PKG_MGR" in
        apk|opkg) ;;
        *) die "Не найден поддерживаемый менеджер пакетов OpenWrt (apk или opkg)" ;;
    esac
}

detect_openwrt() {
    [ -f /etc/openwrt_release ] || die "Не найден /etc/openwrt_release"
    . /etc/openwrt_release

    OW_RELEASE="${DISTRIB_RELEASE:-unknown}"
    ARCH_PKG="${DISTRIB_ARCH:-}"

    info "OpenWrt: ${B}${OW_RELEASE}${N}"
    info "DISTRIB_ARCH: ${B}${ARCH_PKG}${N}"

    # Detect the package manager from the installed binary. Modern SNAPSHOT
    # builds may use either manager, so the release label must not decide it.
    if command -v apk >/dev/null 2>&1; then
        PKG_MGR="apk"
    elif command -v opkg >/dev/null 2>&1; then
        PKG_MGR="opkg"
    else
        die "Не найден поддерживаемый менеджер пакетов OpenWrt (apk или opkg)"
    fi
    validate_openwrt_support "$OW_RELEASE"
    info "Package manager: ${B}${PKG_MGR}${N}"

    TPROXY_PKG="kmod-nft-tproxy"

    info "Transparent proxy pkg: ${B}${TPROXY_PKG}${N}"
}

ensure_curl() {
    if command -v curl >/dev/null 2>&1 && curl --version >/dev/null 2>&1; then
        info "curl: available"
        return 0
    fi

    if command -v curl >/dev/null 2>&1; then
        warn "curl is installed but cannot run, reinstalling curl libraries..."
    else
        warn "curl not found, installing..."
    fi

    write_status running dependencies "Repairing curl dependencies"
    if [ "$PKG_MGR" = "apk" ]; then
        apk update || die "apk update failed"
        apk add zlib libcurl4 curl || die "curl install failed"
        if ! curl --version >/dev/null 2>&1; then
            apk fix zlib libcurl4 curl || die "curl repair failed"
        fi
    else
        opkg update || die "opkg update failed"
        if command -v curl >/dev/null 2>&1; then
            opkg install --force-reinstall zlib libcurl4 curl || die "curl repair failed"
        else
            opkg install zlib libcurl4 curl || die "curl install failed"
        fi
    fi
    command -v curl >/dev/null 2>&1 && curl --version >/dev/null 2>&1 \
        || die "curl still unavailable after install"
    PKG_UPDATED=1
}

github_proxy_url() {
    case "$1" in
        https://github.com/*|https://api.github.com/*|https://raw.githubusercontent.com/*)
            printf 'https://gh-proxy.com/%s\n' "$1"
            ;;
        *) return 1 ;;
    esac
}

retryable_curl_code() {
    case "$1" in
        5|6|7|28|35|52|55|56) return 0 ;;
        *) return 1 ;;
    esac
}

download_artifact_attempts() {
    attempt_url="$1"
    target="$2"
    error_file="$3"
    curl_code=1
    for family in "" "" "-4"; do
        if curl $family -L -fsS \
            --connect-timeout "$CURL_CONNECT_TIMEOUT" \
            --max-time "$CURL_MAX_TIME" \
            "$attempt_url" -o "$target" 2>"$error_file" && [ -s "$target" ]; then
            return 0
        else
            curl_code=$?
        fi
        rm -f "$target"
        sleep 1
    done
    return "$curl_code"
}

download_artifact() {
    url="$1"
    target="$2"
    label="$3"
    validate_work_dir || die "installer workspace authority changed"
    error_file="$WORK_DIR/download-error-$$"

    write_status running download "Downloading $label"
    rm -f "$target" "$error_file"
    if download_artifact_attempts "$url" "$target" "$error_file"; then
        rm -f "$error_file"
        return 0
    else
        curl_code=$?
    fi

    proxy_url=''
    if retryable_curl_code "$curl_code" && proxy_url="$(github_proxy_url "$url")"; then
        warn "Direct GitHub download failed; trying gh-proxy.com"
        if download_artifact_attempts "$proxy_url" "$target" "$error_file"; then
            rm -f "$error_file"
            return 0
        fi
    fi

    detail=$(tail -n 3 "$error_file" 2>/dev/null | tr '\r\n' '  ')
    rm -f "$error_file"
    die "Failed to download $label: ${detail:-download returned an empty file}"
}

verify_download_checksum() {
    artifact="$1"
    checksum_url="$2"
    artifact_name="$3"
    checksum_file="$WORK_DIR/$artifact_name.sha256"
    TEMP_FILES="$TEMP_FILES $checksum_file"
    download_artifact "$checksum_url" "$checksum_file" "$artifact_name checksum"
    checksum_line=$(cat "$checksum_file" 2>/dev/null) || die "Failed to read $artifact_name checksum"
    expected=$(printf '%s\n' "$checksum_line" | sed -n \
        "s/^\([0-9A-Fa-f]\{64\}\)[[:space:]][[:space:]]*\\*\?$artifact_name\$/\1/p")
    [ -n "$expected" ] && [ "$(printf '%s\n' "$checksum_line" | wc -l | tr -d ' ')" = 1 ] \
        || die "Invalid published checksum for $artifact_name"
    actual=$(sha256sum "$artifact" 2>/dev/null | awk '{print $1}') \
        || die "Failed to hash $artifact_name"
    [ "$(printf '%s' "$actual" | tr 'A-F' 'a-f')" = \
      "$(printf '%s' "$expected" | tr 'A-F' 'a-f')" ] \
        || die "Checksum mismatch for $artifact_name"
}

pkg_update() {
    if [ "$PKG_UPDATED" = "1" ]; then
        info "Package index already updated"
        return 0
    fi

    log "Updating package index..."
    write_status running dependencies "Updating package index"
    if [ "$PKG_MGR" = "apk" ]; then
        apk update || die "apk update failed"
    else
        opkg update || die "opkg update failed"
    fi
    PKG_UPDATED=1
}

install_deps() {
    log "Installing dependencies..."
    write_status running dependencies "Installing dependencies"
    if [ "$PKG_MGR" = "apk" ]; then
        apk add zlib libcurl4 curl "$TPROXY_PKG" kmod-tun coreutils-base64 coreutils-stat \
            || die "Dependency installation failed"
    else
        opkg install zlib libcurl4 curl "$TPROXY_PKG" kmod-tun coreutils-base64 coreutils-stat \
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

reset_miclash_candidate() {
    MICLASH_TAG_NAME=""
    MICLASH_VER=""
    MICLASH_APK_URL=""
    MICLASH_IPK_URL=""
    MICLASH_APK_SHA256_URL=""
    MICLASH_IPK_SHA256_URL=""
}

json_string_values() {
    json_file="$1"
    json_key="$2"
    grep -o "\"$json_key\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$json_file" 2>/dev/null |
        sed 's/^[^:]*:[[:space:]]*"\([^"]*\)"$/\1/'
}

json_boolean_values() {
    json_file="$1"
    json_key="$2"
    grep -o "\"$json_key\"[[:space:]]*:[[:space:]]*\(true\|false\)" "$json_file" 2>/dev/null |
        sed 's/^[^:]*:[[:space:]]*//'
}

exact_value_count() {
    expected_value="$1"
    shift
    count="$($@ | grep -Fxc "$expected_value" 2>/dev/null || true)"
    case "$count" in ''|*[!0-9]*) return 1 ;; esac
    printf '%s' "$count"
}

validate_miclash_release_file() {
    release_file="$1"
    requested_manager="$2"
    expected_tag="$3"
    reset_miclash_candidate

    [ -f "$release_file" ] && [ -s "$release_file" ] || return 1
    case "$requested_manager" in apk|opkg) ;; *) return 1 ;; esac
    printf '%s\n' "$expected_tag" |
        grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z][0-9A-Za-z.-]*)?$' || return 1

    tag_count="$(exact_value_count "$expected_tag" json_string_values "$release_file" tag_name)" || return 1
    [ "$tag_count" = 1 ] || return 1
    draft_count="$(exact_value_count false json_boolean_values "$release_file" draft)" || return 1
    [ "$draft_count" = 1 ] || return 1

    clean_tag="${expected_tag#v}"
    if printf '%s\n' "$clean_tag" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
        prerelease_expected=false
    else
        prerelease_expected=true
    fi
    prerelease_count="$(exact_value_count "$prerelease_expected" \
        json_boolean_values "$release_file" prerelease)" || return 1
    [ "$prerelease_count" = 1 ] || return 1

    if [ "$requested_manager" = apk ]; then
        package_name="luci-app-miclash-${clean_tag}.apk"
    else
        package_name="luci-app-miclash_${clean_tag}_all.ipk"
    fi
    checksum_name="${package_name}.sha256"
    installer_checksum_name="install-miclash.sh.sha256"
    manifest_name="miclash-release-manifest.json"
    release_prefix="https://github.com/ang3el7z/luci-app-miclash/releases/download/${expected_tag}/"
    pending=0

    for asset_name in "$package_name" "$checksum_name" \
        "$installer_checksum_name" "$manifest_name"; do
        asset_url="${release_prefix}${asset_name}"
        name_count="$(exact_value_count "$asset_name" \
            json_string_values "$release_file" name)" || return 1
        url_count="$(exact_value_count "$asset_url" \
            json_string_values "$release_file" browser_download_url)" || return 1
        if [ "$name_count" -gt 1 ] || [ "$url_count" -gt 1 ]; then
            return 1
        elif [ "$name_count" = 0 ] && [ "$url_count" = 0 ]; then
            pending=1
        elif [ "$name_count" != 1 ] || [ "$url_count" != 1 ]; then
            return 1
        fi
    done

    [ "$pending" = 0 ] || return 2
    MICLASH_TAG_NAME="$expected_tag"
    MICLASH_VER="$clean_tag"
    if [ "$requested_manager" = apk ]; then
        MICLASH_APK_URL="${release_prefix}${package_name}"
        MICLASH_APK_SHA256_URL="${release_prefix}${checksum_name}"
    else
        MICLASH_IPK_URL="${release_prefix}${package_name}"
        MICLASH_IPK_SHA256_URL="${release_prefix}${checksum_name}"
    fi
    return 0
}

fixture_release_file() {
    fixture_dir="$1"
    fixture_tag="$2"
    case "$fixture_tag" in
        v3.0.0) fixture_name=terminal-release-incomplete.json ;;
        v2.0.0) fixture_name=terminal-release-ready-opkg.json ;;
        v1.9.0) fixture_name=terminal-release-ready-apk.json ;;
        *) fixture_name="terminal-release-${fixture_tag#v}.json" ;;
    esac
    printf '%s/%s' "$fixture_dir" "$fixture_name"
}

fetch_miclash_catalog() {
    if [ -n "$MICLASH_TEST_FIXTURE_DIR" ]; then
        MICLASH_CATALOG_FILE="$MICLASH_TEST_FIXTURE_DIR/terminal-releases.json"
        [ -f "$MICLASH_CATALOG_FILE" ] || return 1
        return 0
    fi
    MICLASH_CATALOG_FILE="$WORK_DIR/miclash-releases.json"
    TEMP_FILES="$TEMP_FILES $MICLASH_CATALOG_FILE"
    download_artifact "$MICLASH_RELEASES_API" "$MICLASH_CATALOG_FILE" \
        "MiClash release catalog"
}

fetch_miclash_exact_release() {
    exact_tag="$1"
    if [ -n "$MICLASH_TEST_FIXTURE_DIR" ]; then
        MICLASH_FETCHED_FILE="$(fixture_release_file "$MICLASH_TEST_FIXTURE_DIR" "$exact_tag")"
        [ -f "$MICLASH_FETCHED_FILE" ] || return 1
        return 0
    fi
    MICLASH_FETCHED_FILE="$WORK_DIR/miclash-release-${exact_tag#v}.json"
    TEMP_FILES="$TEMP_FILES $MICLASH_FETCHED_FILE"
    download_artifact "${MICLASH_TAG_API}/${exact_tag}" "$MICLASH_FETCHED_FILE" \
        "MiClash $exact_tag release metadata"
}

stable_catalog_tags_newest_first() {
    json_string_values "$MICLASH_CATALOG_FILE" tag_name |
        grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' |
        awk '!seen[$0]++'
}

select_terminal_release() {
    if [ -n "$MICLASH_TARGET_TAG" ]; then
        printf '%s\n' "$MICLASH_TARGET_TAG" |
            grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z][0-9A-Za-z.-]*)?$' \
            || die "Invalid requested MiClash tag"
        fetch_miclash_exact_release "$MICLASH_TARGET_TAG" ||
            die "Requested MiClash release was not found: $MICLASH_TARGET_TAG"
        if ! validate_miclash_release_file "$MICLASH_FETCHED_FILE" \
            "$PKG_MGR" "$MICLASH_TARGET_TAG"; then
            die "Requested MiClash release is not ready: $MICLASH_TARGET_TAG"
        fi
        return 0
    fi

    fetch_miclash_catalog || die "Failed to fetch MiClash release catalog"
    first_tag=""
    inspected=0
    for tag in $(stable_catalog_tags_newest_first); do
        [ "$inspected" -lt 20 ] || break
        inspected=$((inspected + 1))
        [ -n "$first_tag" ] || first_tag="$tag"
        fetch_miclash_exact_release "$tag" || die "Invalid MiClash release catalog entry: $tag"
        if validate_miclash_release_file "$MICLASH_FETCHED_FILE" "$PKG_MGR" "$tag"; then
            if [ "$tag" != "$first_tag" ] && [ -z "$MICLASH_TEST_FIXTURE_DIR" ]; then
                warn "Newest release $first_tag is incomplete; installing ready release $tag"
            fi
            return 0
        else
            validation_result=$?
            [ "$validation_result" = 2 ] || die "Invalid MiClash release metadata: $tag"
        fi
    done
    die "No ready stable MiClash release found in the newest 20 releases"
}

fetch_miclash_release() {
    log "Selecting a ready MiClash release..."
    select_terminal_release
    MICLASH_RELEASE_NORM=$(normalize_version "$MICLASH_VER")
    info "Selected MiClash: ${B}${MICLASH_TAG_NAME}${N}"
    if [ "$PKG_MGR" = apk ]; then
        info "Package asset: ${B}${MICLASH_APK_URL##*/}${N}"
    else
        info "Package asset: ${B}${MICLASH_IPK_URL##*/}${N}"
    fi
}

detect_installed_miclash() {
    MICLASH_INSTALLED_VER=$(installed_miclash_version "$PKG_MGR")

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

    create_marker "$NO_AUTOSTART_CLASH_MARKER" \
        || die "Failed to prepare package service state"
    create_marker "$NO_AUTOSTART_AUTOUPDATE_MARKER" \
        || die "Failed to prepare package service state"
    if [ "$INSTALL_ACTION" = "reinstall" ]; then
        create_marker "$HARD_REINSTALL_MARKER" || die "Failed to prepare hard reinstall"
    fi

    if [ "$PKG_MGR" = "apk" ]; then
        PKG_FILE="$WORK_DIR/${MICLASH_APK_URL##*/}"
        TEMP_FILES="$TEMP_FILES $PKG_FILE"
        write_status running download "Downloading MiClash package"
        download_artifact "$MICLASH_APK_URL" "$PKG_FILE" "MiClash .apk"
        verify_download_checksum "$PKG_FILE" "$MICLASH_APK_SHA256_URL" "${MICLASH_APK_URL##*/}"
        write_status running install "Installing MiClash package"
        if [ "$INSTALL_ACTION" = "reinstall" ]; then
            apk add "$PKG_FILE" --allow-untrusted --force-overwrite \
                || die "Failed to reinstall MiClash .apk"
        else
            apk add "$PKG_FILE" --allow-untrusted || die "Failed to install MiClash .apk"
        fi
        rm -f "$PKG_FILE"
    else
        PKG_FILE="$WORK_DIR/${MICLASH_IPK_URL##*/}"
        TEMP_FILES="$TEMP_FILES $PKG_FILE"
        write_status running download "Downloading MiClash package"
        download_artifact "$MICLASH_IPK_URL" "$PKG_FILE" "MiClash .ipk"
        verify_download_checksum "$PKG_FILE" "$MICLASH_IPK_SHA256_URL" "${MICLASH_IPK_URL##*/}"
        write_status running install "Installing MiClash package"
        if [ "$INSTALL_ACTION" = "reinstall" ]; then
            opkg install --force-reinstall "$PKG_FILE" || die "Failed to reinstall MiClash .ipk"
        else
            opkg install "$PKG_FILE" || die "Failed to install MiClash .ipk"
        fi
        rm -f "$PKG_FILE"
    fi

    if [ "$INSTALL_ACTION" = "reinstall" ]; then
        rm -f /opt/clash/bin/clash || die "Failed to remove Mihomo kernel after hard reinstall"
    fi
}

run_clean_install_mode() {
    MICLASH_TARGET_TAG=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --target-tag)
                [ "$#" -gt 1 ] || die "missing value for --target-tag"
                MICLASH_TARGET_TAG="$2"
                shift 2
                ;;
            *) die "unknown clean-install argument: $1" ;;
        esac
    done
    printf '%s\n' "$MICLASH_TARGET_TAG" | grep -Eq '^v2\.[0-9]+\.[0-9]+$' ||
        die "clean v0.9 upgrade requires a stable v2 target"
    detect_openwrt
    detect_arch
    detect_installed_miclash
    [ -z "$MICLASH_INSTALLED_VER" ] || die "clean-install requires the old package to be removed first"
    prepare_work_dir
    ensure_curl
    fetch_miclash_release
    INSTALL_ACTION="install"
    pkg_update
    install_deps
    install_miclash
    install_mihomo
    echo "MiClash package and fresh Mihomo core installed; services remain stopped"
}

schedule_backend_reload() {
    [ -x /etc/init.d/miclashd ] || return 0
    (
        /bin/busybox sleep 3
        /etc/init.d/miclashd restart
    ) >/dev/null 2>&1 &
}

run_app_mode() {
    INSTALL_ACTION="update"

    while [ $# -gt 0 ]; do
        case "$1" in
            --target-tag)
                [ $# -gt 1 ] || die "missing value for --target-tag"
                MICLASH_TARGET_TAG="$2"
                shift 2
                ;;
            --mode)
                [ $# -gt 1 ] || die "missing value for --mode"
                INSTALL_ACTION="$2"
                shift 2
                ;;
            --status-file)
                [ $# -gt 1 ] || die "missing value for --status-file"
                STATUS_FILE="$2"
                shift 2
                ;;
            --token)
                [ $# -gt 1 ] || die "missing value for --token"
                CURRENT_TOKEN="$(status_text "$2")"
                shift 2
                ;;
            *)
                die "unknown app argument: $1"
                ;;
        esac
    done

    [ -n "$MICLASH_TARGET_TAG" ] || die "missing --target-tag"
    STATUS_TARGET_VERSION="$MICLASH_TARGET_TAG"
    case "$INSTALL_ACTION" in
        install|update|reinstall) ;;
        *) die "unsupported app mode: $INSTALL_ACTION" ;;
    esac

    validate_status_authority || die "invalid update status authority"
    prepare_work_dir
    write_status running queued "Starting MiClash package update" || die "failed to write update status"
    detect_openwrt
    ensure_curl
    fetch_miclash_release
    detect_installed_miclash
    reject_unauthorized_cross_major
    pkg_update
    install_deps
    install_miclash
    write_status success done "MiClash package installed; backend reload scheduled" || {
        printf '%s\n' "MiClash package installed, but final status handoff failed" >&2
        exit 1
    }
    schedule_backend_reload || warn "Failed to schedule MiClash backend reload"
    echo "MiClash package installed; backend reload scheduled"
}

run_status_protocol_test() {
    MICLASH_TARGET_TAG=""
    STATUS_FILE=""
    CURRENT_TOKEN=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --target-tag) [ $# -gt 1 ] || return 64; MICLASH_TARGET_TAG="$2"; shift 2 ;;
            --status-file) [ $# -gt 1 ] || return 64; STATUS_FILE="$2"; shift 2 ;;
            --token) [ $# -gt 1 ] || return 64; CURRENT_TOKEN="$2"; shift 2 ;;
            *) return 64 ;;
        esac
    done
    STATUS_TARGET_VERSION="$MICLASH_TARGET_TAG"
    validate_status_authority || return 65
    prepare_work_dir
    write_status success done || return 70
}

run_installer_security_test() {
    STATUS_FILE=""
    prepare_work_dir
    validate_work_dir || return 65
    test_marker="/tmp/miclash-package-no-autostart-clash"
    [ ! -e "$test_marker" ] && [ ! -L "$test_marker" ] || return 66
    ln -s /etc/passwd "$test_marker" || return 67
    if create_marker "$test_marker"; then return 68; fi
    [ -L "$test_marker" ] || return 69
    rm -f "$test_marker" || return 70
    create_marker "$test_marker" || return 71
    marker_owned "$test_marker" || return 72
    return 0
}

run_ready_release_selection_test() {
    PKG_MGR=""
    MICLASH_TEST_FIXTURE_DIR=""
    MICLASH_TARGET_TAG=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --manager)
                [ $# -gt 1 ] || return 64
                PKG_MGR="$2"
                shift 2
                ;;
            --fixture-dir)
                [ $# -gt 1 ] || return 64
                MICLASH_TEST_FIXTURE_DIR="$2"
                shift 2
                ;;
            --target-tag)
                [ $# -gt 1 ] || return 64
                MICLASH_TARGET_TAG="$2"
                shift 2
                ;;
            *) return 64 ;;
        esac
    done
    case "$PKG_MGR" in apk|opkg) ;; *) return 64 ;; esac
    [ -n "$MICLASH_TEST_FIXTURE_DIR" ] &&
        [ -d "$MICLASH_TEST_FIXTURE_DIR" ] || return 65
    select_terminal_release
    printf '%s\n' "$MICLASH_TAG_NAME"
}

install_mihomo() {
    log "Fetching latest Mihomo release..."
    mihomo_release_file="$WORK_DIR/mihomo-release.json"
    mihomo_archive="$WORK_DIR/clash.gz"
    TEMP_FILES="$TEMP_FILES $mihomo_release_file $mihomo_archive"
    download_artifact "$MIHOMO_API" "$mihomo_release_file" "Mihomo release metadata"
    MIHOMO_JSON=$(cat "$mihomo_release_file" 2>/dev/null) || die "Failed to read Mihomo release data"
    [ -n "$MIHOMO_JSON" ] || die "Mihomo release API returned empty response"

    MIHOMO_VER=$(printf '%s' "$MIHOMO_JSON" \
        | grep '"tag_name"' | head -1 \
        | sed 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
    [ -n "$MIHOMO_VER" ] || die "Failed to parse Mihomo version"

    MIHOMO_URL="${MIHOMO_BASE}/download/${MIHOMO_VER}/mihomo-linux-${MIHOMO_ARCH}-${MIHOMO_VER}.gz"
    info "Latest Mihomo: ${B}${MIHOMO_VER}${N}"
    info "Kernel URL: ${MIHOMO_URL}"

    download_artifact "$MIHOMO_URL" "$mihomo_archive" "Mihomo kernel"
    verify_download_checksum "$mihomo_archive" "${MIHOMO_URL}.sha256" "${MIHOMO_URL##*/}"

    mkdir -p "$(dirname "$CLASH_BIN")"
    gunzip -c "$mihomo_archive" > "$CLASH_BIN" || die "Failed to unpack Mihomo kernel"
    chmod +x "$CLASH_BIN" || die "Failed to chmod Mihomo kernel"
    rm -f "$mihomo_archive"
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
    prepare_work_dir
    ensure_curl
    detect_arch
    fetch_miclash_release
    detect_installed_miclash
    reject_unauthorized_cross_major
    choose_install_action
    sep

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

    if [ "$INSTALL_ACTION" = "skip" ]; then
        log "MiClash package already up to date, skipping package install"
    else
        install_miclash
    fi

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

if [ "${1:-}" = "status-protocol-test" ]; then
    shift
    run_status_protocol_test "$@"
elif [ "${1:-}" = "installer-security-test" ]; then
    shift
    run_installer_security_test "$@"
elif [ "${1:-}" = "ready-release-selection-test" ]; then
    shift
    run_ready_release_selection_test "$@"
elif [ "${1:-}" = "app" ]; then
    shift
    run_app_mode "$@"
elif [ "${1:-}" = "clean-install" ]; then
    shift
    run_clean_install_mode "$@"
else
    main "$@"
fi
