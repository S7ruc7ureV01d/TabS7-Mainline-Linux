# Phase 3 scoping: Battery percentage / fuel gauge (Maxim MAX77705)

Recon pass before starting real fuel-gauge bring-up, done 2026-09-20
right after charging status (`docs/phase3-battery-scoping.md`) got
confirmed working on real hardware. Goal: find out whether battery
percentage is really the from-scratch driver-port task
`phase3-battery-scoping.md` flagged as a real possibility, or whether
prior art already closes most of the gap - **per the owner's explicit
request, this pass specifically searched online for existing work on
this exact problem before assuming a from-scratch port was needed.**
Nothing here has been built or tested yet - this is pure research,
following the same methodology as every other Phase 2/3 scoping doc
(real sources cited, nothing assumed).

## The headline finding: this is already merged in our own kernel tree

**This is not a driver-port task.** `work/linux/drivers/power/supply/
max17042_battery.c` - the kernel source this project already has
checked out (Linux 7.2), already, right now, unconditionally -
contains a real `"maxim,max77705-battery"` compatible-string entry:

```
static const struct of_device_id max17042_dt_match[] __used = {
	...
	{ .compatible = "maxim,max77705-battery",
		.data = (void *) MAXIM_DEVICE_TYPE_MAX17047 },
	...
};
```
(`max17042_battery.c:1358-1359`)

This is real, upstream, already-in-tree code - not something that
needs porting, patching, or waiting on a pending patch series. The
binding doc confirms it too
(`Documentation/devicetree/bindings/power/supply/maxim,max17042.yaml:22`,
`compatible: enum: [... maxim,max77705-battery ...]`).

## Why this exists: real prior art, found online per the owner's request

Web research (LKML/lore.kernel.org archives) found the real history
behind this, confirming it's not a coincidence or a mislabeled
register-compatible chip:

- **Dzmitry Sankouski** (the same author whose MFD + charger drivers
  this project is already using for `pmic@66`/`charger@69`) submitted
  a 7-part "Add support for Maxim Integrated MAX77705 PMIC" series
  (up to at least v17, January 2025) that originally included a
  standalone fuel-gauge driver, but - per that series' own v9
  changelog - was changed to **"use max17042 driver instead of
  separate max77705"** fuel-gauge code. In other words: the driver's
  own author concluded MAX77705's fuel-gauge block is register-level
  compatible with the already-mainlined MAX17042 family (specifically
  matched as `MAXIM_DEVICE_TYPE_MAX17047`, one of several known
  register-layout variants that one shared driver file already
  handles) rather than needing new code.
- **Independent confirmation this exact pattern is sound and
  upstream-accepted**: a *different*, related Maxim companion-PMIC
  fuel gauge - **MAX77759** (used in Google Pixel 6/6 Pro) - went
  through the identical process and is **already fully merged**
  (an 11-patch series, "power: supply: max17042: support Maxim
  MAX77759 fuel gauge", applied by power-supply maintainer Sebastian
  Reichel). `max17042_battery.c` itself now carries real MAX77759
  register-map tables (`max77759_fg_registers[]` etc., lines
  ~1070-1104) sitting right next to the MAX77705 compatible-string
  entry - concrete, visible proof this "extend the shared driver
  with a new compatible string" pattern is the maintainers'
  established, working approach for this whole family of chips, not
  a one-off.

**Conclusion: no online search turned up a separate MAX77705-specific
fuel-gauge driver project (nothing on postmarketOS/LineageOS-mainline
efforts specifically solving this), because none was needed** - the
real solution already lives inside `max17042_battery.c`, merged,
in the exact tree this project builds from.

## Real hardware facts for this board

- **I2C address**: `reg = <0x36>` - the binding doc's own generic
  example uses this exact address for a plain `maxim,max17042`
  device, and it's independently confirmed real for *this specific
  chip* via downstream's own driver:
  `references/gts7l/drivers/mfd/max77705.c:46`,
  `#define I2C_ADDR_FG (0x6C >> 1)` = `0x36` - byte-for-byte the same
  address, not a coincidence. Matches the same "each sub-function is a
  real, separate I2C address on this chip" pattern already confirmed
  twice for `charger@69` (`docs/phase3-battery-scoping.md`).
- **Interrupt**: per the MFD binding's own documented IRQ-source
  mapping (`Documentation/devicetree/bindings/mfd/maxim,max77705.yaml`,
  interrupt-controller description) - "0 - charger, 1 - topsys,
  **2 - fuelgauge**, 3 - usb type-c management block" - so
  `interrupt-parent = <&max77705_pmic>; interrupts = <2>;` on the new
  node, reusing the same MFD-internal interrupt-controller framework
  `charger@69` already uses for its own `interrupts = <0>;`.
- **No `monitored-battery` gotcha this time**: unlike the charger
  driver (`max77705_charger.c`, which bailed its whole probe without
  one - the real bug hit and fixed in the charging-status pass),
  `max17042_battery.c` has **no `power_supply_get_battery_info()`
  call and no `monitored-battery` property at all** (confirmed by
  grepping the whole file) - this driver computes capacity from the
  chip's own internal ModelGauge algorithm directly, not from a
  devicetree-supplied battery model. One less open item than the
  charger had.
- **`shunt-resistor-micro-ohms` is optional**, only needed to enable
  current-sense (`CURRENT_NOW`) reporting - datasheet-recommended
  value is `10000` per the binding doc's own example; not required
  for basic capacity/SOC reporting to work.

## Devicetree shape needed

A single new sibling node under `&i2c0`, alongside the already-working
`pmic@66` and `charger@69`:

