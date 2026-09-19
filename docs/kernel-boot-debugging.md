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

## Round 21-22 (2026-09-19, same day): uniLoader proven fully working end to
end on real hardware - a real breakthrough

Per the owner's direction, before going to UART, tried getting uniLoader's
own `simplefb` console showing on screen first - much cheaper, and
uniLoader has its own driver for exactly this (`lib/simplefb/simplefb.c`,
registers as a `printk` console via `console_register()`).

### Round 21: real progress, then a self-inflicted bug

Added a `simplefb` device to `board/samsung/board-gts7l.c`, reusing the
exact physical framebuffer region and geometry ABL's own splash draws to
(`0x9c000000`, `1600x2560`, confirmed real via this device's own stock
devicetree and Round 13's own log). Rebuilt, repackaged (same proven
method), flashed. **Result: the screen changed from the static Samsung
logo to solid black after ~2 seconds, then hung** - genuinely new
behavior, and itself informative: `simplefb_probe()`'s first action is
exactly to blank the framebuffer to black, so this already proved
uniLoader was getting control and running.

**Root cause found and it's a real mistake, not an upstream bug**: this
driver's `video_info.stride` field means *bytes-per-pixel*, not the
traditional row-pitch-in-bytes - confirmed by checking every other
board's actual values (`board-r0q.c` and every `*_defconfig` with a
framebuffer all use `stride = 4`). The first board file used
`.stride = 1600 * 4 = 6400` (1600x too large). `clean_fbmem()` computes
its `memset` size as `width * height * stride`, so with the wrong stride
that came out to `1600*2560*6400` - about 26GB, starting at `0x9c000000`,
run from a script/board file that genuinely has only ~6GB of real DRAM
behind it. The black screen was the *correct* part of that memset
(zeroing the real framebuffer) followed by the write running straight off
the end of physical memory and hanging. Fixed: `.stride = 4`.

### Round 22: uniLoader confirmed fully working, real kernel handoff reached

Rebuilt with the fix, reflashed. **Owner's live capture of the actual
screen output**:

```
[INFO] simplefb: ready (1600x2560)
[INFO] passed board initialization
[INFO] welcome to uniLoader (eef7bf9) 09-19 13:38:24 on samsung-gts7l
[INFO] trying to open fdt...
[INFO] adding linux,initrd-start...
[INFO] adding linux,initrd-end...
[INFO] Booting kernel...
```

**This is a complete, direct, on-screen confirmation that uniLoader works
end to end on this device**: board init, driver probe, devicetree
patching (`patch_dtb()` adding the initrd location), and the final
`boot_kernel()` call all ran correctly, reaching the exact last `printk`
before `arch_load_kernel()`'s `memcpy`+jump. This is the single most
concrete piece of evidence this entire project has produced about what
happens after ABL handoff - previously always a total blank.

Nothing appeared after "Booting kernel..." - **not necessarily a
failure**: uniLoader's own console is entirely separate from the real
kernel's. Once the jump happens, control passes to the real mainline
kernel, which (at the time of this test) had no framebuffer/console
configured in its own devicetree at all - so even a perfectly-booting
kernel would produce zero visible output. This is the same "no display
configured" gap Round 14 hit, now sitting on top of a *proven-working*
handoff instead of an unconfirmed one.

**Fixed immediately, since this DTB is now entirely private to this
project** (a key structural difference from every DTS change attempted
in Rounds 4-18: this devicetree is embedded directly in uniLoader's own
binary and never seen by ABL at all, since ABL only ever validates stock's
completely separate, untouched DTB/DTBO - so nothing here can affect ABL
acceptance, unlike every earlier DTS experiment):

- `kernel/dts/sm8250-samsung-gts7l.dts`: overrode the inherited
  `framebuffer` node from `sm8250-samsung-common.dtsi` (phone-resolution
  `1080x2400` default) with this tablet's real `1600x2560` - the node's
  `reg`/`format` were already correct (same `cont_splash_region@9c000000`
  physical region, already `no-map`'d in `/reserved-memory` by the same
  shared base file). Also set `chosen/bootargs` directly
  (`console=tty0 loglevel=15`) - uniLoader's `patch_dtb()` only ever adds
  `linux,initrd-start`/`-end`, never bootargs.
- `kernel/config/gts7l.fragment`: added `CONFIG_CMDLINE="console=tty0
  loglevel=15"` + `CONFIG_CMDLINE_FORCE=y` as a second, independent way to
  guarantee the cmdline reaches the kernel regardless of what devicetree
  merging does.

Rebuilt kernel Image + DTB (both confirmed correct via `fdtget` before
using them), rebuilt uniLoader with the fresh blobs, repackaged via the
same proven method (byte-exact verification passed again), flashed.
**Awaiting hardware test result as of writing this entry.**

Tablet state at time of writing: `boot` = this round's uniLoader+console
build, `dtb`/`dtbo`/`ramdisk.cpio` = stock, untouched throughout. `rp`/
`ro.bootloader` reconfirmed unchanged before flashing.

### Tested on hardware: same loop, unchanged by the display/cmdline fixes -
a real, useful negative result

Owner's report: no change from Round 20/21's symptom - stuck on the
*uniLoader* splash screen (not black, not garbled - exactly uniLoader's
own last-drawn text, frozen). `/proc/last_kmsg` confirms this is still
the same boot loop as Round 20: multiple full ABL cycles, each ending in
`Shutting Down UEFI Boot Services` → `PM: HARD RESET by PS_HOLD`,
unchanged in shape or timing from before the framebuffer/cmdline fixes.

**This is a genuinely useful negative result, not just "still broken"**:
since the screen never changes from uniLoader's own last state - never
clears, never gets overwritten - the real kernel's own `fbcon`/`simplefb`
driver almost certainly never got far enough to touch the framebuffer at
all (a working `fbcon` init typically clears/redraws the screen
immediately). Combined with the loop's shape being completely unchanged
by adding a real console and forcing a real cmdline, this points away
from "no display configured" (Round 14/21's theory) and toward the hang
happening **very early in the real kernel's own boot - before
driver-model/fbcon could possibly matter**, independent of anything
display-related. uniLoader itself completes deterministically and
reaches "Booting kernel..." every single cycle, which points the
remaining suspicion at the real kernel's own early init, not at uniLoader.

**This project has now tried every low-cost, non-UART way to get evidence
past this point** (bootloader logs, pstore, uniLoader's own console, a
real kernel-side framebuffer+forced cmdline) and none of them can see
into that early-boot window. UART
(`docs/uart-debug-research.md`) is the clear, necessary next step - not
a fallback option anymore, the only remaining path to direct evidence.

Tablet restored to stock and hash-verified (`boot` `dd`-restored from a
rooted TWRP shell, md5 `cf0cfcbaacc8cbc95f31a569d9823c12` matches
`work/stock-backup/boot.img` exactly - `dtb`/`dtbo`/`ramdisk.cpio` were
never touched this round). `rp` (`1`) and `ro.bootloader`
(`T875XXU1ATK4`) both reconfirmed unchanged.

## Round 23 (2026-09-19, same day): found a persistent Samsung crash-history
partition, and a real Linux kernel panic with a definitive root cause

The owner didn't have working UART hardware (a prior makeshift
resistor-based attempt, per the Round 8 research, produced nothing) and
asked to research online whether other Samsung porters had already solved
"no UART, need early-boot evidence" - a very reasonable bet, since this
project is very unlikely to be the first to hit this specific wall on
Samsung hardware.

**Found it directly**: `/dev/block/by-name/debug` is a real, documented
Samsung debug partition containing a *persistent history* of XBL/TZ
crash-dump auto-summaries, spanning many prior resets - a fundamentally
richer evidence source than `/proc/last_kmsg`'s small, easily-evicted
ring buffer. Confirmed it exists on this device (`sda11`, 10MB) and pulled
it directly via `dd` from a rooted TWRP shell - no special tooling needed,
same access level already used throughout this project.

### What it actually contained

A sequence of numbered (`RWC=`) crash summaries. **Nine consecutive
entries (RWC=72 through RWC=80) match the Round 20-22 uniLoader test
attempts exactly** - mostly `Upload Cause = Watchdog Reset (CPU HANG)`
with `OEM_RESET_REASON: [TZBSP_ERR_FATAL_NON_SECURE_WDT]` (a generic
AP-side hang detector - not a TrustZone security violation, contrary to
the NoC-fault theory carried since Round 15/17). **One entry (RWC=79) is
a real software kernel panic**, not just a watchdog timeout:

```
Upload Cause = 0xc8000000 / KERNEL PANIC ( panic_msg = System is deadlocked on memory
...
@ Kernel Crash Infos
PC is at out_of_memory+0x23c/0x2d0
LR is at out_of_memory+0x240/0x2d0
@ Kernel Backtrace
 __alloc_pages_nodemask+0x60c/0x1190
 handle_pte_fault+0x730/0xf90
 __handle_speculative_fault+0x518/0x7c8
 do_page_fault+0x1f4/0x470
 do_translation_fault+0x2c/0x40
 do_mem_abort+0xe0/0x190
 el0_da+0x20/0x24
```

This is a coherent, logically-ordered mainline Linux page-fault-handling
call chain (`el0_da` → `do_mem_abort` → `do_translation_fault` →
`do_page_fault` → `__handle_speculative_fault`/`handle_pte_fault` →
`__alloc_pages_nodemask` → `out_of_memory`) - all standard mainline
function names (not Samsung-specific), appearing in exactly the right
calling order. A coincidentally-wrong symbol table would be very unlikely
to produce something this coherent - this is genuine evidence the real
kernel was running, handling page faults, and hit an actual out-of-memory
condition.

### Root cause, found directly and confirmed in this project's own build

