# Phase 3 scoping: USB-C/PD port management + MUIC (Maxim MAX77705)

Recon pass done 2026-09-20, prompted by a real symptom found while
testing charging status on real hardware
(`docs/phase3-battery-scoping.md`): plugging in a genuine USB-PD
"Superfast" wall charger makes Plasma's charging icon appear for only
~2-3 seconds before it disappears, with the charge state never
settling. Goal: find out whether this is a small, fixable gap in what
was already built, or a genuinely separate, much bigger subsystem -
**per the owner's explicit request, this pass searched online for
prior art before assuming a from-scratch port was needed**, the same
discipline that turned the fuel-gauge task from an assumed big port
into a two-line devicetree change. Nothing here has been built or
tested; this is pure research.

## The headline finding: this is genuinely different from the last two passes - no prior art exists

Unlike the fuel gauge, **this is real from-scratch-port territory, not
a hidden two-line fix.** Checked three separate places, all consistent:

1. **The upstream MAX77705 patch series itself** - the same 7-part
   "Add support for Maxim Integrated MAX77705 PMIC" series
   (Dzmitry Sankouski, up to v17) this project already uses for
   `pmic@66`/`charger@69` **does not include Type-C, USB-PD, MUIC, or
   CCIC support at all**. Its 7 patches are: DT bindings (charger,
   MFD), the charger driver, `simple-mfd-i2c` glue, the MFD core
   driver, haptic support, and LED support. The fuel-gauge path was a
   *separate* mechanism (extending `max17042_battery.c`, not part of
   this series). Confirmed by reading the series' own patch list
   directly (lkml.indiana.edu mirror of the v17 posting) - the
   introductory text even describes MAX77705 as "a Companion Power
   Management **and Type-C interface** IC," but none of the 7 patches
   touch that part of the chip.
2. **Mainline `drivers/usb/typec/`** - no MAX77705-specific file
   anywhere. The one real near-miss, `drivers/usb/typec/tcpm/
   tcpci_maxim_core.c` ("MAXIM TCPCI based TCPC driver", written by
   Google for their **MAX77759** Pixel 6 PMIC - the same sibling chip
   the fuel-gauge driver already reuses code from) turned out to be a
   dead end on closer reading: its `of_device_id` table matches only
   `"maxim,max33359"` (`tcpci_maxim_core.c:588`), a *different*,
   standards-compliant TCPCI chip Google also happens to use - no
   `"maxim,max77759"` or `"maxim,max77705"` string appears anywhere in
   that file. MAX77705/77759's own Type-C block uses a proprietary,
   non-TCPCI register/message interface (confirmed below), so it
   can't bind to the generic `tcpci.c` core the way a standards-based
   chip can.
3. **Web search for any other prior art** (postmarketOS, other
   community mainline-Linux-on-Samsung projects, any standalone patch
   series) - found nothing. The only other MAX77705-adjacent mainline
   work found is a separate, recent "Introduce MAX77759 charger
   driver" series (v5/v7, 2026) - a *different* chip's *charger*
   block, not Type-C/PD, and not this chip.

**Conclusion: no reusable mainline driver or in-flight patch exists
for this chip's Type-C/PD/MUIC block.** This is the opposite finding
from the fuel-gauge pass, and it's important to say so honestly rather
than force-fit the same "just add a compatible string" pattern.

## Why: this is architecturally a bigger, different kind of block

Read downstream's real driver source directly rather than assuming
scope from the chip's marketing description:

- `references/gts7l/drivers/ccic/max77705_usbc.c` - **3959 lines**.
- `references/gts7l/drivers/muic/max77705-muic.c` - 2661 lines.
- `references/gts7l/drivers/muic/max77705-muic-afc.c` (fast-charge
  negotiation) - 514 lines.
- `references/gts7l/drivers/muic/max77705-muic-ccic.c` - 263 lines.
- `references/gts7l/include/linux/ccic/max77705_usbc.h` - 364 lines.

