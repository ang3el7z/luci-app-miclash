#!/bin/sh

set -eu

fail() {
	printf '%s\n' "capture-network-contract: $*" >&2
	exit 1
}

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
legacy_rules="$repo_root/luci-app-miclash/rootfs/opt/clash/bin/clash-rules"

normalize_stream() {
	sed -e 's/pid=[0-9][0-9]*/pid=<PID>/g' \
		-e 's/[[:space:]][[:space:]]*/ /g' \
		-e 's/[[:space:]]$//'
}

normalize_nft() {
	input=$1 output=$2
	[ -f "$input" ] || { : > "$output"; return; }
	normalize_stream < "$input" | awk '
		/^nft (add|insert|replace) / { sub(/^nft /, ""); if ($0 != "" && !seen[$0]++) print; next }
		/^nft-batch / { sub(/^nft-batch /, ""); if ($0 != "" && !seen[$0]++) print }
	' > "$output"
}

normalize_iptables() {
	input=$1 output=$2
	[ -f "$input" ] || { : > "$output"; return; }
	normalize_stream < "$input" | awk '
		/^(iptables|ip6tables) -t .* -(N|A|I) / { if (!seen[$0]++) print; next }
		/^ipset (create|add|flush) / { if (!seen[$0]++) print }
	' > "$output"
}

normalize_routes() {
	input=$1 output=$2
	[ -f "$input" ] || { : > "$output"; return; }
	normalize_stream < "$input" | awk '
		/^ip (-6 )?route replace / { if (!seen[$0]++) print; next }
		/^ip (-6 )?rule add / { if (!seen[$0]++) print }
	' > "$output"
}

