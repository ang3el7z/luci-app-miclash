#!/bin/sh

set -eu

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
helper="$repo_root/luci-app-miclash/rootfs/usr/share/miclash/package-upgrade-recover"
initd="$repo_root/luci-app-miclash/rootfs/etc/init.d/miclashd"
busybox="${BUSYBOX_BIN:-$(command -v busybox 2>/dev/null || true)}"

[ -f "$helper" ] || {
	echo 'package upgrade recovery helper missing' >&2
	exit 1
}
[ -f "$initd" ] || {
	echo 'miclashd init script missing' >&2
	exit 1
}
[ -n "$busybox" ] || {
	echo 'BusyBox is required for the package upgrade recovery chroot' >&2
	exit 1
}

fixture="$(mktemp -d)"
cleanup() {
	rm -rf "$fixture"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$fixture/bin" "$fixture/dev" "$fixture/etc/init.d" "$fixture/etc/miclash" \
	"$fixture/usr/share/miclash" "$fixture/tmp" "$fixture/var/run"
: > "$fixture/dev/null"
chmod 0666 "$fixture/dev/null"
cp "$busybox" "$fixture/bin/busybox"
for applet in sh stat sed rm rmdir sleep mkdir chmod chown ln cat cmp cp mv wc readlink; do
	ln "$fixture/bin/busybox" "$fixture/bin/$applet"
done
cp "$helper" "$fixture/usr/share/miclash/package-upgrade-recover"
chmod 0700 "$fixture/usr/share/miclash/package-upgrade-recover"
cp "$initd" "$fixture/etc/init.d/miclashd-init"
chmod 0700 "$fixture/etc/init.d/miclashd-init"
sed -n '/^define Package\/\$(PKG_NAME)\/preinst$/,/^endef$/p' \
	"$repo_root/luci-app-miclash/Makefile" | sed '1d;$d;s/\$\$/\$/g' \
	> "$fixture/preinst"
chmod 0700 "$fixture/preinst"
sed -n '/^define Package\/\$(PKG_NAME)\/postinst$/,/^endef$/p' \
	"$repo_root/luci-app-miclash/Makefile" | sed '1d;$d;s/\$\$/\$/g' \
	> "$fixture/postinst"
chmod 0700 "$fixture/postinst"

cat > "$fixture/usr/bin-uci" <<'EOF'
#!/bin/sh
printf '%s\n' uci >> /tmp/calls
cat /tmp/guard-enabled
EOF
cat > "$fixture/usr/bin-ubus" <<'EOF'
#!/bin/sh
printf '%s\n' ubus >> /tmp/calls
[ ! -f /tmp/hold-health ] || {
	: > /tmp/owner-health
	while [ ! -f /tmp/release-health ]; do
		/bin/busybox sleep 1
	done
}
[ ! -f /tmp/health-fail ]
EOF
cat > "$fixture/etc/init.d/miclash-guard" <<'EOF'
#!/bin/sh
printf '%s %s\n' miclash-guard "${1:-}" >> /tmp/calls
case "${1:-}" in
	start) [ ! -f /tmp/fail-guard-start ] ;;
	enable) exit 0 ;;
	*) exit 1 ;;
esac
EOF
cat > "$fixture/etc/init.d/rpcd" <<'EOF'
#!/bin/sh
printf '%s %s\n' rpcd "${1:-}" >> /tmp/calls
[ "${1:-}" = reload ]
EOF
cat > "$fixture/etc/init.d/miclashd" <<'EOF'
#!/bin/sh
printf '%s %s\n' miclashd "${1:-}" >> /tmp/calls
case "${1:-}" in enable|start) exit 0 ;; *) exit 1 ;; esac
EOF
cat > "$fixture/etc/init.d/clash" <<'EOF'
#!/bin/sh
printf '%s %s\n' clash "${1:-}" >> /tmp/calls
case "${1:-}" in
	enabled)
		[ ! -f /tmp/fail-clash-enabled-on ] || exit 1
		[ ! -f /tmp/fail-clash-enabled-off ] || exit 0
		[ "$(cat /tmp/service-enabled)" = 1 ]
		;;
	enable)
		[ ! -f /tmp/fail-clash-enable ] || {
			printf '%s\n' 'injected-child-noise=never-publish-this-secret' >&2
			exit 1
		}
		printf '%s\n' 1 > /tmp/service-enabled
		;;
	disable)
		[ ! -f /tmp/fail-clash-disable ] || exit 1
		printf '%s\n' 0 > /tmp/service-enabled
		;;
	running)
		[ ! -f /tmp/fail-clash-running-on ] || exit 1
		[ ! -f /tmp/fail-clash-running-off ] || exit 0
		[ "$(cat /tmp/service-running)" = 1 ]
		;;
	start)
		[ ! -f /tmp/fail-clash-start ] || exit 1
		printf '%s\n' 1 > /tmp/service-running
		;;
	stop)
		[ ! -f /tmp/fail-clash-stop ] || exit 1
		printf '%s\n' 0 > /tmp/service-running
		;;
	*) exit 1 ;;
