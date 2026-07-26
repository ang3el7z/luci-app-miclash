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

printf '%s\n' 'package upgrade prerm classification passed'
