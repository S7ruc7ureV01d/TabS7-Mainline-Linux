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
- Getting there from Linux (DTS `&pon` reboot modes, 2026-09-24):
  `systemctl reboot --reboot-argument=recovery` over ssh as root (systemd 261 rejects the old positional form). On the tablet, use the "Reboot to
  Recovery" launcher (`tools/rootfs/recovery/`; right-click it for "Reboot
  to Download Mode"; it sets the argument through logind `SetRebootParameter`, which needs no password in the desktop session). `--reboot-argument=download` goes to Odin mode.

### 2. Booted into Arch Linux (normal boot)

- **Wi-Fi: static `<lan>.110`** (set 2026-09-24 at the owner's request,
  NetworkManager connection "<home-wifi>": gateway
  `<lan>.1`, DNS `<lan>.101`). The ath11k MAC is random every
  boot, so DHCP gave a new address each time. Not in the tarball.
  `ssh -i ~/.ssh/id_ed25519_gts7l root@<lan>.110`. If the PC loses
  its ARP entry (No route to host), ping the tablet until it answers,
  then keep the entry alive from the tablet:
  `systemd-run --unit=arpkeep --collect ping -i 2 -w 3600 -q <PC IP>`.

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
  - If the key is suddenly rejected (`Permission denied (publickey,...)`),
    check `/root/.ssh/authorized_keys` ownership: the v2-v4 rootfs
    tarballs shipped it owned by `alarm:alarm`, which sshd's StrictModes
    refuses for root. Log in with the password and
    `chown root:root /root/.ssh/authorized_keys`. Fixed in v5.
  - Password root login is also enabled (`/etc/ssh/sshd_config.d/`) as a
    fallback, but the key is the normal path. Both `root` and `alarm`'s
    password is `make.believe`. `alarm` has sudo via
    `/etc/sudoers.d/10-wheel` (`%wheel ALL=(ALL:ALL) ALL`, password
    required).
  - **Current rootfs tarball:**
    `work/archroot-build/archroot-rootfs-v13.tar` (2026-09-24, sha256
    `bc38d553047229322ae7b453cf286f4ff5799978de07fa9849be81b607d71467`).
    Lineage, each step a verified stream-rewrite of the previous one with
    Python's `tarfile` (GNU `tar --delete` corrupted this archive):
    - v5 = v4 + `authorized_keys` owned by root + `/etc/sudoers.d/10-wheel`
    - v6 = v5 minus `/.dockerenv`. That empty Docker build artifact made
      systemd think it was in a container (`systemd-detect-virt` said
      `docker`), which silently skipped timesyncd, systemd-pstore,
      random-seed, fstrim and ModemManager.
    - v7 = v6 + the RTC offset service (`tools/rootfs/rtc-offset/`),
      enabled
    - v8 = v7 + the SLPI sensor stack as running live:
      - `slpi.*` firmware;
      - hexagonrpcd, built from `tools/rootfs/hexagonrpcd/`;
      - the HexagonFS tree, with the SLPI-validated registry;
      - a `fastrpc` user/group (963), added to the four account files;
      - `slpi-start.service`, and `hexagonrpcd-sdsp.service` plus its
        drop-in;
      - udev rules 81/90.

      The build tools (base-devel/meson/git) used on the live install
      are *not* included.
    - v9 = v8 + the speaker audio setup as running live
      (`docs/phase3-audio-scoping.md` stages 4-4d):
      - `alsa-utils` (package files plus its pacman db entry; every
        dependency was already in v8);
      - firmware: `cirrus/cs35l41-dsp1-spk-prot-gts7l.{wmfw,bin}` (stock
        protection firmware) and `qcom/sm8250/samsung/gts7l/adsp.*`;
      - everything `tools/rootfs/audio/install.sh` installs: the gate,
        autosuspend and safe-state udev rules, `gts7l-audio-safe` plus
        its unit, the UCM profile, the WirePlumber sink rule and the
        PipeWire upmix;
      - `alsa-restore`/`alsa-state` masked, and no `asound.state`;
      - the current `slpi-start.service` (v8's didn't boot the ADSP).

      The owner's own apps installed since v8 (Krita, Telegram, Prism
      Launcher, dev tools, ...) are *not* included. Verified: 183431
      entries = v8 - 1 replaced + 134 added; the 6 capability xattrs are
      identical; all 124 new files match the device; GNU tar and bsdtar
      both read it cleanly.
    - v10 = v9 with the audio changes made after v9:
      - the UCM `Mic` device (`usr/share/alsa/ucm2/Samsung/gts7l/HiFi.conf`)
        and the WirePlumber rule pinning the mic source to S16
        (`51-gts7l-speakers.conf`), for the internal microphones (stage 5);
      - no `73-gts7l-cs35l41-autosuspend.rules`: kernel patch 0023 fixed
        the mailbox bug it worked around.

      Verified: 183430 entries = v9 - 1; capabilities identical; both
      files match the repo; GNU tar and bsdtar read it cleanly. It needs
      a kernel with patches 0018-0023 and the stage-5 DTS/config.

    - v11 = v10 + an 8 GiB swap file service (`tools/rootfs/swap/`,
      `gts7l-swapfile.service`, enabled): it creates `/swapfile` with
      `mkswap --file --size 8G` on first boot (not shipped in the tarball)
      and activates it. v11 does not yet include the camera, USB and
      microSD userspace installed live since v10 (libcamera stack, Kamoso,
      GStreamer PipeWire plugins, dosfstools/exfatprogs,
      `tools/rootfs/camera/`).
    - v12 = v11 with two boot fixes:
      - swap: `gts7l-swapfile.service` replaced by `swapfile.swap` plus
        `gts7l-swapfile-create.service` (`tools/rootfs/swap/`). The old
        service's `After=local-fs.target` made an ordering cycle
        (swap.target -> tmp.mount -> local-fs.target) that systemd broke
        by dropping a random job every boot: usually `tmp.mount` (so no
        tmpfs /tmp), once `local-fs.target`, and then the USB gadget,
        Wi-Fi rebind and DSP start never ran.
      - USB gadget (`tools/rootfs/usb/gadget/`, now tracked in the repo):
        if the UDC is missing or the port is in host mode at boot (a
        monitor or USB device attached), `usb-gadget-ecm-wait.service`
        binds it once the port reaches device mode.

      Verified: 183435 entries = v11 - 4 + 6; capabilities identical;
      the new files match the repo; GNU tar and bsdtar read it cleanly.
    - v13 = v12 + the port software installed live since v10, taken from
      the tablet with GNU tar (`--xattrs --numeric-owner`, only the listed
      entries):
      - 76 packages with their pacman db entries: the camera stack
        (libcamera, -ipa, -tools, pipewire-libcamera, gst-plugin-libcamera,
        gst-plugin-pipewire, gst-plugins-good, kamoso), dosfstools and
        exfatprogs (microSD), kdialog (recovery launcher), plasma-keyboard,
        spectacle, and their dependencies;
      - libssc 0.4.4-1.1 (`tools/rootfs/sensors/libssc/`, the
        ambient_light_v fallback) replacing 0.4.4-1;
      - `tools/rootfs/camera/` (focus service, enabled), `recovery/`, and
        `sensors/autobrightness/` (curve seeding, enabled for all users).

      Not included: the owner's apps (Krita, Prism Launcher, Telegram,
      Vesktop) and dev/debug tools (base-devel, git, meson, ninja,
      gobject-introspection, yay, fastfetch, tcpdump, libgpiod), and the
      static Wi-Fi setting. Verified: 189943 entries = v12 - 54 replaced
      + 6562 added, no duplicate names; capabilities identical; every file
      listed in all 741 pacman db entries is present; GNU tar and bsdtar
      read it cleanly.

    File capabilities (`kwin_wayland`, `newuidmap`, ...) are preserved
    byte-for-byte. Python tags two entries with a `hdrcharset=BINARY` pax
    keyword, which GNU tar ignores with a warning and bsdtar handles
    cleanly. TWRP's own tar hasn't been tried on v5+ yet. Only the current
    tarball and `ArchLinuxARM-aarch64-latest.tar.gz` (the upstream base)
    are kept.
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
  - **SLPI sensor DSP (2026-09-22):** firmware `slpi.mdt` + `slpi.b00`-`b20`
    lives on the rootfs in `/lib/firmware/qcom/sm8250/samsung/gts7l/`
    (copied from `work/stock-dump/dump/vendor-firmware_mnt-image/`;
    in tarball v8). `slpi-start.service` (`tools/rootfs/slpi/`)
    boots it after the rootfs is mounted. Check with
    `cat /sys/class/remoteproc/remoteproc0/state` and
    `python3 tools/rootfs/slpi/qrtr_lookup.py` (look for service 400).
    **Note:** the rootfs has no `/lib/modules`, so any `=m` kernel option
    is effectively absent; build what you need `=y`.
  - **Clock (2026-09-22):** the PM8150 RTC works (`CONFIG_RTC_DRV_PM8XXX=y`,
    `/dev/rtc0`) but is **read-only for Linux**. The PMIC arbiter refuses
    writes: `disallowed SPMI write to sid=0, addr=0x6046`. Its raw count
    is arbitrary (around 1971), so `rtc-offset.service`
    (`tools/rootfs/rtc-offset/`) keeps offset = real time - raw RTC in
    `/var/lib/rtc-offset/offset`. It restores time at boot, before
    timesyncd, and saves the offset every 15 min while NTP-synced and at
    shutdown - same idea as stock Android's time daemon.
    `systemd-timesyncd` does the actual syncing.
    **Don't set the time by hand in KDE's Date & Time settings or with
    `timedatectl set-time`:** either one silently turns NTP off
    (`systemd-timedated: Set NTP to be disabled`). If that happens, run
    `timedatectl set-ntp true`. A clock that jumps mid-session (for
    example 1970 -> now) also leaves KDE's app-launcher cache stale;
    `kbuildsycoca6` in the user session fixes it.
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
   **Also diff the result against the previous build's `.config`.** Since
   2026-09-23 a fresh defconfig plus fragment merge reproduces the
   working `.config` exactly (0 differing lines, "is not set" entries
   included). `PHY_QCOM_QMP_PCIE_8996`, `PHY_QCOM_QMP_USB` and `RTL_CARDS`
   (which a fresh merge used to make `=m`), `DETECT_HUNG_TASK` and
   `USB_QCOM_EUD` are pinned. To check without touching the tree's
   `.config`:
   `make ARCH=arm64 KCONFIG_CONFIG=/tmp/x/def.config defconfig`, then
   `scripts/kconfig/merge_config.sh -m -O /tmp/x /tmp/x/def.config
   ../../kernel/config/gts7l.fragment`, then
   `make ARCH=arm64 KCONFIG_CONFIG=/tmp/x/.config olddefconfig`, and diff.
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
   (`work/round-nothp-build/stock-template.img` - unpacks to Samsung's own
   `4.19.81-19993249` kernel; confirm with `strings -n 20 kernel | grep
   "Linux version"` after unpacking. **Not** `work/round48-build/new-boot.img`,
   which the older version of this line named: as of 2026-09-22 that file
   is one of our own packed images, and repacking from it overflowed the
   size ceiling below) with
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