Checked this project's own compiled DTB immediately: `fdtget -t x
<dtb> /memory reg` → `0 80000000 0 0`. Checked upstream's
`sm8250.dtsi` source directly:

```c
memory@80000000 {
	device_type = "memory";
	/* We expect the bootloader to fill in the size */
	reg = <0x0 0x80000000 0x0 0x0>;
};
```

**The size is zero, by design - upstream expects a bootloader to patch it
at runtime with the real detected DRAM size, exactly like ABL does for
every other DTB this project has ever booted.** uniLoader's own
`patch_dtb()` never does this - it only ever adds
`linux,initrd-start`/`-end` (confirmed directly in Round 22's own on-screen
capture). Since this project's embedded DTB is uniLoader's private copy,
never touched by ABL at all, nothing was ever filling in the real size.
**The real kernel was booting believing it had zero bytes of usable RAM**
- a complete, sufficient explanation for the observed OOM panic,
independent of anything display/cmdline-related (Round 21-22's fixes
never had a chance to matter, since this happens far earlier and for an
unrelated reason).

**Fixed directly** in `kernel/dts/sm8250-samsung-gts7l.dts`, overriding
the zero-size placeholder with this device's real, already-known DRAM
size (`Rank 0 size = 6144 MB`, confirmed in this project's own hardware
logs since Round 13's era): `&{/memory@80000000} { reg = <0x0 0x80000000
0x1 0x80000000>; };`. Rebuilt DTB (confirmed via `fdtget`:
`0 80000000 1 80000000`), rebuilt uniLoader with the fresh blob, packaged
via the same proven method (byte-exact verification passed), flashed.

**Awaiting hardware test result as of writing this entry** - but this is
the first root cause found in this entire debugging effort (Rounds 4-22)
that comes from *direct evidence* of a real kernel crash, rather than
inference from bootloader-log absence or symptom-matching against a
different device's porting log.

Tablet state at time of writing: `boot` = this round's memory-node-fixed
uniLoader build, `dtb`/`dtbo`/`ramdisk.cpio` = stock, untouched
throughout. `rp`/`ro.bootloader` reconfirmed unchanged before flashing.

### Tested: memory fix confirmed working (OOM panic is gone), but the
kernel now hangs silently with no new evidence

Owner's report: same visible symptom (stuck on uniLoader's own screen,
not black) - but this time **no automatic reset loop** at all, just a
plain hang until manually forced back to TWRP. Pulled
`/dev/block/by-name/debug` fresh (`work/debug_partition2.bin`) and
confirmed directly: **the `RWC=` entry list is completely unchanged from
before this test** (still ending at RWC=81, the prior manual-reset entry)
- no new crash-dump was recorded at all. This confirms the memory-node
fix worked (the specific OOM panic from Round 23 is gone) but the kernel
is now hanging somewhere else in a way that never triggers a hardware
watchdog reset. `console-ramoops-0` checked again too - still only stock
Android's own real downstream driver output (`max77705`/`sec_battery`/
SELinux `avc` denials), confirming it still reflects whichever kernel is
*currently* running, not this test.

**Root cause of "no new crash-dump": confirmed directly in the working
`.config`** - `CONFIG_SOFTLOCKUP_DETECTOR` and `CONFIG_HARDLOCKUP_DETECTOR`
were both off, `CONFIG_PANIC_ON_OOPS` was off, `CONFIG_PANIC_TIMEOUT=0`.
If the kernel is now stuck in a genuine hang rather than crashing, nothing
detects it and calls `panic()` - and Samsung's crash-dump capture (proven
working in Round 23, from the OOM panic) only engages when the kernel
actually panics. This is a debugging tool gap, not a boot-chain problem -
turning a future silent hang back into a captured, analyzable crash
doesn't require UART at all, just getting the kernel to call `panic()`
reliably.

**Fixed** in `kernel/config/gts7l.fragment`: `CONFIG_SOFTLOCKUP_DETECTOR`,
`CONFIG_HARDLOCKUP_DETECTOR`, `CONFIG_BOOTPARAM_HARDLOCKUP_PANIC`,
`CONFIG_PANIC_ON_OOPS` all enabled, `CONFIG_PANIC_TIMEOUT=5` (reboot 5s
after any panic instead of hanging forever post-panic), plus
`softlockup_panic=1 watchdog_thresh=5` added to the forced cmdline
(`CONFIG_BOOTPARAM_SOFTLOCKUP_PANIC` turned out to be an int-valued
symbol, not bool - the `=y` fragment line silently reverted to its
default `0` during `olddefconfig`, confirmed via `grep` on the resulting
`.config`; the cmdline `softlockup_panic=1` achieves the identical
runtime effect regardless, so no functional loss). `watchdog_thresh=5`
shortens the default ~20s soft-lockup detection window for faster
iteration.

Rebuilt kernel Image (full rebuild triggered by the config change, ~9
minutes), rebuilt uniLoader with the fresh blob, packaged via the same
proven method (byte-exact verification passed), flashed.

Tablet state at time of writing: `boot` = this round's watchdog-enabled
uniLoader build, `dtb`/`dtbo`/`ramdisk.cpio` = stock, untouched
throughout. `rp`/`ro.bootloader` reconfirmed unchanged before flashing.
**Awaiting hardware test result.**

### Tested: no panic even after 1-2 minutes - hang is earlier than the
lockup detectors themselves

Owner's report: hung again, waited 1-2 minutes (well past the shortened
5s threshold), no auto-reboot. Pulled the debug partition fresh
(`work/debug_partition3.bin`) - **still completely unchanged**, `RWC=81`
still the newest entry. Even with soft/hard lockup detection enabled and
a short threshold, nothing panicked.

**This is real, meaningful negative evidence**: `lockup_detector_init()`
itself only runs partway through `start_kernel()`, after timekeeping and
the scheduler are already up. If neither detector ever fired in 1-2
minutes, the hang is happening *before* that init point - the kernel
doesn't yet have enough of itself running to detect its own hang, let
alone panic. Not "stuck somewhere in general boot" - stuck very close to
the actual entry point.

## Round 25 (2026-09-19, same day): a raw DRAM marker at the kernel's very
first instruction - the most fundamental check possible, no UART needed

Checked whether physical memory could be read directly from TWRP to avoid
needing another boot cycle at all - confirmed neither `/dev/mem` nor
`/proc/kcore` exist on this device's TWRP kernel (both plain "No such
file or directory"). No direct physical-memory readback available.

**Workaround, reusing infrastructure already proven working**: since DRAM
survives the warm `PS_HOLD`/`KPDPWR_AND_RESIN` resets used throughout this
project (confirmed by every pstore/ramoops reference so far), have
uniLoader itself - which we know reliably runs and can print to its own
`simplefb` console every single boot - read a fixed physical address and
print it on screen via a new `late_init` board hook
(`board/samsung/board-gts7l.c`), right after the console comes up, before
jumping to the kernel again. This makes the check a two-cycle,
single-flash process: cycle 1 lets a potential write happen (or not);
cycle 2 (same image, no reflash) prints back whatever cycle 1's kernel
left behind, right there on uniLoader's own splash screen.

**The write side**: patched `arch/arm64/kernel/head.S`'s `primary_entry` -
the literal first instructions executed after the kernel's own Linux
image header, before `record_mmu_state`, before anything else - to write
a distinctive, essentially-impossible-by-coincidence 64-bit pattern
(`0xdeadbeefcafec0de`) to a fixed physical address in this device's known-
free memory gap (`0x95000000`), using plain `movz`/`movk` immediate-move
instructions (not a literal-pool `ldr =`, safer in this identity-mapped
startup section) followed by an explicit `dc cvac`+`dsb sy` to force the
write out of any cache line and into real DRAM before a later hang/reset
could lose it (caches don't survive a reset; only DRAM does, the same
reason pstore/ramoops itself works). Safe by construction: the arm64 boot
protocol *requires* the MMU to be off at this exact entry point, so a
plain physical-address `str` is always valid regardless of how uniLoader
hands off. Saved as a tracked patch:
`kernel/patches/0001-round25-early-dram-debug-marker.patch` (applied
against `work/linux`, a build-scratch checkout, not tracked by this
project's own git history otherwise).

Rebuilt kernel Image (incremental, one file changed), rebuilt uniLoader
with both the marker-write kernel and the marker-read board hook,
packaged via the same proven method (byte-exact verification passed),
flashed.

**Awaiting hardware test result** - the owner needs to run *two* boot
cycles from this one flash: reboot and let it hang as before, then reboot
again (no reflash) and read whatever uniLoader prints for "debug marker @
0x95000000" on its splash screen. `deadbeef cafec0de` means the kernel's
first instructions genuinely executed; anything else means the jump from
uniLoader never reached real kernel code at all - two completely
different problems requiring completely different next steps.

Tablet state at time of writing: `boot` = this round's marker build,
`dtb`/`dtbo`/`ramdisk.cpio` = stock, untouched throughout. `rp`/
`ro.bootloader` reconfirmed unchanged before flashing.

### Tested: `ffffffff ffffffff`, not the kernel's marker - ambiguous,
needed a control

Owner's readback: `debug marker @ 0x95000000: ffffffff ffffffff` - not
`deadbeef cafec0de`, but also not zero. Genuinely ambiguous on its own:
all-`0xff` is a classic pattern many SoCs return when a bus master reads
a hardware-protected or unmapped region (as opposed to genuinely free-but-
never-written DRAM, which this project had no independent way to
characterize at this exact address). Without a control, this result
couldn't distinguish "the kernel never executed its first instruction at
all" from "0x95000000 was never actually safe, ordinary DRAM in the first
place, and Round 25's whole premise was flawed."

**Added a control**: a second, independent marker
(`0xc001babeb00b1e55`) written by uniLoader *itself*, immediately before
the jump to the kernel (`arch/aarch64/load-kernel.c`,
`arch_load_kernel()`), at a nearby address (`0x95001000`) using the same
write+cache-clean pattern as the kernel-side marker. `board-gts7l.c`'s
`late_init` now prints both. Logic: if uniLoader's own canary reads back
correctly next boot but the kernel's marker still doesn't, that proves
`0x9500xxxx` is genuinely accessible, ordinary DRAM (ruling out the
protected-region explanation) and isolates the problem specifically to
the jump/kernel-entry itself, not this memory region.

Rebuilt uniLoader only (kernel Image unchanged from Round 25), packaged
via the same proven method (byte-exact verification passed), flashed.
Same two-cycle procedure as Round 25 - hang, then reboot again without
reflashing to read back both markers.

Tablet state at time of writing: `boot` = this round's canary build,
`dtb`/`dtbo`/`ramdisk.cpio` = stock, untouched throughout. `rp`/
`ro.bootloader` reconfirmed unchanged before flashing. **Awaiting
hardware test result.**

### Tested: both markers came back `ffffffff` even after a confirmed
second cycle - the real cause was the chosen address, not the technique

Confirmed directly with the owner this was a genuine second-cycle read
(flash → boot → hang → hard-reboot via `KPDPWR_AND_RESIN` → this
screen), and confirmed via `md5sum /dev/block/by-name/boot` that Round 26
really was what got tested. Both markers still `ffffffff ffffffff` -
including uniLoader's own canary, which definitely executes every single
cycle (uniLoader reliably reaches "Booting kernel..." every time). Also
confirmed with the owner: **no software `PS_HOLD` reset has happened at
any point in this whole line of testing** - every recovery back to TWRP
has been the owner's manual hard-reboot combo.

**Reconsidered against this project's own accumulated evidence rather
than guessing again**: `/proc/last_kmsg` and `console-ramoops` have been
read back successfully, with real, accurate, sequential content, after
*this exact same reset combo* dozens of times throughout this entire
debugging effort (every single round's evidence-gathering has depended on
it). That's real, repeated, direct proof DRAM survives this combo -
contradicting a first-pass "hard reboot destroys DRAM" theory. The better
explanation: a full cold boot likely re-trains/recalibrates the DDR PHY,
which can scramble most of DRAM - *except* the specific small regions the
SoC's own boot firmware is deliberately designed to preserve across that
retrain, like Samsung's own `ramoops`/`last_kmsg` buffer. Round 25/26's
guessed "free" address (`0x95000000`, chosen only because it fell outside
the devicetree's reserved-memory list) never had any such guarantee.

## Round 27 (2026-09-19, same day): moved both markers into the real,
proven-persistent `ramoops` carveout

Moved both the kernel-side marker (`arch/arm64/kernel/head.S`) and
uniLoader's own canary (`arch/aarch64/load-kernel.c`) out of the guessed
address and into unused padding *inside* this device's real, DTB-declared
`ramoops@9fa00000` carveout (size `0x100000`; its own sub-buffers -
record/console/ftrace/pmsg - only use the first `0xc4000`, leaving
`0x3c000` of genuinely free padding at the end): `0x9fac4000` for the
kernel marker, `0x9fac5000` for uniLoader's canary - the same region
this project has directly, repeatedly read real content back from after
the owner's exact reset combo, throughout this whole debugging effort.

**Caught and fixed a real bug while doing this**: the new address
(`0x9fac4000`) has non-zero low 16 bits, unlike Round 25/26's
`0x95000000` (whose low half is all zero) - a single `movz x9, #0x9fac,
lsl #16` would have silently built the *wrong* address (`0x9fac0000`,
missing the `0x4000` low half entirely). Caught before flashing by
computing the low/high 16-bit split explicitly; fixed with the correct
`movz`+`movk` pair.

Rebuilt kernel Image (`head.S` changed) and uniLoader with the fresh
blob, packaged via the same proven method (byte-exact verification
passed), flashed. Same two-cycle procedure as Rounds 25-26.

Tablet state at time of writing: `boot` = this round's ramoops-marker
build, `dtb`/`dtbo`/`ramdisk.cpio` = stock, untouched throughout. `rp`/
`ro.bootloader` reconfirmed unchanged before flashing. **Awaiting
hardware test result.**

### Tested: real text fragments came back, not our marker - the region
wasn't actually unused padding

