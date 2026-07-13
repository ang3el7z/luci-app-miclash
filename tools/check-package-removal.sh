#!/bin/sh

set -eu

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

if [ "${MICLASH_PACKAGE_REMOVAL_NS:-}" != 1 ]; then
	exec unshare --mount --pid --fork --mount-proc env MICLASH_PACKAGE_REMOVAL_NS=1 sh "$0"
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
		if [ -f "${MICLASH_PACKAGE_TEST_LOG}.fail-unlink" ]; then
			: > "${MICLASH_PACKAGE_TEST_LOG}.held-manifest"
			mount --bind "${MICLASH_PACKAGE_TEST_LOG}.held-manifest" \
				/var/run/miclash/routing-ownership.json
		fi
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
		;;
	start) : > /var/run/miclash/guard-active ;;
esac
EOF
chmod 0700 /etc/init.d/clash /etc/init.d/miclash-guard

cp "$repo_root/luci-app-miclash/rootfs/usr/share/miclash/package-remove" \
	/usr/share/miclash/package-remove
cp "$repo_root/luci-app-miclash/rootfs/usr/share/miclash/routing-cleanup.uc" \
	/usr/share/miclash/routing-cleanup.uc
cp "$repo_root/luci-app-miclash/rootfs/usr/share/miclash/mutation-lock.sh" \
	/usr/share/miclash/mutation-lock.sh
cp "$repo_root/luci-app-miclash/rootfs/usr/share/miclash/package-release" \
	/usr/share/miclash/package-release
chmod 0700 /usr/share/miclash/package-remove
chmod 0600 /usr/share/miclash/mutation-lock.sh
chmod 0700 /usr/share/miclash/package-release

reset_state() {
	umount /var/run/miclash/routing-ownership.json 2>/dev/null || true
	rm -rf /var/run/miclash/package-removal
	rm -rf /var/run/miclash/package-removal-release
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
if [ ! -f /var/run/miclash/guard-active ] ||
	grep -Eq '^miclash-guard (remove|start)$' "$log"; then
	echo 'successful prerm removed the primary Guard before package finalization' >&2
	exit 1
fi
! grep -q '/opt/clash/bin/clash-rules update' /etc/crontabs/root

line_of() { grep -n -m1 "^$1$" "$log" | cut -d: -f1; }
[ "$(line_of 'miclashd stop')" -lt "$(line_of 'clash delete')" ]
[ "$(line_of 'clash delete')" -lt "$(line_of 'routing-cleanup')" ]
[ "$(line_of 'routing-cleanup')" -lt "$(line_of 'clash package_cleanup')" ]
[ "$(cat "$log.probes")" -eq 0 ]

# Stale legacy PID-only worker locks are not identity proof. Package removal
# must never signal an unrelated live process whose PID was recycled into one
# of these records; the shared mutation lease already provides quiescence.
start_unrelated_process() {
	marker="$1"
	release="$2"
	sh -c 'trap '\''printf TERM > "$1"'\'' TERM; while [ ! -e "$2" ]; do sleep 0.02; done' \
		sh "$marker" "$release" &
	unrelated_pid=$!
}

reset_state
rm -f "$log.unrelated-release"
start_unrelated_process "$log.update-unrelated-signalled" "$log.unrelated-release"
update_unrelated_pid="$unrelated_pid"
start_unrelated_process "$log.autoupdate-unrelated-signalled" "$log.unrelated-release"
autoupdate_unrelated_pid="$unrelated_pid"
mkdir -p /tmp/miclash-update.lock /tmp/miclash-autoupdate.lock
printf '%s\n' "$update_unrelated_pid" > /tmp/miclash-update.lock/pid
printf '%s\n' "$autoupdate_unrelated_pid" > /tmp/miclash-autoupdate.lock/pid
/usr/share/miclash/package-remove
if [ -e "$log.update-unrelated-signalled" ] || \
	[ -e "$log.autoupdate-unrelated-signalled" ] || \
	! kill -0 "$update_unrelated_pid" 2>/dev/null || \
	! kill -0 "$autoupdate_unrelated_pid" 2>/dev/null; then
	echo 'package removal signalled an unrelated PID from a stale worker lock' >&2
	exit 1
fi
touch "$log.unrelated-release"
wait "$update_unrelated_pid" 2>/dev/null || true
wait "$autoupdate_unrelated_pid" 2>/dev/null || true
rm -rf /tmp/miclash-update.lock /tmp/miclash-autoupdate.lock

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
! grep -Eq '^miclash-guard (remove|start)$' "$log"

reset_state
: > "$log.fail-preserve"
if /usr/share/miclash/package-remove; then
	echo 'package removal unexpectedly succeeded after preserve cleanup failure' >&2
	exit 1
fi
[ -d /var/run/miclash/package-removal ]
[ -f /var/run/miclash/routing-ownership.json ]
[ -f /var/run/miclash/guard-active ]
! grep -Eq '^miclash-guard (remove|start)$' "$log"

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
! grep -Eq '^miclash-guard (remove|start)$' "$log"

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
! grep -Eq '^miclash-guard (remove|start)$' "$log"

# A real service worker that passed its pre-barrier check must retain the
# shared lease until its synchronous init mutation finishes. Package prerm
# establishes the barrier but may not begin quiescence until that lease exits.
cp "$repo_root/luci-app-miclash/rootfs/opt/clash/bin/miclash-service" \
	/opt/clash/bin/miclash-service
chmod 0700 /opt/clash/bin/miclash-service
cat > "$fixture/bin/delayed-init" <<'EOF'
#!/bin/sh
case "${1:-}" in
	stop)
		echo 'delayed-service mutation-enter' >> "$MICLASH_PACKAGE_TEST_LOG"
		: > "${MICLASH_PACKAGE_TEST_LOG}.writer-entered"
		while [ ! -f "${MICLASH_PACKAGE_TEST_LOG}.writer-release" ]; do sleep 0.02; done
		echo 'delayed-service mutation-exit' >> "$MICLASH_PACKAGE_TEST_LOG"
		;;
