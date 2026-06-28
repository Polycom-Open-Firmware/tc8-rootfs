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

# --- apply ----------------------------------------------------------------
KIOSK=${TC8_CFG_KIOSK:-/etc/default/tc8-kiosk}   # TC8_CFG_KIOSK override = test hook

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

while IFS= read -r line || [ -n "$line" ]; do
	case "$line" in ''|\#*) continue ;; esac
	key=${line%%=*}; val=${line#*=}
	case "$key" in
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

[ "${ca_changed:-0}" = 1 ] && update-ca-certificates 2>/dev/null
log "config applied"
exit 0
