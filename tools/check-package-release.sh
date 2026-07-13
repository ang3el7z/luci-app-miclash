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

prepare() {
	rm -rf "$BARRIER" "$RELEASE"
	mkdir "$BARRIER" "$RELEASE"
	chmod 0700 "$BARRIER" "$RELEASE"
	printf 'complete\n' > "$BARRIER/complete"
	printf 'complete\n' > "$RELEASE/complete"
	cp "$helper" "$RELEASE/helper"
	chmod 0600 "$BARRIER/complete" "$RELEASE/complete"
	chmod 0700 "$RELEASE/helper"
}

prepare
: > "$BARRIER/unexpected"
if "$RELEASE/helper" "$RELEASE"; then
	echo 'release helper ignored unexpected barrier debris' >&2
	exit 1
fi
[ -f "$BARRIER/complete" ]
[ -f "$RELEASE/complete" ]
[ -x "$RELEASE/helper" ]
rm -f "$BARRIER/unexpected"
"$RELEASE/helper" "$RELEASE"
[ ! -e "$BARRIER" ]
[ -f "$RELEASE/complete" ]
[ -x "$RELEASE/helper" ]

prepare
mount --bind "$BARRIER" "$BARRIER"
if "$RELEASE/helper" "$RELEASE"; then
	echo 'release helper ignored a failed barrier rmdir' >&2
	exit 1
fi
[ -f "$BARRIER/complete" ]
[ -f "$RELEASE/complete" ]
[ -x "$RELEASE/helper" ]
umount "$BARRIER"
"$RELEASE/helper" "$RELEASE"
[ ! -e "$BARRIER" ]

printf 'retryable package release gate passed\n'
