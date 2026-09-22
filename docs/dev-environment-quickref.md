# Dev environment quick reference

A fast-start reference for a new session on this project, so you don't have
to reconstruct connection/build details from `docs/kernel-boot-debugging.md`'s
full chronological log (5800+ lines as of 2026-09-20). If anything here
disagrees with that log, the log is authoritative (this file summarizes it)
- fix this file, don't trust it blindly.

## ⚠️ The one rule that overrides everything else

This device (`SM-T875`/`gts7l`) is being kept as a **collector's item on its
original `T875XXU1ATK4` firmware forever**. `ro.boot.rp` (anti-rollback
eFuse counter) is currently `1` and **must never advance** - it's a one-way,
hardware-level burn. Practical effect: **only ever touch the `boot` partition
and the userdata-backed Arch rootfs.** Never flash `abl`, `xbl`, `xbl_config`,
`tz`, `hyp`, `keymaster`, `vbmeta*`, `modem*`, `param`, `persist*`, or the
GPT itself, and never let the device check for an OTA. See
`docs/device-state.md` for the full detail. Every flash in this project's
history has verified `getprop ro.boot.rp` / `ro.bootloader` unchanged both
immediately before and immediately after writing `boot`, and you should too.

## Two device states, two access methods

The device is always in exactly one of these; ask the user to confirm which
before doing anything device-facing (you cannot tell from software state
alone without asking, and getting this wrong wastes a round-trip):

### 1. TWRP (recovery)

- Confirm with `adb devices` - shows `recovery`, not `device`, next to the
  serial.
- Used for: pushing/flashing a new `boot.img`, and for one-time setup that
  writes directly to the `archroot`/`userdata`-backed partition.
- `adb shell` gets you a root shell in TWRP's own busybox environment, not
  the real Arch rootfs.

### 2. Booted into Arch Linux (normal boot)

- Not visible to `adb` at all once fully booted - this project's `boot.img`
  runs a mainline kernel + Arch userspace, not stock Android, so there's no
  ADB daemon.
- Real access is a point-to-point **USB Ethernet (ECM) gadget**, brought up
  automatically by `usb-gadget-ecm.service` (installed on the Arch rootfs,
  `/usr/local/bin/usb-gadget-ecm.sh`) on every boot:
  - Device static IP: `172.16.42.1`
  - Host static IP: `172.16.42.2`
  - SSH in with the project's dedicated key:
    ```
    ssh -i ~/.ssh/id_ed25519_gts7l -o BatchMode=yes root@172.16.42.1
    ```
  - Password root login is also enabled (`/etc/ssh/sshd_config.d/`) as a
    fallback, but the key is the normal path. Both `root` and `alarm`'s
    password is `make.believe` (2026-09-22, baked into
    `work/archroot-build/archroot-rootfs-v3.tar` onward).
  - Internet access on-device works via NAT: the host does
    `iptables -t nat -A POSTROUTING -s 172.16.42.0/24 -o wlan0 -j MASQUERADE`
    plus `ip_forward=1`, and the device gets a default route via
    `172.16.42.2` and a plain `1.1.1.1` resolver - both brought up
    automatically by the same systemd service, guarded by a ping check so
    it's a no-op if the debug cable isn't attached. **The host-side NAT
    rule is not persistent** - it has to be re-run (as root, on the
    host) after every host reboot:
    ```
    sudo sysctl -w net.ipv4.ip_forward=1
    sudo iptables -t nat -A POSTROUTING -s 172.16.42.0/24 -o wlan0 -j MASQUERADE
    sudo iptables -A FORWARD -i enp0s20f0u3 -o wlan0 -j ACCEPT
    sudo iptables -A FORWARD -i wlan0 -o enp0s20f0u3 -j ACCEPT
    ```
    (the USB gadget interface name varies by host - check `ip addr`
    for the `172.16.42.2/24` interface if not `enp0s20f0u3`).
  - **No RTC** - the device's clock is always stuck at 1970-01-01 on a
    fresh boot, which breaks `pacman`'s PGP signature checks (looks
    like "corrupted package (PGP signature)" but is really a clock
    problem). `systemd-timesyncd` is enabled and self-corrects once the
    device has a real route/DNS, but if you need `pacman` to work
    *before* that (or the fix hasn't landed on the running instance
    yet), set the clock manually first: `date -u -s 'YYYY-MM-DD
    HH:MM:SS'`.
  - **Known flaky bit**: the default route on the device side sometimes
    races against interface bring-up and doesn't get set, causing DNS/
    internet failures right after boot even though the point-to-point link
    itself is fine. Fix from the device shell if this happens:
    `ip route add default via 172.16.42.2 dev usb0`.
  - **Known flaky bit**: a *live-following* SSH session
    (`journalctl -k -f`) does not reliably show a crash as it happens, and
    does not reliably error out either - it can go silently stale (TCP
    just stops delivering data, no FIN/RST) exactly when the device
    crashes. Don't rely on it for real-time crash monitoring; `kill` the
    stale process and use post-crash forensics instead (next section).
  - Host-side NetworkManager will fight you for the `usb0`/gadget
    interface unless you give it a persistent static-IP connection
    profile (a bare `ip addr add` gets silently reset) and a `conf.d`
    drop-in telling it to leave the device side alone.