# Pure normalization entry point used by the contract test. It cannot target
# tracked canonical fixtures and performs no namespace or network operation.
if [ "${1:-}" = --normalize ]; then
	[ "$#" -eq 4 ] || fail 'usage: --normalize nft|iptables|routes INPUT OUTPUT'
	kind=$2 input=$3 output=$4
	case "$input:$output" in /*:/*) ;; *) fail 'normalization paths must be absolute' ;; esac
	[ -f "$input" ] || fail 'normalization input must be a regular file'
	[ ! -e "$output" ] && [ ! -L "$output" ] || fail 'normalization output must not already exist'
	output_parent=${output%/*}
	[ -d "$output_parent" ] && [ ! -L "$output_parent" ] || fail 'normalization output parent is unsafe'
	output_parent=$(CDPATH= cd -- "$output_parent" && pwd -P) || fail 'cannot resolve normalization output parent'
	case "$output_parent/" in "$repo_root/tests/fixtures/network/"*) fail 'refusing canonical fixture output' ;; esac
	case "$kind" in
		nft) normalize_nft "$input" "$output" ;;
		iptables) normalize_iptables "$input" "$output" ;;
		routes) normalize_routes "$input" "$output" ;;
		*) fail 'unknown normalization kind' ;;
	esac
	exit 0
fi

requested_root=${MICLASH_CAPTURE_ROOT:-}

[ -n "$requested_root" ] || fail 'MICLASH_CAPTURE_ROOT is required'
case "$requested_root" in
	/*) ;;
	*) fail 'MICLASH_CAPTURE_ROOT must be an absolute POSIX path' ;;
esac
[ ! -L "$requested_root" ] || fail 'capture root must not be a symlink'
[ -d "$requested_root" ] || fail 'capture root does not exist'
root=$(CDPATH= cd -- "$requested_root" && pwd -P)

case "$root" in
	/|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/opt|/proc|/root|/run|/sbin|/sys|/tmp|/usr|/var)
		fail 'refusing a host system directory as capture root'
		;;
esac
case "$root/" in
	"$repo_root/"|"$repo_root/"*) fail 'capture root must be outside the workspace' ;;
esac
case "$repo_root/" in
	"$root/"*) fail 'capture root must not contain the workspace' ;;
esac

command -v stat >/dev/null 2>&1 || fail 'stat is required for ownership checks'
command -v findmnt >/dev/null 2>&1 || fail 'findmnt is required for nested-mount checks'
command -v readlink >/dev/null 2>&1 || fail 'readlink is required for namespace checks'
owner=$(stat -c '%u' "$root" 2>/dev/null || fail 'cannot inspect capture root owner')
[ "$owner" = "$(id -u)" ] || fail 'capture root must be owned by the invoking user'
mode=$(stat -c '%a' "$root" 2>/dev/null || fail 'cannot inspect capture root permissions')
group_digit=$(printf '%s\n' "$mode" | sed 's/.*\(.\)\(.\)$/\1/')
world_digit=$(printf '%s\n' "$mode" | sed 's/.*\(.\)$/\1/')
case "$group_digit$world_digit" in
	*[2367]*) fail 'capture root must not be group- or world-writable' ;;
esac
[ -f "$root/.miclash-capture-disposable" ] || \
	fail 'capture root lacks .miclash-capture-disposable safety marker'
[ -x "$root/bin/sh" ] || fail 'capture root needs its own executable /bin/sh'
[ -f "$legacy_rules" ] || fail 'legacy clash-rules source is missing'
command -v chroot >/dev/null 2>&1 || fail 'chroot is required inside the namespace boundary'
command -v unshare >/dev/null 2>&1 || fail 'isolated mount and network namespaces are required'
command -v mount >/dev/null 2>&1 || fail 'mount is required to privatize the isolated namespace'
[ "$(id -u)" -eq 0 ] || fail 'isolated namespaces and chroot require uid 0'

# The disposable root must be its own mount and contain no bind/sub-mounts.
# A cloned mount namespace still references the same mounted filesystems, so
# merely making propagation private would not make writes to a nested host bind
# mount safe.
root_mounts=$(findmnt -R -n -o TARGET --target "$root" 2>/dev/null || true)
[ "$root_mounts" = "$root" ] || \
	fail 'capture root must be a dedicated mount with no nested mounts'

parent_net_ns=$(readlink /proc/self/ns/net 2>/dev/null || true)
parent_mnt_ns=$(readlink /proc/self/ns/mnt 2>/dev/null || true)
[ -n "$parent_net_ns" ] && [ -n "$parent_mnt_ns" ] || fail 'cannot inspect parent namespaces'
if ! unshare --mount --net --pid --fork /bin/sh -c '
	mount --make-rprivate / || exit 1
	[ "$(readlink /proc/self/ns/net)" != "$1" ] || exit 1
	[ "$(readlink /proc/self/ns/mnt)" != "$2" ] || exit 1
' namespace-probe "$parent_net_ns" "$parent_mnt_ns"
then
	fail 'verifiable isolated mount+network namespaces are unavailable'
fi

tmp_base=${TMPDIR:-/tmp}
case "$tmp_base" in /*) ;; *) fail 'TMPDIR must be absolute' ;; esac
tmp_base=$(CDPATH= cd -- "$tmp_base" && pwd -P) || fail 'TMPDIR does not exist'
case "$tmp_base/" in "$repo_root/"*) fail 'candidate TMPDIR must be outside the workspace' ;; esac
candidate_root=$(mktemp -d "$tmp_base/miclash-network-candidates.XXXXXX") || \
	fail 'cannot create unique candidate output directory'
case "$candidate_root/" in
	"$repo_root/tests/fixtures/network/"*) fail 'candidate output must not enter canonical fixture directories' ;;
esac

mkdir -p "$root/tmp"
work_host=$(mktemp -d "$root/tmp/miclash-network-capture.XXXXXX") || \
	fail 'cannot create unique isolated work directory'
case "$work_host/" in "$root/tmp/miclash-network-capture."*) ;; *) fail 'unsafe work path' ;; esac
cleanup() {
	rm -rf -- "$work_host"
}
trap cleanup EXIT HUP INT TERM

work_chroot=${work_host#"$root"}
mkdir -p "$work_host/bin-common" "$work_host/bin-nft" "$work_host/bin-iptables" "$work_host/records"
cp "$legacy_rules" "$work_host/clash-rules"
chmod 0700 "$work_host/clash-rules"

cat > "$work_host/network-fake" <<'FAKE'
#!/bin/sh
set -u
cmd=${0##*/}
case "$cmd" in
	nft) record="$MICLASH_RECORD_DIR/nft.raw" ;;
	iptables|ip6tables|ipset) record="$MICLASH_RECORD_DIR/iptables.raw" ;;
	ip) record="$MICLASH_RECORD_DIR/routes.raw" ;;
	*) exit 127 ;;
esac
{
	printf '%s' "$cmd"
	for arg in "$@"; do printf '\t%s' "$arg"; done
	printf '\n'
} >> "$record"

# Preserve batch content, not only the `nft -f` wrapper invocation. Both stdin
# and file-backed batches occur in legacy paths.
if [ "$cmd" = nft ] && [ "${1:-}" = -f ]; then
	batch=${2:-}
	if [ "$batch" = - ]; then
		while IFS= read -r line || [ -n "$line" ]; do
			printf 'nft-batch\t%s\n' "$line" >> "$record"
		done
	elif [ -n "$batch" ] && [ -f "$batch" ]; then
		while IFS= read -r line || [ -n "$line" ]; do
			printf 'nft-batch\t%s\n' "$line" >> "$record"
		done < "$batch"
	fi
