#!/bin/sh

# Shared MiClash cross-process mutation lock. This file is sourced by package
# writers; it intentionally has no user-facing command dispatcher.

MICLASH_MUTATION_LOCK_ROOT=/var/run/miclash
MICLASH_MUTATION_LOCK_DIR=$MICLASH_MUTATION_LOCK_ROOT/mutation.lock
MICLASH_MUTATION_LOCK_TAKEOVER=$MICLASH_MUTATION_LOCK_ROOT/mutation.lock.takeover
MICLASH_MUTATION_LOCK_BARRIER=$MICLASH_MUTATION_LOCK_ROOT/package-removal
MICLASH_MUTATION_LOCK_GRACE=5
: "${MICLASH_MUTATION_LOCK_TOKEN:=}"
MICLASH_MUTATION_LOCK_KIND=
MICLASH_MUTATION_LOCK_RECORD=
MICLASH_MUTATION_LOCK_PARTICIPANT=
MICLASH_MUTATION_LOCK_DEPTH=0

miclash_mutation_lock_busy() {
	echo "MiClash mutation lock busy" >&2
	return 75
}

miclash_mutation_lock_boot() {
	boot="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)" || return 1
	case "$boot" in
		????????-????-????-????-????????????) printf '%s' "$boot" ;;
		*) return 1 ;;
	esac
}

miclash_mutation_lock_start() {
	pid="$1"
	case "$pid" in ''|*[!0-9]*|0) return 1 ;; esac
	stat_line="$(cat "/proc/$pid/stat" 2>/dev/null)" || return 1
	case "$stat_line" in "$pid ("*") "*) ;; *) return 1 ;; esac
	rest="${stat_line##*) }"
	set -- $rest
	[ "$#" -ge 20 ] || return 1
	i=1
	while [ "$i" -lt 20 ]; do shift; i=$((i + 1)); done
	case "$1" in ''|*[!0-9]*) return 1 ;; esac
	printf '%s' "$1"
}

miclash_mutation_lock_nonce() {
	nonce="$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')" || return 1
	case "$nonce" in
		*[!0-9a-f]*|'') return 1 ;;
	esac
	[ "${#nonce}" -eq 32 ] || return 1
	printf '%s' "$nonce"
}

miclash_mutation_lock_identity_live() {
	identity_boot="$1"
	identity_pid="$2"
	identity_start="$3"
	[ "$(miclash_mutation_lock_boot)" = "$identity_boot" ] || return 1
	[ "$(miclash_mutation_lock_start "$identity_pid")" = "$identity_start" ]
}

miclash_mutation_lock_secure_dir() {
	path="$1"
	[ ! -L "$path" ] && [ -d "$path" ] || return 1
	owner_mode="$(stat -c '%u:%a' "$path" 2>/dev/null)" || return 1
	case "$owner_mode" in 0:700) ;; *) return 1 ;; esac
}

miclash_mutation_lock_secure_root() {
	if [ ! -e "$MICLASH_MUTATION_LOCK_ROOT" ] && [ ! -L "$MICLASH_MUTATION_LOCK_ROOT" ]; then
		(umask 077; mkdir "$MICLASH_MUTATION_LOCK_ROOT") 2>/dev/null || true
		chown 0:0 "$MICLASH_MUTATION_LOCK_ROOT" 2>/dev/null || return 1
		chmod 0700 "$MICLASH_MUTATION_LOCK_ROOT" || return 1
	fi
	miclash_mutation_lock_secure_dir "$MICLASH_MUTATION_LOCK_ROOT" || return 1
	canonical="$(readlink -f "$MICLASH_MUTATION_LOCK_ROOT" 2>/dev/null)" || return 1
	case "$canonical" in
		/var/run/miclash|/run/miclash|/tmp/run/miclash) return 0 ;;
		*) return 1 ;;
	esac
}

