#!/bin/sh

set -eu

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

if [ "${MICLASH_ROUTING_NETNS:-}" != 1 ]; then
	exec unshare --mount --net --fork env MICLASH_ROUTING_NETNS=1 \
		UCODE_BIN="${UCODE_BIN:-}" sh "$0"
fi

mount --make-rprivate /
mkdir -p /var/run/miclash
mount -t tmpfs -o mode=0700,size=1m miclash-routing-state /var/run/miclash
ip link set lo up
UCODE_PATH="$repo_root/tests/ucode:$repo_root/luci-app-miclash/rootfs/usr/share"
export UCODE_PATH

UCODE_BIN="${UCODE_BIN:-$(command -v ucode)}"
set --
ucode_module_dir="$(dirname -- "$UCODE_BIN")"
if [ -f "$ucode_module_dir/fs.so" ]; then
	set -- "$@" -L "$ucode_module_dir/*.so"
fi
old_ifs="$IFS"
IFS=:
for module_path in $UCODE_PATH; do
	set -- "$@" -L "$module_path"
done
IFS="$old_ifs"

"$UCODE_BIN" "$@" "$repo_root/tests/ucode/routing-netns-gate.uc"

producer_dir="$(mktemp -d)"
trap 'rm -rf "$producer_dir"' EXIT INT TERM
cat > "$producer_dir/ip" <<'PRODUCER'
#!/bin/sh
trap '' PIPE
chunk=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
while :; do
	printf '%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s\n' \
		"$chunk" "$chunk" "$chunk" "$chunk" "$chunk" "$chunk" "$chunk" "$chunk" \
		"$chunk" "$chunk" "$chunk" "$chunk" "$chunk" "$chunk" "$chunk" "$chunk" || true
done
PRODUCER
chmod 0700 "$producer_dir/ip"

# The outer deadline verifies cleanup even if the inner producer ignores PIPE.
producer_started="$(date +%s%3N)"
PATH="$producer_dir:$PATH" /usr/bin/timeout -s KILL 5 \
	"$UCODE_BIN" "$@" "$repo_root/tests/ucode/routing-capture-deadline-gate.uc"
producer_elapsed=$(( $(date +%s%3N) - producer_started ))
[ "$producer_elapsed" -le 3500 ]
printf 'routing oversized producer deadline passed (%sms)\n' "$producer_elapsed"
