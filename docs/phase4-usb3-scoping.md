# Phase 4: USB 3 SuperSpeed (2026-09-24)

USB 3 works in both cable orientations: an HP P500 SSD enumerates at
SuperSpeed (5 Gbit/s) and reads at 229 MB/s (29 MB/s over USB 2.0).
Patch 0036, DT, config below.

## The SuperSpeed path (stock r07 DT, kona-usb.dtsi, drivers/redriver/ps5169.c)

dwc3 -> QMP combo PHY (`usb_1_qmpphy`, `qcom,sm8250-qmp-usb3-dp-phy`) ->
Parade PS5169 redriver (i2c14 = QUP SE14, gpio40/41, address 0x28) ->
USB-C connector.

- **QMP PHY**: supplies as stock: core L9A (1.2 V), PLL L18A 912 mV
  (added to our PM8150 regulator block). `CONFIG_PHY_QCOM_QMP_COMBO=y`.
- **PS5169**: enable pin TLMM gpio8 (stock `combo,redriver_en`; ABL already
  drives it high; now a gpio-hog). Chip ID 0x69/0x87 (0xad/0xac). Stock's
  WORK_MODE init at probe with the gts7l values (0x52 = 0x30,
  0x5e = 0x06); per attach 0x40 = 0xc0 (USB 3, CC1) or 0xd0 (CC2),
  0xa0 = 0x02; on detach 0x40 = 0x80, 0xa1 = 0x00. Mainline has no PS5169
  driver; the USB-C driver programs it (`maxim,usb3-redriver` phandle).
- **Orientation**: stock's `samsung,cc_dir` / `combo,con_sel` is TLMM
  gpio65, an input; it reads high for CC2, agreeing with the CCIC's
  CC_STATUS0 CCPinStat. Stock sets both the PHY lane select and the PS5169
  flip from it; our driver does both from CCPinStat, via the QMP PHY's
  typec orientation switch (`CONFIG_TYPEC=y`), found through a
  `usb-c-connector` child of the MAX77705 USB-C node (graph: HS to dwc3,
  SS to the QMP PHY).
- **gpio40-43**: the Samsung common dtsi reserves them as "Unused", but on
  this board stock drives them from Linux (the PS5169 bus; gpio42 is the
  rear ultra-wide camera's VANA). Our `gpio-reserved-ranges` keeps only
  the fingerprint SPI (20-23).

## The one crash on the way

With `maximum-speed = "super-speed"` (stock's value) the SoC reset during
boot: pstore showed a bus fault in `dwc3_readl()` from `dwc3_core_init()`,
at `DWC3_LLUCTL` (0xd024), which dwc3 only reads on DWC_usb31 cores with
maximum-speed exactly "super-speed" (to force Gen1). Mainline SM8250
boards leave maximum-speed unset; so do we now (hardware max,
super-speed-plus; the P500 links at 5 Gbit/s).

## Side effect: KDE's USB device notifications work

With the QMP PHY available and the connector graph, the root hub ports are
"hotplug" and devices `removable=removable`, so Plasma's
`devicenotifications` shows its message and plays the connect sound
(`docs/phase4-usb-host-scoping.md`).

## Not done

- DisplayPort alt mode (VDM discovery, SET_ALTERNATEMODE bit 1, the PS5169
  DP modes, the QMP PHY's DP half, MDSS DP controller).
