#!/bin/sh
# tc8-config — apply a configuration blob pushed to the `cache` GPT partition
# over fastboot (the provisioning wizard's "Reconfigure" path). Runs once at
# boot, before the kiosk. If there's no valid blob (fresh/empty cache) it does
# nothing and the device keeps its current config. Full spec + the web/wizard
# half: ../../CONFIG-PARTITION.md (tc8-firmware-build/CONFIG-PARTITION.md).
#
# Blob at the START of the cache partition (little-endian):
#   off  0   8   magic   "TC8CFGv1"
#   off  8   4   length  N = payload byte length (u32 LE)
#   off 12  32   sha256(payload), raw bytes
#   off 44  20   reserved (zero)
#   off 64   N   payload: UTF-8 `KEY=value` lines (LF-separated)
#
# Only busybox/coreutils are present in the rootfs, so this is plain POSIX sh.

log() { echo "tc8-config: $*"; }

DEV=${TC8_CFG_DEV:-/dev/disk/by-partlabel/cache}   # TC8_CFG_DEV override = test hook
[ -e "$DEV" ] || { log "no cache partition — skipping"; exit 0; }

tmp_h=$(mktemp) || exit 0
tmp_p=$(mktemp) || exit 0
trap 'rm -f "$tmp_h" "$tmp_p"' EXIT

# --- header (first 64 bytes) ----------------------------------------------
dd if="$DEV" of="$tmp_h" bs=64 count=1 2>/dev/null

magic=$(dd if="$tmp_h" bs=1 count=8 2>/dev/null)
[ "$magic" = "TC8CFGv1" ] || { log "no config blob (magic mismatch) — skipping"; exit 0; }

# payload length: u32 LE at offset 8 (parse 4 bytes portably, no od --endian)
set -- $(od -An -tu1 -j8 -N4 "$tmp_h")
len=$(( ${1:-0} + ${2:-0} * 256 + ${3:-0} * 65536 + ${4:-0} * 16777216 ))
if [ "$len" -le 0 ] || [ "$len" -gt 1048576 ]; then
	log "implausible payload length ($len) — skipping"; exit 0
fi

want=$(od -An -tx1 -j12 -N32 "$tmp_h" | tr -d ' \n')

# --- payload + integrity --------------------------------------------------
dd if="$DEV" of="$tmp_p" bs=1 skip=64 count="$len" 2>/dev/null
got=$(sha256sum "$tmp_p" | cut -d' ' -f1)
if [ "$got" != "$want" ]; then
	log "sha256 mismatch — refusing to apply (want $want got $got)"; exit 0
fi
log "valid config blob: $len bytes"

# --- apply-once gating ----------------------------------------------------
# The full apply (chpasswd, CA install, hostname, wifi, kiosk URL…) runs ONCE
# per unique config blob — re-running it on every boot is noisy and can fight
# live changes. The blob's payload sha ($got) identifies the config; the marker
# lives on facres (persistent). A plain reboot has the same blob → skip. A
# re-provision writes a new blob → new sha → fresh apply.
#
# Sealed-mode wrinkle: with the rootfs behind a tmpfs overlay, /etc is
# ephemeral, so "just skip" would revert to baked defaults. So on an
# unchanged-config SEALED boot we silently restore the persisted /etc snapshot
# instead of re-applying. In direct-rw (maintenance) mode /etc persists on its
# own, so we simply skip and leave whatever's there.
PERSIST=${TC8_CFG_PERSIST:-/persist}
SHA_MARKER="$PERSIST/.tc8-config.sha"
SNAP="$PERSIST/tc8-config-etc"
CFG_PATHS="/etc/default/tc8-kiosk /etc/hostname /etc/shadow /etc/localtime /etc/timezone /etc/systemd/timesyncd.conf /etc/wpa_supplicant /etc/systemd/network/25-wlan0.network /usr/local/share/ca-certificates /etc/ssl/certs /etc/tc8-profile /etc/systemd/system/default.target /etc/systemd/system/getty@tty1.service.d"
SEALED=0; [ "$(findmnt -n -o FSTYPE / 2>/dev/null)" = overlay ] && SEALED=1
PERSIST_OK=0; { [ -d "$PERSIST" ] && mountpoint -q "$PERSIST" 2>/dev/null; } && PERSIST_OK=1

snap_restore() { for _p in $CFG_PATHS; do [ -e "$SNAP$_p" ] || continue; mkdir -p "$(dirname "$_p")"; cp -a "$SNAP$_p" "$(dirname "$_p")/" 2>/dev/null || true; done; }
snap_save()    { rm -rf "$SNAP"; for _p in $CFG_PATHS; do [ -e "$_p" ] || continue; mkdir -p "$SNAP$(dirname "$_p")"; cp -a "$_p" "$SNAP$(dirname "$_p")/" 2>/dev/null || true; done; printf '%s\n' "$got" > "$SHA_MARKER"; }

