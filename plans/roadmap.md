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

**Status:** in progress (all research-only exit criteria met; recovery
choice and actual toolchain fetch/first-build still pending)

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
- [x] **A working TWRP for `gts7l` has been built from source.** Resolved by
      building option 3 from `../docs/recovery-options.md` (the two stale
      source-only device trees named exactly for `gts7l`), rather than
      trusting either community prebuilt (wrong variant / firmware-update
      requirement conflicting with the RP constraint). Full build process,
      two real bugs found and fixed in the 2020-era device tree, and what's
      still unverified, in `../docs/twrp-build-notes.md`; what's committed
      vs. not in `../recovery/PROVENANCE.md`. Result:
      `../artifacts/twrp-gts7l-unofficial.img` (73MB, valid Android bootimg,
      built clean in 15:22) plus a matching AVB-disabled
      `../artifacts/vbmeta_disabled.img`. **Not yet flashed to the physical
      device or boot-tested** — this is a built-and-audited artifact, not a
      confirmed-working recovery. The flashing decision itself remains the
      owner's call given the anti-rollback constraint, same as before.
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
  now essentially complete except for the TWRP/recovery question.
- 2026-09-11: **First proof-of-toolchain build succeeded.** Shallow-cloned
  upstream Linux `v7.2` into `work/linux` (gitignored scratch space) and ran
  `make ARCH=arm64 LLVM=1 LLVM_IAS=1 defconfig && make ... -j20 Image dtbs`.
  Clean build, zero warnings, `Image` produced, both `sm8250-samsung-r8q.dtb`
  and `sm8250-samsung-x1q.dtb` compiled successfully — confirms the chosen
  kernel baseline and local toolchain work end-to-end before any
  `gts7l`-specific code is written. Full details in
  `../docs/build-environment.md`, including a process note about a false
  "build complete" notification from a `nohup`-backgrounded process that's
  worth remembering for future long builds. Phase 0 is now fully done except
  for the TWRP/recovery decision (which is intentionally left open for the
  owner, not blocking Phase 1 kernel-side work). Next: start Phase 1 for
  real — write `sm8250-samsung-gts7l.dts` forked from
  `sm8250-samsung-common.dtsi`.
- 2026-09-11: Surveyed TWRP/custom-recovery options for `gts7l` — see
  `../docs/recovery-options.md`. No option is a risk-free "just flash it":
  an actively maintained prebuilt TWRP exists but for the wrong model variant
  (T870, not our T875 — different partition table); a currently-active
  project (TerracottaROM) explicitly supports `gts7l` but its install
  guidance says to update to "latest stock firmware" first, which conflicts
  with the anti-rollback constraint and needs checking rather than trusting;
  two stale source-only device trees named exactly for `gts7l` could be built
  from scratch as a fully-audited fallback. Nothing flashed or downloaded to
  the device — decision on which path deliberately left open for the owner.