esac
EOF
rm "$fixture/bin/mv"
cat > "$fixture/bin/mv" <<'EOF'
#!/bin/sh
printf '%s\n' mv >> /tmp/calls
[ ! -f /tmp/fail-mv ] || exit 1
exec /bin/busybox mv "$@"
EOF
rm "$fixture/bin/sleep"
cat > "$fixture/bin/sleep" <<'EOF'
#!/bin/sh
[ ! -f /tmp/lock-wait-handshake ] || [ -e /tmp/lock-wait-entered ] || {
	: > /tmp/lock-wait-entered
	while [ ! -f /tmp/release-waiter ]; do
		/bin/busybox sleep 1
	done
}
[ ! -f /tmp/lock-wait-sleep ] || exec /bin/busybox sleep "$@"
exit 0
EOF
chmod 0700 "$fixture/usr/bin-uci" "$fixture/usr/bin-ubus" \
	"$fixture/etc/init.d/miclash-guard" "$fixture/etc/init.d/miclashd" \
	"$fixture/etc/init.d/rpcd" "$fixture/etc/init.d/clash" "$fixture/bin/mv" \
	"$fixture/bin/sleep"
ln -s /usr/bin-uci "$fixture/bin/uci"
ln -s /usr/bin-ubus "$fixture/bin/ubus"

write_state() {
	printf '%s\n' "$@" > "$fixture/etc/miclash/package-upgrade-state"
	chmod 0600 "$fixture/etc/miclash/package-upgrade-state"
}

expect_calls() {
	label="$1"
	shift
	: > "$fixture/tmp/expected-calls"
	[ "$#" -eq 0 ] || printf '%s\n' "$@" > "$fixture/tmp/expected-calls"
	chroot "$fixture" /bin/cmp /tmp/expected-calls /tmp/calls || {
		echo "$label: unexpected recovery command order" >&2
		chroot "$fixture" /bin/cat /tmp/calls >&2
		exit 1
	}
}

expect_health_failure_calls() {
	printf '%s\n' uci 'miclash-guard start' > "$fixture/tmp/expected-calls"
	attempt=0
	while [ "$attempt" -lt 30 ]; do
		printf '%s\n' ubus >> "$fixture/tmp/expected-calls"
		attempt=$((attempt + 1))
	done
	chroot "$fixture" /bin/cmp /tmp/expected-calls /tmp/calls || {
		echo 'daemon health failure: unexpected recovery command order' >&2
		exit 1
	}
}

prepare() {
	rm -rf "$fixture/var/run"
	rm -f "$fixture/etc/miclash/package-upgrade-state" "$fixture/etc/miclash/package-upgrade-state-link" \
		"$fixture/etc/miclash/package-upgrade-state-hardlink" \
		"$fixture/tmp/calls" "$fixture/tmp/health-fail" "$fixture/tmp/fail-guard-start" \
		"$fixture/tmp/hold-health" "$fixture/tmp/owner-health" "$fixture/tmp/release-health" \
		"$fixture/tmp/lock-wait-sleep" "$fixture/tmp/lock-wait-handshake" \
		"$fixture/tmp/lock-wait-entered" "$fixture/tmp/release-waiter" \
		"$fixture/tmp/recovery-pid" \
		"$fixture/tmp/fail-clash-enable" "$fixture/tmp/fail-clash-enabled-on" \
		"$fixture/tmp/fail-clash-enabled-off" "$fixture/tmp/fail-clash-start" \
		"$fixture/tmp/fail-clash-running-on" "$fixture/tmp/fail-clash-running-off" \
		"$fixture/tmp/fail-clash-stop" "$fixture/tmp/fail-clash-disable" "$fixture/tmp/fail-mv"
	rm -f "$fixture/tmp/miclash-package-no-autostart-autoupdate" \
		"$fixture/tmp/miclash-package-no-autostart-autoupdate-target"
	printf '%s\n' 1 > "$fixture/tmp/guard-enabled"
	printf '%s\n' 0 > "$fixture/tmp/service-running"
	printf '%s\n' 0 > "$fixture/tmp/service-enabled"
	: > "$fixture/tmp/calls"
}

