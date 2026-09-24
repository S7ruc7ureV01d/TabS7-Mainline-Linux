# Phase 4: USB host / OTG (2026-09-23)

USB keyboards and USB storage work through the USB-C port (USB 2.0 High
Speed). Patches 0034 and 0035, DT and config below.

## How it works

The MAX77705's USB-C firmware does the Type-C work itself; the driver
(`max77705_usbc_ilim.c`, patch 0034) only reacts to the CC state in
`CC_STATUS0` (CCStat bits 2:0: 0 none, 1 sink, 2 source):

- **Source role enable**: after reset the firmware only sinks. OPCODE
  `SET_ALTERNATEMODE` (0x55) with bit 0 (SRCCAP) lets it toggle as a
  dual-role port; an attached device (Rd) then shows as CCStat = 2. Stock
  sends 0x3 at boot (bit 1 adds VDM alt-mode discovery, for DP/DeX; not
  needed here). Found by logging CC_STATUS0 with an OTG adapter: before the
  command only CCPinStat changed, after it CCStat went to 2.
- **VBUS**: the charger's OTG boost, `CHG_CNFG_00` OTG|BOOST (0x5 -> 0xf,
  stock's mode 0xf), never switched on while VBUS is already present. The
  mainline charger writes the MODE field only at probe, so nothing fights
  over it. OTG current limit 1.5 A (the boost's maximum, `CHG_CNFG_02`
  bits 7:6 = 3): at the charger's 900 mA an HP P500 SSD's start-up current
  pulled VBUS down until the CC logic saw a detach, and it never enumerated.
- **D+/D- switch**: the firmware's CONTROL1 (opcode 0x06; COMN1SW bits 2:0,
  COMP2SW bits 5:3) resets to 0x00, open and following BC1.2 detection,
  which only runs when we sink. As a source the data lines stayed
  disconnected; devices enumerated only when a PC connection had just left
  the switch on USB (it first looked orientation-dependent). Set to COM_USB
  (0x09) while sourcing, as stock does for OTG, and back to 0x00 after.
- **Data role**: the driver registers an extcon (EXTCON_USB,
  EXTCON_USB_HOST): source = host, sink with VBUS (PC, charger) = device.
  `&usb_1` (dwc3-qcom-legacy glue, VBUS override) and `&usb_1_dwc3`
  (`dr_mode = "otg"`) follow it. USB networking to a PC keeps working.
- While sourcing, the input-current logic stands down (VBUS is our own).

## Mainline charger bugs found (patch 0035)

- `max77705_aicl_irq()` loops lowering CHGIN_LIM until AICL reports OK. In
  OTG boost that never happens, so the loop never ended, in the MAX77705's
  nested interrupt thread: every later MAX77705 interrupt (detach, charger,
  fuel gauge) was lost. Found as `irq/171-max77705` stuck in D state in
  `max77705_aicl_irq`. Now ignored in OTG boost, and the loop stops at the
  lowest limit.
- `online` came from CHGIN_OK, which our own boost sets: upower saw line
  power, and KDE played its charger sound for every USB device. Now offline
  in OTG boost.

## Result

- USB keyboard (low speed HID): works, either plug orientation, re-plug OK.
- HP P500 SSD (C-to-C cable): enumerates (usb-storage), KDE storage
  notification; raw read 29 MB/s (USB 2.0 High Speed ceiling).
- Detach/attach cycles handled; device mode to a PC unchanged.

## Not done yet

- **USB 3 SuperSpeed**: needs the QMP combo PHY (`usb_1_qmpphy`) enabled
  and wired, plus orientation (stock: `samsung,cc_dir` input gpio65 read by
  dwc3-msm) and the PS5169 redriver (`ps5169@28`, `combo,con_sel`,
  `combo,redriver_en`).
- **KDE's generic "USB device connected" sound/notification**: Plasma's
  `devicenotifications` skips devices with sysfs `removable=fixed`. Ours are
  "fixed" because the root hub's OF graph port 1 (dwc3 `port@1`) leads to
  the disabled QMP PHY, so `usb_of_get_connect_type()` returns "not used".
  Fixed naturally by the USB 3 work (QMP PHY enabled + a `usb-c-connector`
  node, as mainline boards do).
- DisplayPort alt mode (needs VDM, SET_ALTERNATEMODE bit 1).

## Testing tips

With the port in host mode there is no USB networking: use ssh over Wi-Fi.
The tablet's Wi-Fi address changes every boot (DHCP), and the PC's ARP entry
goes stale: run `ping -i 2 <pc>` on the tablet to keep it fresh.
`/root/cclog.sh`, `/root/otglog.sh` (on the tablet during this work) log
CC_STATUS0, VBUS ADC, CHG_CNFG_00 and xHCI PORTSC.
