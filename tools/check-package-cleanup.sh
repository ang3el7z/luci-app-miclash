#!/bin/sh

set -eu

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
if [ "${MICLASH_PACKAGE_CLEANUP_NS:-}" != 1 ]; then
	exec unshare --mount --fork env MICLASH_PACKAGE_CLEANUP_NS=1 sh "$0"
fi

mount --make-rprivate /
for path in /var/run/miclash /usr/share/miclash /opt/clash /etc /var/etc; do
	mkdir -p "$path"
done
mount -t tmpfs -o mode=0700,size=2m miclash-cleanup-run /var/run/miclash
mount -t tmpfs -o mode=0755,size=2m miclash-cleanup-share /usr/share/miclash
mount -t tmpfs -o mode=0755,size=2m miclash-cleanup-opt /opt/clash
mount -t tmpfs -o mode=0755,size=2m miclash-cleanup-etc /etc
mount -t tmpfs -o mode=0755,size=1m miclash-cleanup-var-etc /var/etc
mkdir -p /opt/clash/bin /etc/init.d
chmod 0700 /var/run/miclash

fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT INT TERM
mkdir -p "$fixture/bin" "$fixture/nftbin" "$fixture/iptbin" "$fixture/state"
export MICLASH_CLEANUP_STATE="$fixture/state"
ln -s /usr/bin/mawk "$fixture/bin/awk"