## Crash forensics: pstore/ramoops

A hard lockup/hard reset kills the device before a normal panic can flush
to the journal. `sm8250-samsung-common.dtsi` already has a real
`ramoops@9fa00000` node (1MB, `no-map`) inherited for free - the fragment
just needed `CONFIG_PSTORE=y` / `CONFIG_PSTORE_RAM=y` / `CONFIG_PSTORE_CONSOLE=y`
added (done, in `kernel/config/gts7l.fragment`).

- Normal path after a reboot: `dmesg | grep -i ramoops` /
  `/sys/fs/pstore/console-ramoops-0`.
- **A real hard lockup's abrupt reset frequently leaves the persistent-RAM
  header torn** (`ramoops: found existing invalid buffer, size X, start Y`
  with `Y > X`) - a non-atomic-header-update-vs-abrupt-reset race, not a
  bit-flip, so ECC wouldn't fix it. When this happens, pstore's own driver
  refuses to expose the (probably still largely intact) data at all.
- Manual recovery (requires `# CONFIG_STRICT_DEVMEM is not set`, already
  set in the fragment): the ramoops region is `no-map`, so a plain
  `dd if=/dev/mem` / `read()`-based access fails with `Bad address` (no
  linear-map entry for `no-map` memory). Use `mmap()` instead, which
  doesn't need the linear map (same technique the kernel's own `ioremap()`
  users rely on):
  ```python
  import mmap, os
  fd = os.open('/dev/mem', os.O_RDONLY)
  m = mmap.mmap(fd, 0x100000, mmap.MAP_SHARED, mmap.PROT_READ, offset=0x9fa00000)
  open('/tmp/ramoops_raw.bin', 'wb').write(m.read(0x100000))
  ```
  Run this over SSH, `scp` the result to the host, then
  `strings -n 6 -t d ramoops_raw.bin` and manually reconstruct - expect
  real bit-level corruption requiring careful cross-referencing (this
  worked well enough to recover a full, if line-mangled, panic backtrace
  once already; see `docs/kernel-boot-debugging.md`'s 2026-09-20/21
  entries).
- **Caveat found 2026-09-21**: this physical RAM region is not cleared by
  a warm/`PS_HOLD` reset - a raw dump can contain leftover fragments from
  *old stock-Android boots* (literal `HidlServiceManagement` lines showed
  up) mixed in with current-session data. Don't assume everything in the
  dump is from the crash you're investigating; cross-check timestamps and
  content plausibility.

## Standard build → flash pipeline

Round-trip, used identically every time a kernel/DTS change needs testing:

1. Edit `kernel/config/gts7l.fragment` and/or
   `kernel/dts/sm8250-samsung-gts7l.dts`.
2. Copy the DTS into the build tree:
   ```
   cp kernel/dts/sm8250-samsung-gts7l.dts work/linux/arch/arm64/boot/dts/qcom/sm8250-samsung-gts7l.dts
   ```
3. In `work/linux`:
   ```
   make ARCH=arm64 LLVM=1 defconfig
   ./scripts/kconfig/merge_config.sh -m .config ../../kernel/config/gts7l.fragment
   make ARCH=arm64 LLVM=1 olddefconfig
   ```
   **Always grep the resulting `.config` for the symbols you just touched**
   - this project has repeatedly hit a "tristate ceiling" gotcha where
   forcing a child symbol `=y` silently gets capped back to `=m`/unset by an
   unrelated-looking parent Kconfig dependency (documented at length in
   `docs/kernel-config-notes.md` and throughout `kernel-boot-debugging.md`).
   Don't trust `olddefconfig`'s silence as confirmation.
4. If the DTS changed:
   ```
   make -j20 ARCH=arm64 LLVM=1 LLVM_IAS=1 dtbs
   ```
   Confirm zero DTC warnings.
5. Build the kernel (slow, runs in background):
   ```
   make -j20 ARCH=arm64 LLVM=1 LLVM_IAS=1 Image
   ```
