# Phase 4 scoping: S Pen (Wacom W90xx-series EMR digitizer)

Recon pass before starting real S Pen bring-up, done 2026-09-21 per the
owner's request to scope it before committing to implementation. Goal:
find out whether mainline already has enough of a working driver for
this exact chip family that this is a bounded, moderate task, or
whether it needs a from-scratch port. Nothing here has been built or
tested yet - pure research, same methodology as the other Phase 2/3
scoping docs (real sources cited, nothing assumed).

## RESOLVED (2026-09-22): the S Pen works - four stacked bugs

Confirmed by the owner on real hardware: hover, contact, pressure and
the side button all work in KDE. The rest of this doc is the history.
Several of its conclusions (the "brownout" root cause, "every
software-visible detail matches stock") were wrong, as corrected
below.

The digitizer was failing four separate ways at once. Each one hid the
next, which is why the six earlier hypotheses (timing, flash-mode
polarity x2, forced/conditional power cycle, RPMh HPM) all showed
identical `-ENXIO`: none of them was tested with the chip actually
powered.

1. **AVDD never had a voltage vote (the -ENXIO).** mainline's
   `pmic5_pldo` table is 1.504V + n x 8mV, so **3.3V isn't
   representable**: the nearest steps are 3.296V and 3.304V.
   Downstream sends raw millivolts to RPMh and never hits this. Our
   original `min = max = 3300000` made `set_machine_constraints()` fail
   its apply_uV step. Regulator registration failed, and the whole
   pm8150 rpmh-regulator probe went down with it, display and USB
   supplies included. That was the 2026-09-21 "brownout", not an
   electrical fault and not a spurious vote. (The claim below that
   `voltage_selector` "defaults to 0" is also wrong: it starts at
   `-ENOTRECOVERABLE`, `qcom-rpmh-regulator.c:494`.) The "fix" of
   dropping the constraints left the rail with no voltage vote at all,
   so the chip sat underpowered and NACKed every query.
   **Fix:** `pm8150_l13` min = max = **3296000**. Confirmed at probe
   ("Setting 3296000-3296000uV"), no brownout, and the chip's first
   query returned X23585 x Y14741, exactly what stock reads.
2. **IRQ polarity.** Downstream requests the pen IRQ as
   `IRQF_TRIGGER_LOW`; the line idles high. Our DTS had
   `IRQ_TYPE_LEVEL_HIGH`. **Fix:** `IRQ_TYPE_LEVEL_LOW`.
3. **libinput ignored the device** ("missing tablet capabilities:
   resolution. Ignoring this device"). Because KWin never opened it, the
   driver never powered the chip. **Fix:** `touchscreen-x-mm = <237>`,
   `touchscreen-y-mm = <148>` (the 11" 16:10 panel, about 100
   units/mm), which the driver already turns into axis resolution.
4. **Coordinate packets were misparsed.** Every report was dropped with
   "Pressure out of range 32768". The W9021 puts a packet type in byte
   0's low nibble (only type 1 is coordinates) and uses 12-bit pressure
   (`(data[5] & 0x0f) << 8 | data[6]`); byte 5's upper nibble is flags.
   **Fix:** `kernel/patches/0016-wacom-w9000-w9021-packet-id-and-12bit-pressure.patch`
   (opt-in per variant, gts7l only).

Also set: `touchscreen-inverted-x` + `touchscreen-swapped-x-y`, from
downstream's `wacom,invert = <1 0 1>`. `wacom_i2c_coord_modify()`
inverts raw X and then swaps, the same order mainline applies these
properties. Tilt isn't transformed by mainline, so tilt direction is
unverified. The chip needs no start command: it reports as soon as it
is powered and opened. The i2c17 bus runs at 100 kHz here versus 400
kHz on stock; that works fine, so it was left alone.

**Lesson for any RPMh LDO on this SoC:** check that every
`regulator-*-microvolt` value is an exact step of the driver's linear
range. A non-representable fixed voltage doesn't just get rounded - it
fails the whole regulator block.

## The headline finding: mainline has the right driver family, missing one variant and tilt support

**This is not a from-scratch port.** `work/linux/drivers/input/
touchscreen/wacom_w9000.c` already exists upstream (Copyright 2026,
Hendrik Noack) and implements the exact I2C protocol family our
hardware uses - confirmed by direct byte-for-byte comparison against
downstream's own driver, not assumed:

| Field | Downstream (`references/gts7l/drivers/input/wacom/wacom_i2c.c`) | Mainline (`wacom_w9000.c`) |
|---|---|---|
| Query command | `0x2a`, header check `data[0] == 0x0f` | Identical (`CMD_QUERY = 0x2a`, same header check) |
| `max_x` | `EPEN_REG_X1`/`X2` = query bytes 1-2 | `get_unaligned_be16(&data[1])` - same offset |
| `max_y` | `EPEN_REG_Y1`/`Y2` = query bytes 3-4 | `get_unaligned_be16(&data[3])` - same offset |
| `max_pressure` | `EPEN_REG_PRESSURE1`/`2` = query bytes 5-6 | `get_unaligned_be16(&data[5])` - same offset |
| `fw_version` | `EPEN_REG_FWVER1`/`2` = query bytes 7-8 | `get_unaligned_be16(&data[7])` - same offset |

Every field mainline already parses lines up exactly with downstream's
byte layout. This is the same chip family, same protocol - not a
coincidental match.

## What's actually missing

**1. A variant table entry for our exact chip.** Mainline currently only
knows `wacom,w9002`, `wacom,w9007a-lt03`, `wacom,w9007a-v1`
(`wacom_w9000.c:416-418`). Our hardware's `ic_type = 0x233d`
(`references/gts7l`'s overlay r07, `wacom@56` node, confirmed live on
this exact physical unit per `docs/hardware-inventory.md`) doesn't
match any of those - it needs its own compatible string and a new
`wacom_w9000_variant` struct entry. The struct itself is tiny (just
`cmd_query_num`, `msg_coord_num`, `name` - see `wacom_w9000.c:31-35`),
so adding one is mechanical, not a rewrite.

**2. Longer message buffers.** Downstream's query/coord message lengths
(`references/gts7l/drivers/input/wacom/wacom_dev.h:65,67`:
`COM_COORD_NUM = 16`, `COM_QUERY_NUM = 15`) exceed mainline's current
compile-time maximums (`CMD_QUERY_NUM_MAX = 9`, `MSG_COORD_NUM_MAX =
12`, `wacom_w9000.c:22,26`) - because our chip's response format has
several extra trailing fields (module/bootloader version, tilt, height,
format revision) that the shorter w9002/w9007a variants don't carry.
Bumping these two `#define`s is a one-line-each change; the rest of the
driver already sizes its stack buffers off them.

**3. Tilt reporting doesn't exist in mainline yet.** This is the one
real gap, and it's exactly what the roadmap's exit criterion asks for
("S Pen hover/pressure/tilt input"). Downstream reads tilt from
`EPEN_REG_TILT_X`/`TILT_Y` = query bytes 0x0B/0x0C (max range, at query
time) and from coordinate-report bytes 8-9, as **signed** values
(`(s8)data[8]`, `references/gts7l/.../wacom_i2c.c:1239-1240`), then
calls `input_set_abs_params(ABS_TILT_X, -max, max, 0, 0)` and
`input_report_abs(ABS_TILT_X, tilt_x)` at runtime
(`wacom_i2c.c:1675-1676,1288-1289`). Mainline's `wacom_w9000_query()`
and `wacom_w9000_coord()` don't read or report tilt at all right now -
they stop after `ABS_DISTANCE` (conditionally, only if `msg_coord_num >
7`; `wacom_w9000.c:183-200`). Adding tilt is the same conditional
pattern already used for distance, extended by two more fields - real
code, but small and mechanical, following an existing pattern in the
same function rather than inventing a new one.

**Everything else the mainline driver already handles**, with no
changes needed: power sequencing (regulator + optional reset/flash-mode
GPIOs, both obtained via `devm_gpiod_get_optional` -
`wacom_w9000.c:291,296` - so hardware without a distinct line for one
of these, if that turns out to be the case here, degrades gracefully
rather than failing to probe), proximity/hover detection (`data[0] &
BIT(7)`, already handled), touch/side-button/eraser detection, and the
input-device lifecycle (open/close tied to power on/off).

## Devicetree binding: already documented, real example available

`Documentation/devicetree/bindings/input/touchscreen/
wacom,w9007a-lt03.yaml` is the real, current binding doc (not a draft) -
properties are `compatible`, `reg`, `interrupts`, `vdd-supply`,
`flash-mode-gpios` (optional), `reset-gpios` (optional), plus the
generic `touchscreen.yaml` properties (`touchscreen-x-mm`,
`touchscreen-inverted-x`, etc., which map to downstream's
`wacom,origin`/`wacom,invert`). The doc's own worked example is close
to a template for our node, once the compatible string and the real
GPIO/regulator identities are resolved.

## What's genuinely unresolved and needs real work

- **Real GPIO/regulator identities for this board.** Downstream's node
  (`wacom@56`, overlay r07 line ~10005) references phandles as raw hex
  (`wacom,irq-gpio = <0xffffffff 0x88 0x0>`, `wacom,pdct-gpio = <...
  0x7 0x0>`, `wacom,fwe-gpio = <... 0x6 0x0>`, `pinctrl-0 = <0x96
  0x97>`) and a named regulator (`wacom,regulator_avdd = "wacom_avdd"`)
  that all need resolving against the real overlay/base-dtsi node
  table - the same phandle-archaeology process already done successfully
  for MAX77705's IRQ GPIO (`docs/devicetree-notes.md`, "PM8150L gpio
  11" entry) and documented there as a repeatable pattern, not a new
  risk.
- **`wacom,pdct-gpio` has no mainline equivalent.** PDCT ("pen detect")
  is an auxiliary signal some Wacom digitizers expose for faster/more
  reliable proximity detection alongside the main IRQ. Mainline's driver
  doesn't model it at all. Worth checking whether it's load-bearing for
  correct behavior on this specific chip or genuinely optional (the
  primary IRQ-driven proximity bit already works per the protocol
  comparison above) - if it turns out to matter, that's a second, small
  driver addition, not a blocker.
- **Confirm the exact compatible string / public model name.** `ic_type
  = 0x233d` is Wacom's internal ID as read by the query command, not
  necessarily a public part number - `wacom,w90xx` in the downstream DT
  is a generic placeholder, not a real chip name either. Worth a
  targeted web search (Tab S7's S Pen digitizer is publicly documented
  in repair/teardown contexts) before inventing a compatible string, so
  it matches whatever the upstream maintainer would actually want if
  this gets submitted.
- **Kconfig**: `CONFIG_TOUCHSCREEN_WACOM_W9000` exists
  (`drivers/input/touchscreen/Kconfig:613`) but isn't yet in
  `kernel/config/gts7l.fragment` - needs adding, `=y` per this
  project's established pattern for early-boot/no-module-loading
  reliability.

## Status update (2026-09-21): implemented, structurally confirmed on real hardware, not yet end-to-end working

Everything scoped above was implemented and tested the same day:

- `kernel/patches/0011-wacom-w9000-add-gts7l-variant-and-tilt.patch` -
  the `wacom,w9021-gts7l` variant, the two buffer-size bumps, and tilt
  reporting, all in mainline's `wacom_w9000.c`.
- `kernel/dts/sm8250-samsung-gts7l.dts` - the real device node, on
  `&i2c17` (resolved via the exact same downstream-fixup-table method
  already used for MAX77705's bus: `qupv3_se17_i2c` -> mainline's
  `&i2c17`), with real IRQ (tlmm 136) and flash-mode (tlmm 6) GPIOs
  reusing pinctrl states a previous session had already resolved and
  live-confirmed via `/proc/interrupts`.
- Two real, previously-undocumented-for-this-board gaps found and
  fixed along the way, both following an exact precedent already in
  this file for i2c5/i2c8: `i2c17`'s parent QUP wrapper
  (`qupv3_id_2`/`geniqup@8c0000`) defaults to `status = "disabled"` in
  `sm8250.dtsi` and needed enabling, and `i2c17`'s GENI SE instance has
  no FIFO mode and needs a real GPI DMA channel (`gpi_dma2`) with the
  same kind of `qcom,gpi-ee-offset` TrustZone-execution-environment
  override i2c5 needed - real value (`0x6000`, confirmed different
  from i2c5's `0x1000`) pulled directly from downstream's own
  `kona.dtsi`.

**Confirmed on real hardware:** the digitizer enumerates correctly on
the I2C bus (`ls /sys/bus/i2c/devices/` shows `17-0056`), the driver
binds, and it attempts its query command the documented 8 times before
failing cleanly with `-ENXIO` - because the chip has no real power
without its actual `vdd` rail (currently falls back to a dummy
always-on regulator stub, which satisfies the software dependency but
doesn't turn on real hardware). No crashes, no hangs, no effect on any
other subsystem.

**What's left, and it's now a single, well-isolated gap:** the real
S Pen AVDD rail is `pm8150_l13` (PM8150 LDO13), confirmed by name via a
second instance of this node in the GPL source, but no board in
mainline has ever wired PM8150's L13 before, and this project has no
confirmed real voltage for it. Guessing one would be an actual safety
risk (unlike omitting the property, which just fails probe cleanly).
Real next step: find PM8150 LDO13's actual voltage (PM8150 datasheet,
or a differently-sourced downstream tree that defines rather than just
references this rail) and add `regulators-0`'s `l13` node (grouped
under `vdd-l13-l16-l17-supply` per PM8150's binding) plus the
`vdd-supply` property on the wacom node together.

## Real hardware brownout, found and fixed (2026-09-21)

Wiring the AVDD rail was not as simple as finding its real voltage
(3.3V, confirmed by direct live measurement on this exact device via
`/sys/class/regulator/regulator.24` in stock TWRP/Android - `state:
enabled`, `microvolts: 3300000`, `min_microvolts` = `max_microvolts` =
`3300000`, sysfs device path `10-0056-pm8150_l13` independently
confirming it's the right rail since `0056` is the wacom digitizer's
own I2C address). Wiring that measured voltage directly as
`regulator-min-microvolt`/`regulator-max-microvolt` on the new
`pm8150_l13` node caused a **real hardware brownout on every single
boot** - backlight off, USB completely unresponsive, no kernel panic,
nothing in pstore. Confirmed via careful bisection (with the owner's
suggestion to test toggling the live regulator directly, which turned
out to be blocked by the sysfs `state` file being read-only with no
debugfs override available - a real dead end, documented so a future
session doesn't retry it) that the crash happened even with **zero
consumers wired to the regulator at all** - `regulator_enable()` was
never even called. `regulator-boot-on` did not help either, with or
without it.

**Root cause, confirmed by reading mainline source directly** (cross-
checked by two independent research passes that both traced the same
code path):
- `drivers/regulator/of_regulator.c`'s devicetree parsing sets
  `constraints->apply_uV = true` automatically whenever BOTH
  `regulator-min-microvolt` and `regulator-max-microvolt` are present
  - no special "fixed voltage" opt-in needed, and it doesn't matter
  whether they're equal.
- `drivers/regulator/qcom-rpmh-regulator.c`'s
  `rpmh_regulator_vrm_get_voltage_sel()` returns a purely software-
  tracked counter (`vreg->voltage_selector`), never a real hardware
  register read - RPMh is a write-only voting protocol; there's no way
  for the AP to query a rail's real aggregated hardware voltage at
  all. This field defaults to 0 at probe.
- `drivers/regulator/core.c`'s `set_machine_constraints()`, which runs
  at `regulator_register()` time - i.e. at **probe, unconditionally,
  regardless of enable/consumer state**, matching the bisection result
  exactly - sees `apply_uV` is true, computes a "current" voltage from
  that always-zero selector (1.504V on this LDO's real linear range,
  `pmic5_pldo`: `REGULATOR_LINEAR_RANGE(1504000, 0, 255, 8000)`), finds
  it's below our fixed-3.3V constraint, and issues a real, live,
  **uncommanded RPMh SET_VOLTAGE vote** to "correct" a rail that was
  already correct - based entirely on software's own wrong bookkeeping
  about a protocol it fundamentally cannot read back.

**Fix**: omit `regulator-min-microvolt`/`regulator-max-microvolt`
entirely on the `pm8150_l13` node. Neither is actually needed - the
wacom driver only ever calls `regulator_enable()`/
`regulator_disable()`, never `regulator_set_voltage()` - and without
both properties present, `apply_uV` never becomes true, so
`set_machine_constraints()`'s voltage-forcing block never runs at all.
Confirmed on real hardware: boots cleanly, no brownout, the regulator
enables/disables correctly around the driver's probe-time query
attempt. This is a genuinely useful, exportable finding for any future
work adding an LDO (not SMPS) to an already-probed PM8150-family RPMh
regulator block on this or a sibling SoC - the two SMPS rails already
in this file's `regulators-0` block hit the identical code path but
apparently tolerate the spurious nudge; this specific LDO's shared
group (`l13-l16-l17`) evidently does not.

**Current status after the fix**: no brownout, the S Pen still doesn't
respond over I2C (`wacom_w9000 17-0056: error -ENXIO: Failed to
query`, same failure as before this fix, minus the crash). This is now
an ordinary, non-destructive driver problem - safe to iterate on
without needing a hard reset each time.

**Timing tested and ruled out (2026-09-21).** Added a per-variant
`power_on_delay_ms`/`query_retry_delay_ms` to the driver
(`kernel/patches/0011-...patch`) and tried 500ms power-on settle time
(vs the driver's default 200ms) plus real 20ms spacing between the 8
query retries (vs firing all of them back-to-back). Identical `-ENXIO`
result either way, on real hardware. This rules out "the chip just
needs more time to boot" as the explanation.

**Confirmed real GPIO/regulator states via `/sys/kernel/debug/gpio`
and `/sys/class/regulator/`** on the running mainline kernel: `gpio6`
(flash-mode) reads `out low` as expected from the driver's
`GPIOD_OUT_LOW` request; `gpio136` (IRQ) reads `in high` at idle (not
yet meaningful on its own - the IRQ is never enabled during probe,
only later via `open()`, so this doesn't confirm or rule out trigger
polarity). `pm8150_l13`'s sysfs `state`/`microvolts` files are
read-only with no debugfs override available in the recovery kernel -
directly toggling the live regulator to test enable/disable behavior
in isolation (an idea from the owner, worth recording as tried and
blocked, not just skipped) was not possible with the tools available.

**GPIO polarity also tested and ruled out (2026-09-21).** Flipped
`flash-mode-gpios` from `GPIO_ACTIVE_HIGH` to `GPIO_ACTIVE_LOW` - this
physically inverts the driver's requested logical-LOW initial state
(previously physically LOW, now physically HIGH). Identical `-ENXIO`
result on real hardware. Combined with timing already ruled out, the
two most plausible software-side explanations for "chip doesn't ack
its own I2C address at all" are both eliminated. Left the property at
`GPIO_ACTIVE_LOW` rather than reverting - equally unconfirmed either
way absent real evidence, no reason to prefer one over the other.

**Power-cycle sequencing tested and ruled out too (2026-09-21).**
Deep online research (cross-checked directly against Samsung's real
downstream driver source, `references/gts7l/drivers/input/wacom/
wacom_i2c.c`) found a real, concrete difference: downstream's
`wacom_power()`/`wacom_reset_hw()` never trusts a bare
`regulator_enable()` to have produced a real electrical edge - it
explicitly forces `regulator_disable()` -> `msleep(100)` ->
`regulator_enable()` -> `msleep(200)` once, specifically because this
rail can already read back as "enabled" (RPMh aggregate vote, firmware
left it on) without any of *this* driver's own calls ever having
toggled real hardware - confirmed via a `static bool boot_on = true`
that forces the first enable through regardless of
`regulator_is_enabled()`'s answer. Implemented the equivalent in
mainline (`force_power_cycle` variant flag,
`kernel/patches/0011-...patch`) and tested on real hardware: **identical
`-ENXIO` result.** `regulator_disable()`/`regulator_enable()` both
completed with no errors in dmesg. This was a well-sourced, high-
confidence hypothesis and it still didn't work - ruled out.

**What's next, and why it's currently blocked**: three real,
independently well-reasoned hypotheses (power-on timing, FWE GPIO
polarity, power-cycle sequencing matching downstream exactly) have all
been tested on real hardware and cleanly ruled out. Remaining
candidates are more speculative and not safely testable by guessing
further - e.g. whether the chip needs an explicit command sequence to
switch out of a "boot_addr" bootloader-mode listening address
(downstream's overlay records `wacom,boot_addr = <0x9>` as a distinct
alternate address; mainline's driver has no concept of this at all),
what `wacom,support_aop_mode`/`wacom,use_garage`/`wacom,table_swap`
actually configure (undocumented anywhere we could find), or whether a
second, not-yet-identified power rail (a digital I/O supply distinct
from AVDD) exists that downstream powers through a path we haven't
found. Each of these needs either the chip's own real datasheet (not
available - Wacom doesn't publish EMR digitizer specs publicly, and
the two most likely-looking documents found online both returned
HTTP 403) or a live UART capture of whatever the chip itself reports
at power-up, which this project's own prior research
(`docs/uart-debug-research.md`) documents a real method for (CC-line
resistance detection via the MUIC, not the PD-VDM "AnyWay JIG"
mechanism) but never actually built or tested - it needs physical
hardware (a bare USB-C breakout board, a ~619kOhm resistor, a USB-to-
TTL serial adapter) that wasn't available this session. This is the
concrete blocker for making further progress here without guessing.

## Bottom line

This was a bounded, moderate-scope task for the driver/DT wiring
itself, confirmed by actually doing it. It surfaced a real, subtle,
and initially dangerous mainline regulator-core interaction (above)
that took several hard-reset cycles to properly isolate and fix -
worth remembering as a general lesson for this project: a regulator's
*live-measured* voltage is not automatically safe to encode as a DT
voltage *constraint* when the underlying RPMh (or similar write-only)
regulator driver can't read hardware state back. The S Pen itself
still doesn't respond over I2C, but that's now a normal, safe-to-debug
driver problem, not a hardware risk.

## Tested and RULED OUT (2026-09-22): flash-mode-gpios genuinely conditional

The 2026-09-21 "force_power_cycle" test never actually exercised the
real downstream behavior it was meant to replicate - it hardcoded
`force_power_cycle = true` unconditionally, so a `flash_mode_was_high ||
force_power_cycle` check added alongside it was dead code (the second
operand was always true, so the first never mattered). Fixed properly:
`wacom_data->flash_mode_gpio` is now acquired with `GPIOD_ASIS` (no
direction/value change on request) so its hardware-default level can be
read *before* this driver ever touches it, and `force_power_cycle` is
now `false` in the variant table, letting that real hardware read
genuinely decide whether to power-cycle - matching downstream's
`wacom_i2c_probe()` branch exactly instead of a superset of it
(`kernel/patches/0012-wacom-w9000-real-conditional-power-cycle.patch`).

Tested on real hardware: identical `-ENXIO` on every query attempt,
same as every other GPIO/timing/power-cycle variant already ruled out.
This conclusively closes out flash-mode-gpios sequencing as a whole -
every reasonable variant of it (both polarities, forced power-cycle,
and now genuinely-conditional power-cycle) has been tried with
identical failure, while the chip is confirmed to work under stock
Android's exact own sequence (via a real console-ramoops capture,
`wacom_w90xx 0-0056: [sec_input] ... ERROR PACKET!` - real bidirectional
I2C traffic, not just a bare ACK). What's left needs either this chip's
real datasheet or a live UART capture of the I2C bus during a working
stock boot - neither available this session.

## Real stock-Android probe trace captured (2026-09-22)

Booted real stock Android (Magisk root + adb enabled, owner's own
device) specifically to get ground truth. Captured from `t=0` (before
the ring buffer could wrap - a first attempt at uptime 85s+ had already
lost it, see `docs/logs/stock-boot-2026-09-22/02-...txt`) - full log at
`docs/logs/stock-boot-2026-09-22/01-dmesg-full-boot-from-t0-wacom-real-probe-success.txt`,
real probe excerpt at `.../06-wacom-real-probe-trace-excerpt.txt`. The
real, complete, successful sequence:

```
wacom_i2c_probe: start!
failed to read support_garage_open_test -22                    <- benign
boot_addr: 0x9, ... fw_path: epen/w9021_gts7l.bin, ... use garage, boot on
wacom_compulsory_flash_mode : enable(0) fwe(0)                  <- fwe driven LOW
Linked as a consumer to regulator.24
wacom_power: on: avdd:on
wacom_i2c_query: 0th ret of wacom query=31                      <- succeeds, retry 0
fw_ver_ic=0x405B ... ic version is high, do not update fw
init irq 454 / init pdct 455
probe done
```

Cross-checked every piece of this against what our own driver/DTS
already does:

- **`regulator.24` is literally `pm8150_l13`** - confirmed via
  `/sys/class/regulator/regulator.24/name` on the live stock device
  (`docs/logs/stock-boot-2026-09-22/05-pm8150-l13-live-regulator-state.txt`)
  - the exact same regulator this project already wires up.
- The I2C bus is `88c000.i2c` - the exact same QUP instance as our
  `i2c17`.
- `wacom_compulsory_flash_mode: enable(0) fwe(0)` confirms fwe driven
  physically LOW before power-on, exactly matching what
  `kernel/patches/0012-...patch` already does.
- The query succeeds within ~1ms of `avdd:on`, no retry, no power-cycle
  delay of any kind visible in the log - `regulator_boot_on`-style
  behavior (the rail was very likely already live from firmware
  hand-off, not really toggled by this call at all), which our own
  driver's `force_power_cycle=false` path also now matches structurally.

**Follow-up test (2026-09-22, same day): regulator power mode, ruled
out cleanly.** The live stock capture also showed this exact regulator
running in RPMh's High Power Mode (`opmode` sysfs reads "fast"),
matching this device's own downstream devicetree
(`qcom,init-mode = <RPMH_REGULATOR_MODE_HPM>`). Mainline's regulator
core has no equivalent init-mode DT property for this RPMh driver - a
consumer has to request it explicitly. First attempt used the wrong
encoding (`REGULATOR_MODE_NORMAL` = the generic Linux API constant,
`0x2`) for the `regulator-allowed-modes` DT property, which is
silently ignored unless it matches the driver's *own*
`RPMH_REGULATOR_MODE_*` encoding
(`include/dt-bindings/regulator/qcom,rpmh-regulator.h`: `_HPM = 3`) -
found by reading `drivers/regulator/of_regulator.c` directly. Fixed
with the correct encoding plus `regulator-initial-mode` (matching
downstream's approach of setting this at registration, not just
runtime) - confirmed genuinely working this time, not just attempted:
`regulator_set_mode(NORMAL) returned 0, mode now 2` on real hardware.
**The chip still gives identical `-ENXIO` on every query.** This
cleanly rules out regulator power mode as the blocker too - the rail
is now provably running in the exact same mode as the working stock
boot, voltage, GPIO sequencing, and I2C bus config, and it still
doesn't respond.

**Conclusion: every software-visible detail line up exactly with what
this project's driver already does, and it still fails on real
hardware.** This isn't a devicetree or driver-logic gap that more
comparison against the downstream source can find - the actual
differentiator, if there is one, is something electrical/protocol-level
that Linux's own logs on either side don't surface. Real next step
needs either this chip's real datasheet or a live logic-analyzer/UART
capture of the I2C bus itself during a real transaction, on both a
working (stock) and failing (mainline) boot, to compare at the
signal level - not more source reading.

## Sources

- `work/linux/drivers/input/touchscreen/wacom_w9000.c` (mainline driver)
- `work/linux/Documentation/devicetree/bindings/input/touchscreen/wacom,w9007a-lt03.yaml` (binding doc)
- `work/linux/drivers/input/touchscreen/Kconfig:613` (Kconfig symbol)
- `references/gts7l/drivers/input/wacom/wacom_i2c.c` (downstream driver)
- `references/gts7l/drivers/input/wacom/wacom_dev.h` (downstream message-length constants)
- `references/gts7l/drivers/input/wacom/wacom_reg.h` (downstream query-response register offsets)
- `references/gts7l/arch/arm64/boot/dts/samsung/gts7l/kona-sec-gts7l-eur-overlay-r07.dts` (real devicetree node, line ~10005)
- `docs/hardware-inventory.md` (chip identification, confirmed live on real hardware)
- `docs/devicetree-notes.md` (phandle-resolution precedent)
