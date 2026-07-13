#!/bin/sh

set -eu

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
init="$repo_root/luci-app-miclash/rootfs/etc/init.d/clash"
owner="$repo_root/luci-app-miclash/rootfs/usr/share/miclash/dns.uc"
control="$repo_root/luci-app-miclash/rootfs/usr/share/miclash/dns-control.uc"
cleanup="$repo_root/luci-app-miclash/rootfs/usr/share/miclash/dns-cleanup.uc"
remove="$repo_root/luci-app-miclash/rootfs/usr/share/miclash/package-remove"
makefile="$repo_root/luci-app-miclash/Makefile"

if [ "${MICLASH_DNS_GATE_NS:-}" != 1 ]; then
	exec unshare --mount --pid --fork --mount-proc env MICLASH_DNS_GATE_NS=1 \
		UCODE_BIN="${UCODE_BIN:-}" LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}" sh "$0"
fi

for file in "$owner" "$control" "$cleanup"; do
	[ -f "$file" ] || { echo "missing shipped DNS owner: $file" >&2; exit 1; }
done

if grep -Eq 'setup_dns|restore_dns|verify_dns_restored|restart_dnsmasq|DNS_BACKUP_FILE' "$init"; then
	echo 'legacy shell DNS backend remains in clash init' >&2
	exit 1
fi
if grep -Eq '(^|[;&|[:space:]])uci([[:space:]]|$)|/etc/init.d/dnsmasq[[:space:]]+restart' "$init"; then
	echo 'clash init still mutates or restarts DNS directly' >&2
	exit 1
fi
grep -Fq 'dns_control apply' "$init"
grep -Fq 'dns_control cleanup' "$init"
grep -Fq "command: '/etc/init.d/dnsmasq', args: [ 'restart' ]" "$owner"
grep -Fq "command: '/etc/init.d/dnsmasq', args: [ 'running' ]" "$owner"
grep -Fq "write_json(runtime, MANIFEST_PATH" "$owner"
grep -Fq "with_lock(runtime" "$owner"
grep -Fq "runtime.mutation_lock_token = getenv('MICLASH_MUTATION_LOCK_TOKEN')" "$control"
grep -Fq "runtime.package_removal_cleanup = true" "$cleanup"
grep -Fq 'normalize(error).code' "$control"
grep -Fq 'normalize(error).code' "$cleanup"
grep -Fq '/usr/share/miclash/dns-cleanup.uc' "$remove"
grep -Fq 'protect_dns_proof' "$remove"
grep -Fq '[ ! -e /etc/miclash/dns-ownership.json ]' "$makefile"
grep -Fq '[ ! -e /opt/clash/.dns_backup ]' "$makefile"

[ -n "${UCODE_BIN:-}" ] && [ -x "$UCODE_BIN" ] || {
	echo 'DNS lifecycle gate requires UCODE_BIN' >&2
	exit 1
}

mount --make-rprivate /
for path in /etc/miclash /opt/clash /var/run/miclash /etc/init.d /usr/share/miclash; do
	mkdir -p "$path"
	mount -t tmpfs -o mode=0755,size=2m miclash-dns-gate "$path"
done
chmod 0700 /etc/miclash /var/run/miclash

fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT INT TERM
export MICLASH_DNS_GATE_STATE="$fixture/uci.json"
export MICLASH_DNS_GATE_FAIL="$fixture/fail"
export MICLASH_DNS_GATE_LOG="$fixture/lifecycle.log"
export MICLASH_DNS_GATE_FIXTURE="$fixture"