**Alternative to step 10, from running Linux (used since 2026-09-24):** the
same `boot` partition is `/dev/sda23` (TWRP's `by-name/boot` points there
too). Check that `readlink -f /dev/disk/by-partlabel/boot` is `/dev/sda23`
and that its first 17408×4096 bytes md5 to the previously flashed image.
Then `scp` the image to `/tmp` and `dd if=/tmp/new-boot.img of=/dev/sda23
bs=4096 conv=fsync`, and read it back the same way. The new kernel runs
only after a reboot: check `uptime`/`/proc/version` before trusting a test.
No ABL/rp involvement: only `boot` is written, as in step 10.

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
  The DPU frame-event pool bump that used to live only in
  `work/linux` is captured as `0015-dpu-crtc-double-frame-event-pool.patch`
  (2026-09-22). The CPU hard-hang investigation's patches 0007-0009
  (genpd OSI backport, cluster/per-CPU idle-state disables) were removed
  from this directory and reverted in `work/linux` the same day; they're
  still in git history.
- `work/` - gitignored scratch (build trees, TWRP/magisk tooling,
  per-round build artifacts under `work/roundNN-build/`). Nothing here is
  durable; don't rely on any specific round's directory surviving.
- `docs/kernel-boot-debugging.md` - the full chronological engineering
  log, one entry per real finding/test. This file is a summary pointer
  into it, not a replacement.
- `plans/roadmap.md` - phase-level plan and cross-phase progress notes.

## Known-good baseline vs. current experimental state

As of 2026-09-22 (evening), `boot` carries a **clean, non-debug kernel**
(build #95). The CPU hard-hang is fixed: the DTS memory node now matches
ABL's two real ranges, so the 52 MiB non-RAM hole at `0xbcc00000` is no
longer handed out as RAM (`kernel-boot-debugging.md`, "CPU hard-hang,
root cause found"). All of the investigation's overhead has been removed:
- the pseudo-NMI bootarg and Kconfig, and `rootflags=nodelalloc`
- ftrace/irqsoff, `STRICT_DEVMEM=n`, EUD, and the `qcom_scm` tracing
- THP=n (THP is back to defconfig's `always`)
- patches 0007-0009 (all CPU idle states are active again)

This build was verified with the 1500M/3000M/4600M-OOM `vmstress` runs and
a Minecraft soak. Pstore/ramoops, zram (driver only), BWMON, OSM L3 and
Round 24's lockup-panic Kconfig are intentionally kept.

Regenerating `.config` from defconfig + fragment still changes three
symbols from the known-good build (see step 3 above). This round was built
from the previous `.config` plus `scripts/config` edits for exactly that
reason.