esac
exit 0
EOF
chmod 0700 "$fixture/bin/delayed-init"

wait_for_file() {
	path="$1"
	i=0
	while [ ! -e "$path" ] && [ "$i" -lt 250 ]; do sleep 0.02; i=$((i + 1)); done
	[ -e "$path" ]
}

reset_state
rm -f "$log.writer-entered" "$log.writer-release"
MICLASH_CLASH_INIT="$fixture/bin/delayed-init" \
	MICLASH_SERVICE_LOCK_DIR="$fixture/service-lock" \
	MICLASH_SERVICE_STATUS_DIR="$fixture/service-status" \
	/opt/clash/bin/miclash-service stop >/dev/null 2>&1 &
writer_pid=$!
wait_for_file "$log.writer-entered"
/usr/share/miclash/package-remove >/dev/null 2>&1 &
remove_pid=$!
wait_for_file /var/run/miclash/package-removal
sleep 0.2
! grep -q '^miclashd stop$' "$log"
: > "$log.writer-release"
wait "$writer_pid"
wait "$remove_pid"
[ "$(line_of 'delayed-service mutation-exit')" -lt "$(line_of 'miclashd stop')" ]
[ ! -e /var/run/miclash/mutation.lock ]
[ ! -e /var/run/miclash/mutation.lock.takeover ]

# The updater worker acquires inside the background/actual command, before its
# first download-side mutation. The job launcher itself is intentionally not
# the lease owner.
cp "$repo_root/luci-app-miclash/rootfs/opt/clash/bin/miclash-update" \
	/opt/clash/bin/miclash-update
chmod 0700 /opt/clash/bin/miclash-update
cat > "$fixture/bin/curl" <<'EOF'
#!/bin/sh
[ "${1:-}" != --version ] || { echo 'curl test'; exit 0; }
target=""
previous=""
for argument in "$@"; do
	[ "$previous" != -o ] || target="$argument"
	previous="$argument"
