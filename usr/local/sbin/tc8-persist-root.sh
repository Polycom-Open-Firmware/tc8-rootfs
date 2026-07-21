#!/bin/sh
# Keep root's home (and a little persistent state) on the facres partition
# when it is available. Runs in BOTH rootfs modes (overlay and direct-rw) —
# facres is a separate partition, so /root behaves identically either way.

set -eu

log() { echo "tc8-persist-root: $*"; }

DEV=${TC8_PERSIST_DEV:-/dev/disk/by-partlabel/facres}
MNT=${TC8_PERSIST_MNT:-/persist}
ROOT=${TC8_PERSIST_ROOT:-$MNT/tc8-root}

# udev may still be settling at boot; give the by-partlabel symlink a
# moment instead of silently booting without persistence.
tries=0
while [ ! -e "$DEV" ] && [ "$tries" -lt 50 ]; do
	sleep 0.2
	tries=$((tries + 1))
done
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

# Purge stock Polycom Android app/bin staging the factory left on facres. These
# are APK bundles for the stock Android OS -- inert on the Debian firmware
# and ~600 MB of dead weight. Idempotent: wipes on first boot, no-op thereafter.
for stale in app bin; do
	[ -e "$MNT/$stale" ] && rm -rf "$MNT/$stale" && log "purged stock /persist/$stale"
done

# Kodi's persistent home (KIOSK_ENGINE=kodi runs as the kiosk user, uid 1000):
# library/settings survive reboots and reflashes alongside /root.
install -d -m 0755 -o 1000 -g 1000 "$MNT/kodi-home"
# The media library (Kodi's "Local media" source; exported over MTP as
# "Media"): drag-and-drop content that survives reboots and reflashes. The
# type subdirs give MTP a clear drop target per kind; the photo-frame mode
# slideshows "photos" (pictures only, no video/music mixed in).
install -d -m 0775 -o 1000 -g 1000 "$MNT/media"
for sub in photos music video; do
	install -d -m 0775 -o 1000 -g 1000 "$MNT/media/$sub"
done

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

# fake-hwclock: with the rootfs sealed behind a tmpfs overlay, the saved
# clock in /etc/fake-hwclock.data evaporates on reboot and every boot would
# start at the image build time (breaking TLS until NTP syncs). Keep the
# saved clock on facres via a file bind; the unit's ExecStop saves through
# it at shutdown.
if command -v fake-hwclock >/dev/null 2>&1; then
	if [ ! -f "$MNT/fake-hwclock.data" ]; then
		cp /etc/fake-hwclock.data "$MNT/fake-hwclock.data" 2>/dev/null \
			|| : > "$MNT/fake-hwclock.data"
	fi
	[ -f /etc/fake-hwclock.data ] || : > /etc/fake-hwclock.data
	if ! grep -q ' /etc/fake-hwclock.data ' /proc/mounts; then
		mount --bind "$MNT/fake-hwclock.data" /etc/fake-hwclock.data 2>/dev/null \
			|| log "failed to bind fake-hwclock.data (clock will reset each boot)"
	fi
	# Jump the clock forward to the persisted value (no-op if already ahead).
	fake-hwclock load >/dev/null 2>&1 || true
fi