cat > "$fixture/uci.uc" <<'EOF'
let fs = require('fs');
let state_path = getenv('MICLASH_DNS_GATE_STATE');
let fail_path = getenv('MICLASH_DNS_GATE_FAIL');
function clone(value) { return value == null ? value : json(sprintf('%J', value)); };
function load_state() { return json(fs.readfile(state_path)); };
function cursor() {
	let committed = load_state(), values = clone(committed), dirty = false;
	return {
		get: (config, section, option) => clone(values[config]?.[section]?.[option]),
		get_first: (config, wanted) => {
			for (let name, section in values[config] ?? {})
				if (section?.['.type'] == wanted) return name;
			return null;
		},
		get_all: (config, section) => section == null ? clone(values[config]) : clone(values[config]?.[section]),
		changes: (config) => fs.stat(fail_path + '-pending') != null ? { injected: true } :
			(dirty ? { local: true } : {}),
		set: (config, section, option, value) => {
			values[config] ??= {}; values[config][section] ??= {};
			values[config][section][option] = clone(value); dirty = true; return true;
		},
		delete: (config, section, option) => {
			if (values[config]?.[section] == null || !exists(values[config][section], option)) return false;
			delete values[config][section][option]; dirty = true; return true;
		},
		revert: (config) => { values = clone(committed); dirty = false; return true; },
		commit: (config) => {
			if (fs.stat(fail_path + '-commit') != null) return null;
			fs.writefile(state_path, sprintf('%J\n', values)); committed = clone(values); dirty = false; return true;
		}
	};
};
return { cursor };
EOF

cat > /etc/init.d/dnsmasq <<'EOF'
#!/bin/sh
printf '%s\n' "dnsmasq-${1:-}" >> "$MICLASH_DNS_GATE_LOG"
[ -e /var/run/miclash/guard-active ] || exit 91
case "${1:-}" in
	restart) [ ! -e "$MICLASH_DNS_GATE_FAIL-restart" ] ;;
	running) [ ! -e "$MICLASH_DNS_GATE_FAIL-running" ] ;;
	*) exit 1 ;;
esac
EOF
chmod 0700 /etc/init.d/dnsmasq

module_dir="$(dirname -- "$UCODE_BIN")"
export MICLASH_DNS_GATE_MODULE_DIR="$module_dir"
run_control() {
	"$UCODE_BIN" -L "$module_dir/*.so" -L "$fixture" \
		-L "$repo_root/luci-app-miclash/rootfs/usr/share" "$control" "$1"
}
run_package_cleanup() {
	"$UCODE_BIN" -L "$module_dir/*.so" -L "$fixture" \
		-L "$repo_root/luci-app-miclash/rootfs/usr/share" "$cleanup"
}
reset_state() {
	rm -rf /var/run/miclash/mutation.lock /var/run/miclash/mutation.lock.takeover \
		/var/run/miclash/package-removal
	rm -f /etc/miclash/dns-ownership.json /opt/clash/.dns_backup "$fixture"/fail-*
	printf '%s\n' '{"dhcp":{"main":{".type":"dnsmasq","server":["1.1.1.1"],"cachesize":"1000"}}}' \
		> "$MICLASH_DNS_GATE_STATE"
	: > /var/run/miclash/guard-active
}
assert_guard() { [ -f /var/run/miclash/guard-active ]; }
assert_no_guard() { [ ! -e /var/run/miclash/guard-active ]; }
assert_before() {
	first="$(grep -n -m1 -F "$1" "$MICLASH_DNS_GATE_LOG" 2>/dev/null | cut -d: -f1 || true)"
	second="$(grep -n -m1 -F "$2" "$MICLASH_DNS_GATE_LOG" 2>/dev/null | cut -d: -f1 || true)"
	[ -n "$first" ] && [ -n "$second" ] && [ "$first" -lt "$second" ] || {
		echo "lifecycle order violation: $1 must precede $2" >&2
		cat "$MICLASH_DNS_GATE_LOG" >&2
		exit 1
	}
}

