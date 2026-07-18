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

echo 'ready release selection tests passed'
