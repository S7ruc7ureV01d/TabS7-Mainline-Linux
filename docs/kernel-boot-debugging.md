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
