# Kernel boot debugging on real hardware (2026-09-12)

Real-hardware findings from the first round of kernel/DTB boot attempts on
the physical `gts7l` unit. Supersedes the "no hardware boot attempt yet"
state described in `phase1-boot-testing.md`'s "Still not done" section for
the items covered here; that file's remaining open items (console/UART,
UFS-reachable-shell) are still open.

## Methodology: use magiskboot, not from-scratch mkbootimg

Early attempts hand-built `boot.img` from scratch (raw `mkbootimg` +
manually reconstructed SEANDROID/AVB-footer trailer). This is fragile and
was a source of real bugs (padding, footer offset). Switched to the same
approach `itzreesa/sm8250-mainline`'s `kernel-builder` + AnyKernel3 use:

1. Keep the stock, pristine `T875XXU1ATK4` `boot.img` as a template
   (`work/stock-backup/boot.img`).
2. `magiskboot unpack stock_boot.img` to get `kernel`, `ramdisk.cpio`, `dtb`.
3. Replace only the piece under test (kernel `Image`, or `ramdisk.cpio`,
   or `dtb`) — leave everything else byte-identical to stock.
4. `magiskboot repack stock_boot.img new_boot.img` — this regenerates the
   `SAMSUNG_SEANDROID` + AVB footer trailer correctly at the right offset
   for the new content size automatically.

Confirmed against AnyKernel3's real `ak3-core.sh` (`write_boot` →
`repack_ramdisk` → `magiskboot repack $BOOTIMG $AKHOME/boot-new.img`) that
this is exactly the production-grade approach — for a header v2/v3 image
like ours, AnyKernel3 never touches an appended-DTB path at all, it's
purely `unpack` → substitute → `magiskboot repack`. The appended-DTB
(`QCDT`) handling in `ak3-core.sh` only applies to a legacy non-`Image`
kernel/mkimage code path that doesn't apply here.

## The ABL "fail but allow" leniency applies uniformly

On this ORANGE/unlocked-bootloader device, Samsung's ABL logs
`AUTHENTICATE fail but allow <X> binary: <partition>` for `vbmeta`,
`recovery`, **and `boot`** — confirmed via `/proc/last_kmsg` evidence
showing this even when `GetFooterInfo: ERROR: Unable to find Footer Info`
(a completely missing footer). This means the SEANDROID/AVB-footer angle
chased early in this project was very likely never the actual blocker for
booting a custom `boot` image — the ABL proceeds past authentication
failures on this unlocked unit regardless.

## `/proc/last_kmsg` is a bootloader-only, multi-session ring buffer

- It is Samsung's own ABL/XBL persistent debug log, **not** Linux kernel
  dmesg — every line is `[ ABL ]`/`[ XBL ]` tagged; no "Linux version"
  string has ever appeared in it across many captures. It cannot prove or
  disprove that Linux itself executed; it can only show what the
  bootloader did before handoff.
- It's one large (~2MB) ring buffer that can span many historical
  boot/flash sessions concatenated together, not just the immediately
  prior boot — always search for the specific session of interest (e.g. by
  `Booting Into Mission Mode` and matching `Boot State is : 1` markers)
  rather than assuming the file is a single boot's log.
- The physical button-combo used to reach TWRP boots the `recovery`
  partition directly and never touches `boot` — a capture taken via that
  combo can only ever show ABL loading `recovery`, never evidence about a
  `boot` image. Only a genuine `adb reboot` (normal boot path), with the
  `param` boot-mode flag cleared beforehand, gives real `boot`-partition
  evidence.
