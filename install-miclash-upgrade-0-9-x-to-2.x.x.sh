#!/bin/sh

# One-time clean reinstall from MiClash v0.9.x to an exact MiClash v2 release.
# Only user-visible settings, subscription URLs and config profiles cross the
# boundary. The Mihomo binary and provider/runtime caches are installed fresh.
set -eu

TAG=''
WORK=''
BACKUP=''
GUARD_ENABLED=0
OLD_ENABLED=0
OLD_RUNNING=0
PKG_MGR=''
UPGRADE_STATE='fresh'

say() { printf '%s\n' "$*"; }
die() { printf 'MiClash clean upgrade failed: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "required command is missing: $1"; }

installed_miclash_version() {
	case "$1" in
		apk)
			apk list -I 2>/dev/null | awk '
				$1 ~ /^luci-app-miclash-[0-9]/ {
					sub(/^luci-app-miclash-/, "", $1)
					print $1
					exit
				}'
			;;
		opkg)
			opkg list-installed luci-app-miclash 2>/dev/null |
				awk 'NR == 1 { print $3 }'
			;;
		*) return 64 ;;
	esac
}

backup_value() {
	awk -F= -v key="$2" '
		$1 == key { value = substr($0, length(key) + 2); count++ }
		END { if (count == 1) print value; else exit 1 }
	' "$1/upgrade-info" 2>/dev/null
}

legacy_value() {
	awk -F= -v key="$2" '
		$1 == key { value = substr($0, length(key) + 2); found = 1 }
		END { if (found) print value; else exit 1 }
	' "$1/settings.v09" 2>/dev/null
}

legacy_bool() {
	value="$(legacy_value "$1" "$2" || true)"
	case "$value" in
		true|1|yes|on) printf '1\n' ;;
		false|0|no|off) printf '0\n' ;;
		*) return 1 ;;
	esac
}

uci_set() {
	uci -q set "miclash.$1.$2=$3" || die "cannot restore MiClash setting $1.$2"
}

restore_bool() {
	value="$(legacy_bool "$BACKUP" "$1" || true)"
	[ -n "$value" ] || return 0
	uci_set "$2" "$3" "$value"
}

restore_enum() {
	value="$(legacy_value "$BACKUP" "$1" || true)"
	case ":$4:" in *:"$value":*) uci_set "$2" "$3" "$value" ;; esac
}

restore_text() {
	value="$(legacy_value "$BACKUP" "$1" || true)"
	[ -n "$value" ] || return 0
	[ "${#value}" -le 4096 ] || return 0
	printf '%s' "$value" | grep -q '[[:cntrl:]]' && return 0
	uci_set "$2" "$3" "$value"
}

restore_interface() {
	value="$(legacy_value "$BACKUP" "$1" || true)"
	[ -z "$value" ] || printf '%s\n' "$value" | grep -Eq '^[A-Za-z0-9_.:-]+$' || return 0
	uci_set interfaces "$2" "$value"
}

restore_interfaces() {
	value="$(legacy_value "$BACKUP" "$1" || true)"
	[ -z "$value" ] || printf '%s\n' "$value" | grep -Eq '^[A-Za-z0-9_.:,-]+$' || return 0
	uci_set interfaces "$2" "$value"
}

restore_url() {
	value="$(legacy_value "$BACKUP" "$1" || true)"
	[ -n "$value" ] || return 0
	printf '%s\n' "$value" | grep -Eq '^https?://[^[:space:]]+$' || return 0
	uci_set core "$2" "$value"
}

