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
      attempted on hardware. Pivot identified in Round 12
      (`../docs/kernel-boot-debugging.md`): two independent real,
      hardware-proven kernels for this SoC family (one for this project's
      exact device) both sidestep every "Board Dtb"/"Board Dtbo" matching
      failure from Rounds 4-11 by never flashing a custom DTB or `dtbo.img`
      at all - only the kernel binary is swapped inside the existing
      boot.img, via the same `magiskboot`-based repack this project already
      uses. Next concrete test: repack with only the kernel replaced,
      stock's own appended DTB left untouched, and `dtbo.img` left
      unflashed/stock - not yet attempted.**
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
- 2026-09-13 (later still): Directly addressed the "evidence-capture
  methodology is the practical bottleneck" problem from the entry above,
  without needing UART. TWRP's recovery ramdisk now automatically saves
  `/proc/last_kmsg` into `/cache/last_kmsg/` (rolling 5-boot history) on
  every boot, early in `init.rc` processing, so a capture survives however
  many reboots it takes to get back to a working `adb` session - no more
  racing the ~2MB ring buffer's eviction. Getting this genuinely reliable
  took three rounds of live hardware debugging (a `by-name/cache` symlink
  race, `/proc/last_kmsg` not populated as early as expected, and `/cache`
  turning out to be a symlink to `/data/cache` at that point in boot) -
  each root-caused by temporarily redirecting the capture script's own
  output to `/tmp` and inspecting it after boot, not guessed at. Separately
  found and worked around a real, unrelated bug while iterating on this:
  `adb reboot recovery`/`bootloader`/`sideload`/`fastboot` silently do
  nothing on this TWRP build, because real AOSP `libfs_mgr` can't parse
  our `recovery.fstab`'s TWRP-specific column order when trying to write
  the bootloader message - confirmed directly from `dmesg`. Plain `adb
  reboot` (no target) works and lands back in TWRP anyway, since the
  Samsung `param` partition is currently pinned to force-recovery
  (`0x02`). Full writeup, all three races, and the `adb reboot` root cause
  in `../docs/kernel-boot-debugging.md`. New recovery image built and
  flashed to the physical tablet, capture confirmed working end-to-end
  across a real reboot cycle.
- 2026-09-12/13 (Round 7): Used the new automated capture for real, and it worked -
  3 clean, marker-anchored captures across 3 tests. **Major correction: retracted
  Round 5's "No match found for Soc Dtb type is fixed" claim.** Discovered the
  artifact Round 6 tested was stale (built before both the Round 5 and Round 6
  fixes, per build-log timestamps), so Round 6's "inconclusive" result was actually
  silently re-testing the old broken build. Rebuilt a correct, fresh artifact
  combining both fixes from source and tested it with a verified capture: fails
  identically to the original pre-fix baseline, down to the exact microsecond
  timestamp. Isolated `-@`/`__symbols__` by testing the 3-entry DTB without it -
  also fails identically. **Every DTS/DTB variant tried in this project so far
  produces the same deterministic ABL rejection at the same microsecond offset** -
  root cause is genuinely unknown again. Also found and partially worked around a
  new evidence-capture gotcha: a Download-Mode bounce alone can evict the ring
  buffer before even one recovery reboot completes if too much time elapses first;
  attempted a `heimdall`-scripted fast exit to remove human reaction time from the
  loop but it isn't working yet (PIT partition naming, stuck USB session) - left
  for a future round. Full evidence and reasoning in
  `../docs/kernel-boot-debugging.md` (Round 7). Tablet safe throughout: stock
  `boot.img`/`dtbo.img` reflashed and hash-verified, `param` left forced to
  recovery, `rp` unaffected. Next: pursue an evidence source independent of
  `/proc/last_kmsg` (real UART, matching `ramoops` address for TWRP pstore, or
  direct ABL binary inspection) before any more blind DTS iteration - black-box
  guessing against this specific failure has now produced two false "fixed"
  conclusions in a row.
