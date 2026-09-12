# Phase 1 Boot Testing — Kernel + Initramfs + Boot Image

Recorded: 2026-09-12. This builds a complete, self-contained bootable
artifact for `gts7l` ahead of any actual hardware test, so that when
flashing does happen it's a matter of using something already built and
understood, not scrambling to assemble it live. Nothing has been flashed to
the physical tablet as part of this work.

## What was built

1. **A static `busybox` binary for aarch64**, compiled from source
   (`busybox-1.36.1`) against a self-contained musl cross toolchain
   (`musl.cc`'s `aarch64-linux-musl-cross`, downloaded rather than requiring
   a system package install — the machine had no `sudo` access available in
   this session). Verified `static-pie linked, stripped` via `file`. This
   gives us an auditable, from-source init environment rather than trusting
   a random prebuilt binary off the internet — consistent with how this
   project has approached the kernel and TWRP builds.
2. **A minimal initramfs skeleton** (`kernel/initramfs/init`) — mounts
   `/proc`, `/sys`, `/dev`, prints kernel version and block device/partition
   info (so a first boot immediately tells us whether UFS enumerated), then
   drops to an interactive `ash` shell. This is deliberately not a real
   root filesystem — it exists purely to satisfy Phase 1's exit criteria
   ("boots to an initramfs/console") and to give us a shell to poke around
   in on the very first boot attempt.
3. **The initramfs embedded directly into the kernel `Image`** via
   `CONFIG_INITRAMFS_SOURCE`, rather than packaged as a separate ramdisk
   file — simpler for a first test (one less moving part / file to keep in
   sync), verified by extracting `usr/initramfs_data.cpio` from the build
   tree and confirming our `init` script and all 403 busybox applet
   symlinks are actually present in it.
4. **A flashable `boot.img`** combining that kernel `Image` and our
   `kernel/dts/sm8250-samsung-gts7l.dtb`, built with `mkbootimg` using the
   same header conventions (`--header_version 2`, kernel/ramdisk/tags
   offsets, `--board SRPTC18C001`) as the `twrp_gts7l` device tree's
   `BOARD_MKBOOTIMG_ARGS` from `docs/twrp-build-notes.md` — verified by
   round-tripping it through `unpack_bootimg`, which confirms the DTB size
   (114780 bytes, matching our `.dtb` exactly) and kernel size line up
   correctly, `ramdisk size: 0` as expected since the initramfs is baked
   into the kernel itself rather than a separate ramdisk section.

Artifacts (gitignored, in `../artifacts/`, regenerate per this doc rather
than trusting a stale copy):
- `boot-test-gts7l.img` — the packaged boot image
- `busybox-aarch64-static` — the built busybox binary, for reference/reuse

## How to reproduce

