# Tab S7 Mainline Linux — Bring-up Roadmap

Target device: the physical unit in hand is a Samsung Galaxy Tab S7 **LTE**
(`SM-T875`, codename `gts7l`/`gts7leea`) — confirmed via `adb` in
`../docs/device-state.md`. The Wi-Fi-only `SM-T870` (`gts7wifi`) may or may not
also be targeted; this needs an explicit decision (see cross-phase notes).
SoC: Qualcomm SM8250 "kona" / Snapdragon 865(+), Adreno 650.

**⚠️ Hard constraint on every phase:** this specific unit must never have its
anti-rollback (`rp`) counter advanced — no OTA, no Odin flash of any firmware
newer than the currently-installed `T875XXU1ATK4`. See
`../docs/device-state.md` for why and what that rules out. Any phase involving
`abl`/`xbl`/`vbmeta`/bootloader work must be checked against this before
flashing anything.

This is a living document. **Any agent instance picking up work here must
update this file** — tick checkboxes, move a phase's `Status` line, and append
an entry to that phase's `Progress log` before finishing a session. Do not
silently make progress without recording it here; the next instance has no
other way to know what's already true. See `../PORTING_ANALYSIS.md` for the
background/feasibility writeup this roadmap is based on, and
`../references/` for the prior-art repos.

## How to use this file

- Each phase has a `Status` line: `not started` / `in progress` / `blocked` /
  `done`.
- Checkboxes are exit criteria for that phase, not a task list — check one only
  when it's actually verified on hardware or otherwise confirmed true, not when
  code merely "should" work.
- `Progress log` entries are short, dated, and append-only (never rewritten or
  deleted) — same spirit as the reference project's `docs/porting-log.md`.
  Format: `- YYYY-MM-DD: <what happened, what was learned, what's next>`
- If a phase reveals that an earlier assumption in this roadmap was wrong,
  fix the roadmap in the same commit and say so in the log entry — don't leave
  stale plans around for the next instance to trip over.
- Detailed findings, driver-specific notes, and durable "don't repeat this"
  conclusions belong in `../docs/` (mirroring the reference project's
  `development-notes.md` / `hardware-status.md` split), not crammed into this
  file. Link to them from the relevant phase.

---

## Phase 0 — Reconnaissance and source acquisition

**Status:** not started

Goal: gather every piece of ground truth needed before writing a single line
of kernel code, and confirm (or correct) the assumptions in
`PORTING_ANALYSIS.md`.

Exit criteria:
- [ ] Samsung's official GPL kernel source release for `gts7`/`gts7wifi`
      obtained (opensource.samsung.com) and unpacked into `references/`.
- [ ] Exact PMIC, charger/fuel-gauge, touchscreen, Wi-Fi/BT, and panel part
      numbers identified from that source (board files / DTS / Kconfig), not
      guessed from marketing specs.
- [ ] Current state of SM8250 mainline Linux + postmarketOS support surveyed
      (`sm8250-mainline` community, OnePlus 8/8T/8 Pro, Poco F2 Pro trees) and
      the closest existing upstream board file identified as a starting DTS.
- [ ] Confirmed whether any existing mainline/postmarketOS port for `gts7`
      already exists anywhere (re-check beyond the initial search in
      `PORTING_ANALYSIS.md` — check postmarketOS wiki/gitlab directly, not just
      web search).
- [ ] Bootloader/partition recon on physical hardware: ABL log format,
      `param`/`vbmeta` behavior, Download/TWRP mode USB VID:PID identification,
      confirmed against `gts7` (do not assume the S9 Ultra project's exact
      offsets carry over — verify).
- [ ] A working TWRP (or equivalent custom recovery) confirmed available for
      the target `gts7` model/region, or a plan to build one.
- [ ] Unlocked bootloader + toolchain/build environment reproduced locally
      (cross compiler, WSL/Linux build host, `mmdebstrap` availability).

Progress log:
- (none yet)

---

## Phase 1 — Boot to a shell (no display, no peripherals)

**Status:** not started

Goal: mainline (or near-mainline) kernel boots on the Tab S7 far enough to get
a serial/USB shell — proof the boot chain, DTB, and minimal platform drivers
(clocks, RPMh, pinctrl, UFS) work.

Exit criteria:
- [ ] Devicetree for `gts7wifi` created (`kernel/dts/sm8250-samsung-gts7wifi.dts`
      or similar), derived from the closest upstream SM8250 board + Samsung's
      GPL source for regulator/pinctrl topology.
- [ ] Kernel builds and boots to an initramfs/console (UART or USB) on the
      physical tablet.
- [ ] UFS storage enumerates and is readable.
- [ ] Root filesystem reachable via ADB/serial shell, even without display.

Progress log:
- (none yet)

---

## Phase 2 — Display and input

**Status:** not started

Goal: get a usable framebuffer and touch input — the minimum for anything
interactive.

Exit criteria:
- [ ] DSI panel driver for the Tab S7's LCD panel (not OLED — expect a
      different driver family than the S9 Ultra's `ana38407`).
- [ ] KMS/DRM brings up the native panel resolution at the correct refresh
      rate.
- [ ] Touchscreen driver working (identify actual chip from Phase 0 recon;
      do not assume Goodix parity with the S9 Ultra).
