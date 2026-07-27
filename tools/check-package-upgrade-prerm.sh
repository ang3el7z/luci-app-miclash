#!/bin/sh

set -eu

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT HUP INT TERM
installer="$repo_root/install-miclash.sh"

sed -n '/^define Package\/\$(PKG_NAME)\/prerm$/,/^endef$/p' \
	"$repo_root/luci-app-miclash/Makefile" |
	sed '1d;$d;s/\$\$/\$/g' > "$fixture/prerm"
chmod 0700 "$fixture/prerm"
cp "$fixture/prerm" "$fixture/current-prerm-pkg"
cp "$fixture/prerm" "$fixture/current-prerm-pkg.before"
chmod 0755 "$fixture/current-prerm-pkg" "$fixture/current-prerm-pkg.before"

remove="$fixture/package-remove"
called="$fixture/remove-called"
sed -i.bak "s#/usr/share/miclash/package-remove#$remove#g" "$fixture/prerm"
rm -f "$fixture/prerm.bak"

cat > "$remove" <<EOF
#!/bin/sh
printf called > "$called"
EOF
chmod 0700 "$remove"

PKG_UPGRADE=1 "$fixture/prerm" remove
[ ! -e "$called" ]

PKG_UPGRADE=0 "$fixture/prerm" /usr/lib/opkg/info/luci-app-miclash.prerm upgrade
[ ! -e "$called" ]

PKG_UPGRADE=0 "$fixture/prerm" upgrade
[ ! -e "$called" ]

PKG_UPGRADE=0 "$fixture/prerm" remove
[ "$(cat "$called")" = called ]

repair_function="$(
	sed -n '/^repair_installed_prerm_upgrade_classification() {$/,/^}$/p' "$installer"
)"
[ -n "$repair_function" ]
init_repair_function="$(
	sed -n '/^repair_installed_miclashd_self_update_stop() {$/,/^}$/p' "$installer"
)"
[ -n "$init_repair_function" ]

vulnerable="$fixture/vulnerable-prerm-pkg"
cat > "$vulnerable" <<'EOF'
#!/bin/sh
[ -n "$IPKG_INSTROOT" ] || {
	case "$1" in
		upgrade|update) ;;
		*) /usr/share/miclash/package-remove || exit 1 ;;
	esac
}
EOF
chmod 0755 "$vulnerable"

(
	stat() { printf '%s\n' '0:755:1'; }
	readlink() { [ "$1" = -f ] && printf '%s\n' "$2"; }
	eval "$repair_function"
	repair_installed_prerm_upgrade_classification "$vulnerable"
	repair_installed_prerm_upgrade_classification "$fixture/current-prerm-pkg"
)
grep -Fq 'case "${2:-${1:-}}" in' "$vulnerable"
! grep -Fq 'case "$1" in' "$vulnerable"
cmp "$fixture/current-prerm-pkg.before" "$fixture/current-prerm-pkg"

legacy_init="$fixture/legacy-miclashd"
cat > "$legacy_init" <<'EOF'
#!/bin/sh /etc/rc.common

START=95
STOP=10
USE_PROCD=1
PACKAGE_REMOVAL_BARRIER="/var/run/miclash/package-removal"

start_service() {
	:
}
EOF
chmod 0755 "$legacy_init"

(
	stat() { printf '%s\n' '0:755:1'; }
	readlink() { [ "$1" = -f ] && printf '%s\n' "$2"; }
	eval "$init_repair_function"
	repair_installed_miclashd_self_update_stop "$legacy_init"
	repair_installed_miclashd_self_update_stop "$legacy_init"
)
grep -Fq 'APP_UPDATE_MARKER="/tmp/miclash-package-no-autostart-autoupdate"' "$legacy_init"
grep -Fq 'start|stop)' "$legacy_init"
grep -Fq 'operation_journal="/tmp/miclash/operations/$operation_id.json"' "$legacy_init"
[ "$(grep -Fc 'app_update_handoff_active()' "$legacy_init")" = 1 ]
sh -n "$legacy_init"

operation=1000000000000-00000001-0123456789abcdef
status="/tmp/miclash/updates/handoff-$operation.status"
journal="/tmp/miclash/operations/$operation.json"
mkdir -p /tmp/miclash/updates /tmp/miclash/operations "$fixture/bin"
chmod 0700 /tmp/miclash /tmp/miclash/updates /tmp/miclash/operations
printf '%s\n' "$status" > /tmp/miclash-package-no-autostart-autoupdate
printf '%s\n' status > "$status"
printf '%s\n' '{"state":"running"}' > "$journal"
chmod 0600 /tmp/miclash-package-no-autostart-autoupdate "$status" "$journal"
cat > "$fixture/bin/ubus" <<'EOF'
#!/bin/sh
printf '%s\n' '{"miclashd":{"instances":{"instance1":{"running":true}}}}'
EOF
cat > "$fixture/bin/jsonfilter" <<'EOF'
#!/bin/sh
cat >/dev/null
printf '%s\n' true
EOF
chmod 0700 "$fixture/bin/ubus" "$fixture/bin/jsonfilter"
(
	PATH="$fixture/bin:$PATH"
	action=stop
	. "$legacy_init"
	[ -z "${USE_PROCD:-}" ]
)
(
	PATH="$fixture/bin:$PATH"
	action=start
	. "$legacy_init"
	[ -z "${USE_PROCD:-}" ]
)
printf '%s\n' '{"state":"interrupted"}' > "$journal"
(
	PATH="$fixture/bin:$PATH"
	action=stop
	. "$legacy_init"
	[ "${USE_PROCD:-}" = 1 ]
)
rm -f /tmp/miclash-package-no-autostart-autoupdate "$status" "$journal"

printf '%s\n' 'package upgrade lifecycle compatibility passed'
