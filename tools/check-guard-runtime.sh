#!/bin/sh

set -eu

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
[ -n "${UCODE_BIN:-}" ] && [ -x "$UCODE_BIN" ] || {
	echo 'Guard runtime gate requires UCODE_BIN' >&2
	exit 1
}

UCODE_BIN="$UCODE_BIN" "$repo_root/tools/run-ucode-tests.sh" \
	"$repo_root/tests/ucode/test-guard-runtime.uc"
node "$repo_root/tools/check-guard-runtime.mjs"

printf 'Guard runtime focused gate passed\n'
