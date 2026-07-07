#!/usr/bin/env bash
# TC8 slim Debian bookworm arm64 rootfs builder.
#
# Produces:
#   out/rootfs.tar.gz            — the default profile (kiosk)
#   out/rootfs-<profile>.tar.gz  — one per requested profile
#
# Usage:
#   sudo ./build.sh                          # default profile (kiosk)
#   sudo ./build.sh --profile=kiosk,bare     # explicit profile list
#   sudo ./build.sh --keep                   # don't remove work trees
#
# A profile is the metapackage poly-tc8-profile-<name> from the OpenPolycom
# apt archive (baked into the base via sources.list.d/openpolycom.list).
# The special profile "bare" installs nothing on top of the base. The base
# is debootstrapped ONCE; each profile gets an isolated copy so variants
# never pollute each other. See polycom_dev/PROFILES-PLAN.md (M2).
#
# Requires (host): debootstrap, qemu-user-static, binfmt-support active,
#                  gzip, rsync, tar.
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
PROFILES="kiosk"
DEFAULT_PROFILE="kiosk"
for arg in "$@"; do
    case "$arg" in
        --keep) KEEP=1 ;;
        --profile=*) PROFILES="${arg#--profile=}" ;;
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
need gzip
need rsync
need tar
[ -x /usr/bin/qemu-aarch64-static ] || {
    echo "missing /usr/bin/qemu-aarch64-static (apt install qemu-user-static)" >&2
    exit 1
}

