#!/bin/sh

set -eu

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
: "${UCODE_BIN:?Guard runtime gate requires UCODE_BIN}"
entry="$repo_root/luci-app-miclash/rootfs/usr/share/miclash/guard-runtime.uc"
lock="$repo_root/luci-app-miclash/rootfs/usr/share/miclash/mutation-lock.sh"

if [ "${MICLASH_GUARD_GATE_NS:-}" != 1 ]; then
	exec unshare --mount --pid --fork --mount-proc env MICLASH_GUARD_GATE_NS=1 \
		UCODE_BIN="$UCODE_BIN" LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}" sh "$0"
fi

mount --make-rprivate /
for path in /var/run/miclash /tmp/miclash /usr/sbin; do
	mkdir -p "$path"
	mount -t tmpfs -o mode=0700,size=2m miclash-guard-gate "$path"
done
chmod 0700 /var/run/miclash /tmp/miclash

fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT INT TERM
state="$fixture/state"
mkdir "$state"
export MICLASH_GUARD_GATE_STATE="$state"
export MICLASH_GUARD_GATE_UCODE="$UCODE_BIN"
export MICLASH_GUARD_GATE_MODULE_DIR="$(dirname -- "$UCODE_BIN")"
export MICLASH_GUARD_GATE_RENDER="$fixture/render.uc"

cat > "$fixture/render.uc" <<'EOF'
let table = ARGV[0], chain = 'protected_direct_drop_v1';
function matched(left, op, right) { return { match: { left, op, right } }; };
function meta(key) { return { meta: { key } }; };
function payload(protocol, field) { return { payload: { protocol, field } }; };
function prefix(value) {
	let at = rindex(value, '/');
	return { prefix: { addr: substr(value, 0, at), len: int(substr(value, at + 1)) } };
};
let entries = [
	{ table: { family: 'inet', name: table } },
	{ chain: { family: 'inet', table, name: chain, type: 'filter',
		hook: 'forward', prio: -310, policy: 'accept' } }
];
let expressions = [
	[ matched(meta('iifname'), '==', 'clash-tun'), { accept: null } ],
	[ matched(meta('oifname'), '==', 'clash-tun'), { accept: null } ],
	[ matched({ ct: { key: 'status' } }, 'in', 'dnat'), { accept: null } ],
	[ matched(payload('udp', 'sport'), '==', 67), matched(payload('udp', 'dport'), '==', 68), { accept: null } ],
	[ matched(payload('udp', 'sport'), '==', 68), matched(payload('udp', 'dport'), '==', 67), { accept: null } ],
	[ matched(payload('ip', 'daddr'), '==', { set: map([
		'0.0.0.0/8', '10.0.0.0/8', '100.64.0.0/10', '127.0.0.0/8',
		'169.254.0.0/16', '172.16.0.0/12', '192.168.0.0/16',
		'224.0.0.0/4', '240.0.0.0/4' ], prefix) }), { accept: null } ],
	[ matched(payload('ip6', 'daddr'), '==', { set: map([
		'::/128', '::1/128', 'fc00::/7', 'fe80::/10', 'ff00::/8' ], prefix) }), { accept: null } ],
	[ matched(meta('nfproto'), '==', 'ipv4'), { drop: null } ],
	[ matched(meta('nfproto'), '==', 'ipv6'), { drop: null } ]
];
for (let expr in expressions)
	push(entries, { rule: { family: 'inet', table, chain, expr } });
print(sprintf('%J\n', { nftables: entries }));
EOF

cat > /usr/sbin/nft <<'EOF'
#!/bin/sh
set -eu
state="$MICLASH_GUARD_GATE_STATE"
printf '%s\n' "$*" >> "$state/calls"
if [ "$*" = '-j list tables' ]; then
	first=1
	printf '{"nftables":['
	for table in miclash_guard_emergency_v1 miclash_guard_bootstrap_v1; do
		[ -f "$state/table.$table" ] || continue
		[ "$first" = 1 ] || printf ','
		printf '{"table":{"family":"inet","name":"%s"}}' "$table"
		first=0
	done
	printf ']}\n'
	exit 0
fi
if [ "${1:-}" = -j ] && [ "${2:-}" = list ] && [ "${3:-}" = table ] &&
	[ "${4:-}" = inet ] && [ -n "${5:-}" ]; then
	[ -f "$state/table.$5" ] || exit 1
	exec "$MICLASH_GUARD_GATE_UCODE" -L "$MICLASH_GUARD_GATE_MODULE_DIR/*.so" \
		"$MICLASH_GUARD_GATE_RENDER" "$5"
fi
if [ "${1:-}" = -f ] && [ -f "${2:-}" ]; then
	batch="$2"
	if [ -f "$state/fail-all" ] ||
	   { [ -f "$state/fail-delete-emergency" ] &&
	     grep -q '^delete table inet miclash_guard_emergency_v1$' "$batch"; }; then
		exit 1
	fi
	while read -r action kind family table rest; do
		[ "$kind" = table ] && [ "$family" = inet ] || continue
		case "$action" in
			add) : > "$state/table.$table" ;;
			delete) rm -f "$state/table.$table" ;;
		esac
	done < "$batch"
	exit 0
fi
exit 1
EOF
chmod 0700 /usr/sbin/nft

run_guard() {
	"$UCODE_BIN" -L "$(dirname -- "$UCODE_BIN")/*.so" \
		-L "$repo_root/luci-app-miclash/rootfs/usr/share" "$entry" "$1"
}

. "$lock"

# No inherited owner means the privileged CLI cannot mutate anything.
if run_guard protect >/dev/null 2>&1; then
	echo 'Guard CLI mutated without the canonical inherited owner' >&2
	exit 1
fi
[ ! -e "$state/table.miclash_guard_emergency_v1" ]

miclash_mutation_lock_enter normal 1000
run_guard protect
run_guard verify-protected
[ -f "$state/table.miclash_guard_emergency_v1" ]
run_guard release
[ -f "$state/table.miclash_guard_bootstrap_v1" ]
[ ! -e "$state/table.miclash_guard_emergency_v1" ]
run_guard verify-bootstrap-on
run_guard disable
[ ! -e "$state/table.miclash_guard_bootstrap_v1" ]
run_guard verify-bootstrap-off
miclash_mutation_lock_leave

# Atomic apply failure cannot manufacture a falsely verified owner.
miclash_mutation_lock_enter normal 1000
: > "$state/fail-all"
if run_guard protect >/dev/null 2>&1; then
	echo 'Guard protect ignored nft apply failure' >&2
	exit 1
fi
[ ! -e "$state/table.miclash_guard_emergency_v1" ]
rm -f "$state/fail-all"
run_guard protect
: > "$state/fail-delete-emergency"
if run_guard release >/dev/null 2>&1; then
	echo 'Guard release ignored emergency deletion failure' >&2
	exit 1
fi
# Primary was repaired before the failed release and emergency remains: there
# is no direct-traffic gap even across the failed process boundary.
[ -f "$state/table.miclash_guard_bootstrap_v1" ]
[ -f "$state/table.miclash_guard_emergency_v1" ]
run_guard verify-protected
rm -f "$state/fail-delete-emergency"
run_guard release
run_guard disable
miclash_mutation_lock_leave

# Package removal is a hard admission barrier for ordinary Guard mutations.
mkdir /var/run/miclash/package-removal
chmod 0700 /var/run/miclash/package-removal
if miclash_mutation_lock_enter normal 0; then
	echo 'Guard owner entered during package removal' >&2
	exit 1
fi
[ ! -e /var/run/miclash/mutation.lock ]

printf 'Native Guard process lifecycle gate passed\n'
