#!/bin/sh

set -eu

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
installer="$repo_root/install-miclash.sh"
transition_installer="$repo_root/install-miclash-upgrade-0-9-x-to-2.x.x.sh"
fixtures="$repo_root/tests/fixtures/releases"

apk() {
    [ "$1" = list ] && [ "$2" = -I ] || return 1
    printf '%s\n' 'luci-app-miclash-0.9.2-r1 noarch {/build/luci-app-miclash} () [installed]'
}

opkg() {
    [ "$1" = list-installed ] && [ "$2" = luci-app-miclash ] || return 1
    printf '%s\n' 'luci-app-miclash - 0.9.2-r1'
}

for package_installer in "$installer" "$transition_installer"; do
    version_function="$(sed -n '/^installed_miclash_version() {$/,/^}$/p' "$package_installer")"
    [ -n "$version_function" ] || {
        echo "installed version parser is missing from $package_installer" >&2
        exit 1
    }
    eval "$version_function"
    [ "$(installed_miclash_version apk)" = 0.9.2-r1 ]
    [ "$(installed_miclash_version opkg)" = 0.9.2-r1 ]
done

function_body() {
    sed -n "/^$2() {$/,/^}$/p" "$1"
}

require_function() {
    body="$(function_body "$1" "$2")"
    [ -n "$body" ] || {
        echo "$2() is missing from $1" >&2
        return 1
    }
    printf '%s\n' "$body"
}

test_installer_download_fallback() (
    eval "$(require_function "$installer" github_proxy_url)"
    eval "$(require_function "$installer" retryable_curl_code)"
    eval "$(require_function "$installer" download_artifact_attempts)"
    eval "$(require_function "$installer" download_artifact)"
    WORK_DIR="$(mktemp -d)"
    trap 'rm -rf "$WORK_DIR"' EXIT
    CURL_CONNECT_TIMEOUT=1
    CURL_MAX_TIME=2
    calls=0
    proxy_calls=0
    curl_result=28
    validate_work_dir() { return 0; }
    write_status() { :; }
    warn() { :; }
    sleep() { :; }
    die() { return 1; }
    curl() {
        calls=$((calls + 1))
        output=''
        previous=''
        for argument in "$@"; do
            [ "$previous" != -o ] || output="$argument"
            previous="$argument"
        done
        case "$*" in
            *https://gh-proxy.com/https://github.com/*)
                proxy_calls=$((proxy_calls + 1))
                printf 'package' >"$output"
                return 0
                ;;
        esac
        return "$curl_result"
    }
    target="$WORK_DIR/package.apk"
    download_artifact \
        'https://github.com/ang3el7z/luci-app-miclash/releases/download/v2.0.2/package.apk' \
        "$target" 'MiClash .apk'
    [ "$(cat "$target")" = package ]
    [ "$calls" -eq 4 ]
    [ "$proxy_calls" -eq 1 ]

    calls=0
    proxy_calls=0
    curl_result=22
    if download_artifact \
        'https://github.com/ang3el7z/luci-app-miclash/releases/download/v2.0.2/missing.apk' \
        "$target" 'missing package' >/dev/null 2>&1; then
        exit 1
    fi
    [ "$calls" -eq 3 ]
    [ "$proxy_calls" -eq 0 ]
)

test_transition_download_fallback() (
    eval "$(require_function "$transition_installer" github_proxy_url)"
    eval "$(require_function "$transition_installer" retryable_curl_code)"
    eval "$(require_function "$transition_installer" download_once)"
    eval "$(require_function "$transition_installer" download)"
    calls=0
    proxy_calls=0
    curl_result=28
    say() { :; }
    curl() {
        calls=$((calls + 1))
        output=''
        previous=''
        for argument in "$@"; do
            [ "$previous" != --output ] || output="$argument"
            previous="$argument"
        done
        case "$*" in
            *https://gh-proxy.com/https://github.com/*)
                proxy_calls=$((proxy_calls + 1))
                printf 'installer' >"$output"
                return 0
                ;;
        esac
        return "$curl_result"
    }
    target="$(mktemp)"
    trap 'rm -f "$target"' EXIT
    download \
        'https://github.com/ang3el7z/luci-app-miclash/releases/download/v2.0.2/install-miclash.sh' \
        "$target"
    [ "$(cat "$target")" = installer ]
    [ "$calls" -eq 2 ]
    [ "$proxy_calls" -eq 1 ]

    calls=0
    proxy_calls=0
    curl_result=22
    if download \
        'https://github.com/ang3el7z/luci-app-miclash/releases/download/v2.0.2/missing' \
        "$target"; then
        exit 1
    fi
    [ "$calls" -eq 1 ]
    [ "$proxy_calls" -eq 0 ]
)

test_installer_download_fallback
test_transition_download_fallback

run_installer() {
    if command -v ash >/dev/null 2>&1; then
        ash "$installer" "$@"
    elif command -v busybox >/dev/null 2>&1; then
        busybox ash "$installer" "$@"
    else
        echo 'BusyBox ash is required for installer tests' >&2
        return 127
    fi
}

selected="$(run_installer ready-release-selection-test \
    --manager opkg --fixture-dir "$fixtures")"
[ "$selected" = v2.0.0 ]

selected="$(run_installer ready-release-selection-test \
    --manager apk --fixture-dir "$fixtures")"
[ "$selected" = v1.9.0 ]

if run_installer ready-release-selection-test --manager opkg \
    --fixture-dir "$fixtures" --target-tag v3.0.0 >/dev/null 2>&1; then
    exit 1
fi

if run_installer ready-release-selection-test --manager apk \
    --fixture-dir "$fixtures/no-ready" >/dev/null 2>&1; then
    exit 1
fi

if run_installer ready-release-selection-test --manager opkg \
    --fixture-dir "$fixtures/duplicate" --target-tag v4.0.0 >/dev/null 2>&1; then
    exit 1
fi

if run_installer ready-release-selection-test --manager opkg \
    --fixture-dir "$fixtures/forged" --target-tag v5.0.0 >/dev/null 2>&1; then
    exit 1
fi

selected="$(run_installer ready-release-selection-test \
    --manager apk --fixture-dir "$fixtures" --target-tag v2.5.2_rc1)"
[ "$selected" = v2.5.2_rc1 ]

echo 'ready release selection tests passed'