**~7761 lines total** - several times larger than any single driver
this project has ported or written this session (the touchscreen
driver, the largest from-scratch port so far, is a few hundred lines).
The reason: `max77705_usbc.c` registers **ten separate interrupt
lines** (`irq_apcmd`, `irq_sysmsg`, `irq_vdm0` through `irq_vdm6`,
`irq_vir0`, confirmed by grepping every `request_threaded_irq()` call
in the file) implementing a real USB-PD **VDM (Vendor-Defined
Message)** protocol bridge - the chip runs its own PD policy engine
firmware internally, and the host driver's job is to exchange
structured PD/VDM messages with it, not just read a status register.
This is architecturally the same *class* of work as a full TCPM
port for a new chip, not a simple MFD child driver like the charger or
fuel gauge turned out to be.

## Real hardware facts confirmed for this board

- **MUIC I2C address**: `0x25` - `references/gts7l/drivers/mfd/
  max77705.c:44`, `#define I2C_ADDR_MUIC (0x4A >> 1)` = `0x25`. Same
  "each sub-function is a real, separate I2C address" pattern
  confirmed three times now (charger `0x69`, fuel gauge `0x36`, MUIC
  `0x25`) - if a driver existed, this address is real and ready to
  use.
- **Interrupt routing**: the MFD binding's own documented
  interrupt-controller mapping (`Documentation/devicetree/bindings/
  mfd/maxim,max77705.yaml`) lists index 3 as "usb type-c management
  block" - reusable via the same `interrupt-parent = <&max77705_pmic>;
  interrupts = <3>;` mechanism `charger@69`/`fuelgauge@36` already use
  successfully. **This one interrupt line is not the whole picture
  though** - downstream's driver derives its own ten sub-interrupt
  sources (`irq_apcmd` etc.) from registers read *after* this single
  IRQ fires, not ten separate GPIO/MFD-domain lines - a from-scratch
  mainline driver would need to replicate that demuxing logic, not
  just wire up ten devicetree interrupt properties.
- **CHGIN detection (what already works) is independent of this
  block**: confirmed by re-reading `max77705_charger.c` - its
  `POWER_SUPPLY_PROP_ONLINE` handler does a direct live regmap read of
  a charger-block-local `MAX77705_CHGIN_OK` bit
  (`max77705_charger.c:135`), not anything from the MUIC/CCIC block.
  This means the observed symptom (icon flashes, then disappears) is
  most likely a genuine hardware-level bounce of that bit itself -
  plausible if, without a working PD negotiation, the charger's own
  attach state machine can't settle into a stable "sink" role and
  cycles between attach/detach attempts - not a bug in the charging
  driver already built.

## Kernel config, if this were pursued

No existing symbol to force - a from-scratch driver would need its
own new `Kconfig` entry (following the same shape as
`CONFIG_CHARGER_MAX77705`, presumably `depends on MFD_MAX77705`).
Generic `CONFIG_TYPEC`/`CONFIG_TYPEC_TCPM` (the framework a real
driver would register against for `power_supply`/`extcon`/`typec`
port-role reporting) - not yet checked whether these are already `=y`
via defconfig; would need the same tristate-ceiling check every other
symbol this project has added has needed.

## The `boot` partition size question - this is the one most likely to actually matter here

Every Phase 3 scoping doc since Wi-Fi has flagged the partition's hard
ceiling (71303168 bytes, zero headroom on every recent build) as a
standing constraint, and every driver added so far has still fit. **A
from-scratch ~1500-3000+ line port of this block (even trimmed down
significantly from downstream's full 7761 lines, the way the
touchscreen driver was trimmed from its own downstream source) is the
first candidate this session that could plausibly not fit anymore.**
If it doesn't, real module-loading or kernel image compression - both
already flagged twice as deferred - stops being optional and becomes
a hard prerequisite, not a "nice to have soon."

## Open questions, genuinely unresolved

- Whether the CHGIN bounce is really caused by the missing PD
  negotiation (this doc's working theory) versus something else
  entirely (a cable/power-supply quality issue, a `qca6390-pmu`-style
  regulator sequencing gap, or a completely unrelated USB PHY
  interaction) - **not confirmed**, only inferred from how the
  charger driver's `ONLINE` property is computed. A live register-read
  characterization (see suggested step below) would confirm or refute
  this before committing to a full port.
- Whether **basic (non-PD, 5V/2.4A-class) charging actually works
  today** - not yet tested. If plain CHGIN-based charging (no PD
  negotiation at all, the charger falling back to a simple "dumb"
  5V charge rate) works and only *fast*-charge negotiation is broken,
  the practical impact of not porting this block is much smaller
  (the tablet still charges, just not at full "Superfast" speed) -
  this materially changes how urgent this task is. Worth testing with
  a plain USB-A charger or a PC's own USB port (not a PD-capable
  charger) before assuming charging is broken outright.
- Whether a real Type-C role/orientation is even needed for basic
  charging on this board, or whether MAX77705's own internal state
  machine can supply *some* default/fallback charging behavior without
  any host-side PD driver at all (i.e., whether the 2-3 second flash
  itself might just be a transient the driver could reasonably
  smooth over/debounce in software, rather than a sign that charging
  never stabilizes at all) - not confirmed either way.

## Suggested next step: diagnose before porting, not the other way around

Given the size and total absence of prior art here - a very different
situation from the charger/fuel-gauge passes - **do not start by
porting a driver.** Recommend a much smaller, purely diagnostic first
step to actually characterize the problem before committing real
effort:

1. **First, and cheapest of all**: test charging with a plain,
   non-PD USB charger or a PC's own USB-A/USB-C port (not the
   Superfast PD charger that exposed this). If `POWER_SUPPLY_ONLINE`
   stays stable and the battery genuinely charges, the real-world
   impact of skipping this whole subsystem is much smaller than it
   first appeared, and this task can reasonably stay deferred
   indefinitely.
2. If basic charging is *also* unstable: add a small, temporary
   diagnostic (not a real driver) that just enables MFD interrupt
   index 3 and logs the MUIC/CCIC block's raw status registers
   (`references/gts7l/drivers/muic/max77705-muic.c`'s own register
   reads are a real reference for which addresses to poll) on every
   fire, mirroring this project's own established "add a rate-limited
   diagnostic print, rebuild, reflash, read real evidence" methodology
   (used successfully for the touch CRC-reboot investigation) - to
   confirm or refute the "PD negotiation never completes" theory
   directly, before deciding whether a full port is actually
   warranted.
3. Only if (1) shows basic charging is *also* broken, and (2)
   confirms the MUIC/CCIC block is the real cause: scope a genuine
   driver-port task properly (register map extraction, VDM message
   format, a real Kconfig entry, and - given the file-size finding
   above - a serious, dedicated check of whether it fits the
   partition at all) as its own separate, much larger effort, not
   something to fold into "just enable one more devicetree node" the
   way every other Phase 3 chunk has been so far this session.

## Result (2026-09-23): not a PD problem - three smaller bugs, two fixed

The capture script `tools/rootfs/charging/pdcap.sh` reads the charger
regmap and the unbound CCIC at 0x25 over `i2cget`, 5 times a second.
Logs are in `docs/logs/charging-2026-09-23/`. With the Samsung Superfast
charger plugged in, the working theory above turned out wrong:

- **CHGIN never bounced.** `CHG_DETAILS_00` stayed 0xe0 (CHGIN valid)
  and `online` stayed 1 for the whole ~27 s. The charger was in
  fast-charge CC mode throughout.
- **VBUS stayed at 5 V** (CCIC `USBC_STATUS1` VBADC = 2). Without a host
  driver, the CCIC firmware does not negotiate a higher PD voltage.
- **The charger advertises 3 A on CC** (`CC_STATUS0` = 0xb1:
  CCPinStat = CC2, CCIStat = 3 = CCI_3_0A, CCStat = sink) and is
  detected as a **DCP** (`BC_STATUS` = 0x83, ChgTyp = 3).

The three real problems:
1. **The battery status was always Unknown**, which KDE shows as "Not
   charging". `max17042_get_status()` calls
   `power_supply_am_i_supplied()`, and the fuel gauge had no supplier.
   **Fixed:** `power-supplies = <&max77705_charger>` on `fuelgauge@36`.
2. **Every current and charge reading was 5x too low.** Stock's
   `max77705_fuelgauge.c` uses `fg_resistor = 5` as a multiplier on
   10 mOhm steps (15625 x 5 / 100000 = 0.78125 mA/bit), so the sense
   resistor is **2 mOhm**, not the DTS's 10 mOhm. **Fixed:**
   `shunt-resistor-micro-ohms = <2000>`. Confirmed: `charge_full_design`
   now reads 7255 mAh = stock's `fuelgauge,capacity` 0xb56 x 2.5 mAh.
3. **Charging was starved (open).** Mainline's charger driver never sets
   the input limit or the charge current, so the chip's power-on
   defaults stay. Those were 900/900 mA on some boots and 500/100 mA on
   others. Tablet load then ate most of it: battery current was about 0,
   or discharging. Stock's `cable-info` for a 5 V TA is
   `default_input_current` 1800 mA and `default_charging_current`
   2100 mA; USB (SDP) uses 475 mA, and 9 V TA uses 1650 mA input with
   3150 mA charge.
   - With 1800/2100 set by hand through sysfs, the battery charged at
     1.30 A on the Superfast charger (all samples "Charging") and 1.25 A
     on the PC's USB-C port.
   - The owner confirmed the icon and state now stay "Charging", and go
     back correctly on unplug.

**What's left, and much smaller than the port above:**
- **Source-aware input limit at 5 V:** read `BC_STATUS` (ChgTyp:
  SDP/CDP/DCP) and `CC_STATUS0` (CCIStat: 500 mA/1.5 A/3 A) on the
  MAX77705 USB-C interrupt (MFD index 3), then set the charger's
  `input_current_limit` from stock's table. A small MFD-child driver of
  a few hundred lines. No PD message bridge, no VDM. Blind 1800 mA would
  be wrong for a 500 mA USB-A port.
- **9 V / PPS "Superfast":** the only part that needs the CCIC command
  interface (PDO selection through the APCMD opcodes). A separate, later
  step.

### Source-aware input limit: done (2026-09-23, patch 0024)

`drivers/power/supply/max77705_usbc_ilim.c` (`CONFIG_CHARGER_MAX77705_USBC_ILIM`,
about 270 lines) binds to a new `usbc@25` node (`maxim,max77705-usbc`,
`interrupts = <3>` from `max77705_pmic`):
- It unmasks only VBUSDetI/ChgTypI (UIC_INT_M = 0xdd) and
  CCIStatI/CCStatI (CC_INT_M = 0xfa).
- Its regmap allows writes only to those two mask registers, so it
  cannot command the USB-C firmware, request PD or change VBUS.
- On each interrupt it clears UIC/CC/PD/VDM_INT and re-evaluates 300 ms
  after the last event.
- The input limit is the larger of the BC1.2 value (SDP 475, CDP 1000,
  DCP 1800 mA) and the Type-C value (500 mA -> 475, 1.5 A -> 1500,
  3 A -> 1800, capped at stock's 5 V TA value). The charge current is
  2100 mA at 1800 input, otherwise the same as the input.
- While neither result is known, which the chip briefly reports as
  "type 0, current 0" during attach and detach, it leaves the setting
  alone.

Verified by the owner and by capture:
- **Boot on the PC port:** SDP + Type-C 3 A, so 1800/2100 mA; the
  battery charges at about 1.2 A.
- **Superfast plug-ins:** set by Type-C 3 A (BC1.2 reports DCP later).
  Every sample with a charger online had the input at 1825 mA, the
  battery averaged +1.24 A, and KDE stayed on "Charging".
- **V1 vs V1.1:** V1 followed the PC port's advertisement as it flipped
  between 1.5 A and 3 A for about 0.5 s after attach (about 10 limit
  writes). V1.1's 300 ms debounce turned 44 interrupts in a full replug
  round into zero changes.

## Next: 9 V / PPS (not started)

The only piece that needs the CCIC's command interface is PDO selection
(APCMD). See `references/gts7l/drivers/ccic/max77705_pd.c` and
`max77705_usbc.c`. Stock's 9 V table is 1650 mA input and 3150 mA charge.

## Status: 5 V charging done (DT + patch 0024); 9 V PD next

Nothing built or flashed. This document is the research-only pass;
implementation - if pursued at all, pending step 1 above - is a
separate, future step.