restore_legacy_user_data() {
	restore_enum INTERFACE_MODE interfaces mode 'exclude:explicit'
	restore_enum PROXY_MODE core proxy_mode 'tproxy:tun:mixed'
	restore_enum TUN_STACK core tun_stack 'system:gvisor:mixed'
	restore_bool AUTO_DETECT_LAN interfaces auto_detect_lan
	restore_bool AUTO_DETECT_WAN interfaces auto_detect_wan
	restore_bool BLOCK_QUIC core block_quic
	restore_bool USE_TMPFS_RULES core use_tmpfs_rules
	restore_bool ENABLE_HWID core hwid_enabled
	restore_text HWID_USER_AGENT core hwid_user_agent
	restore_text HWID_DEVICE_OS core hwid_device_os
	restore_interface DETECTED_LAN detected_lan
	restore_interface DETECTED_WAN detected_wan
	restore_interfaces INCLUDED_INTERFACES included
	restore_interfaces EXCLUDED_INTERFACES excluded
	restore_bool AUTO_FAKEIP_WHITELIST guard auto_fakeip_whitelist
	restore_bool ENABLE_MEMORY_GUARD memory enabled
	restore_bool AUTO_HIDE_NOTIFICATIONS notifications auto_hide
	restore_bool AUTO_UPDATE_CONFIG updates auto_subscription
	restore_enum MICLASH_RELEASE_CHANNEL updates miclash_release_channel 'release:prerelease'
	restore_enum MIHOMO_RELEASE_CHANNEL updates mihomo_release_channel 'release:prerelease'

	interval="$(legacy_value "$BACKUP" AUTO_UPDATE_INTERVAL_HOURS || true)"
	if printf '%s\n' "$interval" | grep -Eq '^[1-9][0-9]{0,3}$' &&
		[ "$interval" -le 8760 ]; then
		uci_set updates interval_hours "$interval"
	fi

	restore_url SUBSCRIPTION_URL subscription_url
	restore_url SUBSCRIPTION_URL_CONFIG_YAML subscription_url_config_yaml
	restore_url SUBSCRIPTION_URL_CONFIG2_YAML subscription_url_config2_yaml
	restore_url SUBSCRIPTION_URL_CONFIG3_YAML subscription_url_config3_yaml
	main_url="$(legacy_value "$BACKUP" SUBSCRIPTION_URL_CONFIG_YAML || true)"
	[ -n "$main_url" ] || main_url="$(legacy_value "$BACKUP" SUBSCRIPTION_URL || true)"
	if [ -n "$main_url" ] && printf '%s\n' "$main_url" | grep -Eq '^https?://[^[:space:]]+$'; then
		uci_set core subscription_url_config_yaml "$main_url"
	fi

	uci_set guard enabled "$GUARD_ENABLED"
	uci -q commit miclash || die 'cannot commit migrated MiClash settings'
}

find_resume_backup() {
	BACKUP=''
	for candidate in /root/miclash-v09-backup-*; do
		[ ! -L "$candidate" ] && [ -d "$candidate" ] || continue
		printf '%s\n' "${candidate##*/}" |
			grep -Eq '^miclash-v09-backup-[0-9]{8}-[0-9]{6}$' || continue
		[ ! -e "$candidate/upgrade-complete" ] && [ ! -L "$candidate/upgrade-complete" ] || continue
		[ ! -L "$candidate/upgrade-info" ] && [ -f "$candidate/upgrade-info" ] || continue
		[ ! -L "$candidate/settings.v09" ] && [ -f "$candidate/settings.v09" ] || continue
		version="$(backup_value "$candidate" old_version || true)"
		enabled="$(backup_value "$candidate" old_enabled || true)"
		running="$(backup_value "$candidate" old_running || true)"
		guard="$(backup_value "$candidate" guard_enabled || true)"
		release="$(backup_value "$candidate" release_tag || true)"
		case "$version" in 0.9.*) ;; *) continue ;; esac
		case "$enabled:$running:$guard" in
			[01]:[01]:[01]) ;;
			*) continue ;;
		esac
		printf '%s\n' "$release" | grep -Eq '^v2\.[0-9]+\.[0-9]+$' || continue
		BACKUP="$candidate"
	done
	[ -n "$BACKUP" ]
}

load_resume_backup() {
	OLD_VERSION="$(backup_value "$BACKUP" old_version)"
	OLD_ENABLED="$(backup_value "$BACKUP" old_enabled)"
	OLD_RUNNING="$(backup_value "$BACKUP" old_running)"
	GUARD_ENABLED="$(backup_value "$BACKUP" guard_enabled)"
	backup_value "$BACKUP" release_tag >/dev/null
}

ensure_stat_runtime() {
	command -v stat >/dev/null 2>&1 && return 0
	say 'Installing the OpenWrt stat compatibility dependency...'
	case "$PKG_MGR" in
		apk)
			apk update >/dev/null && apk add coreutils-stat >/dev/null ||
				die 'cannot install coreutils-stat on OpenWrt APK'
			;;
		opkg)
			opkg update >/dev/null && opkg install coreutils-stat >/dev/null ||
				die 'cannot install coreutils-stat on OpenWrt opkg'
			;;
	esac
	command -v stat >/dev/null 2>&1 || die 'stat is still unavailable after dependency installation'
}