fi

case "$cmd:$*" in
	'nft:list tables'*) printf '%s\n' 'table inet fw4' ;;
	'iptables:'*'-D '*|'ip6tables:'*'-D '*|'iptables:'*'-C '*|'ip6tables:'*'-C '*) exit 1 ;;
	'ip:'*' rule del '*) exit 1 ;;
	'ip:'*'route replace default dev clash-tun'*) [ "$MICLASH_CAPTURE_TUN_EXISTS" = true ] || exit 1 ;;
	'ip:route show default'*|'ip:-4 route show default'*)
		[ -n "$MICLASH_CAPTURE_WAN4" ] || exit 1
		printf 'default via 192.0.2.1 dev %s\n' "$MICLASH_CAPTURE_WAN4"
		;;
	'ip:-6 route show default'*)
		[ -n "$MICLASH_CAPTURE_WAN6" ] || exit 1
		printf 'default via 2001:db8::1 dev %s\n' "$MICLASH_CAPTURE_WAN6"
		;;
	'ipset:list '*) exit 1 ;;
esac
exit 0
FAKE
chmod 0700 "$work_host/network-fake"
for cmd in nft ip; do cp "$work_host/network-fake" "$work_host/bin-nft/$cmd"; done
for cmd in iptables ip6tables ipset ip; do cp "$work_host/network-fake" "$work_host/bin-iptables/$cmd"; done

cat > "$work_host/control-fake" <<'FAKE'
#!/bin/sh
case "${0##*/}:$*" in
	sysctl:*'-n '*) printf '%s\n' 1 ;;
esac
exit 0
FAKE
chmod 0700 "$work_host/control-fake"
for cmd in logger sysctl ubus uci; do cp "$work_host/control-fake" "$work_host/bin-common/$cmd"; done

# Do not expose the root's general PATH: an unexpected nft/ip/sysctl binary there
# would defeat recording. Link only utilities which cannot mutate host networking.
for cmd in awk basename cat cut find grep head md5sum mkdir mktemp pgrep readlink rm sed sleep sort tail tr wc xargs; do
	if [ -x "$root/bin/$cmd" ]; then
		ln -s "/bin/$cmd" "$work_host/bin-common/$cmd"
	elif [ -x "$root/usr/bin/$cmd" ]; then
		ln -s "/usr/bin/$cmd" "$work_host/bin-common/$cmd"
	else
		fail "disposable root lacks required utility: $cmd"
	fi
done

scenario_names='tproxy-explicit-guard-ipv4-quic
tproxy-exclude-open-dualstack-multiwan
tun-explicit-guard-fakeip-ipv4
tun-exclude-open-ipv6-existing
mixed-explicit-guard-devices-dualstack
mixed-exclude-open-quic-multiwan
tproxy-explicit-empty-detection-guard
tun-exclude-empty-detection-guard
mixed-explicit-guard-provider-bypass
mixed-exclude-fakeip-whitelist
tproxy-exclude-device-policies
tun-explicit-existing-clash-tun'

