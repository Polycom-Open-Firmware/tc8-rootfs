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

# 5a. Optional SSH pubkey injection. Device generates its own host privkey
#     on first boot (chroot-setup.sh runs `ssh-keygen -A`); we just slip in
#     the operator's pubkey so root login works out of the box.
#     Source order: TC8_SSH_PUBKEY env wins, else ./authorized_keys at repo
#     root if it exists (gitignored — drop your pubkey there).
SSH_PUBKEY_SRC="${TC8_SSH_PUBKEY:-}"
[ -z "$SSH_PUBKEY_SRC" ] && [ -f "$ROOT_DIR/authorized_keys" ] && SSH_PUBKEY_SRC="$ROOT_DIR/authorized_keys"
if [ -n "$SSH_PUBKEY_SRC" ]; then
    if [ -f "$SSH_PUBKEY_SRC" ]; then
        echo "==> baking SSH pubkey from $SSH_PUBKEY_SRC"
        install -d -m 0700 "$ROOTFS/root/.ssh"
        cat "$SSH_PUBKEY_SRC" >> "$ROOTFS/root/.ssh/authorized_keys"
        chmod 0600 "$ROOTFS/root/.ssh/authorized_keys"
    else
        echo "warning: pubkey source $SSH_PUBKEY_SRC not found, skipping" >&2
    fi
fi

# 5b. Root password — works on tty, USB CDC ACM gadget (/dev/ttyGS0), and ssh.
#     Default is "root"; override with TC8_ROOT_PASSWORD env or
#     ./root_password file at repo root (gitignored). sshd is configured to
#     accept *both* pubkey and password — pubkey wins when both are present.
ROOT_PW="root"
if [ -n "${TC8_ROOT_PASSWORD:-}" ]; then
    ROOT_PW="$TC8_ROOT_PASSWORD"
elif [ -f "$ROOT_DIR/root_password" ]; then
    ROOT_PW="$(head -n1 "$ROOT_DIR/root_password")"
fi
echo "==> baking root password (tty + CDC ACM + ssh)"
install -d -m 1777 "$ROOTFS/tmp"
printf '%s' "$ROOT_PW" > "$ROOTFS/tmp/.tc8_root_pw"
chmod 0600 "$ROOTFS/tmp/.tc8_root_pw"
install -d -m 0755 "$ROOTFS/etc/ssh/sshd_config.d"
cat > "$ROOTFS/etc/ssh/sshd_config.d/99-tc8-rootpw.conf" <<EOF
PermitRootLogin yes
PasswordAuthentication yes
EOF

# 5. Config overlay — copy etc/ before chroot-setup so ssh-keygen -A and
#    `systemctl enable` see our unit files / network config / udev rules.
echo "==> applying etc/ overlay"
rsync -a "$ROOT_DIR/etc/" "$ROOTFS/etc/"

# 5c. Version stamp. firmware-build's top-level build.sh exports these so
# the image self-identifies. Stand-alone rootfs builds get "standalone".
cat > "$ROOTFS/etc/tc8-version" <<VER
# tc8-firmware version metadata. Sourceable as shell.
TC8_FW_VERSION="${TC8_FW_VERSION:-standalone}"
TC8_ROOTFS_VERSION="${TC8_ROOTFS_VERSION:-$(git describe --tags --always --dirty 2>/dev/null || echo standalone)}"
TC8_PATCHES_VERSION="${TC8_PATCHES_VERSION:-unknown}"
TC8_BUILD_DATE="${TC8_BUILD_DATE:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
TC8_BUILD_HOST="${TC8_BUILD_HOST:-$(hostname)}"
VER
chmod 0644 "$ROOTFS/etc/tc8-version"


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
tar --numeric-owner --one-file-system --exclude=./proc --exclude=./sys --exclude=./dev --exclude=./run -C "$ROOTFS" -czf "$OUT/rootfs.tar.gz" .

# 10. Initramfs.
echo "==> building initramfs"
BUSYBOX="$ROOTFS/usr/bin/busybox" "$ROOT_DIR/initramfs/build.sh"

if [ "$KEEP" -eq 0 ]; then
    echo "==> removing work/rootfs (use --keep to retain)"
    # Non-fatal: in unprivileged LXCs lazy /proc umount can leave residue
    # that we can't unlink. Tarball + initramfs are already built.
    rm -rf "$ROOTFS" 2>/dev/null || echo "warning: leftover work/rootfs files (harmless in unpriv LXC)" >&2
fi

echo "==> done"
ls -lh "$OUT"/rootfs.tar.gz "$OUT"/initramfs.cpio.gz
