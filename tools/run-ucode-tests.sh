#!/bin/sh

set -u

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

if [ -z "${UCODE_BIN:-}" ]; then
	UCODE_BIN="$(command -v ucode 2>/dev/null || true)"
fi

if [ -z "$UCODE_BIN" ] || ! command -v "$UCODE_BIN" >/dev/null 2>&1; then
	echo "ucode binary not found; set UCODE_BIN" >&2
	exit 127
fi

UCODE_PATH="${UCODE_PATH:-$repo_root/tests/ucode:$repo_root/luci-app-miclash/rootfs/usr/share}"
export UCODE_PATH

run_ucode_test() {
	test_file="$1"
	shift
	old_ifs="$IFS"
	IFS=:
	for module_path in $UCODE_PATH; do
		if [ -n "$module_path" ]; then
			set -- "$@" -L "$module_path"
		fi
	done
	IFS="$old_ifs"
	"$UCODE_BIN" "$@" "$test_file"
}

failures=0
tests=0

if [ "$#" -eq 0 ]; then
	set -- "$repo_root"/tests/ucode/test-*.uc
fi

for test_file in "$@"; do
	tests=$((tests + 1))
	echo "==> ${test_file#"$repo_root"/}"
	if ! run_ucode_test "$test_file"; then
		failures=$((failures + 1))
	fi
done

if [ "$failures" -ne 0 ]; then
	echo "$failures of $tests ucode tests failed" >&2
	exit 1
fi

echo "$tests ucode tests passed"
