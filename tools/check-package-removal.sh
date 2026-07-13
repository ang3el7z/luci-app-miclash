#!/bin/sh

set -eu

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

if [ "${MICLASH_PACKAGE_REMOVAL_NS:-}" != 1 ]; then
	exec unshare --mount --pid --fork --mount-proc env MICLASH_PACKAGE_REMOVAL_NS=1 sh "$0"
fi

mount --make-rprivate /
for path in /var/run/miclash /usr/share/miclash /opt/clash/bin /etc/miclash /etc/init.d /etc/crontabs; do
	mkdir -p "$path"
	mount -t tmpfs -o mode=0755,size=1m miclash-package-test "$path"
done
chmod 0700 /var/run/miclash

fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT INT TERM
mkdir -p "$fixture/bin"
log="$fixture/log"
export MICLASH_PACKAGE_TEST_LOG="$log"
export MICLASH_PACKAGE_SHIPPED_INIT="$fixture/clash.init"
export MICLASH_PACKAGE_RULES_SHIM="$fixture/clash-rules-stateful"
export PATH="$fixture/bin:/usr/bin:/bin"

cat > "$fixture/bin/logger" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$fixture/bin/ubus" <<'EOF'
#!/bin/sh
if [ "${1:-}" = call ] && [ "${3:-}" = delete ]; then
	[ -f /var/run/miclash/package-guard-proven ] || {
		echo cleanup-before-package-guard:ubus-delete >> "$MICLASH_PACKAGE_TEST_LOG"
		exit 96
	}
	exit 0
fi
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
[ -d /var/run/miclash/package-removal ]
[ -f /var/run/miclash/guard-active ]
[ -f /var/run/miclash/package-guard-proven ] || {
	echo "cleanup-before-package-guard:ucode:$*" >> "$MICLASH_PACKAGE_TEST_LOG"
	exit 96
}
case "$*" in
	*routing-cleanup.uc*)
		echo routing-cleanup >> "$MICLASH_PACKAGE_TEST_LOG"
		[ -f /var/run/miclash/routing-ownership.json ]
		[ ! -f "${MICLASH_PACKAGE_TEST_LOG}.fail-routing" ] || exit 1
		;;
	*dns-cleanup.uc*)
		echo dns-cleanup >> "$MICLASH_PACKAGE_TEST_LOG"
		[ -f /etc/miclash/dns-ownership.json ]
		[ ! -f "${MICLASH_PACKAGE_TEST_LOG}.fail-dns" ] || exit 1
		if [ -f "${MICLASH_PACKAGE_TEST_LOG}.fail-dns-export" ] &&
		   [ "$(grep -c '^dns-cleanup$' "$MICLASH_PACKAGE_TEST_LOG")" -gt 1 ]; then
			exit 1
		fi
		printf '%s\n' '{"version":1,"owner":"miclash","section":"main","original":{"server":{"present":false,"value":[]},"cachesize":{"present":false,"value":null},"noresolv":{"present":false,"value":null}},"target_preexisting":false,"state":"clean","transition":null,"clean":{"server":{"present":false,"value":[]},"cachesize":{"present":false,"value":null},"noresolv":{"present":false,"value":null}}}' > /etc/miclash/dns-ownership.json
		chmod 0600 /etc/miclash/dns-ownership.json
		rm -f /opt/clash/.dns_backup
		;;
	*) exit 1 ;;
esac
EOF
chmod 0700 "$fixture/bin/logger" "$fixture/bin/ubus" "$fixture/bin/ucode"

for service in miclashd miclash-autoupdate miclash-memory-guard cron; do
	cat > "/etc/init.d/$service" <<'EOF'
#!/bin/sh
echo "$(basename "$0") ${1:-}" >> "$MICLASH_PACKAGE_TEST_LOG"
[ "${1:-}" != stop ] && [ "${1:-}" != restart ] ||
	[ -f /var/run/miclash/package-guard-proven ] || {
		echo "cleanup-before-package-guard:$(basename "$0")-${1:-}" >> "$MICLASH_PACKAGE_TEST_LOG"
	exit 96
}
exit 0
EOF
	chmod 0700 "/etc/init.d/$service"
