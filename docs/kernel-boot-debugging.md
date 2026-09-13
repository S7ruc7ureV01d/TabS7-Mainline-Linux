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
  DTS's current (stock-matching) wildcard convention. **Bigger finding**:
  stock's own real compiled DTB also lacks `qcom,pmic-id`, meaning stock
  itself can't be satisfying this same exact-match path either - it likely
  reaches Linux via a different boot-chain mechanism entirely, which calls
  into question whether this exact-match path is even the right thing to
  keep chasing. Real verbose ABL logging would resolve this decisively but
  needs raw `uefivarstore` partition writes (EDK2 variable-store format) -
  not attempted, a real side-project of its own.

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
