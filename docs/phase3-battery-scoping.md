# Phase 3 scoping: Charging + battery telemetry (Maxim MAX77705)

Recon pass before starting real charging/battery bring-up, done
2026-09-20 right after Wi-Fi and Bluetooth (`docs/phase3-wifi-bt-scoping.md`,
`docs/phase3-bluetooth-scoping.md`) both got working on real hardware.
Goal: find out how much of this is genuinely new work versus reusable
mainline infrastructure, and - critically, given today's own
hard-won lesson - whether the `boot` partition's now-completely-full
size budget makes this even feasible to bring up the same way Wi-Fi/BT
were, before writing any DTS/config changes. Nothing here has been
built or tested yet - this is pure research, following the same
methodology as the other Phase 2/3 scoping docs (real sources cited,
nothing assumed).

## The chip, and a real head start from earlier Phase 1 work

Chip confirmed **Maxim MAX77705** (charger + fuel gauge + MUIC + haptic
+ USB-PD combo IC), per `docs/hardware-inventory.md`. Unlike Wi-Fi/BT,
**this project already did real hardware-wiring research for this
exact chip once before**, during Phase 1 - a large, already-committed
comment block sits directly in `kernel/dts/sm8250-samsung-gts7l.dts`
(search for "Charger + fuel gauge + MUIC + haptics", around line
520-543) with facts confirmed **two independent ways**:

- `reg = <0x66>` (I2C slave address), from the GPL overlay
  (`references/gts7l/arch/arm64/boot/dts/samsung/gts7l/
  kona-sec-gts7l-eur-overlay-r07.dts:10219`, `max77705@66`,
  `compatible = "maxim,max77705"` - the exact compatible string, see
  below).
