# poly-rootfs

Builds the slim Debian bookworm arm64 kiosk rootfs for the **Polycom
panels** — one builder for both boards (same i.MX 8M Mini SoC):
`--device=tc8` (default) or `--device=c60` picks the board's profile
metapackage (see [Device-role profiles](#device-role-profiles)).

This repo only produces the rootfs.  The kernel comes from
`poly-kernel-patches`; the flashable boot artifacts are assembled by
`poly-firmware-build`, which packs this rootfs per target — the sparse
`rootfs.simg` flashed to `userdata` on the TC8, `rootfs.img.zst` for
`system_a` on the C60.

## What this builds

- `out/rootfs.tar.gz` — minbase Debian bookworm arm64 chroot, with
  the kiosk service stack (cage + cog/WPE), Hantro VPU userspace,
  baked SSH host keys, and our `/etc` overlay applied

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
- Minimal utils: util-linux, psmisc, procps, less,
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
- the `/data` mount (`/dev/mmcblk2p15`, Android's userdata partition, for
  cross-slot persistence) is inlined in `kiosk.service` as an
  `ExecStartPre` (`mountpoint -q /data || mount /dev/mmcblk2p15 /data`) —
  there's no separate mount unit
- `etc/udev/rules.d/{50-drm,70-seat}.rules` — gives the `kiosk` user
  group access to `/dev/dri/*` and seat-tags `/dev/input/event*` so
  libinput finds the Goodix touchscreen
- `etc/environment.d/99-vpu.conf` — biases GStreamer toward the
  v4l2 stateless decoders (Hantro G1/G2) over libav

Per-device overrides are intended to live on `/data/poly-kiosk/config`
(populated separately during deployment); `kiosk-config.service` reads
that at boot if present.

## Read-only rootfs, overlay writes, persistent /root

On the flashed image the initramfs (assembled by `poly-firmware-build`)
mounts `userdata` **read-only** and lays a tmpfs overlay over `/`: the
system runs normally but every write is ephemeral and evaporates on
reboot. Two escape hatches ship in this repo:

- **Persistent `/root`** — `tc8-persist-root.service` mounts the 1 GiB
  `facres` GPT partition at `/persist` (auto-`mkfs.ext4` on first use)
  and binds `/persist/tc8-root` onto `/root`. facres is never touched
  by the provisioner, so root's home survives reboots *and* reflashes.
  The saved fake-hwclock timestamp is persisted there too.
- **Maintenance mode** — `tc8-rw [--reboot]` (alias `poly-open`) sets a sticky flag on
  facres (`/persist/.tc8-rootfs-rw`); the next boot mounts the rootfs
  direct-rw with **no** overlay, so `apt install` etc. are safe and
  permanent. `tc8-ro && reboot` (alias `poly-pin`) reseals. `tc8-mode` reports the current
  and next-boot mode, and interactive logins get a banner while in
  maintenance mode (`etc/profile.d/tc8-mode.sh`).

Never write to the underlying fs while an overlay boot is active (e.g.
by remounting the lower rw) — dpkg state would tear between the
ephemeral upper and the persistent lower. Always use the reboot flow.

Full design, boot flow and failure modes: `docs/RO-ROOT.md` in
`poly-firmware-build`.

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

## Known limitations

- No automatic touch calibration; final viewing rotation is the sum of
  the kernel cmdline `video=DSI-1:rotate=270` (panel mounted 270° from
  native) and cage's `-r` (90° CCW in the compositor). wlroots
  auto-maps the single-output touch transform off the wayland output
  rotation. If you change either piece, re-run the orientation sweep
  with `smoke/orient.html`.
- Shared SSH host keys (see above)
- Offline clock is *roughly* right, not exact: with no NTP the boot
  clock comes from the image build date (`fake-hwclock`) bumped
  forward-only to the wizard's flash-time stamp (`CONFIG_TIME`) — good
  enough for TLS; real time still needs `timesyncd` reaching NTP

## Licensing

Build scripts and config files in this repo: GPL-2.0-only (see
`LICENSE`).  Installed Debian packages: their respective upstream
licenses (mostly GPL-2.0+ and LGPL-2.1+).  AOSP testkey + AVB
tooling: handled by the downstream `poly-firmware-build` repo, not
here.

## Device-role profiles

`sudo ./build.sh --profile=<name>[,<name>…] --device=<tc8|c60>` (defaults:
profile `kiosk`, device `tc8`) builds one debootstrap base and then, per
profile, an isolated clone with the `poly-<device>-profile-<name>`
metapackage installed from the
[OpenPolycom archive](https://github.com/Polycom-Open-Firmware/apt) —
emitted as `out/rootfs-<name>.tar.gz` with `TC8_PROFILE` stamped in
`/etc/tc8-version`. `--device` picks the per-board metapackage
(`poly-tc8-profile-kiosk` vs `poly-c60-profile-kiosk`); the composer
(`poly-firmware-build`) passes it from `--target`. `bare` = the untouched
base; plain `rootfs.tar.gz` always aliases the default profile. The archive
keyring + sources.list are baked into the base
(`etc/apt/sources.list.d/openpolycom.list`), so both image builds and
on-device `tc8-rw` maintenance installs resolve `poly-*` packages with no
setup. The device role at runtime is set from the config blob's `PROFILE`
key by `apply-config` (kiosk / dev / smart-speaker). Big picture:
`polycom_dev/PROFILES-PLAN.md`.