run_recovery() {
	chroot "$fixture" /usr/share/miclash/package-upgrade-recover /etc/miclash/package-upgrade-state
}

run_recovery_tracked() {
	exec chroot "$fixture" /bin/sh -c '
		helper="$(sed -n "1p" /tmp/upgrade-recover-command)"
		state="$(sed -n "2p" /tmp/upgrade-recover-command)"
		printf "%s\\n" "$$" > /tmp/recovery-pid
		exec "$helper" "$state"
	'
}

assert_lock_removed() {
	[ ! -e "$fixture/var/run/miclash/package-upgrade-recover.lock" ] &&
		[ ! -L "$fixture/var/run/miclash/package-upgrade-recover.lock" ] || {
		echo "$1: recovery lock was retained" >&2
		exit 1
	}
}

wait_for_file() {
	path="$1"
	label="$2"
	attempt=0
	while [ ! -e "$path" ]; do
		attempt=$((attempt + 1))
		[ "$attempt" -lt 10 ] || {
			echo "$label" >&2
			exit 1
		}
		sleep 1
	done
}

wait_for_owner_health() {
	wait_for_file "$fixture/tmp/owner-health" \
		'concurrent recovery: owner did not reach readiness'
}

assert_removed() {
	[ ! -e "$fixture/etc/miclash/package-upgrade-state" ] &&
		[ ! -L "$fixture/etc/miclash/package-upgrade-state" ] || {
		echo "$1: successful recovery retained its journal" >&2
		exit 1
	}
}

assert_retained() {
	[ -e "$fixture/etc/miclash/package-upgrade-state" ] ||
		[ -L "$fixture/etc/miclash/package-upgrade-state" ] || {
		echo "$1: failed recovery deleted its journal" >&2
		exit 1
	}
}

prepare_preinst() {
	prepare
	mkdir -p "$fixture/etc/config"
	printf '%s\n' config > "$fixture/etc/config/miclash"
	chmod 0600 "$fixture/etc/config/miclash"
	printf '%s\n' 1 > "$fixture/tmp/service-running"
}

run_preinst() {
	chroot "$fixture" /preinst
}

prepare_postinst() {
	prepare
	mkdir -p "$fixture/etc/config" "$fixture/opt/clash"
	printf '%s\n' config > "$fixture/etc/config/miclash"
	chmod 0600 "$fixture/etc/config/miclash"
	printf '%s\n' retained > "$fixture/opt/clash/.config.yaml.upgrade.bak"
}

run_postinst() {
	chroot "$fixture" /postinst
}

capture_upgrade_recover_command() {
	cat > "$fixture/run-init-capture" <<'EOF'
#!/bin/sh
current=
procd_open_instance() { current="$1"; }
procd_set_param() {
	[ "$1" = command ] && [ "$current" = upgrade-recover ] || return 0
	shift
	: > /tmp/upgrade-recover-command
	for argument in "$@"; do
		printf '%s\n' "$argument" >> /tmp/upgrade-recover-command
	done
}
procd_close_instance() { :; }
. /etc/init.d/miclashd-init
start_service
EOF
	chmod 0700 "$fixture/run-init-capture"
	chroot "$fixture" /run-init-capture
	printf '%s\n' /usr/share/miclash/package-upgrade-recover \
		/etc/miclash/package-upgrade-state > "$fixture/tmp/expected-upgrade-recover-command"
	cmp "$fixture/tmp/expected-upgrade-recover-command" \
		"$fixture/tmp/upgrade-recover-command" || {
		echo 'boot recovery command: procd does not directly own the helper and state path' >&2
		exit 1
	}
	! grep -q '^/bin/sh$' "$fixture/tmp/upgrade-recover-command" || {
		echo 'boot recovery command: procd retained a shell wrapper' >&2
		exit 1
	}
}