if [ "$PERSIST_OK" = 1 ] && [ "$(cat "$SHA_MARKER" 2>/dev/null)" = "$got" ]; then
	if [ "$SEALED" = 1 ] && [ -d "$SNAP" ]; then
		snap_restore; log "config unchanged — restored persisted state (apply-once)"; exit 0
	elif [ "$SEALED" = 0 ]; then
		log "config unchanged — already applied (apply-once)"; exit 0
	fi
fi
log "applying config (new, changed, or first boot)"

# --- apply ----------------------------------------------------------------
KIOSK=${TC8_CFG_KIOSK:-/etc/default/tc8-kiosk}   # TC8_CFG_KIOSK override = test hook
WPA_CONF=${TC8_CFG_WPA_CONF:-/etc/wpa_supplicant/wpa_supplicant-wlan0.conf}
WLAN_NET=${TC8_CFG_WLAN_NET:-/etc/systemd/network/25-wlan0.network}

set_kv() {  # set_kv FILE KEY VALUE — replace `KEY=...` in place, else append
	_f=$1; _k=$2; _v=$3
	if [ -f "$_f" ] && grep -q "^${_k}=" "$_f"; then
		awk -v k="$_k" -v v="$_v" '
			$0 ~ "^" k "=" { print k "=" v; seen=1; next }
			{ print }
			END { if (!seen) print k "=" v }
		' "$_f" > "$_f.tmp" && mv "$_f.tmp" "$_f"
	else
		printf '%s=%s\n' "$_k" "$_v" >> "$_f"
	fi
}

wifi_escape() {  # escape for a wpa_supplicant quoted string
	printf '%s' "$1" | awk '{ gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); printf "%s", $0 }'
}

apply_wifi() {
	[ -n "${wifi_ssid+x}" ] || return 0
	[ -n "$wifi_ssid" ] || { log "empty WIFI_SSID — skipping wifi config"; return 0; }

	install -d -m 0755 "$(dirname "$WPA_CONF")" "$(dirname "$WLAN_NET")"
	{
		printf 'ctrl_interface=/run/wpa_supplicant\n'
		printf 'update_config=0\n'
		[ -n "${wifi_country:-}" ] && printf 'country=%s\n' "$(wifi_escape "$wifi_country")"
		printf '\nnetwork={\n'
		printf '\tssid="%s"\n' "$(wifi_escape "$wifi_ssid")"
		printf '\tscan_ssid=1\n'
		if [ -n "${wifi_password+x}" ] && [ -n "$wifi_password" ]; then
			printf '\tpsk="%s"\n' "$(wifi_escape "$wifi_password")"
		else
			printf '\tkey_mgmt=NONE\n'
		fi
		printf '}\n'
	} > "$WPA_CONF"
	chmod 0600 "$WPA_CONF"

	cat > "$WLAN_NET" <<'EOF'
[Match]
Name=wlan0

[Network]
DHCP=yes
EOF

	if command -v systemctl >/dev/null 2>&1; then
		systemctl enable wpa_supplicant@wlan0.service >/dev/null 2>&1 || true
		systemctl restart wpa_supplicant@wlan0.service systemd-networkd.service >/dev/null 2>&1 || true
	fi
	log "configured wifi"
}

apply_profile() {
	# Device ROLE — the wizard's Application picker writes PROFILE=<id>. The role
	# IS the systemd default target: kiosk boots graphical.target (kiosk.service is
	# WantedBy it); dev / smart-speaker boot multi-user.target (console + ssh, no
	# kiosk lock). The role apps are baked (poly-<device>-profile-<id>); nothing is
	# fetched here. Persisted via CFG_PATHS so a sealed reboot keeps the role.
	role=${profile:-kiosk}
	printf '%s\n' "$role" > /etc/tc8-profile
	command -v systemctl >/dev/null 2>&1 || { log "no systemd — profile=$role recorded only"; return 0; }
	case "$role" in
		kiosk)
			systemctl set-default graphical.target >/dev/null 2>&1
			systemctl enable kiosk.service >/dev/null 2>&1 || true
			rm -f /etc/systemd/system/getty@tty1.service.d/autologin.conf 2>/dev/null
			log "profile=kiosk (fullscreen web kiosk)" ;;
		dev)
			# Console + SSH, no kiosk grab. Autologin root on tty1 for a
			# hands-on console; ssh is already baked-enabled for provisioning.
			systemctl set-default multi-user.target >/dev/null 2>&1
			systemctl enable ssh.service >/dev/null 2>&1 || systemctl enable ssh >/dev/null 2>&1 || true
			install -d /etc/systemd/system/getty@tty1.service.d
			printf '[Service]\nExecStart=\nExecStart=-/sbin/agetty --autologin root --noclear %%I $TERM\n' \
				> /etc/systemd/system/getty@tty1.service.d/autologin.conf
			log "profile=dev (console + ssh, no kiosk lock)" ;;
		smart-speaker)
			# Voice role. Its app ships in poly-<device>-profile-smart-speaker;
			# enable that service if it is baked in, otherwise leave a serviceable
			# console and say so — the voice stack is not built yet.
			systemctl set-default multi-user.target >/dev/null 2>&1
			if systemctl list-unit-files 2>/dev/null | grep -q '^poly-smart-speaker\.service'; then
				systemctl enable poly-smart-speaker.service >/dev/null 2>&1 || true
				log "profile=smart-speaker"
			else
				log "profile=smart-speaker selected, but its app package isn't installed — booting to console"
			fi ;;
		*)  log "unknown PROFILE '$role' — leaving the kiosk default"
		    systemctl set-default graphical.target >/dev/null 2>&1 ;;
	esac
}