- IRQ GPIO: PM8150L GPIO 11, active-low - from the overlay's
  `max77705,irq-gpio = <0x92 0xb 0x1>` (phandle `0x92` resolves to the
  PM8150L gpio-controller per the overlay's own symbol table) **and**
  independently confirmed live on the physical unit's stock Android
  boot: `/sys/kernel/debug/gpio`'s PM8150L gpiochip shows GPIO 11 as an
  input with pull-up (consistent with active-low), and
  `/proc/interrupts` shows a live, firing family of `max77705`
  interrupt names (`chgin-irq`, `fuelgauge-irq`, `muic-*`, `pd-*`,
  `usbc-*`) on the running stock kernel - this is the real, active
  chip, not a guess.
- This project's own DTS already has the pinctrl state wired up
  (`&pm8150l_gpios { max77705_int_gts7l: max77705-int-state { pins =
  "gpio11"; ...}; };`) - the IRQ GPIO pin config is **already done**,
  from Phase 1, zero new pinctrl work needed.

**The real I2C bus** wasn't identified in that earlier pass (its own
comment says "not yet mapped"), but this session found it: the
downstream overlay's fixup table maps `fragment@134` (the fragment
containing `max77705@66`) to `qupv3_se0_i2c`
(`kona-sec-gts7l-eur-overlay-r07.dts:12582`,
`qupv3_se0_i2c = "/fragment@134:target:0", ...`) - **QUP SE0, i.e.
mainline's `i2c0`** (`work/linux/arch/arm64/boot/dts/qcom/
sm8250.dtsi:1367`, `i2c0: i2c@980000`, `status = "disabled"` by
default - same recurring "off unless a board DTS turns it on" pattern
already solved for `qupv3_id_0`/`gpi_dma0`/`&pcie0`/`&uart6` in every
prior Phase 2/3 bring-up this session).

**A correction to that earlier Phase 1 TODO, now confirmed wrong**:
the comment reads *"TODO(phase3): mainline has no 'maxim,max77705'
driver - this is a Samsung/Maxim combo IC ... that will need real
driver work, not just a devicetree node."* **This is no longer true**
(it may have been true when written, or was simply not re-checked
since) - see below.

## Mainline already has a real MAX77705 driver - but a partial one

Checked `work/linux/drivers/mfd/Kconfig` and
`work/linux/drivers/power/supply/Kconfig` directly:

- **`CONFIG_MFD_MAX77705`** (`drivers/mfd/max77705.c`, 180 lines) -
  the core chip driver, `of_device_id` table matches
  `"maxim,max77705"` exactly (`max77705.c:163`) - **byte-for-byte the
  same compatible string** downstream's own overlay already uses
  (`kona-sec-gts7l-eur-overlay-r07.dts:10219`). Real, working, current
  mainline driver - not a stub.
- **`CONFIG_CHARGER_MAX77705`** (`drivers/power/supply/
  max77705_charger.c`, 699 lines), `depends on MFD_MAX77705` - reports
  `POWER_SUPPLY_PROP_ONLINE` and `POWER_SUPPLY_PROP_STATUS` (is a
  charger plugged in, and charging/not-charging state) - confirmed by
  reading the property list directly (`max77705_charger.c:32-34`).
- The MFD driver's own sub-device list (`max77705.c:18-21`,
  `max77705_devs[]`) instantiates exactly three children:
  `max77705-rgb` (notification LED), `max77705-charger`, and
  `max77705-haptic`. **No fuel-gauge sub-device is created at all.**

**This is the single most important finding of this scoping pass**:
despite the binding doc's own description text mentioning "fuelgauge"
as one of the chip's four IRQ sources (`Documentation/devicetree/
bindings/mfd/maxim,max77705.yaml`, interrupt-controller description,
"2 - fuelgauge"), and despite the chip's real downstream driver having
a full separate `max77705_fuelgauge.c`
(`references/gts7l/drivers/battery_v2/max77705_fuelgauge.c`) -
**mainline's charger driver does not report
`POWER_SUPPLY_PROP_CAPACITY` (battery percentage) at all**, confirmed
by reading its complete property list. Grepping mainline's whole
`drivers/power/supply/` tree for any `max77705`-fuelgauge-specific
file found none. **"Charging + battery telemetry" splits into two
very differently-sized tasks**:

1. **Charging status (plugged in / charging / not charging)**: a real
   "enable an existing driver" task, the same shape as most of Wi-Fi's
   bring-up - genuinely small.
2. **Battery percentage (fuel gauge / state of charge)**: mainline has
   **no driver at all** for this specific chip's fuel-gauge block.
   This is a "port a new driver" task, comparable in scope to the
   original touchscreen driver work (a from-scratch mainline driver
   informed by the real downstream source), not a quick enable. Not
   attempted or scoped in detail here - flagged honestly as
   significantly bigger than it might first sound from the phase
   roadmap's one-line "charger/fuel-gauge/MUIC IC" description.

**Also not in mainline's `max77705_devs[]` cell list**: MUIC (USB
accessory/cable detection) and USB-PD role-swap support, both of which
*are* real, active, firing interrupt sources on this physical unit
per the live `/proc/interrupts` evidence above (`muic-*`, `pd-*`,
`usbc-*`). Out of scope for a first charging/battery pass; noted for
completeness since the roadmap's Phase 3 description groups
"charger/fuel-gauge/MUIC" together as if they were one task.

## Devicetree shape needed (charger-only scope)

The binding docs (`Documentation/devicetree/bindings/mfd/
maxim,max77705.yaml` and `.../power/supply/maxim,max77705.yaml`, both
read in full) show a real, working example matching this board's
already-confirmed wiring almost exactly:

```
i2c0 {
	pmic@66 {
		compatible = "maxim,max77705";
		reg = <0x66>;
		interrupt-parent = <&pm8150l_gpios>;
		interrupts = <11 IRQ_TYPE_LEVEL_LOW>;
		interrupt-controller;
		#interrupt-cells = <1>;
		pinctrl-names = "default";
		pinctrl-0 = <&max77705_int_gts7l>;

		charger {
			compatible = "maxim,max77705-charger";
			monitored-battery = <&battery>;
		};
	};
};
```

Two genuinely open items this simple example surfaces:

- **`monitored-battery` is `required`** (`.../power/supply/
  maxim,max77705.yaml`, `required: [compatible, reg,
  monitored-battery]`) - a phandle to a standard
  `simple-battery`-compatible devicetree node describing the physical
  battery (design capacity, voltage curve, etc., per the generic
  `power-supply.yaml` framework every mainline charger driver shares).
  This project's DTS has no such node yet. Downstream's own overlay
  does have *some* real battery data (`fragment@142`'s bare `battery {
  io-channels = <0x0 0x8 0x10>; }` stub, and a separate, unexamined
  `qcom,battery-data` node spotted once in passing during Bluetooth
  research at `kona-sec-gts7l-eur-overlay-r07.dts` line ~7533) - **not
  yet read in enough depth to know if it has the real capacity/voltage
  numbers needed**, or whether reasonable generic placeholder values
  would be good enough for `POWER_SUPPLY_PROP_ONLINE`/`STATUS` to work
  correctly regardless (charging-status reporting likely doesn't
  strictly need accurate battery physical parameters the way a real
  fuel gauge would).
- **Whether the charger sub-node shares the MFD's `reg = <0x66>` or
  needs its own separate I2C address**: the binding's own *example*
  shows `charger@69` as a sibling I2C device at a *different* address
  from the parent `pmic@66` example elsewhere in the same file, and
  the charger driver's own probe code
  (`max77705_charger.c:624`, `devm_regmap_init_i2c(i2c, ...)`) expects
  a real, distinct `i2c_client` - suggesting the charger sub-device
  may genuinely need to be a proper i2c child address, not literally
  nested under the mfd node the way `MFD_CELL_OF`'s naming might
  suggest at a glance. Downstream's own overlay never mentions a
  second I2C address for this chip anywhere seen so far. **Genuinely
  unresolved** - needs either closer reading of how `MFD_CELL_OF`
  actually wires child-node `reg`/regmap sharing for this specific
  driver, or just trying `reg = <0x66>` on both and seeing whether
  probe succeeds on real hardware.

## The real blocker: the `boot` partition has zero space left

This is the most important thing to flag in this document, more than
any driver detail above. **Today's session hit the same real
constraint twice already** (Wi-Fi's firmware-in-kernel attempt,
round76; every Bluetooth-era build since has packaged to *exactly*
71303168 bytes - the partition's real, fixed capacity - with
literally zero bytes of headroom measured on the last several rounds).

`CONFIG_MFD_MAX77705` (180 lines) + `CONFIG_CHARGER_MAX77705` (699
lines) is a small amount of new code compared to the ~4.5MB of Wi-Fi
firmware that caused the actual overflow - built-in driver *code*
size, as opposed to embedded firmware *data*, is the relevant
comparison, and every built-in driver added so far this session
(PHY_QCOM_QMP_PCIE, the whole BT/UHID/HIDP stack, Landlock) has each
individually fit within whatever small page-rounding slack exists,
each confirmed via a real size check before flashing. **It is likely,
but not certain, that MAX77705's driver code alone would also fit** -
this has not been tested and should not be assumed either way; the
same "package it, check the exact byte count against 71303168, and
only flash if it fits" discipline used for every build since round76
is now a hard requirement, not just good practice, for this and every
future Phase 3/4 kernel change.

**The bigger, structural point**: this project has now added new
built-in kernel code for five separate features (Wi-Fi, Bluetooth,
UHID/HIDP/HIDRAW, Landlock, and now potentially MAX77705) into a
`boot` partition whose size was fixed by Samsung's original stock
kernel's own reserved space, with genuinely no headroom left as
measured today. **Speakers/microphone, motion sensors, and Phase 4's
S Pen/camera/fingerprint work are all still ahead**, and each will
need its own kernel code. Continuing to force everything built-in
(this project's answer so far to "we have no module-loading
infrastructure") is **very likely to hit a hard wall soon, if it
hasn't already** - recommend treating "set up either real Linux kernel
module loading (the `depends`/`option 2` this project's own Wi-Fi
scoping doc already flagged and deferred) or kernel image compression
(gzip/lz4 `Image.gz`, which this project's boot pipeline has never
used - all builds so far use `KERNEL_FMT [raw]`)" as a genuine
prerequisite to unblock, not just optimize, the remaining Phase 3/4
roadmap - **not something to keep deferring indefinitely the way it
has been since Wi-Fi's own scoping doc first raised it**.

## Plasma/UpowerD UI

Not checked live (no device access in this research pass) - but the
mechanism is well-understood and low-risk based on how `upower`/
Plasma's battery applet generally work: once a real `power_supply`
class device exists (`/sys/class/power_supply/*`, which
`CONFIG_CHARGER_MAX77705` would register automatically once probed
successfully), `upower` and Plasma's own battery monitor plasmoid
auto-detect it with no additional kernel-side work - the same
"kernel driver alone isn't enough, the matching Plasma package also
has to be installed" gap hit twice already (`plasma-nm` for Wi-Fi,
proactively avoided for Bluetooth's `bluedevil`) is the one thing
worth checking for proactively here too: confirm `upower` itself is
actually installed on the live rootfs (`pacman -Q upower`) before
assuming the battery applet will "just work" once the kernel driver
probes - Plasma's own battery indicator plasmoid is normally part of
the base `plasma-desktop` install already on this system, but `upower`
itself is a separate package some minimal installs skip.

## Suggested next step when this work actually starts

Mirror the order that's worked every time this session: confirm the
hardware path exists before chasing anything else, with the
partition-size check now a mandatory gate before any flash, not an
afterthought.

1. Enable `&i2c0` (`status = "okay"`) and the parent QUP wrapper if it
   isn't already covered by an existing `status = "okay"` from prior
   phases (check - touch's `&qupv3_id_0` enable may or may not cover
   the QUP instance `i2c0` sits under; SE0 and SE5 (touch) may be on
   different QUP wrapper instances, needs a real check, not an
   assumption).
2. Add the `max77705@66` node with real IRQ/pinctrl wiring (already
   fully specified in this project's own existing DTS comment) and a
   *minimal* `charger` sub-node, resolving the `reg`-sharing and
   `monitored-battery` open items above by direct experimentation if
   reading the driver source further doesn't resolve them cleanly
   first.
3. Force `CONFIG_MFD_MAX77705=y` and `CONFIG_CHARGER_MAX77705=y` in
   `kernel/config/gts7l.fragment` (check for the same class of
   tristate-ceiling gotcha hit repeatedly this session - `POWER_SUPPLY`
   core, I2C core, etc. dependencies - before assuming a plain `=y`
   request resolves cleanly).
4. **Package and check the exact byte count against 71303168 before
   touching the device at all** - this is new, hard-won process this
   session, not yet written down anywhere as a standing rule before
   this document. If it doesn't fit, stop and address the real
   module-loading/compression prerequisite above rather than trying to
   shave bytes elsewhere.
5. Confirm real I2C enumeration/probe success
   (`/sys/class/power_supply/*`, `dmesg` for a clean
   `max77705`/`max77705-charger` probe) before worrying about Plasma
   UI - the same "confirm the hardware path" discipline every prior
   bring-up this session used.
6. Only once charging status is confirmed working, decide whether to
   scope the much larger fuel-gauge driver-port task separately (a new
   document, given its real size) or leave battery-percentage as a
   known, documented gap.

## Status: charging status working on real hardware (2026-09-20)

Implemented the same day this doc was written. Followed the suggested
plan closely, plus found two more real bugs only visible on real
hardware:

**1. `Rev.0x2 is not tested`** - mainline's MFD probe
(`drivers/mfd/max77705.c`) only accepted `MAX77705_PASS3` silicon.
This unit's real chip reports PASS2 (confirmed via a clean regmap read
of the revision register - a genuine I2C success, not a wiring
failure). Samsung's own downstream driver
(`references/gts7l/drivers/mfd/max77705*.c`) treats PASS2 as a fully
normal, supported revision throughout every switch-case that handles
chip revisions - this upstream gate is simply more conservative than
real shipped hardware, not evidence of an incompatibility. Patched
mainline's `drivers/mfd/max77705.c` to accept `MAX77705_PASS2` too -
same precedent as this project's existing `drivers/dma/qcom/gpi.c`
patch (a real, well-justified upstream driver change for real hardware
this session already established, not a new pattern).

**2. The charger doesn't bind as an MFD sub-cell at all** - the
scoping doc's own flagged "genuinely unresolved" question turned out
to be the real blocker. `drivers/power/supply/max77705_charger.c` is a
genuine `module_i2c_driver`, needing its own real `i2c_client` - not a
`platform_device` the MFD framework creates via `MFD_CELL_OF`.
Confirmed live: nesting `charger {}` under `pmic@66` created a real,
correctly-matched platform device in sysfs, but zero driver ever bound
to it (`max77705-charger` never appeared under
`/sys/bus/platform/drivers/` at all, since `module_i2c_driver`
registers on the I2C bus, not the platform bus). The *charger*
binding's own example (`maxim,max77705.yaml`, a different file from
the MFD binding) shows exactly this: `charger@69` as a sibling I2C
node, not nested. `0x69` independently confirmed real for this exact
chip via downstream's own `I2C_ADDR_CHG = (0xD2 >> 1)`
(`references/gts7l/drivers/mfd/max77705.c:45`) - the exact same
address mainline's doc example uses, not a coincidence. Moved the
`charger` node to a proper sibling `charger@69`, wired its interrupt
through the parent's own interrupt-controller domain (interrupt 0,
"charger" per the MFD binding's documented IRQ mapping), and added a
minimal `simple-battery` node (`monitored-battery` turned out to be a
real runtime requirement, not just a DT-schema nicety -
`max77705_charger_initialize()` calls
`power_supply_get_battery_info()` unconditionally and bails the whole
probe without it).

**Confirmed on real hardware**: `/sys/class/power_supply/max77705-charger`
exists with real, live telemetry read straight from the chip
(`POWER_SUPPLY_STATUS=Full`, `POWER_SUPPLY_ONLINE=1`,
`POWER_SUPPLY_CONSTANT_CHARGE_CURRENT=900000`,
`POWER_SUPPLY_CONSTANT_CHARGE_VOLTAGE=4200000` - genuine chip data,
not placeholders). `upower` (already installed) correctly enumerates
it as `line_power_max77705_charger`.

**The Plasma UI gap this time is structural, not a missing package**:
unlike Wi-Fi (`plasma-nm`) and Bluetooth (`bluedevil`), no icon appears
in Plasma's system tray for this device - not because a package is
missing, but because `upower` correctly classifies it as a
`line-power`/AC-adapter device (icon `ac-adapter-symbolic`), not a
`battery` device. Plasma's system tray battery widget specifically
needs a real `Battery`-type `power_supply` device (with a capacity) to
render anything at all - this is exactly the fuel-gauge gap already
flagged above as deliberately out of scope for this pass, not a new
finding. Scoped separately: `docs/phase3-fuelgauge-scoping.md`.

**Bonus fix confirmed working in this same round**: the
`CONFIG_SECURITY_LANDLOCK` fix (from Bluetooth's own session) -
`pacman -Sy` completed with zero sandbox errors.