write_scenario_settings() {
	name=$1
	proxy_mode=tproxy interface_mode=explicit guard=false quic=false lan=br-lan wan=eth1
	auto_wan=false capture_wan4=eth1 capture_wan6= existing=false server_lines=
	case "$name" in
		tproxy-explicit-guard-ipv4-quic) guard=true quic=true wan=pppoe-wan auto_wan=true capture_wan4=pppoe-wan server_lines='8.8.8.8' ;;
		tproxy-exclude-open-dualstack-multiwan) interface_mode=exclude lan=br-lan wan=pppoe-wan,wwan0 capture_wan4=pppoe-wan capture_wan6=wwan0 server_lines='1.1.1.1 2606:4700:4700::1111' ;;
		tun-explicit-guard-fakeip-ipv4) proxy_mode=tun guard=true ;;
		tun-exclude-open-ipv6-existing) proxy_mode=tun interface_mode=exclude wan=wan6 quic=true capture_wan4= capture_wan6=wan6 existing=true server_lines='2620:fe::fe' ;;
		mixed-explicit-guard-devices-dualstack) proxy_mode=mixed guard=true quic=true lan=br-lan,wlan0 auto_wan=true capture_wan6=eth1 ;;
		mixed-exclude-open-quic-multiwan) proxy_mode=mixed interface_mode=exclude quic=true wan=eth1,wwan0 ;;
		tproxy-explicit-empty-detection-guard) guard=true lan= wan= capture_wan4= ;;
		tun-exclude-empty-detection-guard) proxy_mode=tun interface_mode=exclude guard=true lan= wan= capture_wan4= ;;
		mixed-explicit-guard-provider-bypass) proxy_mode=mixed guard=true auto_wan=true capture_wan6=eth1 existing=true server_lines='9.9.9.9 2620:fe::9' ;;
		mixed-exclude-fakeip-whitelist) proxy_mode=mixed interface_mode=exclude ;;
		tproxy-exclude-device-policies) interface_mode=exclude guard=true quic=true ;;
		tun-explicit-existing-clash-tun) proxy_mode=tun guard=true quic=true lan=br-guest auto_wan=true existing=true server_lines='149.112.112.112' ;;
		*) fail "unknown scenario: $name" ;;
	esac
	mkdir -p "$root/opt/clash/lst" "$root/opt/clash"
	{
		printf 'PROXY_MODE=%s\n' "$proxy_mode"
		printf 'INTERFACE_MODE=%s\n' "$interface_mode"
		printf 'AUTO_DETECT_LAN=false\nAUTO_DETECT_WAN=%s\n' "$auto_wan"
		printf 'INCLUDED_INTERFACES=%s\nEXCLUDED_INTERFACES=%s\n' "$lan" "$wan"
		printf 'DETECTED_LAN=%s\nDETECTED_WAN=%s\n' "$lan" "$wan"
		printf 'INTERNET_ONLY_MICLASH=%s\nBLOCK_QUIC=%s\n' "$guard" "$quic"
		printf 'AUTO_FAKEIP_WHITELIST=false\n'
	} > "$root/opt/clash/settings"
	{
		printf 'mixed-port: 7890\ntproxy-port: 7894\n'
		if [ -n "$server_lines" ]; then
			printf 'proxies:\n'
			for server in $server_lines; do printf '  - name: capture-%s\n    server: %s\n' "$server" "$server"; done
		fi
		case "$name" in
			*tun-explicit-guard-fakeip*|*mixed-exclude-fakeip*)
				printf 'dns:\n  enhanced-mode: fake-ip\n  fake-ip-range: 198.18.0.1/16\n  fake-ip-filter-mode: whitelist\n'
				;;
		esac
	} > "$root/opt/clash/config.yaml"
	case "$name" in
		*tun-explicit-guard-fakeip*) printf '%s\n' '198.18.0.0/16' '8.8.4.0/24' > "$root/opt/clash/lst/fakeip-whitelist-ipcidr.txt" ;;
		*mixed-exclude-fakeip*) printf '%s\n' '198.18.0.0/16' '1.0.0.0/24' > "$root/opt/clash/lst/fakeip-whitelist-ipcidr.txt" ;;
		*) : > "$root/opt/clash/lst/fakeip-whitelist-ipcidr.txt" ;;
	esac
}

run_backend() {
	name=$1 backend=$2
	rm -f "$work_host/records/nft.raw" "$work_host/records/iptables.raw" "$work_host/records/routes.raw"
	write_scenario_settings "$name"
	case "$backend" in
		nft) capture_bin="$work_chroot/bin-nft" ;;
		iptables) capture_bin="$work_chroot/bin-iptables" ;;
		*) fail "unknown backend: $backend" ;;
	esac
	if ! unshare --mount --net --pid --fork /bin/sh -c \
		'mount --make-rprivate / || exit 1; exec "$@"' isolated \
		chroot "$root" /bin/sh -c \
		'PATH="$1:$2"; export PATH; MICLASH_RECORD_DIR="$3"; MICLASH_CAPTURE_WAN4="$4"; MICLASH_CAPTURE_WAN6="$5"; MICLASH_CAPTURE_TUN_EXISTS="$6"; export MICLASH_RECORD_DIR MICLASH_CAPTURE_WAN4 MICLASH_CAPTURE_WAN6 MICLASH_CAPTURE_TUN_EXISTS; exec /bin/sh "$7" start' \
		capture "$capture_bin" "$work_chroot/bin-common" "$work_chroot/records" \
		"$capture_wan4" "$capture_wan6" "$existing" "$work_chroot/clash-rules"
	then
		fail "isolated legacy capture failed for $name ($backend)"
	fi
}

printf '%s\n' "$scenario_names" | while IFS= read -r name; do
	[ -n "$name" ] || continue
	mkdir -p "$candidate_root/$name"
	run_backend "$name" nft
	normalize_nft "$work_host/records/nft.raw" "$candidate_root/$name/nft.candidate"
	normalize_routes "$work_host/records/routes.raw" "$candidate_root/$name/routes.candidate"
	run_backend "$name" iptables
	normalize_iptables "$work_host/records/iptables.raw" "$candidate_root/$name/iptables.candidate"
done

printf '%s\n' "Candidate captures written to: $candidate_root"
printf '%s\n' 'Review them manually; this tool never overwrites canonical golden fixtures.'