done
echo 'delayed-update mutation-enter' >> "$MICLASH_PACKAGE_TEST_LOG"
: > "${MICLASH_PACKAGE_TEST_LOG}.writer-entered"
while [ ! -f "${MICLASH_PACKAGE_TEST_LOG}.writer-release" ]; do sleep 0.02; done
echo 'delayed-update mutation-exit' >> "$MICLASH_PACKAGE_TEST_LOG"
[ -n "$target" ] || exit 1
printf '#!/bin/sh\nexit 0\n' > "$target"
EOF
chmod 0700 "$fixture/bin/curl"
reset_state
rm -f "$log.writer-entered" "$log.writer-release"
/opt/clash/bin/miclash-update app --target-tag test --mode update >/dev/null 2>&1 &
writer_pid=$!
wait_for_file "$log.writer-entered"
/usr/share/miclash/package-remove >/dev/null 2>&1 &
remove_pid=$!
wait_for_file /var/run/miclash/package-removal
sleep 0.2
! grep -q '^miclashd stop$' "$log"
: > "$log.writer-release"
wait "$writer_pid"
wait "$remove_pid"
[ "$(line_of 'delayed-update mutation-exit')" -lt "$(line_of 'miclashd stop')" ]

# Both shipped hotplug entrypoints acquire before invoking their synchronous
# mutation child. The child is delayed here to expose the pre-barrier window.
cat > /opt/clash/bin/clash-rules <<'EOF'
#!/bin/sh
echo 'delayed-tun-hotplug mutation-enter' >> "$MICLASH_PACKAGE_TEST_LOG"
: > "${MICLASH_PACKAGE_TEST_LOG}.writer-entered"
while [ ! -f "${MICLASH_PACKAGE_TEST_LOG}.writer-release" ]; do sleep 0.02; done
echo 'delayed-tun-hotplug mutation-exit' >> "$MICLASH_PACKAGE_TEST_LOG"
exit 0
EOF
chmod 0700 /opt/clash/bin/clash-rules
reset_state
rm -f "$log.writer-entered" "$log.writer-release"
ACTION=add INTERFACE=clash-tun \
	sh "$repo_root/luci-app-miclash/rootfs/etc/hotplug.d/net/99-clash-tun" >/dev/null 2>&1 &
writer_pid=$!
wait_for_file "$log.writer-entered"
/usr/share/miclash/package-remove >/dev/null 2>&1 &
remove_pid=$!
wait_for_file /var/run/miclash/package-removal
sleep 0.2
! grep -q '^miclashd stop$' "$log"
: > "$log.writer-release"
wait "$writer_pid"
wait "$remove_pid"
[ "$(line_of 'delayed-tun-hotplug mutation-exit')" -lt "$(line_of 'miclashd stop')" ]

# Direct clash-rules owns the lease while its first real nft mutation is
# delayed. This also proves a synchronous command shim cannot outlive release.
cp "$repo_root/luci-app-miclash/rootfs/opt/clash/bin/clash-rules" \
	/opt/clash/bin/clash-rules
chmod 0700 /opt/clash/bin/clash-rules
cat > "$fixture/bin/nft" <<'EOF'
#!/bin/sh
echo 'delayed-clash-rules mutation-enter' >> "$MICLASH_PACKAGE_TEST_LOG"
: > "${MICLASH_PACKAGE_TEST_LOG}.writer-entered"
while [ ! -f "${MICLASH_PACKAGE_TEST_LOG}.writer-release" ]; do sleep 0.02; done
echo 'delayed-clash-rules mutation-exit' >> "$MICLASH_PACKAGE_TEST_LOG"
exit 0
EOF
chmod 0700 "$fixture/bin/nft"
reset_state
rm -f "$log.writer-entered" "$log.writer-release"
/opt/clash/bin/clash-rules guard_stop >/dev/null 2>&1 &
writer_pid=$!
wait_for_file "$log.writer-entered"
/usr/share/miclash/package-remove >/dev/null 2>&1 &
remove_pid=$!
wait_for_file /var/run/miclash/package-removal
sleep 0.2
! grep -q '^miclashd stop$' "$log"
: > "$log.writer-release"
wait "$writer_pid"
wait "$remove_pid"
[ "$(line_of 'delayed-clash-rules mutation-exit')" -lt "$(line_of 'miclashd stop')" ]
[ ! -e /var/run/miclash/mutation.lock ]
[ ! -e /var/run/miclash/mutation.lock.takeover ]