done

cp "$repo_root/luci-app-miclash/rootfs/etc/init.d/clash" "$MICLASH_PACKAGE_SHIPPED_INIT"
cat > /etc/init.d/clash <<'EOF'
#!/bin/sh
command="${1:-}"
. "$MICLASH_PACKAGE_SHIPPED_INIT" || exit 1
echo "clash $command" >> "$MICLASH_PACKAGE_TEST_LOG"
case "$command" in
	delete)
		echo 0 > "${MICLASH_PACKAGE_TEST_LOG}.probes"
		delete
		;;
	package_cleanup) package_cleanup ;;
	*) exit 1 ;;
esac
EOF

cat > "$MICLASH_PACKAGE_RULES_SHIM" <<'EOF'
#!/bin/sh
. /usr/share/miclash/mutation-lock.sh || exit 1
command="${1:-}"
trusted_package_authority() {
	barrier=/var/run/miclash/package-removal
	[ ! -L "$barrier" ] && [ -d "$barrier" ] &&
		[ "$(stat -c '%u:%a' "$barrier" 2>/dev/null)" = 0:700 ] || return 1
	canonical="$(readlink -f "$barrier" 2>/dev/null)" || return 1
	case "$canonical" in
		/var/run/miclash/package-removal|/run/miclash/package-removal|/tmp/run/miclash/package-removal) ;;
		*) return 1 ;;
	esac
	[ "${MICLASH_MUTATION_LOCK_PACKAGE:-0}" = 1 ] &&
		[ -n "${MICLASH_MUTATION_LOCK_TOKEN:-}" ] || return 1
	miclash_mutation_lock_enter package 0 || return 1
	miclash_mutation_lock_assert_held || return 1
}
leave_authority() { miclash_mutation_lock_leave >/dev/null 2>&1 || true; }
case "$command" in
	package_guard_start)
		trusted_package_authority || exit 97
		echo package-guard-start >> "$MICLASH_PACKAGE_TEST_LOG"
		: > /var/run/miclash/guard-active
		: > /var/run/miclash/package-guard-proven
		leave_authority
		;;
	package_guard_verify)
		trusted_package_authority || exit 97
		[ -f /var/run/miclash/guard-active ] &&
			[ -f /var/run/miclash/package-guard-proven ] || exit 98
		echo package-guard-verify >> "$MICLASH_PACKAGE_TEST_LOG"
		leave_authority
		;;
	package_cleanup)
		trusted_package_authority || exit 97
		[ -f /var/run/miclash/guard-active ] &&
			[ -f /var/run/miclash/package-guard-proven ] || exit 98
		echo rules-package-cleanup >> "$MICLASH_PACKAGE_TEST_LOG"
		[ ! -f "${MICLASH_PACKAGE_TEST_LOG}.fail-preserve" ] || exit 1
		if [ -f "${MICLASH_PACKAGE_TEST_LOG}.fail-unlink" ]; then
			: > "${MICLASH_PACKAGE_TEST_LOG}.held-manifest"
			mount --bind "${MICLASH_PACKAGE_TEST_LOG}.held-manifest" \
				/var/run/miclash/routing-ownership.json
		fi
		leave_authority
		;;
	guard_start)
		echo rejected-ordinary-guard-start >> "$MICLASH_PACKAGE_TEST_LOG"
		exit 99
		;;
	*) exit 1 ;;
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
chmod 0700 /etc/init.d/clash /etc/init.d/miclash-guard "$MICLASH_PACKAGE_SHIPPED_INIT" \
	"$MICLASH_PACKAGE_RULES_SHIM"

cp "$repo_root/luci-app-miclash/rootfs/usr/share/miclash/package-remove" \
	/usr/share/miclash/package-remove
cp "$repo_root/luci-app-miclash/rootfs/usr/share/miclash/routing-cleanup.uc" \
	/usr/share/miclash/routing-cleanup.uc
