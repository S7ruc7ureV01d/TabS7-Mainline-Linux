# Tab S7 Mainline Linux — Bring-up Roadmap

Target device: **primary target is the physical unit in hand**, a Samsung
Galaxy Tab S7 **LTE** (`SM-T875`, codename `gts7l`/`gts7leea`) — confirmed via
`adb` in `../docs/device-state.md`, bootloader unlocked, Knox tripped. The
Wi-Fi-only `SM-T870` (`gts7wifi`) is a **desired future target, not blocking**
— design DTS/drivers to be extensible to it where cheap to do so, but don't
delay `gts7l` bring-up waiting for `gts7wifi` hardware/parity.
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
- [x] Samsung's official GPL kernel source release for `gts7l`/`SM-T875`
      obtained and cloned into `references/gts7l` (a community re-host of
      Samsung's `SM-T875_QQ_Opensource.zip`, bootloader `T875XXU1ATK1` — close
      to but not byte-identical to our unit's `T875XXU1ATK4`; see caveat in
      `../docs/hardware-inventory.md`). `gts7wifi`'s equivalent not yet
      obtained — not blocking since `gts7l` is primary target.
- [x] Exact PMIC, charger/fuel-gauge, touchscreen, Wi-Fi/BT, and panel part
      numbers identified from that source — **see
      `../docs/hardware-inventory.md` for the full table.** Highlights:
      display+touch = Novatek NT36523 TDDI (panel `PPA957DB1`), S Pen = Wacom
      W90xx EMR, charger/fuel-gauge = Maxim MAX77705, core PMICs = standard
      Qualcomm PM8150+PM8009 (not Samsung-proprietary — easier than the S9
      Ultra's `sm5440`/`sm5714`), Wi-Fi/BT = Qualcomm QCA6390 (mainline
      `ath11k`, better positioned than the `ath10k`-class chip guessed
      earlier).
- [x] Current state of SM8250 mainline Linux + postmarketOS support surveyed,
      **and base board file chosen: see `../docs/kernel-baseline.md`.**
      `sm8250-mainline`'s `linux`/`pmos-pmaports` repos (cloned into
      `references/`) turned out to be a stale, non-Samsung-focused `v6.2`
      snapshot — checking current upstream `torvalds/linux` directly instead
      turned up an existing **Samsung SM8250 family base**
      (`sm8250-samsung-common.dtsi`, built on `pm8150.dtsi` — matching our
      confirmed PMIC) plus two Samsung phone boards (`r8q`/`x1q`, Galaxy
      S20/S20 FE). **Decision: fork `gts7l`'s DTS from
      `sm8250-samsung-common.dtsi`**, following the same
      `"samsung,gts7l", "qcom,sm8250"` compatible-string convention, rather
      than from any OnePlus/Xiaomi-oriented `kona` tree.
- [x] Confirmed (again, this pass) that no existing mainline/postmarketOS port
      for `gts7`/`gts7l` was found anywhere — remains a from-scratch bring-up.
- [x] Bootloader unlock state and Knox status confirmed: **unlocked, Knox
      `0x1`/tripped** (see `../docs/device-state.md`). ABL log format,
      `param`/`vbmeta` byte-level behavior, and Download/TWRP mode USB VID:PID
      identification still need hands-on confirmation against `gts7l` — don't
      assume the S9 Ultra project's exact offsets carry over.
- [ ] A working TWRP (or equivalent custom recovery) confirmed available for
      `gts7l`/`SM-T875`, vetted for anti-rollback (`rp`) safety before
      flashing (see the hard constraint at the top of this file), or a plan to
      build one.
- [x] Toolchain/build environment checked on the primary dev machine — see
      `../docs/build-environment.md`. **Already sufficient for an `LLVM=1`
      clang/lld kernel build**: `clang` 22.1.8, `lld`, `dtc`, `mkbootimg`,
      `bc`/`bison`/`flex`/`openssl`/`libelf`/`base-devel` all present, no GNU
      cross-`gcc` needed. 90G free disk space at time of check. `mmdebstrap`
      availability not yet checked (not needed until Phase 5).

Progress log:
- 2026-09-11: Chose the kernel baseline (upstream `sm8250-samsung-common.dtsi`)
  and confirmed the local build toolchain is ready — see
  `../docs/kernel-baseline.md` and `../docs/build-environment.md`. Phase 0 is
  now essentially complete except for the TWRP/recovery question. Next:
  actually fetch upstream Linux source at a recent tag and attempt a first
  `x1q`/`r8q`-equivalent build to prove the toolchain end-to-end before
  writing any `gts7l`-specific devicetree code (Phase 1).

---

## Phase 1 — Boot to a shell (no display, no peripherals)

**Status:** not started