remove_legacy_guard_rules() {
	if [ -x /opt/clash/bin/clash-rules ]; then
		/opt/clash/bin/clash-rules guard_stop >/dev/null 2>&1 || true
	fi
	if command -v nft >/dev/null 2>&1; then
		for guard_table in miclash_guard_bootstrap_v1 miclash_guard_emergency_v1 miclash_guard; do
			nft delete table inet "$guard_table" >/dev/null 2>&1 || true
		done
	fi
	for firewall_cmd in iptables ip6tables; do
		command -v "$firewall_cmd" >/dev/null 2>&1 || continue
		while "$firewall_cmd" -t filter -D FORWARD -j MICLASH_GUARD_FORWARD >/dev/null 2>&1; do :; done
		"$firewall_cmd" -t filter -F MICLASH_GUARD_FORWARD >/dev/null 2>&1 || true
		"$firewall_cmd" -t filter -X MICLASH_GUARD_FORWARD >/dev/null 2>&1 || true
		while "$firewall_cmd" -t filter -D OUTPUT -j MICLASH_GUARD_OUTPUT >/dev/null 2>&1; do :; done
		"$firewall_cmd" -t filter -F MICLASH_GUARD_OUTPUT >/dev/null 2>&1 || true
		"$firewall_cmd" -t filter -X MICLASH_GUARD_OUTPUT >/dev/null 2>&1 || true
	done
}

verify_legacy_guard_off() {
	if command -v nft >/dev/null 2>&1; then
		for guard_table in miclash_guard_bootstrap_v1 miclash_guard_emergency_v1 miclash_guard; do
			if nft list table inet "$guard_table" >/dev/null 2>&1; then
				return 1
			fi
		done
	fi
	for firewall_cmd in iptables ip6tables; do
		command -v "$firewall_cmd" >/dev/null 2>&1 || continue
		if "$firewall_cmd" -t filter -S 2>/dev/null | grep -Eq 'MICLASH_GUARD_(FORWARD|OUTPUT)'; then
			return 1
		fi
	done
}

disable_legacy_guard() {
	if [ -f /opt/clash/settings ]; then
		if grep -q '^INTERNET_ONLY_MICLASH=' /opt/clash/settings; then
			sed -i 's/^INTERNET_ONLY_MICLASH=.*/INTERNET_ONLY_MICLASH=false/' /opt/clash/settings ||
				die 'cannot disable Guard in legacy settings'
		else
			printf '%s\n' 'INTERNET_ONLY_MICLASH=false' >> /opt/clash/settings ||
				die 'cannot disable Guard in legacy settings'
		fi
	fi
	remove_legacy_guard_rules
	verify_legacy_guard_off || die 'legacy Guard rules are still active; refusing to remove MiClash'
	say 'Legacy Guard disabled for the clean replacement.'
}

remove_incomplete_v2() {
	say 'Cleaning the interrupted MiClash v2 installation...'
	for service in miclashd clash; do
		if command -v ubus >/dev/null 2>&1; then
			ubus call service delete "{ \"name\": \"$service\" }" >/dev/null 2>&1 || true
		fi
		[ ! -x "/etc/init.d/$service" ] || "/etc/init.d/$service" disable >/dev/null 2>&1 || true
	done

	partial_version="$(installed_miclash_version "$PKG_MGR")"
	if [ -n "$partial_version" ]; then
		case "$PKG_MGR" in
			apk)
				apk --no-scripts del luci-app-miclash || true
				;;
			opkg)
				opkg --force-remove remove luci-app-miclash || true
				;;
		esac
		[ -z "$(installed_miclash_version "$PKG_MGR")" ] ||
			die "cannot remove incomplete MiClash v2 package $partial_version"
	fi
	if [ "$PKG_MGR" = apk ]; then
		# Skipping package scripts also skips alternative restoration for v2-only
		# dependencies. Reinstall them immediately after the broken package is gone.
		apk add coreutils-timeout ip-full ucode-mod-socket >/dev/null ||
			die 'cannot restore APK runtime dependencies after clean retry removal'
	fi

	remove_legacy_guard_rules
	verify_legacy_guard_off || die 'interrupted v2 Guard rules are still active'
	rm -rf /var/run/miclash /tmp/miclash
	rm -f /tmp/miclash-hard-reinstall
	say 'Interrupted MiClash v2 state removed; the backup remains intact.'
}

usage() {
	cat <<'EOF'
Usage: install-miclash-upgrade-0-9-x-to-2.x.x.sh [--release-tag v2.X.Y]

Performs a clean reinstall from an installed MiClash v0.9.x to the exact v2
release. Existing config profiles, subscription URLs and compatible UI
settings are retained. Mihomo and provider/runtime caches are installed fresh.

There is no automatic rollback. The previous Guard and service enabled/running
state are restored after the v2 package and user files are installed. If an
earlier attempt stopped after creating its backup, run the same command again.
EOF
}