cp "$repo_root/luci-app-miclash/rootfs/usr/share/miclash/dns-cleanup.uc" \
	/usr/share/miclash/dns-cleanup.uc
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
	rm -f /var/run/miclash/package-guard-proven
	: > /var/run/miclash/routing-ownership.json
	printf '%s\n' '{"version":1,"owner":"miclash","section":"main","original":{"server":{"present":false,"value":[]},"cachesize":{"present":false,"value":null},"noresolv":{"present":false,"value":null}},"target_preexisting":false,"state":"active","transition":null,"clean":null}' > /etc/miclash/dns-ownership.json
	chmod 0600 /etc/miclash/dns-ownership.json
	rm -f /opt/clash/.dns_backup
	: > /var/run/miclash/guard-active
	cp "$MICLASH_PACKAGE_RULES_SHIM" /opt/clash/bin/clash-rules
	chmod 0700 /opt/clash/bin/clash-rules
	: > "$log"
	rm -f "$log.fail-routing" "$log.fail-dns" "$log.fail-dns-export" "$log.fail-preserve" "$log.fail-guard" \
		"$log.fail-unlink" "$log.held-manifest" "$log.probes"
	printf '%s\n' '*/30 * * * * /opt/clash/bin/clash-rules update >/dev/null 2>&1' > /etc/crontabs/root
}

reset_state
mkdir /var/run/miclash/package-removal
chmod 0700 /var/run/miclash/package-removal
if MICLASH_MUTATION_LOCK_PACKAGE=1 /opt/clash/bin/clash-rules package_guard_start >/dev/null 2>&1; then
	echo 'package Guard entrypoint accepted an environment flag without a live inherited lease' >&2
	exit 1
fi
[ ! -e /var/run/miclash/package-guard-proven ]
[ -e /var/run/miclash/guard-active ]
rm -rf /var/run/miclash/package-removal

reset_state
/usr/share/miclash/package-remove
[ -d /var/run/miclash/package-removal ]
[ "$(stat -c '%u:%a' /var/run/miclash/package-removal)" = '0:700' ]
[ ! -e /var/run/miclash/routing-ownership.json ]
[ ! -e /etc/miclash/dns-ownership.json ]
[ -f /var/run/miclash/package-removal-release/dns-ownership.json ]
if [ ! -f /var/run/miclash/guard-active ] ||
	grep -Eq '^miclash-guard (remove|start)$' "$log"; then
	echo 'successful prerm removed the primary Guard before package finalization' >&2
	exit 1
fi
! grep -q '/opt/clash/bin/clash-rules update' /etc/crontabs/root

line_of() { grep -n -m1 "^$1$" "$log" | cut -d: -f1; }
[ "$(line_of 'miclashd stop')" -lt "$(line_of 'clash delete')" ]
[ "$(line_of 'package-guard-start')" -lt "$(line_of 'cron restart')" ]
[ "$(line_of 'clash delete')" -lt "$(line_of 'routing-cleanup')" ]
[ "$(line_of 'routing-cleanup')" -lt "$(line_of 'dns-cleanup')" ]
[ "$(line_of 'dns-cleanup')" -lt "$(line_of 'clash package_cleanup')" ]
[ "$(line_of 'package-guard-verify')" -lt "$(line_of 'rules-package-cleanup')" ]
! grep -q '^cleanup-before-package-guard:' "$log"
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
: > "$log.fail-dns"
if /usr/share/miclash/package-remove; then
	echo 'package removal unexpectedly succeeded after DNS cleanup failure' >&2
	exit 1
fi
[ -d /var/run/miclash/package-removal ]
[ -f /var/run/miclash/routing-ownership.json ]
[ -f /etc/miclash/dns-ownership.json ]
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
: > "$log.fail-dns-export"
if /usr/share/miclash/package-remove; then
	echo 'package removal exported a DNS proof without a fresh final verification' >&2
	exit 1