reset_state
run_control apply
grep -Fq '127.0.0.1#7874' "$MICLASH_DNS_GATE_STATE"
grep -Eq '"cachesize"[[:space:]]*:[[:space:]]*"0"' "$MICLASH_DNS_GATE_STATE"
grep -Eq '"noresolv"[[:space:]]*:[[:space:]]*"1"' "$MICLASH_DNS_GATE_STATE"
[ "$(stat -c '%u:%a' /etc/miclash/dns-ownership.json)" = 0:600 ]
run_control apply
run_control cleanup
grep -Eq '"server"[[:space:]]*:[[:space:]]*\[[[:space:]]*"1.1.1.1"[[:space:]]*\]' "$MICLASH_DNS_GATE_STATE"
grep -Eq '"cachesize"[[:space:]]*:[[:space:]]*"1000"' "$MICLASH_DNS_GATE_STATE"
[ ! -e /etc/miclash/dns-ownership.json ]
assert_guard

reset_state
run_control apply
printf '%s\n' '{"dhcp":{"main":{".type":"dnsmasq","server":["1.1.1.1","127.0.0.1#7874"],"cachesize":"77","noresolv":"1"}}}' \
	> "$MICLASH_DNS_GATE_STATE"
if run_control apply >/dev/null 2>&1; then
	echo 'fixed DNS adapter accepted committed-active scalar drift' >&2; exit 1
fi
grep -Eq '"cachesize"[[:space:]]*:[[:space:]]*"77"' "$MICLASH_DNS_GATE_STATE"
[ -f /etc/miclash/dns-ownership.json ]

reset_state
run_control apply
: > "$MICLASH_DNS_GATE_FAIL-pending"
if run_control apply >/dev/null 2>&1; then
	echo 'fixed DNS adapter accepted committed-active pending UCI deltas' >&2; exit 1
fi
[ -f /etc/miclash/dns-ownership.json ]

reset_state
run_control apply
printf '%s\n' '{"dhcp":{"other":{".type":"dnsmasq","server":["1.1.1.1","127.0.0.1#7874"],"cachesize":"0","noresolv":"1"}}}' \
	> "$MICLASH_DNS_GATE_STATE"
if run_control apply >/dev/null 2>&1; then
	echo 'fixed DNS adapter accepted committed-active section replacement' >&2; exit 1
fi
grep -Fq '"other"' "$MICLASH_DNS_GATE_STATE"
[ -f /etc/miclash/dns-ownership.json ]

reset_state
: > "$MICLASH_DNS_GATE_FAIL-restart"
if run_control apply >/dev/null 2>&1; then
	echo 'DNS entrypoint ignored restart failure' >&2; exit 1
fi
[ -f /etc/miclash/dns-ownership.json ]
grep -Fq '"transition"' /etc/miclash/dns-ownership.json
assert_guard
rm -f "$MICLASH_DNS_GATE_FAIL-restart"
run_control apply
grep -Eq '"transition"[[:space:]]*:[[:space:]]*null' /etc/miclash/dns-ownership.json

reset_state
: > "$MICLASH_DNS_GATE_FAIL-commit"
if run_control apply >/dev/null 2>&1; then
	echo 'DNS entrypoint ignored UCI commit failure' >&2; exit 1
fi
[ -f /etc/miclash/dns-ownership.json ]
grep -Eq '"cachesize"[[:space:]]*:[[:space:]]*"1000"' "$MICLASH_DNS_GATE_STATE"
assert_guard
rm -f "$MICLASH_DNS_GATE_FAIL-commit"
run_control apply
grep -Fq '127.0.0.1#7874' "$MICLASH_DNS_GATE_STATE"

reset_state
: > "$MICLASH_DNS_GATE_FAIL-running"
if run_control apply >/dev/null 2>&1; then
	echo 'DNS entrypoint ignored dnsmasq running failure' >&2; exit 1
fi
[ -f /etc/miclash/dns-ownership.json ]
assert_guard
rm -f "$MICLASH_DNS_GATE_FAIL-running"
run_control apply
grep -Eq '"transition"[[:space:]]*:[[:space:]]*null' /etc/miclash/dns-ownership.json

