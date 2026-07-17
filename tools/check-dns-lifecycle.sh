#!/bin/sh

set -eu

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
init="$repo_root/luci-app-miclash/rootfs/etc/init.d/clash"
network="$repo_root/luci-app-miclash/rootfs/usr/share/miclash/network.uc"
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
grep -Fq "import * as dns from 'miclash.dns'" "$network"
grep -Fq 'modules.dns.apply' "$network"
grep -Fq 'modules.dns.recover' "$network"
grep -Fq 'modules.dns.cleanup' "$network"
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

printf 'Native DNS process lifecycle gate passed\n'
