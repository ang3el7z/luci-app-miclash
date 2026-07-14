#!/bin/sh

set -eu

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
helper="$repo_root/luci-app-miclash/rootfs/usr/share/miclash/package-release"
[ -x "$helper" ] || {
	echo 'packaged retryable release helper missing' >&2
	exit 1
}

if [ "${MICLASH_PACKAGE_RELEASE_NS:-}" != 1 ]; then
	exec unshare --mount --fork env MICLASH_PACKAGE_RELEASE_NS=1 sh "$0"
fi

mount --make-rprivate /
mkdir -p /var/run/miclash
mount -t tmpfs -o mode=0700,size=1m miclash-release-test /var/run/miclash
chmod 0700 /var/run/miclash
BARRIER=/var/run/miclash/package-removal
RELEASE=/var/run/miclash/package-removal-release

fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT INT TERM
mkdir -p "$fixture/bin" "$fixture/state"
: > "$fixture/legacy4"
export MICLASH_RELEASE_TEST_STATE="$fixture/state"
PATH="$fixture/bin:/usr/bin:/bin"
export PATH

case_enabled() {
	[ "${MICLASH_RELEASE_CASE:-all}" = all ] || [ "$MICLASH_RELEASE_CASE" = "$1" ]
}

cat > "$fixture/bin/cat" <<'EOF'
#!/bin/sh
if [ "$#" -eq 1 ] && [ "$1" = /proc/net/ip_tables_names ]; then
	exec /bin/cat "$MICLASH_RELEASE_TEST_STATE/../legacy4"
fi
exec /bin/cat "$@"
EOF

cat > "$fixture/bin/mv" <<'EOF'
#!/bin/sh
state="$MICLASH_RELEASE_TEST_STATE"
if [ -f "$state/fail-hold-restore" ] &&
	[ "${1:-}" = /var/run/miclash/package-removal-release/barrier-complete.hold ] &&
	[ "${2:-}" = /var/run/miclash/package-removal/complete ]; then
	exit 1
fi
exec /bin/mv "$@"
EOF

cat > "$fixture/bin/rm" <<'EOF'
#!/bin/sh
state="$MICLASH_RELEASE_TEST_STATE"
last=
for item in "$@"; do last="$item"; done
if [ -f "$state/fail-dns-proof-remove" ]; then
	for item in "$@"; do
		[ "$item" != /var/run/miclash/package-removal-release.cleanup/dns-ownership.json ] || exit 1
	done
fi
if [ -f "$state/fail-hold-remove" ] &&
	[ "$last" = /var/run/miclash/package-removal-release/barrier-complete.hold ]; then
	exit 1
fi
exec /bin/rm "$@"
EOF

cat > "$fixture/bin/nft" <<'EOF'
#!/bin/sh
state="$MICLASH_RELEASE_TEST_STATE"
case "$*" in
	'list tables')
		[ ! -f "$state/fail-nft-inventory" ] || exit 1
		if [ -f "$state/fail-nft-verify" ] && [ -f "$state/nft-applied" ]; then
			echo 'table inet miclash_guard_bootstrap_v1'
		else
			cat "$state/nft.tables"
		fi
		;;
	'list ruleset')
		[ ! -f "$state/fail-nft-ruleset-inventory" ] || exit 1
		cat "$state/nft.ruleset"
		;;
	-f\ *)
		batch="$2"
		[ ! -f "$state/fail-nft-delete" ] || exit 1
		if [ -f "$state/fail-nft-partial" ]; then
			grep -v '^table inet miclash_guard_bootstrap_v1$' "$state/nft.tables" \
				> "$state/nft.tables.next"
			mv "$state/nft.tables.next" "$state/nft.tables"
			: > "$state/nft-applied"
			exit 1
		fi
		while IFS= read -r line; do
			set -- $line
			[ "${1:-}" = delete ] && [ "${2:-}" = table ] && [ "${3:-}" = inet ] || continue
			grep -v "^table inet ${4}$" "$state/nft.tables" > "$state/nft.tables.next"
			mv "$state/nft.tables.next" "$state/nft.tables"
		done < "$batch"
		: > "$state/nft-applied"
		;;
	*) exit 1 ;;