miclash_mutation_lock_read_owner() {
	directory="$1"
	file="$directory/owner"
	[ ! -L "$file" ] && [ -f "$file" ] || return 1
	[ "$(stat -c '%u:%a:%h' "$file" 2>/dev/null)" = '0:600:1' ] || return 1
	size="$(stat -c '%s' "$file" 2>/dev/null)" || return 1
	case "$size" in ''|*[!0-9]*) return 1 ;; esac
	[ "$size" -gt 0 ] && [ "$size" -le 768 ] || return 1
	[ "$(wc -l < "$file" 2>/dev/null)" -eq 5 ] || return 1
	[ "$(sed -n '1p' "$file")" = 'version=1' ] || return 1
	record_boot="$(sed -n 's/^boot=//p' "$file")"
	record_pid="$(sed -n 's/^pid=//p' "$file")"
	record_start="$(sed -n 's/^start=//p' "$file")"
	record_nonce="$(sed -n 's/^nonce=//p' "$file")"
	case "$record_boot" in ????????-????-????-????-????????????) ;; *) return 1 ;; esac
	case "$record_pid:$record_start" in *[!0-9:]*|0:*|*:0|:*|*:) return 1 ;; esac
	case "$record_nonce" in *[!0-9a-f]*|'') return 1 ;; esac
	[ "${#record_nonce}" -eq 32 ] || return 1
	MICLASH_MUTATION_LOCK_RECORD_BOOT="$record_boot"
	MICLASH_MUTATION_LOCK_RECORD_PID="$record_pid"
	MICLASH_MUTATION_LOCK_RECORD_START="$record_start"
	MICLASH_MUTATION_LOCK_RECORD_NONCE="$record_nonce"
	MICLASH_MUTATION_LOCK_RECORD="$record_boot:$record_pid:$record_start:$record_nonce"
}

miclash_mutation_lock_read_participant() {
	file="$1"
	[ ! -L "$file" ] && [ -f "$file" ] || return 1
	[ "$(stat -c '%u:%a:%h' "$file" 2>/dev/null)" = '0:600:1' ] || return 1
	size="$(stat -c '%s' "$file" 2>/dev/null)" || return 1
	case "$size" in ''|*[!0-9]*) return 1 ;; esac
	[ "$size" -gt 0 ] && [ "$size" -le 768 ] || return 1
	[ "$(wc -l < "$file" 2>/dev/null)" -eq 6 ] || return 1
	[ "$(sed -n '1p' "$file")" = 'version=1' ] || return 1
	record_owner="$(sed -n 's/^owner=//p' "$file")"
	record_boot="$(sed -n 's/^boot=//p' "$file")"
	record_pid="$(sed -n 's/^pid=//p' "$file")"
	record_start="$(sed -n 's/^start=//p' "$file")"
	record_nonce="$(sed -n 's/^nonce=//p' "$file")"
	case "$record_boot" in ????????-????-????-????-????????????) ;; *) return 1 ;; esac
	case "$record_pid:$record_start" in *[!0-9:]*|0:*|*:0|:*|*:) return 1 ;; esac
	case "$record_nonce" in *[!0-9a-f]*|'') return 1 ;; esac
	[ "${#record_nonce}" -eq 32 ] || return 1
	case "$record_owner" in
		????????-????-????-????-????????????:[1-9]*:[1-9]*:[0-9a-f]*) ;;
		*) return 1 ;;
	esac
	MICLASH_MUTATION_LOCK_RECORD_OWNER="$record_owner"
	MICLASH_MUTATION_LOCK_RECORD_BOOT="$record_boot"
	MICLASH_MUTATION_LOCK_RECORD_PID="$record_pid"
	MICLASH_MUTATION_LOCK_RECORD_START="$record_start"
	MICLASH_MUTATION_LOCK_RECORD_NONCE="$record_nonce"
	MICLASH_MUTATION_LOCK_RECORD="$record_boot:$record_pid:$record_start:$record_nonce"
}