- [ ] Adreno 650 GPU acceleration working (Mesa/Turnip or Freedreno, whichever
      mainline supports for this GPU generation).
- [ ] Basic GNOME/Wayland session reaches a usable desktop on-device.

Progress log:
- (none yet)

---

## Phase 3 — Core platform peripherals

**Status:** not started

Goal: the tablet is usable as a tablet — power, connectivity, audio, sensors.

Exit criteria:
- [ ] Charging + battery telemetry (PMIC/fuel-gauge driver identified and
      ported/written for the Tab S7's actual charger IC).
- [ ] Wi-Fi working.
- [ ] Bluetooth working.
- [ ] Speakers and microphone(s) working.
- [ ] Volume/power buttons working.
- [ ] Motion sensors (accelerometer/gyro, rotation) working.
- [ ] Suspend/resume cycle survives repeatedly without corruption (this bit
      the S9 Ultra project hard — see its `docs/resume-recovery.md` — budget
      real time for this).

Progress log:
- (none yet)

---

## Phase 4 — S Pen, cameras, and remaining hardware

**Status:** not started

Goal: everything else the hardware has, to the extent it's feasible.

Exit criteria:
- [ ] S Pen hover/pressure/tilt input (passive EMR digitizer — no BLE features
      expected; scope this down explicitly rather than assuming S9 Ultra
      parity).
- [ ] Cameras (front/rear) working via V4L2, to whatever extent the ISP allows
      under mainline.
- [ ] Fingerprint reader: **explicitly decide and record** whether the target
      SKU has one at all before doing any work here — most base Tab S7 units
      don't (see `PORTING_ANALYSIS.md` §4). If absent, mark this item N/A
      rather than leaving it unchecked forever.
- [ ] microSD and USB host (storage + HID) working.
- [ ] USB-C DisplayPort output working, if hardware supports it on this model.

Progress log:
- (none yet)

---

## Phase 5 — Userspace, packaging, and dual boot

**Status:** not started

Goal: turn a hand-booted hacked kernel + rootfs into something installable and
maintainable, matching the S9 Ultra project's user-facing shape.

Exit criteria:
- [ ] Ubuntu rootfs build reproducible via `mmdebstrap` + this repo's
      `packaging/`/`configs/`.
- [ ] Installer ZIP flashable from TWRP, tested on real hardware.
- [ ] Dual boot (Android kept alongside Ubuntu) working, with a toggle from
      both sides, following the S9 Ultra project's split-storage approach where
      applicable.
- [ ] Update mechanism (in-place system updates) working.
- [ ] "Tab Companion"-equivalent app scoped down to what actually applies to
      Tab S7 hardware (S Pen settings, keyboard remap if a cover keyboard
      exists for this model, dual-boot toggle; drop fingerprint/UDFPS-specific
      features that don't apply).

Progress log:
- (none yet)

---

## Phase 6 — Polish and documentation parity

**Status:** not started

Goal: bring the repo's documentation and hardware-status reporting up to the
same standard as the reference project, so it's maintainable by others.

Exit criteria:
- [ ] `docs/hardware-status.md` (component-by-component table with evidence)
      created and kept current.
- [ ] `docs/development-notes.md` (durable "don't repeat this" conclusions)
      created and kept current.
- [ ] `docs/porting-log.md` (chronological engineering history) created and
      kept current — this can absorb/replace the per-phase progress logs in
      this file once it exists, if that turns out to be less duplicative.
- [ ] Known issues documented.
- [ ] Licensing/provenance file for imported kernel sources
      (`kernel/PROVENANCE.md` equivalent) created and kept current as sources
      are imported.

Progress log:
- (none yet)

---

## Cross-phase notes

Anything that doesn't cleanly belong to one phase (recurring blockers, tooling
decisions, scope changes) goes here instead of being forced into a phase log.

- 2026-09-11: Device recon via `adb` on the physical unit (see
  `../docs/device-state.md`) shows it is the **LTE `SM-T875`/`gts7l`**, not the
  Wi-Fi-only `SM-T870`/`gts7wifi` this roadmap originally assumed. Open
  decision: target `gts7l` only, or also aim for `gts7wifi` parity? Until
  decided, treat `gts7l` (this physical unit) as the primary target and modem
  bring-up (`mdm`/RIL) as in-scope rather than out-of-scope.
- 2026-09-11: **Anti-rollback constraint is permanent for this unit** — owner
  wants to keep it on its original `T875XXU1ATK4` first-release firmware as a
  collector's device. `ro.boot.rp`/`androidboot.rp` = `1` currently. Never
  trigger an OTA and never Odin-flash a bootloader/`vbmeta`/AP package with a
  higher RP requirement than this. This bounds Phase 0 (recovery/TWRP
  selection) and Phase 5 (installer ZIP flashing) in particular — any
  candidate TWRP or flashing procedure must be vetted for RP impact before use
  on this device. Full detail in `../docs/device-state.md`.
- 2026-09-11: `getprop` and `/proc/cmdline` disagree on Knox warranty bit and
  verified-boot state on this unit (likely Magisk prop spoofing) — not yet
  independently confirmed via Download mode. Doesn't block bring-up work, but
  don't trust `getprop` alone for security-state questions on this device.
