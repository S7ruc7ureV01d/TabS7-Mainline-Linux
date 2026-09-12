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
- [x] **A working TWRP for `gts7l` has been built, flashed, and confirmed
      working on the physical tablet.** Built from source (option 3 from
      `../docs/recovery-options.md`) rather than trusting either community
      prebuilt. Flashed per `../docs/flashing-plan.md` (AP slot only, RP
      confirmed unaffected) — **this is the first artifact from this project
      to actually run on the physical hardware.** Four real bugs found and
      fixed via live hardware testing (touch/theme orientation mismatch,
      broken dynamic-partition fstab entries, and two USB gadget bugs — a
      missing `sys.usb.configfs=1` and an exact-string-match property
      timing issue), each root-caused from real evidence (a live TWRP
      terminal, a comparison against an actively-working sibling build) not
      guessed at. **Confirmed on real hardware:** correct portrait
      display/touch, `/vendor`/`/odm`/`/product`/`/system` mount cleanly,
      USB/adb fully functional (`adb devices -l` sees it in recovery mode).
      Full story in `../docs/twrp-build-notes.md`.
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
- [x] **Flashing plan written** — see `../docs/flashing-plan.md`. Covers:
      pre-flight `rp`/bootloader baseline capture, full raw backups of every
      partition this plan touches (`boot`/`recovery`/`vbmeta`/
      `vbmeta_samsung`/`dtbo`, checksummed, bundled into a one-shot
      `gts7l-STOCK-RESTORE-T875XXU1ATK4.tar` rollback package), the RP-safety
      whitelist/blacklist reasoning, and a staged procedure (recovery+vbmeta
      first as a safe/reversible fallback-establishing step, verified
      working, *then* boot+dtbo as the actual kernel test). **New safety
      finding while planning this:** the live `/proc/cmdline` shows Samsung's
      ABL applies a per-revision `dtbo` overlay (`androidboot.dtbo_idx=7`)
      designed for its *downstream* devicetree on top of whatever base DTB
      boots — flashing our mainline `boot.img` without addressing this risked
      Samsung's overlay corrupting our tree. Fixed the same way the S9 Ultra
      project did: built a genuinely empty "noop" DTBO
      (`kernel/dtbo/gts7l-noop.dts`, 9 identical entries matching the stock
      partition's entry count) to flash alongside `boot.img`. All Odin-ready
      `.tar` packages built and checksummed. **Nothing flashed yet** —
      execution is the owner's call, physical access to the device is
      required (Download-mode button combo).
- [ ] Kernel builds and boots to an initramfs/console (UART or USB) on the
      physical tablet. **Artifact + flashing plan ready (above); not yet
      attempted on hardware.**
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
- 2026-09-12: Owner's tablet backup complete; asked for the flashing plan
  with anti-rollback safety as the top priority. Pulled full raw backups of
  every partition about to be touched (`boot`/`recovery`/`vbmeta`/
  `vbmeta_samsung`/`dtbo`) straight off the live device and bundled a
  one-shot restore package, before writing anything else. While planning,
  found a real gap the earlier boot-test artifact hadn't accounted for:
  Samsung's ABL merges a downstream-shaped `dtbo` overlay
  (`androidboot.dtbo_idx=7`) onto the boot DTB — built a noop DTBO to
  neutralize that (same fix the S9 Ultra project needed for the analogous
  problem). Full plan, all reasoning, and ready-to-flash `.tar` packages in
  `../docs/flashing-plan.md`. **Still nothing flashed** — next actual step is
  the owner physically putting the tablet into Download Mode.
- 2026-09-12: **First flash to physical hardware, and it worked.** Flashed
  `gts7l-recovery-vbmeta.tar` per the plan; RP confirmed unaffected. TWRP
  booted but needed four real fixes discovered through live testing (not
  guessed): touch/theme orientation, broken dynamic-partition fstab entries,
  and two layered USB gadget bugs (`sys.usb.configfs` never enabled, then
  once fixed, `sys.usb.config` reading `mtp,adb` instead of the exact string
  `adb` that TWRP's stock UDC-bind rules require). Each fix went through its
  own rebuild-reflash-reboot cycle using the live TWRP terminal (once touch
  worked) to get real evidence instead of guessing further. **TWRP is now
  fully working**: correct display/touch, all partitions mount, USB/adb
  confirmed functional. Full story in `../docs/twrp-build-notes.md`. Next:
  the actual Phase 1 goal — flash `gts7l-kernel-test.tar` (mainline kernel +
  our DTS + noop DTBO) and see if it boots.
- 2026-09-12: First real hardware boot-testing round on our own kernel/DTB,
  using `magiskboot unpack`/`repack` against the stock `boot.img` as
  template (far more reliable than the earlier from-scratch `mkbootimg`
  approach, confirmed against AnyKernel3's own real repack path). **Got a
  confirmed-good baseline**: stock ramdisk + our kernel/DTB reaches genuine
  Android `init`, which then requests recovery via `param` when `/data`
  fails to mount (expected, given our minimal DTS lacks matching
  FBE/crypto support) — real progress past the ABL. Also confirmed via
  `/proc/last_kmsg` evidence that the ABL's "fail but allow" authentication
  leniency applies uniformly to `vbmeta`/`recovery`/`boot` on this unlocked
  unit, closing out the SEANDROID/AVB-footer theory chased earlier as very
  likely never the real blocker. Two follow-up additions
  (`simple-framebuffer` devicetree node + `CONFIG_FB_SIMPLE`, and separately
  `qcom,msm-id`/`qcom,board-id` copied from `itzreesa/sm8250-mainline`'s WIP
  DTS) were each tested and **each caused a real regression** back to
  Download Mode, confirmed via direct log comparison against the
  known-good baseline rather than guessed — both reverted. Full writeup,
  including the exact log evidence, in `../docs/kernel-boot-debugging.md`.
  Next: retest our own busybox initramfs alone against the clean baseline,
  single-variable, to keep closing in on an interactive shell.
- 2026-09-12 (later): Rebuilt the kernel/DTB from the just-reverted clean
  baseline and ran the planned single-variable busybox-initramfs test —
  bounced to Download Mode. Then ran an immediate sanity re-check (same
  kernel/DTB, stock ramdisk restored — nominally the exact combo that
  originally worked) as a control, and **it also bounced to Download
  Mode**, which means the busybox result can't actually be attributed to
  the ramdisk — the "known-good baseline" itself isn't currently
  reproducing. Also confirmed `/proc/last_kmsg` cannot be cleared from
  userspace (tried as root, no effect). Tablet restored to stock
  `boot.img`, `rp` confirmed unaffected. Next: a real power-cycle test of
  the known-good combo, to check whether cold vs. warm boot is the actual
  variable.
- 2026-09-12 (still later): **Major correction — the "confirmed baseline
  reaches genuine Android init" claim from earlier today was wrong.** The
  cold-boot test (done to chase the warm-reboot theory above) also bounced
  to Download Mode, with a `/proc/last_kmsg` capture whose timestamps
  matched every prior capture to the microsecond — which turned out to be
  because early ABL/XBL execution on this hardware is fully deterministic
  up to the failure point, not because of a stale ring buffer. That
  determinism made it possible to re-audit every `last_kmsg` capture taken
  this session by checking what *actually* follows each file's own
  `Booting Into Mission Mode` marker (rather than searching the whole 2MB
  buffer for a success string). Finding, with zero exceptions across all
  seven captures taken today: our kernel's own boot attempt is *always*
  followed 150 lines later by `No match found for Soc Dtb type` → Download
  Mode. It has never once reached the `EDTBO check fail` → continue path —
  including in the exact file the original "confirmed baseline" claim was
  built from. Those `EDTBO check fail` lines belonged to a different
  (almost certainly TWRP/recovery) boot session sitting nearby in the same
  ring buffer; the earlier analysis conflated the two. This means: the
  `msm-id`/`board-id` and `simple-framebuffer` "regressions" logged earlier
  today were compared against a baseline that itself never worked, so
  those conclusions are unverified too (not necessarily wrong, just not
  established the way they were claimed to be). **Real state of Phase 1**:
  our custom kernel/DTB has never gotten past the ABL's DTB-identity
  check, in any configuration tried so far today. Leading new theory: the
  failure strings match Qualcomm's legacy QCDT appended-DTB table format
  (built by `dtbTool`), a different mechanism from DT properties inside
  our single FDT blob — worth investigating directly rather than more DTS
  property experiments. Full evidence and reasoning in
  `../docs/kernel-boot-debugging.md` (Round 4). Tablet is safe, stock
  `boot.img` restored, `rp` unaffected throughout all of today's testing.
- 2026-09-13: Per the owner's direction, researched and cloned external
  reference projects into `references/` instead of continuing to guess:
  `sm8250-mainline` (fully, was only remotely referenced before),
  `galaxy-tab-s7-plus-droidian`/`adaptation-samsung-gts7xlwifi`/
  `kernel_samsung_sm8250`/`droidian-recipes` (a real working Halium/Droidian
  port for the sibling Tab S7+ Wi-Fi, same SM8250 family, found via an XDA
  thread the owner linked), and re-examined the already-local
  `postmarketos-galaxy-tab-s9-ultra`/`ubuntu-galaxy-tab-s9-ultra` (a sibling
  Samsung-ABL project on a different SoC that documented hitting and fixing
  the identical error strings). **Found the real cause of `No match found
  for Soc Dtb type` by extracting stock's own `dtb` boot.img section and
  inspecting it directly**: it's three concatenated plain FDTs, one per
  `kona` silicon stepping (msm-id `0x10000`/`0x20000`/`0x20001`), each just
  `compatible = "qcom,kona"` — not a QCDT wrapper, not board-id (that's a
  separate later overlay). Our DTS only ever produced one DTB for one
  stepping. Rebuilt the artifact to match stock's exact 3-entry structure
  (`kernel/dts/sm8250-samsung-gts7l.dts` updated with `qcom,kona` +
  `qcom,msm-id`, three `fdtput`-patched copies concatenated before
  `magiskboot repack`). **Evidence it worked**: the previously
  100%-reliable `No match found for Soc Dtb type` string is now absent
  from all three post-fix `/proc/last_kmsg` captures, versus present in
  all five pre-fix ones. Also preemptively applied the S9 Ultra project's
  next documented fix (`DTC_FLAGS ... := -@` for `/__symbols__`, needed for
  Samsung's `ufdt` overlay fork) — not yet confirmed either way, since three
  post-fix test attempts all ended in Download Mode per direct observation
  but none of the three log pulls captured the actual boot-attempt entries
  before ring-buffer eviction. **The evidence-capture methodology (the
  ~2MB `/proc/last_kmsg` ring buffer vs. how many reboots it takes to get
  back to a working `adb` session) is now the practical bottleneck**, not
  any specific DTS content. Full writeup in
  `../docs/kernel-boot-debugging.md` (Round 5/6). Tablet safe throughout,
  `rp` unaffected. Next: either a cleaner/faster log capture, or an
  alternative evidence source (real UART, or matching `ramoops` address so
  TWRP's own pstore might surface something).
- 2026-09-13 (later): Researched getting a live UART console to sidestep
  the `last_kmsg` ring-buffer eviction problem above. Ruled out Samsung's
  real "AnyWay" USB-C JIG (needs a rare factory PD-VDM tool, weeks of lead
  time, unconfirmed payoff even for people with the real hardware). Found
  something more promising by reading our own device's real GPL kernel
  source (`references/gts7l/drivers/muic/max77705-muic.c`): JIG UART mode
  is actually triggered by the CCIC's own hardware CC-line resistance
  detection (a real USB-C accessory-detection mechanism, not a PD
  message), and the `uart_en`/`uart_sel` sysfs controls for it already
  exist and are readable/settable as root on the physical unit right now
  via TWRP. Full findings, exact driver code, and a concrete next
  experiment (bare USB-C breakout + ~619kΩ resistor on CC1/CC2-to-GND,
  battery power only, probe D+/D− at 115200 baud) written up in
  `../docs/uart-debug-research.md`. Not yet attempted on hardware.

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