```
&i2c0 {
	...
	fuelgauge@36 {
		compatible = "maxim,max77705-battery";
		reg = <0x36>;
		interrupt-parent = <&max77705_pmic>;
		interrupts = <2>;
		shunt-resistor-micro-ohms = <10000>;
	};
};
```

(`max77705_pmic` is the label already given to `pmic@66` during the
charging-status pass, for exactly this kind of reuse.)

## Kernel config

`work/linux/drivers/power/supply/Kconfig:447`, `config
BATTERY_MAX17042` - `tristate "Maxim MAX17042/17047/17050/8997/8966
family Fuel Gauge"`, `depends on I2C` (already `=y`), `select
REGMAP_I2C` (auto-satisfied via `select`, not a plain `depends` -
no tristate-ceiling risk expected, unlike several Wi-Fi/BT symbols
this project had to chase through a dependency chain). Force
`CONFIG_BATTERY_MAX17042=y` in `kernel/config/gts7l.fragment`, same
policy as every other symbol this project has forced given the
standing "no module-loading infrastructure" constraint.

## The `boot` partition size question

Same standing constraint flagged in every Phase 3 scoping doc since
Wi-Fi: the partition is at its confirmed hard ceiling
(71303168 bytes, zero headroom measured on every recent build).
`CONFIG_BATTERY_MAX17042` is a `tristate`, so `max17042_battery.c`
only gets compiled in once actually selected - it isn't part of any
build this session has produced yet. The file itself is a modest
amount of source, and every driver added so far this session
(MAX77705's own MFD + charger included) has fit within the
partition's small page-rounding slack, so this should very likely fit
too - but per this project's own hard-won rule (first written down in
`docs/phase3-battery-scoping.md`, now a standing requirement):
**package and check the exact byte count against 71303168 before
touching the device, every time, no exceptions.**

## Open questions, genuinely unresolved

- Whether `MAXIM_DEVICE_TYPE_MAX17047`'s specific register map (the
  variant mainline maps `maxim,max77705-battery` to) is a *close
  enough* match to this exact chip's real fuel-gauge behavior to give
  accurate percentages, or just "close enough to probe and report
  something" - can't know without testing on real hardware. Given
  this mapping was chosen deliberately by the driver's own original
  author (who had real downstream MAX77705 source to compare against,
  same as this project does), there's real reason for confidence, but
  it's not yet confirmed live.
- Whether the MFD's own `interrupt-controller` framework correctly
  routes IRQ index 2 through to a working virq the fuelgauge node can
  actually request - untested; `charger@69`'s own IRQ index 0 already
  works, so the mechanism itself is proven, just not yet at index 2
  specifically.

## Suggested next step when this work actually starts

Same order every prior bring-up this session used - confirm the
hardware path before worrying about anything else:

1. Add the `fuelgauge@36` node (exact shape above) to
   `kernel/dts/sm8250-samsung-gts7l.dts`.
2. Force `CONFIG_BATTERY_MAX17042=y` in `kernel/config/gts7l.fragment`.
3. Build, **package and check the exact byte count against 71303168
   before touching the device** (now a hard, standing rule, not
   optional).
4. Flash and confirm a real `power_supply` class device appears
   (`/sys/class/power_supply/max17042` or similar - check the actual
   registered name live) with real, plausible
   `POWER_SUPPLY_PROP_CAPACITY` values, the same "confirm the
   hardware path" discipline every prior bring-up used.
5. Confirm `upower`/Plasma's battery applet picks it up automatically
   once a real `Battery`-type `power_supply` device exists (this is
   the missing piece charging-status alone couldn't provide - a
   `line-power`-type device doesn't make Plasma's battery icon
   appear, a `Battery`-type one should).

## Status: battery percentage working on real hardware (2026-09-20)

Implemented the same day this doc was written - the prior art
identified above turned out to be exactly right, with zero surprises
of the kind every other Phase 2/3 bring-up this session hit. The
`fuelgauge@36` node (exact shape above) plus `CONFIG_BATTERY_MAX17042=y`
worked on the **first flash**, no additional patches, no DTS
corrections, no boot-partition overflow (the packaged image was still
exactly 71303168 bytes - fits, still zero headroom, but fits).

**Confirmed on real hardware**: `/sys/class/power_supply/max170xx_battery`
exists (`compatible = "maxim,max77705-battery"` resolved correctly)
with real, plausible, complete telemetry read straight from the
chip's own ModelGauge algorithm - not placeholder/zero values:

```
POWER_SUPPLY_CAPACITY=93
POWER_SUPPLY_VOLTAGE_NOW=4191562
POWER_SUPPLY_CHARGE_FULL_DESIGN=1451000
POWER_SUPPLY_CHARGE_FULL=1359000
POWER_SUPPLY_CYCLE_COUNT=4281
POWER_SUPPLY_TEMP=348
POWER_SUPPLY_TIME_TO_EMPTY_NOW=16903
```

The real cycle count (4281) and visible capacity fade
(`CHARGE_FULL`/`CHARGE_FULL_DESIGN` ≈ 93.7%) are exactly what a real,
used battery reports - strong independent confirmation the
`MAXIM_DEVICE_TYPE_MAX17047` register mapping genuinely matches this
chip's real fuel-gauge block, not just "close enough to probe."

The owner confirmed the battery percentage is now visible directly in
KDE Plasma.

**A real, separate problem found during the same testing session, out
of scope for this doc**: a genuine USB-PD "Superfast" charger's
connection state doesn't stay stable in Plasma (charging icon appears
for ~2-3 seconds then disappears) - not a fuel-gauge or charging-status
bug, but almost certainly the MAX77705's separate USB-C/PD
port-management and MUIC block, which this project has never touched
at all. Scoped separately: `docs/phase3-typec-muic-scoping.md`.
