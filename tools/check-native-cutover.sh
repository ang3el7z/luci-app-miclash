#!/bin/sh

set -eu

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
: "${UCODE_BIN:?native cutover gate requires UCODE_BIN}"

UCODE_BIN="$UCODE_BIN" "$repo_root/tools/run-ucode-tests.sh" \
	"$repo_root/tests/ucode/test-network-contract.uc" \
	"$repo_root/tests/ucode/test-reconcile-adapter.uc" \
	"$repo_root/tests/ucode/test-daemon.uc" \
	"$repo_root/tests/ucode/test-startup-guard.uc" \
	"$repo_root/tests/ucode/test-guard-runtime.uc" \
	"$repo_root/tests/ucode/test-routing.uc" \
	"$repo_root/tests/ucode/test-dns.uc" \
	"$repo_root/tests/ucode/test-migrate.uc" \
	"$repo_root/tests/ucode/test-legacy-network.uc" \
	"$repo_root/tests/ucode/test-config.uc" \
	"$repo_root/tests/ucode/test-http-subscription.uc"

"${NODE_BIN:-node}" "$repo_root/tools/check-package-cutover.mjs"
"${NODE_BIN:-node}" "$repo_root/tools/check-package-removal-barrier.mjs"
"${NODE_BIN:-node}" "$repo_root/tools/check-ucode-layout.mjs"

if grep -R -E '/opt/clash/bin/(clash-rules|miclash-service|miclash-subscription|miclash-update)' \
	"$repo_root/luci-app-miclash/rootfs/usr/share/miclash"/*.uc \
	"$repo_root/luci-app-miclash/rootfs/usr/sbin/miclashd" >/dev/null 2>&1; then
	echo 'native cutover retained a legacy production backend call' >&2
	exit 1
fi

printf 'Native backend cutover gate passed\n'