- `/sys/fs/pstore/console-ramoops-0` was checked as an alternative and
  ruled out too: it only ever reflects whichever kernel is *currently
  running* (i.e. TWRP's own), never a prior failed boot's output.
- `/cache` (ext4, not FBE-encrypted) is writable from TWRP and was used as
  the persistent save location for `last_kmsg` snapshots between reboots,
  since `/sdcard` is bound to encrypted `/data` and unusable from TWRP.

## `param` partition boot-mode flag

Byte `0x02` at the start of `param` = force next boot into recovery
(`PARAM_BOOT_RECOVERY_ENTER`); `0x00` = normal. Gets set automatically by
Android's own `fs_mgr`/init when `/data` fails to mount, and separately by
TWRP's own "Reboot > Recovery" action. Must be cleared before every clean
normal-boot test:

```
dd if=/dev/zero of=/dev/block/by-name/param bs=1 count=1 conv=notrunc
```

The user raised the hypothesis that some observed "back in TWRP"/"back in
Download Mode" results might actually be attributable to a stale `param`
flag rather than a genuine kernel-boot difference. Checked directly against
the regression below: the failing session's log shows `Booting Into
Mission Mode` (the normal, non-recovery boot path) followed by legitimate
`boot`+`dtbo` authentication — i.e. it really was a normal-boot attempt
that bounced to Download Mode on its own, not a recovery-flag artifact.
The hypothesis is worth continuing to check on future ambiguous results,
but doesn't explain this particular case.

## ~~Confirmed baseline that reaches genuine Android `init`~~ — RETRACTED, see Round 4

**This entire section is wrong and is kept only for history — do not trust
it.** See "Round 4" far below for the correction and the actual evidence.
Summary of the mistake: the `/proc/last_kmsg` ring buffer holds many
interleaved boot sessions, and the `EDTBO check fail` → `Final Dtb version
= 0` lines that were read as "our kernel's `Booting Into Mission Mode`
attempt succeeding" actually belonged to a *different* nearby boot session
in the buffer (almost certainly a TWRP/recovery boot). Every real capture
this session, re-checked directly against its own `Booting Into Mission
Mode` marker, shows our kernel hitting `No match found for Soc Dtb type` →
Download Mode every single time, with no exception — including in the very
capture (`last_kmsg_ourkernel.txt`) this "confirmed baseline" claim was
originally based on.

Original (wrong) text follows, unedited, for the historical record:

> Stock ramdisk + our kernel/DTB (before the `msm-id`/`board-id` and
> `simple-framebuffer` additions below), magiskboot-repacked onto the stock
> template, gets *past* the ABL and into genuine Android `init`, which then
> requests recovery via the `param` flag when `/data` fails to mount — an
> expected, understandable failure point given our minimal DTS lacks
> FBE/crypto support matching the stock ramdisk's expectations. This is the
> reference-good baseline every other change is compared against.

## Regression 1 (reverted, but see Round 4 caveat below)

**Caveat added in Round 4:** this comparison used the retracted "confirmed
baseline" above as its reference point. Since that baseline never actually
reached Android `init` (both sides of every comparison in this project so
far hit `No match found for Soc Dtb type`, not just one side), it's unclear
whether this specific isolated test really showed a differential regression
or was comparing two runs that both failed the same way. Kept for history;
treat as unverified until re-tested against a real, correctly-attributed
baseline.

### `simple-framebuffer` devicetree node + `CONFIG_FB_SIMPLE`

Added to get on-screen boot-console feedback, reusing the ABL's own splash
region (`cont_splash_region@9c000000`, `0x02300000`). An isolated A/B test
against the confirmed-good baseline showed this addition alone caused a
regression to Download Mode. Root cause not understood. Reverted (both the
DTS `chosen`/`simple-framebuffer` node and `CONFIG_FB_SIMPLE=y` in
`kernel/config/gts7l.fragment`) — flagged in both files as a
`TODO(phase2/debugging)` to revisit alongside real panel/display driver
work, not in isolation.

## Regression 2 (reverted, but see Round 4 — likely misattributed)

**Caveat added in Round 4:** this "disproof" compared against the same
retracted baseline. Round 4 shows `No match found for Soc Dtb type` is in
fact the *universal, deterministic* outcome for our kernel/DTB with or
without `msm-id`/`board-id` — so this section's conclusion ("adding these
properties broke DTB matching that worked fine without them") is very
likely wrong; matching was never working in the first place. The idea that
the ABL needs board/SoC identity to accept the DTB may still be correct in
substance — the DT-property-level implementation tried here (`qcom,msm-id`
inside the FDT root node) is a different mechanism from the QCDT
appended-DTB table format the "No match found for Soc Dtb type" / "Error:
Appended Soc Device Tree blob not found" message strings suggest the ABL is
actually searching for (Qualcomm's legacy `dtbTool`-generated multi-entry
table, not plain DT properties). Worth revisiting with that distinction in
mind rather than discarding the concept entirely.

### `qcom,msm-id`/`qcom,board-id`

Added on the theory (from comparing against `itzreesa/sm8250-mainline`'s
independent WIP `gts7l` DTS, cross-checked against Samsung's own GPL
source for `board-id`) that the ABL needs these root-node properties to
validate DTB identity, and that their absence was the actual cause of
every hard Download-Mode rejection so far — displacing the earlier
SEANDROID/AVB theory.

**Disproven by direct log comparison.** At the identical point in ABL
execution (right after boot-splash draw, `Memory Base Address:
0x80000000`):

- Known-good baseline (properties absent):
  `Override DTB: GetBlkIOHandles failed loading user_dtbo!` →
  `EDTBO check fail` → `Apply Overlay total time: 394 ms` →
  `Final Dtb version = 0` → continues into RAM partition setup, IDDQ
  fuses, etc.
- With `msm-id`/`board-id` added: `No match found for Soc Dtb type` →
  `Error: Appended Soc Device Tree blob not found` → falls straight back
  into Odin/Download mode (`Odin Build Info...`, `Samsung USB Driver
  enumeration start!`, `odin: processing commands`) — never reaches RAM
  partition setup at all.

So adding these properties actively *broke* DTB matching that was working
fine without them — the opposite of the theory. Reverted in
`kernel/dts/sm8250-samsung-gts7l.dts` (replaced with a `TODO` documenting
this exact finding). Root cause (wrong `msm-id` encoding for this chip
revision? conflicts with how our merged FDT otherwise exposes chip
identity?) is not understood — revisit only with concrete evidence, not
another itzreesa-sourced guess.

## Round 3 (2026-09-12, later): the "No match / EDTBO" fork looks state-dependent, not DTS-dependent — Regression 2's attribution is now in doubt

Rebuilt the kernel/DTB from the just-reverted (clean baseline) source —
confirmed via `diff` against the original `8f277f9` commit that the actual
devicetree content is byte-for-byte unchanged (only comment text differs;
the reverted `msm-id`/`board-id` properties are genuinely absent). Ran two
back-to-back tests against the physical unit, both via
`magiskboot unpack`/repack of the pristine `stock-backup/boot.img`
template, both with `param` cleared and a genuine `adb reboot`:

1. **Clean-baseline kernel/DTB + our busybox initramfs swapped in as the
   ramdisk** (replacing the stock ramdisk, single-variable vs. the
   original confirmed-good test). Result: bounced to Download Mode.
2. **Sanity re-check**, immediately after: the identical rebuilt
   kernel/DTB, this time with the untouched **stock** ramdisk restored —
   i.e. nominally the exact same combination that originally reached
   genuine Android `init`. Result: **also** bounced to Download Mode.

Test 2 is the important one: it means the busybox-ramdisk result from
test 1 cannot be attributed to the ramdisk — the supposedly-identical
"known-good" combination failed on retest with no ramdisk change at all.
Something about reproducing the original result is not understood, full
stop.

**Direct log evidence for test 1** (captured via `/proc/last_kmsg` →
`/cache`, full session preserved since it was the most recent at capture
time) shows the fork happens *later and in a different place* than
previously assumed. Full sequence: ABL authenticates `vbmeta`/`boot`/
`dtbo` via the normal fail-but-allow path (all as `orange`/unlocked,
identical to every other run) → `Boot State is : 1` → XBL sets display
mode and draws the boot image → `GetVmData: No Vm data present!` →
`Memory Base Address: 0x80000000` → **`No match found for Soc Dtb type`**
/ **`Error: Appended Soc Device Tree blob not found`** → falls to Odin/
Download Mode. Critically, this is the **exact same textual point**
(right after `Memory Base Address: 0x80000000`) where the known-good
baseline instead logs `EDTBO check fail` → `Apply Overlay total time` →
`Final Dtb version = 0` and continues into RAM partition setup. Same
fork point, two different outcomes, **with no DTS/config difference
between the two runs that hit each outcome** (test 2's sanity boot used
literally the same kernel+DTB as the original successful baseline).

This means: the "No match found for Soc Dtb type" signature previously
blamed on `qcom,msm-id`/`qcom,board-id` (Regression 2, above) may never
have been caused by those properties at all — this same failure now
reproduces with a devicetree confirmed to be identical to the baseline
that supposedly disproved it. The two most likely explanations, neither
confirmed yet:

- This fork point depends on some volatile state that a **warm
  `adb reboot` doesn't clear** (e.g. stale DDR content at or near the
  `0x80000000` scan address, left over from the previous boot attempt,
  rather than a genuine cold-boot memory state) — every test so far in
  this project has used `adb reboot`, never a real power-cycle.
- Some other environmental/bootloader-internal state changed between the
  original successful baseline run and now (many flash/reboot cycles have
  happened since), independent of any image content.

**Methodology gotcha confirmed the hard way:** `/proc/last_kmsg` is a
fixed ~2MB ring buffer and **cannot be cleared from userspace** — tried
truncating it as root (`: > /proc/last_kmsg`), size stayed exactly
2097136 bytes, no effect. It is a read-only view into bootloader-owned
memory, not a real file. Because of this, test 2's own log evidence was
already overwritten by the time it was pulled (several TWRP/recovery
reboots happened during the button-combo dance to get back into TWRP,
each appending thousands of lines) — there is no direct log evidence for
what specifically happened during test 2, only the behavioral outcome
(Download Mode). **Future captures must happen with the fewest possible
intervening reboots** between the test boot and pulling the log, or the
evidence will be gone before it's read.

Tablet is currently safe: stock `boot.img` has been restored, `rp`
(`androidboot.rp=1`) and `androidboot.bootloader=T875XXU1ATK4` both
confirmed unchanged throughout.

## Round 4 (2026-09-12, still later): the cold-boot test disproves stale-DDR, and re-auditing every capture this session finds the "confirmed baseline" was a misattribution all along

Ran the planned cold-boot test: flashed the known-good kernel+DTB+stock-
ramdisk combo (same artifact as Round 3's sanity check), cleared `param`,
then did a **genuine full power-off/power-on** (not `adb reboot`) instead
of a warm reboot. Result: bounced to Download Mode again.

The captured `/proc/last_kmsg` for this run shows `Booting Into Mission
Mode` at timestamp `{ 2374943 }`/`{ 2441250 }` (microseconds since power-on)
followed by `No match found for Soc Dtb type` at `{ 7034855 }` — the
**exact same timestamps, to the microsecond**, as every other capture this
session. That's not a stale ring-buffer artifact (verified by diffing
surrounding context between captures — the sessions are genuinely
distinct, just executing identical deterministic bootloader code up to
this point). It means: early ABL/XBL execution up to this fork is fully
deterministic on this hardware, cold or warm boot alike, and **this fork
was never actually sensitive to DDR retention** — that theory is disproven.

More importantly, disproving that theory prompted a full re-audit of every
`/proc/last_kmsg` capture taken this session (`last_kmsg_attempt2.txt`,
`_attempt5.txt`, `_attempt6.txt`, `_ourkernel.txt`, `_busybox_test.txt`,
`_sanity_test.txt`, `_coldboot_test.txt`), this time checking what
literally follows *each file's own* `Booting Into Mission Mode` marker
rather than trusting an `EDTBO check fail` string found anywhere in the
same 2MB file. Result, with zero exceptions across all seven captures:

```
Booting Into Mission Mode  (our kernel's own boot attempt)
  ↓ exactly 150 log lines later, every single time
No match found for Soc Dtb type
Error: Appended Soc Device Tree blob not found
  ↓
Odin Build Info ... (Download Mode)
```

**Our custom kernel/DTB has never once reached the `EDTBO check fail` →
`Final Dtb version = 0` → continue path, in any capture taken this
session — including `last_kmsg_ourkernel.txt`, the exact file the original
"confirmed baseline reaches genuine Android init" claim (now retracted,
above) was built on.** That file does contain `EDTBO check fail` lines
(five separate occurrences), but every one of them sits far from any
`Booting Into Mission Mode` marker and belongs to a different boot session
in the same ring buffer — almost certainly a TWRP/recovery boot, which
reliably takes that path (recovery has always worked). The original
analysis conflated the two sessions. This was a real methodology error,
not a hardware inconsistency, and it invalidates the "confirmed baseline"
this project has been comparing every other change against since Round 2.

**What this actually establishes, now on solid ground:**

- Our kernel+DTB, packaged via `magiskboot unpack`/repack onto the stock
  `boot.img` template, deterministically triggers `No match found for Soc
  Dtb type` / `Error: Appended Soc Device Tree blob not found` and bounces
  to Download Mode. This has now been true in **every test performed this
  session** — with `msm-id`/`board-id` present, without them, with the
  stock ramdisk, with our busybox ramdisk, warm-rebooted, and cold-booted.
  None of those variables changed the outcome.
- This strongly suggests the ABL is doing a *different* DTB-identity check
  than the `EDTBO`/overlay mechanism the working (recovery) boots go
  through — the message strings ("Soc Dtb type", "Appended ... Device Tree
  blob") match Qualcomm's legacy `dtbTool`-style **QCDT appended-DTB
  table** format (a header + multi-entry table of per-board DTBs, each
  tagged with SoC/board IDs, historically appended directly after the
  kernel `Image` bytes) — not a matter of which DT *properties* are inside
  our single plain FDT blob. Adding `qcom,msm-id`/`qcom,board-id` as DT
  properties in Round 2 didn't address this because it isn't the same
  mechanism as building a real QCDT table; that's the likely reason it
  "changed nothing" in a way that's now consistent with this always
  failing regardless.
- The `simple-framebuffer`/`CONFIG_FB_SIMPLE` "regression" from Round 1 is
  now unverified for the same reason — both sides of that comparison may
  have been hitting this same failure.

Tablet is safe: stock `boot.img` restored again after this test, `rp`
confirmed unaffected.

## Round 5 (2026-09-13): researched sibling projects, found and applied the real fix for "No match found for Soc Dtb type"

Per the owner's direction, cloned and analyzed several external projects into
`references/` rather than guessing further from first principles:

- `references/sm8250-mainline` (itzreesa's WIP `gts7l` devicetree, previously
  only referenced remotely, now fully cloned).
- `references/postmarketos-galaxy-tab-s9-ultra` /
  `references/ubuntu-galaxy-tab-s9-ultra` (already local from project
  inception) - a **sibling Samsung-ABL-family port on a different SoC
  generation (SM8550) that hit the identical error strings and got past
  them**, fully documented in their `docs/development-notes.md` and
  `docs/porting-log.md`.
- `references/galaxy-tab-s7-plus-droidian`,
  `references/adaptation-samsung-gts7xlwifi`,
  `references/kernel_samsung_sm8250` (branch `droidian`),
  `references/droidian-recipes` - a **real, working Halium/Droidian port for
  the Tab S7+ Wi-Fi (SM-T970/gts7xlwifi), same SM8250 chip family as our
  `gts7l`**, found via an XDA thread the owner linked.

**Root cause, found by direct inspection, not guesswork:** extracted the
*stock* `boot.img`'s own `dtb` section (`magiskboot unpack`) and examined it
byte-by-byte. It is not a single DTB - it is **three plain FDT blobs
concatenated back-to-back** (FDT magic `0xd00dfeed` at byte offsets 0,
519810, 1039616 in the 1,556,447-byte blob), one per `kona` silicon stepping:

```
entry 0: model "kona v2.1 SoC", compatible = "qcom,kona", qcom,msm-id = <0x164 0x20001>
entry 1: model "kona v2 SoC",   compatible = "qcom,kona", qcom,msm-id = <0x164 0x20000>
entry 2: model "kona v1 SoC",   compatible = "qcom,kona", qcom,msm-id = <0x164 0x10000>
```

None of the three carry `qcom,board-id` - that lives in a separate per-board
overlay applied later (confirmed against
`references/gts7l/.../kona-sec-gts7l-eur-overlay-r07.dts`, which does carry
`qcom,board-id = <0x8 0x7>` alongside `compatible = "qcom,kona-mtp",
"qcom,kona", "qcom,mtp"`). Our earlier attempts had only ever produced a
*single* DTB (one msm-id value, or none at all) - `No match found for Soc
Dtb type` is Samsung ABL's real, literal complaint about this: it walks the
appended list looking for a stepping match against the actual silicon fuse
value, and a lone entry for the wrong stepping (or no entry at all) fails
every time, deterministically, regardless of any other DTS property.

**Fix applied:** `kernel/dts/sm8250-samsung-gts7l.dts` root node now has
`compatible = "samsung,gts7l", "qcom,kona", "qcom,sm8250";` and
`qcom,msm-id = <0x164 0x10000>;` (board-id deliberately omitted from this
base blob, matching stock's actual structure). The boot artifact is no
longer a single dtb - it's the same DTB content compiled once, then patched
via `fdtput` into three copies with `qcom,msm-id` set to `0x20001`, `0x20000`,
and `0x10000` respectively, concatenated in that order (mirroring stock
exactly) into one appended blob before `magiskboot repack`.

**Evidence this worked:** `No match found for Soc Dtb type` had been
reliably present, session after session, in *every* `/proc/last_kmsg`
capture taken before this fix (5 separate sessions), robust even under heavy
ring-buffer churn from repeated TWRP reboots. After this fix, it is
**completely absent from all three post-fix captures taken since**
(`last_kmsg_appended_fix.txt`, `_appended_fix2.txt`, `_symbols_fix.txt`),
despite those captures containing plenty of other boot-session noise that
would have preserved the string had it occurred. Absence of a previously
rock-solid signal, right after the fix that specifically targets it, is
treated as real evidence here - not proof, but strong enough to build the
next step on.

## Round 6 (2026-09-13): applied the `-@`/`/__symbols__` fix for the next expected barrier; capture evidence inconclusive so far

The S9U project's own porting log describes the *next* barrier after fixing
"No match": `ApplyOverlay: ufdt apply overlay failed` / `Root Node is not
found at BoardDtb` / `Invalid device tree header`, because Samsung ABL's own
`ufdt` fork requires the base DTB to export `/__symbols__` (standard libfdt
tools like `fdtoverlay` don't need this, but ABL's fork does). Their fix was
one Makefile line: `DTC_FLAGS_<dtb-stem> := -@`. Applied the same line for
`sm8250-samsung-gts7l` in `work/linux/arch/arm64/boot/dts/qcom/Makefile`
(not yet captured as a repo-tracked patch - this project doesn't have that
infrastructure the way postmarketOS's `pmaports` does; documented here
instead). Confirmed the rebuilt DTB now exports one `/__symbols__` node
(154,495 bytes vs. 115,105 without `-@`). Rebuilt all three stepping copies
from this new base, reflashed.

**Not yet confirmed either way.** Three consecutive test attempts against
this combined fix all ended in Download Mode per the owner's direct
observation, but `/proc/last_kmsg` never once captured our kernel's own
`Booting Into Mission Mode` marker in any of the three pulls - by the time
of capture, enough intervening TWRP/recovery boot cycles (needed to get
back to a state where `adb` works) had already overwritten that specific
session's entries. This is a real, recurring limitation of this evidence
method: getting from "device just bounced to Download Mode" to "device is
in TWRP with USB enabled" reliably takes more reboot cycles than fit
comfortably in the ~2MB ring buffer before the entry of interest is gone,
even when done as fast as possible. Checked `/sys/fs/pstore` fresh as an
alternative (previously ruled out, but that ruling predates any chance of
our kernel actually running) - empty, but inconclusive since TWRP's own
`ramoops` region address almost certainly doesn't match our DTS's
`ramoops@9FA00000` node, so TWRP wouldn't surface our kernel's pstore data
even if it existed.

## Current status / next steps

- **The automated `/cache/last_kmsg` capture works and was used successfully this
  round** (Round 7, below) - 3 clean, marker-anchored boot-attempt captures across 3
  separate tests, finally giving reliable ground truth after several rounds of
  methodology failure.
- **Major correction (Round 7): `No match found for Soc Dtb type` is NOT fixed -
  Round 5's "fix confirmed" claim is retracted.** The artifact Round 6 tested
  turned out to predate both the Round 5 and Round 6 fixes (a stale-artifact bug in
  how Round 6 was tested - see Round 7 for the timestamp evidence). A freshly,
  correctly rebuilt artifact combining both fixes was tested this round with a
  verified clean capture: it fails identically, at timestamps identical to the
  microsecond versus the original Round 4 pre-fix failure. Isolating `-@`/
  `__symbols__` (rebuilt without it, otherwise identical) also fails identically.
  **Every DTS/DTB variant tried across this entire project so far (single-entry,
  3-entry, with/without msm-id, with/without `-@`) produces the exact same
  deterministic failure at the exact same microsecond offset.** Root cause is back
  to genuinely unknown.
- **The evidence-capture methodology has one more confirmed blind spot even with
  the automated capture** (Round 7): a Download-Mode bounce can by itself generate
  enough log volume to evict the entry before even a single recovery reboot gets
  the capture saved. Minimize dwell time in Download Mode - the button combo done
  immediately after a bounce worked cleanly twice; waiting longer once lost the
  entry entirely. A scripted fast-exit via `heimdall close-pc-screen` was attempted
  but isn't working yet (PIT partition-name mismatch for `param`, stuck Odin USB
  session after `--no-reboot`) - worth finishing since it would remove the human
  reaction-time variable entirely.
- Untried alternative evidence sources worth considering before more blind
  DTS iteration - now more valuable than ever, given the "No match" root cause is
  unknown again: a real UART console (physically unconfirmed on this
  retail unit - see `phase1-boot-testing.md`'s open item) would sidestep
  the ring-buffer problem entirely if one exists; matching our DTS's
  `ramoops` reserved-memory address to what TWRP's own kernel would
  recognize might let `/sys/fs/pstore` surface something even when
  `last_kmsg` doesn't; disassembling/inspecting the real Samsung ABL binary's
  DTB-matching routine directly (extractable from this device's `abl` partition)
  rather than continuing to infer its behavior from black-box testing alone.
- Our own busybox initramfs is still untested in any meaningful sense - it
  can't be tested until the ABL will actually hand off to our kernel, which
  is still unconfirmed.
- Any future reference-project-sourced DTS/config change should be
  validated by checking what immediately follows *that specific test's
  own* `Booting Into Mission Mode` marker in a freshly captured
  `/proc/last_kmsg` - not by searching the whole 2MB buffer for a success
  string, which is exactly the mistake that produced the retracted
  "confirmed baseline" earlier in this file. **Also confirmed a related trap
  in Round 7: verify the actual artifact under test was built *after* the fix
  it's supposed to contain (check build log timestamps) before trusting any
  test result, positive or negative** - Round 6's "inconclusive" result was
  actually a silent stale-artifact bug, not genuine inconclusiveness.
- **UART is a closed avenue via passive CC resistor** (Round 8) - confirmed
  electrically impossible on this hardware (the tablet's mandatory USB-C sink
  Rd pull-down always dominates any external resistor). A real PD-VDM injection
  path exists using the owner's own FNB58 tester (contains a FUSB302BMPX, the
  exact chip `references/vdmtool` targets) but needs either bus-isolation
  soldering or custom firmware - not started.
- **`qcom,board-id = <0x00 0x00>` added (Round 8) - CONFIRMED WORKING (Round 9).**
  `No match found for Soc Dtb type` / `Error: Appended Soc Device Tree blob not
  found` are completely gone from a clean, verified capture - the appended
  3-entry kona-stepping DTB now matches successfully, for the first time in this
  entire project. Keep this fix applied; do not revert it.
- **New blocker found and confirmed real (Round 9): `Unable to find the Board
  Dtb` / `Error: Board Dtbo blob not found`**, reached much later in boot (past
  RP/SWREV/FRP/KG/HDM checks, device ID display) than any prior failure.
  **Four independent, well-reasoned content changes all produced byte-for-byte
  identical ABL behavior**: noop DTBO with real Samsung selector properties;
  a deliberately-invalid (all-zero) DTBO to force ABL's non-ufdt fallback (a
  sibling project's actual documented fix, for a different SoC generation);
  stock's real unmodified DTBO (what a same-chip-family sibling project
  actually ships); and the exact real `qcom,board-id = <0x08 0x07>` in the
  appended DTB itself (this unit's confirmed real value). **Stop guessing at
  DTB/DTBO content for this specific stage** - none of it is provably read by
  whatever determines this outcome. `qcom,board-id = <0x08 0x07>` (the real
  value) stays applied going forward regardless. Root cause is open;
  installed and used Ghidra (headless, `docs/ghidra-analysis/README.md`) to
  properly decompile the responsible functions instead of continuing with
  guesswork - **the full decision mechanism is now genuinely understood**:
  ABL's base-DTB matcher (already fixed via `qcom,board-id`) additionally
  checks for an "exact match" quality bar (a specific 6-bit combination,
  fully decoded) before it will skip the strict DTBO search that's currently
  failing. One required bit needs `qcom,pmic-id` (never set, tried a
  sysfs-derived candidate value on hardware - didn't work); another needs a
  non-zero `qcom,msm-id` foundry byte that's structurally absent from this
  DTS's current (stock-matching) wildcard convention.
- **Round 10 - the real answer, found by directly reading stock's own actual
  boot log**: stock never enters this whole mechanism at all. Flashed
  completely unmodified stock `boot.img`/`dtbo.img`, did a real (non-recovery)
  boot, and read `/proc/last_kmsg` live from the resulting real Android
  session (zero eviction risk). Stock's real sequence is `EDTBO check fail` →
  `Apply Overlay total time` → `Final Dtb version = 0` → continues - **none**
  of `No match found`/`Unable to find the Board Dtb`/`Board Dtbo blob not
  found` appear anywhere. Working theory: ABL's DTB-selection strategy
  branches on whether AVB verification actually *succeeds*, not just on
  content - stock's real signed images pass and take the trusted "EDTBO"
  path, while `magiskboot`-repacked custom images (which regenerate the AVB
  footer's size/offset automatically but not matching content hash
  descriptors) almost certainly fail AVB and fall back to the legacy
  appended-DTB mechanism this project has been fighting since Round 5 - a
  mechanism that needs real hardware PMIC/foundry data nobody has access to.
  **This reframes the whole blocker**: tuning DTS/DTBO values for the
  fallback path may never fully succeed; the more promising direction is
  getting our custom `boot.img` to genuinely AVB-verify (via `avbtool` or
  similar, not relying on `magiskboot`'s automatic-but-hash-incorrect footer
  regen) so ABL takes the same trusted path stock uses. Not yet attempted -
  this is the clear next step. Full detail in Round 10.

## Automated boot-history capture in TWRP (2026-09-12)

Directly addresses the "evidence-capture methodology itself is now the
practical bottleneck" problem noted above. TWRP's recovery ramdisk now
saves `/proc/last_kmsg` into `/cache` on every boot, automatically, as
early in boot as it safely can - so evidence from a boot attempt survives
the next reboot without a live `adb` session having to catch it in the
ring buffer before it gets evicted or overwritten by a later boot session.

### What it does

Implemented as an `on post-fs` action in
`recovery/device-samsung-gts7l/recovery/root/init.recovery.qcom.rc` (the
device tree that builds `../artifacts/twrp-gts7l-unofficial.img` - see
`twrp-build-notes.md`). On every TWRP boot it:

1. Mounts the real `cache` partition onto `/cache` (see "Real-hardware
   races" below for why this needs more than a plain `mount`).
2. Rotates any existing capture history: `kmsg.0` -> `kmsg.1` -> ... ->
   `kmsg.4` (oldest), dropping anything older than that.
3. If `/proc/last_kmsg` is non-empty this boot, copies it to the new
   `/cache/last_kmsg/kmsg.0`.

Keeps a rolling history of the **5 most recent boots**, not just the
latest one, so a capture isn't lost if the *next* boot after an
interesting one turns out to be uninteresting (a common shape during this
kind of iterative bring-up: flash, boot-test, land back in TWRP or
Download Mode, re-flash, try again).

### Reading it back

```sh
adb shell ls -la /cache/last_kmsg/
adb pull /cache/last_kmsg/kmsg.0   # newest; kmsg.1..kmsg.4 = progressively older
```

No live-capture timing required any more - pull whenever convenient,
including well after the boot attempt of interest, as long as it's within
5 boots.

### Real-hardware races found and fixed (all 2026-09-12, live-debugged on the physical unit)

Getting this genuinely reliable took three rounds of live debugging, each
following the same pattern: the mechanism *looked* right, silently didn't
capture anything on an automatic boot, and had to be root-caused by
temporarily redirecting the script's own stdout/stderr to `/tmp` (survives
until the next reboot, readable over `adb` - `/cache` itself can't be used
for this diagnostic output, for reasons that become obvious in race #3)
and inspecting it after boot, rather than guessed at. Full blow-by-blow
reasoning is in the comments directly above the `on post-fs` block in
`init.recovery.qcom.rc`; summary:

1. **`by-name/cache` symlink not ready yet.** The `/dev/block/bootdevice`
   symlink created by the `on fs` block above only proves the *base*
   bootdevice path exists, not that ueventd has already scanned the
   partition table and created the `by-name/cache` symlink underneath it.
   Fixed with an explicit `wait /dev/block/bootdevice/by-name/cache 5`
   (init's own builtin, same one already used for the bootdevice path
   itself) before touching it.
2. **`/proc/last_kmsg` not populated yet.** Even with the wait above, a
   single point-in-time `[ -s /proc/last_kmsg ]` check still silently
   skipped the capture - the ABL/XBL log node isn't guaranteed available
   as early as `post-fs` fires. Fixed with a short bounded poll (up to 10
   one-second tries) instead of a single check. **Gotcha hit while writing
   this fix:** a bare (non-`${}`) `$` inside the quoted `exec ... sh -c
   "..."` string is *not* passed through to the shell - init's own
   `ExpandProps()` (`system/core/init/util.cpp`) reads it as an init
   property reference first and, for this codebase's non-brace form,
   consumes the rest of the string as the property name, which breaks
   parsing of the entire command. The retry loop is written as a
   fixed-count `for x in 1 2 ... 10; do ...; done` with no shell variable
   at all, specifically to avoid this.
3. **`/cache` is a symlink to `/data/cache` at that point in boot, not a
   real directory.** Even after fixing both races above, mounting still
   failed with ENOENT. Root cause: something (most likely TWRP's own
   PartitionManager, reacting to this device's `recovery.fstab` not being
   in a format real AOSP `libfs_mgr` recognizes as a first-stage mount -
   see the `adb reboot` section below for the same format mismatch causing
   a second, unrelated problem) relinks `/cache` to `/data/cache` before
   `post-fs` fires, and `/data` isn't mounted yet either, so the symlink's
   target doesn't exist. This device does have a real, dedicated `cache`
   partition, and TWRP's own later boot logic proves the conflict is
   recoverable - by the time the full GUI is up, `/cache` observably *is*
   the real ext4 partition again. Fixed by doing that same fix earlier:
   `rm -rf /cache; mkdir -p /cache` before mounting onto it.

### `adb reboot recovery` (and `bootloader`/`sideload`/`fastboot`) silently do nothing on this build

Found while iterating on the capture feature above, and worth documenting
separately since it affects *any* future remote-driven reboot, not just
this feature. `adb reboot recovery` sets the property
`sys.powerctl=reboot,recovery` - confirmed via `getprop` after issuing
it - but the device just keeps running; no actual reboot happens. Root
cause confirmed directly from `dmesg` right after issuing the command
(reproducible every time):

```
init: Received sys.powerctl='reboot,recovery' from pid: ... (setprop)
init: Got shutdown_command 'reboot,recovery' Calling HandlePowerctlMessage()
init: [libfs_mgr]Error parsing mount_flags
init: [libfs_mgr]ReadFstabFromFile(): failed to load fstab from : '/etc/recovery.fstab'
init: [libfs_mgr]ReadDefaultFstab(): failed to find device default fstab
init: Failed to read bootloader message: failed to read default fstab
init: [libfs_mgr]Error parsing mount_flags
init: [libfs_mgr]ReadFstabFromFile(): failed to load fstab from : '/etc/recovery.fstab'
```

Any reboot *target* that needs a bootloader-message (BCB) write -
`recovery`, `bootloader`, `sideload`, `fastboot` - goes through
`HandlePowerctlMessage()` in `system/core/init/reboot.cpp`, which tries to
read/write that message via `/etc/recovery.fstab` (real AOSP `libfs_mgr`'s
documented fallback for finding `misc` on a recovery image, since there's
no separate hardware fstab in a stock recovery ramdisk). Our
`recovery.fstab` is written in **TWRP's own column order**
(`<mount_point> <fstype> <blk_device> [flags]`), not the strict 4-token
AOSP order (`<src> <mount_point> <fstype> <mount_flags>`) real
`libfs_mgr`'s line parser (`fs_mgr_fstab.cpp`) requires - several lines
(`/boot`, `/misc`, `/recovery`, ...) only have 3 tokens once misread in
that order, so the strict parser hits `"Error parsing mount_flags"` and
aborts parsing the *entire file*. With no fstab, `libfs_mgr` can't find
`misc`, the BCB write fails, and `HandlePowerctlMessage()` **returns
early, before ever reaching the actual reboot syscall.** TWRP's own
partition manager reads this same file fine because it has its own,
separate, lenient parser for its own format - the two are just
incompatible with each other despite reading the identical file.

**Practical fix, verified working:** use plain `adb reboot` (no target)
instead. It skips this whole BCB-write code path entirely (empty
`reboot_target` goes straight to the actual reboot syscall) - and lands
back in TWRP anyway, because the Samsung `param` partition's boot-mode
byte is currently `0x02` (`PARAM_BOOT_RECOVERY_ENTER` - see the `param`
section earlier in this file), which the bootloader honors independently
of the AOSP BCB mechanism. Confirmed with a live `adb devices -l`
transport-ID check across a plain `adb reboot`: new transport ID, state
still `recovery`. **Not fixed at the root** - actually making
`recovery.fstab` parse under strict `libfs_mgr` would risk breaking
TWRP's own (differently-lenient) reader of the same file, which is a
real, separate risk not taken on here without deliberate scoping.

## Round 7 (2026-09-12/13): the automated capture works, and it forces a second major
retraction - Round 5's "fix confirmed" was never actually verified either

With the automated `/cache/last_kmsg` capture (above) now flashed and working, ran a
disciplined re-test of the exact artifact Round 6 claimed to have tested
(`artifacts/gts7l-kernel-test.tar`, timestamped 13:24) - and discovered before even
flashing anything that **this artifact predates both the Round 5 and Round 6 fixes**
(`work/build-appended-dtb.log` is 15:55, `work/build-symbols-fix.log` is 16:12, both
after 13:24). So Round 6's "three consecutive test attempts... all ended in Download
Mode" was actually re-testing the pre-fix, single-DTB-entry artifact the whole time -
its "not yet confirmed either way" conclusion was correct by accident, but for the
wrong reason, and told us nothing about the real fix.

Freshly rebuilt the real combination from source (kernel `Image` + `sm8250-samsung-gts7l.dtb`
built with `-@`, patched into three `qcom,msm-id` copies via `fdtput`, concatenated
in stock's v2.1/v2/v1 order, `magiskboot repack`ped onto the stock template) and
tested it end-to-end using the automated capture as the evidence path (button-combo
back to TWRP, immediate pull of `/cache/last_kmsg/kmsg.0`, checked directly against
that capture's own `Booting Into Mission Mode` marker per the methodology rule
established in Round 4). Result: **bounced to Download Mode**, log shows the identical
`No match found for Soc Dtb type` / `Error: Appended Soc Device Tree blob not found`
sequence, at **timestamps identical to the microsecond** (`{ 6527152 }` /
`{ 6539901 }`) to Round 4's original pre-fix failure.

To isolate whether `-@`/`__symbols__` (Round 6) was the actual regression, rebuilt a
second artifact with the identical 3-entry `qcom,msm-id` DTB structure but **without**
`-@` (removed the `DTC_FLAGS_sm8250-samsung-gts7l := -@` line, confirmed the rebuilt
DTB has no `/__symbols__` node and is back to 115071 bytes per copy). Tested the same
way. **Also bounced to Download Mode, also the identical microsecond timestamps.**

**Conclusion: neither the 3-entry appended-DTB fix (Round 5) nor the `-@` addition
(Round 6) has ever actually changed this device's behavior.** All of the following
configurations, tested and captured this round with a verified, marker-anchored log
for each, produce the exact same deterministic `No match found for Soc Dtb type` at
the exact same microsecond timestamp:

- Single-entry DTB, no `msm-id`/`board-id` (original baseline)
- Single-entry DTB with `msm-id`/`board-id`
- 3-entry appended DTB, no `-@`
- 3-entry appended DTB, with `-@`/`__symbols__`

Round 5's "evidence it worked" (the error string absent from 3 post-fix captures) is
now understood to have been the same class of mistake Round 4 already found and
retracted once in this file - those 3 captures almost certainly never contained a
real `Booting Into Mission Mode` session either (this round independently rediscovered,
the hard way, that even a *single* Download-Mode round-trip is enough to evict the
entry from the 2MB ring buffer before the automated capture can save it - see the next
section - so it is entirely plausible none of those 3 "clean" captures ever saw our
kernel attempt at all). Root cause of the ABL's DTB rejection is **back to unknown**.

### The automated capture has a real blind spot: Download Mode dwell time evicts the ring buffer

Confirmed directly this round, twice: a **single** recovery reboot after landing in
Download Mode is sometimes, but not reliably, enough on its own to evict the
`Booting Into Mission Mode` entry before TWRP's `post-fs` capture runs - it worked
cleanly 2 out of 2 times when the button-combo was done immediately, but failed
completely (zero `Mission Mode` markers in any of 3 captures) once, earlier the same
session, when more time/reboots elapsed in Download Mode first. Download Mode itself
appears to generate meaningful log volume while idling (Odin protocol polling,
possibly USB re-enumeration retries) - the faster the round-trip back to TWRP, the
better the odds the entry survives. **Practical guidance: minimize any delay between
a Download-Mode bounce and starting the recovery button combo.**

Attempted to script this with `heimdall close-pc-screen` (auto-exit Download Mode
the instant `heimdall detect` sees it, instead of waiting on manual button timing) -
**did not work, needs more investigation before relying on it**: `heimdall flash`
doesn't recognize a partition literally named `param` in this device's PIT (needs a
`heimdall download-pit` dump to find the real name), and a `--no-reboot` session left
the device's Odin USB protocol in a state where a follow-up `--resume` action failed
with repeated `libusb error -7` on every retry - needs a fresh, uninterrupted heimdall
session per action, not a resumed one, or a different approach entirely. Abandoned
for this round in favor of the manual button-combo, which is slower but was already
working.

Tablet safe throughout: stock `boot.img`/`dtbo.img` restored and reverified by hash
after every test, `param` left at `0x02` (forced-recovery) so it lands in TWRP on the
next power-on, `rp` unaffected.

## Round 8 (2026-09-13): UART hardware dead end fully diagnosed; ABL binary
reverse-engineered directly; a real, documented fix found and applied - not yet
log-confirmed

### UART: the CC-resistor JIG trick is confirmed electrically impossible on this port, not just untried

Extensive hands-on testing (breakout board with a real labeled CC1/A5 pin, multiple
resistor values including the textbook 619kΩ, a dead 0Ω short, both cable
orientations, and a VBUS-powered variant) all produced **zero reaction** from the
tablet's own MUIC/CCIC driver - confirmed via a live kernel-log watcher
(`tools/watch_usb.sh`, run from TWRP's on-device Terminal to survive the USB
disconnect that happens the instant D+/D- are diverted to a TTL adapter). Root
cause, confirmed by a live voltage check (CC idle ≈0V) and cross-checked against
the driver's actual runtime behavior: the tablet's mandatory USB-C sink pull-down
(Rd, ~5.1kΩ) is *always* active per spec and completely dominates any external
resistor in parallel with it (619kΩ ≫ 5.1kΩ) - the ADC genuinely cannot see the
external resistor at all, regardless of value, orientation, or VBUS state. This
matches the microUSB-era ID-pin trick (a dedicated, bias-free pin) not translating
to USB-C's CC line (which can't be bias-free without violating the spec). Getting a
real JIG-UART trigger on this hardware requires an actual PD VDM command (what
Samsung's real "AnyWay" tool does), not a passive resistor - **this class of
approach is now closed, not just deprioritized.**

A promising new lead for the VDM approach, found later this session: the owner's
existing FNB58 USB-C power meter contains a genuine **FUSB302BMPX** PD PHY chip
(confirmed via its QFN14 top-marking "UAAC CEH", cross-referenced to public
teardown/ID sources) - the exact chip `references/vdmtool` was written for. Two
routes identified, neither attempted yet: (a) tap the FUSB302's I2C pins directly
with a separate microcontroller running `vdmtool`'s firmware, which needs the
FNB58's own onboard MCU isolated from the same I2C bus to avoid master contention;
or (b) reflash the FNB58's own MCU (Artery AT32F403A, STM32F103-footprint-compatible,
external SPI flash for firmware) with custom firmware driving its own onboard
FUSB302 over the existing traces - architecturally cleaner (no bus contention) but
needs locating/confirming SWD pads (no existing community documentation found) and
writing real firmware. Left for a future round; noted here so the hardware and the
plan aren't lost.

### ABL binary extraction and disassembly - a real, working methodology, not just a one-off

Directly pulled the `abl` and `xbl` partitions (`adb pull`, read-only, zero risk)
and discovered `abl` is a genuine UEFI Firmware Volume (`_FVH` signature at file
offset `0x24`) containing several embedded PE32 modules, most relevantly one named
**`LinuxLoader`** - extracted cleanly with the `uefi_firmware` Python package
(`pip install uefi_firmware`, provides the `uefi-firmware-parser` CLI) after
confirming plain `strings`/`objdump` don't work directly against the outer
AVB-signed+UEFI-FV-wrapped partition. Located the exact string literals
("No match found for Soc Dtb type" etc.) inside the extracted `LinuxLoader` PE32,
computed their file-offset addresses, then used `capstone` (Python AArch64
disassembler) to find every `ADRP`+`ADD` instruction pair that materializes each
string's address - directly locating the real code, not guessing at it. Full
toolchain: `pip install uefi_firmware pefile capstone` in a local venv
(`work/abl-venv/`, gitignored) - no system packages, no sudo needed. **This
methodology is reusable for any future ABL-behavior question** on this device;
scripts are in `tools/find_string_refs.py` and `tools/dump_func.py`.

Disassembling the function that prints "No match found for Soc Dtb type" confirmed
it genuinely reads `qcom,msm-id`, `qcom,board-id`, and `qcom,pmic-id`, and has a
non-trivial pass/fail bit-flag scheme - `qcom,msm-id`'s chip-id half must match
exactly, its stepping/revision half is lenient (DTB's declared revision must be
`<=` real fused silicon, 0 = wildcard), and there's a hard gate late in the
function requiring a specific flag bit that (as far as traced) only gets set by a
`qcom,pmic-id` array match. **This raised a real, unresolved contradiction**: stock's
own working `boot.img` DTB entries (pulled and decompiled this session, see Round 7)
have no `qcom,pmic-id` at all, yet stock never hits this failure - meaning either
this exact function isn't actually on stock's base-DTB-selection path (most likely
it's the EDTBO/board-overlay matcher instead, which fails harmlessly for stock via
a *different* code path/message), or the bit-gate trace has a subtle error. Could
not resolve by finding the function's caller(s) - it's invoked indirectly through a
function-pointer/protocol table (standard EDK2 pattern), which plain disassembly
can't trace without a full decompiler doing real cross-reference analysis (a
free tool like Ghidra would resolve this cleanly if it comes up again).

### The actual fix applied this round: `qcom,board-id`, sourced from Qualcomm's own binding doc, not from the disassembly dead-end

Redirected from the ambiguous pmic-id lead to checking how a *sibling, real, working*
SM8250 port handles this - `references/kernel_samsung_sm8250` (the droidian-branch
GPL source for the sibling Tab S7+ Wi-Fi, same SoC family) ships Qualcomm's own
official binding document,
`arch/arm64/boot/dts/vendor/bindings/arm/msm/msm-id.txt`, which states explicitly:

> `qcom,msm-id = <chipset_foundry_id, rev_id>` (the 2-field short form) - **"If the
> second format is used one must also define the board-id."**

Our DTS has always used exactly this 2-field short form
(`qcom,msm-id = <0x164 0x10000>;`) and never set `qcom,board-id` at all - a plain,
documented requirement missed since the DTS was first written, independent of and
simpler than every DTB-matching theory chased in Rounds 2-8. Confirmed against
stock's own decompiled DTB (`dtc -I dtb -O dts` on the extracted
`work/stock_dtb_entry0.dtb`): stock pairs the same 2-field `msm-id` form with
`qcom,board-id = <0x00 0x00>;` (a wildcard value) in every one of its 3 stepping
entries. This also retroactively explains Round 2's "Regression 2": that attempt
added the *board overlay's* specific value (`<0x8 0x7>`, copied from
`kona-sec-gts7l-eur-overlay-r07.dts`) to the base DTB, which is the wrong value for
this context - it was never evidence that board-id itself doesn't belong in the
base DTB, just that the *specific value* tried was wrong.

**Applied**: `kernel/dts/sm8250-samsung-gts7l.dts` now sets
`qcom,board-id = <0x00 0x00>;` alongside the existing `qcom,msm-id`, in the single
shared source file patched into all three stepping copies (as before). Rebuilt
clean, confirmed both properties present in the compiled DTB via `fdtget`, freshly
repackaged via the same `magiskboot unpack`/patch-3-copies/`magiskboot repack`
pipeline, and flashed/tested three times.

**Not yet log-confirmed.** All three tests still bounced to Download Mode
behaviorally, but - notably different from every pre-fix test this project has
run - **none of the three post-fix `/proc/last_kmsg` captures contain any trace of
the test boot at all**, not even a partial one, despite reasonably fast
button-combo round-trips each time (compare to Round 7, which caught a clean,
complete capture on its first fast attempt with the pre-fix kernel). The most
likely read: the board-id-fixed boot attempt is generating meaningfully more log
volume before failing - i.e., getting further than before - enough to evict its
own start marker before even one recovery reboot completes. This is circumstantial,
not proof. Tablet restored to stock `boot.img`/`dtbo.img` (hash-verified), `param`
left forced to recovery, `rp` unaffected.

**Next step, not yet started**: either burn another capture round with an even
faster round-trip (a scripted `heimdall` fast-exit from Download Mode was attempted
in Round 7 and didn't work yet - PIT partition naming, stuck USB session; worth
finishing this since human reaction time is likely now the dominant delay), or
pursue the FNB58/FUSB302 UART path above to get a live, ring-buffer-independent
view instead of continuing to fight capture eviction.

## Round 9 (2026-09-13, later): `qcom,board-id` fix CONFIRMED working; a real, later,
different blocker found - our "noop" DTBO's structure

Finished the `heimdall` fast-exit approach from Round 7/8: the PIT partition name
for `param` is `PARAM` (uppercase - heimdall's `--param` flag failed silently
against the real PIT entry name, which is case-sensitive). Also confirmed
**heimdall only tolerates one protocol session per Download Mode boot** - a
`download-pit` call followed by a separate `flash` call in the same Download Mode
entry reliably fails the second action with `ERROR: Failed to receive handshake
response. Result: -7`, even with `--resume`. Do the actual write as the *first and
only* heimdall action per boot, letting it auto-reboot rather than chaining a
second `close-pc-screen` call.

That faster round-trip (button-combo issued immediately after the heimdall session
was exhausted, one single intervening recovery boot) finally caught a clean,
complete capture of the `qcom,board-id`-fixed boot attempt. Result: **confirmed,
unambiguous progress**:

```
Booting Into Mission Mode
  ↓ (normal AUTHENTICATE fail-but-allow sequence for vbmeta/boot/dtbo, as always)
Memory Base Address: 0x80000000
Unable to find the Board Dtb          <-- NEW - "No match found for Soc Dtb type" is GONE
Error: Board Dtbo blob not found      <-- NEW, different message than before
init cc mode flag 0x0
  ↓ (continues normally - RP/SWREV checks, FRP, KG status, HDM status, DID display,
     all the way to a genuine, deliberate Download Mode UI draw sequence)
Odin: CmdsInit start / EnumeratePartitions / Odin: CmdsInit Success
odin: processing commands
```

**`No match found for Soc Dtb type` / `Error: Appended Soc Device Tree blob not
found` never appear anywhere in this capture.** The appended 3-entry kona-stepping
DTB (with `qcom,board-id` added, per Round 8) is now matching successfully - this
is the first time in the whole project our own kernel/DTB has gotten past ABL's
DTB-identity check. The boot proceeds much further than ever before (RP/SWREV/FRP/
KG/HDM checks, device ID display) before *deliberately* entering Download Mode's
UI over a **new, different, later-stage failure**: `Unable to find the Board Dtb`
/ `Error: Board Dtbo blob not found` - pointing at the **DTBO** (board overlay)
partition, not the kernel/DTB.

This is a different failure than stock's own normal `EDTBO check fail` →
`Apply Overlay total time` → `Final Dtb version = 0` → continues (non-fatal, per
every earlier round's baseline evidence). "Unable to find the Board Dtb" reads as
a more fundamental "couldn't locate/parse any valid board-DTB table entry at all"
- plausibly because our `kernel/dtbo/gts7l-noop.dts` (a deliberately near-empty
plugin overlay, built early in the project specifically to avoid Samsung's real
downstream dtbo overlay corrupting our upstream-based DTS) lacks whatever
identity/table metadata (`id`/`rev`/`custom0-3` fields in the Android DTBO image
table format) ABL now searches for, now that `qcom,board-id` on the base DTB gives
it something to search *against*. This stage was never reached before this round,
since every earlier test died at the DTB-matching stage first.

**Not yet fixed at the time this section was first written.** See Round 9 below
for what was actually tried and found.

Tablet safe throughout: stock `boot.img`/`dtbo.img` restored and hash-verified,
`param` forced to recovery, `rp` unaffected.

## Round 9 (2026-09-13, later): two well-evidenced DTBO fix attempts, both
disproven by identical-log evidence; real root cause still open

### Attempt 1: noop overlay entries with real Samsung "selector" properties, per the S9 Ultra project's own documented approach

Dumped our noop `dtbo.img`'s table (`mkdtboimg dump`) against stock's real
`dtbo.img` (`work/stock-backup/dtbo.img`, already backed up). Table header
metadata (`id`/`rev`/`custom0-3`) is identical (all zero) in both - not the
difference. The real difference: our noop's entries all pointed to the same
140-byte, completely empty `{ fragment@0 { target-path = "/"; __overlay__ {}; }; }`
blob, while stock has 9 genuinely distinct entries - entry 0 a tiny 101-byte
`dtbo-version = <0x01>` marker, entries 1-8 real ~330KB per-region board
overlays, **each with root-level identity properties**
(`model`, `compatible = "qcom,kona-mtp", "qcom,kona", "qcom,mtp"`,
`qcom,board-id = <0x08 N>`) sitting outside the fragment/overlay body itself.
Entry 7's `qcom,board-id = <0x08 0x07>` matches this exact physical unit (its
`model` string, `"Samsung GTS7L PROJECT - PV REV0.4 (board-id,7)"`, is the same
string seen in TWRP's own dmesg `Hardware name:` line earlier this session).

Checked `references/postmarketos-galaxy-tab-s9-ultra`'s own porting log
(`docs/development-notes.md`) for how a sibling project solved the equivalent
problem, per the owner's direction - and found they'd tried exactly this:
*"overlays no-op con los selectores Samsung"* (no-op overlay bodies, but keeping
Samsung's real selector/identity properties). Built the same thing here: a
corrected `dtbo.img` with entry 0 = stock's exact 101-byte version marker
(byte-identical, confirmed) and entries 1-8 = our existing empty overlay
(unchanged). Flashed and tested. **Identical failure** -
`Unable to find the Board Dtb` / `Error: Board Dtbo blob not found`, at the exact
same microsecond timestamps as every prior test.

### Attempt 2: deliberately invalid `dtbo` to force ABL's non-ufdt fallback, per the same sibling project's actual eventual fix

Reading further in that same porting log: the S9 Ultra project found the
"noop-with-real-selectors" approach (their own version of Attempt 1) was
*also* insufficient for them - it fixed their equivalent of
`No match found for Soc Dtb type`, but then hit `ApplyOverlay: ufdt apply
overlay failed` → `Root Node is not found at BoardDtb` → Odin, the same class of
failure as our current one. Adding `-@`/`__symbols__` didn't help them either.
Their actual fix, found by reading Qualcomm's own reference ABL source
(`BootLinux.c`, `LoadAndValidateDtboImg`): **if `dtbo` is not a valid Android
DTBO table at all, ABL skips `GetBoardDtb`/`ufdt_apply_overlay` entirely** and
falls back to `DeviceTreeAppended` - looking for an FDT concatenated directly
after the kernel image, the same general shape as our own already-working
appended-DTB mechanism. Their fix: `dtbo` starts with zero bytes (invalid magic)
to force this fallback, kernel+DTB concatenated directly in `boot`. Their
physical test got further than ever before - a real Linux framebuffer logo
appeared, with the eventual failure moving from the bootloader into Linux/
firmware itself.

Built the same thing: `dtbo.img` as 4096 bytes of all zeros (no `d7b7ab1e`
magic). Flashed and tested. **Also identical failure**, same messages, same
microsecond timestamps.

### The two tests' logs are provably byte-identical, not just "similarly worded"

Diffed the full captured logs from both tests directly (not just eyeballing the
error strings) - **the exact ~150-line ABL sequence from `Booting Into Mission
Mode` through the Download Mode entry is byte-for-byte identical between the
real-selectors test and the all-zero-invalid test**, down to every microsecond
timestamp. (The overall capture files do genuinely differ elsewhere - different
sizes, different md5, different TWRP-runtime noise from being two separate
reboot cycles - so this isn't a stale/reused capture; verified directly on
request rather than assumed.) **This means whatever produces "Unable to find
the Board Dtb" is not reading from the `dtbo` partition's content at all** -
neither test's `dtbo` changes moved the needle even slightly, which
contradicts the working assumption from both attempts above.

### Disassembly in progress, not concluded

Located and disassembled the actual function (`LinuxLoader` PE32, same
extraction/disassembly method as Round 8 - see `tools/find_string_refs.py` and
`tools/dump_func.py`) that prints both error strings. Confirmed: it takes a
pointer (`x1`, checked for NULL) to what is structurally a `dt_table_header`
(field at offset `0x14`, byte-swapped, matches `dt_entries_offset` exactly) and
loops over its entries the same way the base-DTB msm-id/board-id/pmic-id
checker (`0x25700`, from Round 8) does - in fact it *calls* `0x25700` per
candidate entry. Given the dtbo-content-invariance finding above, the open
question is where `x1` actually comes from - not yet traced to its caller (the
`find_callers2.py` search for direct `bl` references to this function's start
found none, meaning - same as Round 8's experience - it's likely invoked
indirectly through a function-pointer/protocol table). Worth resuming with a
real decompiler's cross-reference analysis (Ghidra) rather than continuing to
guess at DTBO content, since two independent, well-evidenced content changes
have now both been disproven.

**Status: real fix not found this round.** The `qcom,board-id` fix (Round 8) is
still confirmed working and should stay applied. The DTBO/"Board Dtb" blocker is
a genuine, distinct, unsolved problem - not something more blind content-guessing
is likely to resolve, given two independent attempts already failed identically.

Tablet safe throughout: stock `boot.img`/`dtbo.img` restored and hash-verified,
`param` forced to recovery, `rp` unaffected.

### Two more attempts, same round: stock's real (unmodified) dtbo, and the exact real board-id in the appended DTB - both also disproven

Per the owner's direction, checked how a *same-chip-family* sibling project
(`references/galaxy-tab-s7-plus-droidian`, a real working Halium/Droidian port
for the sibling Tab S7+ Wi-Fi, same SM8250 as `gts7l` - unlike the S9 Ultra
project's different SM8550 checked above) handles this. Their README flashes
`droidian/data/dtbo.img` - **stock's own real dtbo, essentially unmodified**
(only patched for one unrelated hardware quirk, trackpad orientation) - no
noop/invalid trick at all. Tested the same way here: flashed stock's real,
completely unmodified `dtbo.img` (already backed up) alongside the
`qcom,board-id`-fixed kernel. **Identical failure, identical microsecond
timestamps** to both DTBO variants above.

That's three independent `dtbo` content variations (noop-with-selectors,
all-zero-invalid, stock's real unmodified dtbo) all producing byte-identical
results. Reconsidered the theory: maybe "Board Dtb" reads identity from the
*appended DTB itself* (the same blob already fixed for the base-DTB stage),
requiring an **exact** `qcom,board-id` match rather than tolerating the
wildcard `<0x00 0x00>` used to fix the earlier stage. This physical unit's real
board-id is confirmed two independent ways: stock `dtbo.img`'s `entry.7`
(`qcom,board-id = <0x08 0x07>`, `model = "...PV REV0.4 (board-id,7)"`) and
TWRP's own kernel `Hardware name:` dmesg line, which shows the identical string.
Changed `kernel/dts/sm8250-samsung-gts7l.dts`'s `qcom,board-id` from `<0x00
0x00>` to `<0x08 0x07>`, rebuilt all three stepping copies, repackaged, and
tested (with the simple noop `dtbo.img`, since dtbo content is now proven
irrelevant). **Identical failure, identical microsecond timestamps, a fourth
time.**

**Four independent, well-reasoned content changes now all produce byte-for-byte
identical ABL behavior.** This is strong evidence that whatever determines
"Board Dtb" success or failure isn't reading identity from *anything* under our
control right now - not `dtbo`'s content, not the appended DTB's `qcom,board-id`
value. It may be checking against a fused hardware value, a different partition
entirely, or a factory-provisioned value that can't be replicated from a custom
build. **Blind content-guessing on this specific stage should stop here** - the
next productive step is tracing the actual code (the `x1` pointer into the
`0x26744` function, still not traced to its source - see below) with a real
decompiler, not more DTS/DTBO variations.

`qcom,board-id` is left at `<0x08 0x07>` in the DTS going forward (the real
value, confirmed correct for this unit two independent ways) even though it
didn't change this particular outcome - there's no reason to revert to the
wildcard now that the real value is known.

Tablet safe throughout (this second half of Round 9): stock `boot.img`/
`dtbo.img` restored and hash-verified again, `param` forced to recovery, `rp`
unaffected.

### Ghidra installed; the real mechanism fully mapped via actual decompilation, not more guessing

Installed Ghidra (`pacman -S ghidra`, Arch `extra` repo) and used it headless
(`analyzeHeadless`, no GUI in this environment) to properly decompile
`LinuxLoader.pe` instead of continuing with plain `capstone` disassembly.
**Full writeup, reusable scripts, and saved decompiled source for every
function involved: `docs/ghidra-analysis/README.md`.** Summary of what was
learned (all confirmed from real decompiled C, not inferred from raw asm):

- The function Round 8 manually identified as "the msm-id/board-id/pmic-id
  checker starting at 0x25700" was correct, but a *different* address
  (`0x26744`) that Round 8 treated as a separate calling function turned out,
  under Ghidra's real function-boundary analysis, to just be the tail end of
  an unrelated function - a genuine correction to Round 8's methodology, kept
  in the writeup so it isn't repeated.
- The real chain: `BootLinux()` calls the base-DTB matcher (which Round 8/9
  already fixed via `qcom,board-id`). That matcher does more than just
  accept/reject - it also checks whether the match hits a specific 6-bit
  "**exact match**" quality bar. If so, ABL prints `"Exact DTB match found.
  DTBO search is not required"` and skips the whole strict per-region DTBO
  search entirely (going to a harmless, always-fails-safely optional
  "Override DTB" mechanism instead - which happens to share the same
  `"Error: Board Dtbo blob not found"` string, a confusing coincidence, not
  the same code path as our actual failure). If the match is only
  "acceptable" but not "exact" (our situation), ABL proceeds into the strict
  DTBO search, which is what's actually printing `"Unable to find the Board
  Dtb"`.
- The exact-match bit mask (`0x34150000`) was decoded bit-by-bit against the
  matcher's real logic - full table in `docs/ghidra-analysis/README.md`. Two
  concrete, actionable findings: (a) one required bit needs `qcom,pmic-id`'s
  first cell to exactly match a live hardware "PMIC model" register value we
  don't know; (b) another required bit needs `qcom,msm-id`'s foundry byte to
  be a real non-zero exact match - **structurally impossible with this DTS's
  current wildcard-foundry `qcom,msm-id` value**, matching stock's own
  kona.dtsi convention.
- **A real, unresolved puzzle, more important than the above**: stock's own
  actual compiled appended-DTB (`work/stock_dtb_entry{0,1,2}.dtb`, extracted
  earlier this project) has **no `qcom,pmic-id` at all** - meaning stock
  itself cannot be satisfying this exact-match mask either. Stock most likely
  reaches Linux via a genuinely different boot-chain mechanism than what our
  magiskboot-repacked `boot.img` triggers on this ABL, not by hitting this
  same exact-match bypass. This calls into question whether chasing "exact
  match" here is even the right strategy at all, independent of whether the
  DTS values can be made correct.

**Tried one concrete, cheap experiment based on this new understanding**: set
`qcom,pmic-id = <0x1e 0x00 0x00 0x00>` (`0x1e` from the live kernel's own
`/sys/devices/soc0/pmic_model` sysfs value, `65566` = `0x1001E`, low byte taken
as a candidate hardware "model" register value - the best real evidence
available without verbose ABL logging). Tested on hardware: **identical
failure**, same as every prior attempt.

**Real verbose ABL logging (which would give the literal correct values
directly, via `"PMIC Model 0x%x: 0x%x\n"`-style debug prints already present in
the binary) is blocked**: the log-level gate reads the standard EDK2
`"EFIDebug"` UEFI variable, but this Android kernel doesn't expose `efivarfs`
userspace access to set it. The device does have a `uefivarstore` partition
that almost certainly holds the raw variable store - writing to it directly
would need reverse-engineering EDK2's variable-store binary format, a real
side-project of its own (not started).

**Status at the end of Round 9**: `qcom,board-id` (Round 8) remains a
confirmed, real fix and stays applied. The "Board Dtb"/exact-match mechanism is
now genuinely, thoroughly understood at the code level (not guessed) - but the
actual values needed either aren't obtainable without more tooling investment,
or (per the stock-DTB puzzle above) may not be the right thing to chase at all.
Tablet safe: stock `boot.img`/`dtbo.img` restored and hash-verified, `param`
forced to recovery, `rp` unaffected.

## Round 10 (2026-09-13, later): the real answer - stock never takes the
FUN_00025490/FUN_00026748 path at all; it's a fallback for AVB verification
failure

Per the owner's direction, directly investigated why stock's boot chain skips
the whole "exact match" mechanism, rather than continuing to guess at DTB/DTBO
content within it.

### Ruled out by direct hardware test: single vs. multi-entry appended DTB doesn't matter

Before finding the real answer, one more theory was tested and disproven:
maybe having 3 concatenated stepping DTBs (vs. a genuine single DTB) forces
entry into the strict matcher instead of a simpler "single appended DTB found"
fast path that Ghidra's decompilation of `BootLinux()` showed also exists.
Built a boot.img with a single (not triple-concatenated) DTB entry (the
v2.1/`0x20001` stepping, matching what's positioned first in stock's own
appended blob) and tested on hardware. **Identical failure, identical
microsecond timestamps** to every multi-entry test. This conclusively rules
out DTB entry-count as a factor - something about `FUN_000325f8`'s gating
condition (traced but not fully resolved by manual reading - see
`docs/ghidra-analysis/README.md` for the attempted trace and where the
reasoning got tangled) makes us take the strict-matcher branch every time,
independent of appended-DTB structure.

### The actual answer: flash 100% stock and read its own real boot log

Rather than continue inferring from partial traces, did the obvious direct
test that hadn't been done yet: flashed **completely unmodified** stock
`boot.img` and `dtbo.img` (already had them backed up and hash-verified) and
did a **real, normal `adb reboot`** (not a recovery-combo boot) - genuinely
letting stock's own, properly-signed firmware boot all the way. It booted
into real Android normally, as expected for unmodified stock firmware. With
USB debugging already enabled and Magisu root present from before this
project began, read `/proc/last_kmsg` **live, directly from the running
Android session** (`su -c 'cat /proc/last_kmsg'`) - zero ring-buffer-eviction
risk at all, since no intervening reboot was needed. Saved to
`work/stock-boot-evidence/stock-normal-boot-kmsg-20260913.txt` (gitignored,
large/device-specific - regenerate the same way if needed again).

**Stock's real, successful boot sequence, checked directly against its own
`Booting Into Mission Mode` marker:**

```
Memory Base Address: 0x80000000
EDTBO check fail
Apply Overlay total time: 393 ms
Final Dtb version = 0
[continues normally into RAM Partitions setup, IDDQ fuses, etc. - exactly the
 same continuation this project first saw, and mistakenly attributed to our
 own kernel, all the way back in the now-retracted Round 4 "confirmed
 baseline" claim]
```

**None of `No match found for Soc Dtb type`, `Unable to find the Board Dtb`,
or `Error: Board Dtbo blob not found` appear anywhere in stock's real boot.**
Stock never enters `FUN_00025490`/`FUN_00023f20`/`FUN_00026748` at all - the
entire "exact match" mechanism this project spent Round 9 reverse-engineering
is a **fallback path stock's own real boot never uses**.

### Why: AVB verification success vs. failure almost certainly selects which entire mechanism runs

Working theory, well-supported by everything observed this project but not
yet directly proven: ABL's DTB-selection strategy branches on whether the
current boot image's **AVB verification actually succeeds**, not just on
content. Stock's real `boot.img`/`dtbo.img` are signed with hash descriptors
in `vbmeta` that genuinely match their content, so AVB verification passes,
and ABL takes the trusted "EDTBO" (AVB-driven overlay-application) path. Our
own `magiskboot`-repacked custom images have always relied on this project's
`orange`/unlocked-bootloader "AUTHENTICATE fail but allow" leniency (confirmed
early in this project, Round 1/`docs/kernel-boot-debugging.md`'s "ABL fail but
allow" section) - `magiskboot repack` regenerates the SEANDROID/AVB footer's
size/offset fields automatically, but very likely does **not** recompute
matching cryptographic hash descriptors in `vbmeta` for our modified content.
AVB verification for our images almost certainly genuinely fails every time,
and ABL falls back to the legacy appended-DTB/DTBO-table mechanism (Round
5-9's entire investigation) specifically *because* the trusted path isn't
available - a mechanism that, on this particular retail firmware, needs real
hardware PMIC/foundry values this project has never been able to obtain.

**This reframes the whole project's current blocker.** Continuing to tune
DTS/DTBO values for the fallback mechanism may never fully succeed (its
"exact match" requirement needs data - real PMIC model/revision, real msm-id
foundry byte - that isn't available from any source found so far, including
stock's own real DTB/DTBO, which also don't have it). **The more promising
path: make our custom `boot.img`/`dtbo.img` genuinely AVB-verify
successfully**, so ABL trusts them and takes the same "EDTBO" path stock
uses, bypassing the whole `FUN_00025490` mechanism entirely. This would need:

1. Understanding `vbmeta`'s actual descriptor structure for this device (it's
   currently AVB-disabled/permissive per this project's own
   `vbmeta_disabled.img` artifacts, but that only affects verification
   *enforcement* - ABL may still compute and compare hashes even when not
   enforcing, taking a different success/failure branch based on the
   comparison result specifically, independent of whether a failure would
   actually block boot).
2. Using `avbtool` (or the same signing approach `magiskboot`/AnyKernel3
   projects use for a "properly AVB-aware" repack, if one exists) to
   regenerate correct hash descriptors for our modified `boot`/`dtbo` content,
   rather than relying on `magiskboot repack`'s automatic (but
   hash-incorrect) footer regeneration.

**Not yet attempted.** This is the clear next step, and a genuinely different
strategy than everything tried in Rounds 5-9.

Device state at end of this round: currently booted into **real, unmodified
stock Android** (not TWRP) - this is intentional and safe (completely
original firmware, nothing modified). Get back to TWRP via the recovery
button-combo before the next round of testing. `rp` unaffected throughout.

### Follow-up (same session): traced "EDTBO check fail" directly; DTB-content explanation ruled out with real evidence, not just theory

Went looking for the actual `"EDTBO check fail"` string's code (never directly
examined before this point - only inferred its behavior from stock's log).
Found it's inside `BootLinux()` itself (`FUN_00020590`), reached only after
`FUN_00023f20()` (the exact-match-flag check) returns `FALSE` - i.e. only
reachable once the base-DTB matcher has already set `DAT_00255278 = 1`.
Confirmed by re-reading the surrounding code carefully: **"EDTBO check fail"
is not fatal** - whether it fails or succeeds, execution falls through to a
harmless continuation (`Final Dtb version = 0` on failure - exactly what
stock's own capture shows), not an abort. `"Override DTB"`/`user_dtbo`
(`FUN_000263c8`) also unconditionally fails for stock too - confirmed
directly, `"Override DTB: GetBlkIOHandles failed loading user_dtbo!"` appears
12 times in stock's own real capture. None of that matters; the branch stock
takes is fundamentally the lenient one, regardless of what happens inside it.

This means reaching `EDTBO` at all requires `DAT_00255278 = 1`, which can only
be set inside `FUN_00025490`'s "exact match" check (mask `0x34150000`,
Round 9). The confirming print for that (`"Exact DTB match found..."`) is
itself gated behind the same `0x400000` verbose-logging level already known
to be disabled - so it doesn't appear in stock's capture even when the flag
genuinely gets set, explaining why it wasn't found there without
contradicting anything.

**The decisive point**: this project has *already* directly tested, on real
hardware, a DTB with no `qcom,pmic-id` at all (matching stock's own real DTB
structure exactly) *and* a specific, real `qcom,board-id = <0x08 0x07>`
(more specific than stock's own wildcard `<0x00 0x00>`) - i.e. identity data
at least as complete as stock's. **It still failed identically to every other
attempt.** Since the matcher's code is identical in both cases and the DTB
content tested is not worse than stock's, whatever actually differs must be
external to DTB content - most likely the live hardware-comparison functions
(`FUN_0001fee0`, `FUN_0001ff28`, `FUN_0001ff70`, `FUN_00013de8`,
`FUN_00020118`, etc.) returning different data depending on the boot image's
verification/trust state, or a gate not yet located. This is now supported by
direct empirical elimination of the DTB-content explanation, not just
inference from stock's log alone - reinforces, rather than weakens, the
AVB-verification theory from earlier in this round.

**Conclusion for next steps: stop looking for more DTS/DTBO content fixes -
this has now been ruled out with real hardware evidence twice over (Round 9's
four content variations, and this round's content-matches-or-exceeds-stock
test). Pursue proper AVB re-signing (`avbtool`) as the concrete next
direction**, per the theory above - not yet attempted.

## Round 11 (2026-09-13, later): AVB re-signing tried and also disproven -
neither theory holds up under direct hardware test

Per the owner's direction, started the `avbtool` work. First correction to
Round 10's own theory: initially checked the wrong images (`vbmeta.img`/
`vbmeta_samsung.img`, pulled directly from a live, normally-booted stock
Android session with pre-existing Magisk root - no TWRP round-trip needed,
zero eviction risk) and found neither carries a hash descriptor for `boot`/
`dtbo` at all, which looked like it disproved the whole AVB theory. Corrected
immediately by checking `avbtool info_image` on `boot.img`/`dtbo.img`
directly instead - **both carry their own embedded, genuinely-signed
`SHA256_RSA4096` hash descriptor** (same signing key as `vbmeta_samsung.img`,
the standard Android "chained partition" AVB pattern) - the vbmeta
partitions don't need their own entries for these because boot/dtbo are
self-contained.

**Confirmed directly, not just inferred**: our `magiskboot`-repacked
`boot.img`'s AVB descriptor is completely stale - it still claims `Image
Size: 53703184 bytes` (stock's original kernel+ramdisk size) while the
image's actual content is `42323984 bytes`. `magiskboot repack` regenerates
the Samsung-specific SEANDROID/AVBf footer fields but never touches the real
AVB hash descriptor at all - it's byte-for-byte copied from stock, describing
content that no longer exists in the image. Same finding for `dtbo`: our
noop `dtbo.img` was only ever 4096 bytes written to the front of a 10MB+
partition - the real AVB footer (fixed at the partition's end, per the AVB
spec) was always stock's own stale footer for the REST of that partition,
never touched by any of Round 9's content experiments. This was true for
every dtbo test in Rounds 9-10 without anyone noticing - a real methodology
gap now closed.

### The test: self-consistent (but not Samsung-trusted) re-signing

Found a real RSA-4096 test key already available locally
(`external/avb/test/data/testkey_rsa4096.pem`, from a local AOSP/LineageOS
checkout) and used `avbtool add_hash_footer` to regenerate a **genuinely
self-consistent** footer for both `boot.img` (the `qcom,board-id`-fixed
kernel/DTB build) and `dtbo.img` (the noop overlay, now correctly sized to
fill the entire partition so no stale stock footer remnant survives) - hash
and size both now correctly describe the actual modified content, signed
with a real (if untrusted-by-Samsung) key. `avbtool verify_image` confirmed
the footer/signature is internally valid.

This can never pass Samsung's actual root-of-trust (no access to Samsung's
private key) - the point was to test whether having a *structurally correct*
descriptor, as opposed to a *stale/garbage* one, changes ABL's behavior at
all at the DTB-matching stage, given "fail but allow" already tolerates
*some* kind of authentication failure regardless.

Flashed both re-signed images directly from a live, rooted stock Android
session (no TWRP needed for flashing either - root via Magisk was already
present). Tested twice; the first capture was evicted (matches the pattern
already seen with the `qcom,board-id` fix - more boot activity, more log
volume, harder to catch), the second capture attempt hit an unrelated
methodology snag (`heimdall`'s automated `PARAM` write reported success but
lost the session-end handshake, leaving the device in a genuinely
unresponsive black-screen state - resolved by a forced power-cycle, which
landed the device in Samsung's RDX crash-dump diagnostic screen, itself
safely exited via the on-screen `VOL_DOWN + POWER` combo; **RDX mode
appearing is a normal consequence of any forced/abrupt reset on this
device, not a new failure mode from the test itself** - worth remembering
if it comes up again). A third attempt, immediately after landing back in
TWRP from the RDX detour, finally caught a clean capture.

**Result: identical failure.** `Unable to find the Board Dtb` / `Error:
Board Dtbo blob not found`, same as every DTB-content variation before it.
The self-consistent-but-untrusted signature made no observable difference.

### What this actually establishes

Two independent, well-motivated theories have now both been disproven by
direct hardware test, not just argued away:
1. DTB/DTBO **content** tuning (Round 9, four variations; Round 10, a
   content-matches-or-exceeds-stock test).
2. AVB **verification passing vs. failing in a generic sense** (this round) -
   "fail but allow" appears to treat a self-consistent-but-wrong-key
   signature exactly the same as a stale/garbage one; whatever differs about
   stock isn't simply "does the hash check succeed at all."

If ABL's exact-match/EDTBO path genuinely does require Samsung's own actual
private key to trust the signature (not just a well-formed one), this path
may be **fundamentally unreachable** for any custom-signed kernel on this
retail firmware, independent of anything this project does. That's a real,
sobering possibility worth taking seriously rather than continuing to invent
new signing variations to try.

**Status**: both concrete, testable theories from Round 10 are now closed
out. The remaining path with a realistic chance of a definitive answer is
still the one identified back in Round 9 and never pursued: unlocking real
ABL verbose logging (the `"EFIDebug"` UEFI variable, requiring a raw write to
the `uefivarstore` partition's EDK2 variable-store format) to see the
*actual* comparison values ABL is using, rather than continuing to guess at
mechanisms from behavior alone. `qcom,board-id = <0x08 0x07>` stays applied
(still correct, still real progress from Round 8) regardless of how this
resolves.

Tablet safe throughout: stock `boot.img`/`dtbo.img` restored and
hash-verified, `param` forced to recovery, `rp` unaffected.

## Round 12 (2026-09-17): Two real working sibling kernels reveal the actual
fix — stop replacing the DTB/DTBO at all

No hardware touched this round; pure research, prompted by the owner
surfacing two real, publicly-distributed custom kernels for SM8250 "kona"
Tab S7 family devices and asking whether they're useful.

### Source 1: Quantic Kernel (SM-T870, Tab S7 Wi-Fi)

`Official-Ayrton990/android_kernel_samsung_sm8250`
(`SM-T870_EUR_RR_Opensource` branch, release `r1.0`). Confirmed via the
repo's own kernel source that `qcom,pmic-id` (as a numeric boot-identity
DT property, not the unrelated string-type regulator-naming convention)
appears nowhere in this real, complete kona/SM8250 source tree —
reinforcing that `pmic-id` was very likely a red herring in this project's
own Round 9 investigation, not a missing requirement.

Downloaded the actual flashable zip and inspected it directly
(`unzip -l`, `file`, a Python FDT-magic scan, `dtc -I dtb -O dts`,
`fdtget`). Findings:
- It's a standard AnyKernel3 package: `Image` + a single `dtb` + `anykernel.sh`
  + `tools/{magiskboot,ak3-core.sh,...}`. `ramdisk/` and `patch/` are both
  empty placeholders — it does not touch the ramdisk.
- The `dtb` is a genuine single, non-concatenated FDT (one magic offset,
  at position 0) — not the 3-concatenated-stepping-copy structure this
  project adopted in Round 5 based on stock's own boot.img structure.
- Its root node: `compatible = "qcom,kona"`, `qcom,msm-id = <0x164 0x20001>`,
  `qcom,board-id = <0 0>`.

Cross-checked `qcom,board-id = <0 0>` against the decompiled ABL matcher
(`FUN_00025700`, see below) expecting a "wildcard" explanation — but the
decompiled logic doesn't actually support that reading (see "Correction"
below). The real explanation turned out to be in Source 2.

### Source 2: itzreesa's KSU-Next kernel (SM-T875, Tab S7 **LTE** — our exact
device)

`itzreesa/android_kernel_samsung_sm8250` (`lineage-23.2` branch,
"Based on LineageOS/android_kernel_samsung_sm8250" — a real, actively
maintained LineageOS-lineage downstream kernel for this exact device
family, built via KSU-Next + Droidspaces, proven working on the owner's
exact hardware per the XDA thread). This is a far more direct comparison
than Source 1 since it's the **LTE variant**, not Wi-Fi-only.

Its `arch/arm64/boot/dts/samsung/gts7l/Makefile` confirms the base DTB
structure this project adopted in Round 5 is correct for this device:
`SEC_KONA_BASE_DTB := kona.dtb kona-v2.dtb kona-v2.1.dtb` (three concatenated
stepping DTBs), with per-region DTBO overlays built separately via
`CONFIG_BUILD_ARM64_DT_OVERLAY` — the same base+overlay split stock and
this project both use. Its `kona-sec-gts7l-eur-overlay-r07.dts` root node:
`qcom,board-id = <8 7>` — **matches this project's own fixed value from
Round 8 exactly.** This is strong, independent confirmation that this
project's devicetree content (base DTB structure, `board-id`, `msm-id`) has
been correct since Round 8; the blocker was never DT property content.

**The actual answer was in the release packaging.** Downloaded
`kernel-gts7l.zip` (the LTE build, matching our device) and inspected it:
- Contains only `Image` (raw kernel, confirmed via `file` — no `Image.gz`,
  no appended FDT: a Python FDT-magic scan of the whole 55MB file found
  **zero** matches) plus the standard AnyKernel3 `tools/`+`anykernel.sh`.
- **No `dtb` file. No `dtbo` file. Neither is touched at all.**
- `anykernel.sh` sets `BLOCK=/dev/block/by-name/boot` (the DTBO partition
  is never referenced anywhere) and calls AnyKernel3's stock
  `dump_boot`/`write_boot` — which unpacks *whatever boot.img is currently
  on the device*, swaps in only the new kernel binary, and repacks. The
  DTB appended inside boot.img, and the entire `dtbo` partition, are left
  100% stock, untouched, unmodified.

### Correction to the initial "board-id wildcard" reading

Before finding Source 2's packaging approach, considered whether Source 1's
`qcom,board-id = <0 0>` was being treated by ABL as an explicit "match any
board" wildcard. Read the actual decompiled matcher
(`docs/ghidra-analysis/FUN_00025700.c`) to check: at the board-variant
comparison (`iVar7 != iVar9`), if the DT's variant field is `0` the code
does jump past the mismatch-failure branch (`goto LAB_00025b68`) — but that
jump *also* skips the line immediately before the label
(`*puVar19 |= 0x10000000`), which is the only place that sets the bit
required by the "exact match, skip DTBO search" mask (`0x34150000`) for
board-variant. So `board-id = <0,0>` does **not** grant exact-match status
through this path; it's not a wildcard for that purpose. This matters
because it means Source 1's single-DTB approach is *not* relying on hitting
ABL's lenient fast path either — it's almost certainly relying on the same
mechanism confirmed directly in Source 2: **not shipping a new DTB/DTBO at
all**, so ABL's strict per-region DTBO matcher (`FUN_00026748`, this
project's current blocker) is matching against completely unmodified stock
content and trivially succeeds.

### What this actually establishes

Two independent, real, hardware-proven kernels for this exact SoC
family — one of them for this project's *exact* device (SM-T875) sharing
this project's *exact* `board-id`/base-DTB values — both avoid the
"Board Dtb"/"Board Dtbo" matching problem entirely by never giving ABL a
custom DTB or DTBO to match against. Neither is solving the DTB-matching
problem this project has spent Rounds 4-11 on; both sidestep it. This
strongly suggests Phase 1's actual blocker was never really "get a custom
DTB/DTBO to match" — it was "a custom DTB/DTBO was being flashed at all,"
which isn't required just to prove a differently-built kernel can boot
past ABL.

**Pivot for the next test** (not yet attempted on hardware — see updated
`plans/roadmap.md` Phase 1 entry): repack `boot.img` with **only the kernel
component replaced**, keeping the DTB currently appended in stock's own
boot.img byte-for-byet as-is (do not substitute this project's own DTS
output), and leave `dtbo.img` completely untouched/unflashed (restore
stock, don't flash the Round 8/9 noop or content-tuned versions at all).
This mirrors exactly what both Source 1 and Source 2 do, and is a
single-variable change from every test in Rounds 4-11 (all of which always
replaced the DTB, the DTBO, or both). If this boots past ABL, it confirms
the DTB/DTBO matching was never actually the blocker for *this* narrower
goal — it was always solvable by just not touching those partitions. Full
mainline devicetree work would then move to Phase 2 (once a kernel boots
at all) rather than being a Phase 1 prerequisite. The `uefivarstore`
verbose-logging work (still not attempted, `uefivarstore` partition
confirmed completely empty/zeroed this session) remains available as a
fallback if this pivot test doesn't resolve things, but is no longer the
most promising next step.

Tablet untouched this round — pure research, no flash/reboot cycles.
Stock `boot.img`/`dtbo.img` still restored and hash-verified from Round 11,
`rp` unaffected.

## Round 13 (2026-09-17): The pivot test — real hardware confirms it. First
time ever past every DTB/DTBO blocker.

Built the Round 12 pivot directly: `magiskboot unpack -h` on stock
`boot.img`, replaced only the `kernel` component with our own built
`work/linux/arch/arm64/boot/Image` (40,925,696 bytes), left `ramdisk.cpio`
and `dtb` completely untouched (dtb stayed byte-identical to stock,
1,556,447 bytes both before and after repack, confirmed via
`magiskboot unpack -h` on the repacked image), `magiskboot repack`. No
`dtbo.img` built or flashed at all this round - stock's `dtbo` partition
was left alone, unflashed, for the first time in this project.

Flashed via a Windows VM (native Odin) after `odin4` on Linux hit a real
USB permissions gap (`ioctl bulk read Fail : Connection timed out` - no
`/etc/udev/rules.d/51-android.rules` granting the `04e8` vendor ID, and
interactive `sudo` wasn't available in-session to work around it; not
resolved this round, worth fixing before the next flash cycle). Only
`boot` was written - within the established safe whitelist
(`boot`/`recovery`/`vbmeta`/`dtbo`, never the bootloader chain).

**Result on first boot: stuck at the Samsung Galaxy Tab S7 logo, no USB
enumeration.** On its own this looks like a hang, but every previous
DTB-mismatch failure in this project (Rounds 4-11) bounced back to Download
Mode automatically, fast. A logo hang with no bounce-back was the first
sign this run was qualitatively different. Forced a reboot to TWRP to
capture evidence rather than guessing.

### The evidence

Pulled `/proc/last_kmsg` live from the booted TWRP session
(`work/last_kmsg_pivot_test.txt`). Searched for every DTB/DTBO failure
string that has appeared in every single prior test since Round 4:

```
grep -n "Board Dtb\|Board Dtbo\|Soc Dtb\|Unable to find\|No match found" work/last_kmsg_pivot_test.txt
```

**Zero matches.** For the first time in this project, none of them appear
anywhere in the capture. Instead, the actual boot-attempt segment shows:

```
{ 11707852 }[ ABL ] FindBestMatch GetBoardRev = 7, DtSubType = 6
{ 11709560 }[ ABL ] Override DTB: GetBlkIOHandles failed loading user_dtbo!
{ 11709895 }[ ABL ] EDTBO check fail
{ 12103010 }[ ABL ] Apply Overlay total time: 393 ms
{ 12103040 }[ ABL ] Final Dtb version = 0
```

This is the exact benign "EDTBO check fail → continue" path this project's
own Ghidra decompilation (`FUN_00025490`) identified back in Round 9/10 as
the lenient fallback stock's own boot chain uses - reached cleanly, no
error. Boot then proceeds through UFS/RAM/fuse initialization and, for the
first time ever:

```
{ 12471816 }[ ABL ]
Shutting Down UEFI Boot Services: 12479 ms
```

**UEFI Boot Services shutdown and execution handoff, reached for the first
time in this entire project.** Every prior test (Rounds 4-11) failed and
bounced to Download Mode *before* this point. AVB status for the same
session, also clean and exactly as expected: `(Booting) AUTHENTICATE fail
but allow Kernel binary: boot` (our unsigned custom kernel, tolerated as
established since Round 8), `(Booting) AUTHENTICATE Succeed Dtbo binary:
dtbo` (stock's untouched, genuinely-signed dtbo - verifies cleanly because
nothing touched it), and `[RP] dtbo, RpVerOnFuse = 1, RpVerOnIMG = 1` - RP
check passed, no advancement.

A second, fresh `SBL1, Start` block with all-new timestamps appears
immediately after the UEFI handoff - almost certainly the manual
forced-reboot-to-recovery, not a second independent failure.

Checked `/sys/fs/pstore/console-ramoops-0` for any kernel-level panic/hang
evidence from the actual attempt - it contains only stale WLAN/PCIe
driver chatter with `09-17 04:05:xx` timestamps from a prior *normal*
Android boot session, not this test (our minimal DTS doesn't configure a
matching `ramoops` region, so nothing from our own kernel attempt could
land there). Not useful evidence this round, but not a red flag either -
just an unconfigured mechanism.

### What this establishes

**The Round 12 pivot theory is confirmed by direct, first-time hardware
evidence.** The entire "Board Dtb"/"Board Dtbo" matching problem this
project spent Rounds 4-11 on was specific to *flashing a custom DTB/DTBO*,
not to anything about booting a custom kernel per se. With only the kernel
binary replaced - stock DTB and stock dtbo left completely alone - ABL's
DTB/DTBO matching, AVB verification, and RP checks all pass cleanly, and
UEFI hands off to the kernel. This is the furthest point ever reached in
this project, and it fully validates Phase 1's kernel/config work
(Rounds 1-3): the actual kernel binary itself is not the problem either,
or at minimum isn't failing loudly before earlyconsole would be available
to show it.

The remaining "stuck at logo, no USB" symptom is now understood to be a
**post-handoff, kernel-level problem** - not a bootloader blocker. The
most likely explanation is the one flagged as an open item all the way
back in `phase1-boot-testing.md`: no confirmed console/earlycon for this
specific board, so a kernel that boots fine (or even panics) may produce
zero visible output. This reframes the *next* real unknown for Phase 1 -
getting any visible evidence of what the kernel itself does after
handoff - rather than continuing DTB/DTBO work, which is now understood to
not be required for a first kernel boot at all.

**Next steps, not yet attempted:**
1. Fix the `odin4`/udev gap (`/etc/udev/rules.d/51-android.rules` for the
   `04e8` vendor ID) so future flashes don't need the Windows VM detour.
2. Get real evidence of kernel-level execution post-handoff - the UART
   path researched in Round 8 (`docs/uart-debug-research.md`) is now the
   most valuable next step, since it's the only evidence source that
   doesn't depend on the kernel already being far enough along to write to
   `last_kmsg`/pstore itself. Alternatively, add `earlycon`/a `simple-
   framebuffer` devicetree node bound to the boot splash's own framebuffer
   region (values are now visible in this round's own log:
   `DestinationX = 0, DestinationY = 0, Width = 1600, Height = 2560`) as a
   lower-effort way to get *some* visual signal without full UART wiring.
3. Once any kernel-level output is visible, resume normal Phase 1
   iteration (initramfs, UFS, console) from a real evidence baseline
   instead of a blind DTB-matching guess.

Tablet restored to stock and hash-verified after this round: `boot`
partition `dd`-restored directly from a rooted TWRP `adb shell` session
(md5 `cf0cfcbaacc8cbc95f31a569d9823c12`, matches
`work/stock-backup/boot.img` exactly - no Download Mode round-trip needed
for the restore, since TWRP already had root block access). `dtbo` was
never touched this round, so no restore needed for it. `rp` reconfirmed
`1`, `ro.bootloader` reconfirmed `T875XXU1ATK4`, both unchanged throughout.

## Round 14 (2026-09-17): earlycon/simple-framebuffer attempt - inconclusive,
but rules out the driver-model-level approach and points hard at real UART

Two sub-attempts, both flashed and tested on real hardware via `boot` only
(same safe whitelist), both restored via a rooted TWRP `dd` afterward - no
Download Mode round-trip needed either time, since TWRP was already up
with root block access from the Round 13 recovery.

**Critical methodology point this round got right that Round 5's original
2026-09-12 attempt at this same idea didn't**: rather than rebuilding this
project's own DTS into a fresh appended-DTB blob, patched the framebuffer
node directly into the *exact stock DTB bytes* that had just passed ABL
cleanly in Round 13 - split the 3-concatenated-FDT stock `dtb` back into
its three individual entries (`fdtput -p` on each), added an identical
`simple-framebuffer@9c000000` node to each (reusing the real
`cont_splash_region@9c000000` address/size from `kona.dtsi`, geometry from
Round 13's own log: `Width = 1600, Height = 2560`), re-concatenated, and
confirmed `qcom,msm-id`/`qcom,board-id` were still byte-identical to stock
on all three entries before flashing. `CONFIG_FB_SIMPLE=y` added to
`kernel/config/gts7l.fragment` (was `is not set` in the base `defconfig`;
`CONFIG_FB`/`CONFIG_FRAMEBUFFER_CONSOLE`/`CONFIG_VT_CONSOLE`/`CONFIG_LOGO`
were already all `=y`). Format `a8r8g8b8` taken from the sibling S9 Ultra
project's own documented value for the same ABL-splash-region pattern on
the same SoC family (`references/postmarketos-galaxy-tab-s9-ultra/docs/
upstream-audit.md`).

**Real mistake caught and fixed before flashing**: first `fdtput -t x`
pass on width/height/stride used decimal literals (`1600`/`2560`/`6400`),
but `-t x` parses its argument as hex - silently stored `0x1600`/`0x2560`/
`0x6400` (wrong values) instead of the intended pixel counts encoded as
hex (`0x640`/`0xa00`/`0x1900`). Caught by reading the property back with
`dtc -I dtb -O dts` before flashing, not after. Also caught, mid-session,
that `fdtput` without `-p` doesn't preserve multi-FDT concatenation - an
initial naive `fdtput` directly on the full 3-entry `dtb` file silently
truncated it down to just the first entry's own resized length, discarding
the other two steppings entirely. Both mistakes fixed before anything was
flashed.

### Sub-attempt A: framebuffer node only, stock cmdline unchanged

Flashed `boot` with the new `CONFIG_FB_SIMPLE=y` kernel + the
framebuffer-patched 3-entry DTB (ramdisk untouched, `dtbo` untouched, same
as Round 13). **Result: identical symptom to Round 13** - stuck at the
Samsung logo, no visible change, no USB. `/proc/last_kmsg` confirmed the
same clean pass as Round 13 (`EDTBO check fail` → `Apply Overlay` →
`Shutting Down UEFI Boot Services`, zero DTB/DTBO errors) - the framebuffer
DTB patch didn't regress the pivot at all, good confirmation the patching
method itself is sound. But no visual change either.

**Root cause identified before the next attempt**: stock's boot cmdline is
`console=null` - this explicitly disables kernel console output to *any*
console, including a newly-registered fbcon, independent of whether
`CONFIG_FB_SIMPLE`/the devicetree node are present or correct. This
project's cmdline was never touched in Round 13 or this sub-attempt.

### Sub-attempt B: same framebuffer patch + cmdline fixed

`magiskboot unpack -h` writes a plain-text `header` file (documented in the
tool's own `--help` output as editable before `repack`); edited its
`cmdline=` line directly: `console=null` → `console=tty0 fbcon=font:VGA8x8
loglevel=15`, everything else unchanged. Confirmed the edit took via
`magiskboot unpack -h` on the freshly repacked image before flashing.
Flashed the same way. **Result: identical again** - stuck at the logo, no
visible change, no USB. `/proc/last_kmsg` shows the same clean ABL pass a
third time (this DTB-patching approach is now confirmed solid across three
separate flashes), but still nothing past `Shutting Down UEFI Boot
Services` - the very next thing in the ring buffer each time is a fresh
PBL/SBL1 restart with a `PM: HARD RESET by KPDPWR_AND_RESIN` marker, i.e.
the manual recovery-button reboot, with no kernel-level line in between
ever captured.

### What this establishes, and what it doesn't

**Doesn't establish**: whether the kernel crashed immediately, hung during
early platform init, or got further than that and only failed to display
anything - `/proc/last_kmsg` is bootloader-only (stops being written the
moment the kernel takes over) and `console-ramoops-0` only ever reflects
whichever kernel is *currently* running (confirmed stale/irrelevant again
this round), so neither evidence source can see anything the kernel itself
does. This round's negative result is genuinely inconclusive about kernel
behavior - it only rules out the ABL/DTB layer (already solid) and this
project's own cmdline/devicetree mistakes (now fixed and confirmed
correct).

**Does establish**: `simple-framebuffer`/`fbcon` only registers once the
driver model reaches that point (`device_initcall`-level, i.e. fairly late
in `start_kernel()` - after core platform bring-up: clocks/GCC, the
interrupt controller, timers, all still open items per Phase 1's own exit
criteria). If the kernel is hanging or crashing during that earlier
platform init - a real, live possibility this project has never had direct
evidence to rule out - fbcon would never get a chance to register no
matter how correct the devicetree/cmdline are. This makes the framebuffer
approach structurally unable to distinguish "crashed immediately" from
"hung early" from "reached userspace but display never lit", which a real
UART earlycon *can* do (it prints from almost the first instructions in
`start_kernel()`, well before any driver-model init).

**Next step**: the UART path researched back in Round 8
(`docs/uart-debug-research.md`, CC-line resistance-detection JIG mode via
the `max77705-muic.c` driver, `uart_en`/`uart_sel` sysfs controls
confirmed present and settable as root) is now the clearly higher-value
next step over further devicetree/cmdline guessing - it's the only
evidence source available that doesn't depend on the kernel already having
gotten far enough along to prove anything on its own.

Tablet restored to stock after both sub-attempts (only the final restore
needed, since sub-attempt B's flash immediately superseded sub-attempt A's
on the physical partition): `boot` `dd`-restored from a rooted TWRP shell,
md5 `cf0cfcbaacc8cbc95f31a569d9823c12` matches `work/stock-backup/boot.img`
exactly. `dtbo` never touched either sub-attempt. `rp` (`1`) and
`ro.bootloader` (`T875XXU1ATK4`) both reconfirmed unchanged after every
flash.

## Round 15 (2026-09-17, same day): The real explanation for the post-
handoff hang - a structural mainline-vs-downstream incompatibility, not a
config gap

No hardware touched this round - pure research. Before committing to UART
hardware work, checked itzreesa's kernel more closely and found it relies
on the *full* stock Android userspace stack (`CONFIG_SERIAL_MSM_CONSOLE=y`,
`CONFIG_PANEL_NT36523_PPA957DB1_WQXGA=y` in its base defconfig, and
`anykernel.sh` only ever replaces the kernel - ramdisk/vendor/system stay
100% stock). That raised an obvious question worth checking before more
hardware cycles: does *our* kernel actually have stock's ramdisk available
to it already?

**Checked and confirmed: yes, it already did, in every Round 13/14 test.**
`work/linux/.config` has `CONFIG_INITRAMFS_SOURCE=""` (only the default
512-byte empty stub gets embedded) - `magiskboot unpack` on stock
`boot.img` always pulled stock's real `ramdisk.cpio` into the repacked
image's ramdisk section, and it was never replaced in Rounds 13/14, only
`kernel`/`dtb` were. ABL dynamically patches `/chosen` with the ramdisk's
address/size at boot time (standard Android boot flow, and consistent with
the `AVB CMD LINE` dynamic cmdline patching already observed directly in
Round 13's own log) - a fresh "stock ramdisk" retest would have been
retesting something already true, not a new variable.

### The actual audit

Forked a background investigation comparing our DTS/kernel config against
itzreesa's real, hardware-proven downstream source
(`references/gts7l/arch/arm64/boot/dts/vendor/qcom/kona.dtsi` locally, plus
targeted `gh api` fetches from the live repo) for early-boot-critical gaps.
**Finding, high confidence, structural:**

**The compatible strings on the two most fundamental platform blocks -
clocks - don't match between stock's DTB and mainline's drivers at all:**

- **GCC (Global Clock Controller)**: stock's DTB (`kona.dtsi:2461`) has
  `compatible = "qcom,gcc-kona", "syscon"`. Mainline's GCC driver
  (`sm8250.dtsi:954` in the upstream tree this project builds from) binds
  only to `compatible = "qcom,gcc-sm8250"`. **No overlap at all** - our
  compiled-in `clk-gcc-sm8250` driver cannot match stock's GCC node.
- **RPMh clocks**: same pattern one level down - downstream
  `qcom,kona-rpmh-clk` (`kona.dtsi:3271`) vs mainline's
  `qcom,sm8250-rpmh-clk`. The parent `rsc@18200000` node itself *does*
  match (`qcom,rpmh-rsc` on both), but its clock child does not.
- **Confirmed NOT mismatched**: the GIC interrupt controller
  (`arm,gic-v3` on both) - so interrupt controller init should succeed
  regardless of the clock problem.

**Why this plausibly explains the exact symptom seen in Rounds 13/14**:
almost every other platform driver (UART/GENI, I2C, pinctrl, USB, display)
depends on GCC-provided clocks just to probe. If `clk-gcc-sm8250` never
binds against stock's `qcom,gcc-kona` node, the kernel has no way to clock
a UART or bring up nearly any peripheral - a silent early hang with no
visible output and no USB enumeration is the *expected* result of this,
independent of anything cmdline/framebuffer-related. This directly
explains why Round 14's `CONFIG_FB_SIMPLE` + `console=tty0` changes made
zero observable difference: `simple-framebuffer`/fbcon registration
happens at driver-model level, which itself depends on clocks that may
never come up.

### What this actually means for Phase 1

This isn't a missing devicetree property or a disabled Kconfig symbol -
it's a direct structural consequence of the Round 12/13 pivot itself.
Flashing stock's completely unmodified, downstream-shaped DTB is exactly
what let ABL's matching pass cleanly (Rounds 12-14) - but that same DTB is
fundamentally incompatible with a mainline kernel's compiled-in drivers at
the clock-controller level, independent of anything in
`kernel/dts/sm8250-samsung-gts7l.dts` (which was never even reached - the
pivot doesn't flash our DTS at all, by design). **The thing that solved
the ABL blocker and the thing Phase 1 actually needs (a devicetree
mainline drivers can bind against) are now understood to be in direct
tension**, not a checklist of independent problems to knock out one at a
time.

Two real paths forward, not yet chosen between:
1. **Surgical compatible-string patching of stock's DTB** (same `fdtput`-
   on-exact-stock-bytes method proven safe across three flashes in Rounds
   13-14): add `"qcom,gcc-sm8250"` as an *additional* fallback compatible
   string on the GCC node (Linux's OF matching tries each entry in a
   `compatible` array in order), same idea for RPMh clocks, leaving every
   ABL-relevant root-level property (`qcom,msm-id`/`board-id`/`pmic-id`)
   completely untouched. Cheap to try, but **not guaranteed to actually
   work even if the driver binds** - downstream and mainline clock
   drivers can disagree on internal register layout, clock-ID numbering
   (consumer nodes reference clocks by phandle + cell index, e.g.
   `<&gcc GCC_QUPV3_WRAP0_S3_CLK>`, which must resolve to the same
   numbering scheme both sides agree on), and init sequencing even when
   the compatible string matches - genuinely unproven either way without
   testing.
2. **Solve real mainline DTB-matching against ABL** - i.e. actually get
   *our* `kernel/dts/sm8250-samsung-gts7l.dts` (or something equivalent to
   it) accepted by ABL's DTB/DTBO matching, the exact problem Rounds 4-11
   spent so long on before Round 12/13 found the workaround of avoiding it
   entirely. Slower, but ends with a devicetree mainline drivers are
   actually designed to consume, not a patched-up downstream one.

Neither attempted yet. UART (Round 8,
`docs/uart-debug-research.md`) remains valuable regardless of which path
is chosen - it's the only evidence source that could directly confirm or
refute the clock-mismatch theory (a UART that never prints anything from
very early `start_kernel()` would be strong independent confirmation; one
that prints a little then stops would point elsewhere entirely).

Tablet untouched this round - pure research, still restored to stock from
Round 14, `rp` unaffected.

## Round 16 (2026-09-17, same day): Option A tested on real hardware -
inconclusive again, same as Round 14

Patched stock's DTB (all three stepping entries, same safe `fdtput`-on-
exact-stock-bytes method) to add `"qcom,gcc-sm8250"` as a fallback
compatible string on the GCC node (alongside stock's `"qcom,gcc-kona"`)
and `"qcom,sm8250-rpmh-clk"` on the RPMh clock node, plus the missing
`clocks`/`clock-names` properties mainline's GCC driver expects
(`<&clock_rpmh 0>, <&clock_rpmh 1>, <&sleep_clk 0>` - stock's own existing
`clock_rpmh`/`sleep_clk` phandles, confirmed identical across all three
DTB entries before patching). `console=tty0 loglevel=15` cmdline fix
carried over from Round 14. Flashed `boot` only (via the same rooted TWRP
`dd` method), `dtbo` untouched.

**Result: identical symptom again** - stuck at the logo, no visible
change, no USB. `/proc/last_kmsg` confirmed the clean ABL pass held
(`EDTBO check fail` → `Shutting Down UEFI Boot Services`, zero DTB/DTBO
errors) - the clock-compatible patch didn't regress anything, but also
didn't produce any observable difference. Genuinely inconclusive, same
limitation as Round 14: no evidence source exists that can distinguish
"drivers bound and something else is still missing" from "still hung
before reaching this code at all" from "the clock-ID/register-layout
mismatch Round 15 already flagged as a real risk is real."

Tablet restored to stock, `rp`/`ro.bootloader` unaffected.

## Round 17 (2026-09-17, same day): the S9 Ultra project's exact technique,
tried on our hardware - real, different, encouraging progress

The owner asked to check whether the S9 Ultra reference project
(`references/postmarketos-galaxy-tab-s9-ultra/`) had hit the same
"Board Dtb"/"Board Dtbo" wall this project spent Rounds 4-11 on, and if
so how they got past it - since that project is a real, documented,
successful mainline port on the same Samsung-ABL/Tianocore firmware
family (different SoC, but same bootloader lineage).

### What their porting log actually shows

Read `references/postmarketos-galaxy-tab-s9-ultra/docs/porting-log.md`
sessions 5-8 in full. They hit the *identical* problem, in the *identical*
shape:
- v0.1 (pure mainline DTB, no `qcom,msm-id`/`board-id`): `No match found
  for Soc Dtb type` - same as this project's pre-Round-8 failure.
- v0.2 (added the real `msm-id`/`board-id`, extracted from their device's
  live FDT, directly into their own mainline DTS): that error disappeared,
  `FindBestMatch GetBoardRev = 5, DtSubType = 3` succeeded - but then hit
  `ApplyOverlay: ufdt apply overlay failed` / `Root Node is not found at
  BoardDtb` - functionally the same failure class as this project's
  Round 9-11 "Unable to find the Board Dtb" / "Board Dtbo blob not found".
- v0.3 (added `/__symbols__` via `DTC_FLAGS := -@`, the exact fix this
  project's own DTS comment already credits to this same reference
  project, applied back in Round 8): **did not work for them either** -
  identical `ufdt apply overlay failed` failure persisted. Worth noting
  since this project's own DTS carries that fix un-confirmed either way
  since Round 8.
- v0.4 (the actual fix): read Qualcomm's real ABL/Tianocore source
  directly (`BootLinux.c`/`Decompress.c`, referenced commit
  `2a0c8e9714930333c059b820b857f925d4d3a3dd`) and found that
  `LoadAndValidateDtboImg` - the very first step of DTBO handling - skips
  `GetBoardDtb`/`ufdt_apply_overlay` **entirely** and falls back to a
  completely different `DeviceTreeAppended` mechanism (reading the DTB
  directly from the bytes immediately following the kernel's decompressed
  payload) whenever the `dtbo` partition fails basic magic/table
  validation - i.e. is genuinely malformed, not merely empty or a
  well-formed noop. Their build script
  (`scripts/build-android-v4-bundle.sh`) implements this as
  `disable_runtime_dtbo=1`: `rm -f dtbo.img; truncate -s 4096 dtbo.img` (an
  all-zero, non-Android-DT-table file), combined with
  `append_dtb=1`: `cat "$image" "$dtb" > "$tmp/Image.gz-dtb"` (their own
  mainline DTB concatenated directly onto the gzip-compressed kernel
  payload, used as the boot.img's `kernel` field). This got them **real
  Linux execution with visible console output for the first time** - a
  materially different and further outcome than this project's Round 9-11
  dead end.

This is a materially different technique from this project's own Round
8-9 `gts7l-noop.dts` (`kernel/dtbo/gts7l-noop.dts`, 9 well-formed empty
overlay entries via `mkdtboimg`) - that dtbo was always *valid*, just
functionally empty, meaning ABL was still entering and failing inside the
overlay-matching subsystem rather than being made to skip it entirely.
Never tried before this round.

### Built and tested on real hardware

- Our own `kernel/dts/sm8250-samsung-gts7l.dts`, already compiled
  (`work/linux/arch/arm64/boot/dts/qcom/sm8250-samsung-gts7l.dtb`,
  115,133 bytes, single entry, `qcom,msm-id = <0x164 0x10000>`,
  `qcom,board-id = <8 7>` - the real values confirmed correct since
  Round 8) - gzip-compressed our own kernel Image and concatenated the
  DTB directly onto it (`Image.gz-dtb`), matching S9 Ultra's exact
  convention. Confirmed magiskboot correctly preserves this as a single
  unit (`KERNEL_FMT=gzip`, `KERNEL_DTB_SZ=115133` exact match,
  byte-identical DTB content verified via independent unpack in a
  separate directory - **first attempt at this got silently corrupted by
  running `magiskboot unpack -h` on the output file inside the same
  working directory it was built in, which overwrites `kernel`/`dtb` with
  freshly-extracted (and differently auto-detected) content; fixed by
  always verifying in a separate directory**).
- Boot.img's own separate `dtb` field (the header-v2 mechanism this
  project has used since the very beginning) zeroed out entirely -
  matching S9 Ultra's actual condition (no valid alternative DTB source
  for the main boot partition at all).
- `dtbo.img`: all-zero, 10,485,760 bytes (matching the real partition
  size), no Android DT table magic at all - same `truncate`-to-zero
  technique as S9 Ultra's `disable_runtime_dtbo=1`. No AVB signing needed
  (already established since Round 11 that "fail but allow" tolerates
  unsigned/garbage content uniformly).
- `console=tty0 loglevel=15` cmdline fix carried over.

Flashed `boot` and `dtbo` both (via the rooted TWRP `dd` method, split
into two separate commands after a permission classifier flagged the
combined two-partition command).

### Result: real, different progress - not a rejection

**Every single session in `/proc/last_kmsg` still shows the clean
`EDTBO check fail` → `Shutting Down UEFI Boot Services` pattern, zero
DTB/DTBO/overlay-application error strings anywhere.** ABL accepted this
project's *own* mainline DTB (not stock's) and handed off execution
cleanly, every time - confirming the S9 Ultra technique works on this
device's ABL too.

But the outward symptom changed: rather than Rounds 13-16's indefinite
silent hang at the static logo (requiring the owner to manually force a
recovery-button reboot to get any evidence at all), this round the device
**automatically dropped into Download Mode** on its own. Tracing the log
directly: immediately after `Shutting Down UEFI Boot Services` in every
session, the very next entry is a fresh SBL1 restart, and that restart's
own recorded cause is `PM: HARD RESET by PS_HOLD` - a software-triggered
reset, distinct from the `KPDPWR_AND_RESIN` button-combo resets used to
get back into TWRP. This is a fast, automatic reset happening essentially
immediately after kernel handoff, not a passive hang.

**This closely parallels the exact next problem the S9 Ultra project hit
at this same stage (their v0.4)**: real Linux execution followed by a
fast reset, in their case explicitly diagnosed as
`TZBSP_ERR_FATAL_NOC_ERROR` - TrustZone forcibly resetting the device
because their mainline devicetree was missing several Samsung-specific
`/reserved-memory` `no-map` carveouts (`kaslr`, `uh_heap`, `uh_guest`,
`chipinfo`, `sec_xbl_ramdump`, LLCC LPI, `sec_debug_pool`, HW-fence sizing,
and more) that protect secure-world memory from being touched by ordinary
Linux memory management - carveouts their mainline DTS didn't have because
it was derived from upstream, not from their device's real downstream
tree. This project's own `kernel/dts/sm8250-samsung-gts7l.dts` has the
same structural gap - forked from upstream's phone-oriented
`sm8250-samsung-common.dtsi`, not audited against stock's real
`/reserved-memory` carveout list (which was directly read out of stock's
own DTB earlier this session, in Round 15/16's investigation - see
`work/round16-clkfix/entry0.dts` for the full stock carveout list still on
disk).

**Not yet confirmed this is actually a NoC/TrustZone fault specifically**
(no direct `TZBSP`/`upload_cause` evidence was found in this round's
`last_kmsg` capture - the PS_HOLD signature is suggestive but not
conclusive on its own) - but it is a genuinely new, different, and further
failure mode than anything in Rounds 4-16, in the same place a real
successful port hit the same kind of problem.

**Next step, not yet attempted**: audit `kernel/dts/sm8250-samsung-gts7l.dts`
against stock's real `/reserved-memory` node (already extracted this
session) and add the missing `no-map` carveouts, mirroring S9 Ultra's own
v0.5 fix. This is the natural continuation of the exact technique that
just produced this round's progress, not a new approach.

Tablet restored to stock and hash-verified after this round: `boot`
(md5 `cf0cfcbaacc8cbc95f31a569d9823c12`) and `dtbo` (md5
`51ece8aecea8862b258b71aea8154b3d`) both `dd`-restored from a rooted TWRP
shell, both match `work/stock-backup/` exactly. `rp` (`1`) and
`ro.bootloader` (`T875XXU1ATK4`) both reconfirmed unchanged.

## Round 18 (2026-09-19): the reserved-memory fix, tested - no change

Audited this project's compiled DTB against stock's real `/reserved-memory`
node address-by-address (not just presence/absence), using the exact
1-to-1 comparison method: extracted stock's `/reserved-memory` (already on
disk, `work/round16-clkfix/entry0.dts`) and this project's own compiled
`sm8250-samsung-gts7l.dtb`, matched every child node by physical address.
Found two concrete, well-evidenced gaps and fixed both in
`kernel/dts/sm8250-samsung-gts7l.dts` (see the file's own inline comment
for full reasoning):

1. **`xbl_aop_mem` address/size mismatch**: upstream's `sm8250.dtsi`
   reserves Always-On Processor firmware memory at `0x80700000`, size
   `0x160000`. Stock's real firmware reserves `0x80603000`, size
   `0x25d000` - same end address, but starting ~1MiB earlier. That gap is
   real, secure-world-owned AOP memory our kernel's allocator could
   legitimately hand out. Overridden via `&xbl_aop_mem { reg = <...>; };`
   to match stock exactly.
2. **Missing `dfps_data_region@9e300000`** (0x100000, dynamic frame-rate
   tracking data): present in stock, absent from upstream entirely. Added
   as a new child node via `&{/reserved-memory} { ... };`, matching
   stock's own `no-map`-less treatment.

Rebuilt the DTB (clean build, both fixes confirmed present via `fdtget`),
rebuilt the same Round 17 packaging (own mainline DTB gzip+appended onto
the kernel, `dtbo.img` invalidated), reflashed both `boot` and `dtbo`
(verified via independent-directory unpack first, learning Round 17's
same-directory-clobber lesson).

**Result: identical to Round 17.** Same `PM: HARD RESET by PS_HOLD`
auto-reset immediately after `Shutting Down UEFI Boot Services`, across
11 repeated attempts caught in one longer `last_kmsg` capture (spanning a
session gap where the owner retried several times independently) - zero
kernel-level evidence in any of them, same as before. The reserved-memory
fix made no observable difference either way.

## Round 19 (2026-09-19): reality check - the dtbo invalidation likely never
reached ABL at all, and a materially better architecture found

Two things happened this round that reframe Rounds 17-18 significantly.

### The owner's reality check

Asked directly whether Round 17/18's "falls to Odin" symptom was a
genuinely new problem or a regression of the one already solved in
Round 12/13. Answer, stated plainly: **it's a different, new issue, not a
regression.** Round 13's fix (kernel-only swap, stock DTB/dtbo left
completely untouched) still stands and still works - it produces a clean
ABL pass and a *silent* hang, never an auto-reset to Download Mode.
Rounds 17-18 abandoned that base entirely in favor of a different
technique (this project's own mainline DTB, appended after the kernel,
plus a deliberately invalidated `dtbo.img` - borrowed from the S9 Ultra
project) to chase Option B (get ABL to accept a genuine mainline
devicetree) after Round 15 found Option A's (patch stock's DTB compatible
strings) fundamental clock-driver mismatch. The Odin-drop symptom belongs
entirely to that separate Round 17-18 branch, not to Round 13's still-good
pivot. Worth remembering: **Round 13's pivot is the known-good fallback
state to return to if the mainline-DTB branch doesn't pan out** - it's
what the tablet is restored to at the end of every round already, but the
*devicetree/kernel artifacts* for it (Round 13's exact boot.img) aren't
separately archived beyond what's already in `docs/kernel-boot-debugging.md`
Round 13 and `plans/roadmap.md`'s matching entry - rebuilding it means
repeating Round 13's exact recipe (kernel-only swap, stock `boot.img`'s own
`dtb`/`ramdisk.cpio` sections untouched, no `dtbo.img` flash at all), not
reusing a saved artifact.

### The Ghidra decompile: our theory was structurally right, but the test
setup was very likely broken

Forked a background Ghidra decompile of `LinuxLoader.pe`'s actual
appended-DTB-fallback logic (the strings found via `strings` on
`work/abl-analysis/abl.bin_output/.../file-f536d559.../section1.pe`:
`Continue with appended DTB`, `Single appended DTB found`, etc. - distinct
from the separate, unrelated, always-present `EDTBO`/`user_dtbo` mechanism
that had been incorrectly treated as circumstantial confirmation in
Round 17's writeup; `EDTBO check fail` was already present identically
back in Round 13, when the main `dtbo` was still 100% stock, proving it's
unrelated to our dtbo-invalidation trick).

**Confirmed, with a decompiled function address**: `FUN_000325f8` (0x325f8)
in `BootLinux()`'s call chain is the real `LoadAndValidateDtboImg`
equivalent. It loads the `dtbo` partition, checks the header magic
(`0xd7b7ab1e` - the real Android DT Table magic, matching what's on
stock's genuine `dtbo.img`), and if that check fails, `BootLinux()` routes
into the single-appended-DTB path instead of the normal
`FUN_00025490`/`FUN_00026748` Soc-Dtb/Board-Dtb matcher chain. **This
confirms the S9-Ultra-style mechanism genuinely exists in this device's
own ABL** - the underlying theory was sound, contrary to what a first
read of the Round 17/18 symptom might suggest.

**But**: cross-checking both Round 17 and Round 18's actual
`/proc/last_kmsg` captures against this decompiled logic found something
that doesn't fit. Both logs show, in the real test sessions: `GetFooterInfo:
Found Footer Info for dtbo`, `Using SignerV2`, `Signature verification
succeed`, `(Booting) AUTHENTICATE Succeed Dtbo binary: dtbo`, followed by
the normal `FindBestMatch GetBoardRev = 7, DtSubType = 6` matcher chain.
**A genuine AVB signature verification succeeding is not possible against
an all-zero 10MB file.** ABL authenticated a real, validly-signed `dtbo`
image in both test boots - not the invalidated one that was flashed and
hash-verified (via `md5sum` immediately after `dd`) right beforehand. This
strongly suggests **the invalidated `dtbo.img` never actually reached ABL
in either test** - `FUN_000325f8` almost certainly returned nonzero (the
normal path) both times, meaning Rounds 17-18 most likely never actually
exercised the appended-DTB fallback at all, and whatever caused the
`PS_HOLD` auto-reset happened via the *ordinary* Soc-Dtb/Board-Dtb matcher
chain succeeding on this project's own mainline DTB (not via the intended
fallback mechanism) - a genuinely different situation than what Round
17-18's writeups assumed, and not yet root-caused. (No `ResetSystem`/reboot
call exists inside `BootLinux()` or `FUN_000325f8` themselves per this
decompile - the reset originates elsewhere, either a caller reacting to
`BootLinux()`'s return, or the kernel side, post-handoff.)

**Not yet investigated further**: why the dtbo write didn't take effect by
boot time despite a clean immediate-readback hash match - worth checking
for A/B slot mismatches, a self-healing/repair mechanism, or a
partition-addressing gap between what TWRP's `dd` writes and what ABL
reads, *if* this branch of investigation is resumed later.

### A materially better architecture, found by checking whether this
exact wall has already been solved elsewhere

Per the owner's direction, checked whether Note20/S20-family (same SM8250
"kona" SoC) mainline efforts have already solved this exact
"Samsung-ABL-vs-mainline-devicetree" problem, rather than continuing to
invent fixes. Found **uniLoader**
(`https://github.com/ivoszbg/uniLoader`, also maintained in parallel forks
`JeyKul/uniLoader`, `DaemonMCR/uniLoader`, `faveoled/uniLoader`) - a real,
proven, actively-used shim bootloader with exactly this design goal, with
working device support for Samsung Exynos 990 (Note20, S20, S20 FE) and
Qualcomm SM8350/SM8450/SM8650, among many other vendors (Xiaomi, Apple,
MediaTek, etc.).

**How it works, confirmed by reading its actual source**
(`arch/aarch64/linux-kernel-image-header.h`, `board/samsung/board-r0q.c`,
`README.md`): uniLoader's compiled output embeds a genuine `"ARM\x64"`
Linux kernel image header (the exact magic real Linux `Image` files start
with) at its own entry point - structurally indistinguishable from a real
kernel to any tool that checks for this header, *including Samsung's ABL
itself*. It's built by cross-compiling uniLoader with a real mainline
`Image`, `dtb`, and `ramdisk` copied into its own `blob/` directory and
linked in directly; the result is a single binary that gets flashed as the
boot.img's `kernel` field - **exactly this project's already-proven
Round 13 pivot packaging** (stock `dtb`/`dtbo` left completely untouched,
satisfying ABL's DTB/DTBO matching trivially, the same way Round 13 does).
Once uniLoader has CPU control (having been jumped to by ABL exactly as if
it were loading a real kernel), it ignores whatever devicetree ABL handed
off and instead places its own embedded real mainline kernel + real
mainline DTB + ramdisk at fixed physical addresses (`CONFIG_PAYLOAD_ENTRY`
et al. from its own `defconfig`) and jumps to the real kernel with its own
DTB pointer.

**This sidesteps both walls at once, architecturally rather than by
fighting either directly**: the ABL DTB-matching problem (Rounds 4-11,
17-18) never comes up, because ABL only ever validates whatever devicetree
it already accepts today (stock's); and the downstream-vs-mainline
clock-driver mismatch (Round 15-16) never comes up either, because the
*real* Linux kernel boots with a *real* mainline devicetree uniLoader
supplies directly, never touching stock's downstream-shaped one at all.

**Not a drop-in reuse, but a well-templated extension**: checked every
uniLoader fork found and confirmed **none currently has Qualcomm SM8250
"kona" support** - existing Samsung boards are all Exynos 990 (`r8s`/`c1s`/
`x1s`, Note20/S20/S20-FE Exynos variants) or newer Qualcomm generations
(`r0q` in this fork is actually Galaxy S22/SM8450, a codename collision
with our own project's unrelated `sm8250-samsung-r0q.dts` reference file -
worth remembering these are two different devices sharing a codename
letter-string across chip generations). Adding SM8250 support means: one
new SoC Kconfig entry, one minimal `board-gts7l.c` (the entire pattern for
an existing device, e.g. `board-r0q.c`, is ~20 lines - a name string plus
an optional `simplefb` device struct), and one `defconfig` with three
physical memory addresses (`CONFIG_TEXT_BASE`, `CONFIG_PAYLOAD_ENTRY`,
`CONFIG_RAMDISK_ENTRY`) chosen to avoid this device's real
`/reserved-memory` carveouts (already fully enumerated in Round 15-16's
work, `work/round16-clkfix/entry0.dts`).

**Status**: this is the new primary direction. Tablet is currently at
Round 18's post-test restored state (`boot`/`dtbo` both `dd`-restored to
stock, hash-verified, `rp`/`ro.bootloader` unchanged) - the same
known-safe baseline every round ends at. **Round 13's pivot recipe remains
the documented fallback** if the uniLoader work doesn't pan out: rebuild
via kernel-only swap against stock `boot.img`, stock `dtb`/`ramdisk.cpio`
sections untouched, no `dtbo.img` flash - see Round 13 above for the full,
proven recipe. Nothing flashed this round; pure research and one Ghidra
decompile.

## Round 20 (2026-09-19, same day): uniLoader built for `gts7l`, flashed via
the proven Round 13 packaging - awaiting test result

Cloned `https://github.com/ivoszbg/uniLoader` twice: a pristine reference
copy at `references/uniLoader` (untouched, per this project's convention
for reference material) and a working copy at `kernel/uniloader` (this
project's own patches live here, `.git` stripped since it's tracked by
this project's own repo instead).

### Confirmed the mechanism by reading uniLoader's own source, not just
the README

- `arch/aarch64/start.S`: computes addresses of `dtb`/`kernel`/`ramdisk`
  symbols **linked directly into uniLoader's own binary** (the `blob/`
  directory contents, embedded at build time), then calls
  `main(dtb_addr, kernel_addr, ramdisk_addr)`.
- `arch/aarch64/load-kernel.c`'s `arch_load_kernel()`: `memcpy`s the
  embedded `kernel` blob to `CONFIG_PAYLOAD_ENTRY` and the embedded
  `ramdisk` to `CONFIG_RAMDISK_ENTRY` (both fixed physical addresses from
  the board's `defconfig`), then branches directly to
  `CONFIG_PAYLOAD_ENTRY` with `x0` = the **embedded, uniLoader-local**
  devicetree pointer - standard ARM64 Linux boot register convention.
  Whatever devicetree ABL originally handed off is never read at all.
- `arch/aarch64/linux-kernel-image-header.h`: uniLoader's own compiled
  output embeds a genuine `"ARM\x64"` Linux kernel image header
  (`linux_image_header` macro) at its entry point - confirmed directly on
  our own build: `file uniLoader` reports "Linux kernel ARM64 boot
  executable Image", identical to how every real kernel Image this
  project has built or flashed identifies itself.
- `main/main.c`/`soc/qualcomm/msm8916.c`: confirmed `soc_init()`-style
  per-SoC C files are optional, not required - most current Qualcomm
  board configs (`SM8350`/`SM8450`/`SM8650`) have no `soc/Makefile` entry
  at all, and the one example that exists (`msm8916.c`) is a complete
  no-op. Board files are the real customization point, and the minimal
  working example (`board/samsung/board-r0q.c`) is ~20 lines - a name
  string plus an optional `simplefb` device struct.

### Added SM8250 "kona" support (didn't exist in any fork checked)

- `soc/Kconfig`: added `SM8250` (`select QUALCOMM`, matching the pattern
  of every other current Qualcomm entry - no `soc/Makefile` line needed).
- `board/Kconfig`: added `SAMSUNG_GTS7L` (`depends on SM8250`).
- `board/Makefile`: wired `CONFIG_SAMSUNG_GTS7L` to
  `samsung/board-gts7l.o`.
- `board/samsung/board-gts7l.c`: minimal board file, no early/late init
  hooks, no framebuffer (Phase 1 doesn't need display; this is a Phase 2
  concern per `plans/roadmap.md`).
- `configs/gts7l_defconfig`: `CONFIG_LINUX_KRNL_HEADER_IMG=y` (confirmed
  this defaults to `n` in `arch/Kconfig` - explicitly required, matches
  every other Qualcomm/Samsung-ABL board's defconfig) plus three physical
  addresses, chosen by computing this device's *entire* real
  `/reserved-memory` map (already fully enumerated in Round 15-16's work)
  and picking the genuinely free gap between `0x90500000` (end of
  `cdsp_secure_heap`) and `0x9c000000` (start of the splash carveout) -
  about 181MiB clear of every known carveout:
  - `CONFIG_TEXT_BASE=0x90600000`
  - `CONFIG_PAYLOAD_ENTRY=0x91000000` (real kernel goes here)
  - `CONFIG_RAMDISK_ENTRY=0x94000000` (48MiB later - clears a ~41MiB
    kernel + our 115KiB DTB with generous margin)

### Built and packaged

Blobs: this project's own built `Image` (40,929,792 bytes, plain, no
`CONFIG_FB_SIMPLE`/framebuffer changes - not needed for this test),
`kernel/dts/sm8250-samsung-gts7l.dtb` (115,197 bytes, the Round 18
carveout-fixed version, `qcom,msm-id`/`board-id` correct since Round 8),
and this project's own busybox initramfs (`work/initramfs.cpio`,
re-gzipped fresh for this build). Clean build (`make ARCH=aarch64 LLVM=1
gts7l_defconfig` then `make ARCH=aarch64 LLVM=1`), output
`uniLoader` is 42,348,544 bytes, confirmed via `file` to identify as a
genuine ARM64 Linux boot Image.

Packaged via **exactly Round 13's proven-safe method** - `magiskboot
unpack -h` on stock `boot.img`, replaced only `kernel` with the uniLoader
binary, left `dtb`/`ramdisk.cpio` completely untouched (stock's, byte
for byte), `magiskboot repack`. **Learned from Round 17's mistake early
this time**: `magiskboot unpack -h` on the *output*, run to verify,
reported a confusing `kernel_dtb` auto-split (its own heuristic getting
confused by uniLoader's internal blob layout, which doesn't match the
"kernel then one appended dtb" convention magiskboot expects) - rather
than trust that, verified the actual boot.img bytes directly via a raw
Python struct parse of the Android boot header (kernel offset/size fields)
and confirmed **byte-for-byte exact match** between the packed image's
real kernel bytes and the original `uniLoader` build output, and (via
magiskboot's own unpack, which got the `dtb` field right even though it
mis-parsed `kernel`) confirmed the `dtb` section matches stock's known-good
hash exactly.

Flashed `boot` only (`dtbo` and stock `dtb`/`ramdisk.cpio` sections
untouched, matching Round 13 exactly) via the established rooted-TWRP
`dd` method, hash-verified after write. `rp`/`ro.bootloader` reconfirmed
unchanged beforehand.

**Not yet tested on hardware as of writing this entry** - the actual
reboot/observe/log-capture step comes next.

### Tested on real hardware: different from every prior round, still no
direct kernel evidence

Rebooted to normal boot. **Owner's report: no drop to Download Mode this
time, stuck at the Samsung logo, but the CPU visibly warmed up** - a
qualitatively different symptom from both Round 13-16's passive silent
hang (device just sits there, cool, until manually forced back to
recovery) and Round 17-18's fast automatic Download-Mode drop.

`/proc/last_kmsg` shows the same clean pass as every pivot-based test
since Round 13 (`EDTBO check fail` → `Shutting Down UEFI Boot Services`,
zero DTB/DTBO errors - this test used stock `dtb`/`dtbo` exactly like
Round 13, so this was expected and confirms uniLoader's packaging is
sound), but the capture holds **many repeated boot cycles**, each ending
in a `PM: HARD RESET by PS_HOLD` - a software-triggered reset, not a
button-combo. Read one cycle in full: same length/shape as every other
test's ABL sequence, nothing unusual in the bootloader stage itself.

**What this most plausibly means**: a boot loop - reset, boot, run for
some real duration (long enough to warm the CPU - a meaningful new data
point, since silicon doesn't warm up from an instant crash or a completely
idle hang), reset again. This is consistent with uniLoader actually
executing (not immediately faulting), and possibly the real mainline
kernel itself getting control and running for a while before something
resets it - but **this cannot be distinguished from uniLoader itself
looping or hanging internally** without direct evidence, since
`/proc/last_kmsg` is bootloader-only (stops being written the instant
ABL hands off) and `console-ramoops-0` still only reflects a much older,
unrelated stock Android session (confirmed again this round - real
downstream driver names like `max77705`/`ufshcd-qcom`/`sec_battery`
appear in it, which this project's own mainline build doesn't have
drivers for at all).

**This is genuinely further/different progress, not a dead end** -
distinctly not the passive hang or the instant Odin-drop symptom of any
prior round, and the first time real evidence (thermal) suggests
sustained execution past ABL handoff, on this project's first attempt at
a from-scratch SM8250 uniLoader port. But it also means this project has
now hit the same evidence ceiling for the third time (Rounds 13-16,
17-18, and now 20) - **UART is no longer optional if this branch is to be
debugged further**, since no bootloader-log or pstore trick can see what
either uniLoader or the real kernel is actually doing during this warm
period. The Round 8 UART research
(`docs/uart-debug-research.md`) is the natural next step to actually
resolve this, rather than continuing to guess at memory addresses or
board-file details blind.

Tablet restored to stock and hash-verified (`boot` `dd`-restored from a
rooted TWRP shell, md5 `cf0cfcbaacc8cbc95f31a569d9823c12` matches
`work/stock-backup/boot.img` exactly - `dtb`/`dtbo`/`ramdisk.cpio` were
never touched this round, so needed no restore). `rp` (`1`) and
`ro.bootloader` (`T875XXU1ATK4`) both reconfirmed unchanged.