miclash_mutation_lock_participant_live() {
	directory="$1"
	owner_token="$2"
	participants="$directory/participants"
	miclash_mutation_lock_secure_dir "$participants" || return 0
	for file in "$participants"/*; do
		[ -e "$file" ] || continue
		miclash_mutation_lock_read_participant "$file" || return 0
		[ "$MICLASH_MUTATION_LOCK_RECORD_OWNER" = "$owner_token" ] || return 0
		if miclash_mutation_lock_identity_live "$MICLASH_MUTATION_LOCK_RECORD_BOOT" \
			"$MICLASH_MUTATION_LOCK_RECORD_PID" "$MICLASH_MUTATION_LOCK_RECORD_START"; then
			return 0
		fi
	done
	return 1
}

miclash_mutation_lock_stale() {
	directory="$1"
	miclash_mutation_lock_secure_dir "$directory" || return 1
	if ! miclash_mutation_lock_read_owner "$directory"; then
		modified="$(stat -c '%Y' "$directory" 2>/dev/null)" || return 1
		now="$(date +%s 2>/dev/null)" || return 1
		case "$modified:$now" in *[!0-9:]*|:*|*:) return 1 ;; esac
		[ $((now - modified)) -ge "$MICLASH_MUTATION_LOCK_GRACE" ]
		return
	fi
	owner_token="$MICLASH_MUTATION_LOCK_RECORD"
	if miclash_mutation_lock_identity_live "$MICLASH_MUTATION_LOCK_RECORD_BOOT" \
		"$MICLASH_MUTATION_LOCK_RECORD_PID" "$MICLASH_MUTATION_LOCK_RECORD_START"; then
		return 1
	fi
	! miclash_mutation_lock_participant_live "$directory" "$owner_token"
}

miclash_mutation_lock_remove_stale() {
	directory="$1"
	miclash_mutation_lock_stale "$directory" || return 1
	owner_token=
	miclash_mutation_lock_read_owner "$directory" && owner_token="$MICLASH_MUTATION_LOCK_RECORD"
	participants="$directory/participants"
	miclash_mutation_lock_secure_dir "$participants" || return 1
	for file in "$participants"/*; do
		[ -e "$file" ] || continue
		miclash_mutation_lock_read_participant "$file" || return 1
		[ -z "$owner_token" ] || [ "$MICLASH_MUTATION_LOCK_RECORD_OWNER" = "$owner_token" ] || return 1
		! miclash_mutation_lock_identity_live "$MICLASH_MUTATION_LOCK_RECORD_BOOT" \
			"$MICLASH_MUTATION_LOCK_RECORD_PID" "$MICLASH_MUTATION_LOCK_RECORD_START" || return 1
		rm -f "$file" || return 1
	done
	rmdir "$participants" || return 1
	[ ! -e "$directory/owner" ] || rm -f "$directory/owner" || return 1
	rmdir "$directory"
}

miclash_mutation_lock_settle_takeover() {
	[ -e "$MICLASH_MUTATION_LOCK_TAKEOVER" ] || [ -L "$MICLASH_MUTATION_LOCK_TAKEOVER" ] || return 0
	if miclash_mutation_lock_stale "$MICLASH_MUTATION_LOCK_TAKEOVER"; then
		miclash_mutation_lock_remove_stale "$MICLASH_MUTATION_LOCK_TAKEOVER" || return 1
		return 0
	fi
	if [ ! -e "$MICLASH_MUTATION_LOCK_DIR" ] && [ ! -L "$MICLASH_MUTATION_LOCK_DIR" ]; then
		mv "$MICLASH_MUTATION_LOCK_TAKEOVER" "$MICLASH_MUTATION_LOCK_DIR" 2>/dev/null || return 1
	fi
	return 1
}

miclash_mutation_lock_takeover() {
	miclash_mutation_lock_stale "$MICLASH_MUTATION_LOCK_DIR" || return 1
	[ ! -e "$MICLASH_MUTATION_LOCK_TAKEOVER" ] && [ ! -L "$MICLASH_MUTATION_LOCK_TAKEOVER" ] || return 1
	mv "$MICLASH_MUTATION_LOCK_DIR" "$MICLASH_MUTATION_LOCK_TAKEOVER" 2>/dev/null || return 1
	# Revalidate after the atomic rename; contenders treat TAKEOVER as busy.
	if ! miclash_mutation_lock_stale "$MICLASH_MUTATION_LOCK_TAKEOVER"; then
		if [ ! -e "$MICLASH_MUTATION_LOCK_DIR" ] && [ ! -L "$MICLASH_MUTATION_LOCK_DIR" ]; then
			mv "$MICLASH_MUTATION_LOCK_TAKEOVER" "$MICLASH_MUTATION_LOCK_DIR" 2>/dev/null || true
		fi
		return 1
	fi
	miclash_mutation_lock_remove_stale "$MICLASH_MUTATION_LOCK_TAKEOVER"
}

miclash_mutation_lock_write_owner() {
	directory="$1"
	boot="$2"
	pid="$3"
	started="$4"
	nonce="$5"
	temp="$directory/owner.tmp.$pid.$nonce"
	(
		umask 077
		set -C
		printf 'version=1\nboot=%s\npid=%s\nstart=%s\nnonce=%s\n' \
			"$boot" "$pid" "$started" "$nonce" > "$temp"
	) 2>/dev/null || return 1
	chown 0:0 "$temp" 2>/dev/null || return 1
	chmod 0600 "$temp" || return 1
	mv "$temp" "$directory/owner" || return 1
}

miclash_mutation_lock_create_owner() {
	mkdir "$MICLASH_MUTATION_LOCK_DIR" 2>/dev/null || return 1
	chown 0:0 "$MICLASH_MUTATION_LOCK_DIR" 2>/dev/null || return 1
	chmod 0700 "$MICLASH_MUTATION_LOCK_DIR" || return 1
	# A stale-recovery rename may have opened this pathname after our first
	# sentinel check. Never publish a second owner beside TAKEOVER.
	if [ -e "$MICLASH_MUTATION_LOCK_TAKEOVER" ] || [ -L "$MICLASH_MUTATION_LOCK_TAKEOVER" ]; then
		rmdir "$MICLASH_MUTATION_LOCK_DIR" 2>/dev/null || true
		return 1
	fi
	mkdir "$MICLASH_MUTATION_LOCK_DIR/participants" || return 1
	chown 0:0 "$MICLASH_MUTATION_LOCK_DIR/participants" 2>/dev/null || return 1
	chmod 0700 "$MICLASH_MUTATION_LOCK_DIR/participants" || return 1
	boot="$(miclash_mutation_lock_boot)" || return 1
	started="$(miclash_mutation_lock_start "$$")" || return 1
	nonce="$(miclash_mutation_lock_nonce)" || return 1
	miclash_mutation_lock_write_owner "$MICLASH_MUTATION_LOCK_DIR" "$boot" "$$" "$started" "$nonce" || return 1
	miclash_mutation_lock_read_owner "$MICLASH_MUTATION_LOCK_DIR" || return 1
	[ "$MICLASH_MUTATION_LOCK_RECORD" = "$boot:$$:$started:$nonce" ] || return 1
	MICLASH_MUTATION_LOCK_KIND=owner
	MICLASH_MUTATION_LOCK_TOKEN="$MICLASH_MUTATION_LOCK_RECORD"
	export MICLASH_MUTATION_LOCK_TOKEN
	return 0
}

miclash_mutation_lock_join() {
	inherited="$MICLASH_MUTATION_LOCK_TOKEN"
	miclash_mutation_lock_read_owner "$MICLASH_MUTATION_LOCK_DIR" || return 1
	[ "$MICLASH_MUTATION_LOCK_RECORD" = "$inherited" ] || return 1
	miclash_mutation_lock_identity_live "$MICLASH_MUTATION_LOCK_RECORD_BOOT" \
		"$MICLASH_MUTATION_LOCK_RECORD_PID" "$MICLASH_MUTATION_LOCK_RECORD_START" || return 1
	boot="$(miclash_mutation_lock_boot)" || return 1
	started="$(miclash_mutation_lock_start "$$")" || return 1
	nonce="$(miclash_mutation_lock_nonce)" || return 1
	participant="$MICLASH_MUTATION_LOCK_DIR/participants/$$.$started.$nonce"
	(
		umask 077
		set -C
		printf 'version=1\nowner=%s\nboot=%s\npid=%s\nstart=%s\nnonce=%s\n' \
			"$inherited" "$boot" "$$" "$started" "$nonce" > "$participant"
	) 2>/dev/null || return 1
	chown 0:0 "$participant" 2>/dev/null || return 1
	chmod 0600 "$participant" || return 1
	miclash_mutation_lock_read_participant "$participant" || return 1
	[ "$MICLASH_MUTATION_LOCK_RECORD_OWNER" = "$inherited" ] || return 1
	MICLASH_MUTATION_LOCK_KIND=participant
	MICLASH_MUTATION_LOCK_PARTICIPANT="$participant"
	return 0
}

miclash_mutation_lock_barrier_allowed() {
	mode="$1"
	active=0
	if [ -e "$MICLASH_MUTATION_LOCK_BARRIER" ] || [ -L "$MICLASH_MUTATION_LOCK_BARRIER" ]; then active=1; fi
	case "$mode:$active" in normal:0|package:1) return 0 ;; *) return 1 ;; esac
}

miclash_mutation_lock_enter_internal() {
	mode="${1:-normal}"
	wait_ms="${2:-0}"
	authority="${3:-participant-only}"
	case "$mode" in normal|package) ;; *) return 2 ;; esac
	case "$wait_ms" in ''|*[!0-9]*) return 2 ;; esac
	case "$authority" in participant-only|package-owner-internal) ;; *) return 2 ;; esac
	[ "$authority" != package-owner-internal ] || {
		[ "$mode" = package ] && [ -z "${MICLASH_MUTATION_LOCK_TOKEN:-}" ] || return 2
	}
	miclash_mutation_lock_secure_root || return 1
	miclash_mutation_lock_barrier_allowed "$mode" || return 75
	if [ "$MICLASH_MUTATION_LOCK_DEPTH" -gt 0 ]; then
		miclash_mutation_lock_assert_held || return 75
		MICLASH_MUTATION_LOCK_DEPTH=$((MICLASH_MUTATION_LOCK_DEPTH + 1))
		return 0
	fi
	attempts=$(( (wait_ms + 49) / 50 + 1 ))
	while [ "$attempts" -gt 0 ]; do
		if miclash_mutation_lock_settle_takeover; then
			if [ -n "${MICLASH_MUTATION_LOCK_TOKEN:-}" ]; then
				miclash_mutation_lock_join && acquired=1 || acquired=0
			elif [ "$mode" = package ] && [ "$authority" != package-owner-internal ]; then
				acquired=0
			else
				miclash_mutation_lock_create_owner && acquired=1 || {
					miclash_mutation_lock_takeover >/dev/null 2>&1 || true
					miclash_mutation_lock_create_owner && acquired=1 || acquired=0
				}
			fi
		else
			acquired=0
		fi
		if [ "$acquired" = 1 ]; then
			# Publish logical ownership before the post-acquire barrier check so
			# exact release can roll back the physical owner/participant.
			MICLASH_MUTATION_LOCK_DEPTH=1
			if ! miclash_mutation_lock_barrier_allowed "$mode"; then
				miclash_mutation_lock_leave >/dev/null 2>&1 || return 1
				return 75
			fi
			[ "$mode" != package ] || { MICLASH_MUTATION_LOCK_PACKAGE=1; export MICLASH_MUTATION_LOCK_PACKAGE; }
			return 0
		fi
		attempts=$((attempts - 1))
		[ "$attempts" -le 0 ] || sleep 0.05
	done
	miclash_mutation_lock_busy
}

miclash_mutation_lock_enter() {
	miclash_mutation_lock_enter_internal "${1:-normal}" "${2:-0}" participant-only
}

miclash_mutation_lock_enter_package_owner() {
	miclash_mutation_lock_enter_internal package "${1:-0}" package-owner-internal
}

miclash_mutation_lock_assert_held() {
	case "$MICLASH_MUTATION_LOCK_KIND" in
		owner)
			miclash_mutation_lock_read_owner "$MICLASH_MUTATION_LOCK_DIR" || return 1
			[ "$MICLASH_MUTATION_LOCK_RECORD" = "$MICLASH_MUTATION_LOCK_TOKEN" ] || return 1
			miclash_mutation_lock_identity_live "$MICLASH_MUTATION_LOCK_RECORD_BOOT" \
				"$MICLASH_MUTATION_LOCK_RECORD_PID" "$MICLASH_MUTATION_LOCK_RECORD_START"
			;;
		participant)
			miclash_mutation_lock_read_participant "$MICLASH_MUTATION_LOCK_PARTICIPANT" || return 1
			[ "$MICLASH_MUTATION_LOCK_RECORD_OWNER" = "$MICLASH_MUTATION_LOCK_TOKEN" ] || return 1
			miclash_mutation_lock_identity_live "$MICLASH_MUTATION_LOCK_RECORD_BOOT" \
				"$MICLASH_MUTATION_LOCK_RECORD_PID" "$MICLASH_MUTATION_LOCK_RECORD_START"
			;;
		*) return 1 ;;
	esac
}

miclash_mutation_lock_leave() {
	[ "$MICLASH_MUTATION_LOCK_DEPTH" -gt 0 ] || return 1
	if [ "$MICLASH_MUTATION_LOCK_DEPTH" -gt 1 ]; then
		MICLASH_MUTATION_LOCK_DEPTH=$((MICLASH_MUTATION_LOCK_DEPTH - 1))
		return 0
	fi
	miclash_mutation_lock_assert_held || return 1
	case "$MICLASH_MUTATION_LOCK_KIND" in
		participant)
			rm -f "$MICLASH_MUTATION_LOCK_PARTICIPANT" || return 1
			;;
		owner)
			[ -d "$MICLASH_MUTATION_LOCK_DIR/participants" ] || return 1
			set -- "$MICLASH_MUTATION_LOCK_DIR/participants"/*
			[ "$1" = "$MICLASH_MUTATION_LOCK_DIR/participants/*" ] || return 1
			rmdir "$MICLASH_MUTATION_LOCK_DIR/participants" || return 1
			rm -f "$MICLASH_MUTATION_LOCK_DIR/owner" || return 1
			rmdir "$MICLASH_MUTATION_LOCK_DIR" || return 1
			;;
		*) return 1 ;;
	esac
	MICLASH_MUTATION_LOCK_DEPTH=0
	MICLASH_MUTATION_LOCK_KIND=
	MICLASH_MUTATION_LOCK_PARTICIPANT=
	MICLASH_MUTATION_LOCK_TOKEN=
	MICLASH_MUTATION_LOCK_PACKAGE=
	unset MICLASH_MUTATION_LOCK_TOKEN MICLASH_MUTATION_LOCK_PACKAGE
	return 0
}
