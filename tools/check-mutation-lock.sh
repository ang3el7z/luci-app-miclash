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
cleanup() {
	[ -z "${owner_pid:-}" ] || kill -KILL "$owner_pid" 2>/dev/null || true
	[ -z "${child_pid:-}" ] || kill -KILL "$child_pid" 2>/dev/null || true
	[ -z "${race_a:-}" ] || kill -KILL "$race_a" 2>/dev/null || true
	[ -z "${race_b:-}" ] || kill -KILL "$race_b" 2>/dev/null || true
	rm -rf "$work"
}
trap cleanup EXIT INT TERM

cat > "$work/owner.sh" <<'OWNER'
#!/bin/sh
set -eu
. "$1"
miclash_mutation_lock_enter normal 0
printf '%s\n' "$MICLASH_MUTATION_LOCK_TOKEN" > "$2/owner.ready"
while [ ! -e "$2/release" ]; do sleep 0.02; done
miclash_mutation_lock_leave
OWNER
chmod 0700 "$work/owner.sh"

"$work/owner.sh" "$helper" "$work" &
owner_pid=$!
i=0
while [ ! -s "$work/owner.ready" ] && [ "$i" -lt 100 ]; do
	sleep 0.02
	i=$((i + 1))
done
[ -s "$work/owner.ready" ]

set +e
(
	. "$helper"
	miclash_mutation_lock_enter normal 0
) >"$work/contender.out" 2>"$work/contender.err"
contender_code=$?
set -e
[ "$contender_code" -ne 0 ]
[ -d /var/run/miclash/mutation.lock ]

touch "$work/release"
wait "$owner_pid"
owner_pid=""
[ ! -e /var/run/miclash/mutation.lock ]

cat > "$work/participant.sh" <<'PARTICIPANT'
#!/bin/sh
set -eu
. "$1"
miclash_mutation_lock_enter normal 0
printf '%s\n' "$$" > "$2/participant.ready"
while [ ! -e "$2/participant.release" ]; do sleep 0.02; done
miclash_mutation_lock_leave
PARTICIPANT
chmod 0700 "$work/participant.sh"

cat > "$work/owner-with-child.sh" <<'OWNER_CHILD'
#!/bin/sh
set -eu
. "$1"
miclash_mutation_lock_enter normal 0
"$2/participant.sh" "$1" "$2" &
child=$!
printf '%s\n' "$child" > "$2/child.pid"
while [ ! -s "$2/participant.ready" ]; do sleep 0.02; done
printf '%s\n' "$$" > "$2/owner-child.ready"
wait "$child"
miclash_mutation_lock_leave
OWNER_CHILD
chmod 0700 "$work/owner-with-child.sh"

"$work/owner-with-child.sh" "$helper" "$work" &
owner_pid=$!
i=0
while [ ! -s "$work/owner-child.ready" ] && [ "$i" -lt 100 ]; do
	sleep 0.02
	i=$((i + 1))
done
[ -s "$work/owner-child.ready" ]
child_pid="$(cat "$work/child.pid")"
kill -KILL "$owner_pid"
wait "$owner_pid" 2>/dev/null || true
owner_pid=""

set +e
(
	. "$helper"
	miclash_mutation_lock_enter normal 0
) >/dev/null 2>&1
participant_contender=$?
set -e
[ "$participant_contender" -ne 0 ]
[ -d /var/run/miclash/mutation.lock ]
touch "$work/participant.release"
i=0
while find /var/run/miclash/mutation.lock/participants -type f 2>/dev/null | grep -q . && \
	[ "$i" -lt 100 ]; do
	sleep 0.02
	i=$((i + 1))
done
[ -z "$(find /var/run/miclash/mutation.lock/participants -type f 2>/dev/null)" ]
child_pid=""
(
	. "$helper"
	miclash_mutation_lock_enter normal 0
	miclash_mutation_lock_leave
)
[ ! -e /var/run/miclash/mutation.lock ]
[ ! -e /var/run/miclash/mutation.lock.takeover ]

# An incomplete owner is busy during the initialization grace, then recoverable
# only after it is demonstrably old.
mkdir /var/run/miclash/mutation.lock
chmod 0700 /var/run/miclash/mutation.lock
mkdir /var/run/miclash/mutation.lock/participants
chmod 0700 /var/run/miclash/mutation.lock/participants
set +e
(
	. "$helper"
	miclash_mutation_lock_enter normal 0
) >/dev/null 2>&1
grace_code=$?
set -e
[ "$grace_code" -ne 0 ]
touch -t 197001010000.00 /var/run/miclash/mutation.lock
(
	. "$helper"
	miclash_mutation_lock_enter normal 0
	miclash_mutation_lock_leave
)
[ ! -e /var/run/miclash/mutation.lock ]

# A live PID with a different /proc start time is stale (PID reuse defense).
(
	. "$helper"
	boot="$(miclash_mutation_lock_boot)"
	started="$(miclash_mutation_lock_start "$$")"
	wrong_started=$((started + 1))
	mkdir /var/run/miclash/mutation.lock
	chmod 0700 /var/run/miclash/mutation.lock
	mkdir /var/run/miclash/mutation.lock/participants
	chmod 0700 /var/run/miclash/mutation.lock/participants
	printf 'version=1\nboot=%s\npid=%s\nstart=%s\nnonce=%s\n' \
		"$boot" "$$" "$wrong_started" 00000000000000000000000000000001 \
		> /var/run/miclash/mutation.lock/owner
	chmod 0600 /var/run/miclash/mutation.lock/owner
	miclash_mutation_lock_enter normal 0
	miclash_mutation_lock_leave
)
[ ! -e /var/run/miclash/mutation.lock ]

cat > "$work/racer.sh" <<'RACER'
#!/bin/sh
set -eu
. "$1"
while [ ! -e "$2/start" ]; do sleep 0.005; done
if miclash_mutation_lock_enter normal 0 >/dev/null 2>&1; then
	printf '%s\n' "$$" > "$2/winner.$$"
	while [ ! -e "$2/release" ]; do sleep 0.005; done
	miclash_mutation_lock_leave
else
	printf '%s\n' "$$" > "$2/loser.$$"
fi
RACER
chmod 0700 "$work/racer.sh"

iteration=1
while [ "$iteration" -le 20 ]; do
	round="$work/round.$iteration"
	mkdir "$round"
	"$work/racer.sh" "$helper" "$round" & race_a=$!
	"$work/racer.sh" "$helper" "$round" & race_b=$!
	touch "$round/start"
	i=0
	while [ "$(find "$round" -name 'winner.*' | wc -l)" -lt 1 ] && [ "$i" -lt 200 ]; do
		sleep 0.005
		i=$((i + 1))
	done
	[ "$(find "$round" -name 'winner.*' | wc -l)" -eq 1 ]
	touch "$round/release"
	wait "$race_a"
	wait "$race_b"
	race_a=""
	race_b=""
	[ "$(find "$round" -name 'winner.*' | wc -l)" -eq 1 ]
	[ "$(find "$round" -name 'loser.*' | wc -l)" -eq 1 ]
	[ ! -e /var/run/miclash/mutation.lock ]
	[ ! -e /var/run/miclash/mutation.lock.takeover ]
	iteration=$((iteration + 1))
done

printf 'shared mutation lock process gate passed (20 race iterations)\n'
