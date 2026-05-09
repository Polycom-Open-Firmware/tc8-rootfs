# initramfs

Slot-aware busybox initramfs.  Boots first, picks the active A/B slot
from the kernel command line, mounts the matching ext4 root, and
`switch_root`s into it.

## What `init` does

1. Mounts `/proc`, `/sys`, `/dev`.
2. Reads `/proc/cmdline`, looks for `androidboot.slot_suffix=_a` or `_b`.
3. Maps slot to root device:
   - `_a` -> `/dev/mmcblk2p5`
   - `_b` -> `/dev/mmcblk2p6`
   - missing/unknown -> falls back to `_b` with a warning.
4. Waits up to 5 s for the block device node to appear.
5. `mount -o rw $ROOT /sysroot`.  On failure, drops to a busybox shell.
6. Unmounts `/proc /sys /dev`, then `exec switch_root /sysroot /sbin/init`.

## Build

```
BUSYBOX=/path/to/busybox-static ./initramfs/build.sh
```

Or run the top-level `./build.sh`, which builds the rootfs first and
then calls this script with `BUSYBOX=work/rootfs/usr/bin/busybox`.

Output: `out/initramfs.cpio.gz`.

## Applets baked in

`sh mount umount mkdir cat grep sed cp ls switch_root sleep echo cut tr`
(symlinks to `/bin/busybox`).
