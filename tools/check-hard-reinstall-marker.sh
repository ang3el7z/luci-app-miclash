#!/bin/sh

set -eu

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

if [ "${MICLASH_HARD_MARKER_NS:-}" != 1 ]; then
	exec unshare --mount --fork env MICLASH_HARD_MARKER_NS=1 sh "$0"
fi

fixture=$(mktemp -d /tmp/miclash-hard-marker.XXXXXX)
cleanup() { rm -rf "$fixture" /tmp/miclash-hard-reinstall 2>/dev/null || true; }
trap cleanup EXIT HUP INT TERM

sed -n '/^define Package\/\$(PKG_NAME)\/postrm$/,/^endef$/p' \
	"$repo_root/luci-app-miclash/Makefile" | sed '1d;$d;s/\$\$/\$/g' > "$fixture/postrm"
chmod 0700 "$fixture/postrm"
mkdir -p /opt/clash/bin

printf 'core\n' > /opt/clash/bin/clash
: > /tmp/miclash-hard-reinstall
chmod 0600 /tmp/miclash-hard-reinstall
chown 1000:1000 /tmp/miclash-hard-reinstall
"$fixture/postrm" upgrade
[ -f /opt/clash/bin/clash ]
[ ! -e /tmp/miclash-hard-reinstall ] && [ ! -L /tmp/miclash-hard-reinstall ]

: > /tmp/miclash-hard-reinstall
chmod 0600 /tmp/miclash-hard-reinstall
ln /tmp/miclash-hard-reinstall "$fixture/hardlink"
"$fixture/postrm" upgrade
[ -f /opt/clash/bin/clash ]

: > /tmp/miclash-hard-reinstall
chmod 0600 /tmp/miclash-hard-reinstall
"$fixture/postrm" upgrade
[ ! -e /opt/clash/bin/clash ] && [ ! -L /opt/clash/bin/clash ]

echo 'hard-reinstall marker authentication gate passed'
