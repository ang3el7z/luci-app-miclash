#!/bin/sh

set -eu

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
installer="$repo_root/install-miclash.sh"

function_body() {
	sed -n "/^$1() {$/,/^}$/p" "$installer"
}

restore_functions="$(
	function_body clash_is_running
	function_body marker_tracked
	function_body clear_clash_no_autostart_marker
	function_body restore_clash_intent
)"
[ -n "$restore_functions" ] || {
	echo "terminal service restore helpers are missing" >&2
	exit 1
}

fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
init="$fixture/clash"

cat >"$init" <<'EOF'
#!/bin/sh
root="${MICLASH_TEST_STATE:?}"
case "$1" in
	enabled) [ "$(cat "$root/enabled")" = 1 ] ;;
	enable) printf '1' >"$root/enabled" ;;
	disable) printf '0' >"$root/enabled" ;;
	running) [ "$(cat "$root/running")" = 1 ] ;;
	start)
		[ ! -e "$root/start-fails" ] || exit 1
		[ -e "$root/start-noop" ] || printf '1' >"$root/running"
		;;
	stop) printf '0' >"$root/running" ;;
	*) exit 64 ;;
esac
EOF
chmod 0755 "$init"

run_restore() (
	was_running="$1"
	was_enabled="$2"
	expected_running="$3"
	expected_enabled="$4"
	fault="${5:-}"
	state="$fixture/state-$was_running-$was_enabled-${fault:-ok}"
	mkdir "$state"
	printf '0' >"$state/running"
	printf '0' >"$state/enabled"
	OWNED_MARKERS="$state/no-autostart"
	case "$fault" in
		start-fails|start-noop) : >"$state/$fault" ;;
		untrusted-marker) printf 'foreign' >"$state/no-autostart" ;;
		untracked-marker)
			printf 'owned' >"$state/no-autostart"
			OWNED_MARKERS=""
			;;
		*) printf 'owned' >"$state/no-autostart" ;;
	esac

	export MICLASH_TEST_STATE="$state"
	CLASH_INIT="$init"
	NO_AUTOSTART_CLASH_MARKER="$state/no-autostart"
	CLASH_WAS_RUNNING="$was_running"
	CLASH_WAS_ENABLED="$was_enabled"
	CLASH_RESTORE_WAIT_SECONDS=2
	log() { :; }
	warn() { :; }
	sleep() { :; }
	die() { printf '%s\n' "$*" >&2; exit 1; }
	marker_owned() {
		[ -f "$1" ] && [ ! -L "$1" ] && [ "$(cat "$1")" = owned ]
	}
	eval "$restore_functions"

	clear_clash_no_autostart_marker
	restore_clash_intent
	[ ! -e "$NO_AUTOSTART_CLASH_MARKER" ]
	[ "$(cat "$state/running")" = "$expected_running" ]
	[ "$(cat "$state/enabled")" = "$expected_enabled" ]
)

run_restore 1 1 1 1
run_restore 1 0 1 1
run_restore 0 1 0 1
run_restore 0 0 0 0

if run_restore 1 1 1 1 start-fails >/dev/null 2>&1; then
	echo "failed clash restart was accepted" >&2
	exit 1
fi
if run_restore 1 1 1 1 start-noop >/dev/null 2>&1; then
	echo "no-op clash restart was accepted" >&2
	exit 1
fi
if run_restore 0 1 0 1 untrusted-marker >/dev/null 2>&1; then
	echo "untrusted no-autostart marker was removed" >&2
	exit 1
fi
if run_restore 0 1 0 1 untracked-marker >/dev/null 2>&1; then
	echo "untracked no-autostart marker was removed" >&2
	exit 1
fi

main_body="$(sed -n '/^main() {$/,/^}$/p' "$installer")"
capture_line="$(printf '%s\n' "$main_body" | grep -n 'CLASH_WAS_RUNNING=' | head -n1 | cut -d: -f1)"
package_line="$(printf '%s\n' "$main_body" | grep -n 'install_miclash' | head -n1 | cut -d: -f1)"
kernel_line="$(printf '%s\n' "$main_body" | grep -n 'install_mihomo' | tail -n1 | cut -d: -f1)"
restore_line="$(printf '%s\n' "$main_body" | grep -n 'restore_clash_intent' | tail -n1 | cut -d: -f1)"
[ "$capture_line" -lt "$package_line" ]
[ "$kernel_line" -lt "$restore_line" ]

printf '%s\n' "terminal service restore contract passed"
