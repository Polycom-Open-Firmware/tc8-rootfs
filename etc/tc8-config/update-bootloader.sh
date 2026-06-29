#!/bin/sh
# tc8-update-bootloader — flash a new stage-2 to the eMMC boot1 HW partition if
# one is staged in the `cache` partition. Rides the config-data mechanism: the
# wizard writes the bootloader image into cache (at the bootloader offset)
# alongside the config blob; this runs at boot and applies it. No serial needed.
#
# Idempotent: only writes when the staged image differs from boot1. boot0 (the
# stock stage-1) is never touched, so a bad write is recoverable via the HW SDP /
# uuu path. Spec: /CONFIG-PARTITION.md (bootloader region). Only busybox/
# coreutils are present, so this is plain POSIX sh.
#
# cache bootloader region (little-endian):
#   1 MiB        header sector: magic "TC8BOOT1" | len u32 | sha256(image,32) | rsvd
#   1 MiB + 512  the stage-2 image (sector-aligned), `len` bytes

log() { echo "tc8-bootloader: $*"; }

DEV=${TC8_CACHE_DEV:-/dev/disk/by-partlabel/cache}
BOOT1=${TC8_BOOT1:-/dev/mmcblk2boot1}
FORCE_RO=${TC8_FORCE_RO:-/sys/block/mmcblk2boot1/force_ro}
HDR_SECTOR=2048          # 1 MiB / 512
IMG_SECTOR=2049          # (1 MiB + 512) / 512

[ -e "$DEV" ] && [ -e "$BOOT1" ] || { log "no cache or boot1 — skip"; exit 0; }

hdr=$(mktemp) || exit 0
img=$(mktemp) || exit 0
trap 'rm -f "$hdr" "$img"' EXIT

dd if="$DEV" of="$hdr" bs=512 skip="$HDR_SECTOR" count=1 2>/dev/null
magic=$(dd if="$hdr" bs=1 count=8 2>/dev/null)
[ "$magic" = "TC8BOOT1" ] || { log "no bootloader image staged — skip"; exit 0; }

set -- $(od -An -tu1 -j8 -N4 "$hdr")
len=$(( ${1:-0} + ${2:-0} * 256 + ${3:-0} * 65536 + ${4:-0} * 16777216 ))
if [ "$len" -le 4096 ] || [ "$len" -gt 4194304 ]; then
	log "implausible image length ($len) — skip"; exit 0
fi
want=$(od -An -tx1 -j12 -N32 "$hdr" | tr -d ' \n')

secs=$(( (len + 511) / 512 ))
dd if="$DEV" of="$img" bs=512 skip="$IMG_SECTOR" count="$secs" 2>/dev/null
truncate -s "$len" "$img"

got=$(sha256sum "$img" | cut -d' ' -f1)
[ "$got" = "$want" ] || { log "sha256 mismatch — refusing to flash"; exit 0; }
sig=$(od -An -tx1 -N4 "$img" | tr -d ' ')
[ "$sig" = "0a000014" ] || { log "not a stage-2 image (sig=$sig) — refusing"; exit 0; }

cur=$(dd if="$BOOT1" bs=512 count="$secs" 2>/dev/null | head -c "$len" | sha256sum | cut -d' ' -f1)
if [ "$cur" = "$got" ]; then
	log "boot1 already current — nothing to do"; exit 0
fi

log "flashing new stage-2 to boot1 ($len bytes)"
echo 0 > "$FORCE_RO" 2>/dev/null || true
dd if="$img" of="$BOOT1" bs=512 conv=fsync 2>/dev/null
sync
echo 1 > "$FORCE_RO" 2>/dev/null || true

new=$(dd if="$BOOT1" bs=512 count="$secs" 2>/dev/null | head -c "$len" | sha256sum | cut -d' ' -f1)
if [ "$new" = "$got" ]; then
	log "bootloader updated OK — active on next reboot"
else
	log "VERIFY FAILED after write — boot1 may be inconsistent (recover via SDP/uuu)"
fi
exit 0
