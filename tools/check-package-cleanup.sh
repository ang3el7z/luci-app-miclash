#!/bin/sh

set -eu

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
remove="$repo_root/luci-app-miclash/rootfs/usr/share/miclash/package-remove"

if [ "${MICLASH_PACKAGE_CLEANUP_NS:-}" != 1 ]; then
	exec unshare --mount --pid --fork --mount-proc env MICLASH_PACKAGE_CLEANUP_NS=1 sh "$0"
fi

mount --make-rprivate /
for path in /var/run/miclash /usr/share/miclash /etc/miclash /opt/clash \
	/etc/init.d; do
	mkdir -p "$path"
	mount -t tmpfs -o mode=0755,size=2m miclash-package-cleanup "$path"
done
chmod 0700 /var/run/miclash /etc/miclash
mkdir -p /opt/clash/bin

fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT INT TERM
mkdir -p "$fixture/bin" "$fixture/state"
log="$fixture/state/process.log"
export MICLASH_PACKAGE_CLEANUP_LOG="$log"
export MICLASH_PACKAGE_CLEANUP_STATE="$fixture/state"

cp "$repo_root/luci-app-miclash/rootfs/usr/share/miclash/mutation-lock.sh" \
	/usr/share/miclash/mutation-lock.sh
cp "$repo_root/luci-app-miclash/rootfs/usr/share/miclash/package-release" \
	/usr/share/miclash/package-release
chmod 0600 /usr/share/miclash/mutation-lock.sh
chmod 0700 /usr/share/miclash/package-release
for helper in routing-cleanup.uc dns-cleanup.uc firewall-cleanup.uc guard-runtime.uc; do
	printf '%s\n' '# process fixture; execution is intercepted below' > "/usr/share/miclash/$helper"
	chmod 0600 "/usr/share/miclash/$helper"
done

cat > "$fixture/bin/ucode" <<'EOF'
#!/bin/sh
set -eu
log="$MICLASH_PACKAGE_CLEANUP_LOG"
state="$MICLASH_PACKAGE_CLEANUP_STATE"
printf 'ucode:%s\n' "$*" >> "$log"
[ -d /var/run/miclash/package-removal ] || exit 90
[ "${MICLASH_MUTATION_LOCK_PACKAGE:-}" = 1 ] || exit 91
case "$*" in
	*guard-runtime.uc*protect*)
		[ ! -f "$state/fail-guard" ] || exit 1
		: > "$state/guard-protected"
		;;
	*guard-runtime.uc*verify-protected*) [ -f "$state/guard-protected" ] ;;
	*routing-cleanup.uc*)
		[ -f "$state/guard-protected" ]
		[ -f /var/run/miclash/routing-ownership.json ]
		;;
	*dns-cleanup.uc*)
		[ -f "$state/guard-protected" ]
		cat > /etc/miclash/dns-ownership.json <<-'JSON'
		{"version":1,"owner":"miclash","section":"main","original":{"server":{"present":false,"value":[]},"cachesize":{"present":false,"value":null},"noresolv":{"present":false,"value":null}},"target_preexisting":false,"state":"clean","transition":null,"clean":{"server":{"present":false,"value":[]},"cachesize":{"present":false,"value":null},"noresolv":{"present":false,"value":null}}}
		JSON
		chmod 0600 /etc/miclash/dns-ownership.json
		;;
	*firewall-cleanup.uc*) [ -f "$state/guard-protected" ] ;;
	*) exit 1 ;;
esac
EOF
chmod 0700 "$fixture/bin/ucode"
mkdir -p /usr/bin
[ -e /usr/bin/ucode ] || : > /usr/bin/ucode
mount --bind "$fixture/bin/ucode" /usr/bin/ucode
PATH="$fixture/bin:/usr/bin:/bin"
export PATH

cat > "$fixture/bin/ubus" <<'EOF'
#!/bin/sh
printf 'ubus:%s\n' "$*" >> "$MICLASH_PACKAGE_CLEANUP_LOG"
[ -f "$MICLASH_PACKAGE_CLEANUP_STATE/guard-protected" ] || exit 92
printf '{}\n'
EOF
chmod 0700 "$fixture/bin/ubus"

for service in clash miclashd cron; do
	cat > "/etc/init.d/$service" <<'EOF'
#!/bin/sh
printf 'service:%s:%s\n' "$(basename "$0")" "${1:-}" >> "$MICLASH_PACKAGE_CLEANUP_LOG"
[ -f "$MICLASH_PACKAGE_CLEANUP_STATE/guard-protected" ] || exit 93
exit 0
EOF
	chmod 0700 "/etc/init.d/$service"
done

reset_state() {
	rm -rf /var/run/miclash/* /etc/miclash/* "$fixture/state"/*
	printf '%s\n' '{"version":1,"routes":[],"rules":[]}' \
		> /var/run/miclash/routing-ownership.json
	chmod 0600 /var/run/miclash/routing-ownership.json
}

# A failed native Guard process is a hard precondition failure: no service or
# network owner may be touched and the package owner lease is released.
reset_state
: > "$fixture/state/fail-guard"
if "$remove" >/dev/null 2>&1; then
	echo 'package-remove ignored native Guard failure' >&2
	exit 1
fi
! grep -q '^service:' "$log"
! grep -q 'routing-cleanup.uc' "$log"
[ ! -e /var/run/miclash/mutation.lock ]

# Retry from the same real entrypoint completes one ordered package transaction.
reset_state
"$remove"
[ -f /var/run/miclash/package-removal/complete ]
[ -f /var/run/miclash/package-removal-release/complete ]
[ -x /var/run/miclash/package-removal-release/helper ]
[ -f /var/run/miclash/package-removal-release/dns-ownership.json ]
[ ! -e /var/run/miclash/routing-ownership.json ]
[ -f "$fixture/state/guard-protected" ]
guard_line="$(grep -n -m1 'guard-runtime.uc protect' "$log" | cut -d: -f1)"
stop_line="$(grep -n -m1 'service:clash:stop' "$log" | cut -d: -f1)"
routing_line="$(grep -n -m1 'routing-cleanup.uc' "$log" | cut -d: -f1)"
dns_line="$(grep -n -m1 'dns-cleanup.uc' "$log" | cut -d: -f1)"
firewall_line="$(grep -n -m1 'firewall-cleanup.uc' "$log" | cut -d: -f1)"
[ "$guard_line" -lt "$stop_line" ]
[ "$stop_line" -lt "$routing_line" ]
[ "$routing_line" -lt "$dns_line" ]
[ "$dns_line" -lt "$firewall_line" ]

printf 'Native package cleanup process gate passed\n'