fi
[ -f /etc/miclash/dns-ownership.json ]
[ ! -e /var/run/miclash/package-removal-release/dns-ownership.json ]
[ "$(grep -c '^dns-cleanup$' "$log")" -eq 2 ]
[ -f /var/run/miclash/guard-active ]

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
cat > "$fixture/delayed-tun-rules" <<'EOF'
#!/bin/sh
case "${1:-}" in
	package_guard_start|package_guard_verify|package_cleanup)
		exec "$MICLASH_PACKAGE_RULES_SHIM" "$@"
		;;
esac
echo 'delayed-tun-hotplug mutation-enter' >> "$MICLASH_PACKAGE_TEST_LOG"
: > "${MICLASH_PACKAGE_TEST_LOG}.writer-entered"
while [ ! -f "${MICLASH_PACKAGE_TEST_LOG}.writer-release" ]; do sleep 0.02; done
echo 'delayed-tun-hotplug mutation-exit' >> "$MICLASH_PACKAGE_TEST_LOG"
exit 0
EOF
reset_state
cp "$fixture/delayed-tun-rules" /opt/clash/bin/clash-rules
chmod 0700 /opt/clash/bin/clash-rules
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
cat > "$fixture/bin/nft" <<'EOF'
#!/bin/sh
if [ ! -f "${MICLASH_PACKAGE_TEST_LOG}.writer-entered" ]; then
	echo 'delayed-clash-rules mutation-enter' >> "$MICLASH_PACKAGE_TEST_LOG"
	: > "${MICLASH_PACKAGE_TEST_LOG}.writer-entered"
	while [ ! -f "${MICLASH_PACKAGE_TEST_LOG}.writer-release" ]; do sleep 0.02; done
	echo 'delayed-clash-rules mutation-exit' >> "$MICLASH_PACKAGE_TEST_LOG"
fi
state="${MICLASH_PACKAGE_TEST_LOG}.nft-guard"
case "$*" in
	'list table inet miclash_guard') [ -f "$state" ] && echo 'table inet miclash_guard' || exit 1 ;;
	'list chain inet miclash_guard forward')
		[ -f "$state" ] || exit 1
		echo 'chain forward { meta nfproto ipv4 drop comment "miclash-guard"; }'
		if [ "${MICLASH_MUTATION_LOCK_PACKAGE:-}" = 1 ]; then
			: > /var/run/miclash/package-guard-proven
			# This scenario's production command has now established and proven
			# Guard. Hand subsequent package-cleanup calls back to the stateful
			# rules shim used by the package-removal integration fixture.
			cp "$MICLASH_PACKAGE_RULES_SHIM" /opt/clash/bin/clash-rules
			chmod 0700 /opt/clash/bin/clash-rules
		fi
		;;
	'delete table inet miclash_guard') rm -f "$state" ;;
	'add table inet miclash_guard') : > "$state" ;;
	add\ *) ;;
	*) exit 0 ;;
esac
EOF
chmod 0700 "$fixture/bin/nft"
reset_state
cp "$repo_root/luci-app-miclash/rootfs/opt/clash/bin/clash-rules" \
	/opt/clash/bin/clash-rules
chmod 0700 /opt/clash/bin/clash-rules
: > "$log.nft-guard"
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
wait "$remove_pid" || {
	echo 'package removal failed after delayed direct clash-rules writer' >&2
	cat "$log" >&2
	exit 1
}
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
cat > "$fixture/iface-rules" <<'EOF'
#!/bin/sh
case "${1:-}" in
	package_guard_start|package_guard_verify|package_cleanup)
		exec "$MICLASH_PACKAGE_RULES_SHIM" "$@"
		;;
	*) exit 0 ;;
esac
EOF
chmod 0700 "$fixture/bin/pgrep" "$fixture/bin/ip" "$fixture/bin/curl" "$fixture/iface-rules"
last_line_of() { grep -n "^$1$" "$log" | tail -n 1 | cut -d: -f1; }
reset_state
cp "$fixture/iface-rules" /opt/clash/bin/clash-rules
chmod 0700 /opt/clash/bin/clash-rules
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
