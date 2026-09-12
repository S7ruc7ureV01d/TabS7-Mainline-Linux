# Getting a live UART console on gts7l — research findings (2026-09-13)

Motivation: `/proc/last_kmsg` (the bootloader's own ring buffer, see
`kernel-boot-debugging.md`) has repeatedly lost the exact evidence needed to
diagnose the current boot blocker, because getting the tablet from "just
bounced to Download Mode" back to "in TWRP with USB enabled" takes more
reboot cycles than fit in its ~2MB before the entry of interest is
overwritten. A real hardware UART would sidestep this entirely - it would
show Linux's own `Linux version ...` banner and dmesg live, something
`last_kmsg` (bootloader-only) can never show regardless of methodology.

## Ruled out: the real Samsung "AnyWay" USB-C JIG

Modern Samsung USB-C devices need a genuine USB-PD Vendor-Defined-Message
sent by Samsung's own factory tool (**AnyWay S103** dongle + a **Type-C
test cable, part GH81-11962W**) to switch into JIG UART mode - not a simple
resistor trick. Source: XDA thread
`https://xdaforums.com/t/has-anyone-tried-the-samsung-usb-c-jig.4766565/`
(the owner pasted its full content into this session). Even people who
obtained the genuine hardware couldn't get useful output without an
authorized Samsung engineering account for the box's software, and even a
successful VDM replay in that thread (`binzmo`'s captured trace) only got a
partial reply on retry with a Twinkie clone - not confirmed working
end-to-end by anyone in that thread. **Not pursued further**: rare
service-only hardware, weeks of lead time, uncertain payoff.

## The actual mechanism, found by reading our own device's real kernel source

`references/gts7l/drivers/muic/max77705-muic.c` (Samsung's real GPL source
for this exact device) shows the JIG-UART table entry:

```c
{
	.adc		= MAX77705_UIADC_619K,
	.vbvolt		= VB_LOW,              // <-- no VBUS/charger power on this port
	.chgtyp		= CHGTYP_NO_VOLTAGE,
	.muic_switch	= COM_UART,
	.vps_name	= "JIG UART ON",
	.attached_dev	= ATTACHED_DEV_JIG_UART_ON_MUIC,
},
```

and `max77705_muic_update_adc_with_rid()` shows this "619K" identity comes
from `muic_data->ccic_info_data.ccic_evt_rid` - **the CCIC (Type-C port
controller)'s own real hardware CC-line resistance detection**, the same
class of mechanism USB-C itself defines for passive accessories (audio
adapter, debug-accessory mode). This is *not* the PD-VDM mechanism the
"AnyWay" research above is about - it's a simpler, lower-level, genuinely
resistor-based detection that the CCIC does before/without any PD
communication. This is a materially different (and much more accessible)
finding than the initial "must be PD VDM" assumption.

**Important, easy-to-get-wrong detail**: the table entry requires
`vbvolt = VB_LOW` - i.e. this specific match only fires when **no external
power is present on the USB-C port at the moment the resistor is read**.
Several people in the community threads who tried plain resistor-on-CC
tricks on other USB-C Samsung devices and failed were very likely also
supplying USB power/charging through the same port while testing, which
would push the detection into a different (or no) table entry. Also
relevant: many off-the-shelf "USB-C breakout boards" include their own
onboard CC pull resistors (for sink/source negotiation), which would
corrupt a naive external-resistor test - a **bare** breakout (just the
connector pins broken out, no onboard CC circuitry) is needed.

## Confirmed live on the physical unit right now, no new hardware

The sysfs nodes this driver exposes for manual control already exist and
are readable/writable as root from TWRP:

```sh
$ adb shell cat /sys/devices/virtual/sec/switch/uart_en
1
$ adb shell cat /sys/devices/virtual/sec/switch/uart_sel
AP
```

Both already show the "enabled, routed to AP" preference on this unit,
confirmed live during this session. **Caveat found by reading the driver
source**: `uart_sel`/`uart_en` only set a stored preference
(`pdata->uart_path`) - the actual physical switch
(`switch_to_ap_uart()` → `com_to_uart_ap()` → the real `COM_UART` register
write) only fires when `muic_data->attached_dev` is actually one of the
`JIG_UART_ON`/`JIG_UART_OFF` states, i.e. **only once the CC-resistance
detection above has actually fired**. Setting `uart_sel=AP` ahead of time is
still worth doing (so that once the physical JIG condition is detected, it
switches to AP rather than CP/modem), but it is not sufficient by itself.

## Where the switched UART signal physically appears (inferred, not yet confirmed)

`COM_UART` is the same analog-switch register value this whole MUIC driver
family has always used (going back to microUSB-era Samsung phones, where
the switched UART TX/RX appeared on the **D+/D− data lines**, not on
anything USB-C-specific like SBU1/SBU2). Since this driver reuses the exact
same `com_to_uart_ap()`/`COM_UART` mechanism unchanged from that lineage,
**D+/D− is the best inference for where TX/RX will appear on this device
too** - as opposed to Apple's or Librem 5's convention (SBU1/SBU2), which is
a different vendor's design and not what this driver does. This is
reasoning from the driver source, not yet verified against a real probe.

## Concrete next step (not yet attempted)

1. A **bare** USB-C breakout board (no onboard CC pull resistors/circuitry -
   just the pins broken out).
2. A single resistor close to 619 kΩ (the community's microUSB-era guides
   used 619-620 kΩ 1%; not yet independently re-derived from this exact
   driver's ADC threshold ranges - `MAX77705_UIADC_619K` is a named
   constant, not a raw value, in the source we have) between **CC1** and
   **GND** (try **CC2** too / flip the cable if CC1 doesn't work - Type-C's
   reversibility means only one of the two is "live" per orientation).
3. Critically: **do not supply VBUS/charging power through this same port**
   while making the connection, per the `VB_LOW` requirement above -
   power the tablet from battery only during the test.
4. From TWRP (root shell), pre-set the preference:
   `echo 1 > /sys/devices/virtual/sec/switch/uart_en` and
   `echo AP > /sys/devices/virtual/sec/switch/uart_sel` (already the
   current state, confirmed above, but worth setting explicitly).
5. Attach a normal 3.3V USB-to-TTL serial adapter's RX/TX/GND to whatever
   the breakout exposes for D+/D− and GND, 115200 baud (the standard rate
   for this ABL/kernel family per every log capture so far), and watch for
   output while power-cycling the tablet.
6. If nothing appears on D+/D-, the SBU1/SBU2 pins are the fallback thing
   to try, in case this device's actual physical routing differs from the
   inference in the previous section.

## Reference tools cloned for this research

- `references/vdmtool` (AsahiLinux) - an Arduino + FUSB302 USB-PD VDM
  injection tool. Not needed for the CC-resistance approach above, but kept
  since it's the right tool if the resistor approach fails and a real PD-VDM
  trigger turns out to be necessary after all (Samsung's `AnyWay` box is
  understood to use PD VDMs for *some* JIG modes even where CC-resistance
  detection also exists for others - not yet clear which applies here
  without testing).
