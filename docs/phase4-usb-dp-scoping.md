# Phase 4: DisplayPort over USB-C (2026-09-24)

DP alt mode works: two different USB-C portable monitors show a picture
in both cable orientations, KDE detects them as a second screen, and USB
device mode (ssh over the cable) comes back after unplugging.
Patches 0037 (USB-C driver) and 0038 (msm DP mode filter), plus DT.

## The path

MDSS DP controller (`mdss_dp`, 4 lanes) -> QMP combo PHY DP half
(`usb_1_qmpphy`, `mode-switch`) -> PS5169 redriver -> USB-C connector.
AUX runs on the SBU pins through a separate analog switch. HPD comes
from the CCIC as a VDM, not from a pin, so the DRM bridge chain ends in
a `drm_aux_hpd` bridge on the `usb-c-connector` node that the USB-C
driver notifies.

## What the CCIC firmware does, and what it leaves to the AP

The MAX77705 firmware runs PD itself. With SET_ALTERNATEMODE (0x55)
= SRCCAP | VDM it runs Discover Identity, SVIDs and Modes and reports each
one through VDM_INT (0x05); the answers are read with VDM_GET_RESP
(0x4b). Both monitors report the DP SVID 0xff01 plus Samsung's 0x04e8,
and **pin assignment C only** (`pins 0x04`: 4 DP lanes, no USB 3).

The firmware does **not** enter DP mode on its own. Stock's
`max77705_alternate.c` sends Enter Mode from the AP; we do too, with
VDM_SET_REQ (0x48, header 0xff018104). Findings on the way:

- `max77705_opcode()` had a 2-byte buffer and rejected every multi-byte
  VDM with -EINVAL. None of the requests left the kernel until it took
  the full opcode length.
- The 0x48 reply only arrives after the partner answers, so it's polled
  for up to 1 s, and a timeout is not an error.
- Enter Mode sent straight at Discover Modes is lost, because the
  firmware is still discovering the Samsung SVID. It's now sent **1.5 s
  later** from delayed work.
- After Enter Mode the firmware runs DP Status and Configure itself.
  The driver switches the data path on the Configure ACK (PD_INT bit3),
  and sends Configure itself only as a fallback.
- HPD comes from Attention (PD_INT bit4) / DP Status VDOs, bit 7. Seen:
  `0x8a` = UFP_D connected, enabled, HPD high.

## Data path switching (on Configure ACK)

1. `typec_mux_set()` on the QMP PHY: TYPEC_DP_STATE_C/E means 4 DP lanes,
   D means 2 DP lanes + USB 3. The PHY's `mode-switch` DT property is
   what registers the mux.
2. PS5169 0x40 = 0xa0/0xb0 (DP 4 lanes, CC1/CC2) or 0xe0/0xf0 (DP + USB),
   plus 0xa0 = 0x00, 0xa1 = 0x04 (values from stock ps5169.c).
3. **The SBU/AUX switch**: without it every DPCD read timed out (-110).
   Stock `kona-sec-gts7l` uses `dp,aux_en` = TLMM gpio10 (active low)
   and `dp,aux_sel` = gpio47 (0 = CC1, 1 = CC2), with the pull-ups
   powered from L2A (3.1 V). In DT these are `dp-aux-en-gpios`,
   `dp-aux-sel-gpios` and `dp-aux-pullup-supply` on the USB-C node, with
   the `dp_aux_sw` pinctrl state. sel is set, then after 100 us en.

On detach, or on a later non-DP attach, the PHY goes back to USB mode.
The QMP PHY drops that switch with "DP PHY is still in use, delaying
switch" while the DP side is still powered. Before the fix, device mode
stayed dead (UDC "not attached") after unplugging a monitor. Every
non-DP attach now re-asserts USB mode.

## The garbled 1366x768 picture (0038)

The monitors' preferred 1366x768 came out sheared, tilted and
blinking; 1360x768 and 1280x720 were clean. SM8250 DP uses the wide bus
(2 pixels per clock), and a width that isn't a multiple of 4 breaks
it. `msm_dp_bridge_mode_valid()` now rejects such modes when the wide bus
is on, and KDE picks 1360x768.

## Timing

A picture appears about **7-10 s** after plugging in. From one log:
attach 224.7 s, Discover Modes 225.2, our Enter 226.7 (+1.5 s delay),
Configure ACK 233.9, HPD 235.1. Most of it is the firmware's ~7 s gap
between Enter and its own Status/Configure. A possible speed-up is to
send DP Status/Configure ourselves right after Enter ACK instead of
waiting for the firmware. Not done yet.

## Don't

**Don't read `/sys/kernel/debug/dri/0/DP-1/*`** while DP is up.
`msm_dp_test_active_show` dereferences NULL (a mainline bug) and the
tablet resets.

## Not covered

- Pin assignment D (DP + USB 3 at once): coded, but untested; neither
  monitor offers it. A dock would test it.
- Audio over DP: not looked at.
- Tool: `tools/rootfs/usb/vdmprobe.sh` is the read-only discovery probe
  used at the start. It enables VDM discovery from userspace
  (i2c-tools) and dumps the firmware's Discover Identity/SVIDs/Modes
  answers. It sends no Enter/Configure. Don't run it while the driver is
  bound and a partner is attached.
