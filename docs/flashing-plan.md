# Flashing Plan — First Hardware Test on `gts7l`

Recorded: 2026-09-12. This is the plan for the first time anything actually
gets written to the physical tablet. **Nothing has been flashed yet** — this
document is the plan, prep work (backups, packaging, a newly-identified
safety fix), and step-by-step procedure, ready for when the owner chooses to
execute it. Every step below is designed around one non-negotiable
constraint:

## The hard constraint, restated

Per `device-state.md`: this unit must stay on its first-release firmware
(`T875XXU1ATK4`) forever, as a collector's device. The anti-rollback counter
(`ro.boot.rp` / `androidboot.rp`, currently **`1`**) must never advance — it
is an eFuse, burning it is permanent and irreversible, and doing so would
also break the ability to ever Odin-flash back to `T875XXU1ATK4` at all.

**Why this plan doesn't risk that:** RP is enforced by the ABL when
accepting new `abl`/`xbl`/`xbl_config`/`tz`/`keymaster`/modem components -
the actual bootloader chain. This plan **only ever writes to `boot`,
`recovery`, `vbmeta`, and `dtbo`** — application/kernel/devicetree-level
partitions that carry no anti-rollback version assertion of their own. It
does not touch, and will never touch as part of this plan, `abl`, `xbl`,
`xbl_config`, `tz`, `aop`, `hyp`, `cmnlib`, `cmnlib64`, `keymaster`, `modem`,
`param`, `persist`, or `vbmeta_samsung`. If any step below is ever adapted to
touch one of those, stop and re-derive this reasoning first — don't assume
it still holds.

**Verification, not just trust:** `ro.boot.rp` is checked and recorded
before this plan starts (see below) and must be re-checked after every
flash. If it ever changes, stop immediately and do not flash anything
further until that's understood.

## Pre-flight state (recorded before any flash)

Captured 2026-09-12, in `work/stock-backup/pre-flash-state.txt` (not
committed - device-specific, kept local):

```
ro.boot.rp:                     1
ro.bootloader:                  T875XXU1ATK4
ro.build.version.security_patch: 2020-11-01
```

**This is the baseline. After every step below, re-check `ro.boot.rp` and
`ro.bootloader` and confirm they still read exactly this.**

## Safety backups taken (before anything is touched)

Raw `dd` copies of every partition this plan will write to, pulled from the
live device over `adb` with root, in `work/stock-backup/` (gitignored,
device-specific, not committed):

| Partition | Size | SHA-256 |
|---|---|---|
| `boot.img` | 71,303,168 B | `616af1821ac7326321c340be1ede2460e22daa2def7d504cafdea5f9447ecb69` |
| `recovery.img` | 86,888,448 B | `c71dff04acbc93bbd378231cb701c84b7f6775142f10284c8c8ba99440732603` |
| `vbmeta.img` | 65,536 B | `3c84bb3506f994b8e88fbd53121fe35737f53ada66f087aa8ab44f5f7b8553a9` |
| `vbmeta_samsung.img` | 65,536 B | `beb45dd9f66f24a45bfebfb470d20e178c60016db599eb036cb37d163ca7655e` |
| `dtbo.img` | 10,485,760 B | `dcd524c25257bb6fbb90604bab4c8addb376d612c9fb06701d24782e9a1ae2af` |

Also bundled into a single one-shot restore package:
**`artifacts/gts7l-STOCK-RESTORE-T875XXU1ATK4.tar`** — flashing this via
Odin's AP slot puts all five partitions back exactly as they are right now.
**This is the rollback path if anything below goes wrong.**

(`vbmeta_samsung` is backed up for completeness but this plan doesn't modify
it — see the AVB reasoning below for why touching only the top-level
`vbmeta` is expected to be sufficient.)

## New finding this pass: the DTBO overlay problem, and its fix

While preparing this plan, checked how Samsung's boot chain actually applies
devicetree data, via the live `/proc/cmdline`: it carries both
**`androidboot.dtb_idx=0`** and **`androidboot.dtbo_idx=7`** - confirming the
ABL loads a base DTB *and* merges a per-revision DTBO overlay on top of it,
the same mechanism the S9 Ultra reference project had to work around (see
`references/ubuntu-galaxy-tab-s9-ultra/configs/dtbo/gts9uwifi-board00-noop.dts`
for their equivalent fix).

**The problem:** the stock `dtbo` partition's entry 7 is a real Samsung
overlay (~330KB, confirmed via `mkdtboimg dump` against the backed-up
`dtbo.img` - 9 entries total, entry 0 is a 101-byte placeholder, entries 1-8
are substantial per-revision overlays) written to patch *Samsung's
downstream* base devicetree. If our `boot.img` (carrying a *mainline*
`sm8250-samsung-gts7l.dtb`, structurally nothing like Samsung's downstream
tree) boots while the stock `dtbo` partition is still in place, the ABL
would attempt to merge that downstream-shaped overlay onto our
completely different mainline tree - fragment target-paths and phandle
fixups almost certainly won't line up, with an unpredictable result ranging
from "silently skipped" to "corrupted tree." This was not something the
original plan accounted for; caught by actually reading the boot cmdline
rather than assuming a plain kernel+dtb boot.img would be sufcient on its
own.

**The fix:** built a genuinely empty DTBO overlay
(`kernel/dtbo/gts7l-noop.dts` — a `/plugin/;` fragment targeting `/` that
changes nothing) and packaged it with **9 identical entries** via
`mkdtboimg create` (matching the stock partition's entry count, so whichever
index `dtbo_idx` selects resolves to a valid, harmless entry rather than an
out-of-bounds read) into `artifacts/gts7l-noop-dtbo.img`. Flashing this to
`dtbo` alongside our `boot.img` means nothing gets merged onto our mainline
DTB at all - the kernel sees exactly what we embedded in `boot.img`, no more,
no less.

