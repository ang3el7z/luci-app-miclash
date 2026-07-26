#!/bin/sh

set -eu

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
installer="$repo_root/install-miclash.sh"
root=/tmp/miclash/updates
operation=0000000000001-00000001-0123456789abcdef
status="$root/handoff-$operation.status"
journal_root=/tmp/miclash/operations
journal="$journal_root/$operation.json"
terminal_target="$journal_root/terminal-target.json"
token=0123456789abcdef0123456789abcdef
token2=fedcba9876543210fedcba9876543210

cleanup() {
	rm -f "$status" "$status".tmp.* "$journal" "$terminal_target" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM
mkdir -p "$root" "$journal_root"
chmod 0700 "$root" "$journal_root"
cleanup

"$installer" status-protocol-test --status-file "$status" --token "$token" \
	--target-tag v9.9.9 --service-was-running 1
[ "$(stat -c '%u:%a' "$status")" = 0:600 ]
[ "$(wc -l < "$status" | tr -d ' ')" = 8 ]
grep -Fxq 'protocol=miclash-update-status-v1' "$status"
grep -Fxq "token=$token" "$status"
grep -Fxq 'state=success' "$status"
grep -Fxq 'phase=done' "$status"
grep -Fxq 'target_version=v9.9.9' "$status"
grep -Fxq 'service_was_running=1' "$status"
grep -Fxq 'postcheck=pending' "$status"
grep -Eq '^updated_at=[0-9]+$' "$status"

printf '%s\n' stale > "$status"
chmod 0600 "$status"
"$installer" status-protocol-test --status-file "$status" --token "$token2" \
	--target-tag v9.9.10_rc1 --service-was-running 0
grep -Fxq "token=$token2" "$status"
grep -Fxq 'target_version=v9.9.10_rc1' "$status"
grep -Fxq 'service_was_running=0' "$status"
! grep -Fq stale "$status"

terminal_function="$(
	sed -n '/^operation_terminal_for_status() {$/,/^}$/p' "$installer"
)"
[ -n "$terminal_function" ]
eval "$terminal_function"

printf '%s\n' '{"state":"running"}' > "$journal"
chmod 0600 "$journal"
! operation_terminal_for_status "$status"

printf '%s\n' '{"state":"success"}' > "$journal"
chmod 0600 "$journal"
operation_terminal_for_status "$status"

printf '%s\n' '{"state":"failure"}' > "$journal"
chmod 0600 "$journal"
operation_terminal_for_status "$status"

mv "$journal" "$terminal_target"
ln -s "$terminal_target" "$journal"
! operation_terminal_for_status "$status"
rm -f "$journal" "$terminal_target"

if "$installer" status-protocol-test --status-file /tmp/foreign.status \
	--token "$token" --target-tag v9.9.9 --service-was-running 1 >/dev/null 2>&1; then
	exit 1
fi

"$installer" installer-security-test

echo 'update status protocol integration passed'