run_registered_recovery_capture() {
	cat > "$fixture/run-registered-recovery-capture" <<'EOF'
#!/bin/sh
helper="$(sed -n '1p' /tmp/upgrade-recover-command)"
state="$(sed -n '2p' /tmp/upgrade-recover-command)"
"$helper" "$state" > /tmp/boot-recover.stdout 2> /tmp/boot-recover.stderr
printf '%s\n' "$?" > /tmp/boot-recover-exit
EOF
	chmod 0700 "$fixture/run-registered-recovery-capture"
	chroot "$fixture" /run-registered-recovery-capture
}

assert_boot_recovery_failure_log() {
	prepare
	write_state version=2 guard_enabled=1 service_running=1 service_enabled=0
	: > "$fixture/tmp/fail-clash-enable"
	run_registered_recovery_capture
	printf '%s\n' 'MiClash package upgrade recovery remains pending' > "$fixture/tmp/expected-boot-recover.stderr"
	cmp "$fixture/tmp/expected-boot-recover.stderr" "$fixture/tmp/boot-recover.stderr" || {
		echo 'boot recovery failure: emitted secret, verbose, or repeated stderr output' >&2
		exit 1
	}
	[ "$(cat "$fixture/tmp/boot-recover-exit")" = 1 ] || {
		echo 'boot recovery failure: helper failure was not propagated' >&2
		exit 1
		}
}

assert_boot_recovery_silent() {
	label="$1"
	prepare
	[ "$label" != success ] || write_state version=2 guard_enabled=1 service_running=1 service_enabled=0
	run_registered_recovery_capture
	[ "$(cat "$fixture/tmp/boot-recover-exit")" = 0 ] || {
		echo "boot recovery $label: successful recovery did not return zero" >&2
		exit 1
	}
	[ ! -s "$fixture/tmp/boot-recover.stdout" ] && [ ! -s "$fixture/tmp/boot-recover.stderr" ] || {
		echo "boot recovery $label: successful or missing recovery emitted output" >&2
		exit 1
	}
}

expect_postinst_preamble() {
	label="$1"
	shift
	expect_calls "$label" 'rpcd reload' 'miclash-guard enable' 'miclash-guard start' \
		'miclashd enable' 'miclashd start' "$@"
}

assert_preinst_state() {
	printf '%s\n' version=2 guard_enabled=1 service_running=1 service_enabled=0 \
		> "$fixture/tmp/expected-state"
	cmp "$fixture/tmp/expected-state" "$fixture/etc/miclash/package-upgrade-state" || {
		echo "$1: preinst wrote an unexpected journal" >&2
		exit 1
	}
	[ "$(stat -c '%u:%a:%h' "$fixture/etc/miclash/package-upgrade-state")" = '0:600:1' ] || {
		echo "$1: preinst journal is not root-owned mode 0600 with one link" >&2
		exit 1
	}
}

assert_retry_on() {
	label="$1"
	fault="$2"
	prepare
	write_state version=2 guard_enabled=1 service_running=1 service_enabled=0
	: > "$fixture/tmp/$fault"
	if run_recovery; then
		echo "$label: faulted recovery unexpectedly succeeded" >&2
		exit 1
	fi
	assert_retained "$label"
	rm -f "$fixture/tmp/$fault"
	run_recovery
	assert_removed "$label retry"
	[ "$(cat "$fixture/tmp/service-running")" = 1 ] &&
		[ "$(cat "$fixture/tmp/service-enabled")" = 1 ] || exit 1
}

assert_retry_off() {
	label="$1"
	fault="$2"
	prepare
	write_state version=2 guard_enabled=1 service_running=0 service_enabled=0
	: > "$fixture/tmp/$fault"
	if run_recovery; then
		echo "$label: faulted recovery unexpectedly succeeded" >&2
		exit 1
	fi
	assert_retained "$label"
	rm -f "$fixture/tmp/$fault"
	run_recovery
	assert_removed "$label retry"
	[ "$(cat "$fixture/tmp/service-running")" = 0 ] &&
		[ "$(cat "$fixture/tmp/service-enabled")" = 0 ] || exit 1
}

capture_upgrade_recover_command

