#!/bin/sh

set -eu

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
helper="$repo_root/luci-app-miclash/rootfs/usr/share/miclash/mutation-lock.sh"

if [ "${MICLASH_MUTATION_LOCK_NS:-}" != 1 ]; then
	exec unshare --mount --fork env MICLASH_MUTATION_LOCK_NS=1 sh "$0"
fi

mount --make-rprivate /
mkdir -p /var/run/miclash
mount -t tmpfs -o mode=0700,size=1m miclash-mutation-lock /var/run/miclash
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT INT TERM

cat > "$work/owner" <<'EOF'
#!/bin/sh
set -eu
. "$1"
miclash_mutation_lock_enter normal 0
printf '%s\n' "$MICLASH_MUTATION_LOCK_TOKEN" > "$2/token"
while [ ! -e "$2/release" ]; do sleep 0.01; done
miclash_mutation_lock_leave
EOF
chmod 0700 "$work/owner"
"$work/owner" "$helper" "$work" &
owner=$!
for attempt in $(seq 1 200); do [ -s "$work/token" ] && break; sleep 0.01; done
[ -s "$work/token" ]

# Independent writers are excluded while an exact inherited capability may
# join as a participant. This is the process boundary used by native ucode
# helpers invoked from package and Guard owners.
set +e
(
	. "$helper"
	unset MICLASH_MUTATION_LOCK_TOKEN
	miclash_mutation_lock_enter normal 0
) >/dev/null 2>&1
contender=$?
set -e
[ "$contender" -ne 0 ]
(
	export MICLASH_MUTATION_LOCK_TOKEN="$(cat "$work/token")"
	. "$helper"
	miclash_mutation_lock_enter normal 0
	[ "$MICLASH_MUTATION_LOCK_KIND" = participant ]
	miclash_mutation_lock_assert_held
	miclash_mutation_lock_leave
)
touch "$work/release"
wait "$owner"
[ ! -e /var/run/miclash/mutation.lock ]

# The removal barrier rejects a normal writer and can only be entered through
# the private package-owner primitive; its exact child token remains join-only.
mkdir /var/run/miclash/package-removal
chmod 0700 /var/run/miclash/package-removal
set +e
(
	. "$helper"
	miclash_mutation_lock_enter normal 0
) >/dev/null 2>&1
barrier=$?
set -e
[ "$barrier" -ne 0 ]
(
	. "$helper"
	miclash_mutation_lock_enter_package_owner 0
	package_token="$MICLASH_MUTATION_LOCK_TOKEN"
	(
		export MICLASH_MUTATION_LOCK_TOKEN="$package_token"
		export MICLASH_MUTATION_LOCK_PACKAGE=1
		. "$helper"
		miclash_mutation_lock_enter package 0
		[ "$MICLASH_MUTATION_LOCK_KIND" = participant ]
		miclash_mutation_lock_leave
	)
	miclash_mutation_lock_assert_held
	miclash_mutation_lock_leave
)
rmdir /var/run/miclash/package-removal
[ ! -e /var/run/miclash/mutation.lock ]

printf 'Native mutation lock process gate passed\n'