reset_state
printf '%s\n' '{"dhcp":{"main":{".type":"dnsmasq","server":["127.0.0.1#7874"],"cachesize":"0","noresolv":"1"}}}' \
	> "$MICLASH_DNS_GATE_STATE"
printf 'CACHESIZE=1000\nNORESOLV=0\n' > /opt/clash/.dns_backup
chmod 0600 /opt/clash/.dns_backup
mount --bind /opt/clash/.dns_backup /opt/clash/.dns_backup
if run_control apply >/dev/null 2>&1; then
	echo 'DNS entrypoint ignored legacy unlink failure' >&2; exit 1
fi
[ -f /etc/miclash/dns-ownership.json ] && [ -f /opt/clash/.dns_backup ]
assert_guard
umount /opt/clash/.dns_backup
run_control apply
[ ! -e /opt/clash/.dns_backup ]

reset_state
: > "$MICLASH_DNS_GATE_FAIL-pending"
if run_control apply >/dev/null 2>&1; then
	echo 'DNS entrypoint ignored pending UCI changes' >&2; exit 1
fi
[ ! -e /etc/miclash/dns-ownership.json ]
assert_guard

reset_state
chmod 0777 /etc/miclash
if run_control apply >/dev/null 2>&1; then
	echo 'DNS entrypoint accepted an insecure authority directory' >&2; exit 1
fi
grep -Eq '"cachesize"[[:space:]]*:[[:space:]]*"1000"' "$MICLASH_DNS_GATE_STATE"
assert_guard
chmod 0700 /etc/miclash

reset_state
run_control apply
. "$repo_root/luci-app-miclash/rootfs/usr/share/miclash/mutation-lock.sh"
mkdir /var/run/miclash/package-removal
chmod 0700 /var/run/miclash/package-removal
miclash_mutation_lock_enter_package_owner 1000
run_package_cleanup
miclash_mutation_lock_leave
[ -f /etc/miclash/dns-ownership.json ]
grep -Eq '"state"[[:space:]]*:[[:space:]]*"clean"' /etc/miclash/dns-ownership.json
grep -Eq '"transition"[[:space:]]*:[[:space:]]*null' /etc/miclash/dns-ownership.json
assert_guard

