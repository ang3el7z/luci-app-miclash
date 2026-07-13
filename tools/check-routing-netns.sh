#!/bin/sh

set -eu

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

if [ "${MICLASH_ROUTING_NETNS:-}" != 1 ]; then
	exec unshare --net --fork env MICLASH_ROUTING_NETNS=1 sh "$0"
fi

ip link set lo up
UCODE_PATH="$repo_root/tests/ucode:$repo_root/luci-app-miclash/rootfs/usr/share"
export UCODE_PATH

set --
ucode_module_dir="$(dirname -- "$(command -v ucode)")"
if [ -f "$ucode_module_dir/fs.so" ]; then
	set -- "$@" -L "$ucode_module_dir/*.so"
fi
old_ifs="$IFS"
IFS=:
for module_path in $UCODE_PATH; do
	set -- "$@" -L "$module_path"
done
IFS="$old_ifs"

exec ucode "$@" "$repo_root/tests/ucode/routing-netns-gate.uc"