- 2026-09-11: Owner directed building our own TWRP (option 3) rather than
  waiting on the murky community-prebuilt options. **Done and successful.**
  Bootstrapped the `repo` tool, synced the `twrp-12.1` minimal manifest
  (~33G), and built `ianmacd/twrp_gts7l`'s device tree against it. Found and
  fixed two real bugs in the 2020-era tree: a missing
  `TARGET_SUPPORTS_64_BIT_APPS` (new stricter check on modern build/make),
  and a `PRODUCT_BUILD_RECOVERY_IMAGE` that was both missing *and*, on first
  attempt, placed in the wrong file (`BoardConfig.mk` instead of the product
  `.mk` - it's a read-only-by-that-point `PRODUCT_*` variable) which caused
  the build to silently report success while producing zero output, twice,
  before the real cause was traced through the build system's own source.
  Result: a clean 15-minute build producing a real `recovery.img` + a
  generated AVB-disabled `vbmeta.img`, both in `../artifacts/` (gitignored),
  with the small patched device tree committed at
  `../recovery/device-samsung-gts7l/`. Full writeup in
  `../docs/twrp-build-notes.md`. **Nothing has been flashed to the physical
  tablet** — this closes the "do we have a recovery" question, not the
  "should we flash it now" one, which stays the owner's call.

---

## Phase 1 — Boot to a shell (no display, no peripherals)

**Status:** in progress

Goal: mainline (or near-mainline) kernel boots on the Tab S7 far enough to get
a serial/USB shell — proof the boot chain, DTB, and minimal platform drivers
(clocks, RPMh, pinctrl, UFS) work.

Exit criteria:
- [x] Devicetree for `gts7l` created —
      **`kernel/dts/sm8250-samsung-gts7l.dts`**, forked from upstream's
      `sm8250-samsung-common.dtsi` per `../docs/kernel-baseline.md`.
      Cross-checked two independent ways (Samsung's GPL board-revision
      overlay + live `/proc/interrupts`/`/sys/kernel/debug/gpio` introspection
      of the physical unit) for volume-up (PM8150L, not PM8150 as on the
      phone reference), touchscreen/S-Pen/MAX77705 IRQ-GPIO wiring, and
      confirmed the Wi-Fi/BT combo is PCIe-attached. Full derivation and
      remaining gaps in `../docs/devicetree-notes.md`. **Builds clean (zero
      DTC warnings) against the `v7.2` tree proven in
      `build-environment.md`**, and decompiling the output DTB confirmed
      every override actually took effect — this is devicetree-level
      validation only, not a real hardware boot test yet. Panel, touch I2C
      bus/reset, S Pen driver binding, MAX77705 driver, Wi-Fi PCIe
      instantiation, and Book Cover Keyboard are explicitly deferred to their
      later phases per the file's own `TODO` comments, not silently missing.
- [x] Kernel config for `gts7l` established —
      **`kernel/config/gts7l.fragment`**, layered onto plain `defconfig` via
      `merge_config.sh`. Audit found `defconfig` already covers nearly
      everything Phase 1 needs (PMIC/pinctrl/clocks/IPC/console/pwrkey all
      `=y` already) — the fragment only needed to force UFS storage
      (`SCSI_UFS_QCOM`, `PHY_QCOM_QMP_UFS` + its `PHY_QCOM_QMP` parent)
      built-in rather than modules, to remove initramfs module-load-ordering
      risk from the very first boot attempt. Full audit and a Kconfig
      parent/child tristate-ceiling gotcha worth remembering later in
      `../docs/kernel-config-notes.md`. **Builds clean (zero warnings)**
      merged with the `gts7l` DTS against the same `v7.2` tree — config-level
      validation only, not hardware-booted yet.
- [x] A complete, flashable boot-test artifact is built and package-verified
      — **see `../docs/phase1-boot-testing.md`.** Self-built a static
      aarch64 `busybox` (musl cross toolchain, no root/sudo needed), a
      minimal initramfs (`kernel/initramfs/init`) that mounts
      proc/sys/dev, prints kernel version and block/partition info, and
      drops to a shell, embedded directly into the kernel via
      `CONFIG_INITRAMFS_SOURCE`, and packaged with our
      `sm8250-samsung-gts7l.dtb` into `../artifacts/boot-test-gts7l.img` via
      `mkbootimg` (header v2, matching the TWRP device tree's
      `BOARD_MKBOOTIMG_ARGS` conventions). Verified by round-tripping through
      `unpack_bootimg` — sizes/offsets check out. **Open item, honestly
      flagged rather than guessed past:** the console (`console=ttyMSM0` in
      the cmdline) is a best-effort placeholder — no `serial0` alias/UART
      instance has been confirmed for this specific board, and retail
      tablets often don't expose one at all without hardware modification;
      USB console is the more realistic fallback per this exit criterion's
      own wording, not yet set up.
- [ ] Kernel builds and boots to an initramfs/console (UART or USB) on the
      physical tablet. **Artifact ready (above); not yet attempted on
      hardware.**
- [ ] UFS storage enumerates and is readable. **Driver forced built-in
      already (`gts7l.fragment`); needs the actual boot attempt to confirm.**
- [ ] Root filesystem reachable via ADB/serial shell, even without display.

Progress log:
- 2026-09-11: Wrote and validated (build-only, not hardware-booted)
  `sm8250-samsung-gts7l.dts`. Notable finding along the way: our tablet has a
  three-PMIC complex (PM8150+PM8150L+PM8009) that upstream's
  `sm8250-samsung-common.dtsi` doesn't include by default (the Galaxy S20
  phones it was written for apparently don't need PM8150L/PM8009 wired up at
  this level) — added both `#include`s to our board file.
- 2026-09-11: Established `gts7l.fragment`, a minimal kernel config layered
  onto plain `defconfig`. Most of what Phase 1 needs was already on by
  default; only had to force UFS storage built-in for a more reliable first
  boot attempt. Both the devicetree and config now build clean together.
- 2026-09-12 (owner backing up tablet data in parallel, no hardware touched):
  Built a complete boot-test artifact ahead of any hardware attempt —
  self-built static busybox + minimal initramfs, embedded into the kernel,
  packaged into a flashable `boot.img` with our DTB. See
  `../docs/phase1-boot-testing.md`. Identified (not yet resolved) that the
  debug console/UART for this specific tablet is unconfirmed - flagged
  honestly rather than assumed. **All remaining Phase 1 exit criteria now
  require an actual boot attempt on the physical tablet** — that's the real
  next step once the owner is ready, not more build-side work.

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
