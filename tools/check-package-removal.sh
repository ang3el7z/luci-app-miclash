#!/bin/sh

set -eu

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

if [ "${MICLASH_PACKAGE_REMOVAL_NS:-}" != 1 ]; then
	exec unshare --mount --pid --fork env MICLASH_PACKAGE_REMOVAL_NS=1 sh "$0"
fi

mount --make-rprivate /
for path in /var/run/miclash /usr/share/miclash /opt/clash/bin /etc/init.d /etc/crontabs; do
	mkdir -p "$path"
	mount -t tmpfs -o mode=0755,size=1m miclash-package-test "$path"
done
chmod 0700 /var/run/miclash

fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT INT TERM
mkdir -p "$fixture/bin"
log="$fixture/log"
export MICLASH_PACKAGE_TEST_LOG="$log"
export PATH="$fixture/bin:/usr/bin:/bin"

cat > "$fixture/bin/logger" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$fixture/bin/ubus" <<'EOF'
#!/bin/sh
if [ "${1:-}" = call ] && [ "${3:-}" = list ]; then
	probes_file="${MICLASH_PACKAGE_TEST_LOG}.probes"
	probes="$(cat "$probes_file" 2>/dev/null || echo 0)"
	if [ "$probes" -gt 0 ]; then
		echo $((probes - 1)) > "$probes_file"
		echo '{"clash":{"instances":{"instance1":{"running":true}}}}'
	else
		echo '{}'
	fi
	exit 0
fi
exit 1
EOF
cat > "$fixture/bin/ucode" <<'EOF'
#!/bin/sh
echo routing-cleanup >> "$MICLASH_PACKAGE_TEST_LOG"
[ -d /var/run/miclash/package-removal ]
[ -f /var/run/miclash/routing-ownership.json ]
[ -f /var/run/miclash/guard-active ]
[ ! -f "${MICLASH_PACKAGE_TEST_LOG}.fail-routing" ] || exit 1
EOF
chmod 0700 "$fixture/bin/logger" "$fixture/bin/ubus" "$fixture/bin/ucode"

for service in miclashd miclash-autoupdate miclash-memory-guard cron; do
	cat > "/etc/init.d/$service" <<'EOF'
#!/bin/sh
echo "$(basename "$0") ${1:-}" >> "$MICLASH_PACKAGE_TEST_LOG"
exit 0
EOF
	chmod 0700 "/etc/init.d/$service"
done

cat > /etc/init.d/clash <<'EOF'
#!/bin/sh
echo "clash ${1:-}" >> "$MICLASH_PACKAGE_TEST_LOG"
case "${1:-}" in
	delete) echo 3 > "${MICLASH_PACKAGE_TEST_LOG}.probes" ;;
	package_cleanup)
		[ -d /var/run/miclash/package-removal ]
		[ ! -f /var/run/miclash/routing-ownership.json ]
		[ -f /var/run/miclash/guard-active ]
		[ ! -f "${MICLASH_PACKAGE_TEST_LOG}.fail-preserve" ] || exit 1
		;;
esac
EOF
cat > /etc/init.d/miclash-guard <<'EOF'
#!/bin/sh
echo "miclash-guard ${1:-}" >> "$MICLASH_PACKAGE_TEST_LOG"
case "${1:-}" in
	remove)
		rm -f /var/run/miclash/guard-active
		[ ! -f "${MICLASH_PACKAGE_TEST_LOG}.fail-guard" ] || exit 1
		if [ -f "${MICLASH_PACKAGE_TEST_LOG}.fail-unlink" ]; then
			: > "${MICLASH_PACKAGE_TEST_LOG}.held-manifest"
			mount --bind "${MICLASH_PACKAGE_TEST_LOG}.held-manifest" \
				/var/run/miclash/routing-ownership.json
		fi
		;;
	start) : > /var/run/miclash/guard-active ;;
esac
EOF
chmod 0700 /etc/init.d/clash /etc/init.d/miclash-guard

cp "$repo_root/luci-app-miclash/rootfs/usr/share/miclash/package-remove" \
	/usr/share/miclash/package-remove
