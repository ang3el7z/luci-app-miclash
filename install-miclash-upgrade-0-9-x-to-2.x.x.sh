#!/bin/sh

# One-time clean reinstall from MiClash v0.9.x to an exact MiClash v2 release.
# This script deliberately has no migration or rollback engine: it keeps a
# user-data backup in /root and performs a clean package replacement.
set -eu

TAG=''
WORK=''
BACKUP=''
GUARD_ENABLED=0
OLD_ENABLED=0
OLD_RUNNING=0
PKG_MGR=''

say() { printf '%s\n' "$*"; }
die() { printf 'MiClash clean upgrade failed: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "required command is missing: $1"; }

usage() {
	cat <<'EOF'
Usage: install-miclash-upgrade-0-9-x-to-2.x.x.sh --release-tag v2.X.Y

Performs a clean reinstall from an installed MiClash v0.9.x to the exact v2
release. Profiles, the installed Mihomo core, rules/providers and legacy
settings are copied to a persistent /root/miclash-v09-backup-* directory.

There is no automatic rollback. The previous Guard and service enabled/running
state are restored after the v2 package and user files are installed.
EOF
}

cleanup_work() {
	[ -n "$WORK" ] || return 0
	rm -f "$WORK/install-miclash.sh" "$WORK/install-miclash.sh.sha256" 2>/dev/null || true
	rmdir "$WORK" 2>/dev/null || true
}

signal_exit() {
	trap - EXIT INT TERM HUP
	cleanup_work
	exit "$1"
}

trap cleanup_work EXIT
trap 'signal_exit 130' INT
trap 'signal_exit 143' TERM
trap 'signal_exit 129' HUP

while [ "$#" -gt 0 ]; do
	case "$1" in
		--release-tag)
			[ "$#" -gt 1 ] || { usage >&2; exit 64; }
			TAG="$2"
			shift 2
			;;
		--help|-h) usage; exit 0 ;;
		*) usage >&2; exit 64 ;;
	esac
done

printf '%s\n' "$TAG" | grep -Eq '^v2\.[0-9]+\.[0-9]+$' || die 'release tag must be a stable v2 tag'
[ "$(id -u)" = 0 ] || die 'root is required'

for command in curl sha256sum sed awk grep cp rm mkdir chmod date id mktemp rmdir; do need "$command"; done

if command -v apk >/dev/null 2>&1 && apk info -e luci-app-miclash >/dev/null 2>&1; then
	PKG_MGR=apk
	OLD_VERSION="$(apk info -v luci-app-miclash 2>/dev/null | sed -n '1s/^luci-app-miclash-//p')"
elif command -v opkg >/dev/null 2>&1; then
	PKG_MGR=opkg
	OLD_VERSION="$(opkg list-installed luci-app-miclash 2>/dev/null | awk 'NR == 1 { print $3 }')"
else
	die 'installed MiClash package was not found'
fi

case "$OLD_VERSION" in 0.9.*) ;; *) die "expected installed MiClash v0.9.x, found: ${OLD_VERSION:-none}" ;; esac
[ -x /etc/init.d/clash ] || die 'legacy clash service is missing'
[ -x /opt/clash/bin/clash-rules ] || die 'legacy cleanup helper is missing'

/etc/init.d/clash enabled >/dev/null 2>&1 && OLD_ENABLED=1 || true
/etc/init.d/clash running >/dev/null 2>&1 && OLD_RUNNING=1 || true
if [ -f /opt/clash/settings ] &&
	grep -Eq '^INTERNET_ONLY_MICLASH=(true|1)$' /opt/clash/settings; then
	GUARD_ENABLED=1
fi
[ "$GUARD_ENABLED" != 1 ] || need uci

WORK="$(mktemp -d /tmp/miclash-v09-clean.XXXXXX)" || die 'cannot create temporary directory'
chmod 0700 "$WORK" || die 'cannot protect temporary directory'
release_base="https://github.com/ang3el7z/luci-app-miclash/releases/download/$TAG"
curl --fail --show-error --location --proto '=https' --tlsv1.2 \
	--connect-timeout 10 --max-time 120 --retry 2 \
	--output "$WORK/install-miclash.sh" "$release_base/install-miclash.sh" || die 'cannot download the v2 installer'
curl --fail --show-error --location --proto '=https' --tlsv1.2 \
	--connect-timeout 10 --max-time 120 --retry 2 \
	--output "$WORK/install-miclash.sh.sha256" "$release_base/install-miclash.sh.sha256" || die 'cannot download the installer checksum'
chmod 0600 "$WORK/install-miclash.sh" "$WORK/install-miclash.sh.sha256" || die 'cannot protect installer files'
expected="$(awk 'NF == 2 && $2 == "install-miclash.sh" { print $1 }' "$WORK/install-miclash.sh.sha256")"
printf '%s\n' "$expected" | grep -Eq '^[0-9a-f]{64}$' || die 'invalid installer checksum file'
[ "$(sha256sum "$WORK/install-miclash.sh" | awk '{ print $1 }')" = "$expected" ] || die 'installer checksum mismatch'
grep -Fq 'MICLASH_CLEAN_INSTALL_PROTOCOL="miclash-clean-install-v1"' "$WORK/install-miclash.sh" ||
	die 'selected v2 release does not support the clean v0.9 upgrade'