esac
EOF

cat > "$fixture/bin/iptables-save" <<'EOF'
#!/bin/sh
state="$MICLASH_RELEASE_TEST_STATE"
family=iptables
[ ! -f "$state/fail-iptables-inventory" ] || exit 1
if [ -f "$state/fail-iptables-verify" ] && [ -f "$state/$family-applied" ]; then
	cat "$state/$family.original"
else
	cat "$state/$family.filter"
fi
EOF
sed 's/family=iptables/family=ip6tables/' "$fixture/bin/iptables-save" \
	> "$fixture/bin/ip6tables-save"
cat > "$fixture/bin/iptables-restore" <<'EOF'
#!/bin/sh
state="$MICLASH_RELEASE_TEST_STATE"
family=iptables
cat > "$state/$family.next"
[ ! -f "$state/fail-iptables-apply" ] || exit 1
mv "$state/$family.next" "$state/$family.filter"
: > "$state/$family-applied"
EOF
sed 's/family=iptables/family=ip6tables/' "$fixture/bin/iptables-restore" \
	> "$fixture/bin/ip6tables-restore"
chmod 0700 "$fixture/bin/cat" "$fixture/bin/mv" "$fixture/bin/rm" "$fixture/bin/nft" \
	"$fixture/bin/iptables-save" \
	"$fixture/bin/ip6tables-save" "$fixture/bin/iptables-restore" \
	"$fixture/bin/ip6tables-restore"
sed -n '/^define Package\/\$(PKG_NAME)\/postrm$/,/^endef$/p' \
	"$repo_root/luci-app-miclash/Makefile" |
	sed '1d;$d;s/\$\$/\$/g' > "$fixture/postrm"
chmod 0700 "$fixture/postrm"

