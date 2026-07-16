#!/bin/sh

set -eu

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
[ -n "${UCODE_BIN:-}" ] && [ -x "$UCODE_BIN" ] || {
	echo 'Guard runtime gate requires UCODE_BIN' >&2
	exit 1
}

UCODE_BIN="$UCODE_BIN" "$repo_root/tools/run-ucode-tests.sh" \
	"$repo_root/tests/ucode/test-guard-runtime.uc"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT INT TERM
cat > "$work/entrypoint-overrides" <<'EOF'
routing_mutation_allowed() { return 0; }
miclash_writer_lock_enter() { return 0; }
miclash_writer_lock_leave() { return 0; }
load_all_settings_once() { return 0; }
capture_guard_expected_interfaces() {
	[ -f "$MICLASH_GUARD_EMERGENCY_STATE" ] || return 2
	grep -q 'add table inet miclash_guard_emergency_v1' "$MICLASH_GUARD_EMERGENCY_STATE" || return 2
	grep -q 'priority -310' "$MICLASH_GUARD_EMERGENCY_STATE" || return 2
	grep -q 'meta nfproto ipv4 drop' "$MICLASH_GUARD_EMERGENCY_STATE" || return 2
	grep -q 'meta nfproto ipv6 drop' "$MICLASH_GUARD_EMERGENCY_STATE" || return 2
	printf '%s\n' capture-after-emergency > "$MICLASH_GUARD_CAPTURE_LOG"
	return 1
}
stop() {
	printf '%s\n' stop >> "$MICLASH_GUARD_RESTART_LOG"
	[ ! -e "$MICLASH_GUARD_RESTART_FAIL-stop" ]
}
start() {
	printf '%s\n' start >> "$MICLASH_GUARD_RESTART_LOG"
	[ ! -e "$MICLASH_GUARD_RESTART_FAIL-start" ]
}
EOF
cat > "$work/ucode-stub" <<'EOF'
#!/bin/sh
case " $* " in
	*' /usr/share/miclash/guard-runtime.uc protect '*)
		cat > "$MICLASH_GUARD_EMERGENCY_STATE" <<-'NFT'
		add table inet miclash_guard_emergency_v1
		add chain inet miclash_guard_emergency_v1 protected_direct_drop_v1 { type filter hook forward priority -310; policy accept; }
		add rule inet miclash_guard_emergency_v1 protected_direct_drop_v1 meta nfproto ipv4 drop
		add rule inet miclash_guard_emergency_v1 protected_direct_drop_v1 meta nfproto ipv6 drop
		NFT
		exit 0
		;;
esac
exit 1
EOF
chmod 0700 "$work/ucode-stub"
cat > "$work/mutation-lock-fake" <<'EOF'
miclash_mutation_lock_enter() { return 0; }
miclash_mutation_lock_leave() { return 0; }
EOF
awk -v helper="$work/mutation-lock-fake" -v ucode="$work/ucode-stub" '
	FNR == NR { injection = injection $0 ORS; next }
	/^MUTATION_LOCK_HELPER=/ { print "MUTATION_LOCK_HELPER=\"" helper "\""; next }
	!injected && $0 == "case \"$1\" in" { printf "%s", injection; injected = 1 }
	{ gsub("/usr/bin/ucode", ucode); print }
' "$work/entrypoint-overrides" \
	"$repo_root/luci-app-miclash/rootfs/opt/clash/bin/clash-rules" \
	> "$work/clash-rules"
chmod 0700 "$work/clash-rules"
export MICLASH_GUARD_RESTART_LOG="$work/restart.log"
export MICLASH_GUARD_RESTART_FAIL="$work/fail"
export MICLASH_GUARD_EMERGENCY_STATE="$work/emergency.nft"
export MICLASH_GUARD_CAPTURE_LOG="$work/capture.log"
if "$work/clash-rules" guard_start; then
	echo 'capture failure unexpectedly reported Guard success' >&2
	exit 1
fi
[ "$(cat "$MICLASH_GUARD_CAPTURE_LOG")" = capture-after-emergency ]
[ -s "$MICLASH_GUARD_EMERGENCY_STATE" ]
: > "$work/guard-preserved"
: > "$MICLASH_GUARD_RESTART_FAIL-stop"
if "$work/clash-rules" restart; then
	echo 'shipped clash-rules restart ignored stop failure' >&2
	exit 1
fi
[ "$(cat "$MICLASH_GUARD_RESTART_LOG")" = stop ]
[ -e "$work/guard-preserved" ]
rm -f "$MICLASH_GUARD_RESTART_FAIL-stop"
: > "$MICLASH_GUARD_RESTART_LOG"
: > "$MICLASH_GUARD_RESTART_FAIL-start"
if "$work/clash-rules" restart; then
	echo 'shipped clash-rules restart ignored start failure' >&2
	exit 1
fi
[ "$(cat "$MICLASH_GUARD_RESTART_LOG")" = "$(printf 'stop\nstart')" ]
[ -e "$work/guard-preserved" ]
rm -f "$MICLASH_GUARD_RESTART_FAIL-start"

"${NODE_BIN:-node}" "$repo_root/tools/check-guard-runtime.mjs"

printf 'Guard runtime focused gate passed\n'