cp "$repo_root/luci-app-miclash/rootfs/usr/share/miclash/routing-cleanup.uc" \
	/usr/share/miclash/routing-cleanup.uc
chmod 0700 /usr/share/miclash/package-remove

reset_state() {
	umount /var/run/miclash/routing-ownership.json 2>/dev/null || true
	rm -rf /var/run/miclash/package-removal
	: > /var/run/miclash/routing-ownership.json
	: > /var/run/miclash/guard-active
	: > "$log"
	rm -f "$log.fail-routing" "$log.fail-preserve" "$log.fail-guard" \
		"$log.fail-unlink" "$log.held-manifest" "$log.probes"
	printf '%s\n' '*/30 * * * * /opt/clash/bin/clash-rules update >/dev/null 2>&1' > /etc/crontabs/root
}

reset_state
/usr/share/miclash/package-remove
[ -d /var/run/miclash/package-removal ]
[ "$(stat -c '%u:%a' /var/run/miclash/package-removal)" = '0:700' ]
[ ! -e /var/run/miclash/routing-ownership.json ]
[ ! -e /var/run/miclash/guard-active ]
! grep -q '/opt/clash/bin/clash-rules update' /etc/crontabs/root

line_of() { grep -n -m1 "^$1$" "$log" | cut -d: -f1; }
[ "$(line_of 'miclashd stop')" -lt "$(line_of 'clash delete')" ]
[ "$(line_of 'clash delete')" -lt "$(line_of 'routing-cleanup')" ]
[ "$(line_of 'routing-cleanup')" -lt "$(line_of 'clash package_cleanup')" ]
[ "$(line_of 'clash package_cleanup')" -lt "$(line_of 'miclash-guard remove')" ]
[ "$(cat "$log.probes")" -eq 0 ]

reset_state
: > "$log.fail-routing"
if /usr/share/miclash/package-remove; then
	echo 'package removal unexpectedly succeeded after routing cleanup failure' >&2
	exit 1
fi
[ -d /var/run/miclash/package-removal ]
[ -f /var/run/miclash/routing-ownership.json ]
[ -f /var/run/miclash/guard-active ]
! grep -q '^clash package_cleanup$' "$log"
! grep -q '^miclash-guard remove$' "$log"

reset_state
: > "$log.fail-preserve"
if /usr/share/miclash/package-remove; then
	echo 'package removal unexpectedly succeeded after preserve cleanup failure' >&2
	exit 1
fi
[ -d /var/run/miclash/package-removal ]
[ -f /var/run/miclash/routing-ownership.json ]
[ -f /var/run/miclash/guard-active ]
! grep -q '^miclash-guard remove$' "$log"

reset_state
: > "$log.fail-guard"
if /usr/share/miclash/package-remove; then
	echo 'package removal unexpectedly succeeded after partial Guard removal' >&2
	exit 1
fi
[ -d /var/run/miclash/package-removal ]
[ -f /var/run/miclash/routing-ownership.json ]
[ -f /var/run/miclash/guard-active ]
grep -q '^miclash-guard start$' "$log"

reset_state
: > "$log.fail-unlink"
if /usr/share/miclash/package-remove; then
	echo 'package removal unexpectedly succeeded when final manifest unlink failed' >&2
	exit 1
fi
[ -d /var/run/miclash/package-removal ]
[ -f /var/run/miclash/routing-ownership.json ]
[ -f /var/run/miclash/guard-active ]
[ ! -e /var/run/miclash/package-removal/complete ]
grep -q '^miclash-guard start$' "$log"

reset_state
rm -rf /var/run/miclash/package-removal
mkdir "$fixture/redirected-barrier"
chmod 0700 "$fixture/redirected-barrier"
ln -s "$fixture/redirected-barrier" /var/run/miclash/package-removal
if /usr/share/miclash/package-remove; then
	echo 'package removal unexpectedly accepted a symlink barrier' >&2
	exit 1
fi
[ -L /var/run/miclash/package-removal ]
[ -f /var/run/miclash/routing-ownership.json ]
[ -f /var/run/miclash/guard-active ]

printf 'package removal process and failure-preservation gate passed\n'
