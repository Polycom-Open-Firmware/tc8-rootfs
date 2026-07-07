#!/bin/sh
# Keep root's home on the facres partition when it is available.

set -eu

log() { echo "tc8-persist-root: $*"; }

DEV=${TC8_PERSIST_DEV:-/dev/disk/by-partlabel/facres}
MNT=${TC8_PERSIST_MNT:-/persist}
ROOT=${TC8_PERSIST_ROOT:-$MNT/tc8-root}

[ -e "$DEV" ] || { log "no facres partition -- keeping /root on userdata"; exit 0; }

fstype=$(blkid -o value -s TYPE "$DEV" 2>/dev/null || true)
if [ "$fstype" != ext4 ]; then
	command -v mkfs.ext4 >/dev/null 2>&1 || { log "facres is not ext4 and mkfs.ext4 is unavailable"; exit 0; }
	log "initializing facres as ext4"
	mkfs.ext4 -F -L tc8-persist "$DEV" >/dev/null || { log "failed to initialize facres"; exit 0; }
fi

install -d -m 0755 "$MNT"
if ! mountpoint -q "$MNT"; then
	mount -o rw,noatime "$DEV" "$MNT" || { log "failed to mount facres"; exit 0; }
fi

install -d -m 0700 "$ROOT"
if [ ! -e "$ROOT/.tc8-root-initialized" ]; then
	if [ -d /root ]; then
		cp -a /root/. "$ROOT"/ 2>/dev/null || true
	fi
	touch "$ROOT/.tc8-root-initialized"
	chmod 0700 "$ROOT"
	log "initialized $ROOT"
fi

if ! mountpoint -q /root; then
	mount --bind "$ROOT" /root || { log "failed to bind $ROOT to /root"; exit 0; }
fi
chmod 0700 /root
log "/root is persistent on facres"