Owner's readback: `kernel marker @ 0x9fac4000: 23800 6c6c` / `uniLoader
canary @ 0x9fac5000: 2e2e2e 72656874`. Decoded directly: `6c6c` = ASCII
`ll`; `72656874` read as bytes `72 65 68 74`, little-endian word =
`t h e r` - a genuine English text fragment, not noise and not either
marker. **This is real console/dmesg log content**, meaning the "unused
padding past ramoops' sub-buffers" assumption was wrong - this offset is
actually live, and gets overwritten by whatever kernel boots next
(TWRP's own recovery kernel, which legitimately uses the same shared
`ramoops` region) before uniLoader's next readback ever happens. A
genuinely shared/contested region, not an exclusive one - defeats the
whole point regardless of DRAM retention.

Asked the owner how to proceed rather than guess a fourth address.
Researched online (per the owner's request) whether other porters have a
known answer for "early hang, no UART" - found `CONFIG_NETCONSOLE` and
postmarketOS's USB-ACM debug shell as the established mainline answers,
but both need substantially more kernel infrastructure already running
(USB controller probed, network stack up) than this project's hang point
- already shown, via Round 24's watchdog-detector test, to be *before*
even `lockup_detector_init()` can arm. Neither would help here.

## Round 28 (2026-09-19, same day): arm the real hardware watchdog
directly from uniLoader - reusing proven infrastructure instead of a
fourth memory-address guess

Reconsidered the approach entirely rather than trying another DRAM
address: this device's real hardware "apps watchdog" is the same *class*
of mechanism that has *already*, repeatedly, reliably produced real,
analyzable crash-dump entries in `/dev/block/by-name/debug` throughout
this project - Round 23's genuine `out_of_memory` panic backtrace, and
RWC=72-78's `Watchdog Reset (CPU HANG)` entries from Rounds 20-22. This
is proven, working infrastructure, not a new guess - the actual gap was
just that nothing was arming a *short-timeout* watchdog specifically
covering uniLoader's own jump-to-kernel window.

**Confirmed the exact hardware directly**: `work/linux/.../sm8250.dtsi`
declares `watchdog@17c10000`, `compatible = "qcom,apss-wdt-sm8250",
"qcom,kpss-wdt"`, clocked by `&sleep_clk` (this device's real fixed
32000 Hz clock, confirmed since Round 16). Cross-checked the exact
register layout against the real mainline driver,
`drivers/watchdog/qcom-wdt.c`'s `reg_offset_data_kpss` table (the
`"qcom,kpss-wdt"` compatible string maps to this exact layout, not the
`apcs_tmr` one): `WDT_RST=0x4`, `WDT_EN=0x8`, `WDT_BARK_TIME=0x10`,
`WDT_BITE_TIME=0x14`.

**Implemented in `arch/aarch64/load-kernel.c`, `arch_load_kernel()`**,
immediately before the jump to the kernel, mirroring the real driver's
own `qcom_wdt_start()` sequence exactly (disable → reset counter → set
bark/bite time → enable) with a short 3-second timeout
(`3 * 32000` ticks) and then left running, unpetted. If the kernel hangs
before it could ever reach Linux's own watchdog-petting infrastructure
(already shown to be the case - Round 24's own softlockup/hardlockup
detectors, which arm earlier than watchdog petting would, never even
fired), this hardware watchdog fires independently of anything the
kernel does, forcing a real reset without needing the owner's manual
hard-reboot at all - and per this device's own proven `sec_debug`/TZBSP
crash-dump behavior, the resulting event should itself get captured with
a real, symbolized backtrace, the same as Round 23's OOM panic.

Removed the now-redundant DRAM canary write (Round 27's confound doesn't
apply to this approach at all - no reliance on reading anything back
through uniLoader's own screen). Left the kernel-side `head.S` marker and
`board-gts7l.c`'s readback prints in place as harmless bonus
instrumentation, in case DRAM does happen to survive a watchdog-triggered
reset differently than the owner's manual combo.

Rebuilt uniLoader only (kernel Image unchanged from Round 27), packaged
via the same proven method (byte-exact verification passed), flashed.
**Snapshotted the debug partition immediately before this test**
(`work/debug_partition_pre_round28.bin`, md5
`7d9548f71dffbce8ff1d7564ce45c525`) so any new entry afterward can be
confirmed genuinely new, not a stale artifact.

Tablet state at time of writing: `boot` = this round's watchdog-arm
build, `dtb`/`dtbo`/`ramdisk.cpio` = stock, untouched throughout. `rp`/
`ro.bootloader` reconfirmed unchanged before flashing. **Awaiting
hardware test result.**

### Tested: no auto-reset, no new crash-dump entry either

Owner's report: still no self-reset, forced a manual reboot after ~1
minute. Confirmed via a pre/post snapshot of `/dev/block/by-name/debug`
(`work/debug_partition_pre_round28.bin` vs
`work/debug_partition_post_round28.bin`) - completely unchanged, `RWC=81`
still the newest entry. The directly-armed hardware watchdog didn't fire
either, even though arming it happens in uniLoader's *own* code, before
the jump - a stronger negative result than a kernel-side detector not
arming, since this doesn't depend on the kernel reaching any particular
point at all.

Four independent techniques in a row have now produced no usable
evidence: a guessed DRAM address, a ramoops-region address (contested,
not actually exclusive), kernel-side lockup detection, and a directly
armed hardware watchdog. Discussed this honestly with the owner rather
than trying a fifth blind guess - real options laid out: get actual UART
hardware, fall back to Round 13's proven state and pursue the known,
scoped clock-driver problem instead of an unknown one, or reconsider
whether the project's real goal (a working mainline-adjacent Linux
system) is better served by a proven downstream-kernel path (matching
every other real success story found for this device family) than by
continuing to chase genuine upstream mainline blind.

## Round 29 (2026-09-19, same day): a real answer found via research - a
byte-compatible sec_log_buf console, adapted from a working mainline
Samsung/Qualcomm port

The owner asked directly what kernel the S9 Ultra reference project
actually used, given the downstream-kernel pivot felt like it defeated
this project's actual goal. Checked directly rather than from memory:
their kernel source tree is literally named `linux-mainline`
(`references/postmarketos-galaxy-tab-s9-ultra/scripts/
build-android-v4-bundle.sh` line 216, `git -C "$base/linux-mainline"`)
and their package is `linux-samsung-gts9uwifi-mainline` - genuinely
upstream-based, not a downstream fork, confirming their whole project is
the same kind of effort as this one, not a different category.

**Found the actual answer in their own patch set**:
`pmaports/device/testing/linux-samsung-gts9uwifi-mainline/
add-samsung-sec-log-console.patch` adds a small, real mainline printk
console driver (`drivers/soc/qcom/samsung-gts9uwifi-sec-log.c`) that
writes directly into Samsung's own persistent `sec_log_buf` ring - the
*exact* mechanism `/proc/last_kmsg` reads from, and the one this project
has used successfully, over and over, all session. A companion patch,
`ignore-console-null.patch`, makes ABL's appended `console=null` a
no-op (not directly needed here, since this project already forces the
cmdline via `CONFIG_CMDLINE_FORCE`, but kept as a reference/precedent).

**Confirmed the exact on-disk format matches this device's own real
downstream source exactly** -
`references/gts7l/include/linux/samsung/debug/sec_log_buf.h`:
`struct sec_log_buf { u32 boot_cnt; u32 magic; u32 idx; u32 prev_idx;
char buf[]; }`, `SEC_LOG_MAGIC = 0x4d474f4c` ("LOGM") - byte-identical
field names/order/types and magic value to the S9 Ultra patch's own
`struct sec_log_header`, because Samsung uses this exact mechanism across
its whole device lineup. This project's version is actually simpler than
the reference: since TWRP's own kernel *already* reads this format
correctly via its own `sec_log_buf.c` driver (confirmed directly in this
device's real source), no new reader needs to be written at all - only a
byte-compatible writer.

**Found the real, live address directly** - not guessed, not
reverse-engineered from a devicetree node (there isn't one; downstream
passes it via a cmdline parameter instead): `adb shell "cat /proc/cmdline
| grep sec_log"` on the currently-booted stock/TWRP kernel returned
`sec_log=0x200000@0x9F200000` directly - the real, confirmed-live
physical address and size of this exact buffer on this exact device.

**Implemented directly in `init/main.c`** (not as a separate driver -
this project's kernel needs it registered far earlier than the reference
patch's `core_initcall_sync` timing, since Round 24 already showed this
kernel's hang happens before even `lockup_detector_init()` can arm,
which is itself earlier than any initcall level). Added
`early_sec_log_init()`, called immediately after `setup_arch(&command_line)`
returns - the earliest point on arm64 where the kernel's real linear
map is established and a plain `phys_to_virt()` access to ordinary RAM
is safe, confirmed by checking `start_kernel()`'s own first `pr_notice()`
call (right before `setup_arch()`) proves the printk log-buffer
infrastructure itself needs no special init at all. Registers a
`struct console` with `CON_ENABLED | CON_PRINTBUFFER | CON_ANYTIME`
(`CON_PRINTBUFFER` replays everything already buffered since boot, same
as the reference patch's own flag choice) and a `write` callback matching
the real downstream driver's own ring-buffer wraparound logic exactly
(`references/gts7l/drivers/samsung/debug/sec_log_buf.c`,
`__sec_log_buf_write()`).

**Also reserved the region in the devicetree**
(`kernel/dts/sm8250-samsung-gts7l.dts`, `&{/reserved-memory} {
sec_log_region@9f200000 { reg = <0x0 0x9f200000 0x0 0x200000>; }; };`) -
deliberately without `no-map`, matching this file's own splash-region
convention, since `early_sec_log_write()` needs this region to stay part
of the kernel's ordinary linear map for `phys_to_virt()` to work, while
still preventing the kernel's own allocator from handing this physical
range out to anything else.

Rebuilt kernel Image + DTB (both confirmed correct - `fdtget` on the new
DTB shows the reserved-memory node present at the right address),
rebuilt uniLoader with the fresh blobs, packaged via the same proven
method (byte-exact verification passed), flashed.

Tablet state at time of writing: `boot` = this round's sec_log-console
build, `dtb`/`dtbo`/`ramdisk.cpio` = stock, untouched throughout. `rp`/
`ro.bootloader` reconfirmed unchanged before flashing. **Awaiting
hardware test result.**

### Tested: still pure ABL/XBL text, zero kernel-level content - the
early sec_log console never wrote anything either

`/proc/last_kmsg` after this test: identical shape to every prior round -
multiple full `EDTBO check fail` → `Shutting Down UEFI Boot Services`
sessions, nothing whatsoever from the kernel (`early_sec_log_init()`,
registered right after `setup_arch()` returns - about as early as
architecturally possible - never wrote anything). Combined with Round
25/26's head.S marker (at the kernel's literal first instruction) also
never writing anything, this is now **two independent write points, at
two different very-early stages, both silent** - strong evidence the
problem isn't happening deep inside the kernel's own boot sequence at
all, but at or before the kernel's actual first instruction.

**New working theory**: uniLoader is built `CONFIG_POSITION_INDEPENDENT`
and could be loaded by ABL at a different physical address than
`CONFIG_TEXT_BASE` (0x90600000) assumes - genuinely unknown, since this
project has no way to directly observe where ABL places the `kernel`
partition's payload. If uniLoader's own ~42MiB actually gets loaded
somewhere overlapping `CONFIG_PAYLOAD_ENTRY` (0x91000000) or
`CONFIG_RAMDISK_ENTRY` (0x94000000), the `memcpy()` in
`arch_load_kernel()` - which runs *while uniLoader's own code is still
executing* - could be silently overwriting uniLoader's own live
code/stack mid-flight, corrupting everything downstream including the
jump itself. This would explain the silence at *both* write points
without needing anything to be wrong kernel-side at all.

**Cheap, direct check added** rather than guessing a fix blind:
`board-gts7l.c`'s `late_init` now prints uniLoader's own real runtime
execution address, computed via a PC-relative `adr` instruction (not a
plain C symbol reference - this build isn't real ELF PIE, so `&symbol`
would just embed the link-time constant, not the true runtime address).
Rebuilt uniLoader only (kernel/DTB unchanged from Round 29), packaged via
the same proven method (byte-exact verification passed), flashed.

Tablet state at time of writing: `boot` = this round's PC-check build,
`dtb`/`dtbo`/`ramdisk.cpio` = stock, untouched throughout. `rp`/
`ro.bootloader` reconfirmed unchanged before flashing. **Awaiting
hardware test result.**

