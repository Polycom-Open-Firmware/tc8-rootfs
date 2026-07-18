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
  the kiosk service stack (weston + cog/WPE), Hantro VPU userspace,
  baked SSH host keys, and the `/etc` overlay applied

## Quick start

```bash
sudo apt-get install debootstrap qemu-user-static binfmt-support \
                     gzip rsync
sudo ./build.sh
```

Output lands in `out/`.

## Repo layout

```
build.sh            # host-side: debootstrap, chroot, overlay, tarball
chroot-setup.sh     # runs inside the chroot: apt + cleanup + enable units
package-list.txt    # one Debian package per line (comments OK)
etc/                # files copied verbatim into the rootfs at the same path
usr/                # ditto: kiosk-launch, the tc8-* sbin helpers,
                    #   tc8-bootctl.c, the baked archive keyring
out/                # build output (gitignored)
```

## What's installed

`package-list.txt` (42 packages, one per line with per-package rationale)
covers:

- Boot/init: systemd, systemd-sysv, systemd-resolved, systemd-timesyncd,
  udev, dbus, libnss-systemd, fake-hwclock
- Networking: iproute2, iputils-ping, isc-dhcp-client, openssh-server,
  wpasupplicant
- Wayland kiosk: weston (the kiosk-shell compositor), cog launcher,
  WPE WebKit + libwpe-fdo, plus cage and xwayland (in the package list
  but not on the kiosk path; `weston.ini` sets `xwayland=false`)
- GPU + input: seatd, libinput-bin, libegl1, libgles2, mesa-utils
- Audio: alsa-utils
- Hantro VPU: gstreamer1.0-{plugins-base,plugins-good,plugins-bad,libav},
  v4l-utils
- U-Boot env access from Linux: u-boot-tools, libubootenv-tool
- Minimal utils: util-linux, e2fsprogs, psmisc, procps, less,
  curl, ca-certificates, busybox-static, locales

`--no-install-recommends` everywhere; `/usr/share/doc`, `/usr/share/man`,
non-`en` locales stripped via `dpkg path-exclude`.  Final rootfs tarball
~280-320 MiB compressed.

## Configuration

Per-build defaults live in `etc/`:

- `etc/default/tc8-kiosk` — `KIOSK_URL`, `KIOSK_ENGINE`, `COG_OPTS`,
  `CHROMIUM_OPTS`
- `etc/tc8-kiosk/weston.ini` — compositor config: kiosk-shell,
  `xwayland=false`, output rotation via `transform=rotate-90`
- `etc/systemd/system/{kiosk,kiosk-vt}.service` —
  kiosk-on-tty7 service (runs `kiosk-launch`, which starts weston with
  kiosk-shell and then the browser selected by `KIOSK_ENGINE`: cog by
  default, chromium when installed) + an explicit `chvt 7` helper
- `etc/udev/rules.d/{50-drm,70-seat}.rules` — gives the `kiosk` user
  group access to `/dev/dri/*` and seat-tags `/dev/input/event*` so
  libinput finds the Goodix touchscreen
- `etc/environment.d/99-vpu.conf` — biases GStreamer toward the
  v4l2 stateless decoders (Hantro G1/G2) over libav

Per-device values arrive via the config blob: the provisioning wizard
writes a blob to the `cache` partition and
`etc/tc8-config/apply-config.sh` applies it at boot, writing keys such as
`KIOSK_URL` into `/etc/default/tc8-kiosk` (contract:
`CONFIG-PARTITION.md` in `poly-firmware-build`).

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
- **Maintenance mode** — `tc8-rw [--reboot]` sets a sticky flag on
  facres (`/persist/.tc8-rootfs-rw`); the next boot mounts the rootfs
  direct-rw with **no** overlay, so `apt install` etc. are safe and
  permanent. `tc8-ro && reboot` reseals. `tc8-mode` reports the current
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

SSH host keys are generated at build (`ssh-keygen -A`, copied to
`/etc/ssh/baked/`) and are the same across every panel from one image.
Per-panel keys would need generating into persistent storage
(the `facres`/`persist` partition, which survives reflash).

## Known limitations

- No automatic touch calibration; final viewing rotation is the sum of
  the kernel cmdline `video=DSI-1:rotate=270` (panel mounted 270° from
  native) and weston's output rotation (`transform=rotate-90` in
  `etc/tc8-kiosk/weston.ini`). The compositor maps the single-output
  touch transform off the wayland output rotation. If you change either
  piece, re-run the orientation sweep with `smoke/orient.html` in
  `poly-firmware-build`.
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
profile, an isolated clone with the board-agnostic `poly-app-<name>`
metapackage installed from the
[OpenPolycom archive](https://github.com/Polycom-Open-Firmware/apt),
falling back to the legacy per-board `poly-<device>-profile-<name>` when
no `poly-app-<name>` exists — emitted as `out/rootfs-<name>.tar.gz` with
`TC8_PROFILE` stamped in `/etc/tc8-version`. `--device` picks the
fallback metapackage (`poly-tc8-profile-kiosk` vs
`poly-c60-profile-kiosk`); the composer (`poly-firmware-build`) passes it
from `--target`. `bare` = the untouched base; plain `rootfs.tar.gz`
aliases the default profile when that profile is built, otherwise it
packs the bare base. The archive keyring + sources.list are baked into
the base (`etc/apt/sources.list.d/poly.list`), so both image builds and
on-device `tc8-rw` maintenance installs resolve `poly-*` packages with no
setup. The device role at runtime is set from the config blob's `PROFILE`
key by `apply-config` (kiosk / dev / smart-speaker).