prepare
write_state version=2 guard_enabled=1 service_running=1 service_enabled=0
: > "$fixture/tmp/hold-health"
run_recovery &
owner_pid=$!
wait_for_owner_health
[ -d "$fixture/var/run/miclash/package-upgrade-recover.lock" ] || {
	echo 'concurrent recovery: owner did not acquire the runtime lock' >&2
	exit 1
}
: > "$fixture/tmp/lock-wait-sleep"
: > "$fixture/tmp/lock-wait-handshake"
run_recovery &
waiter_pid=$!
wait_for_file "$fixture/tmp/lock-wait-entered" \
	'concurrent recovery: waiter did not enter the lock wait path'
: > "$fixture/tmp/release-health"
wait "$owner_pid" || {
	echo 'concurrent recovery: owner unexpectedly failed' >&2
	exit 1
}
: > "$fixture/tmp/release-waiter"
wait "$waiter_pid" || {
	echo 'concurrent recovery: waiter did not complete after journal removal' >&2
	exit 1
}
assert_removed 'concurrent recovery'
assert_lock_removed 'concurrent recovery'
expect_calls 'concurrent recovery' uci 'miclash-guard start' ubus 'clash enable' 'clash enabled' \
	'clash running' 'clash start' 'clash running'

prepare
write_state version=2 guard_enabled=1 service_running=1 service_enabled=0
: > "$fixture/tmp/hold-health"
run_recovery_tracked &
interrupted_owner_pid=$!
wait_for_owner_health
[ -d "$fixture/var/run/miclash/package-upgrade-recover.lock" ] || {
	echo 'signal interruption: owner did not acquire the runtime lock' >&2
	exit 1
}
wait_for_file "$fixture/tmp/recovery-pid" \
	'signal interruption: owner did not publish its helper pid'
[ "$(cat "$fixture/tmp/recovery-pid")" = "$interrupted_owner_pid" ] || {
	echo 'signal interruption: registered procd pid did not become the helper pid' >&2
	exit 1
}
kill -TERM "$(cat "$fixture/tmp/recovery-pid")"
: > "$fixture/tmp/release-health"
attempt=0
while [ -e "$fixture/var/run/miclash/package-upgrade-recover.lock" ]; do
	attempt=$((attempt + 1))
	[ "$attempt" -lt 10 ] || {
		echo 'signal interruption: owner did not release the runtime lock' >&2
		exit 1
	}
	sleep 1
done
if wait "$interrupted_owner_pid"; then
	echo 'signal interruption: interrupted owner unexpectedly succeeded' >&2
	exit 1
fi
assert_retained 'signal interruption'
run_recovery &
successor_pid=$!
wait "$successor_pid" || {
	echo 'signal interruption: successor did not recover retained journal' >&2
	exit 1
}
assert_removed 'signal interruption retry'
assert_lock_removed 'signal interruption retry'
expect_calls 'signal interruption retry' uci 'miclash-guard start' ubus \
	uci 'miclash-guard start' ubus 'clash enable' 'clash enabled' \
	'clash running' 'clash start' 'clash running'

prepare
write_state version=2 guard_enabled=1 service_running=1 service_enabled=0
: > "$fixture/tmp/fail-guard-start"
if run_recovery; then
	echo 'failed owner: faulted recovery unexpectedly succeeded' >&2
	exit 1
fi
assert_retained 'failed owner'
assert_lock_removed 'failed owner'

prepare
write_state version=2 guard_enabled=1 service_running=1 service_enabled=0
mkdir -p "$fixture/var/run/miclash/package-upgrade-recover.lock"
rm -rf "$fixture/var/run"
run_recovery
assert_removed 'runtime lock reboot recovery'
assert_lock_removed 'runtime lock reboot recovery'

prepare
write_state version=2 guard_enabled=1 service_running=1 service_enabled=0
mkdir -p "$fixture/var/run/miclash"
: > "$fixture/var/run/miclash/package-upgrade-recover.lock"
if run_recovery; then
	echo 'unsafe runtime lock: recovery unexpectedly succeeded' >&2
	exit 1
fi
assert_retained 'unsafe runtime lock'
[ -f "$fixture/var/run/miclash/package-upgrade-recover.lock" ] || {
	echo 'unsafe runtime lock: recovery removed an unknown lock object' >&2
	exit 1
}

prepare_preinst
: > "$fixture/tmp/fail-mv"
if run_preinst; then
	echo 'preinst atomic replacement: mv failure unexpectedly succeeded' >&2
	exit 1
fi

[ ! -e "$fixture/etc/miclash/package-upgrade-state" ] || {
	echo 'preinst atomic replacement: failed transaction published a partial journal' >&2
	exit 1
}