cleanup_work() {
	[ -n "$WORK" ] || return 0
	rm -f "$WORK/install-miclash.sh" "$WORK/install-miclash.sh.sha256" \
		"$WORK/miclash-release-manifest.json" "$WORK/releases.json" 2>/dev/null || true
	rmdir "$WORK" 2>/dev/null || true
}

signal_exit() {
	trap - EXIT INT TERM HUP
	cleanup_work
	exit "$1"
}

trap cleanup_work EXIT
trap 'signal_exit 130' INT
trap 'signal_exit 143' TERM
trap 'signal_exit 129' HUP

while [ "$#" -gt 0 ]; do
	case "$1" in
		--release-tag)
			[ "$#" -gt 1 ] || { usage >&2; exit 64; }
			TAG="$2"
			shift 2
			;;
		--help|-h) usage; exit 0 ;;
		*) usage >&2; exit 64 ;;
	esac
done

if [ -n "$TAG" ]; then
	printf '%s\n' "$TAG" | grep -Eq '^v2\.[0-9]+\.[0-9]+$' ||
		die 'release tag must be a stable v2 tag'
fi
[ "$(id -u)" = 0 ] || die 'root is required'

for command in curl sha256sum jsonfilter sed awk grep cp rm mkdir chmod date id mktemp rmdir; do need "$command"; done

supported_openwrt_release() {
	release="$1"
	[ "$release" = SNAPSHOT ] && return 0
	printf '%s\n' "$release" | grep -Eq '^[0-9]+(\.[0-9]+)*(-rc[0-9]+)?$' || return 1
	release_major="${release%%.*}"
	release_minor=''
	case "$release" in
		*.*)
			release_minor="${release#*.}"
			release_minor="${release_minor%%.*}"
			release_minor="${release_minor%%-*}"
			;;
	esac
	[ "$release_major" -gt 24 ] 2>/dev/null && return 0
	[ "$release_major" -eq 24 ] 2>/dev/null &&
		[ -n "$release_minor" ] &&
		[ "$release_minor" -ge 10 ] 2>/dev/null
}

validate_openwrt_support() {
	[ -f /etc/openwrt_release ] || die 'OpenWrt release metadata is missing'
	. /etc/openwrt_release
	release="${DISTRIB_RELEASE:-unknown}"
	supported_openwrt_release "$release" ||
		die "OpenWrt $release is unsupported; OpenWrt 24.10 or newer is required"
	command -v fw4 >/dev/null 2>&1 ||
		die 'firewall4 (fw4) is missing; OpenWrt 24.10 or newer is required'
}

if command -v apk >/dev/null 2>&1; then
	PKG_MGR=apk
elif command -v opkg >/dev/null 2>&1; then
	PKG_MGR=opkg
else
	die 'installed MiClash package was not found'
fi
validate_openwrt_support
INSTALLED_VERSION="$(installed_miclash_version "$PKG_MGR")"
case "$INSTALLED_VERSION" in
	0.9.*)
		OLD_VERSION="$INSTALLED_VERSION"
		[ -x /etc/init.d/clash ] || die 'legacy clash service is missing'
		[ -x /opt/clash/bin/clash-rules ] || die 'legacy cleanup helper is missing'
		/etc/init.d/clash enabled >/dev/null 2>&1 && OLD_ENABLED=1 || true
		/etc/init.d/clash running >/dev/null 2>&1 && OLD_RUNNING=1 || true
		if [ -f /opt/clash/settings ] &&
			grep -Eq '^INTERNET_ONLY_MICLASH=(true|1)$' /opt/clash/settings; then
			GUARD_ENABLED=1
		fi
		;;
	''|2.*)
		find_resume_backup ||
			die "no installed v0.9.x and no incomplete v0.9 backup to resume (installed: ${INSTALLED_VERSION:-none})"
		load_resume_backup
		UPGRADE_STATE='resume-install'
		say "Resuming the interrupted clean replacement from: $BACKUP"
		;;
	*) die "expected installed MiClash v0.9.x, found: $INSTALLED_VERSION" ;;
esac
need uci
ensure_stat_runtime

WORK="$(mktemp -d /tmp/miclash-v09-clean.XXXXXX)" || die 'cannot create temporary directory'
chmod 0700 "$WORK" || die 'cannot protect temporary directory'

