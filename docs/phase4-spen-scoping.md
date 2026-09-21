# Phase 4 scoping: S Pen (Wacom W90xx-series EMR digitizer)

Recon pass before starting real S Pen bring-up, done 2026-09-21 per the
owner's request to scope it before committing to implementation. Goal:
find out whether mainline already has enough of a working driver for
this exact chip family that this is a bounded, moderate task, or
whether it needs a from-scratch port. Nothing here has been built or
tested yet - pure research, same methodology as the other Phase 2/3
scoping docs (real sources cited, nothing assumed).

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

## Bottom line

This is a bounded, moderate-scope task - meaningfully easier than
fingerprint (no kernel driver framework exists at all for that sensor
class) or cameras (ISP complexity), and comparable to the touchscreen/
panel bring-up already completed: real driver extension (~variant
table entry + two `#define` bumps + tilt parsing following an existing
pattern in the same function, likely well under 100 lines total) plus
real DT/GPIO archaeology (same resolved-phandle pattern already used
for MAX77705). Not "just flip a config switch," but not a from-scratch
port either - "moderate, well-precedented, mostly mechanical" is the
honest characterization.

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