prepare_preinst
run_preinst
assert_preinst_state 'preinst v2 capture'

# A retained authenticated journal is the transaction's durable intent. A
# retry must not snapshot the partially changed service state instead.
prepare_preinst
write_state version=2 guard_enabled=1 service_running=0 service_enabled=0
cp "$fixture/etc/miclash/package-upgrade-state" "$fixture/tmp/original-off-state"
printf '%s\n' 1 > "$fixture/tmp/service-enabled"
: > "$fixture/tmp/fail-clash-disable"
if run_recovery; then
	echo 'retained OFF retry: faulted recovery unexpectedly succeeded' >&2
	exit 1
fi
assert_retained 'retained OFF retry'
run_preinst
cmp "$fixture/tmp/original-off-state" "$fixture/etc/miclash/package-upgrade-state" || {
	echo 'retained OFF retry: preinst overwrote the original durable intent' >&2
	exit 1
}
rm -f "$fixture/tmp/fail-clash-disable"
run_recovery
assert_removed 'retained OFF retry recovery'
[ "$(cat "$fixture/tmp/service-running")" = 0 ] &&
	[ "$(cat "$fixture/tmp/service-enabled")" = 0 ] || {
	echo 'retained OFF retry: recovery did not restore stopped and disabled state' >&2
	exit 1
}

prepare_preinst
printf '%s\n' sentinel > "$fixture/etc/miclash/preinst-target"
ln -s /etc/miclash/preinst-target "$fixture/etc/miclash/package-upgrade-state"
if run_preinst; then
	echo 'preinst symlink journal: unexpectedly succeeded' >&2
	exit 1
fi
[ "$(cat "$fixture/etc/miclash/preinst-target")" = sentinel ] || {
	echo 'preinst symlink journal: target was modified' >&2
	exit 1
}

prepare_preinst
write_state version=3 guard_enabled=1 service_running=0 service_enabled=0
cp "$fixture/etc/miclash/package-upgrade-state" "$fixture/tmp/invalid-preinst-state"
if run_preinst; then
	echo 'preinst invalid journal: unexpectedly accepted malformed retained state' >&2
	exit 1
fi
cmp "$fixture/tmp/invalid-preinst-state" "$fixture/etc/miclash/package-upgrade-state" || {
	echo 'preinst invalid journal: malformed retained state was replaced' >&2
	exit 1
}

prepare_preinst
write_state version=1 guard_enabled=0 service_running=0
ln "$fixture/etc/miclash/package-upgrade-state" \
	"$fixture/etc/miclash/package-upgrade-state-hardlink"
if run_preinst; then
	echo 'preinst hardlinked journal: unexpectedly succeeded' >&2
	exit 1
fi
assert_retained 'preinst hardlinked journal'

prepare
mkdir -p "$fixture/etc/config"
printf '%s\n' config > "$fixture/etc/config/miclash"
rm -rf "$fixture/etc/miclash"
ln -s /tmp "$fixture/etc/miclash"
if run_preinst; then
	echo 'preinst symlink state directory: unexpectedly succeeded' >&2
	exit 1
fi
[ ! -e "$fixture/tmp/package-upgrade-state" ] || {
	echo 'preinst symlink state directory: journal escaped trusted directory' >&2
	exit 1
}
rm "$fixture/etc/miclash"
mkdir "$fixture/etc/miclash"
chmod 0700 "$fixture/etc/miclash"

assert_retry_on 'Guard start failure' fail-guard-start
assert_retry_on 'clash enable failure' fail-clash-enable
assert_retry_on 'clash enabled verification failure' fail-clash-enabled-on
assert_retry_on 'clash start failure' fail-clash-start
assert_retry_on 'clash running verification failure' fail-clash-running-on
assert_retry_off 'clash stop failure' fail-clash-stop
assert_retry_off 'clash running-off verification failure' fail-clash-running-off
assert_retry_off 'clash disable failure' fail-clash-disable
assert_retry_off 'clash enabled-off verification failure' fail-clash-enabled-off

prepare
write_state version=1 guard_enabled=1 service_running=1
run_recovery
assert_removed 'v1 running=1'
expect_calls 'v1 running=1' uci 'miclash-guard start' ubus 'clash enable' 'clash enabled' \
	'clash running' 'clash start' 'clash running'