Goal: mainline (or near-mainline) kernel boots on the Tab S7 far enough to get
a serial/USB shell — proof the boot chain, DTB, and minimal platform drivers
(clocks, RPMh, pinctrl, UFS) work.

Exit criteria:
- [ ] Devicetree for `gts7l` created (`sm8250-samsung-gts7l.dts`), forked from
      upstream's `sm8250-samsung-common.dtsi` per the decision in
      `../docs/kernel-baseline.md`, cross-checked against
      `references/gts7l/arch/arm64/boot/dts/samsung/gts7l/
      kona-sec-gts7l-eur-overlay-r07.dts` (the exact board-revision DTS
      matching our physical unit — see `../docs/hardware-inventory.md`) for
      regulator/pinctrl/GPIO topology.
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
- [ ] DSI panel driver for the **Novatek NT36523** driving the **PPA957DB1**
      WQXGA LCD panel (confirmed in `../docs/hardware-inventory.md`; reference
      implementation at `references/gts7l/techpack/display/msm/samsung/
      NT36523_PPA957DB1/`, needs a mainline DRM panel driver, not a straight
      port of that downstream one).
- [ ] KMS/DRM brings up the native panel resolution at the correct refresh
      rate.
- [ ] Touchscreen driver working — **same IC as the panel (Novatek NT36523
      TDDI)**, wired in DT as `novatek,nvt-ts`; reference driver at
      `references/gts7l/drivers/input/touchscreen/novatek/nt36523/`. Not
      Goodix — confirmed, no longer a guess.
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
- [ ] Charging + battery telemetry — charger/fuel-gauge/MUIC IC is confirmed
      **Maxim MAX77705** (`../docs/hardware-inventory.md`; reference driver at
      `references/gts7l/drivers/battery_v2/max77705_charger.c` +
      `max77705_fuelgauge.c`); core PMIC rails are standard Qualcomm
      **PM8150+PM8009**, which mainline `kona` support should already cover.
- [ ] Wi-Fi working — combo chip confirmed **Qualcomm QCA6390**, targeted by
      mainline `ath11k`.
- [ ] Bluetooth working — same QCA6390 combo chip as Wi-Fi.
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
- [ ] S Pen hover/pressure/tilt input — confirmed **Wacom W90xx-series EMR
      digitizer over I2C** (`../docs/hardware-inventory.md`; reference driver
      at `references/gts7l/drivers/input/wacom/wacom_i2c.c`), no BLE — scope
      confirmed, not just assumed.
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
      Tab S7 hardware (S Pen settings, keyboard remap — **confirmed**: this
      device has a real Book Cover Keyboard with a pogo-pin trackpad
      (`stm,touchpad`) and keypad (`stm,keypad`, labeled `"Tab S7 Book Cover
      Keyboard"` in DT) per `../docs/hardware-inventory.md` — plus dual-boot
      toggle; drop fingerprint/UDFPS-specific features that don't apply).

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
  Wi-Fi-only `SM-T870`/`gts7wifi` this roadmap originally assumed. **Decided:**
  `gts7l` (this physical unit) is the primary target, modem/RIL bring-up
  in-scope; `gts7wifi` support is a desired future goal, not a blocker — keep
  it cheap-to-extend-to where it doesn't cost extra work, but don't gate
  progress on it.
- 2026-09-11: Owner confirmed physically: **Knox `0x1` (tripped/void)**,
  **bootloader unlocked**. This resolves the `getprop`-vs-`/proc/cmdline`
  discrepancy in `../docs/device-state.md` in favor of the `/proc/cmdline`
  reading (Magisk was spoofing `getprop`). Practical effect: no separate OEM
  unlock step needed before Phase 0/1 flashing work — but the anti-rollback
  (`rp`) constraint below is unaffected by unlock state and still applies in
  full.
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
- 2026-09-11: Found and cloned Samsung's actual GPL kernel source for
  `gts7l`/`SM-T875` (`references/gts7l`), plus the `sm8250-mainline` org's
  `linux` and `pmos-pmaports` repos. Extracted confirmed hardware identity for
  every major component (panel/touch, S Pen, charger/PMIC, Wi-Fi/BT, keyboard
  cover) — written up in `../docs/hardware-inventory.md`, with Phase 0-4 exit
  criteria above updated to cite it instead of guessing. Big positive
  surprise: core PMIC rails are standard Qualcomm silicon (not a
  Samsung-proprietary PMIC needing a from-scratch driver like the S9 Ultra
  project needed), and Wi-Fi/BT (QCA6390) has real mainline `ath11k` support.
  Next up: pick the closest `sm8250-mainline/linux` board file to fork for
  Phase 1's DTS, and start on toolchain/build-environment setup.