# Give a chroot its OWN private /dev — a tmpfs with freshly-made device nodes —
# rather than bind-mounting the host/container's real /dev. Sharing the real /dev
# lets chroot/rsync/umount operations corrupt it: on a privileged LXC /dev/null
# flips into a regular file, which then swallows every `> /dev/null` and wedges
# the build. A private tmpfs is isolated and disposable.
setup_dev() {
    local d="$1/dev"
    mkdir -p "$d"
    mountpoint -q "$d" || mount -t tmpfs -o mode=0755,nosuid tmpfs "$d"
    [ -e "$d/null"    ] || mknod -m 666 "$d/null"    c 1 3
    [ -e "$d/zero"    ] || mknod -m 666 "$d/zero"    c 1 5
    [ -e "$d/full"    ] || mknod -m 666 "$d/full"    c 1 7
    [ -e "$d/random"  ] || mknod -m 444 "$d/random"  c 1 8
    [ -e "$d/urandom" ] || mknod -m 444 "$d/urandom" c 1 9
    [ -e "$d/tty"     ] || mknod -m 666 "$d/tty"     c 5 0
    [ -e "$d/console" ] || mknod -m 600 "$d/console" c 5 1
    ln -sfn /proc/self/fd "$d/fd"       # -n: replace the symlink, don't follow into it
    ln -sfn /proc/self/fd/0 "$d/stdin"
    ln -sfn /proc/self/fd/1 "$d/stdout"
    ln -sfn /proc/self/fd/2 "$d/stderr"
    mkdir -p "$d/pts" "$d/shm"
    mountpoint -q "$d/pts" || mount -t devpts -o mode=0620,gid=5,ptmxmode=666 devpts "$d/pts" 2>/dev/null || true
    mountpoint -q "$d/shm" || mount -t tmpfs tmpfs "$d/shm" 2>/dev/null || true
    [ -e "$d/ptmx" ] || ln -sf pts/ptmx "$d/ptmx"
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

# 5. Config overlay — copy etc/ (and usr/, for local sbin helpers like
#    tc8-hwaddr.sh) before chroot-setup so ssh-keygen -A, chmod and
#    `systemctl enable` see our unit files / network config / scripts.
echo "==> applying etc/ overlay"
rsync -a "$ROOT_DIR/etc/" "$ROOTFS/etc/"
[ -d "$ROOT_DIR/usr" ] && rsync -a "$ROOT_DIR/usr/" "$ROOTFS/usr/"

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

# Baseline clock: stamp build time into fake-hwclock.data so a device flashed
# WITHOUT a config blob (or before it applies) still boots with a roughly-right
# clock instead of 1970 — enough for TLS. The provisioner's CONFIG_TIME (flash
# time, fresher) advances it further; NTP corrects it once there's a network.
# Format is what `fake-hwclock save` writes: UTC "YYYY-MM-DD HH:MM:SS".
date -u +"%Y-%m-%d %H:%M:%S" > "$ROOTFS/etc/fake-hwclock.data"
chmod 0644 "$ROOTFS/etc/fake-hwclock.data"


# Bind /proc /sys /dev for chroot-setup's apt + ssh-keygen.
mount --bind /proc "$ROOTFS/proc"
mount --bind /sys "$ROOTFS/sys"
setup_dev "$ROOTFS"
trap 'umount -lf "$ROOTFS/dev/pts" "$ROOTFS/dev/shm" 2>/dev/null || true; \
      umount -lf "$ROOTFS/dev"     2>/dev/null || true; \
      umount -lf "$ROOTFS/sys"     2>/dev/null || true; \
      umount -lf "$ROOTFS/proc"    2>/dev/null || true' EXIT

echo "==> running chroot-setup.sh"
chroot "$ROOTFS" /tmp/chroot-setup.sh

rm -f "$ROOTFS/tmp/chroot-setup.sh" "$ROOTFS/tmp/package-list.txt"
rm -f "$ROOTFS/usr/bin/qemu-aarch64-static"

# Tear down the binds before tar-ing.
umount -lf "$ROOTFS/dev/pts" "$ROOTFS/dev/shm" 2>/dev/null || true
umount -lf "$ROOTFS/dev"     2>/dev/null || true
umount -lf "$ROOTFS/sys"     2>/dev/null || true
umount -lf "$ROOTFS/proc"    2>/dev/null || true
trap - EXIT

# 9. Profile variants + tar. The base tree is complete; each profile gets
# an isolated copy with its poly-tc8-profile-<name> metapackage installed.
tar_tree() {  # $1 = tree dir, $2 = output tarball
    tar --numeric-owner --one-file-system --exclude=./proc --exclude=./sys \
        --exclude=./dev --exclude=./run -C "$1" -czf "$2" .
}

IFS=',' read -ra PLIST <<< "$PROFILES"
for prof in "${PLIST[@]}"; do
    if [ "$prof" = bare ]; then
        echo "==> profile bare: base tree as-is -> $OUT/rootfs-bare.tar.gz"
        tar_tree "$ROOTFS" "$OUT/rootfs-bare.tar.gz"
        continue
    fi
    PTREE="$WORK/profile-$prof"
    echo "==> profile $prof: cloning base"
    rm -rf "$PTREE"; mkdir -p "$PTREE"
    rsync -aHAX --exclude=/proc/ --exclude=/sys/ --exclude=/dev/ --exclude=/run/ "$ROOTFS/" "$PTREE/"
    cp /usr/bin/qemu-aarch64-static "$PTREE/usr/bin/"
    mkdir -p "$PTREE/proc" "$PTREE/sys"   # excluded from clone; recreate mount points
    mount -t proc proc "$PTREE/proc"; mount --rbind /sys "$PTREE/sys"
    setup_dev "$PTREE"   # private /dev (not a bind of the host's — see setup_dev)
    echo "==> profile $prof: apt install poly-tc8-profile-$prof"
    chroot "$PTREE" sh -c "apt-get update && \
        DEBIAN_FRONTEND=noninteractive apt-get install -y poly-tc8-profile-$prof && \
        apt-get clean && rm -rf /var/lib/apt/lists/*"
    echo "TC8_PROFILE=\"$prof\"" >> "$PTREE/etc/tc8-version"
    umount -lf "$PTREE/dev" "$PTREE/sys" "$PTREE/proc" 2>/dev/null || true
    rm -f "$PTREE/usr/bin/qemu-aarch64-static"
    echo "==> tarring profile $prof -> $OUT/rootfs-$prof.tar.gz"
    tar_tree "$PTREE" "$OUT/rootfs-$prof.tar.gz"
    [ "$KEEP" -eq 0 ] && rm -rf "$PTREE" 2>/dev/null || true
done

# Compatibility: plain rootfs.tar.gz = the default profile (kiosk) when
# built, else the bare base — existing tooling keeps working unchanged.
if [ -f "$OUT/rootfs-$DEFAULT_PROFILE.tar.gz" ]; then
    cp -f "$OUT/rootfs-$DEFAULT_PROFILE.tar.gz" "$OUT/rootfs.tar.gz"
else
    echo "==> tarring base -> $OUT/rootfs.tar.gz"
    tar_tree "$ROOTFS" "$OUT/rootfs.tar.gz"
fi


if [ "$KEEP" -eq 0 ]; then
    echo "==> removing work/rootfs (use --keep to retain)"
    # Non-fatal: in unprivileged LXCs lazy /proc umount can leave residue
    # that we can't unlink. Tarball is already built.
    rm -rf "$ROOTFS" 2>/dev/null || echo "warning: leftover work/rootfs files (harmless in unpriv LXC)" >&2
fi

echo "==> done"
ls -lh "$OUT"/rootfs*.tar.gz