[ "$(cat "$fixture/tmp/service-running")" = 1 ] && [ "$(cat "$fixture/tmp/service-enabled")" = 1 ] || exit 1

prepare
write_state version=2 guard_enabled=1 service_running=1 service_enabled=0
run_recovery
assert_removed 'v2 running=1 enabled=0'
expect_calls 'v2 running=1 enabled=0' uci 'miclash-guard start' ubus 'clash enable' 'clash enabled' \
	'clash running' 'clash start' 'clash running'
[ "$(cat "$fixture/tmp/service-running")" = 1 ] && [ "$(cat "$fixture/tmp/service-enabled")" = 1 ] || exit 1

prepare
write_state version=2 guard_enabled=1 service_running=0 service_enabled=1
run_recovery
assert_removed 'v2 running=0 enabled=1'
expect_calls 'v2 running=0 enabled=1' uci 'miclash-guard start' ubus 'clash enable' 'clash enabled' \
	'clash running' 'clash start' 'clash running'
[ "$(cat "$fixture/tmp/service-running")" = 1 ] && [ "$(cat "$fixture/tmp/service-enabled")" = 1 ] || exit 1

prepare
write_state version=2 guard_enabled=1 service_running=0 service_enabled=0
run_recovery
assert_removed 'v2 running=0 enabled=0'
expect_calls 'v2 running=0 enabled=0' uci 'miclash-guard start' ubus 'clash stop' 'clash running' \
	'clash disable' 'clash enabled'
[ "$(cat "$fixture/tmp/service-running")" = 0 ] && [ "$(cat "$fixture/tmp/service-enabled")" = 0 ] || exit 1

# Run the actual rendered postinst against the same controlled package image.
prepare_postinst
write_state version=2 guard_enabled=1 service_running=0 service_enabled=0
run_postinst
assert_removed 'normal postinst update'
expect_postinst_preamble 'normal postinst update' uci 'miclash-guard start' ubus \
	'clash stop' 'clash running' 'clash disable' 'clash enabled'

prepare_postinst
write_state version=2 guard_enabled=1 service_running=0 service_enabled=0
: > "$fixture/tmp/miclash-package-no-autostart-autoupdate"
chmod 0600 "$fixture/tmp/miclash-package-no-autostart-autoupdate"
run_postinst
assert_retained 'app-marker postinst update'
[ ! -e "$fixture/tmp/miclash-package-no-autostart-autoupdate" ] || {
	echo 'app-marker postinst update: authenticated marker was not consumed' >&2
	exit 1
}
expect_postinst_preamble 'app-marker postinst update'

prepare_postinst
mkdir -p "$fixture/staging/etc/config" "$fixture/staging/opt/clash"
printf '%s\n' config > "$fixture/staging/etc/config/miclash"
printf '%s\n' retained > "$fixture/staging/opt/clash/.config.yaml.upgrade.bak"
: > "$fixture/tmp/miclash-package-no-autostart-autoupdate"
chmod 0600 "$fixture/tmp/miclash-package-no-autostart-autoupdate"
chroot "$fixture" /bin/sh -c 'IPKG_INSTROOT=/staging /postinst'
[ -e "$fixture/tmp/miclash-package-no-autostart-autoupdate" ] || {
	echo 'staging postinst update: marker was consumed outside the live root' >&2
	exit 1
}
expect_calls 'staging postinst update'

prepare_postinst
write_state version=2 guard_enabled=1 service_running=0 service_enabled=0
printf '%s\n' sentinel > "$fixture/tmp/miclash-package-no-autostart-autoupdate-target"
ln -s /tmp/miclash-package-no-autostart-autoupdate-target \
	"$fixture/tmp/miclash-package-no-autostart-autoupdate"
run_postinst
assert_removed 'unsafe app-marker postinst update'
[ -L "$fixture/tmp/miclash-package-no-autostart-autoupdate" ] || {
	echo 'unsafe app-marker postinst update: marker was unexpectedly consumed' >&2
	exit 1
}
expect_postinst_preamble 'unsafe app-marker postinst update' uci 'miclash-guard start' ubus \
	'clash stop' 'clash running' 'clash disable' 'clash enabled'

prepare_postinst
ln -s /etc/miclash/missing-upgrade-state "$fixture/etc/miclash/package-upgrade-state"
if run_postinst; then
	echo 'dangling journal postinst update: unexpectedly succeeded' >&2
	exit 1
