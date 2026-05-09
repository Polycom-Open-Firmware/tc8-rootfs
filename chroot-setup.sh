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
# USB CDC ACM gadget: end-user console access via the panel's USB data port.
# Plug the data port into a host -> /dev/ttyACM0 with a getty waiting.
systemctl enable tc8-usb-gadget.service
systemctl enable serial-getty@ttyGS0.service
systemctl set-default graphical.target

# Install the USB gadget setup script (configfs dance for CDC ACM + CDC NCM).
install -d -m 0755 /usr/local/sbin
cat > /usr/local/sbin/tc8-usb-gadget.sh <<'GADGET'
#!/bin/sh
# tc8-usb-gadget.sh — composite USB gadget for the panel's data port:
#   - CDC ACM  -> /dev/ttyACM0 on host (root login via serial-getty@ttyGS0)
#   - CDC NCM  -> usb0 on host (network 10.55.0.0/24; panel at 10.55.0.1)
# Plug the data port into a host and you get both: a serial console AND
# a network link for ssh/scp/sshfs/etc.
set -eu
GADGET=/sys/kernel/config/usb_gadget/g1
mountpoint -q /sys/kernel/config || mount -t configfs none /sys/kernel/config
[ -e "$GADGET/UDC" ] && [ -s "$GADGET/UDC" ] && exit 0
mkdir -p "$GADGET" && cd "$GADGET"

# IDs: Linux Foundation "Multifunction Composite Gadget"
echo 0x1d6b > idVendor
echo 0x0104 > idProduct
echo 0x0100 > bcdDevice
echo 0x0200 > bcdUSB
# Class 0xEF/0x02/0x01 = "Interface Association Descriptor" — the right
# class for composite devices (host then looks at per-interface classes).
echo 0xEF > bDeviceClass
echo 0x02 > bDeviceSubClass
echo 0x01 > bDeviceProtocol

mkdir -p strings/0x409
SERIAL="$(cat /sys/devices/soc0/serial_number 2>/dev/null || echo TC8)"
echo "Polycom"     > strings/0x409/manufacturer
echo "TC8 Console" > strings/0x409/product
echo "$SERIAL"     > strings/0x409/serialnumber

mkdir -p configs/c.1/strings/0x409
echo "CDC ACM + NCM" > configs/c.1/strings/0x409/configuration
echo 250 > configs/c.1/MaxPower

# Function 1: CDC ACM (serial console).
mkdir -p functions/acm.usb0
ln -sf functions/acm.usb0 configs/c.1/

# Function 2: CDC NCM (USB Ethernet).
# Set static MAC pair so the panel's usb0 has a stable link layer.
# Generate from SoC serial so multiple panels don't collide; fallback fixed.
HEX=$(printf '%s' "$SERIAL" | md5sum | cut -c1-12)
[ "${#HEX}" -eq 12 ] || HEX="020000123456"
DEV_MAC=$(printf '02:%s:%s:%s:%s:%s' \
    ${HEX:2:2} ${HEX:4:2} ${HEX:6:2} ${HEX:8:2} ${HEX:10:2})
HOST_MAC=$(printf '02:%s:%s:%s:%s:%s' \
    ${HEX:2:2} ${HEX:4:2} ${HEX:6:2} ${HEX:8:2} \
    $(printf '%02x' $(( 0x${HEX:10:2} ^ 0x01 )) ))
mkdir -p functions/ncm.usb0
echo "$DEV_MAC"  > functions/ncm.usb0/dev_addr   # MAC seen on the panel side (usb0)
echo "$HOST_MAC" > functions/ncm.usb0/host_addr  # MAC the host's usb-net iface gets
ln -sf functions/ncm.usb0 configs/c.1/

UDC="$(ls /sys/class/udc 2>/dev/null | head -n1)"
[ -n "$UDC" ] || { echo "tc8-usb-gadget: no UDC available" >&2; exit 1; }
echo "$UDC" > UDC
echo "tc8-usb-gadget: bound $UDC; ttyGS0 + usb0 ready"
GADGET
chmod 0755 /usr/local/sbin/tc8-usb-gadget.sh

# Network config for the NCM-side usb0 interface (panel = 10.55.0.1/24).
# Host is expected to take 10.55.0.2 (or run dhclient if you add a server later).
install -d -m 0755 /etc/systemd/network
cat > /etc/systemd/network/usb0.network <<'NW'
[Match]
Name=usb0

[Network]
Address=10.55.0.1/24
ConfigureWithoutCarrier=yes
DHCPServer=yes
IPMasquerade=no

[DHCPServer]
PoolOffset=2
PoolSize=4
EmitDNS=no
EmitNTP=no
NW

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