github_proxy_url() {
	case "$1" in
		https://github.com/*|https://api.github.com/*|https://raw.githubusercontent.com/*)
			printf 'https://gh-proxy.com/%s\n' "$1"
			;;
		*) return 1 ;;
	esac
}

retryable_curl_code() {
	case "$1" in
		5|6|7|28|35|52|55|56) return 0 ;;
		*) return 1 ;;
	esac
}

download_once() {
	rm -f "$2"
	curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
		--connect-timeout 10 --max-time 120 --retry 2 --output "$2" "$1"
}

download() {
	url="$1"
	target="$2"
	if download_once "$url" "$target"; then
		return 0
	else
		curl_code=$?
	fi
	proxy_url=''
	if retryable_curl_code "$curl_code" && proxy_url="$(github_proxy_url "$url")"; then
		say 'Direct GitHub download failed; trying gh-proxy.com'
		download_once "$proxy_url" "$target"
		return $?
	fi
	return "$curl_code"
}

release_ready() {
	candidate="$1"
	release_base="https://github.com/ang3el7z/luci-app-miclash/releases/download/$candidate"
	rm -f "$WORK/install-miclash.sh" "$WORK/install-miclash.sh.sha256" "$WORK/miclash-release-manifest.json"
	download "$release_base/install-miclash.sh" "$WORK/install-miclash.sh" || return 1
	download "$release_base/install-miclash.sh.sha256" "$WORK/install-miclash.sh.sha256" || return 1
	download "$release_base/miclash-release-manifest.json" "$WORK/miclash-release-manifest.json" || return 1
	expected="$(awk 'NF == 2 && $2 == "install-miclash.sh" { print $1 }' "$WORK/install-miclash.sh.sha256")"
	printf '%s\n' "$expected" | grep -Eq '^[0-9a-f]{64}$' || return 1
	[ "$(sha256sum "$WORK/install-miclash.sh" | awk '{ print $1 }')" = "$expected" ] || return 1
	[ "$(jsonfilter -i "$WORK/miclash-release-manifest.json" -e '@.tag' 2>/dev/null)" = "$candidate" ] || return 1
	package_type=ipk
	[ "$PKG_MGR" != apk ] || package_type=apk
	jsonfilter -i "$WORK/miclash-release-manifest.json" -e '@.artifacts[*].package_type' 2>/dev/null |
		grep -Fxq "$package_type" || return 1
	grep -Fq 'MICLASH_CLEAN_INSTALL_PROTOCOL="miclash-clean-install-v2"' "$WORK/install-miclash.sh" || return 1
	chmod 0600 "$WORK/install-miclash.sh" "$WORK/install-miclash.sh.sha256" \
		"$WORK/miclash-release-manifest.json" || return 1
}

if [ -n "$TAG" ]; then
	release_ready "$TAG" || die "requested v2 release is incomplete or unsupported: $TAG"
else
	catalog="$WORK/releases.json"
	download 'https://api.github.com/repos/ang3el7z/luci-app-miclash/releases?per_page=20' "$catalog" ||
		die 'cannot download the MiClash release catalog'
	index=0
	while [ "$index" -lt 20 ]; do
		candidate="$(jsonfilter -i "$catalog" -e "@[$index].tag_name" 2>/dev/null || true)"
		[ -n "$candidate" ] || break
		draft="$(jsonfilter -i "$catalog" -e "@[$index].draft" 2>/dev/null || true)"
		prerelease="$(jsonfilter -i "$catalog" -e "@[$index].prerelease" 2>/dev/null || true)"
		if printf '%s\n' "$candidate" | grep -Eq '^v2\.[0-9]+\.[0-9]+$' &&
			[ "$draft" = false ] && [ "$prerelease" = false ] && release_ready "$candidate" 2>/dev/null; then
			TAG="$candidate"
			break
		fi
		index=$((index + 1))
	done
	[ -n "$TAG" ] || die 'no complete stable v2 release was found in the newest 20 releases'
fi
say "Selected ready MiClash release: $TAG"