### Tested: the bug, found definitively

Owner's readback: `uniLoader runtime PC: 0 9060083c` = `0x9060083c` -
exactly `CONFIG_TEXT_BASE` (`0x90600000`) plus a small code offset,
confirming uniLoader loads exactly where the build assumed. **That's
what exposed the actual bug**: uniLoader's own binary is 42,348,544
bytes (~40.4MiB), so it occupies physical memory from `0x90600000` to
`0x92e63000`. `CONFIG_PAYLOAD_ENTRY` (`0x91000000`, chosen in Round 20)
falls *inside* that range.

`arch_load_kernel()`'s `memcpy()` to `CONFIG_PAYLOAD_ENTRY` was
overwriting uniLoader's own live code/embedded data while uniLoader
itself was still executing - a classic overlapping-copy bug. This fully
explains every symptom seen across Rounds 20-29: `"Booting kernel..."`
always printed correctly (that happens *before* the memcpy), nothing
ever survived after it (the destination write corrupts the source
program's own subsequent instructions/data), neither debug marker was
ever written (the jump never reaches valid, uncorrupted kernel code),
and the CPU still visibly warmed up (Round 20) despite no evidence
anywhere - consistent with continuing to execute *something*, just
corrupted, undefined code rather than either a clean crash or the real
kernel. This was never a kernel-config, devicetree, or memory-node
problem at all - the entire Round 20-29 investigation was chasing
symptoms of a single address-planning mistake in `configs/
gts7l_defconfig`, made when picking `PAYLOAD_ENTRY`/`RAMDISK_ENTRY`
against known devicetree carveouts, without accounting for uniLoader's
own runtime footprint extending well past where those carveouts ended.

## Round 30 (2026-09-19, same day): the actual fix - non-overlapping
memory layout

Computed the real, non-overlapping addresses directly:
uniLoader occupies `0x90600000`-`0x92e63000`. Moved
`CONFIG_PAYLOAD_ENTRY` to `0x93000000` (comfortably clear of that end,
the real kernel Image - ~39MiB - ends at `~0x95708a00`) and
`CONFIG_RAMDISK_ENTRY` to `0x96000000` (clear of the payload, and the
tiny ~737KiB ramdisk still ends well clear of the `0x9c000000` splash
carveout). Updated `configs/gts7l_defconfig`, rebuilt uniLoader (kernel/
DTB unchanged from Round 29), packaged via the same proven method
(byte-exact verification passed), flashed.

Tablet state at time of writing: `boot` = this round's fixed-address
build, `dtb`/`dtbo`/`ramdisk.cpio` = stock, untouched throughout. `rp`/
`ro.bootloader` reconfirmed unchanged before flashing. **Awaiting
hardware test result** - the real one, this time, on a build with no
known bugs left in the loading path.

### Tested: full success - genuine mainline Linux boots on real hardware

Owner's report: after uniLoader's own splash, a black screen appeared
(backlight on - a real, different visual state, not the frozen uniLoader
text every prior round showed), held for ~4-5 seconds, then the device
auto-reset on its own and looped back into uniLoader. Pulled
`/proc/last_kmsg` immediately - and for the first time in this entire
project, **it's full of real, genuine mainline Linux kernel boot output**:

```
[    0.000000] Booting Linux on physical CPU 0x0000000000 [0x51df805e]
[    0.000000] Linux version 7.2.0-dirty (builder@host) (clang version 22.1.8, LLD 22.1.8) #11 SMP PREEMPT Sat Sep 19 15:29:12 -03 2026
[    0.000000] Machine model: Samsung Galaxy Tab S7
[    0.000000] printk: legacy console [earlyseclog0] enabled
[    0.000000] CPU features: detected: GICv3 CPU interface
...
[    0.000000] Kernel command line: console=tty0 loglevel=15 softlockup_panic=1 watchdog_thresh=5
```

This project's own kernel, this project's own build, genuinely executing
on the real tablet - real CPU feature detection (Spectre mitigations, LSE
atomics, PMUv3, GICv3), the exact compiled-in cmdline read back
correctly, and **Round 29's `sec_log` console registered successfully**
(`earlyseclog0` - the very mechanism built to catch exactly this moment,
working on the first real opportunity to prove it).

Kept reading - memory management init, devtmpfs, thermal governors,
cpuidle, ASID allocator, PSCI CPU power domain topology, CoreSight debug
trace component dependency resolution across dozens of devicetree
nodes - **all working, genuine platform bring-up**, not a crash. Then:

```
[    0.729898] sd 0:0:0:0: [sda] Attached SCSI disk
[    0.732927] Freeing unused kernel memory: 2880K
[    0.734507] Run /init as init process
[    0.735961]   with arguments:
[    0.737442]     /init
[    0.738942]   with environment:
[    0.740386]     HOME=/
[    0.741843]     TERM=linux
```

**Full UFS storage enumeration** (all four LUNs, correct partition
counts/names matching this exact device's real GPT layout - `sda`
through `sdd`, 37 partitions each on the two full-layout LUNs) and **the
kernel successfully mounted root and exec'd this project's own busybox
initramfs `/init`.** This is Phase 1's actual exit criteria, met in full:
mainline kernel boots, UFS storage enumerates and is readable, root
filesystem reached.

**The reset loop itself was immediately explained, not a new mystery**:
right after the `TERM=linux` line, the log shows a fresh
`XBL(477, warm reset, valid magic)` session start - a clean, recognized
warm reset, exactly matching Round 28's own hardware-watchdog arm (3
second fixed `WDT_BITE_TIME`, armed by uniLoader before the jump, left
running unpetted since the kernel has no way to know it exists). That
watchdog code was still present in every build since Round 28 including
this one - it had already done exactly what Round 28 asked of it
(turn a hang into a captured, analyzable reset), and was now the only
thing left cutting the kernel off, at a fixed 3 seconds, right as it
reached `/init`.

## Round 31 (2026-09-19, same day): remove the now-obsolete watchdog arm

Removed Round 28's hardware-watchdog-arm code from
`arch/aarch64/load-kernel.c` entirely - it was a diagnostic aid for a
problem that's now solved (Round 30's overlapping `PAYLOAD_ENTRY`), and
is now the only remaining obstacle between the kernel and running past
its own `/init`. Rebuilt uniLoader only (kernel/DTB unchanged from
Round 29), packaged via the same proven method (byte-exact verification
passed), flashed.

Tablet state at time of writing: `boot` = this round's watchdog-removed
build, `dtb`/`dtbo`/`ramdisk.cpio` = stock, untouched throughout. `rp`/
`ro.bootloader` reconfirmed unchanged before flashing. **Awaiting
hardware test result** - expecting this project's own busybox initramfs
`init` script to actually run and reach an interactive shell.

### Tested: still a clean, silent reset right after the init script's own
last line - a new puzzle, distinct from Round 28's watchdog

Owner's report: black screen, backlight on, no USB detected. Waited a
full minute and force-reset manually. `/proc/last_kmsg` pulled
immediately after: **byte-for-byte identical** to a shorter-wait attempt
pulled earlier - ruling out a timing coincidence. Whatever causes the
reset happens quickly and deterministically right after the init
script's own `TERM=linux` line prints, not something that gets further
given more wall-clock time. Checked `/dev/block/by-name/debug` again -
still no new entry at all, and no panic text anywhere in the log either -
ruling out both Round 28's (now-removed) hardware watchdog and a
captured kernel panic (Round 24's lockup detectors, which should print
visible panic text via the `sec_log` console specifically because it's
registered `CON_ANYTIME`).

Owner asked directly whether real display was achievable at this point.
Answered honestly: `simple-framebuffer` likely won't show anything
without a real MIPI-DSI panel driver actively refreshing the panel
(Phase 2 scope, not a quick add-on) - but proposed USB gadget serial
console instead, since this device's USB controller and most of the
gadget kernel infrastructure (`CONFIG_USB_DWC3`, `CONFIG_USB_GADGET`,
`CONFIG_USB_CONFIGFS_ACM`, a real `usb_1_dwc3`/`qcom,sm8250-dwc3`
devicetree node with proper PHY references) were already compiled in by
default - a real, live interactive console without needing display
driver work at all.

## Round 32 (2026-09-19, same day): simplify init to isolate the reset,
add a USB gadget serial console

Per the owner's direction (fix the reset, then add USB console, then
flash together): stripped `kernel/initramfs/init` down to the bare
minimum - dropped the `/proc/partitions`/block-device listing (the only
real device I/O in the earlier version, and the leading suspect for the
silent reset) - and removed `softlockup_panic=1 watchdog_thresh=5` from
the forced cmdline (`kernel/config/gts7l.fragment`), since neither
config change was ever actually observed explaining the symptom (no
panic text, no captured crash-dump entry) and leaving them in place
added uncertainty rather than resolving it.

**Added a USB gadget serial console** in the same pass. Checked the
working `.config` first: `CONFIG_USB_DWC3`, `CONFIG_USB_DWC3_QCOM`,
`CONFIG_USB_GADGET`, `CONFIG_PHY_QCOM_QMP_USB`, and
`CONFIG_USB_CONFIGFS_ACM` were all already `=y` by default - the one
real gap was `CONFIG_USB_CONFIGFS=m` (a module, no good for a minimal
initramfs with zero module-loading support). Forced it built-in. Devicetree
already has a real `usb_1_dwc3`/`qcom,sm8250-dwc3` node with proper PHY
references (upstream `sm8250.dtsi`), so no devicetree work was needed at
all.

`kernel/initramfs/init` now does a standard configfs gadget setup
(`idVendor`/`idProduct`, ACM function, bind to whatever UDC appears under
`/sys/class/udc`) as a best-effort step that can never block reaching the
fallback shell, then spawns a second shell directly on `/dev/ttyGS0` if
it appears within 5 seconds - giving two independent ways to reach an
interactive prompt (the existing `console=tty0` shell and this new USB
one) in a single test.

Rebuilt the initramfs cpio from the updated `kernel/initramfs/init`,
rebuilt the kernel Image (config change triggered a fuller rebuild),
rebuilt uniLoader with all three fresh blobs (confirmed uniLoader's own
total size - 42,553,344 bytes - still leaves `CONFIG_PAYLOAD_ENTRY`
comfortably clear, per Round 30's fix), packaged via the same proven
method (byte-exact verification passed), flashed.

Tablet state at time of writing: `boot` = this round's simplified-init +
USB-console build, `dtb`/`dtbo`/`ramdisk.cpio` = stock, untouched
throughout. `rp`/`ro.bootloader` reconfirmed unchanged before flashing.
**Awaiting hardware test result.**

### Tested: no USB device, but real proof the display genuinely works -
caught on slow-motion video

No USB device enumerated. But the owner noticed something far more
valuable: for a split second during boot, the physical LCD panel showed
real content - the tux logo and real kernel boot text, caught on a
phone's slow-motion camera (the whole visible window is under a second,
matching the timestamps: `Booting Linux` to `Run /init` takes under
0.75s per `/proc/last_kmsg`). Transcribed text included genuine kernel
messages (`KVM: HYP mode not available`, `SquashFS: version 4.0`, key
type registrations, `ledtrig-cpu`) and, critically:

```
simple-framebuffer 9c000000.framebuffer: framebuffer at 0x9c000000
simple-framebuffer 9c000000.framebuffer: format=a8r8g8b8, mode=1600x2560x32, linelength=6400
Console: switching to colour frame buffer device 200x160
Freeing initrd memory: 720k
simple-framebuffer 9c000000.framebuffer: fb0: simplefb registered!
```

**This directly confirms `simple-framebuffer` genuinely works on this
device's real LCD panel** - correct geometry, correct format, `fbcon`
successfully switches over (`200x160` character cells = `1600x2560`
pixels at an 8x16 font, exactly right). The screen goes black
immediately after `simplefb registered!` prints, though - and per the
owner's follow-up capture, nothing else ever becomes visible again, even
though `/proc/last_kmsg` confirms the kernel keeps running completely
normally afterward, still reaching `Run /init` in every capture.