while IFS= read -r line || [ -n "$line" ]; do
	case "$line" in ''|\#*) continue ;; esac
	key=${line%%=*}; val=${line#*=}
	case "$key" in
		PROFILE) profile=$val ;;
		KIOSK_URL|KIOSK_URL_FALLBACK|COG_OPTS)
			set_kv "$KIOSK" "$key" "$val"; log "set $key" ;;
		DEVICE_NAME)
			printf '%s\n' "$val" > /etc/hostname
			hostname "$val" 2>/dev/null || true
			log "set hostname" ;;
		ROOT_PASSWORD)
			printf 'root:%s\n' "$val" | chpasswd 2>/dev/null && log "set root password" ;;
		KIOSK_PASSWORD)
			printf 'kiosk:%s\n' "$val" | chpasswd 2>/dev/null && log "set kiosk password" ;;
		SSH_AUTHKEY)
			install -d -m 0700 /root/.ssh
			grep -qxF "$val" /root/.ssh/authorized_keys 2>/dev/null \
				|| printf '%s\n' "$val" >> /root/.ssh/authorized_keys
			chmod 0600 /root/.ssh/authorized_keys; log "added ssh authorized key" ;;
		TIMEZONE)
			if [ -e "/usr/share/zoneinfo/$val" ]; then
				ln -sf "/usr/share/zoneinfo/$val" /etc/localtime
				printf '%s\n' "$val" > /etc/timezone; log "set timezone=$val"
			else log "unknown timezone '$val'"; fi ;;
		NTP_SERVER)
			set_kv /etc/systemd/timesyncd.conf NTP "$val"; log "set NTP server" ;;
		CONFIG_TIME)
			# FORWARD-ONLY clock bump. The provisioner stamps the flash time
			# (epoch) here so an offline device (no DHCP, no NTP) still boots
			# with a roughly-right clock — enough for TLS cert validity and
			# sane log timestamps. Never move BACKWARD: if NTP already synced
			# (or fake-hwclock holds a newer time), keep the real time.
			case "$val" in
				''|*[!0-9]*) log "bad CONFIG_TIME '$val'" ;;
				*)  now=$(date +%s)
				    if [ "$val" -gt "$now" ]; then
				        date -s "@$val" >/dev/null 2>&1 				          && { command -v fake-hwclock >/dev/null 2>&1 && fake-hwclock save; 				               log "advanced clock to flash time ($(date -u -d @$val +%Y-%m-%dT%H:%MZ))"; }
				    else log "clock already >= CONFIG_TIME, leaving it"; fi ;;
			esac ;;
		WIFI_SSID) wifi_ssid=$val ;;
		WIFI_PASSWORD) wifi_password=$val ;;
		WIFI_COUNTRY) wifi_country=$val ;;
		CA_CERT_B64)
			install -d -m 0755 /usr/local/share/ca-certificates
			ca_n=$(( ${ca_n:-0} + 1 ))
			if printf '%s' "$val" | base64 -d > "/usr/local/share/ca-certificates/fleet-${ca_n}.crt" 2>/dev/null; then
				ca_changed=1; log "installed CA cert fleet-${ca_n}"
			else log "bad CA_CERT_B64 (not base64)"; fi ;;
		VOLUME_MASTER) amixer -q sset 'Master' "${val}%" 2>/dev/null && log "set Master vol" ;;
		VOLUME_SPEAKER) amixer -q sset 'Speaker' "${val}%" 2>/dev/null && log "set Speaker vol" ;;
		*) log "ignoring unknown key '$key'" ;;
	esac
done < "$tmp_p"

apply_wifi
apply_profile
[ "${ca_changed:-0}" = 1 ] && update-ca-certificates 2>/dev/null
# Persist the applied /etc so sealed reboots restore it without re-applying.
[ "$PERSIST_OK" = 1 ] && snap_save
log "config applied"
exit 0
