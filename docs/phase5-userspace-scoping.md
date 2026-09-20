# Phase 5 scoping — Arch Linux ARM + KDE Plasma userspace (2026-09-20)

Scoping pass for Phase 5: turning the now-working kernel (display, touch,
GPU/Mesa-Freedreno all confirmed on hardware) into an actual bootable Arch
Linux ARM + KDE Plasma system. Read a real, mature reference project doing
almost exactly this - `references/ubuntu-galaxy-tab-s9-ultra/` (a sibling
Tab S9 Ultra Ubuntu port, `docs/boot-strategy.md`, `docs/dual-boot.md`,
`docs/ubuntu-userspace.md`) - before writing anything, the same way the
touchscreen and GPU work started.

## Guiding principle (borrowed directly, it's correct)

> The hardware is already solved in the kernel. [Userspace] must reinvent
> none of it: it contributes userspace only.

Kernel/boot work (this project's Phases 1-4) and userspace work (Phase 5)
are genuinely separate concerns. Nothing about Mesa/Freedreno, the touch
driver, or the panel depends on Ubuntu, Debian, or GNOME - all of it is
just as usable under Arch Linux ARM + KDE. Phase 5 should not require going
back and re-touching kernel work, only extending the boot chain to hand off
to a real root filesystem instead of the disposable busybox initramfs used
for testing so far.

## The big open decision: where does the Linux root filesystem live?

This is the one decision that has to be made *before* any implementation
work starts, and it's the one place this project's situation is genuinely
more constrained than the S9 Ultra reference project's.

### What the reference project does

S9U supports two installs, chosen by whether the disk has been "split":

1. **Whole-tablet**: reuse the existing `userdata` partition directly for
   the Linux root (`dd` an ext4 image into it, grow to fill on first boot).
   **The GPT is never touched** - no `sgdisk`/`parted`/`sfdisk`/`mkfs`/
   `wipefs` against the device at all (enforced by their own
   `scripts/validate-bundle.sh`). Cost: Android's user data in `userdata`
   is gone.
2. **Split (dual-boot)**: a dedicated installer shrinks `userdata` and
   creates a new `linuxroot` partition in the freed space (append-only,
   since `userdata` is the last partition on the disk - nothing else has
   to move). Cost: real GPT/PIT-level repartitioning, recoverable via
   Odin's **Re-Partition** option with the correct PIT file from the
   original CSC firmware, per their own recovery doc.

### Our real numbers

Checked this device's actual partition table via TWRP: `userdata` is
`/dev/block/sda37`, **112172012 KiB ≈ 107 GiB**, and it is the *last*
partition on the disk (128 GB unit total) - structurally identical to
S9U's layout, so the same "shrink the last partition, append a new one"
split pattern would work here too if we ever wanted it.

### Why this needs more caution here than on the S9U project

This unit's hard constraint (`device-state.md`, `flashing-plan.md`) is
stricter than anything S9U had to satisfy: **`rp` (anti-rollback) must
never advance, and the device must stay Odin-flashable back to
`T875XXU1ATK4` forever** - it's kept as a collector's item, not a daily
driver being permanently converted. Every flash this project has done so
far deliberately stayed inside `boot`/`recovery`/`vbmeta`/`dtbo` -
partitions with no anti-rollback assertion of their own - specifically to
keep that guarantee airtight.

GPT/PIT repartitioning is a different class of operation from anything
done so far. It doesn't touch `rp` directly (that's enforced via
`abl`/`xbl`/`tz`/`keymaster`/modem version checks, not the partition
table), and S9U's own experience says it's recoverable via Odin
Re-Partition + the stock PIT - but "recoverable in principle, confirmed by
someone else's tablet" is a materially weaker guarantee than "identical to
every flash already proven safe on this exact unit." It would need its own
dedicated verification pass (obtain and confirm the real `T875XXU1ATK4`
PIT file, back up this device's *current* GPT itself, prove a real Odin
Re-Partition round-trip) before ever being attempted - not something to
fold into a first Arch/KDE bring-up.

### Recommendation: start with the whole-tablet pattern, on `userdata`

Reuse `userdata` directly for the Arch root filesystem, exactly like
S9U's non-split path: **no `sgdisk`/`parted`/`mkfs` against the device's
GPT, ever, for this first pass.** This keeps Phase 5 bring-up inside the
same risk envelope every prior flash in this project has stayed within.

**This means accepting Android's user data (photos, installed apps,
accounts - whatever is currently on the tablet) will be gone once
`userdata` is reformatted for ext4.** `boot`/`recovery`/`vbmeta`/
`vbmeta_samsung`/`dtbo` stay fully restorable from the existing
`gts7l-STOCK-RESTORE-T875XXU1ATK4.tar` backup, and the GPT itself is
never modified, so "restore to a genuinely stock, Odin-flashable
`T875XXU1ATK4` state" remains exactly as true as it is today - that
guarantee was always about the firmware/bootloader chain, not about
preserving whatever happens to be in `userdata` right now. Still, this
is real, irreversible, user-visible data loss and a real decision the
owner should make explicitly, not something to do by default.