cp "$repo_root"/luci-app-miclash/rootfs/usr/share/miclash/*.uc /usr/share/miclash/
cp "$repo_root/luci-app-miclash/rootfs/usr/share/miclash/mutation-lock.sh" \
	/usr/share/miclash/mutation-lock.sh
cp "$repo_root/luci-app-miclash/rootfs/opt/clash/bin/clash-rules" \
	/opt/clash/bin/clash-rules
cp "$repo_root/luci-app-miclash/rootfs/etc/init.d/clash" /etc/init.d/clash
chmod 0600 /usr/share/miclash/mutation-lock.sh
chmod 0700 /opt/clash/bin/clash-rules /etc/init.d/clash

cat > "$fixture/bin/ucode" <<'EOF'
#!/bin/sh
state="$MICLASH_CLEANUP_STATE"
while [ "${1:-}" != /usr/share/miclash/guard-runtime.uc ]; do
	[ "$#" -gt 0 ] || exit 1
	shift
done
shift
command="${1:-}"
printf '%s\n' "guard-runtime-$command" >> "$state/guard-runtime.log"
case "$command" in
	protect) : > "$state/emergency-active" ;;
	release) rm -f "$state/emergency-active" ;;
	disable) rm -f "$state/emergency-active" ;;
	verify-nft|verify-iptables4|verify-iptables6)
		cat >/dev/null
		[ -e "$state/guard-active" ]
		;;
	*) exit 1 ;;
esac
EOF
chmod 0700 "$fixture/bin/ucode"
mkdir -p /usr/bin
[ -e /usr/bin/ucode ] || : > /usr/bin/ucode
mount --bind "$fixture/bin/ucode" /usr/bin/ucode

cat > "$fixture/bin/logger" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$fixture/bin/sysctl" <<'EOF'
#!/bin/sh
[ ! -f "$MICLASH_CLEANUP_STATE/fail-sysctl" ]
EOF
cat > "$fixture/bin/uci" <<'EOF'
#!/bin/sh
state="$MICLASH_CLEANUP_STATE"
while [ "${1:-}" = -q ]; do shift; done
command="${1:-}"; shift || true
case "$command:${1:-}" in
	show:firewall)
		[ ! -f "$state/fail-firewall-inventory" ] || exit 1
		if [ -f "$state/firewall-committed-section" ] && \
			[ ! -f "$state/firewall-delete-pending" ]; then
			echo "firewall.miclash='include'"
		fi
		[ ! -f "$state/fail-firewall-verify" ] || \
			{ [ -f "$state/firewall-committed-section" ] && \
			  [ ! -f "$state/firewall-delete-pending" ]; } || exit 1
		;;
	delete:firewall.miclash)
		[ ! -f "$state/fail-firewall-delete" ] || exit 1
		: > "$state/firewall-delete-pending"
		;;
	commit:firewall)
		[ ! -f "$state/fail-firewall-commit" ] || exit 1
		if [ -f "$state/firewall-delete-pending" ]; then
			rm -f "$state/firewall-committed-section" \
				"$state/firewall-delete-pending"
		fi
		: > "$state/firewall-commit-succeeded"
		;;
	changes:firewall)
		[ ! -f "$state/fail-firewall-changes" ] || exit 1
		[ ! -f "$state/firewall-delete-pending" ] || \
			echo "-firewall.miclash"
		[ ! -f "$state/firewall-extra-pending" ] || \
			echo "firewall.foreign='include'"
		;;
	show:dhcp)
		[ ! -f "$state/fail-dhcp-inventory" ] || exit 1
		if [ -f "$state/dns-mutated" ] && [ -f "$state/fail-dhcp-verify" ]; then exit 1; fi
		[ ! -f "$state/dns-server" ] || echo "dhcp.@dnsmasq[0].server='$(cat "$state/dns-server")'"
		[ ! -f "$state/dns-cache" ] || echo "dhcp.@dnsmasq[0].cachesize='$(cat "$state/dns-cache")'"
		[ ! -f "$state/dns-noresolv" ] || echo "dhcp.@dnsmasq[0].noresolv='$(cat "$state/dns-noresolv")'"
		;;
	get:dhcp.@dnsmasq\[0\].server) cat "$state/dns-server" ;;
	get:dhcp.@dnsmasq\[0\].cachesize) cat "$state/dns-cache" ;;
	get:dhcp.@dnsmasq\[0\].noresolv) cat "$state/dns-noresolv" ;;
	del_list:*)
		[ ! -f "$state/fail-dhcp-delete" ] || exit 1
		rm -f "$state/dns-server"
		: > "$state/dns-mutated"
		;;
	set:*)
		[ ! -f "$state/fail-dhcp-set" ] || exit 1
		case "$1" in
			dhcp.@dnsmasq\[0\].cachesize=*) printf '%s' "${1#*=}" > "$state/dns-cache" ;;
			dhcp.@dnsmasq\[0\].noresolv=*) printf '%s' "${1#*=}" > "$state/dns-noresolv" ;;
		esac
		: > "$state/dns-mutated"
		;;
	delete:dhcp.@dnsmasq\[0\].cachesize)
		[ ! -f "$state/fail-dhcp-delete" ] || exit 1
		rm -f "$state/dns-cache"
		: > "$state/dns-mutated"
		;;
	delete:dhcp.@dnsmasq\[0\].noresolv)
		[ ! -f "$state/fail-dhcp-delete" ] || exit 1
		rm -f "$state/dns-noresolv"
		: > "$state/dns-mutated"
		;;
	commit:dhcp)
		[ ! -f "$state/fail-dhcp-commit" ]
		;;
	*) exit 1 ;;
esac
EOF
cat > "$fixture/nftbin/nft" <<'EOF'
#!/bin/sh
state="$MICLASH_CLEANUP_STATE"
case "$*" in
	'list ruleset')
		[ ! -f "$state/fail-nft-inventory" ] || exit 1
		if [ -f "$state/nft-deleted" ] && [ -f "$state/fail-nft-verify" ]; then exit 1; fi
		cat "$state/nft-rules" 2>/dev/null || true
		;;
	'list table inet fw4') exit 1 ;;
	'list table inet miclash_guard')
		[ -f "$state/guard-active" ] && echo 'table inet miclash_guard' || exit 1
		;;
	'-j list table inet miclash_guard')
		[ -f "$state/guard-active" ] && echo '{"nftables":[]}' || exit 1
		;;
	'list chain inet miclash_guard forward')
		[ -f "$state/guard-active" ] || exit 1
		echo 'chain forward { meta nfproto ipv4 drop comment "miclash-guard"; }'
		;;
	'delete table inet miclash_guard') rm -f "$state/guard-active" ;;
	'add table inet miclash_guard') : > "$state/guard-active" ;;
	add\ *) ;;
	'delete table inet clash')
		[ ! -f "$state/fail-nft-delete" ] || exit 1
		: > "$state/nft-rules"
		: > "$state/nft-deleted"
		;;
	*) exit 1 ;;
esac
EOF
cat > "$fixture/iptbin/iptables-save" <<'EOF'
#!/bin/sh
state="$MICLASH_CLEANUP_STATE"
[ ! -f "$state/fail-iptables-inventory" ] || exit 1
if [ -f "$state/iptables-deleted" ] && [ -f "$state/fail-iptables-verify" ]; then exit 1; fi
cat "$state/iptables-rules" 2>/dev/null || true
EOF
cat > "$fixture/iptbin/iptables" <<'EOF'
#!/bin/sh
state="$MICLASH_CLEANUP_STATE"
printf '%s\n' "$*" >> "$state/iptables.log"
[ ! -f "$state/fail-iptables-delete" ] || exit 1
case "$*" in
	*' -C OUTPUT -j MICLASH_GUARD_OUTPUT'|*' -S MICLASH_GUARD_OUTPUT') exit 1 ;;
	*' -C FORWARD -j MICLASH_GUARD_FORWARD')
		[ -f "$state/guard-jump" ] || exit 1
		;;
	*' -S MICLASH_GUARD_FORWARD')
		[ -f "$state/guard-chain" ] || exit 1
		echo '-A MICLASH_GUARD_FORWARD -j DROP'
		;;
	*' -D FORWARD -j MICLASH_GUARD_FORWARD')
		[ -f "$state/guard-jump" ] || exit 1
		rm -f "$state/guard-jump" "$state/guard-active"
		;;
	*' -N MICLASH_GUARD_FORWARD') : > "$state/guard-chain" ;;
	*' -I FORWARD 1 -j MICLASH_GUARD_FORWARD')
		: > "$state/guard-jump"; : > "$state/guard-active"
		;;
	*' -A MICLASH_GUARD_FORWARD '*)
		[ -f "$state/guard-chain" ] || exit 1
		: > "$state/guard-active"
		;;
	*' -F MICLASH_GUARD_FORWARD') ;;
	*' -X MICLASH_GUARD_FORWARD') rm -f "$state/guard-chain" "$state/guard-active" ;;
	*' -D '*)
		[ -s "$state/iptables-rules" ] || exit 1
		: > "$state/iptables-rules"; : > "$state/iptables-deleted" ;;
	*) : > "$state/iptables-rules"; : > "$state/iptables-deleted" ;;
esac
exit 0
EOF
cp "$fixture/iptbin/iptables" "$fixture/iptbin/ip6tables"
cp "$fixture/iptbin/iptables-save" "$fixture/iptbin/ip6tables-save"
cat > /etc/init.d/dnsmasq <<'EOF'
#!/bin/sh
[ "${1:-}" = restart ] || exit 1
[ ! -f "$MICLASH_CLEANUP_STATE/fail-dnsmasq" ]
EOF
cat > /etc/rc.common <<'EOF'
script="$1"
shift
. "$script"
action="${1:-}"
[ -n "$action" ] || exit 2
shift
"$action" "$@"
EOF
chmod 0700 "$fixture/bin/logger" "$fixture/bin/sysctl" "$fixture/bin/uci" \
	"$fixture/nftbin/nft" "$fixture/iptbin/iptables" "$fixture/iptbin/iptables-save" \
	"$fixture/iptbin/ip6tables" "$fixture/iptbin/ip6tables-save" \
	/etc/init.d/dnsmasq /etc/rc.common

mkdir /var/run/miclash/package-removal
chmod 0700 /var/run/miclash/package-removal
: > /var/run/miclash/routing-ownership.json
: > /var/run/miclash/guard-active

. /usr/share/miclash/mutation-lock.sh
run_package_entrypoint() {
	miclash_mutation_lock_enter_package_owner 1000 || return 1
	MICLASH_MUTATION_LOCK_PACKAGE=1
	export MICLASH_MUTATION_LOCK_PACKAGE
	/opt/clash/bin/clash-rules package_guard_start || {
		result=$?
		[ ! -f "$fixture/state/iptables.log" ] || cat "$fixture/state/iptables.log" >&2
		miclash_mutation_lock_leave >/dev/null 2>&1 || true
		return "$result"
	}
	"$@"
	result=$?
	miclash_mutation_lock_leave || return 1
	return "$result"
}

reset_firewall() {
	rm -f "$fixture/state"/*
	: > "$fixture/state/firewall-committed-section"
	printf 'table inet clash { }\n' > "$fixture/state/nft-rules"
	: > /var/etc/miclash.include
}

PATH="$fixture/nftbin:$fixture/bin:/usr/bin:/bin"
export PATH
for failure in fail-nft-inventory fail-nft-delete fail-nft-verify \
	fail-firewall-inventory fail-firewall-delete fail-firewall-commit \
	fail-firewall-changes firewall-extra-pending fail-firewall-verify; do
	reset_firewall
	: > "$fixture/state/$failure"
	if run_package_entrypoint /opt/clash/bin/clash-rules package_cleanup >/dev/null 2>&1; then
		echo "package cleanup unexpectedly ignored $failure" >&2
		exit 1
	fi
	[ -f /var/run/miclash/routing-ownership.json ]
	[ -f /var/run/miclash/guard-active ]
	rm -f "$fixture/state/$failure"
	if ! run_package_entrypoint /opt/clash/bin/clash-rules package_cleanup; then
		echo "package cleanup retry failed after $failure" >&2
		cat "$fixture/state/iptables.log" >&2
		exit 1
	fi
	if [ -e "$fixture/state/firewall-committed-section" ] || \
		[ -e "$fixture/state/firewall-delete-pending" ]; then
		echo 'firewall retry accepted overlay-only absence without committing persistent state' >&2
		exit 1
	fi
done

PATH="$fixture/iptbin:$fixture/bin:/usr/bin:/bin"
export PATH
for failure in fail-iptables-inventory fail-iptables-delete fail-iptables-verify; do
	rm -f "$fixture/state"/* /var/etc/miclash.include
	printf '%s\n' '-N CLASH' '-A PREROUTING -j CLASH' > "$fixture/state/iptables-rules"
	: > "$fixture/state/$failure"
	if run_package_entrypoint /opt/clash/bin/clash-rules package_cleanup >/dev/null 2>&1; then
		echo "package cleanup unexpectedly ignored $failure" >&2
		exit 1
	fi
	[ -f /var/run/miclash/routing-ownership.json ]
	[ -f /var/run/miclash/guard-active ]
	if [ "$failure" = fail-iptables-delete ]; then
		[ -f "$fixture/state/emergency-active" ] || {
			echo 'iptables Guard mutation failure lost emergency protection' >&2
			exit 1
		}
	fi
	rm -f "$fixture/state/$failure"
	run_package_entrypoint /opt/clash/bin/clash-rules package_cleanup
done

# DNS is no longer a shell/init cleanup responsibility.  The package owner
# invokes the fixed ucode cleanup entrypoint under the same package lease;
# check-package-removal.sh exercises its failure and proof ordering.
grep -Fq '/usr/share/miclash/dns-cleanup.uc' \
	"$repo_root/luci-app-miclash/rootfs/usr/share/miclash/package-remove"
! grep -Eq 'restore_dns|setup_dns|verify_dns_restored|uci .*dhcp' /etc/init.d/clash

printf 'production package cleanup failure/retry gate passed\n'