seed_guard() {
	rm -f "$fixture/state"/*
	: > "$fixture/legacy4"
	: > "$fixture/state/nft.ruleset"
	printf '%s\n' \
		'table inet miclash_guard_bootstrap_v1' \
		'table inet miclash_guard_emergency_v1' \
		'table inet miclash_guard' > "$fixture/state/nft.tables"
	for family in iptables ip6tables; do
		cat > "$fixture/state/$family.filter" <<'EOF'
*filter
:INPUT ACCEPT [0:0]
:FORWARD ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
:MICLASH_GUARD_FORWARD - [0:0]
-A FORWARD -j MICLASH_GUARD_FORWARD
-A MICLASH_GUARD_FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
-A MICLASH_GUARD_FORWARD -j DROP
COMMIT
EOF
		cp "$fixture/state/$family.filter" "$fixture/state/$family.original"
	done
}

guard_present() {
	grep -Eq '^table inet (miclash_guard_bootstrap_v1|miclash_guard_emergency_v1|miclash_guard)$' \
		"$fixture/state/nft.tables" 2>/dev/null && return 0
	grep -q 'MICLASH_GUARD_FORWARD' "$fixture/state/iptables.filter" 2>/dev/null && return 0
	grep -q 'MICLASH_GUARD_FORWARD' "$fixture/state/ip6tables.filter" 2>/dev/null
}

proof_retained() {
	{ [ -f "$BARRIER/complete" ] || [ -f "$RELEASE/barrier-complete.hold" ]; } &&
		[ -f "$RELEASE/complete" ] && [ -x "$RELEASE/helper" ] &&
		[ -f "$RELEASE/dns-ownership.json" ]
}

prepare() {
	rm -rf "$BARRIER" "$RELEASE" "$RELEASE.cleanup" "$RELEASE.done"
	mkdir "$BARRIER" "$RELEASE"
	chmod 0700 "$BARRIER" "$RELEASE"
	printf 'complete\n' > "$BARRIER/complete"
	printf 'complete\n' > "$RELEASE/complete"
	printf '%s\n' '{"version":1,"owner":"miclash","section":"main","original":{"server":{"present":false,"value":[]},"cachesize":{"present":false,"value":null},"noresolv":{"present":false,"value":null}},"target_preexisting":false,"state":"clean","transition":null,"clean":{"server":{"present":false,"value":[]},"cachesize":{"present":false,"value":null},"noresolv":{"present":false,"value":null}}}' > "$RELEASE/dns-ownership.json"
	cp "$helper" "$RELEASE/helper"
	chmod 0600 "$BARRIER/complete" "$RELEASE/complete" "$RELEASE/dns-ownership.json"
	chmod 0700 "$RELEASE/helper"
	seed_guard
}

run_postrm() {
	"$fixture/postrm" remove
}

prepare
rm -f "$RELEASE/dns-ownership.json"
if run_postrm; then
	echo 'actual postrm accepted release authority without a DNS clean proof' >&2
	exit 1
fi
guard_present

prepare
mkdir -p /etc/miclash
ln -s /nonexistent/miclash-dns-authority /etc/miclash/dns-ownership.json
if run_postrm; then
	echo 'actual postrm accepted a dangling DNS authority as absent' >&2
	exit 1
fi
proof_retained
guard_present
rm -f /etc/miclash/dns-ownership.json

prepare
mkdir -p /usr/share/miclash
ln -s /nonexistent/miclash-dns-control /usr/share/miclash/dns-control.uc
if run_postrm; then
	echo 'actual postrm accepted a dangling packaged mutator as absent' >&2
	exit 1
fi
proof_retained
guard_present
rm -f /usr/share/miclash/dns-control.uc

prepare
: > "$BARRIER/unexpected"
if "$RELEASE/helper" "$RELEASE"; then
	echo 'release helper ignored unexpected barrier debris' >&2
	exit 1
fi
proof_retained
guard_present
rm -f "$BARRIER/unexpected"
"$RELEASE/helper" "$RELEASE"
[ ! -e "$BARRIER" ]
[ -f "$RELEASE/complete" ]
[ -x "$RELEASE/helper" ]
if guard_present; then
	echo 'copied release helper left the primary Guard active after committed uninstall' >&2
	exit 1
fi

prepare
printf '%s\n' 'table ip miclash_guard_bootstrap_v1' >> "$fixture/state/nft.tables"
if "$RELEASE/helper" "$RELEASE"; then
	echo 'release helper accepted an owned nft name in an ambiguous family' >&2
	exit 1
fi
proof_retained
guard_present
sed -i '$d' "$fixture/state/nft.tables"
"$RELEASE/helper" "$RELEASE"
! guard_present

prepare
printf '%s\n' '-A INPUT -j MICLASH_GUARD_FORWARD' >> "$fixture/state/iptables.filter"
if "$RELEASE/helper" "$RELEASE"; then
	echo 'release helper accepted a foreign reference to the owned iptables chain' >&2
	exit 1
fi
proof_retained
guard_present
sed -i '$d' "$fixture/state/iptables.filter"
"$RELEASE/helper" "$RELEASE"
! guard_present

if case_enabled missing-tools; then
	prepare
	printf 'filter\n' > "$fixture/legacy4"
	/bin/mv "$fixture/bin/iptables-save" "$fixture/bin/iptables-save.off"
	/bin/mv "$fixture/bin/iptables-restore" "$fixture/bin/iptables-restore.off"
	if "$RELEASE/helper" "$RELEASE"; then
		echo 'release helper treated missing IPv4 inspection tools as absence proof' >&2
		exit 1
	fi
	proof_retained
	guard_present
	: > "$fixture/legacy4"
	/bin/mv "$fixture/bin/iptables-save.off" "$fixture/bin/iptables-save"
	/bin/mv "$fixture/bin/iptables-restore.off" "$fixture/bin/iptables-restore"
	"$RELEASE/helper" "$RELEASE"
	! guard_present
fi

if case_enabled nft-only-empty; then
	prepare
	grep -v 'MICLASH_GUARD_FORWARD' "$fixture/state/iptables.filter" \
		> "$fixture/state/iptables.clean"
	mv "$fixture/state/iptables.clean" "$fixture/state/iptables.filter"
	/bin/mv "$fixture/bin/iptables-save" "$fixture/bin/iptables-save.off"
	/bin/mv "$fixture/bin/iptables-restore" "$fixture/bin/iptables-restore.off"
	if ! "$RELEASE/helper" "$RELEASE"; then
		echo 'release helper refused nft-only absence proved by kernel and nft inventories' >&2
		exit 1
	fi
	! guard_present
	/bin/mv "$fixture/bin/iptables-save.off" "$fixture/bin/iptables-save"
	/bin/mv "$fixture/bin/iptables-restore.off" "$fixture/bin/iptables-restore"
fi

if case_enabled missing-tools-nft-chain; then
	prepare
	grep -v 'MICLASH_GUARD_FORWARD' "$fixture/state/iptables.filter" \
		> "$fixture/state/iptables.clean"
	mv "$fixture/state/iptables.clean" "$fixture/state/iptables.filter"
	printf '%s\n' 'table ip filter { chain MICLASH_GUARD_FORWARD { } }' \
		> "$fixture/state/nft.ruleset"
	/bin/mv "$fixture/bin/iptables-save" "$fixture/bin/iptables-save.off"
	/bin/mv "$fixture/bin/iptables-restore" "$fixture/bin/iptables-restore.off"
	if "$RELEASE/helper" "$RELEASE"; then
		echo 'release helper ignored an nft compatibility chain when iptables tools were missing' >&2
		exit 1
	fi
	proof_retained
	guard_present
	/bin/mv "$fixture/bin/iptables-save.off" "$fixture/bin/iptables-save"
	/bin/mv "$fixture/bin/iptables-restore.off" "$fixture/bin/iptables-restore"
fi

if case_enabled absent-barrier; then
	prepare
	/bin/rm -rf "$BARRIER"
	if "$RELEASE/helper" "$RELEASE"; then
		echo 'release helper accepted an absent barrier while Guard remained active' >&2
		exit 1
	fi
	guard_present
fi

prepare
mount --bind "$BARRIER" "$BARRIER"
if "$RELEASE/helper" "$RELEASE"; then
	echo 'release helper ignored a failed barrier rmdir' >&2
	exit 1
fi
proof_retained
! guard_present
umount "$BARRIER"
"$RELEASE/helper" "$RELEASE"
[ ! -e "$BARRIER" ]

if case_enabled hold-restore; then
	prepare
	mount --bind "$BARRIER" "$BARRIER"
	: > "$fixture/state/fail-hold-restore"
	if "$RELEASE/helper" "$RELEASE"; then
		echo 'release helper ignored failed proof restoration after barrier rmdir failure' >&2
		exit 1
	fi
	proof_retained
	rm -f "$fixture/state/fail-hold-restore"
	umount "$BARRIER"
	if ! "$RELEASE/helper" "$RELEASE"; then
		echo 'release helper could not retry from retained HOLD proof' >&2
		exit 1
	fi
	[ ! -e "$BARRIER" ]
fi

if case_enabled hold-remove; then
	prepare
	: > "$fixture/state/fail-hold-remove"
	if ! "$RELEASE/helper" "$RELEASE"; then
		echo 'release helper made local HOLD cleanup a post-barrier failure' >&2
		exit 1
	fi
	[ ! -e "$BARRIER" ]
	[ -f "$RELEASE/barrier-complete.hold" ]
	/bin/rm -f "$fixture/state/fail-hold-remove"
	rm -f "$RELEASE/barrier-complete.hold"
	"$RELEASE/helper" "$RELEASE"
fi

if case_enabled postrm-hold-retry; then
	prepare
	mount --bind "$BARRIER" "$BARRIER"
	if "$RELEASE/helper" "$RELEASE"; then
		echo 'release helper ignored a failed barrier rmdir before postrm retry' >&2
		exit 1
	fi
	umount "$BARRIER"
	if ! run_postrm; then
		echo 'actual postrm rejected the retained empty-barrier-plus-HOLD proof' >&2
		exit 1
	fi
	[ ! -e "$BARRIER" ] && [ ! -e "$RELEASE" ]
fi

if case_enabled postrm-release-cleanup; then
	prepare
	mount --bind "$RELEASE" "$RELEASE"
	if run_postrm; then
		echo 'actual postrm ignored a failed final release-directory cleanup' >&2
		exit 1
	fi
	[ -x "$RELEASE/helper" ] && [ -f "$RELEASE/complete" ] || {
		echo 'actual postrm destroyed retry authority before final local cleanup' >&2
		exit 1
	}
	umount "$RELEASE"
	run_postrm
	[ ! -e "$BARRIER" ] && [ ! -e "$RELEASE" ]
fi

if case_enabled postrm-dns-debris-retry; then
	prepare
	: > "$fixture/state/fail-dns-proof-remove"
	if run_postrm; then
		echo 'actual postrm ignored failed DNS proof debris deletion' >&2
		exit 1
	fi
	[ -f "$RELEASE.done" ] && [ ! -e "$RELEASE.cleanup/complete" ] &&
		[ -f "$RELEASE.cleanup/dns-ownership.json" ] || {
		echo 'actual postrm did not durably commit completion before debris cleanup' >&2
		exit 1
	}
	rm -f "$fixture/state/fail-dns-proof-remove"
	run_postrm
	[ ! -e "$BARRIER" ] && [ ! -e "$RELEASE" ] &&
		[ ! -e "$RELEASE.cleanup" ] && [ ! -e "$RELEASE.done" ]
fi

if case_enabled postrm-nft-only-retry; then
	prepare
	grep -v 'MICLASH_GUARD_FORWARD' "$fixture/state/iptables.filter" \
		> "$fixture/state/iptables.clean"
	mv "$fixture/state/iptables.clean" "$fixture/state/iptables.filter"
	/bin/mv "$fixture/bin/iptables-save" "$fixture/bin/iptables-save.off"
	/bin/mv "$fixture/bin/iptables-restore" "$fixture/bin/iptables-restore.off"
	mount --bind "$RELEASE" "$RELEASE"
	if run_postrm; then
		echo 'actual nft-only postrm ignored forced release-directory cleanup failure' >&2
		exit 1
	fi
	[ -x "$RELEASE/helper" ] || {
		echo 'actual nft-only postrm lost its no-tools retry helper' >&2
		exit 1
	}
	umount "$RELEASE"
	if ! run_postrm; then
		echo 'actual nft-only postrm retry required absent iptables binaries' >&2
		exit 1
	fi
	[ ! -e "$BARRIER" ] && [ ! -e "$RELEASE" ]
	/bin/mv "$fixture/bin/iptables-save.off" "$fixture/bin/iptables-save"
	/bin/mv "$fixture/bin/iptables-restore.off" "$fixture/bin/iptables-restore"
fi

if case_enabled postrm-core-retry; then
	prepare
	mkdir -p /opt/clash/bin
	printf 'core\n' > /opt/clash/bin/clash
	mount --bind /opt/clash/bin/clash /opt/clash/bin/clash
	if run_postrm; then
		echo 'actual postrm ignored a failed final core unlink' >&2
		exit 1
	fi
	[ -f "$RELEASE.done" ] || {
		echo 'actual postrm consumed the final retry proof before core removal' >&2
		exit 1
	}
	umount /opt/clash/bin/clash
	run_postrm
	[ ! -e "$RELEASE.done" ] && [ ! -e "$RELEASE" ] && [ ! -e "$BARRIER" ]
fi

for failure in fail-nft-inventory fail-nft-delete fail-nft-partial fail-nft-verify \
	fail-iptables-inventory fail-iptables-apply fail-iptables-verify; do
	prepare
	: > "$fixture/state/$failure"
	if "$RELEASE/helper" "$RELEASE"; then
		echo "release helper unexpectedly ignored Guard finalization fault: $failure" >&2
		exit 1
	fi
	proof_retained
	[ -d "$BARRIER" ]
	rm -f "$fixture/state/$failure"
	"$RELEASE/helper" "$RELEASE"
	[ ! -e "$BARRIER" ]
	! guard_present
done

printf 'retryable package release gate passed\n'