The dual-boot / split-partition approach (a real second `linuxroot`
partition, Android kept fully intact) is the better long-term shape and
matches what the roadmap's Phase 5 exit criteria already describe - just
not the first move. Once a whole-tablet Arch+KDE install is proven
working end-to-end, revisiting the split approach with its own dedicated
PIT/GPT-backup verification pass is the natural next step, the same way
this project always tests the safe/reversible version of something before
the higher-stakes one.

## Boot chain: actually simpler here than on the S9U reference

S9U's device uses Android boot header v4 (separate `boot`/`init_boot`/
`vendor_boot`/`dtbo` partitions, `APPEND_DTB_TO_KERNEL`/
`DISABLE_RUNTIME_DTBO` quirks to make their ABL accept a mainline DTB).
This device is simpler: boot header **v2**, a single combined `boot.img`
(kernel + ramdisk + DTB together, confirmed via every `magiskboot unpack`
this project has run all session), no separate `init_boot`/`vendor_boot`
at all. Our existing uniLoader-based chain (`kernel/uniloader/`) already
solves the "get a mainline kernel+DTB genuinely booting on this ABL" part
- proven repeatedly this session (display, touch, GPU all working through
it). **Phase 5 doesn't need a new boot chain, only a new *ramdisk
payload*** inside the same proven `boot.img`/uniLoader structure.

## What actually changes: the initramfs's job

Today, `kernel/initramfs/init` mounts `/proc`/`/sys`/`/dev`, runs some
Round-32-era USB-gadget-console diagnostics, and drops to an interactive
busybox shell - a disposable debug environment, never meant to be a real
init. For Arch+KDE, this needs to become a **real, minimal initramfs**
whose only job is:

