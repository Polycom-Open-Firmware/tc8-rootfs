#!/bin/bash
# Runs INSIDE the qemu-binfmt arm64 chroot. Called by build.sh after the
# second-stage debootstrap finishes. Reads /tmp/package-list.txt (staged
# in by build.sh) and installs the configured Debian packages.
set -e

# APT / dpkg config — drop docs, suggests, recommends.
echo 'APT::Install-Recommends "false";' > /etc/apt/apt.conf.d/99-no-recommends
echo 'APT::Install-Suggests   "false";' > /etc/apt/apt.conf.d/99-no-suggests
cat > /etc/dpkg/dpkg.cfg.d/01-no-docs <<'EOF'
path-exclude /usr/share/doc/*
path-exclude /usr/share/man/*
path-exclude /usr/share/info/*
path-exclude /usr/share/locale/*
path-include /usr/share/locale/locale.alias
path-include /usr/share/locale/en/*
path-include /usr/share/locale/en_US/*
path-include /usr/share/locale/C/*
EOF

export DEBIAN_FRONTEND=noninteractive
apt-get update

# Read package-list.txt (one package per line, # comments stripped).
PKG_LIST="/tmp/package-list.txt"
[ -f "$PKG_LIST" ] || { echo "missing $PKG_LIST" >&2; exit 1; }
PKGS=$(sed -e 's/#.*$//' -e '/^[[:space:]]*$/d' "$PKG_LIST" | tr '\n' ' ')

# shellcheck disable=SC2086
apt-get install -y --no-install-recommends $PKGS

# Cache + locale + static-archive cleanup.
apt-get clean
rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*
rm -rf /usr/share/doc/* /usr/share/man/* /usr/share/info/*
find /usr/share/locale -mindepth 1 -maxdepth 1 \
    -not -name 'en*' -not -name 'C.*' -not -name locale.alias \
    -exec rm -rf {} + 2>/dev/null || true
find /usr -name '*.a' -delete 2>/dev/null || true

# kiosk user (uid 1000, no password — login disabled, kiosk service runs via PAM).
if ! id -u kiosk >/dev/null 2>&1; then
    # Ensure groups exist (some not created by our package set)
    for g in render input seat; do
        getent group "$g" >/dev/null || groupadd --system "$g"
    done
    useradd -u 1000 -m -s /bin/bash -G audio,video,render,input kiosk
    passwd -d kiosk
fi

echo 'tc8-kiosk' > /etc/hostname

# Locale: pre-generate en_US.UTF-8 so PAM/openssh stop logging
# "Unable to open env file: /etc/default/locale" on every login.
echo 'en_US.UTF-8 UTF-8' > /etc/locale.gen
locale-gen en_US.UTF-8 >/dev/null 2>&1 || true
echo 'LANG=en_US.UTF-8' > /etc/default/locale

# Network + resolv stub.
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

# Volatile journal — no eMMC writes for logs.
sed -i 's/^#\?Storage=.*/Storage=volatile/' /etc/systemd/journald.conf

# /data mountpoint exists in the rootfs so `data.mount` has a target.
mkdir -p /data

# Enable services.
systemctl enable systemd-networkd
systemctl enable systemd-resolved
systemctl enable systemd-timesyncd
systemctl enable seatd.service
systemctl enable kiosk-config.service
systemctl enable kiosk-vt.service
systemctl enable kiosk.service
systemctl set-default graphical.target

# SSH host keys: build.sh stages shared keys at /etc/ssh/ before this runs;
# generate any missing ones (no-op if all present), and drop a reference copy.
ssh-keygen -A
mkdir -p /etc/ssh/baked
cp /etc/ssh/ssh_host_*_key      /etc/ssh/baked/ 2>/dev/null || true
cp /etc/ssh/ssh_host_*_key.pub  /etc/ssh/baked/ 2>/dev/null || true

mkdir -p /root/.ssh
chmod 700 /root/.ssh
[ -f /root/.ssh/authorized_keys ] || : > /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys

# Optional: root password + sshd PasswordAuthentication, if build.sh
# dropped /etc/ssh/sshd_config.d/99-tc8-rootpw.conf and a /tmp/.tc8_root_pw.
if [ -f /tmp/.tc8_root_pw ]; then
    echo "root:$(cat /tmp/.tc8_root_pw)" | chpasswd
    rm -f /tmp/.tc8_root_pw
fi

echo "chroot-setup.sh: DONE"