- 2026-09-13 (Round 9): **Confirmed `qcom,board-id` (Round 8) actually works** -
  finished the `heimdall` fast-exit from Download Mode (found the real PIT
  partition name is `PARAM`, uppercase, and that heimdall only tolerates one
  protocol session per Download Mode boot - do the write as the only action,
  auto-reboot, don't chain calls), which got a clean, verified capture at last:
  `No match found for Soc Dtb type` is completely gone, and the boot proceeds
  much further than ever before (RP/SWREV/FRP/KG/HDM checks, device ID display)
  before hitting a new, later, different failure: `Unable to find the Board
  Dtb` / `Error: Board Dtbo blob not found`. Per the owner's direction, checked
  how the sibling S9 Ultra project solved the equivalent problem and tried both
  of their documented approaches (no-op DTBO entries with real Samsung
  "selector" identity properties; then a deliberately-invalid `dtbo` to force
  ABL's non-ufdt appended-DTB fallback, their own eventual working fix) -
  **both failed identically**, and a direct log diff proved the `dtbo`
  partition's content has no effect on this failure at all, ruling out more
  guessing at its content as a path forward. Disassembled the responsible
  function (same `LinuxLoader` PE32/toolchain as Round 8) but couldn't trace
  its caller - same indirect-call obstacle as Round 8, needs a real decompiler
  to resolve. Full detail in `../docs/kernel-boot-debugging.md` Round 9.
  Tablet safe: stock `boot.img`/`dtbo.img` restored and hash-verified, `param`
  forced to recovery, `rp` unaffected.
- 2026-09-13 (Round 9, continued): Tried two more independent fixes for the
  "Board Dtb" blocker - stock's real, unmodified `dtbo.img` (what the sibling
  Tab S7+ Droidian project, same SM8250 chip family, actually ships per its
  README) and the exact real `qcom,board-id = <0x08 0x07>` in the appended DTB
  itself (this unit's confirmed real value, from stock `dtbo.img`'s own
  `entry.7` and independently from TWRP's own kernel `Hardware name:` dmesg
  line). **Both also failed identically** - four independent, well-reasoned
  content changes now all produce byte-for-byte identical ABL behavior,
  strong evidence this stage isn't reading identity from anything currently
  under our control. Stopping blind content-guessing on this specific stage;
  `qcom,board-id` stays at the real `<0x08 0x07>` value going forward
  regardless. Full detail in `../docs/kernel-boot-debugging.md` Round 9.
  Tablet safe: stock `boot.img`/`dtbo.img` restored and hash-verified again,
  `param` forced to recovery, `rp` unaffected.
- 2026-09-13 (Round 9, concluded): Installed Ghidra and used it headless to
  properly decompile the ABL functions involved, instead of continuing to
  guess at DTS/DTBO content - full writeup and reusable Java scripts in
  `../docs/ghidra-analysis/`. **The actual decision mechanism is now fully
  understood**: ABL's base-DTB matcher (fixed in Round 8) additionally
  checks whether the match hits a specific 6-bit "exact match" quality bar
  before skipping the strict DTBO search that's currently failing. Decoded
  every bit - one needs `qcom,pmic-id` (never set; tried a sysfs-derived
  candidate value on real hardware, didn't work), another needs a non-zero
  `qcom,msm-id` foundry byte the DTS structurally doesn't have (matching
  stock's own convention). Bigger finding: **stock's own real compiled DTB
  also lacks `qcom,pmic-id`**, meaning stock can't be taking this same
  exact-match path either - it likely reaches Linux via a different
  mechanism entirely, which questions whether this is even the right path
  to keep chasing. Real verbose ABL logging (which would give the literal
  correct values) is blocked behind writing the raw `uefivarstore`
  partition's UEFI variable-store format - not attempted, a real
  side-project. Tablet safe: stock `boot.img`/`dtbo.img` restored and
  hash-verified, `param` forced to recovery, `rp` unaffected. Next: either
  invest in the `uefivarstore` route, or investigate why stock's boot chain
  doesn't need this exact-match path at all before any more DTS tuning.
- 2026-09-13 (Round 10): Directly investigated the "why does stock skip this"
  question per the owner's request, instead of more DTS tuning. First ruled
  out one more theory by direct hardware test: built a boot.img with a
  genuinely single (not triple-concatenated) appended DTB entry - identical
  failure, identical microsecond timestamps, so entry count isn't the
  factor. Then did the obvious direct test that hadn't been tried yet:
  flashed **completely unmodified** stock `boot.img`/`dtbo.img`, did a real
  (non-recovery) `adb reboot`, and read `/proc/last_kmsg` live from the
  resulting real, normally-booted Android session (Magisk root was already
  present from before this project) - zero ring-buffer-eviction risk since
  no intervening reboot was needed. **Found the real answer**: stock's
  actual boot sequence is `EDTBO check fail` → `Apply Overlay total time` →
  `Final Dtb version = 0` → continues normally - none of `No match found`/
  `Unable to find the Board Dtb`/`Board Dtbo blob not found` appear
  anywhere. Stock never enters the whole `FUN_00025490`/`FUN_00026748`
  mechanism Round 8-9 spent so much effort reverse-engineering - that's a
  fallback path, not what stock uses. Working theory: it's gated by AVB
  verification actually succeeding, not just DTB/DTBO content - stock's
  real signed images pass and take this trusted "EDTBO" path, while our
  `magiskboot`-repacked custom images (footer regenerated automatically,
  but very likely without matching content hash descriptors) fail AVB and
  fall back to the legacy mechanism that needs real hardware PMIC/foundry
  data nobody has access to. **This reframes the whole blocker** - continuing
  to tune DTS/DTBO values for the fallback path may never fully succeed;
  getting our custom boot.img to genuinely AVB-verify (via `avbtool` or
  similar) so ABL takes the same trusted path stock uses is the more
  promising direction. Not yet attempted. Full detail in
  `../docs/kernel-boot-debugging.md` Round 10. Device currently booted into
  real, unmodified stock Android (intentional, safe) - get back to TWRP via
  the recovery combo before the next round. `rp` unaffected throughout.
- 2026-09-13 (Round 11): Started the `avbtool` work per the owner's
  direction. Corrected an initial wrong check (the separate `vbmeta`/
  `vbmeta_samsung` partitions don't carry boot/dtbo hash descriptors - `boot`
  and `dtbo` each carry their own embedded, genuinely-signed
  `SHA256_RSA4096` descriptor, the standard "chained partition" AVB
  pattern). Confirmed directly that `magiskboot repack` never updates this
  real descriptor - it's byte-for-byte copied from stock, describing content
  that no longer exists once we swap kernel/DTB. Also found dtbo's AVB
  footer was always stock's own stale one the entire time (fixed at the
  partition's end per the AVB spec, never touched by any of Round 9-10's
  content-only tests, since those only wrote the first 4KB of a 10MB+
  partition) - a real methodology gap, now closed. Used a real RSA-4096 test
  key already available locally to give both `boot.img` and `dtbo.img` a
  genuinely self-consistent (hash matches actual content) though
  Samsung-untrusted signature via `avbtool add_hash_footer`, and tested on
  hardware. **Identical failure** - the self-consistent-but-untrusted
  signature made no difference, disproving this theory too. Two independent,
  well-motivated theories (DTB content, generic AVB pass/fail) are now both
  closed out by direct hardware test. Remaining real path: unlock ABL
  verbose logging via the `uefivarstore` partition (identified in Round 9,
  never attempted) to see actual comparison values instead of continuing to
  guess at mechanisms. `qcom,board-id = <0x08 0x07>` stays applied regardless
  - still correct, still real progress. Full detail in
  `../docs/kernel-boot-debugging.md` Round 11. Tablet safe: stock
  `boot.img`/`dtbo.img` restored and hash-verified, `param` forced to
  recovery, `rp` unaffected.
- 2026-09-13 (Round 8, later): Split the FNB58/FUSB302 VDM-injection idea out into
  its own parked project doc, `../docs/fnb58-vdm-uart-project.md` - decided on the
  reflash-the-FNB58's-own-MCU approach (no permanent hardware mods) over tapping
  its I2C bus with a separate microcontroller, per the owner's preference. Not
  started; documented so it isn't lost and doesn't block the main kernel-boot
  thread. Back to the tablet itself next.
- 2026-09-13 (Round 8): Fully closed out the passive-resistor UART approach -
  confirmed electrically impossible on this hardware via direct testing (proper
  breakout board, multiple resistor values, both orientations, a dead short, a
  VBUS-powered variant - all zero reaction, root-caused to the tablet's mandatory
  USB-C sink pull-down always dominating any external resistor). Found a real
  path forward for later (the owner's FNB58 tester contains the exact FUSB302
  PD-PHY chip `references/vdmtool` needs), not yet started. Separately, pulled
  and reverse-engineered the actual `abl` partition for the first time -
  it's a genuine UEFI Firmware Volume; extracted the embedded `LinuxLoader`
  PE32 module with `uefi_firmware`/`pefile`/`capstone` (all local pip installs,
  no sudo) and disassembled the exact function that prints "No match found for
  Soc Dtb type". That led to a real, well-documented fix: Qualcomm's own
  `msm-id.txt` binding doc says the 2-field short form of `qcom,msm-id` (which
  this DTS has always used) *requires* `qcom,board-id` to also be set - a plain
  requirement missed since the DTS was first written, confirmed against stock's
  own decompiled DTB (which sets `qcom,board-id = <0x00 0x00>`). Applied and
  tested three times - still bounces to Download Mode, but unlike any pre-fix
  test, none of the three post-fix `/proc/last_kmsg` captures caught any trace
  of the attempt at all (likely evicted by more log volume than before, i.e.
  circumstantial evidence of getting further, not proof). Full writeup in
  `../docs/kernel-boot-debugging.md` Round 8. Tablet safe: stock `boot.img`/
  `dtbo.img` restored and hash-verified, `param` forced to recovery, `rp`
  unaffected. Next: resume by getting a real log capture of the board-id-fixed
  boot attempt (faster round-trip, or the FNB58 UART path) before trying
  anything else DTS-side - this is currently the most promising open lead.
- 2026-09-17 (Round 12): No hardware touched - pure research, prompted by the
  owner surfacing two real, hardware-proven custom kernels for this SoC
  family (Quantic Kernel for the sibling SM-T870 Wi-Fi model, and
  itzreesa's KSU-Next kernel for this project's *exact* device, SM-T875
  LTE). Inspecting itzreesa's actual release zip
  (`itzreesa/android_kernel_samsung_sm8250`, `lineage-23.2` branch) found
  the real explanation for Rounds 4-11's "Board Dtb"/"Board Dtbo" matching
  failures: **it doesn't ship a DTB or a DTBO at all.** Just a raw kernel
  `Image` (confirmed via a full-file FDT-magic scan: zero matches) packaged
  via plain AnyKernel3 `dump_boot`/`write_boot`, which repacks whatever
  boot.img is already on the device with only the kernel swapped - DTB and
  `dtbo.img` stay 100% stock. Cross-checked its source tree's
  `qcom,board-id = <8 7>` and 3-entry base-DTB structure
  (`kona.dtb kona-v2.dtb kona-v2.1.dtb`) against this project's own DTS -
  **exact match**, confirming this project's devicetree *content* has been
  correct since Round 8 all along; the blocker was ever giving ABL a custom
  DTB/DTBO to match in the first place. Full evidence, plus a correction to
  an initial "board-id wildcard" misreading of the Ghidra-decompiled
  matcher, in `../docs/kernel-boot-debugging.md` Round 12. **Concrete pivot
  for the next hardware test**: repack boot.img with only the kernel
  component replaced, keep stock's own appended DTB untouched (don't
  substitute this project's DTS output), and don't flash any `dtbo.img` at
  all (leave stock's in place) - the single-variable inverse of every DTB/
  DTBO experiment tried in Rounds 4-11. Not yet attempted on hardware.
  Tablet untouched this round; stock `boot.img`/`dtbo.img` still restored
  and hash-verified from Round 11, `rp` unaffected.

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
