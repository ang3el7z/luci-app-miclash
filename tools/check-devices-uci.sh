#!/bin/sh
set -eu

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
: "${UCODE_BIN:?set UCODE_BIN to the ucode executable}"

root="$(mktemp -d)"
trap 'rm -rf -- "$root"' EXIT HUP INT TERM
config_dir="$root/config"
mkdir -p "$config_dir" "$root/delta"
cat > "$config_dir/miclash" <<'EOF'
config guard 'guard'
	option enabled '0'
EOF

module_dir="${UCODE_MODULE_DIR:-$(dirname -- "$UCODE_BIN")}"
if [ ! -f "$module_dir/uci.so" ] && [ -f /usr/lib/ucode/uci.so ]; then
	module_dir=/usr/lib/ucode
fi
if [ ! -f "$module_dir/uci.so" ]; then
	echo "native UCI device policy integration skipped: $module_dir/uci.so unavailable"
	exit 0
fi
UCODE_PATH="$repo_root/tests/ucode:$repo_root/luci-app-miclash/rootfs/usr/share" \
MICLASH_UCI_CONFIG_DIR="$config_dir" MICLASH_UCI_DELTA_DIR="$root/delta" \
	"$UCODE_BIN" -L "$module_dir/*.so" -L "$repo_root/tests/ucode" \
	-L "$repo_root/luci-app-miclash/rootfs/usr/share" \
	"$repo_root/tests/ucode/devices-uci-integration.uc"
