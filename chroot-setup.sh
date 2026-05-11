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

# systemd-resolved's postinst symlinks /etc/resolv.conf to
# /run/systemd/resolve/stub-resolv.conf. Inside this chroot resolved isn't
# running, so the symlink target is missing and DNS dies. Populating the
# stub directly survives any further re-symlinking from dpkg triggers or
# systemd-tmpfiles. systemd-resolved itself overwrites /run/.../stub-resolv
# on first boot of the real system, so this leaks no test config.
mkdir -p /run/systemd/resolve
printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /run/systemd/resolve/stub-resolv.conf
# And put a regular file at /etc/resolv.conf in case nothing follows the symlink.
rm -f /etc/resolv.conf
printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /etc/resolv.conf

# Build + install uMTP-Responder (umtprd) from source. Not in Debian; the
# binary is ~70 KB so source-build is cheaper than vendoring a deb.
echo "==> building umtprd (uMTP-Responder)"
apt-get install -y --no-install-recommends gcc make libc6-dev
UMTP_TAG=umtprd-1.8.1
curl -fsSL "https://github.com/viveris/uMTP-Responder/archive/refs/tags/${UMTP_TAG}.tar.gz" \
    -o /tmp/umtp.tgz
tar -xzf /tmp/umtp.tgz -C /tmp
# Upstream Makefile has no `install` target; do it by hand.
( cd "/tmp/uMTP-Responder-${UMTP_TAG}" \
  && make -j"$(nproc)" \
  && install -m 0755 umtprd /usr/bin/umtprd )
rm -rf "/tmp/uMTP-Responder-${UMTP_TAG}" /tmp/umtp.tgz
apt-get purge -y gcc make libc6-dev
apt-get autoremove -y --purge

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

# Default ALSA state — caps Master/Speaker at known-safe levels (Master 75%,
# Speaker 85% ≈ -3 dB total through-chain). At full +24 dB the TAS5751 amp
# pulls enough current on certain content to brown out the panel and reboot
# it; this default keeps it audible without going there. alsa-restore.service
# applies this on every boot. Users can crank above it at runtime if they
# want, but the default after reflash/factory-reset is sane.
mkdir -p /var/lib/alsa
install -m 0644 /etc/asound.state.default /var/lib/alsa/asound.state
systemctl enable alsa-restore.service

# Force a fresh DHCPDISCOVER on every cold boot rather than letting
# networkd unicast-renew a stale lease file (which can take 5+ min to
# fall back to broadcast on a network where the old gateway is gone —
# e.g. when the panel moves between LANs). Cheap to do; lease state is
# trivially regenerable.
cat > /etc/systemd/system/wipe-networkd-leases.service <<'UNIT'
[Unit]
Description=Wipe systemd-networkd lease/state cache before networkd starts
DefaultDependencies=no
Before=systemd-networkd.service
ConditionPathExists=/var/lib/systemd/network

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'rm -rf /var/lib/systemd/network/*'
RemainAfterExit=no

[Install]
WantedBy=systemd-networkd.service
UNIT
systemctl enable wipe-networkd-leases.service

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
# tc8-mtp.service is enabled below, after we write its unit file inline.
systemctl set-default graphical.target

# Install the USB gadget setup script (configfs dance for CDC ACM + CDC NCM).
install -d -m 0755 /usr/local/sbin
cat > /usr/local/sbin/tc8-usb-gadget.sh <<'GADGET'
#!/bin/sh
# tc8-usb-gadget.sh — composite USB gadget for the panel's data port:
#   - CDC ACM  -> /dev/ttyACM0 on host (root login via serial-getty@ttyGS0)
#   - CDC NCM  -> usb0 on host (network 10.55.0.0/24; panel at 10.55.0.1)
#   - MTP/FFS  -> "Portable Device" on host, served by umtprd (tc8-mtp.service)
#
# This script ONLY assembles the gadget tree and mounts FunctionFS; it
# leaves UDC unbound. tc8-mtp.service starts umtprd, which opens the FFS
# endpoints, then writes UDC in its ExecStartPost — that's the only safe
# order with FFS-based functions.
set -eu
GADGET=/sys/kernel/config/usb_gadget/g1
FFS_DIR=/dev/ffs-mtp
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

# Function 3: FunctionFS instance for MTP. The ffs.<name>/ directory must
# match the mount tag and the daemon's expected path. umtprd attaches in
# tc8-mtp.service after this script exits.
mkdir -p functions/ffs.mtp
ln -sf functions/ffs.mtp configs/c.1/
mkdir -p "$FFS_DIR"
mountpoint -q "$FFS_DIR" || mount -t functionfs mtp "$FFS_DIR"

# Do NOT bind UDC here — FFS endpoints aren't ready until umtprd opens
# /dev/ffs-mtp/ep0. tc8-mtp.service's ExecStartPost writes UDC.
echo "tc8-usb-gadget: gadget assembled (ACM + NCM + FFS); awaiting umtprd"
GADGET
chmod 0755 /usr/local/sbin/tc8-usb-gadget.sh

# Network config for the NCM-side usb0 interface (panel = 10.55.0.1/24).
# Host is expected to take 10.55.0.2 (or run dhclient if you add a server later).
install -d -m 0755 /etc/systemd/network
# umtprd config — exports /data as a single MTP storage to the host.
install -d -m 0755 /etc/umtprd
cat > /etc/umtprd/umtprd.conf <<'UMTP'
# uMTP-Responder config for the TC8 panel.
# /data is the eMMC userdata partition (Android-format ext4 quota).
usb_vendor_id    = 0x1d6b
usb_product_id   = 0x0104
usb_class        = 0x00
usb_subclass     = 0x00
usb_protocol     = 0x00
usb_dev_version  = 0x0100
usb_max_packet_size = 0x40

manufacturer = "Polycom"
product      = "TC8 Panel Storage"
serial       = "TC8"

# storage = <path>, <description>, <flags>
# flags: locked | always_locked | read_only | (empty for rw)
storage = "/data", "Panel storage",

# Stay attached after first transfer
loop_on_unlock = no
UMTP

# tc8-mtp.service: starts umtprd, then binds the gadget UDC. Order
# matters: umtprd must register FFS endpoints before UDC is bound.
cat > /etc/systemd/system/tc8-mtp.service <<'MTP'
[Unit]
Description=TC8 MTP responder (umtprd over FunctionFS)
Requires=tc8-usb-gadget.service
After=tc8-usb-gadget.service
ConditionPathExists=/dev/ffs-mtp/ep0

[Service]
Type=simple
ExecStart=/usr/bin/umtprd -c /etc/umtprd/umtprd.conf
# Once umtprd has the FFS endpoints open, bind the composite gadget to its
# UDC. UDC writes return -ENODEV until all functions are ready, so retry.
ExecStartPost=/bin/sh -c '\
    UDC=$(ls /sys/class/udc | head -n1); \
    GADGET_UDC=/sys/kernel/config/usb_gadget/g1/UDC; \
    for _ in 1 2 3 4 5 6 7 8 9 10; do \
        echo "$UDC" > "$GADGET_UDC" 2>/dev/null && exit 0; \
        sleep 0.2; \
    done; \
    echo "tc8-mtp: failed to bind UDC after 2s" >&2; \
    exit 1'
ExecStopPost=/bin/sh -c 'echo "" > /sys/kernel/config/usb_gadget/g1/UDC 2>/dev/null || true'
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
MTP
# Now that tc8-mtp.service exists, enable it.
systemctl enable tc8-mtp.service

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