## Packages built, ready to flash

All in `artifacts/` (gitignored - rebuild per `phase1-boot-testing.md` /
`twrp-build-notes.md` / this doc rather than trusting a stale copy; these
are listed here so the plan is self-contained about what each step uses):

| Package | Contents | Purpose |
|---|---|---|
| `gts7l-recovery-vbmeta.tar` | `recovery.img` (our built TWRP) + `vbmeta.img` (AVB disabled) | Step 1: establish a working custom recovery as a fallback environment, before touching `boot` at all |
| `gts7l-kernel-test.tar` | `boot.img` (our mainline kernel + DTB + initramfs) + `dtbo.img` (noop) | Step 2: the actual kernel boot test |
| `gts7l-STOCK-RESTORE-T875XXU1ATK4.tar` | stock `boot`/`recovery`/`vbmeta`/`vbmeta_samsung`/`dtbo` | Rollback, at any point |

## Tooling

- **`odin4`** (a Linux Odin-protocol CLI, already installed) is used instead
  of `heimdall` (not installed) - same USB Download-mode protocol, flashes
  files from a tar via the AP slot (`-a`), matching every community guide's
  "flash the .tar in AP, untick Auto Reboot" instructions from
  `recovery-options.md`.
- **Not yet done, needs the owner** (requires root, unavailable
  interactively in this session): the udev rule `odin4 --help` asks for
  (`/etc/udev/rules.d/51-android.rules`, granting the `04e8` USB vendor ID
  `MODE="0666"`) isn't present yet. Either add that rule and
  `udevadm control --reload-rules`, or run the `odin4` commands below with
  `sudo` interactively.

## Procedure

Stop and re-check `ro.boot.rp` after every numbered step before continuing
to the next.

### 0. Confirm baseline (already done, re-run to double check immediately before starting)

```sh
adb shell "getprop ro.boot.rp; getprop ro.bootloader"
# expect: 1 / T875XXU1ATK4
```

### 1. Enter Download Mode

Physically: power off, then hold **Volume Up + Volume Down**, plug in the
USB cable (or hold Vol Up+Down then Power, per this model's exact
combination - confirm against the device itself since this varies by
Samsung model generation), confirm with Volume Up when prompted.

```sh
odin4 -l   # should list the device path once in Download Mode
```

### 2. Flash Package 1 — recovery + vbmeta (the safe, reversible step)

```sh
odin4 -a artifacts/gts7l-recovery-vbmeta.tar
```

This only touches `recovery` and `vbmeta`. Android's normal boot path
(`boot` partition, untouched) is completely unaffected by this step - if
something is wrong here, a normal reboot into One UI still works.

### 3. Verify TWRP actually boots, before going further

Reboot to recovery (Download mode should offer this, or power off and hold
the recovery-boot combo). Confirm TWRP's UI comes up, touchscreen works
(per `twrp-build-notes.md`, this hasn't been hardware-tested before now).
**This step existing and being checked before Step 4 is the whole point of
doing recovery first** - it gives us a known-working fallback environment
before we touch `boot` at all.

Re-check `ro.boot.rp` (from TWRP's own shell, or reboot to Android normally
first if TWRP doesn't boot and reassess before continuing).

### 4. Flash Package 2 — the actual kernel test

Only proceed here once Step 3 is confirmed. Back into Download Mode:

```sh
odin4 -a artifacts/gts7l-kernel-test.tar
```

This touches `boot` and `dtbo`. This is the step being tested - does the
mainline kernel + our DTS actually boot on real hardware.

### 5. Observe

Reboot normally. Per `phase1-boot-testing.md`, the console/UART path is
unconfirmed for this hardware - what "success" looks like here isn't fully
known yet. Things to check, in order of how likely they are to be
observable:
- Does `adb devices` see anything at all (our initramfs doesn't start
  `adbd`, so probably not - but worth checking in case the kernel panics
  back to a state that does)
- Any physical display output (our DTS doesn't wire up the panel yet per
  `devicetree-notes.md`, so likely nothing here either - not evidence of
  failure on its own)
- Whether the device is still alive/responsive at all vs. hung
- If it hangs or doesn't come back, this is where Step 3's TWRP fallback
  matters: get back into TWRP or Download Mode and move to rollback

### Rollback, at any point

```sh
odin4 -a artifacts/gts7l-STOCK-RESTORE-T875XXU1ATK4.tar
```

Restores `boot`, `recovery`, `vbmeta`, `vbmeta_samsung`, and `dtbo` to
exactly their current (pre-this-plan) state. Re-verify
`ro.boot.rp`/`ro.bootloader` afterward.

## Known unknowns not resolved by this plan

- **Console/UART**, per `phase1-boot-testing.md` - a first boot may produce
  no visible output at all even if it works.
- **The stock recovery's prebuilt kernel/dtbo** (`recovery/PROVENANCE.md`)
  are unaudited third-party binaries - if TWRP itself misbehaves, that's a
  place to look, not necessarily our own fixes.
- **The `mkbootimg`/AOSP-convention embedded-DTB mechanism vs. Samsung's
  `dtb_idx` selection** - this plan addresses the *DTBO* overlay problem, but
  hasn't independently confirmed the ABL reads the boot.img's embedded DTB
  the standard AOSP way at all (vs. some other Samsung-specific path this
  project hasn't identified). If the kernel boots but seems to use a wrong
  or default devicetree, this is the first place to investigate.
- This is a genuinely first attempt - treat any specific outcome (works
  cleanly, partial boot, hang, etc.) as new information to fold back into
  `devicetree-notes.md`/`kernel-config-notes.md`, not a pass/fail verdict on
  the whole project.
