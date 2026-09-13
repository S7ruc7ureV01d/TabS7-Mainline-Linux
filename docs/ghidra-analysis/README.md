# ABL `LinuxLoader` decompilation - "Board Dtb" investigation (2026-09-13, Round 9)

Ghidra decompilation of the exact functions responsible for
`No match found for Soc Dtb type` and `Unable to find the Board Dtb` /
`Error: Board Dtbo blob not found`, produced while chasing the "Board Dtb"
blocker documented in `../kernel-boot-debugging.md` Round 9. Saved here because
this took substantial effort to produce and is directly reusable for any future
question about this exact ABL binary - don't redo this work from scratch.

## How this was produced

Ghidra installed via `pacman -S ghidra` (Arch `extra` repo), used **headless**
(`analyzeHeadless`) since there's no GUI in this environment - a plain `.py`
postScript needs the separate PyGhidra Python bridge (`pip install pyghidra` +
jpype, not set up here), so all scripts are compiled Java `GhidraScript`
subclasses instead, which work with the default headless setup:

- `../../tools/FindBoardDtbCallers.java` - given an RVA, finds every real
  reference *to* it (calls, data/vtable references) via Ghidra's actual
  cross-reference database - this is what plain `capstone` disassembly
  (Round 8's method) fundamentally cannot do for indirect/computed calls.
- `../../tools/FunctionBounds.java` - prints a function's real address range
  and whether a given address is contained in it - use this to sanity-check
  function-boundary assumptions before trusting anything else (a naive
  "looks like a prologue" heuristic from Round 8 turned out wrong this round -
  see "A real correction" below).
- `../../tools/DecompileFunction.java` - decompiles one or more functions
  (given by RVA) to readable C-like pseudocode. Far more useful than raw
  disassembly for anything beyond a few instructions.
- `../../tools/FindDataWriters.java` - given a data RVA, finds every reference
  to it and decompiles each containing function - use this to trace where a
  global flag/variable actually gets set.

Reusable command pattern (import once, then reprocess without re-importing):

```sh
mkdir -p /tmp/ghidra_project
cp <LinuxLoader.pe path> /tmp/ghidra_project/LinuxLoader.pe
/opt/ghidra/support/analyzeHeadless /tmp/ghidra_project ablproj \
    -import /tmp/ghidra_project/LinuxLoader.pe -overwrite   # first time only

/opt/ghidra/support/analyzeHeadless /tmp/ghidra_project ablproj \
    -process LinuxLoader.pe -noanalysis \
    -postScript DecompileFunction.java 0x<rva> \
    -scriptPath <repo>/tools
```

`-noanalysis` skips re-running auto-analysis on subsequent invocations (it
already ran once at import time and is cached in the project) - much faster.

The `LinuxLoader.pe` module itself is extracted from the device's `abl`
partition (a UEFI Firmware Volume) - see `../kernel-boot-debugging.md` Round 8
for how (`pip install uefi_firmware`, `uefi-firmware-parser -b -e`). Not
committed here (large, device-specific binary) - re-extract from a fresh
`adb pull` of `/dev/block/bootdevice/by-name/abl` if needed again.

## A real correction from Round 8: function boundaries aren't always what they look like

Round 8's disassembly (plain `capstone`, no real function-boundary analysis)
assumed a `bl #0x1e34c; sub sp,sp,#0xe0` pattern always marks a function start,
and treated address `0x25700` and (wrongly) `0x26744` as separate functions on
that basis. Ghidra's real analysis (which does proper stack/control-flow
tracking, not just pattern-matching) showed `0x26744` is actually the *tail end*
of a **different** function (`FUN_000263c8`, ending at `0x26747`) reached via an
internal conditional jump - not a separate callable function at all. The actual
function containing the "No match" / "Board Dtb" strings we wanted turned out to
be at different addresses entirely (`0x25490` and `0x26748` respectively).
**Lesson: verify function boundaries with real tooling before trusting a
manually-guessed one, especially before spending effort tracing "callers" that
don't exist.**

## The full call chain and decision logic (all confirmed via decompilation, not guessed)

```
BootLinux() [FUN_00020590, the top-level boot function]
  -> FUN_00025490(kernel_end_addr, ...)   "the base-DTB matcher"
       - loops over the appended-DTB blob's entries (the 3 kona-stepping FDTs
         directly after the kernel Image in `boot` - this is what Round 8's
         qcom,board-id fix addressed)
       - for each entry, calls FUN_00025700(...) (see below) to check
         qcom,msm-id / qcom,board-id / qcom,pmic-id against live hardware
       - prints "No match found for Soc Dtb type" if NO entry is even
         minimally acceptable (this is what Round 8/9 fixed)
       - CRITICALLY: if an entry's match-quality flags satisfy the mask
         0x34150000 exactly (see below), also sets a global "exact match"
         flag (DAT_00255278 = 1) and prints "Exact DTB match found. DTBO
         search is not required"
  -> FUN_00023f20()   returns `~DAT_00255278 & 1` - i.e. TRUE unless the
     "exact match" flag above got set
  -> if TRUE (not an exact match - our current situation):
       FUN_00026748(dtb_ptr, dtbo_buffer)   "the strict per-region DTBO matcher"
         - parses dtbo_buffer as a dt_table_header, loops its entries
         - calls the SAME FUN_00025700(...) matcher per dtbo entry
         - prints "Unable to find the Board Dtb" if no entry ever sets a
           per-loop match-tracking variable (local_a0) nonzero - THIS is our
           actual, current blocker
  -> if FALSE (exact match achieved) AND a separate flag (FUN_00034ea0(),
     byte at file offset 0x260119) is FALSE:
       FUN_000263c8(&out_ptr)   "Override DTB" - looks for an EFI file/
         partition literally named `L"user_dtbo"`. Doesn't exist on this
         device (or presumably any retail unit) - always fails harmlessly,
         printing "Error: Board Dtbo blob not found" (yes, misleadingly, the
         SAME string family - but from a completely different, optional,
         debug-only mechanism, not the strict DTBO search)
```