6. **Mandatory three-way copy, verified by `md5sum`** (forgetting this once
   silently flashed a stale DTB and wasted a whole round):
   ```
   cp work/linux/arch/arm64/boot/Image kernel/uniloader/blob/Image
   cp work/linux/arch/arm64/boot/dts/qcom/sm8250-samsung-gts7l.dtb kernel/dts/sm8250-samsung-gts7l.dtb
   cp work/linux/arch/arm64/boot/dts/qcom/sm8250-samsung-gts7l.dtb kernel/uniloader/blob/dtb
   ```
7. Rebuild uniLoader (bakes `blob/Image` + `blob/dtb` into one self-contained
   binary via `incbin`):
   ```
   cd kernel/uniloader && make ARCH=aarch64 LLVM=1
   ```
8. Package: unpack a stock template `boot.img`
   (`work/round48-build/new-boot.img`, byte-identical stock base kept around
   for exactly this purpose) with
   `work/twrp/external/magisk-prebuilt/prebuilt/magiskboot_x86_64`, replace
   **only** the `kernel` component with the freshly built `uniLoader` binary
   (leave `dtb`/`ramdisk.cpio` stock, untouched), repack.
   - Note: `magiskboot unpack` on one of *our own* previously-packed images
     mis-detects uniLoader's internal blob layout and auto-splits it into
     `kernel` + `kernel_dtb` files - this is just its own confused
     heuristic, not meaningful data. Always unpack the **stock template**,
     not a previous round's own output, to avoid this.
9. **MANDATORY: verify the packaged image is exactly `71303168` bytes**
   before touching the device at all - the `boot` partition has a hard,
   confirmed, zero-headroom size ceiling at this value (one past round
   overflowed by ~800KB and had to be aborted).
10. With the device in TWRP (`adb devices` shows `recovery`):
    ```
    adb shell getprop ro.boot.rp        # confirm still 1, before
    adb shell getprop ro.bootloader     # confirm still T875XXU1ATK4, before
    adb push new-boot.img /sdcard/new-boot.img
    adb shell md5sum /sdcard/new-boot.img   # compare to local md5sum
    adb shell "dd if=/sdcard/new-boot.img of=/dev/block/by-name/boot bs=4096 && sync"
    adb shell "dd if=/dev/block/by-name/boot bs=4096 count=17408 2>/dev/null | md5sum"  # readback, compare
    adb shell getprop ro.boot.rp        # confirm still 1, after
    adb shell getprop ro.bootloader     # confirm still T875XXU1ATK4, after
    ```
11. Ask the user to reboot and confirm which state they land in ("in twrp" /
    "in linux").

## Where things live

- `kernel/config/gts7l.fragment` - tracked Kconfig fragment, merged onto
  plain arm64 `defconfig`. Every symbol change has a dated comment
  explaining why - keep that pattern up.
- `kernel/dts/sm8250-samsung-gts7l.dts` - tracked devicetree source.
- `kernel/uniloader/` - the small ABL-facing loader that's actually placed
  in the Android boot image's `kernel` slot; it unpacks the real kernel
  Image + DTB (baked in from `blob/`) and jumps to them.
- `kernel/patches/000N-*.patch` - tracked patches against upstream driver
  sources in `work/linux` for changes too invasive for a Kconfig/DTS
  fragment (e.g. touch firmware flash timing, MAX77705 PASS2 fix). A
  pending one as of 2026-09-21: the DPU frame-event queue size bump in
  `work/linux/drivers/gpu/drm/msm/disp/dpu1/dpu_crtc.h` has **not yet**
  been captured as a tracked patch file.
- `work/` - gitignored scratch (build trees, TWRP/magisk tooling,
  per-round build artifacts under `work/roundNN-build/`). Nothing here is
  durable; don't rely on any specific round's directory surviving.
- `docs/kernel-boot-debugging.md` - the full chronological engineering
  log, one entry per real finding/test. This file is a summary pointer
  into it, not a replacement.
- `plans/roadmap.md` - phase-level plan and cross-phase progress notes.

## Known-good baseline vs. current experimental state

As of 2026-09-21, `boot` has a kernel with `CONFIG_ARM64_PSEUDO_NMI=y` and
the `irqchip.gicv3_pseudo_nmi=1` bootarg **active** (not just built-in) -
this carries a real ~5% runtime cost while flashed. See
`docs/kernel-boot-debugging.md`'s "Crash investigation" entries and
`docs/crash-investigation-nmi-research.md` for why. **Revert
`CONFIG_CMDLINE`'s `irqchip.gicv3_pseudo_nmi=1`** (and optionally
`CONFIG_ARM64_PSEUDO_NMI` itself) once the crash investigation concludes,
so normal use doesn't permanently pay this cost.
