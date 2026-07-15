#!/bin/sh

set -eu

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
installer="$repo_root/install-miclash.sh"
root=/tmp/miclash/updates
operation=0000000000001-00000001-0123456789abcdef
status="$root/handoff-$operation.status"
token=0123456789abcdef0123456789abcdef
token2=fedcba9876543210fedcba9876543210

cleanup() { rm -f "$status" "$status".tmp.* 2>/dev/null || true; }
trap cleanup EXIT HUP INT TERM
mkdir -p "$root"
chmod 0700 "$root"
cleanup

"$installer" status-protocol-test --status-file "$status" --token "$token" \
	--target-tag v9.9.9
[ "$(stat -c '%u:%a' "$status")" = 0:600 ]
[ "$(wc -l < "$status" | tr -d ' ')" = 6 ]
grep -Fxq 'protocol=miclash-update-status-v1' "$status"
grep -Fxq "token=$token" "$status"
grep -Fxq 'state=success' "$status"
grep -Fxq 'phase=done' "$status"
grep -Fxq 'target_version=v9.9.9' "$status"
grep -Eq '^updated_at=[0-9]+$' "$status"

printf '%s\n' stale > "$status"
chmod 0600 "$status"
"$installer" status-protocol-test --status-file "$status" --token "$token2" \
	--target-tag v9.9.10
grep -Fxq "token=$token2" "$status"
grep -Fxq 'target_version=v9.9.10' "$status"
! grep -Fq stale "$status"

if "$installer" status-protocol-test --status-file /tmp/foreign.status \
	--token "$token" --target-tag v9.9.9 >/dev/null 2>&1; then
	exit 1
fi

echo 'update status protocol integration passed'
