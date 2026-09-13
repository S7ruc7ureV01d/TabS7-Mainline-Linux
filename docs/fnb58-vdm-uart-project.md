# FNB58 reflash for USB-PD VDM injection — parked side-project (2026-09-13)

Split out from `uart-debug-research.md`/`kernel-boot-debugging.md` Round 8 so it
doesn't get lost, but doesn't block the main kernel-boot work either. Not started.
No hardware has been opened or modified yet.

## Why this exists

Passive CC-resistor "JIG UART" (the classic microUSB-era trick) is confirmed
**electrically impossible** on this tablet's USB-C port — see
`uart-debug-research.md` and `kernel-boot-debugging.md` Round 8 for the full
hands-on evidence (breakout board, multiple resistor values, dead short, both
orientations, VBUS-powered variant, all zero reaction; root cause: the tablet's
mandatory USB-C sink pull-down permanently dominates any external resistor).
Real Samsung "AnyWay" JIG-UART entry on modern USB-C devices works over a
genuine **USB-PD VDM (Vendor Defined Message)**, not a passive resistor -
confirmed by community research in
`https://xdaforums.com/t/has-anyone-tried-the-samsung-usb-c-jig.4766565/`
(full thread pasted into a prior session).

## The hardware: already owned, no purchase needed

The owner's **FNIRSI FNB58** USB-C power meter/tester contains a genuine
**FUSB302BMPX** USB-PD PHY chip (QFN14, top-marking "UAAC CEH" — confirmed via
public teardown/chip-ID sources this session) — the exact chip
`references/vdmtool` (an Arduino-based FUSB302 VDM send/receive tool) targets.
Main board also has: Artery **AT32F403A CGT7** (main MCU, ARM Cortex-M4,
pin/tooling-compatible with STM32F103 "blue pill"), **W25Q128JV** (external SPI
flash, holds the MCU's firmware), **TPA626** (current/power monitor), an RS2228
USB 2.0 mux (switches between the Micro-USB and USB-C inputs), and an unidentified
step-down regulator.

## Two possible approaches — decided: Option B (reflash), not Option A (I2C tap)

- **Option A (I2C tap + separate MCU)**: wire an Arduino/ESP32 directly to the
  FUSB302's SDA/SCL/INT/GND pins, running `vdmtool`'s *existing, unmodified*
  firmware. No firmware writing needed at all - but requires physically isolating
  the FUSB302's I2C bus from the FNB58's own onboard MCU (cutting/lifting the
  SDA/SCL traces) to avoid two masters fighting over the same bus, plus real
  soldering to wire in the new MCU.
- **Option B (reflash the FNB58's own MCU) - chosen**: write new firmware for the
  AT32F403A that drives the *same* onboard FUSB302 over the *existing, unmodified*
  wiring. No trace-cutting, no rewiring, nothing permanent - just temporary SWD
  programming pads. Real firmware-writing work is required (there's no existing
  AT32F403A port of `vdmtool` to just flash as-is), but it's forward engineering
  from public sources (Artery's official SDK + porting `vdmtool`'s open-source PD/
  VDM logic), not reverse-engineering of the FNB58's own stock firmware.

**Decided in favor of Option B** per the owner's explicit preference: avoid any
permanent hardware modification (no resoldering/trace-cutting), even at the cost
of needing real firmware-writing effort. Opening the case (non-destructive,
reversible) to reach SWD pads is acceptable.

## Concrete plan, not yet started

1. **Open the FNB58 case** (unscrew/unclip) and locate the AT32F403A's SWD pads
   (SWDIO, SWCLK, GND, 3V3) - almost certainly exposed as test points or an
   unpopulated header near the MCU, since the factory needed some way to program
   it originally. No community documentation of exact pad locations was found
   this session (searched); needs direct inspection of the physical board.
2. **Get a cheap SWD programmer** - an ST-Link V2 clone (~$3-5, extremely common)
   or a Raspberry Pi Pico running open-source "picoprobe"/DAPLink firmware.
   Connects via 4 temporary probe wires or a spring-pin clip; no soldering needed
   if the pads are reachable test points.
3. **Write new AT32F403A firmware** that:
   - Initializes the chip's I2C peripheral already wired to the onboard FUSB302
     (no rewiring - reusing the existing bus).
   - Implements FUSB302 PD/VDM protocol logic, ported from `references/vdmtool`'s
     open-source Arduino code (a real, working reference implementation) rather
     than written from scratch.
   - Exposes a command interface for sending arbitrary VDM messages - ideally
     reusing the FNB58's existing USB-serial link to the PC, if reachable,
     instead of adding a new physical UART connection.
   - Toolchain: Artery provides a free official SDK for this chip family
     (CMSIS-based, structured similarly to STM32 HAL) + `arm-none-eabi-gcc`.
4. **Flash via SWD**, verify the FNB58 still does its normal job (power
   measurement, PD trigger) as a sanity check that nothing broke, then use the
   new VDM command interface for the actual research below.

## The remaining open research question - unsolved regardless of hardware path

**Samsung's actual JIG-UART VDM payload (vendor ID, command structure, exact
bytes) is not publicly documented anywhere found this session**, for this device
or any Samsung USB-C device. The XDA thread above shows a partial capture
(SVID `0xff00`, a `DISCOVER_IDENTITY`-style exchange, and later encrypted-looking
VDO payloads) taken with a real ChargerLAB POWER-Z KM003C against genuine Samsung
"AnyWay S103 + GH81-11962W test cable" hardware - but even the thread's own author,
with real PD-analyzer hardware and a Twonkie for replay, had only gotten a partial
response (a GOODCRC, not the expected full reply) by the last post available.
**Getting the FNB58 hardware working is necessary but not sufficient** - the actual
trigger sequence for `kona`/SM8250-class Samsung devices specifically would still
need to be determined from there (adapting that partial public capture, or
eventually sniffing a real AnyWay exchange if such hardware becomes available).

## Status

Not started. No hardware opened, no firmware written. Revisit here when picking
this back up - don't restart the Option A vs B decision, it's settled per the
owner's stated preference above.