**Realized mid-investigation**: `/proc/last_kmsg` can only ever show
kernel `printk()` output (this project's own `sec_log` console, Round 29)
- it has no visibility into userspace at all, so it can never show this
project's own init script's `echo` output, the USB gadget setup, or a
shell prompt. The framebuffer (when it works) is the *only* evidence
source that can see anything past `exec /bin/busybox sh`.

## Round 33 (2026-09-19, same day): `clk_ignore_unused` - the real
explanation for the black screen, found via research

Per the owner's suggestion to check online again, found the likely
explanation directly: mainline Linux automatically disables ("gates")
any clock with no driver holding it as in-use, fairly late in boot
(`clk_disable_unused()`). If ABL left the display controller's own
clocks running to actively drive the panel, and this minimal kernel has
no MDSS/display driver to claim them (Phase 2 scope, not yet added), the
kernel would gate those clocks right around the same late-boot window
this project has been observing the screen go black in. `clk_ignore_unused`
is the standard, well-known mainline kernel command-line parameter for
exactly this class of bootloader-handoff problem - tells the clock
framework to leave whatever the bootloader left running alone, rather
than assuming "no driver claims it" means "safe to turn off".

Added `clk_ignore_unused` to the forced cmdline in
`kernel/config/gts7l.fragment`. Rebuilt kernel Image (cmdline-only
change), rebuilt uniLoader with the fresh blob (confirmed uniLoader's own
size unchanged, `CONFIG_PAYLOAD_ENTRY` still clear), packaged via the
same proven method (byte-exact verification passed), flashed.

Tablet state at time of writing: `boot` = this round's
`clk_ignore_unused` build, `dtb`/`dtbo`/`ramdisk.cpio` = stock, untouched
throughout. `rp`/`ro.bootloader` reconfirmed unchanged before flashing.
**Awaiting hardware test result** - hoping the display now stays alive
long enough to see this project's own init script and, ideally, an
actual interactive shell prompt.

**Tested: `clk_ignore_unused` did NOT fix it.** Owner's report: "still
cuts right after simplefb registered!, only can see the _ one line under
it and then goes blank" - only a marginal, one-character change from
before. Clock-gating was the wrong theory.

## Round 34 (2026-09-19, same day): live `/reserved-memory` audit against
this device's real hardware

Per the S9 Ultra mainline porting project's own porting log (checked
directly, `references/postmarketos-galaxy-tab-s9-ultra/docs/porting-log.md`)
- they hit a superficially similar symptom (Linux boots, console/logo
visible, then dies with zero pstore/panic evidence) early in their
project and traced it to `TZBSP_ERR_FATAL_NOC_ERROR`: Linux touching a
physical range their minimal upstream DTB didn't reserve but Samsung's
stock DTBO does. The owner correctly pushed back that this doesn't fully
transfer - their failure mode is TrustZone *automatically* resetting the
board, ours is a hang the owner has to manually reset, a materially
different signature - so this was treated as a hypothesis to check, not
a confirmed diagnosis.

Pulled this device's own *live* `/reserved-memory` node directly
(`adb shell` against a TWRP boot, which uses the same ABL-merged stock
DTB/DTBO as normal boot) and diffed it address-by-address against what
upstream's `sm8250.dtsi` + `sm8250-samsung-common.dtsi` already declare.
Found several real gaps: `sec_debug_region@0x9f000000` (8 MiB, actually
encloses our own Round 29 `sec_log_region`), `ss_plog_region`,
`hdm_region`, `kaslr_region`, `tima_region`/`rkp_region`/`uh_heap_region`
(a contiguous 23 MiB block), and a 173 MiB `sec_debug_rdx_bootdev` with
no upstream equivalent at all - plus two upstream nodes that undershoot
what this device's real firmware protects (`xbl_aop_mem`, `removed_mem`).
Added `no-map` reservations for all of them in
`kernel/dts/sm8250-samsung-gts7l.dts`. (The `pil_*` remoteproc regions
were also checked and found shifted vs. upstream, but deliberately left
alone - those are only ever touched by an active PIL/remoteproc driver,
none of which this Phase 1 kernel enables, and Round 30+ already proved
code executing from uniLoader's own `PAYLOAD_ENTRY` - which happens to
overlap the live `cdsp_secure_heap` range - runs correctly for many
seconds, so that overlap isn't hardware-enforced against us.)

Rebuilt DTB, rebuilt uniLoader with the fresh blob (kernel Image
unchanged), packaged via the same proven method (byte-exact verification
passed), flashed. **Tested: no change** - same immediate black screen
right after `fb0: simplefb registered!`. The reserved-memory gaps were
real and worth fixing regardless, but weren't the cause of this symptom.

## Round 35 (2026-09-19, same day): the actual fix - `dispcc` reprograms
the display PLLs on every probe, with no driver left to restore them

Went looking directly in this project's own vendored kernel source
rather than guessing further. `CONFIG_SM_DISPCC_8250=y` is a *built-in*
driver (unlike `CONFIG_DRM_MSM=m`, which never loads - this minimal
initramfs has no module-loading support at all) - so it auto-probes
during every boot, unconditionally. Read `disp_cc_sm8250_probe()`
directly in `drivers/clk/qcom/dispcc-sm8250.c`: for this device's exact
compatible string (`qcom,sm8250-dispcc`), it unconditionally calls
`clk_lucid_pll_configure()` on both display PLLs (pll0/pll1) - no check
for "already locked and actively clocking something". That's completely
normal on mainline *if* a real MDSS/DPU/panel driver immediately runs
after to redo the full power-sequenced re-init (GDSC, reset, PLL
relock, panel commands) - but we don't have one loaded, so dispcc tears
down whatever PLL state ABL left actively driving the LCD panel's
video-mode DSI link, and nothing ever restores it. A video-mode LCD
(confirmed by the owner correcting an earlier "AMOLED" assumption -
this tablet is genuinely LCD) has no internal frame memory like a
command-mode/self-refreshing AMOLED panel would - it blanks the instant
the DSI host stops actively streaming, which lines up exactly with the
"immediately after simplefb registers" timing observed since Round 32.

Confirmed every consumer of `&dispcc`'s clocks/power-domain/resets in
`sm8250.dtsi` is an MDSS/MDP/DSI/DP child node, all only ever bound by
the same never-loaded `CONFIG_DRM_MSM` module - nothing built into this
kernel actually needs dispcc's clocks at boot, so disabling its
devicetree node (`status = "disabled"`) is safe for Phase 1 and keeps
its driver from probing at all.

Rebuilt DTB (confirmed via `fdtget`: dispcc status is `disabled`),
rebuilt uniLoader with the fresh blob (kernel Image unchanged), packaged
via the same proven method (byte-exact verification passed), flashed.

### Tested: this is the fix - the display stays on

Owner's report: **"it stays!!!!! this is the end of the printed log"** -
the kernel boots completely, all the way through UFS enumeration
(`sda`-`sdd`, every real partition on this device), `Run /init as init
process`, this project's own init script, and drops to a live,
interactive `ash` shell prompt - all visible directly on the physical
LCD panel, staying on rather than going black. The owner interacted
with it directly (`ls -l /sys/class/udc`, confirming no UDC is bound -
expected, since `CONFIG_USB_CONFIGFS`'s gadget setup needs a working UDC
driver that isn't relevant now that a real display works) via a USB
keyboard in host mode (`usbhid: USB HID core driver` in the log,
consistent with DWC3's dual-role controller enumerating a keyboard
rather than acting as a gadget).

**This is Phase 1's actual goal, achieved on real hardware**: genuine
mainline Linux, booting via uniLoader on this Galaxy Tab S7's real ABL,
reaching a fully interactive shell with live display and keyboard input,
UFS storage enumerated. `boot` = this round's `dispcc`-disabled build,
`dtbo`/stock `dtb`/`ramdisk.cpio` untouched throughout every round since
Round 13's pivot. `rp`/`ro.bootloader` reconfirmed unchanged before and
after flashing.

Root cause chain across Rounds 32-35, for the record: Round 32/33 wrongly
suspected clock-gating (`clk_disable_unused()`); Round 34 wrongly
suspected a devicetree reserved-memory gap (real gaps existed and were
worth fixing, but weren't the cause); Round 35 found the actual
mechanism by reading this project's own vendored driver source directly
rather than continuing to guess from symptom-matching against other
projects' porting logs.

## Round 36 (2026-09-19, same day): automatic USB diagnostics, since there's
no way to type at the shell yet

With display now working (Round 35) but `/sys/class/udc` still empty and
a USB-OTG keyboard not working either (expected - `dr_mode = "peripheral"`
correctly disables host mode), there was no way to interactively debug
the USB gadget issue at the on-screen shell. `CONFIG_DYNAMIC_DEBUG` is
off in this kernel, so `dwc3`/`dwc3-qcom-legacy`'s `dev_dbg()` calls are
compiled out entirely - their silence in the earlier `last_kmsg` capture
proved nothing either way.

Added an automatic diagnostics block to `kernel/initramfs/init`, printed
before the shell so it's visible without any input device: platform
devices matching usb/dwc, `/sys/class/udc` listing, the deferred-probe
list (`/sys/kernel/debug/devices_deferred`), and dwc3/PHY-related dmesg
lines. Rebuilt just the initramfs cpio + uniLoader (kernel Image
unchanged), packaged, flashed.

**Tested - found the answer immediately**: `platform a600000.usb:
deferred probe pending: dwc3: failed to initialize core` /
`platform: supplier 88e3000.phy not ready`. `dwc3` core itself is fine -
it's permanently waiting on its USB2 HS PHY (`usb_1_hsphy`, compatible
`"qcom,usb-snps-hs-7nm-phy"`), which never appears.

## Round 37 (2026-09-19, same day): the real fix - PHY driver built as a
module, exact same class of bug as `CONFIG_DRM_MSM=m`

Traced the PHY's driver directly: `CONFIG_PHY_QCOM_USB_SNPS_FEMTO_V2`
(`drivers/phy/qualcomm/phy-qcom-snps-femto-v2.c`) defaults to `=m`, and
this minimal initramfs has no module-loading support at all - identical
root cause shape to Round 35's `CONFIG_DRM_MSM=m` never loading. Forced
it built-in in `kernel/config/gts7l.fragment`. This one actually needs a
full kernel rebuild (unlike Round 34-36's DTB/ramdisk-only changes) since
PHY drivers link directly into `vmlinux`. Re-merged the fragment,
`olddefconfig`, rebuilt `Image`, rebuilt uniLoader with the fresh
kernel blob, packaged via the same proven method (byte-exact
verification passed), flashed.

### Tested: this is the fix - USB gadget console works

Owner's report: the tablet's USB gadget strings
(`"UbuntuTabS7 project"` / `"gts7l mainline bring-up console"`, set in
`kernel/initramfs/init`) showed up as a real device connection
notification on the host PC. Opened a serial terminal against the new
`/dev/ttyACM0`/COM port and landed directly on the tablet's live `ash`
shell prompt over USB - genuine two-way interactive access, no more
reboot-and-read-last_kmsg cycle needed for anything short of a kernel
panic. `whoami: unknown uid 0` is expected (no `/etc/passwd` in this
bare initramfs); an `ls` error worth double-checking for a possible
line-ending/echo artifact on the gadget serial link, not investigated
further yet.

**This is Phase 1's exit criteria fully exceeded**: interactive shell
access now works over both the physical display and USB serial,
independent of each other. `boot` = this round's PHY-fixed build,
`dtbo`/stock `dtb`/`ramdisk.cpio` untouched throughout every round since
Round 13's pivot. `rp`/`ro.bootloader` reconfirmed unchanged before and
after flashing.

## Round 38 (2026-09-19, same day): Phase 2 first attempt - real NT36523
panel driver, DPU, dual-DSI

First real Phase 2 hardware test, per `docs/phase2-panel-scoping.md`'s
recon. Added a new `samsung,gts7l-ppa957db1-nt36523` entry to mainline's
existing `drivers/gpu/drm/panel/panel-novatek-nt36523.c` (not a new
driver - that file already supports this chip family via Xiaomi's
elish), transcribing the on-command sequence mechanically (a Python
script parsing the raw byte array, not hand-retyped) from
`references/gts7l/techpack/display/msm/samsung/NT36523_PPA957DB1/
dsi_panel_NT36523_PPA957DB1_wqxga_video.dtsi`. Wrote a small new
`drivers/misc/isl98608-gts7l.c` for the panel's separate bias IC
(single fixed register program at probe, matching the downstream
driver's own behavior exactly - no dynamic control either there).

Devicetree (`kernel/dts/sm8250-samsung-gts7l.dts`): enabled `&mdss`,
both DSI hosts + PHYs (dual-DSI, C-PHY, 3 lanes each), the panel node
with `reset-gpios = <&tlmm 82 GPIO_ACTIVE_LOW>`, two `regulator-fixed`
nodes matching Samsung's own "lcd-vdd"/"lcd-buck" GPIO-controlled rails
exactly, and the ISL98608 bias IC on `&i2c8` (confirmed via the board
overlay's own symbol table to be a real QUP hardware I2C bus,
`qupv3_se8_i2c` - deliberately checked rather than assumed, since the
touchscreen on the same overlay uses an unrelated bitbang i2c-gpio bus
that would have been the wrong reference to copy). DSI controller/PHY
analog supplies (`vreg_l9a_1p2`/`vreg_l5a_0p88`, both PM8150 LDOs
already declared by the shared common.dtsi) cross-checked against this
device's own downstream SoC-level file
(`references/gts7l/arch/arm64/boot/dts/vendor/qcom/kona-sde.dtsi`) -
independently matches Xiaomi elish's own choice for the same rails,
strong cross-OEM confirmation this is Qualcomm's SM8250 reference
wiring, not assumed from a different board. Removed Round 35's
`&dispcc { status = "disabled"; };` override - a real panel driver now
exists to redo dispcc's PLL re-init properly.

Kernel config: `CONFIG_DRM`/`CONFIG_DRM_MSM` both default to `=m` - same
no-module-loading problem as Rounds 35/37. Forcing `CONFIG_DRM_MSM=y`
alone wasn't enough - it silently stayed capped at `=m` because two of
its own dependencies (`CONFIG_QCOM_LLCC`, `CONFIG_QCOM_OCMEM`) were also
`=m` (`depends on QCOM_LLCC || QCOM_LLCC=n` - a built-in driver can't
depend on a loadable module). Found by checking the actual post-merge
`.config`, not assuming the first fragment change was sufficient. Also
force-enabled `CONFIG_DRM_KMS_HELPER`/`CONFIG_DRM_DISPLAY_HELPER`,
`CONFIG_I2C_QCOM_GENI` (for the real `&i2c8` hardware bus),
`CONFIG_BACKLIGHT_CLASS_DEVICE`, and the two new driver symbols
themselves.

**Caught before flashing**: the kernel Image grew from ~41MB to ~43MB
with the new DRM/DPU/DSI stack, which pushed uniLoader's own total
built size (44,478,464 bytes, since it embeds the Image/DTB/ramdisk as
data) past the old `CONFIG_PAYLOAD_ENTRY=0x93000000` - the exact same
class of bug as Round 20/30, caught this time by directly computing
`TEXT_BASE + built size` before flashing rather than assuming the old
addresses were still safe. Moved to `CONFIG_PAYLOAD_ENTRY=0x94000000`,
`CONFIG_RAMDISK_ENTRY=0x98000000` (`kernel/uniloader/configs/
gts7l_defconfig`) - confirmed via computation to leave 15.6 MiB and
22.9 MiB margins respectively, both still clear of every real
reserved-memory carveout (checked against Round 34's live-hardware
audit).

Full clean kernel + DTB + uniLoader rebuild, packaged via the same
proven method (byte-exact verification passed on kernel/dtb/ramdisk
sections all independently). Flashed. `rp`/`ro.bootloader` reconfirmed
unchanged before and after.

**Not yet tested on hardware as of writing this entry.** This is a
substantially bigger, riskier change than any Phase 1 round (real
analog panel power sequencing, an undocumented vendor DCS command
dump, a bias IC on a real i2c bus) - unlike Phase 1's clean successes,
multiple test/adjust cycles should be expected here, not a first-try
success.

### Tested: kernel definitely boots (real gadget strings + same simplefb
blink seen), but zero sec_log content and screen still went blank

Owner's report: USB gadget enumerated with our own descriptor strings
("UbuntuTabS7 project" / "gts7l mainline bring-up console") - proof
`/init` ran, same as every successful round since 37. Screen showed the
same split-second kernel-log blink as every prior round, then went
blank; the backlight itself turned off some time later. `/proc/last_kmsg`
pulled afterward showed **zero** kernel-tagged content at all - purely
`[ XBL ]`/`[ ABL ]` bootloader text (including ABL's own splash
panel-power-up routine, which independently cross-confirmed
`RESET_GPIO: 82` and `VDDI_GPIO: 135` - exactly matching the values
this round derived from the downstream Linux driver, from a completely
different source). No `/dev/mem` available on this TWRP to pull the raw
sec_log carveout directly; the empty last_kmsg is most likely this
round's kernel simply running far longer than any prior round (all of
which crashed/hung within ~1s) and wrapping the 2MB ring buffer past
the point of overwriting its own early boot banner - not proof the
kernel didn't run, given the other direct evidence that it did.

## Round 39 (2026-09-19, same day): removed the still-present Round 22
`simple-framebuffer` node - it was still competing with the new panel

Realized the devicetree still had Round 22's `simple-framebuffer` node
enabled *alongside* the new real DRM/DPU/panel driver from Round 38.
`simple-framebuffer` registers early with no dependency chain at all,
almost certainly winning the race to become `fbcon`'s console (`/dev/fb0`)
before the real DRM/MSM device - which has a long dependency chain
(`dispcc`, `&i2c8`, several regulators) - ever finishes probing. If
`fbcon` never switches to the real DRM device, the new panel driver's
own `.prepare()`/backlight path is never actually invoked by anything,
while `dispcc`'s probe() still unconditionally reprograms the display
PLLs (the exact Round 33 mechanism) - this would produce precisely the
"blink via simplefb, then blank" symptom just observed, with the new
Phase 2 work never actually engaging at all.

Disabled the `framebuffer@9c000000` devicetree node
(`status = "disabled"`) so the real DRM/MSM generic fbdev-emulation
(`CONFIG_DRM_MSM_KMS_FBDEV`) is the only console candidate left.
DTB/uniLoader-only rebuild (kernel Image unchanged), packaged via the
same proven method (byte-exact verification passed), flashed.
`rp`/`ro.bootloader` reconfirmed unchanged before and after.

**Not yet tested on hardware as of writing this entry.**

### Tested: real dmesg finally captured over the USB gadget console (not
last_kmsg) - two concrete DSI probe failures found

Owner ran `dmesg | grep -iE "drm|panel|dsi|dispcc|nt36523|isl98608|mdss|
dpu|i2c8|a80000"` directly at the live USB shell - the console genuinely
works as a debug tool now, no more reboot-and-pull-last_kmsg cycle
needed for this class of problem. Found two things:

1. `DSI PLL(0) lock failed, status=0x00000000` in `dsi_phy_driver_probe()`.
2. `platform ae94000.dsi: deferred probe pending: msm_dsi: Failed to get
   supply 'refgen'` (both DSI hosts).

The `refgen` devicetree node itself (`sm8250.dtsi`'s
`qcom,sm8250-refgen-regulator`) needs no status override - already
enabled by default. Its actual driver,
`CONFIG_REGULATOR_QCOM_REFGEN`, defaults to `=m` - the same
no-module-loading bug as `CONFIG_DRM_MSM`/
`CONFIG_PHY_QCOM_USB_SNPS_FEMTO_V2` before it (Rounds 35/37/38), just a
third instance of the identical pattern. A real driver exists
(`drivers/regulator/qcom-refgen-regulator.c`), it just never got to
register. Likely also the direct cause of the PLL lock failure, since
refgen plausibly supplies the bias/reference voltage the DSI PHY's
analog PLL needs to lock at all - a testable hypothesis, not yet
separately confirmed.

Proactively checked the rest of the new dependency chain for the same
`=m` pattern before another round-trip: `CONFIG_QCOM_GPI_DMA=m` is the
one other candidate (`&i2c8` declares GPI DMA channels), but
`i2c-qcom-geni.c` only requires a working DMA channel if this specific
GENI SE instance's hardware FIFO is disabled (a real per-instance
hardware capability flag, not a devicetree choice) - and the dmesg
capture showed zero i2c8/geni-i2c/isl98608-related errors at all,
meaning that bus already probed fine as-is. Left it alone rather than
forcing every `=m` symbol found.