fi
assert_retained 'dangling journal postinst update'
expect_postinst_preamble 'dangling journal postinst update'

prepare
write_state version=2 guard_enabled=1 service_running=1 service_enabled=0
: > "$fixture/tmp/health-fail"
if run_recovery; then
	echo 'daemon health failure: recovery unexpectedly succeeded' >&2
	exit 1
fi
assert_retained 'daemon health failure'
expect_health_failure_calls

prepare
write_state version=2 guard_enabled=1 service_running=1 service_enabled=0
printf '%s\n' 0 > "$fixture/tmp/guard-enabled"
if run_recovery; then
	echo 'Guard mismatch: recovery unexpectedly succeeded' >&2
	exit 1
fi
assert_retained 'Guard mismatch'
expect_calls 'Guard mismatch' uci

prepare
write_state version=2 guard_enabled=1 service_running=1 service_enabled=0
chmod 0644 "$fixture/etc/miclash/package-upgrade-state"
if run_recovery; then
	echo 'invalid journal: recovery unexpectedly succeeded' >&2
	exit 1
fi
assert_retained 'invalid journal'
expect_calls 'invalid journal'

prepare
write_state version=2 guard_enabled=1 service_running=1 service_enabled=0
chown 1:1 "$fixture/etc/miclash/package-upgrade-state"
if run_recovery; then
	echo 'wrong-owner journal: recovery unexpectedly succeeded' >&2
	exit 1
fi
assert_retained 'wrong-owner journal'
expect_calls 'wrong-owner journal'

prepare
write_state version=2 guard_enabled=1 service_running=1 service_enabled=0
printf '%0513d\n' 0 >> "$fixture/etc/miclash/package-upgrade-state"
if run_recovery; then
	echo 'oversized journal: recovery unexpectedly succeeded' >&2
	exit 1
fi
assert_retained 'oversized journal'
expect_calls 'oversized journal'

prepare
write_state version=2 guard_enabled=1 service_running=1 service_enabled=0
printf '%065d\n' 0 >> "$fixture/etc/miclash/package-upgrade-state"
if run_recovery; then
	echo 'overlong journal line: recovery unexpectedly succeeded' >&2
	exit 1
fi
assert_retained 'overlong journal line'
expect_calls 'overlong journal line'

prepare
write_state version=3 guard_enabled=1 service_running=1 service_enabled=0
if run_recovery; then
	echo 'unknown journal version: recovery unexpectedly succeeded' >&2
	exit 1
fi
assert_retained 'unknown journal version'
expect_calls 'unknown journal version'

prepare
write_state version=2 guard_enabled=1 service_running=1 service_enabled=0 service_enabled=1
if run_recovery; then
	echo 'duplicate journal field: recovery unexpectedly succeeded' >&2
	exit 1
fi
assert_retained 'duplicate journal field'
expect_calls 'duplicate journal field'

prepare
write_state version=2 guard_enabled=1 service_running=1 service_enabled=0 unexpected=1
if run_recovery; then
	echo 'unknown journal field: recovery unexpectedly succeeded' >&2
	exit 1
fi
assert_retained 'unknown journal field'
expect_calls 'unknown journal field'

prepare
write_state version=2 guard_enabled=1 service_running=1 service_enabled=0
ln "$fixture/etc/miclash/package-upgrade-state" "$fixture/etc/miclash/package-upgrade-state-hardlink"
if run_recovery; then
	echo 'hardlinked journal: recovery unexpectedly succeeded' >&2
	exit 1
fi
assert_retained 'hardlinked journal'
expect_calls 'hardlinked journal'

prepare
write_state version=2 guard_enabled=1 service_running=1 service_enabled=0
mv "$fixture/etc/miclash/package-upgrade-state" "$fixture/etc/miclash/package-upgrade-state-link"
ln -s /etc/miclash/package-upgrade-state-link "$fixture/etc/miclash/package-upgrade-state"
if run_recovery; then
	echo 'symlink journal: recovery unexpectedly succeeded' >&2
	exit 1
fi
assert_retained 'symlink journal'
expect_calls 'symlink journal'

prepare
run_recovery
expect_calls 'missing journal'

prepare
assert_boot_recovery_failure_log
assert_boot_recovery_silent success
assert_boot_recovery_silent missing

echo 'package upgrade recovery behavior passed'