stamp="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/miclash-v09-backup-$stamp"
[ ! -e "$BACKUP" ] || die "backup path already exists: $BACKUP"
mkdir -p "$BACKUP/profiles" "$BACKUP/ruleset" "$BACKUP/proxy_providers" "$BACKUP/core" || die 'cannot create backup'
chmod 0700 "$BACKUP" "$BACKUP/profiles" "$BACKUP/ruleset" "$BACKUP/proxy_providers" "$BACKUP/core" || die 'cannot protect backup'

for profile in /opt/clash/config*.yaml; do
	[ -f "$profile" ] || continue
	cp -p "$profile" "$BACKUP/profiles/" || die "cannot back up $profile"
done
[ -f /opt/clash/settings ] && cp -p /opt/clash/settings "$BACKUP/settings.v09" || true
[ -f /opt/clash/bin/clash ] && cp -p /opt/clash/bin/clash "$BACKUP/core/clash" || die 'installed Mihomo core is missing'
[ ! -d /opt/clash/ruleset ] || cp -pR -L /opt/clash/ruleset/. "$BACKUP/ruleset/" || die 'cannot back up rulesets'
[ ! -d /opt/clash/proxy_providers ] || cp -pR -L /opt/clash/proxy_providers/. "$BACKUP/proxy_providers/" || die 'cannot back up providers'
printf 'old_version=%s\nold_enabled=%s\nold_running=%s\nguard_enabled=%s\nrelease_tag=%s\n' \
	"$OLD_VERSION" "$OLD_ENABLED" "$OLD_RUNNING" "$GUARD_ENABLED" "$TAG" > "$BACKUP/upgrade-info"
chmod 0600 "$BACKUP/upgrade-info" "$BACKUP/settings.v09" "$BACKUP/core/clash" 2>/dev/null || true
say "Backup created: $BACKUP"

say 'Stopping and removing MiClash v0.9.x...'
/etc/init.d/clash stop >/dev/null 2>&1 || true
/etc/init.d/clash disable >/dev/null 2>&1 || true
/opt/clash/bin/clash-rules full_cleanup >/dev/null 2>&1 || die 'legacy network cleanup failed'
case "$PKG_MGR" in
	opkg) opkg remove luci-app-miclash || die 'cannot remove the v0.9 package' ;;
	apk) apk del luci-app-miclash || die 'cannot remove the v0.9 package' ;;
esac

rm -rf /opt/clash /etc/config/miclash /etc/miclash
rm -f /etc/init.d/clash /etc/init.d/miclash-autoupdate /etc/init.d/miclash-memory-guard \
	/etc/hotplug.d/iface/40-clash /etc/hotplug.d/net/99-clash-tun /var/etc/miclash.include
if [ -f /etc/crontabs/root ]; then
	sed -i '\|/opt/clash/bin/clash-rules update|d' /etc/crontabs/root || die 'cannot clean legacy cron entry'
fi

say "Installing clean MiClash $TAG..."
sh "$WORK/install-miclash.sh" clean-install --target-tag "$TAG" </dev/null || die "v2 installation failed; backup is kept at $BACKUP"

mkdir -p /opt/clash/bin /opt/clash/ruleset /opt/clash/proxy_providers || die 'cannot create v2 data directories'
cp -p "$BACKUP/core/clash" /opt/clash/bin/clash || die 'cannot restore Mihomo core'
chmod 0700 /opt/clash/bin/clash || die 'cannot protect Mihomo core'
for profile in "$BACKUP"/profiles/config*.yaml; do
	[ -f "$profile" ] || continue
	cp -p "$profile" /opt/clash/ || die "cannot restore ${profile##*/}"
done
cp -pR "$BACKUP/ruleset/." /opt/clash/ruleset/ || die 'cannot restore rulesets'
cp -pR "$BACKUP/proxy_providers/." /opt/clash/proxy_providers/ || die 'cannot restore providers'

if [ "$GUARD_ENABLED" = 1 ]; then
	uci -q set miclash.guard.enabled=1 || die 'cannot restore Guard setting'
	uci -q commit miclash || die 'cannot commit Guard setting'
fi

[ -x /etc/init.d/miclashd ] || die 'v2 miclashd service is missing'
[ -x /etc/init.d/clash ] || die 'v2 clash service is missing'
/etc/init.d/miclashd restart || die 'miclashd did not start'
if [ "$GUARD_ENABLED" = 1 ]; then
	[ -x /etc/init.d/miclash-guard ] || die 'v2 Guard service is missing'
	/etc/init.d/miclash-guard start || die 'v2 Guard did not start'
fi
if [ "$OLD_ENABLED" = 1 ]; then /etc/init.d/clash enable || die 'cannot restore service enable state'; fi
if [ "$OLD_RUNNING" = 1 ]; then
	/etc/init.d/clash start || die 'Mihomo did not start'
	/etc/init.d/clash running >/dev/null 2>&1 || die 'Mihomo is not running after clean install'
fi

say "MiClash $TAG clean installation completed."
say "Your v0.9 backup is kept at: $BACKUP"
