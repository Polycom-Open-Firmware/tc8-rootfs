#!/usr/bin/env bash
# TC8 slim Debian bookworm arm64 rootfs builder.
#
# Produces:
#   out/rootfs.tar.gz          — chrooted rootfs
#   out/initramfs.cpio.gz      — slot-aware busybox initramfs
#
# Usage:
#   sudo ./build.sh             # full build
#   sudo ./build.sh --keep      # don't remove work/rootfs after tarballing
#
# Requires (host): debootstrap, qemu-user-static, binfmt-support active,
#                  cpio, gzip, rsync, tar.
#
# Re-run idempotently: if work/rootfs already exists with /etc/debian_version,
# skips debootstrap and re-applies chroot-setup + config overlay.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK="${ROOT_DIR}/work"
ROOTFS="${WORK}/rootfs"
OUT="${ROOT_DIR}/out"
SUITE="bookworm"
ARCH="arm64"
MIRROR="${MIRROR:-http://deb.debian.org/debian}"

KEEP=0
for arg in "$@"; do
    case "$arg" in
        --keep) KEEP=1 ;;
        *) echo "unknown arg: $arg" >&2; exit 2 ;;
    esac
done

if [ "$(id -u)" -ne 0 ]; then
    echo "build.sh must run as root (chroot needs it)" >&2
    exit 1
fi

# Host-side dep check.
need() { command -v "$1" >/dev/null || { echo "missing host tool: $1" >&2; exit 1; }; }
need debootstrap
need cpio
need gzip
need rsync
need tar
[ -x /usr/bin/qemu-aarch64-static ] || {
    echo "missing /usr/bin/qemu-aarch64-static (apt install qemu-user-static)" >&2
    exit 1
}

mkdir -p "$WORK" "$OUT"

# 1. debootstrap (two-stage, qemu-binfmt for second stage).
if [ ! -f "$ROOTFS/etc/debian_version" ]; then
    echo "==> debootstrap stage 1 ($SUITE/$ARCH)"
    debootstrap --arch="$ARCH" --variant=minbase --foreign \
        "$SUITE" "$ROOTFS" "$MIRROR"

    install -m 0755 /usr/bin/qemu-aarch64-static "$ROOTFS/usr/bin/"

    echo "==> debootstrap stage 2 (in chroot)"
    chroot "$ROOTFS" /debootstrap/debootstrap --second-stage
else
    echo "==> rootfs exists, skipping debootstrap"
    install -m 0755 /usr/bin/qemu-aarch64-static "$ROOTFS/usr/bin/"
fi

# 2-4. chroot-setup: apt config, package install, cleanup, user, services.
echo "==> staging package-list.txt and chroot-setup.sh"
install -m 0644 "$ROOT_DIR/package-list.txt" "$ROOTFS/tmp/package-list.txt"
install -m 0755 "$ROOT_DIR/chroot-setup.sh"  "$ROOTFS/tmp/chroot-setup.sh"

# 5. Config overlay — copy etc/ before chroot-setup so ssh-keygen -A and
#    `systemctl enable` see our unit files / network config / udev rules.
echo "==> applying etc/ overlay"
rsync -a "$ROOT_DIR/etc/" "$ROOTFS/etc/"


# Bind /proc /sys /dev for chroot-setup's apt + ssh-keygen.
mount --bind /proc "$ROOTFS/proc"
mount --bind /sys "$ROOTFS/sys"
mount --bind   /dev  "$ROOTFS/dev"
mount -t devpts devpts "$ROOTFS/dev/pts" || true
trap 'umount -lf "$ROOTFS/dev/pts" 2>/dev/null || true; \
      umount -lf "$ROOTFS/dev"     2>/dev/null || true; \
      umount -lf "$ROOTFS/sys"     2>/dev/null || true; \
      umount -lf "$ROOTFS/proc"    2>/dev/null || true' EXIT

echo "==> running chroot-setup.sh"
chroot "$ROOTFS" /tmp/chroot-setup.sh

rm -f "$ROOTFS/tmp/chroot-setup.sh" "$ROOTFS/tmp/package-list.txt"
rm -f "$ROOTFS/usr/bin/qemu-aarch64-static"

# Tear down the binds before tar-ing.
umount -lf "$ROOTFS/dev/pts" 2>/dev/null || true
umount -lf "$ROOTFS/dev"     2>/dev/null || true
umount -lf "$ROOTFS/sys"     2>/dev/null || true
umount -lf "$ROOTFS/proc"    2>/dev/null || true
trap - EXIT

# 9. Tar.
echo "==> tarring rootfs -> $OUT/rootfs.tar.gz"
tar --numeric-owner -C "$ROOTFS" -czf "$OUT/rootfs.tar.gz" .

# 10. Initramfs.
echo "==> building initramfs"
BUSYBOX="$ROOTFS/usr/bin/busybox" "$ROOT_DIR/initramfs/build.sh"

if [ "$KEEP" -eq 0 ]; then
    echo "==> removing work/rootfs (use --keep to retain)"
    rm -rf "$ROOTFS"
fi

echo "==> done"
ls -lh "$OUT"/rootfs.tar.gz "$OUT"/initramfs.cpio.gz