1. Mount `/proc`, `/sys`, `/dev` (unchanged).
2. Find the real root filesystem by label/UUID (`blkid`, already present
   in the initramfs's busybox build) rather than a hardcoded device node -
   matches S9U's own "the initramfs looks for the root, by label" pattern,
   and survives whether root ends up on `userdata`/`sda37` now or a future
   dedicated `linuxroot` partition later without needing a rebuild.
3. `switch_root` into it, handing off to systemd as PID 1 (Arch's real
   init, not busybox `init`).

This is a genuinely different initramfs than today's, but a *smaller* one
- no more interactive shell, no more USB-gadget-console setup (that was
purely a Phase 1/2 bring-up debugging aid). The temporary `/lib/firmware`
addition made for the GPU bring-up test this session was itself a
bring-up-initramfs-only hack; once GPU firmware lives in the real Arch
root's own `/lib/firmware`, that addition goes away entirely.

## Building the rootfs: `pacstrap` via the same Docker/QEMU trick already proven

The reference project uses `mmdebstrap` (Debian-family) because it accepts
`--architecture=arm64` with `qemu-user-static` and needs no native arm64
host. The direct Arch equivalent is **`pacstrap`**, and this session
already proved the exact same underlying trick works on this host: Docker
with `--platform linux/arm64` (QEMU emulation, confirmed working when
cross-building the Mesa/kmscube GPU test bundle). An `arm64v8/archlinux`
(or the official Arch Linux ARM bootstrap tarball) container run the same
way can `pacstrap` a real Arch ARM root filesystem, with `--customize-hook`-
style package injection done via a scripted container invocation - never
by hand-editing a live install afterward, matching S9U's "never an
unrepeatable installation" principle.

Mirror: Arch Linux ARM's own repos (`http://mirror.archlinuxarm.org/...`),
not regular Arch's x86_64 mirrors.

**Package firmware is only part of the story**: `a650_gmu.bin`/
`a650_sqe.fw` are generic and likely available via Arch's own
`linux-firmware`-equivalent package; the **zap shader is not** - it's
device-signed, pulled from this specific unit's own `apnhlos`/`vendor`
partitions (already done, sitting in `work/gts7l-firmware/`, gitignored
since it's a device-specific proprietary blob, not something to publish).
It needs to be injected into the built rootfs image as a one-off
overlay/customize-hook step, the same way this session staged it into the
bring-up initramfs - just landing in the real root's `/lib/firmware/qcom/
sm8250/samsung/gts7l/` instead this time.

## Validation order: console → (network) → desktop, not desktop first

S9U's own milestone order - a system that boots with a console and SSH
*before* the desktop is even attempted - is the right instinct and matches
this project's whole "prove the smaller thing works before building on top
of it" pattern (exactly how touch and GPU were each de-risked this
session: bus enumeration before a real driver, `kmscube` before a full
compositor). Concretely, for us:

1. Real Arch rootfs on `userdata`, real initramfs `switch_root`s into it,
   systemd reaches a multi-user console target. No desktop packages
   installed yet. Serial console (already the sole debug channel this
   entire project has relied on) is how this gets confirmed, the same way
   every kernel milestone so far has been checked.
2. Basic input/output confirmed from inside a real Arch userspace, not
   just the bring-up busybox shell - re-run the same kind of check this
   session did manually (touch events readable, `renderD128` present).
3. **Then** KDE Plasma - and even that in stages, matching the
   `egltest` → `kmscube` → full desktop escalation this session already
   used for the GPU: a bare `kwin_wayland --drm` nested/standalone session
   before a full Plasma + SDDM login flow, so a failure at the compositor
   level is distinguishable from a failure somewhere in Plasma's own
   session machinery.

Network access (Wi-Fi via `ath11k`, Phase 3, not started yet) is *not* a
blocker for any of this - `pacstrap` runs on the host, the whole rootfs
image is built and transferred as one artifact (matching S9U's "boot
images and rootfs both arrive as a single flashable ZIP" pattern), so a
first, fully offline Arch+KDE boot is achievable before Phase 3's
networking work is done at all. Package updates/`pacman -Syu` on-device
obviously do need it eventually, but that's follow-on work, not a
gate on first boot.

## Real open questions, not yet resolved

- **Exact confirmation of the storage decision above** - this is a real
  choice for the owner, not something to default silently. Whole-tablet
  `userdata` reuse is the recommended first move, but it's irreversible
  for whatever's currently on the tablet's Android side.
- Whether this device's `boot`/ABL chain has any equivalent to S9U's
  "cold hand-off leaves the panel unreachable until one suspend/resume
  cycle" quirk. Nothing like that has been observed in this project's own
  testing so far (display has come up cleanly every time), but it's the
  kind of thing that only shows up once a real display-manager/compositor
  startup sequence is exercised, not a bring-up initramfs's one-shot
  framebuffer console.
- Exact `systemd`/kernel-lockdown implications, if any, for out-of-tree or
  hand-patched kernel modules this project may eventually need (S9U flags
  this as a real gotcha for their ath12k modules) - not yet relevant since
  this project's kernel work so far has stayed in-tree/built-in
  (`CONFIG_DRM_MSM=y` forced on, no external modules), but worth watching
  once Phase 3 peripheral drivers are added.
- Real size budget for the Arch+KDE image (S9U's Ubuntu-minimal-desktop
  install budgets meaningfully more than the ~600 MB `cache` partition
  used for this session's disposable GPU test) - `userdata`'s ~107 GiB is
  vastly more than enough either way, so this isn't a real constraint, just
  unconfirmed exact numbers.

## Suggested next step when this work actually starts

1. Get the owner's explicit decision on the storage question above.
2. Build a minimal (console-only, no desktop) Arch Linux ARM rootfs via
   `pacstrap` under Docker's arm64 QEMU emulation, matching this session's
   already-proven cross-build technique.
3. Rewrite `kernel/initramfs/init` into a real, minimal `switch_root`-based
   initramfs.
4. Get systemd reaching a console target on real hardware - console/serial
   verification first, exactly like every other Phase so far.
5. Only then layer on KDE Plasma, tested in stages (bare KWin session
   before full Plasma+SDDM).

## Status: real boot achieved on hardware (2026-09-20)

Steps 1-2 from the suggested next-step list above are done: a minimal
Arch Linux ARM console rootfs is built and boots for real on hardware
(genuine `archlinux login` prompt, `systemctl is-system-running` →
`running`), on `userdata` reused directly as recommended (GPT never
touched). Full story, including two real bugs found and fixed along the
way, is in `docs/kernel-boot-debugging.md`'s "Phase 5: first real Arch
Linux ARM boot on hardware" section. Also worth correcting here: this
scoping pass never looked into the fingerprint reader question - a
separate stock-firmware-dump pass found this device does have one
(Goodix GW3X, power button), contrary to an earlier kernel-source-only
check.

## Status: KDE Plasma working on hardware too (2026-09-20)

Steps 4-5 are done as well - a real KDE Plasma Wayland session, confirmed
by the owner watching the physical screen, reproducible from a genuine
cold boot with zero manual intervention (SDDM autologin). Getting there
needed real USB-Ethernet internet sharing (`pacman` doesn't work over a
plain point-to-point link), a real debugging detour through KWin's
seat/VT handling (SSH sessions have no seat - a display manager, not
manual `openvt`/`setsid` tricks, is the actual right fix), and safely
isolating a hard, watchdog-triggered reset down to a single environment-
propagation bug (`QT_QPA_PLATFORM` never reaching a D-Bus-activated
service). Full story: `docs/kernel-boot-debugging.md`'s "KDE Plasma: a
real desktop, on real hardware" section. Nothing left open from this
scoping document - what remains (audio, real input devices beyond
touch, packaging this into a repeatable `packaging/` directory) is
Phase 3/4 and general polish work, not Phase 5 scoping gaps.