## The "exact match" bit mask, decoded

`FUN_00025700` (the shared matcher, called both for base-DTB entries and DTBO
entries) writes match-quality bits into a caller-provided output word. Bits
confirmed from the decompiled source (`FUN_00025700.c` in this directory):

| bit | value | condition |
|-----|-------|-----------|
| 29 | `0x20000000` | `qcom,msm-id` first word (chip/SoC ID, lower 16 bits) exact match |
| 28 | `0x10000000` | `qcom,board-id` first cell exact match |
| 26 | `0x04000000` | `qcom,board-id` subtype-id (derived from board-id's second cell, or a byte within the first if the second is zero) exact match |
| 20 | `0x00100000` | not fully traced - likely a second `qcom,pmic-id` array slot's match bit (see the per-slot bit-numbering pattern in the pmic loop, `uVar17`/`lVar15` in `FUN_00025700.c`) |
| 18 | `0x00040000` | `qcom,pmic-id` first cell (slot 0) model byte exact match against live hardware (`FUN_0001f1c0(0)`) |
| 16 | `0x00010000` | `qcom,msm-id` first word's foundry byte (bits 16-23) exact match - **not achievable with foundry=0**, since zero is treated as a wildcard (sets bit 15 instead, not bit 16) |

The check is `(~flags) & 0x34150000 == 0`, i.e. **all six bits must be set
simultaneously**. Bit 16 in particular means this DTS's current
`qcom,msm-id = <0x164 0x10000>;` (foundry byte implicitly 0, a deliberate
wildcard choice, matching stock's own kona.dtsi) **can never satisfy this exact-
match requirement as currently written** - achieving bit 16 would need a real,
non-zero, correct foundry value in the upper byte of the msm-id first cell,
which isn't known and isn't in any reference source found so far either.

## Open, unresolved puzzle: stock's own DTB doesn't have `qcom,pmic-id` either

Checked directly: `work/stock_dtb_entry{0,1,2}.dtb` (stock's real, compiled,
flashed appended-DTB, extracted from stock's own `boot.img` earlier this
project) have **no `qcom,pmic-id` property at all**. Since bit 18 requires it,
stock's own boot can't be satisfying this exact-match mask either - meaning
stock almost certainly reaches Linux via a genuinely different mechanism than
what our magiskboot-repacked `boot.img` triggers on this same ABL. This project
has been assuming "make our custom appended-DTB look enough like stock's" is
the right general strategy, and that assumption may need revisiting - not yet
understood which of stock's boot chain differences (real AVB signing chain?
`vendor_boot`/`recovery_dtbo` partition usage? something in `vbmeta`?) causes
it to route differently. Worth investigating before spending more effort on
DTB/DTBO content tuning for this exact-match path.

## Where to go from here

1. **Real verbose ABL logging would resolve this decisively but is blocked.**
   `FUN_0004c908` (the log-level gate) reads a standard EDK2 UEFI variable
   named `"EFIDebug"` - the normal, documented way to control DEBUG() print
   verbosity in Tianocore-based firmware. This Android kernel doesn't expose
   `efivarfs` (`/sys/firmware/efi/efivars` doesn't exist), so it can't be set
   from userspace the normal way. The device does have a `uefivarstore`
   partition (confirmed present in the PIT, per Round 7's `mkdtboimg`/PIT
   work) that very likely holds the raw UEFI variable store Samsung's own ABL
   reads - writing to it directly would require reverse-engineering EDK2's
   variable-store binary format (headers, GUIDs, attributes, typically a CRC
   or hash) - a real side-project, but would unlock detailed diagnostics
   (including the literal "PMIC Model 0x%x: 0x%x" values) for this and every
   future debugging round, not just this one question.
2. **A candidate `qcom,pmic-id` value was tried and tested on real hardware -
   it didn't work.** `<0x1e 0x00 0x00 0x00>` (`0x1e` from the live kernel's
   `/sys/devices/soc0/pmic_model` = 65566 = `0x1001E`, low byte taken as the
   candidate "model" register value) produced the identical failure. Either
   the encoding guess is wrong, or - per the puzzle above - this isn't even
   the right thing to chase.
3. **Investigate why stock doesn't need this exact-match path at all** -
   likely more productive than continuing to guess at pmic-id/foundry values.
   Worth comparing stock's real, unmodified `boot.img` structure (header
   fields, AVB footer, whether the DTB is *really* appended the same way ours
   is or delivered differently) against what magiskboot produces for our
   custom kernel.