```sh
# 1. Self-contained musl cross toolchain (no root needed)
curl -O https://musl.cc/aarch64-linux-musl-cross.tgz
tar xzf aarch64-linux-musl-cross.tgz

# 2. Build static busybox
curl -O https://busybox.net/downloads/busybox-1.36.1.tar.bz2
tar xjf busybox-1.36.1.tar.bz2
cd busybox-1.36.1
export PATH="$PWD/../aarch64-linux-musl-cross/bin:$PATH"
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-musl- defconfig
sed -i 's/^# CONFIG_STATIC is not set/CONFIG_STATIC=y/' .config
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-musl- oldconfig < /dev/null
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-musl- -j$(nproc)

# 3. Initramfs skeleton
mkdir -p initramfs/{bin,sbin,dev,proc,sys,etc,mnt,root}
cp busybox initramfs/bin/
( cd initramfs/bin && for a in $(./busybox --list); do ln -sf busybox "$a"; done )
cp <repo>/kernel/initramfs/init initramfs/init
chmod +x initramfs/init

# 4. Kernel build with initramfs embedded (same v7.2 tree used throughout
#    Phase 0/1 - see build-environment.md / kernel-config-notes.md)
cd <linux-tree>
make ARCH=arm64 LLVM=1 LLVM_IAS=1 defconfig
./scripts/kconfig/merge_config.sh -O . -m arch/arm64/configs/defconfig \
    <repo>/kernel/config/gts7l.fragment
sed -i 's|^CONFIG_INITRAMFS_SOURCE=.*|CONFIG_INITRAMFS_SOURCE="<path-to-initramfs>"|' .config
make ARCH=arm64 LLVM=1 LLVM_IAS=1 olddefconfig
cp <repo>/kernel/dts/sm8250-samsung-gts7l.dts arch/arm64/boot/dts/qcom/
# register it in arch/arm64/boot/dts/qcom/Makefile (dtb-$(CONFIG_ARCH_QCOM) += sm8250-samsung-gts7l.dtb)
make ARCH=arm64 LLVM=1 LLVM_IAS=1 -j$(nproc) Image dtbs

# 5. Package into a flashable boot.img
mkbootimg \
  --kernel arch/arm64/boot/Image \
  --dtb arch/arm64/boot/dts/qcom/sm8250-samsung-gts7l.dtb \
  --cmdline "console=ttyMSM0,115200n8 earlycon androidboot.hardware=qcom androidboot.console=ttyMSM0" \
  --base 0x00000000 --kernel_offset 0x00008000 --ramdisk_offset 0x02000000 \
  --tags_offset 0x01e00000 --dtb_offset 0x01f00000 --pagesize 4096 \
  --header_version 2 --board SRPTC18C001 \
  -o boot-test-gts7l.img
```

## Open item: the console/UART is a guess, not a confirmed fact

The cmdline above uses `console=ttyMSM0,115200n8` — `ttyMSM` is confirmed as
the correct *driver* name (`drivers/tty/serial/qcom_geni_serial.c`'s
`.dev_name = "ttyMSM"`), but **which physical UART instance is actually
wired to an accessible debug console on this specific tablet is not
confirmed**. Checked mainline's `sm8250.dtsi` and found **no `serial0` alias
defined at the SoC level** — board files that want a UART console define
their own `aliases { serial0 = &uartN; };` pointing at whichever GENI
instance their board wires out (e.g. `sm8250-hdk.dts` uses
`stdout-path = "serial0:115200n8"` with its own alias). Our
`sm8250-samsung-gts7l.dts` doesn't define this yet, and Samsung's GPL source
review hasn't identified which instance (if any) is exposed as a physical
debug UART on a retail Tab S7 — **retail tablets frequently don't expose one
at all without hardware modification (test points, disassembly)**, unlike
development boards.

**Practical implication:** `ttyMSM0` in the cmdline above is a
best-effort placeholder, not a confirmed console. If the first real boot
attempt shows nothing over whatever UART access exists (or none exists),
that's expected and not itself evidence of a failed boot — Phase 1's
"initramfs/console" exit criterion explicitly allows **USB** as the
alternative, which is more realistic for retail hardware (e.g. a USB
gadget serial console, `console=ttyGS0`, once USB device-mode is confirmed
working under our kernel config - not yet set up). This is tracked as a real
open item for whenever an actual boot attempt happens, not silently assumed
solved.

## Still not done

- **No hardware boot attempt.** Everything above is build-and-package-level
  validation (compiles, links, correct sizes/offsets on round-trip) exactly
  like the devicetree and kernel-config work before it — real behavior on
  the physical tablet is unknown.
- UFS enumeration and root-filesystem-reachable-via-shell (the remaining
  Phase 1 exit criteria) can only be confirmed once this boots on real
  hardware.
- The console/UART question above.
- Flashing this at all is still gated on the same considerations as the TWRP
  recovery: this is a `boot.img` for the `boot` partition specifically (not
  `abl`/`xbl`/`vbmeta`), which per `docs/device-state.md` should be
  RP-safe to flash and revert, but that reasoning hasn't been tested against
  real hardware in this project yet either.