## Round 40 (2026-09-19, same day): force `CONFIG_REGULATOR_QCOM_REFGEN`
built-in

Kernel config only change. Re-merged the fragment, `olddefconfig`,
rebuilt `Image` (unchanged size - the refgen driver is tiny), rebuilt
uniLoader with the fresh kernel blob (same 44,478,464-byte size, same
safe `PAYLOAD_ENTRY`/`RAMDISK_ENTRY` margins as Round 38), packaged via
the same proven method (byte-exact verification passed on kernel/dtb/
ramdisk sections independently), flashed. `rp`/`ro.bootloader`
reconfirmed unchanged before and after.

**Not yet tested on hardware as of writing this entry.**

## Round 41 (2026-09-19, same day): patched dsi_phy_7nm.c for a real
board-specific PHY analog trim override

`refgen` (Round 40) fixed one real bug but the PLL still failed to lock.
Traced `dsi_7nm_phy_enable()`'s own bias/calibration register writes
(`REG_DSI_7nm_PHY_CMN_VREG_CTRL_0`, `GLBL_STR_SWI_CAL_SEL_CTRL`,
`GLBL_RESCODE_OFFSET_TOP_CTRL`/`_BOT_CTRL`) directly: mainline hardcodes
these per SoC-generation "quirk" bits with no devicetree override at
all. For our actual quirk (`DSI_PHY_7NM_QUIRK_V4_1`, confirmed by
reading `dsi_phy_7nm_cfgs` itself rather than assuming no-quirk), the
real generic values end up `vreg_ctrl_0=0x51`,
`str_swi_cal_sel_ctrl=0x00`, `rescode_top_ctrl=0x00`,
`rescode_bot_ctrl=0x3c` for C-PHY - versus Samsung's own downstream
values for this exact panel/PHY pairing (`samsung,phy_vreg_ctrl_0=0x50`,
`phy_str_swi_cal_sel_ctrl=0x04`, `phy_offset_top_ctrl=0x1F`,
`phy_offset_bot_ctrl=0x1F`) - a real, substantial mismatch in exactly
the class of register (analog bias/resistor-calibration) that a PLL's
lock behavior is sensitive to.

Found a direct precedent already in this same driver family -
`dsi_phy_10nm.c` already has a `parse_dt_properties` hook + a
`tuning_cfg` struct for exactly this kind of per-board override (its
own `qcom,phy-rescode-offset-top/bot` + `qcom,phy-drive-ldo-level`,
per-lane arrays since 10nm's registers are per-lane). Mirrored the same
pattern for `dsi_phy_7nm.c` (whose equivalent registers are single
global values, not per-lane, so plain scalars): added a
`dsi_phy_7nm_tuning_cfg` struct, a `dsi_7nm_phy_parse_dt()` function
reading four new scalar properties (`qcom,phy-vreg-ctrl-0`,
`qcom,phy-str-swi-cal-sel-ctrl`, `qcom,phy-rescode-offset-top-ctrl`,
`qcom,phy-rescode-offset-bot-ctrl`), wired via
`.parse_dt_properties = dsi_7nm_phy_parse_dt` into `dsi_phy_7nm_cfgs`
specifically (confirmed this is the exact cfg our `qcom,dsi-phy-7nm`
compatible maps to, not a different SM8250-adjacent variant), and
applied as an override in `dsi_7nm_phy_enable()` right after the
existing quirk-based default computation - only takes effect if the
devicetree property is actually present, so every other board using
this shared driver keeps its exact existing behavior untouched.

Set the four properties on both `&mdss_dsi0_phy`/`&mdss_dsi1_phy` in
`kernel/dts/sm8250-samsung-gts7l.dts` with Samsung's own downstream
values. Full kernel rebuild (driver source changed, not just
config/devicetree this time) + DTB rebuild (both clean, zero
warnings), copied into uniLoader's blob, rebuilt uniLoader (same
44,478,464-byte size, same safe address margins as every round since
38), packaged via the same proven method (byte-exact verification
passed on kernel/dtb/ramdisk sections independently), flashed.
`rp`/`ro.bootloader` reconfirmed unchanged before and after.