# Execute the shipped init service entrypoints against stateful firewall, DNS,
# procd and core shims. The shims reject any transition attempted without Guard.
cp "$repo_root"/luci-app-miclash/rootfs/usr/share/miclash/*.uc /usr/share/miclash/
cp "$repo_root/luci-app-miclash/rootfs/usr/share/miclash/mutation-lock.sh" /usr/share/miclash/
mkdir -p /opt/clash/bin
cp "$repo_root/luci-app-miclash/rootfs/opt/clash/bin/clash-rules" "$fixture/clash-rules.actual"
chmod 0700 "$fixture/clash-rules.actual"
cat > "$fixture/ucode" <<'EOF'
#!/bin/sh
for argument in "$@"; do
	[ "$argument" != /usr/share/miclash/guard-runtime.uc ] || guard_runtime=1
done
if [ "${guard_runtime:-0}" = 1 ]; then
	while [ "${1:-}" != /usr/share/miclash/guard-runtime.uc ]; do shift; done
	shift
	command="${1:-}"
	printf '%s\n' "guard-runtime-$command" >> "$MICLASH_DNS_GATE_NFT_LOG"
	case "$command" in
		protect)
			[ ! -e "$MICLASH_DNS_GATE_FAIL-guard-protect" ] || exit 1
			: > "$MICLASH_DNS_GATE_EMERGENCY_STATE"
			;;
		release)
			[ ! -e "$MICLASH_DNS_GATE_FAIL-guard-release" ] || exit 1
			rm -f "$MICLASH_DNS_GATE_EMERGENCY_STATE"
			;;
		disable)
			rm -f "$MICLASH_DNS_GATE_EMERGENCY_STATE"
			;;
		verify-nft)
			cat >/dev/null
			[ ! -e "$MICLASH_DNS_GATE_FAIL-guard-verify" ] || exit 1
			[ -e "$MICLASH_DNS_GATE_NFT_STATE" ]
			;;
		verify-iptables4|verify-iptables6)
			cat >/dev/null
			exit 1
			;;
		*) exit 1 ;;
	esac
	exit $?
fi
exec "$UCODE_BIN" -L "$MICLASH_DNS_GATE_MODULE_DIR/*.so" \
	-L "$MICLASH_DNS_GATE_FIXTURE/*.uc" "$@" >> "$MICLASH_DNS_GATE_LOG.ucode" 2>&1
EOF
chmod 0700 "$fixture/ucode"
mkdir -p /usr/bin
[ -e /usr/bin/ucode ] || : > /usr/bin/ucode
mount --bind "$fixture/ucode" /usr/bin/ucode
cat > "$fixture/logger" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod 0700 "$fixture/logger"
PATH="$fixture:$PATH"
export PATH

export MICLASH_DNS_GATE_NFT_STATE="$fixture/nft-guard-active"
export MICLASH_DNS_GATE_EMERGENCY_STATE="$fixture/nft-guard-emergency"
export MICLASH_DNS_GATE_NFT_LOG="$fixture/nft.log"
cat > "$fixture/nft" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$MICLASH_DNS_GATE_NFT_LOG"
case "$*" in
	'list ruleset')
		[ ! -e "$MICLASH_DNS_GATE_FAIL-guard-inventory" ] || exit 1
		[ ! -e "$MICLASH_DNS_GATE_NFT_STATE" ] ||
			echo 'table inet miclash_guard { chain forward { meta nfproto ipv4 drop comment "miclash-guard"; } }'
		;;
	'list table inet miclash_guard')
		[ -e "$MICLASH_DNS_GATE_NFT_STATE" ] && echo 'table inet miclash_guard' || exit 1
		;;
	'-j list table inet miclash_guard')
		[ -e "$MICLASH_DNS_GATE_NFT_STATE" ] && echo '{"nftables":[]}' || exit 1
		;;
	'list chain inet miclash_guard forward')
		[ -e "$MICLASH_DNS_GATE_NFT_STATE" ] || exit 1
		echo 'chain forward { meta nfproto ipv4 drop comment "miclash-guard"; }'
		;;
	'delete table inet miclash_guard')
		rm -f "$MICLASH_DNS_GATE_NFT_STATE"
		[ ! -e "$MICLASH_DNS_GATE_FAIL-guard-remove" ]
		;;
	'add table inet miclash_guard')
		: > "$MICLASH_DNS_GATE_NFT_STATE"
		;;
	add\ rule\ *) [ ! -e "$MICLASH_DNS_GATE_FAIL-guard-add" ] ;;
	add\ *) ;;
	*) exit 1 ;;
esac
EOF
chmod 0700 "$fixture/nft"

run_actual_rules() {
	rm -rf /var/run/miclash/mutation.lock /var/run/miclash/mutation.lock.takeover
	"$fixture/clash-rules.actual" "$@" > "$fixture/rules.out" 2>&1
}
printf '%s\n' 'INTERNET_ONLY_MICLASH=true' > /opt/clash/settings
rm -rf /var/run/miclash/package-removal
: > "$MICLASH_DNS_GATE_NFT_STATE"
: > "$MICLASH_DNS_GATE_EMERGENCY_STATE"
: > "$MICLASH_DNS_GATE_NFT_LOG"
if ! run_actual_rules guard_finalize; then
	echo 'shipped clash-rules lacks successful enabled Guard finalization' >&2
	cat "$fixture/rules.out" >&2
	exit 1
fi
[ -e "$MICLASH_DNS_GATE_NFT_STATE" ]
if grep -Eq '^(add|delete) ' "$MICLASH_DNS_GATE_NFT_LOG"; then
	echo 'enabled Guard finalization mutated proven Guard state' >&2; exit 1
fi

# A protection precondition failure must occur before any destructive runtime
# mutation and preserve the last exact runtime Guard.
: > "$MICLASH_DNS_GATE_NFT_STATE"
rm -f "$MICLASH_DNS_GATE_EMERGENCY_STATE"
: > "$MICLASH_DNS_GATE_NFT_LOG"
: > "$MICLASH_DNS_GATE_FAIL-guard-protect"
printf '%s\n' 'INTERNET_ONLY_MICLASH=false' > /opt/clash/settings
if run_actual_rules guard_finalize; then
	echo 'disabled finalization ignored emergency protection failure' >&2; exit 1
fi
[ -e "$MICLASH_DNS_GATE_NFT_STATE" ]
! grep -Fq 'delete table inet miclash_guard' "$MICLASH_DNS_GATE_NFT_LOG"
rm -f "$MICLASH_DNS_GATE_FAIL-guard-protect"

# Every nft mutation failure and every exact-proof failure retains the freshly
# established emergency owner and refuses to publish success.
for failure in guard-add guard-verify; do
	printf '%s\n' 'INTERNET_ONLY_MICLASH=true' > /opt/clash/settings
	rm -f "$MICLASH_DNS_GATE_NFT_STATE" "$MICLASH_DNS_GATE_EMERGENCY_STATE"
	: > "$MICLASH_DNS_GATE_NFT_LOG"
	: > "$MICLASH_DNS_GATE_FAIL-$failure"
	if run_actual_rules guard_start; then
		echo "runtime Guard rebuild ignored $failure" >&2; exit 1
	fi
	[ -e "$MICLASH_DNS_GATE_EMERGENCY_STATE" ]
	grep -Fq 'guard-runtime-protect' "$MICLASH_DNS_GATE_NFT_LOG"
	! grep -Fq 'guard-runtime-release' "$MICLASH_DNS_GATE_NFT_LOG"
	rm -f "$MICLASH_DNS_GATE_FAIL-$failure"
done

# A release failure occurs only after exact runtime proof; it still reports
# failure and leaves emergency protection installed for retry.
printf '%s\n' 'INTERNET_ONLY_MICLASH=true' > /opt/clash/settings
rm -f "$MICLASH_DNS_GATE_NFT_STATE" "$MICLASH_DNS_GATE_EMERGENCY_STATE"
: > "$MICLASH_DNS_GATE_NFT_LOG"
: > "$MICLASH_DNS_GATE_FAIL-guard-release"
if run_actual_rules guard_start; then
	echo 'runtime Guard rebuild ignored emergency release failure' >&2; exit 1
fi
[ -e "$MICLASH_DNS_GATE_NFT_STATE" ] && [ -e "$MICLASH_DNS_GATE_EMERGENCY_STATE" ]
grep -Fq 'guard-runtime-verify-nft' "$MICLASH_DNS_GATE_NFT_LOG"
grep -Fq 'guard-runtime-release' "$MICLASH_DNS_GATE_NFT_LOG"
rm -f "$MICLASH_DNS_GATE_FAIL-guard-release"

printf '%s\n' 'INTERNET_ONLY_MICLASH=false' > /opt/clash/settings
: > "$MICLASH_DNS_GATE_NFT_STATE"
rm -f "$MICLASH_DNS_GATE_EMERGENCY_STATE"
: > "$MICLASH_DNS_GATE_NFT_LOG"
: > "$MICLASH_DNS_GATE_FAIL-guard-remove"
if run_actual_rules guard_finalize; then
	echo 'shipped clash-rules ignored Guard removal failure' >&2; exit 1
fi
[ -e "$MICLASH_DNS_GATE_EMERGENCY_STATE" ] || {
	echo 'shipped clash-rules returned from finalization failure without proven Guard' >&2; exit 1
}
grep -Fq 'delete table inet miclash_guard' "$MICLASH_DNS_GATE_NFT_LOG"
grep -Fq 'guard-runtime-protect' "$MICLASH_DNS_GATE_NFT_LOG"
! grep -Fq 'guard-runtime-release' "$MICLASH_DNS_GATE_NFT_LOG"
rm -f "$MICLASH_DNS_GATE_FAIL-guard-remove"

: > "$MICLASH_DNS_GATE_NFT_STATE"
rm -f "$MICLASH_DNS_GATE_EMERGENCY_STATE"
: > "$MICLASH_DNS_GATE_NFT_LOG"
: > "$MICLASH_DNS_GATE_FAIL-guard-inventory"
if run_actual_rules guard_finalize; then
	echo 'shipped clash-rules accepted disabled Guard state without a readable backend inventory' >&2
	exit 1
fi
[ -e "$MICLASH_DNS_GATE_EMERGENCY_STATE" ] || {
	echo 'Guard inventory failure did not restore fail-closed protection' >&2; exit 1
}
grep -Fq 'guard-runtime-protect' "$MICLASH_DNS_GATE_NFT_LOG"
! grep -Fq 'guard-runtime-release' "$MICLASH_DNS_GATE_NFT_LOG"
rm -f "$MICLASH_DNS_GATE_FAIL-guard-inventory"

cat > /opt/clash/bin/clash <<'EOF'
#!/bin/sh
[ ! -e "$MICLASH_DNS_GATE_FAIL-core" ]
EOF
chmod 0700 /opt/clash/bin/clash
cat > /opt/clash/bin/clash-rules <<'EOF'
#!/bin/sh
command="${1:-}"
shift || true
log() { printf '%s\n' "$1" >> "$MICLASH_DNS_GATE_LOG"; }
require_guard() {
	[ -e /var/run/miclash/guard-active ] || {
		log "guard-missing-$command"
		exit 91
	}
}
case "$command" in
	guard_start)
		log guard-start
		[ ! -e "$MICLASH_DNS_GATE_FAIL-guard-start" ] || exit 1
		: > /var/run/miclash/guard-active
		;;
	guard_refresh)
		log guard-refresh
		if [ -e "$MICLASH_DNS_GATE_FAIL-guard-refresh" ] ||
		   { [ -e "$MICLASH_DNS_GATE_FAIL-guard-refresh-final" ] && [ -e /var/run/miclash/firewall-active ]; }; then
			exit 1
		fi
		if [ -e "$MICLASH_DNS_GATE_FAIL-guard-desired-off" ]; then
			rm -f /var/run/miclash/guard-active
		else
			: > /var/run/miclash/guard-active
		fi
		;;
	guard_finalize)
		log guard-finalize
		require_guard
		if [ -e "$MICLASH_DNS_GATE_FAIL-guard-finalize-enabled" ]; then
			log guard-verify
			exit 1
		fi
		if [ -e "$MICLASH_DNS_GATE_FAIL-guard-desired-off" ]; then
			rm -f /var/run/miclash/guard-active
			if [ -e "$MICLASH_DNS_GATE_FAIL-guard-remove" ]; then
				: > /var/run/miclash/guard-active
				log guard-restore
				log guard-verify
				exit 1
			fi
		else
			log guard-verify
		fi
		;;
	start)
		log "rules-start:${1:-}"
		require_guard
		[ "${1:-}" = true ] || exit 92
		[ ! -e "$MICLASH_DNS_GATE_FAIL-firewall-start" ] || exit 1
		: > /var/run/miclash/firewall-active
		;;
	stop)
		log "rules-stop:${1:-}:${2:-}:${3:-}"
		require_guard
		[ "${2:-}" = true ] || exit 93
		rm -f /var/run/miclash/firewall-active
		[ ! -e "$MICLASH_DNS_GATE_FAIL-firewall-stop" ] || exit 1
		;;
	package_cleanup)
		log rules-package-cleanup
		require_guard
		rm -f /var/run/miclash/firewall-active
		;;
	*) exit 94 ;;
esac
EOF
chmod 0700 /opt/clash/bin/clash-rules
printf '%s\n' 'mode: rule' > /opt/clash/config.yaml

procd_open_instance() { printf '%s\n' procd-open >> "$MICLASH_DNS_GATE_LOG"; }
procd_set_param() { :; }
procd_close_instance() { printf '%s\n' procd-close >> "$MICLASH_DNS_GATE_LOG"; }
run_init_start() ( . "$init"; start_service )
run_init_stop() ( . "$init"; stop_service )
reset_init_state() {
	reset_state
	rm -f /var/run/miclash/guard-active /var/run/miclash/firewall-active
	: > "$MICLASH_DNS_GATE_LOG"
}

reset_init_state
: > "$MICLASH_DNS_GATE_FAIL-guard-start"
if run_init_start >/dev/null 2>&1; then
	echo 'shipped init ignored Guard establishment failure' >&2; exit 1
fi
[ ! -e /var/run/miclash/firewall-active ]
[ ! -e /etc/miclash/dns-ownership.json ]

reset_init_state
run_init_start || { cat "$MICLASH_DNS_GATE_LOG.ucode" >&2; exit 1; }
assert_guard
assert_before guard-start rules-start:true
assert_before rules-start:true dnsmasq-restart
assert_before procd-close guard-finalize
if grep -Fq guard-refresh "$MICLASH_DNS_GATE_LOG"; then
	echo 'shipped init used destructive Guard refresh after procd registration' >&2; exit 1
fi

reset_init_state
: > "$MICLASH_DNS_GATE_FAIL-guard-desired-off"
run_init_start
assert_no_guard
assert_before procd-close guard-finalize

reset_init_state
: > "$MICLASH_DNS_GATE_FAIL-restart"
if run_init_start >/dev/null 2>&1; then
	echo 'shipped init ignored DNS failure' >&2; exit 1
fi
assert_guard
[ ! -e /var/run/miclash/firewall-active ]
assert_before guard-start rules-start:true
assert_before dnsmasq-restart rules-stop:false:true:

reset_init_state
: > "$MICLASH_DNS_GATE_FAIL-guard-finalize-enabled"
if run_init_start >/dev/null 2>&1; then
	echo 'shipped init ignored enabled Guard finalization failure' >&2; exit 1
fi
assert_guard
[ -e /var/run/miclash/firewall-active ]
assert_before procd-close guard-finalize

reset_init_state
: > "$MICLASH_DNS_GATE_FAIL-guard-desired-off"
: > "$MICLASH_DNS_GATE_FAIL-guard-remove"
if run_init_start >/dev/null 2>&1; then
	echo 'shipped init ignored disabled Guard removal failure' >&2; exit 1
fi
assert_guard
grep -Fq guard-restore "$MICLASH_DNS_GATE_LOG"
assert_before procd-close guard-finalize

reset_init_state
run_init_start
: > "$MICLASH_DNS_GATE_FAIL-guard-desired-off"
: > "$MICLASH_DNS_GATE_LOG"
run_init_stop
assert_no_guard
[ ! -e /var/run/miclash/firewall-active ]
assert_before guard-start rules-stop:false:true:
assert_before rules-stop:false:true: dnsmasq-restart
assert_before dnsmasq-running guard-finalize

reset_init_state
run_init_start
: > "$MICLASH_DNS_GATE_FAIL-restart"
: > "$MICLASH_DNS_GATE_LOG"
if run_init_stop >/dev/null 2>&1; then
	echo 'shipped init ignored DNS cleanup failure' >&2; exit 1
fi
assert_guard
[ ! -e /var/run/miclash/firewall-active ]

UCODE_BIN="$UCODE_BIN" "$repo_root/tools/run-ucode-tests.sh" \
	"$repo_root/tests/ucode/test-dns.uc"

echo 'DNS lifecycle gate passed'