if [ "$UPGRADE_STATE" = fresh ]; then
	stamp="$(date +%Y%m%d-%H%M%S)"
	BACKUP="/root/miclash-v09-backup-$stamp"
	[ ! -e "$BACKUP" ] || die "backup path already exists: $BACKUP"
	mkdir -p "$BACKUP/profiles" || die 'cannot create backup'
	chmod 0700 "$BACKUP" "$BACKUP/profiles" || die 'cannot protect backup'

	for name in config.yaml config2.yaml config3.yaml; do
		profile="/opt/clash/$name"
		[ ! -L "$profile" ] && [ -f "$profile" ] || continue
		cp -p "$profile" "$BACKUP/profiles/$name" || die "cannot back up $profile"
		chmod 0600 "$BACKUP/profiles/$name" || die "cannot protect backed-up $name"
	done
	if [ ! -L /opt/clash/settings ] && [ -f /opt/clash/settings ]; then
		cp -p /opt/clash/settings "$BACKUP/settings.v09" || die 'cannot back up MiClash settings'
	else
		: > "$BACKUP/settings.v09" || die 'cannot create empty settings backup'
	fi
	printf 'old_version=%s\nold_enabled=%s\nold_running=%s\nguard_enabled=%s\nrelease_tag=%s\n' \
		"$OLD_VERSION" "$OLD_ENABLED" "$OLD_RUNNING" "$GUARD_ENABLED" "$TAG" > "$BACKUP/upgrade-info"
	chmod 0600 "$BACKUP/upgrade-info" "$BACKUP/settings.v09" 2>/dev/null || true
	say "Backup created: $BACKUP"

	disable_legacy_guard
	say 'Stopping and removing MiClash v0.9.x...'
	/etc/init.d/clash stop >/dev/null 2>&1 || true
	/etc/init.d/clash disable >/dev/null 2>&1 || true
	/opt/clash/bin/clash-rules full_cleanup >/dev/null 2>&1 || die 'legacy network cleanup failed'
	case "$PKG_MGR" in
		opkg) opkg remove luci-app-miclash || die 'cannot remove the v0.9 package' ;;
		apk) apk del luci-app-miclash || die 'cannot remove the v0.9 package' ;;
	esac
	remove_legacy_guard_rules
	verify_legacy_guard_off || die 'legacy Guard returned during package removal'
fi

if [ "$UPGRADE_STATE" = resume-install ]; then
	remove_incomplete_v2
fi

rm -rf /opt/clash /etc/config/miclash /etc/miclash
rm -f /etc/init.d/clash /etc/init.d/miclash-autoupdate /etc/init.d/miclash-memory-guard \
	/etc/hotplug.d/iface/40-clash /etc/hotplug.d/net/99-clash-tun /var/etc/miclash.include
if [ -f /etc/crontabs/root ]; then
	sed -i '\|/opt/clash/bin/clash-rules update|d' /etc/crontabs/root || die 'cannot clean legacy cron entry'
fi
remove_legacy_guard_rules
verify_legacy_guard_off || die 'legacy Guard rules are still active before v2 installation'

say "Installing clean MiClash $TAG..."
sh "$WORK/install-miclash.sh" clean-install --target-tag "$TAG" </dev/null ||
	die "v2 installation failed; backup is kept at $BACKUP; run this transition command again to resume"

[ -x /opt/clash/bin/clash ] || die 'fresh Mihomo installation is missing'
for name in config.yaml config2.yaml config3.yaml; do
	profile="$BACKUP/profiles/$name"
	[ ! -L "$profile" ] && [ -f "$profile" ] || continue
	cp -p "$profile" "/opt/clash/$name" || die "cannot restore $name"
done
restore_legacy_user_data

[ -x /etc/init.d/miclashd ] || die 'v2 miclashd service is missing'
[ -x /etc/init.d/clash ] || die 'v2 clash service is missing'
/etc/init.d/miclashd restart || die 'miclashd did not start'
if [ "$GUARD_ENABLED" = 1 ]; then
	[ -x /etc/init.d/miclash-guard ] || die 'v2 Guard service is missing'
	/etc/init.d/miclash-guard start || die 'v2 Guard did not start'
fi
if [ "$OLD_ENABLED" = 1 ]; then /etc/init.d/clash enable || die 'cannot restore service enable state'; fi
if [ "$OLD_RUNNING" = 1 ]; then
	if ! /etc/init.d/clash start || ! /etc/init.d/clash running >/dev/null 2>&1; then
		say 'Mihomo is not ready yet; MiClash UI remains available and will continue recovery.'
	fi
fi

(umask 077; set -C; : > "$BACKUP/upgrade-complete") 2>/dev/null ||
	die 'cannot mark the clean replacement complete'
chmod 0600 "$BACKUP/upgrade-complete" || die 'cannot protect the completion marker'

rm -rf "$BACKUP"
say "MiClash $TAG clean installation completed."
say 'Temporary v0.9 backup removed after successful transition.'
