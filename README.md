# tc8-rootfs

Builds the slim Debian bookworm arm64 kiosk rootfs for the
**Polycom TC8** panel (i.MX 8M Mini).

This repo only produces the rootfs and initramfs.  The kernel comes
from `tc8-kernel-patches`; the flashable `boot.img`/`system.img`/
`vbmeta.img`/`dtbo.img` artifacts are assembled by `tc8-firmware-build`.

## What this builds

- `out/rootfs.tar.gz` — minbase Debian bookworm arm64 chroot, with
  the kiosk service stack (cage + cog/WPE), Hantro VPU userspace,
  baked SSH host keys, and our `/etc` overlay applied
- `out/initramfs.cpio.gz` — slot-aware busybox initramfs that reads
  `androidboot.slot_suffix` from `/proc/cmdline` and mounts
  `/dev/mmcblk2p5` (slot_a) or `/dev/mmcblk2p6` (slot_b) as root

## Quick start

```bash
sudo apt-get install debootstrap qemu-user-static binfmt-support \
                     cpio gzip rsync
sudo ./build.sh
```

Output lands in `out/`.

## Repo layout

```
build.sh            # host-side: debootstrap, chroot, overlay, tarball
chroot-setup.sh     # runs inside the chroot: apt + cleanup + enable units
package-list.txt    # one Debian package per line (comments OK)
etc/                # files copied verbatim into the rootfs at the same path
initramfs/          # busybox /init script + its build script
out/                # build output (gitignored)
```

## What's installed

`package-list.txt` (~34 packages) covers:

- Boot/init: systemd, systemd-sysv, systemd-resolved, systemd-timesyncd,
  udev, dbus, libnss-systemd
- Networking: iproute2, iputils-ping, isc-dhcp-client, openssh-server
- Wayland kiosk: cage compositor, cog launcher, WPE WebKit + libwpe-fdo,
  xwayland (cage 0.1.4 hard-requires it)
- GPU + input: seatd, libinput-bin, libegl1, libgles2, mesa-utils
- Audio: alsa-utils
- Hantro VPU: gstreamer1.0-{plugins-base,plugins-good,plugins-bad,libav},
  v4l-utils
- Minimal utils + initramfs source: util-linux, psmisc, procps, less,
  curl, ca-certificates, busybox-static

`--no-install-recommends` everywhere; `/usr/share/doc`, `/usr/share/man`,
non-`en` locales stripped via `dpkg path-exclude`.  Final rootfs tarball
~280-320 MiB compressed.

## Configuration

Per-build defaults live in `etc/`:

- `etc/default/tc8-kiosk` — `KIOSK_URL` and cage/cog options
- `etc/systemd/network/lan.network` — DHCP on the DSA `lan` interface
- `etc/systemd/system/{kiosk,kiosk-config,kiosk-vt}.service` —
  cage-on-tty7 service + a oneshot that overrides config from
  `/data/poly-kiosk/config` if present + an explicit `chvt 7` helper
- `etc/systemd/system/data.mount` — mounts `/dev/mmcblk2p15`
  (Android's userdata partition) as `/data` for cross-slot persistence
- `etc/udev/rules.d/{50-drm,70-seat}.rules` — gives the `kiosk` user
  group access to `/dev/dri/*` and seat-tags `/dev/input/event*` so
  libinput finds the Goodix touchscreen
- `etc/environment.d/99-vpu.conf` — biases GStreamer toward the
  v4l2 stateless decoders (Hantro G1/G2) over libav

Per-device overrides are intended to live on `/data/poly-kiosk/config`
(populated separately during deployment); `kiosk-config.service` reads
that at boot if present.

## SSH host keys

`chroot-setup.sh` runs `ssh-keygen -A` inside the chroot so every
build gets a fresh, unique set of host keys.  Keys are not committed
to this repo.  If you build the same rootfs twice on different
machines you'll get different keys; that's intentional.

For per-panel keys (rather than per-build), generate them on first
boot and stash under `/data/poly-kiosk/ssh-host-keys/` — the `/data`
partition is shared between A/B slots, so generated keys persist
across slot swaps.  A small first-boot oneshot service in
`etc/systemd/system/` would do this; not currently shipped.

## Initramfs (`initramfs/init`)

Slot-aware: parses `androidboot.slot_suffix=_a|_b` from `/proc/cmdline`,
mounts the corresponding `system_X` partition rw, `switch_root`s into
it.  Falls back to slot_b if no suffix is in cmdline; drops to a
busybox shell on mount failure.  Build:

```bash
BUSYBOX=/path/to/busybox-static ./initramfs/build.sh
```

Or run the top-level `./build.sh`, which builds the rootfs first and
then calls this script with `BUSYBOX=work/rootfs/usr/bin/busybox`.

## Known limitations

- No automatic touch calibration; final viewing rotation is the sum of
  the kernel cmdline `video=DSI-1:rotate=270` (panel mounted 270° from
  native) and cage's `-r -r` (180° CW in the compositor). wlroots
  auto-maps the single-output touch transform off the wayland output
  rotation. If you change either piece, re-run the orientation sweep
  with `tc8-firmware-build/tools/orient.html`.
- Shared SSH host keys (see above)
- No NTP fallback if the network has no internet — boot clock is
  whatever the kernel set; HTTPS in cog will fail until `timesyncd`
  pulls time from `pool.ntp.org`

## Licensing

Build scripts and config files in this repo: GPL-2.0-only (see
`LICENSE`).  Installed Debian packages: their respective upstream
licenses (mostly GPL-2.0+ and LGPL-2.1+).  AOSP testkey + AVB
tooling: handled by the downstream `tc8-firmware-build` repo, not
here.