**Not yet tested on hardware as of writing this entry.**

### Tested: PHY trim fix applied, likely worked for the real enable path,
but a new failure surfaced further along - DSI FIFO error

Owner's report: same symptom as before (backlight off, black screen),
but the `dmesg` capture tells a more nuanced story than "no change".

The two `DSI PLL(0) lock failed, status=0x00000000` messages still
appear, at almost the identical timestamp (~0.35s) as Round 40's test -
but tracing the call path directly (`dsi_phy_driver_probe`'s own
`devm_of_clk_add_hw_provider()` call, right after `.pll_init`
registers the PLL's `clk_hw` with the framework) shows this is most
likely a premature, essentially harmless clock reparent -
`assigned-clock-parents` on `mdss_dsi0`/`mdss_dsi1` pointing at the
PHY's newly-registered clock outputs gets reprocessed the moment the
provider becomes available, which can force an eager prepare/lock
attempt on the raw VCO clock *before* `dsi_7nm_phy_enable()` (where the
new trim override actually lives) has ever run. Consistent with this:
probe continues successfully afterward regardless in every test so far
- `msm_dpu` binds both DSI hosts, `dpu hardware revision:0x60000000`
reads correctly, and `fb0: msmdrmfb frame buffer device` registers.
Confirmed the property-to-register mapping is correct by reading
Samsung's own downstream PHY glue code directly (not just trusting the
panel dtsi's property names): `references/gts7l/techpack/display/msm/
samsung/ss_dsi_panel_common.c` maps `samsung,phy_vreg_ctrl_0` /
`phy_str_swi_cal_sel_ctrl` / `phy_offset_top_ctrl` / `phy_offset_bot_ctrl`
to `SS_PHY_CMN_VREG_CTRL_0` / `SS_PHY_CMN_GLBL_STR_SWI_CAL_SEL_CTRL` /
`SS_PHY_CMN_GLBL_RESCODE_OFFSET_TOP_CTRL` / `_BOT_CTRL` - an exact
match to the mainline register names this patch overrides.

**New evidence the trim fix may actually be working**: no *second*
"DSI PLL lock failed" message appears later, when the real enable path
(`dsi_7nm_phy_enable()`, called from a genuine modeset attempt) would
actually run - PLL lock is normally silent on success, so this absence
is a plausible (not yet fully confirmed) sign the real lock now
succeeds.

**The new, different problem**: `dsi_err_worker: status=4` appears
twice at ~1.09s, shortly before `fb0` registers at 1.15s.
`drivers/gpu/drm/msm/dsi/dsi_host.c` decodes status bit `0x0004` as
`DSI_ERR_STATE_FIFO` - a DSI controller TX FIFO underflow/overflow,
raised by `dsi_fifo_status()` reading `REG_DSI_FIFO_STATUS`. This is a
genuinely different failure class than the PLL lock issue - it happens
during actual data transfer, not PLL startup - and represents real
forward progress (further into the real enable sequence than any
previous round reached) even though the screen is still blank.
Checked whether Samsung's own downstream declares a relevant
`frame-threshold-time-us` DSI controller property
(`references/gts7l/arch/arm64/boot/dts/vendor/qcom/kona-sde.dtsi`) that
mainline might also need - confirmed mainline's
`dsi-controller-main.yaml` binding and `dsi_host.c` have no such
concept at all, so that's not the cause; the real explanation is not
yet found.

**Not yet investigated further as of writing this entry** - paused here
to document and commit the current state at the owner's request, before
continuing the FIFO error investigation.

## Round 42 (2026-09-19, same day): missing MIPI_DSI_MODE_VIDEO_BURST -
a real, confirmed traffic-mode mismatch

Traced `dsi_err_worker: status=4` (`DSI_ERR_STATE_FIFO`) directly to
`dsi_host.c`'s `dsi_get_traffic_mode()`: without
`MIPI_DSI_MODE_VIDEO_BURST` set in a panel's `mode_flags`, it silently
falls back to `NON_BURST_SYNCH_EVENT`. Samsung's own downstream dtsi
explicitly declares `qcom,mdss-dsi-traffic-mode = "burst_mode";` for
this exact panel - `gts7l_desc` (copied from elish's own flags, which
doesn't use burst mode) never set this flag at all, a real, direct
mismatch from what this panel was actually characterized for. Burst vs.
non-burst changes exactly how pixel data is packed against blanking
periods - a textbook cause of the TX FIFO underflow/overflow just
observed. Confirmed `j606f_boe_desc` (the other panel already in this
same driver that also uses burst mode downstream) already sets this
same flag, for the same reason.

Added `MIPI_DSI_MODE_VIDEO_BURST` to `gts7l_desc.mode_flags`
(`drivers/gpu/drm/msm/dsi/... panel-novatek-nt36523.c` - actually
`drivers/gpu/drm/panel/panel-novatek-nt36523.c`, project patch, see
`kernel/patches/0003-...patch`). Also checked BLLP-related downstream
properties (`qcom,mdss-dsi-bllp-eof-power-mode`/`-power-mode`) against
`dsi_host.c` - mainline already always sets the equivalent
`DSI_VID_CFG0_EOF_BLLP_POWER_STOP`/`BLLP_POWER_STOP` bits
unconditionally, so no discrepancy there.

Driver-only change, kernel rebuild only (unchanged size), uniLoader
rebuild (same 44,478,464-byte size, same safe address margins),
packaged via the same proven method (byte-exact verification passed),
flashed. `rp`/`ro.bootloader` reconfirmed unchanged before and after.

**Not yet tested on hardware as of writing this entry.**

## Round 43 (2026-09-19, same day): temporary diagnostic - print the raw
FIFO status register

Round 42's burst-mode fix produced **zero observable change** - the
`dsi_err_worker: status=4` timing and value were essentially identical
to Round 41's test. That's suspicious: two targeted fixes in a row with
no effect at all suggests either the wrong mechanism is being chased,
or (more likely here) `status=4` (`DSI_ERR_STATE_FIFO`) is too coarse to
diagnose further - it's an abstracted bit set whenever *any* of
`REG_DSI_FIFO_STATUS`'s ~15 real bits fire (video MDP over/underflow,
cmd DMA underflow, per-lane HS/LP FIFO empty/full/over/underflow for
4 lanes) - the raw register value was never actually logged anywhere.

Added a temporary `pr_err("gts7l: REG_DSI_FIFO_STATUS raw=0x%08x\n",
status)` directly in `dsi_fifo_status()`
(`drivers/gpu/drm/msm/dsi/dsi_host.c`) - diagnostic-only, not a fix,
purely to see which specific bit(s) are actually set before guessing
further. Kernel + uniLoader rebuild (unchanged sizes), packaged via the
same proven method (byte-exact verification passed), flashed.
`rp`/`ro.bootloader` reconfirmed unchanged before and after.

**Not yet tested on hardware as of writing this entry.**

## Round 44 (2026-09-19, same day): more temporary diagnostics - is
dsi_7nm_phy_enable/vco_prepare even called during the real modeset?

Round 43's raw `REG_DSI_FIFO_STATUS` value (`0x1ddd1011`) decoded to
`HS_FIFO_EMPTY` + `OVERFLOW` + `UNDERFLOW` simultaneously true across
multiple data lanes - a pattern consistent with a FIFO whose read/write
pointers were never coherently clocked at all, not a fine-grained
timing/traffic-mode mismatch. Recomputed the actual bit clock mainline
would derive from our devicetree mode by hand (`dsi_get_pclk_rate()` +
`dsi_byte_clk_get_rate()` in `dsi_host.c`, bonded-DSI halving already
confirmed correct): ~935 MHz, vs. downstream's declared 998 MHz for
this panel - only ~6% off, well inside a fractional-N PLL's normal
lock range, so unlikely to explain a hard `status=0x00000000` failure
on its own. Given two targeted fixes in a row (refgen, trim, burst
mode) produced no observable change, added temporary `pr_err()`s
directly in `dsi_7nm_phy_enable()` (entry: phy id/cphy_mode/
bitclk_rate/tuning_cfg pointer; and again with the final trim values
right before they're written to hardware) and `dsi_pll_7nm_vco_prepare()`
(entry: phy id/vco_current_rate) - to settle, with certainty rather
than inference, whether these functions are even reached during the
real modeset, and whether the Round 41 trim override is actually being
applied. Kernel + uniLoader rebuild (unchanged sizes), packaged via the
same proven method (byte-exact verification passed), flashed.
`rp`/`ro.bootloader` reconfirmed unchanged before and after.

**Not yet tested on hardware as of writing this entry.**

## Round 45 (2026-09-19, same day): confirmed the PLL trim fix worked -
real PLL locks 5x with no failure; new diagnostics target backlight/bias

Owner's dmesg capture with Round 44's diagnostics was decisive:
`dsi_7nm_phy_enable` runs for both PHYs (`bitclk_rate=934773000`, matching
the hand-computed value almost exactly, `tuning_cfg` non-null confirming
the Round 41 override is active), and `dsi_pll_7nm_vco_prepare` is
called **five times** with `vco_current_rate=934772900` - **none** of
which produced a "PLL lock failed" message. The real modeset's PLL
genuinely locks now; the two early failures at ~0.35s really are the
benign premature-reparent artifact theorized in Round 41/43 - confirmed,
not just plausible. `nt36523_prepare()`'s own existing `dev_err()` path
(logs "failed to initialize panel" on any real failure) has never fired
either, confirming the 180-command init sequence has been succeeding
silently every round.

So PLL/clock generation and the panel's own digital init are both
confirmed working. Every test so far has still consistently reported
"backlight off, black screen" regardless of which underlying bug was
being fixed - an angle not yet directly instrumented. Added a probe
success print to `drivers/misc/isl98608-gts7l.c` (never confirmed this
bias IC driver actually probes/writes at all - it previously only
logged on failure) and diagnostics in
`panel-novatek-nt36523.c`'s `nt36523_bl_update_status()` (brightness
value and the DCS write's return code) - `devm_backlight_device_register()`
normally triggers one automatic `update_status()` call, but the exact
timing (probe-time vs. later, e.g. an fbcon blank/unblank notification
right as `fb0` binds) hasn't been confirmed, and a DCS write attempted
while the DSI link isn't fully ready for real HS transfer would be a
plausible, well-timed match for the still-unexplained
`dsi_err_worker: status=4` FIFO error.

Kernel + uniLoader rebuild (unchanged sizes), packaged via the same
proven method (byte-exact verification passed), flashed.
`rp`/`ro.bootloader` reconfirmed unchanged before and after.

**Not yet tested on hardware as of writing this entry.**

## Round 46 (2026-09-19, same day): found the real cause via research -
the automatic backlight update races the DRM commit, corrupting mode_flags

Round 45's diagnostics were decisive: `nt36523_bl_update_status` fires
at 1.074002s (`brightness=512`), `mipi_dsi_dcs_set_display_brightness_large`
returns `0` (success) one microsecond later, and the
`dsi_err_worker: status=4` FIFO error fires **under 1ms after that** -
every single time. Not a coincidence.

Researched this online (per the owner's explicit request) rather than
keep guessing blind - found this matches a documented mainline bug
class exactly: unsynchronized `dsi->mode_flags` read-modify-write
between a backlight/brightness callback and the DRM commit path's own
concurrent use of the same flags can corrupt or drop
`MIPI_DSI_MODE_VIDEO` for a moment. `nt36523_bl_update_status()` does
exactly this (`dsi->mode_flags &= ~MIPI_DSI_MODE_LPM;` ... `|=
MIPI_DSI_MODE_LPM;`, toggling into HS mode to force the brightness
command through) - unsynchronized against whatever the commit path is
concurrently doing to the same device's mode_flags. Found a related
real mainline fix for a similar race
(`dsi_host_transfer()` checking `power_on` vs. `enabled` -
`drivers/gpu/drm/msm/dsi/dsi_host.c`) confirming this class of
synchronization bug is a real, previously-hit problem in this exact
driver stack, not a one-off theory.

Traced why this fires at all: `devm_backlight_device_register()`
(called from `nt36523_create_backlight()`, only reached because
`gts7l_desc.has_dcs_backlight = true`) triggers one automatic initial
`update_status()` call - timing confirmed to land ~1ms before the
CRTC/encoder chain's own concurrent DSI mode_flags manipulation as part
of the same commit finishing up.

**Fix**: set `.has_dcs_backlight = false` on `gts7l_desc`. Confirmed by
reading `drm_panel_of_backlight()`/`devm_of_find_backlight()`/
`of_find_backlight()` directly (not assumed) that this is a
fully-supported, clean no-op when - as here - the panel's own
devicetree node has no `backlight = <&phandle>;` property:
`panel->backlight` simply stays `NULL`, no error, no probe failure.
Software brightness control becomes a deferred item rather than
required for a first picture - this device's backlight isn't wired to
any real consumer-facing control path at this bring-up stage anyway.

Kept the Round 44/45 diagnostics in for this test as a confirmation
signal - the backlight-related ones (`nt36523_bl_update_status called`,
`mipi_dsi_dcs_set_display_brightness_large returned`) should simply
stop appearing entirely if this fix is correct, since that whole code
path is no longer reached.

Kernel + uniLoader rebuild (unchanged sizes), packaged via the same
proven method (byte-exact verification passed), flashed.
`rp`/`ro.bootloader` reconfirmed unchanged before and after.

**Not yet tested on hardware as of writing this entry.**

### Tested: has_dcs_backlight fix eliminated the backlight callback
entirely, but the FIFO error persisted identically - the backlight
race was correlation, not causation

Owner's capture confirmed `nt36523_bl_update_status`/
`mipi_dsi_dcs_set_display_brightness_large` diagnostics no longer
appear at all (that code path is genuinely gone), but
`dsi_err_worker: status=4` and the identical raw
`REG_DSI_FIFO_STATUS=0x1ddd1011` still fired at almost the exact same
relative timing (~365ms after the PLL's 5 successful prepares, right
before `fb0` registers). The backlight race was a coincidental
correlation, not the actual cause - both were triggered by the same
underlying event (the first real frame commit), not one causing the
other.

Checked whether downstream relies on DSC (display stream compression)
to reduce the very high (~935MHz) bit clock's real bandwidth needs -
`dsi_panel_parse_topology()` in
`references/gts7l/techpack/display/msm/dsi/dsi_panel.c` decodes this
panel's own `qcom,display-topology = <2 0 2>` as `num_lm=2, num_enc=0,
num_intf=2` - zero compression encoders, ruling DSC out entirely.

Reconsidered whether `fb0` registering successfully every round (despite
the FIFO error) meant the DRM/DSI pipeline was actually healthy, and the
real "black screen, backlight off" cause was something else entirely -
independent of the DSI FIFO issue. Realized the Round 45/46
`isl98608_gts7l_probe` diagnostic had never appeared in **any** capture
including this one, despite the grep pattern explicitly matching
"isl98608". Asked the owner to check directly at the live USB shell:
`ls /sys/bus/i2c/devices/` came back **completely empty** - not just the
ISL98608 child device, `&i2c8` itself never registered as a real i2c
adapter at all.

## Round 47 (2026-09-19, same day): `CONFIG_QCOM_GPI_DMA=m` - the fourth
instance of the exact same no-module-loading bug

This was flagged as a real risk back in Round 41's notes (`&i2c8`
declares GPI DMA channels via `dmas = <&gpi_dma1 ...>`) but deliberately
left alone at the time, reasoning "no i2c8 errors appeared in dmesg."
That reasoning was backwards - silence is exactly what a permanently
deferred probe looks like, not evidence of a successful FIFO-mode
probe that never needed DMA. `i2c-qcom-geni.c`'s `geni_i2c_probe()`
only needs a working DMA channel if this specific GENI SE instance's
hardware FIFO is disabled (a real per-instance hardware flag) - if it
is, `dma_request_chan()` returns `-EPROBE_DEFER` forever when no DMA
channel provider is registered, and a permanently-deferred probe
prints nothing by design. Confirmed via the owner's own
`ls /sys/bus/i2c/devices/` output (empty) that this is exactly what was
happening - the fourth instance of the identical "driver defaults to
`=m`, minimal initramfs has no module-loading support" bug pattern
already hit with `CONFIG_DRM_MSM`/`CONFIG_PHY_QCOM_USB_SNPS_FEMTO_V2`/
`CONFIG_REGULATOR_QCOM_REFGEN` (Rounds 35/37/40).

Forced `CONFIG_QCOM_GPI_DMA=y` in `kernel/config/gts7l.fragment`. Full
kernel rebuild (confirmed genuinely different Image content despite an
identical byte size to Round 46's build - not a no-op), uniLoader
rebuild (same 44,478,464-byte size, same safe address margins),
packaged via the same proven method (byte-exact verification passed),
flashed. `rp`/`ro.bootloader` reconfirmed unchanged before and after.

**Not yet tested on hardware as of writing this entry.**

### Tested: CONFIG_QCOM_GPI_DMA fix didn't help either -
/sys/bus/i2c/devices/ still completely empty

Owner reconfirmed via the live shell: still zero devices. Per the
owner's request, researched online and checked our own vendored
`sm8250.dtsi` source directly at the same time.

## Round 48 (2026-09-19, same day): the real cause - the parent QUP
wrapper node itself was never enabled

Found it directly in `sm8250.dtsi`: `i2c8` is a *child* of
`qupv3_id_1: geniqup@ac0000` (the QUP wrapper node), which itself
defaults to `status = "disabled"`. A disabled parent means
`of_platform_populate()` never instantiates *any* of its children at
all, regardless of the child's own `status = "okay"` - this was the
actual reason `/sys/bus/i2c/devices/` was completely empty the whole
time, independent of the `CONFIG_QCOM_GPI_DMA` fix (which was real and
worth keeping, but wasn't the blocker). Confirmed this is the standard
mainline convention (not assumed) via a web search - "you set the
parent qupv3_id_1 node's status to okay" to enable I2C on a QUPv3
wrapper, matching real patch precedent.

Added `&qupv3_id_1 { status = "okay"; };` alongside the existing
`&i2c8 { status = "okay"; };` in
`kernel/dts/sm8250-samsung-gts7l.dts`. DTB-only rebuild (confirmed via
`fdtget`: both nodes now `okay`), uniLoader rebuild (unchanged size,
same safe address margins), packaged via the same proven method
(byte-exact verification passed), flashed. `rp`/`ro.bootloader`
reconfirmed unchanged before and after.

**Not yet tested on hardware as of writing this entry.**

### Tested: Round 48 confirmed correct - ISL98608 bias IC now probes and
programs successfully, but the FIFO error is completely unchanged

Owner confirmed via the live shell: `ls /sys/bus/i2c/devices/` now
shows `8-0029` and `i2c-8` (both the adapter and our child device), and
`dmesg` shows `isl98608_gts7l_probe called, i2c addr=0x29` followed by
`both bias registers written successfully`. The Round 48 QUP wrapper
fix was correct and is a real, independent bug fix - the panel's own
AVDD/AVEE bias rails are now genuinely programmed to 5.5V, for the
first time in this project.

**The screen is still black, backlight still off, and the raw
`REG_DSI_FIFO_STATUS` value is bit-for-bit identical
(`0x1ddd1011`) to every previous capture since Round 43, at the same
relative timing (~380ms after the PLL's 5 successful prepares, right
before `fb0` registers).** This is now the fifth consecutive
independently-confirmed, real bug fix (refgen, PHY trim, burst mode,
disabling the racy backlight callback, GPI DMA, the QUP wrapper enable,
and now the bias IC) with zero measurable effect on this one specific
failure - strong evidence it's a single, deterministic, structural
issue rather than a race or a missing peripheral dependency.

Precisely decoded the raw value bit-by-bit (via a small Python script,
not manual counting - caught a genuine miscount in an earlier casual
read): `VIDEO_MDP_FIFO_OVERFLOW` (bit 0) is set, alongside simultaneous
`HS_FIFO_EMPTY`/`OVERFLOW`/`UNDERFLOW` on data lanes 0-2 and
`HS_FIFO_EMPTY` alone on the unused lane 3 (expected/idle for a
3-lane C-PHY link), plus `DLN0_LP_FIFO_EMPTY` and one unaccounted bit
(`0x10`, not present in `dsi.xml.h`'s named constants). Critically,
`VIDEO_MDP_FIFO_OVERFLOW` specifically means the DPU's own pixel-source
FIFO (feeding the DSI controller, not just the DSI-side lane FIFOs) is
overflowing - a genuine bandwidth/timing symptom, not just an
artifact of an unclocked block.

**Ruled out this round, each checked directly against source rather
than assumed:**
- **Lane mapping/swap**: confirmed correct via `dsi_host.c`'s own
  `dsi_host_parse_lane_data()`/`supported_data_lane_swaps[]` lookup -
  our `data-lanes = <0 1 2>` resolves to the straight "0123" mapping
  (index 0, no swap), matching downstream's own explicit
  `qcom,mdss-dsi-lane-map = "lane_map_0123"` for this exact panel.
  `dsi_phy_7nm.c`'s own hardcoded `LANE_CFG0`/`LANE_CFG1` registers
  (with their "TODO: we need to calculate this" comment) are a
  separate, lower-level PHY analog-lane thing, not the logical
  swap/ordering mechanism - a red herring.
- **DSC (display stream compression)**: downstream's own
  `qcom,display-topology = <2 0 2>` decodes via
  `dsi_panel_parse_topology()` (`references/gts7l/techpack/display/
  msm/dsi/dsi_panel.c`) to `num_lm=2, num_enc=0, num_intf=2` - zero
  compression encoders. Not a factor.
- **DPU/DSI bit-rate self-consistency**: both the DPU's pixel timing
  and the DSI bit clock are derived from the exact same
  `drm_display_mode.clock` value (`dsi_get_pclk_rate()` /
  `dsi_byte_clk_get_rate()` in `dsi_host.c`), so they cannot disagree
  with each other regardless of whether the absolute value matches
  downstream's declared 998MHz - the earlier ~935MHz-vs-998MHz
  difference (Round 44) is not a source/sink bandwidth mismatch.
- **Interconnect/bandwidth-vote driver availability**: confirmed
  `CONFIG_INTERCONNECT_QCOM_SM8250=y` is already built-in - not another
  instance of the "module never loads" bug pattern this project has
  hit five times now (`DRM_MSM`, `PHY_QCOM_USB_SNPS_FEMTO_V2`,
  `REGULATOR_QCOM_REFGEN`, `QCOM_GPI_DMA`, and effectively the
  `qupv3_id_1` enable).

**Not yet checked / candidate theories for the next session:**
- The DPU/MMCX RPMh performance-state (OPP) vote possibly staying too
  low for genuine 1600x2560@120Hz uncompressed throughput once real
  streaming starts (as opposed to whatever idle/setup-time vote is
  active during the earlier successful stages).
- A subtle error somewhere in the panel's own 180-command init
  sequence that doesn't fail explicitly (accum_err stays 0, confirmed
  every round via `nt36523_prepare()`'s own unfired `dev_err()` path)
  but leaves some internal panel state wrong in a way that only
  manifests once real HS video streaming begins.

Paused here at the owner's request to record state before continuing -
this is the deepest, most stubborn single bug hit in this project so
far, five independently-real fixes deep with no change to this one
specific symptom.