cat > "$fixture/bin/pgrep" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$fixture/bin/ip" <<'EOF'
#!/bin/sh
[ "${1:-}" != route ] || echo 'default via 192.0.2.1 dev eth0'
exit 0
EOF
cat > "$fixture/bin/curl" <<'EOF'
#!/bin/sh
case " $* " in
	*' -X PUT '*)
		echo 'delayed-iface-hotplug mutation-enter' >> "$MICLASH_PACKAGE_TEST_LOG"
		: > "${MICLASH_PACKAGE_TEST_LOG}.writer-entered"
		while [ ! -f "${MICLASH_PACKAGE_TEST_LOG}.writer-release" ]; do sleep 0.02; done
		echo 'delayed-iface-hotplug mutation-exit' >> "$MICLASH_PACKAGE_TEST_LOG"
		;;
	*) printf '%s\n' '{"providers":{"p":{"name":"p","type":"HTTP"}}}' ;;
esac
exit 0
EOF
cat > /opt/clash/bin/clash-rules <<'EOF'
#!/bin/sh
exit 0
EOF
chmod 0700 "$fixture/bin/pgrep" "$fixture/bin/ip" "$fixture/bin/curl" \
	/opt/clash/bin/clash-rules
last_line_of() { grep -n "^$1$" "$log" | tail -n 1 | cut -d: -f1; }
reset_state
rm -f "$log.writer-entered" "$log.writer-release"
ACTION=ifup INTERFACE=wan DEVICE=eth0 MICLASH_HOTPLUG_SETTLE_SEC=0 \
	sh "$repo_root/luci-app-miclash/rootfs/etc/hotplug.d/iface/40-clash" >/dev/null 2>&1 &
writer_pid=$!
wait_for_file "$log.writer-entered"
/usr/share/miclash/package-remove >/dev/null 2>&1 &
remove_pid=$!
wait_for_file /var/run/miclash/package-removal
sleep 0.2
! grep -q '^miclashd stop$' "$log"
: > "$log.writer-release"
wait "$writer_pid"
wait "$remove_pid"
[ "$(last_line_of 'delayed-iface-hotplug mutation-exit')" -lt "$(line_of 'miclashd stop')" ]
[ ! -e /var/run/miclash/mutation.lock ]
[ ! -e /var/run/miclash/mutation.lock.takeover ]

# The Guard init entrypoint is a production writer too: start/remove dispatch
# guard-bootstrap.uc, which mutates the permanent firewall ownership rules.
# Rewrite only the fixed ucode executable path in a test copy so the real init
# wrapper can be exercised without writing into the host's /usr/bin.
guard_test="$fixture/miclash-guard-test"
sed "s#/usr/bin/ucode#$fixture/bin/delayed-guard-ucode#g" \
	"$repo_root/luci-app-miclash/rootfs/etc/init.d/miclash-guard" > "$guard_test"
cat > "$fixture/bin/delayed-guard-ucode" <<'EOF'
#!/bin/sh
echo 'delayed-guard-init mutation-enter' >> "$MICLASH_PACKAGE_TEST_LOG"
: > "${MICLASH_PACKAGE_TEST_LOG}.writer-entered"
while [ ! -f "${MICLASH_PACKAGE_TEST_LOG}.writer-release" ]; do sleep 0.02; done
echo 'delayed-guard-init mutation-exit' >> "$MICLASH_PACKAGE_TEST_LOG"
exit 0
EOF
chmod 0700 "$guard_test" "$fixture/bin/delayed-guard-ucode"
reset_state
rm -f "$log.writer-entered" "$log.writer-release"
sh -c '. "$1"; start' sh "$guard_test" >/dev/null 2>&1 &
writer_pid=$!
wait_for_file "$log.writer-entered"
/usr/share/miclash/package-remove >/dev/null 2>&1 &
remove_pid=$!
wait_for_file /var/run/miclash/package-removal
sleep 0.2
! grep -q '^miclashd stop$' "$log"
: > "$log.writer-release"
wait "$writer_pid"
wait "$remove_pid"
[ "$(last_line_of 'delayed-guard-init mutation-exit')" -lt "$(line_of 'miclashd stop')" ]
[ ! -e /var/run/miclash/mutation.lock ]
[ ! -e /var/run/miclash/mutation.lock.takeover ]

printf 'package removal process and failure-preservation gate passed\n'
