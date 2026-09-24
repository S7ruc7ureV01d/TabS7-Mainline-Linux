# Phase 4: DisplayPort over USB-C (2026-09-24)

DP alt mode works: two different USB-C portable monitors show a picture
in both cable orientations, KDE detects them as a second screen, and USB
device mode (ssh over the cable) comes back after unplugging.
Patches 0037 (USB-C driver) and 0038 (msm DP mode filter), plus DT;
0039 (QMP PHY) and 0040 (USB-C driver follow-ups) fix USB after DP;
0041 (QMP PHY) and 0042 (aux-hpd bridge) fix booting with a monitor
attached.

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

## USB after a DP session (0039, 0040)

Unplugging the monitor and plugging in the PC left USB device mode dead
(UDC "not attached", the PC saw nothing). Three layers:

1. **The switch back was dropped.** `qmp_combo_typec_mux_set()` refuses
   to leave DP mode while the DP PHY is powered ("DP PHY is still in use,
   delaying switch"), returns 0, and nothing ever retries. 0039 records
   the mode and applies it from `qmp_combo_dp_power_off()`.
2. **The USB PCS didn't come up** in that switch while dwc3 was changing
   role: "phy initialization timed-out" on 5 tries over 330 ms. A few
   minutes later PCS_STATUS1 showed PHYSTATUS clear on its own. 0039
   retries, then marks the USB PHY stale and redoes the full re-init on
   the next orientation set (every attach).
3. **dwc3 gave up for good.** At the detach it switched to device mode
   ~0.2 s after the monitor left, while the PHY was down, and failed
   ("failed to enable ep0out"); nothing re-inits it later. 0040 keeps
   dwc3 in host mode after a DP session until the next attach. With that,
   the delayed switch succeeds on the first try and the PC attach is a
   fresh host -> device switch.

Also in 0039: `qmp_combo_usb_power_on()`'s timeout path disabled the
pipe clock, which belongs to com_init/com_exit since 7.2
("gcc_usb3_prim_phy_pipe_clk already disabled" warning). The same fix is
in the Retroid Pocket 5 (SM8250) pocknix tree.

Tried on the way and kept: `snps,dis_u3_susphy_quirk` on `&usb_1_dwc3`
(GUSB3PIPECTL SUSPHY was set while the switch failed). It did **not** fix
the timeout by itself; it's harmless but unproven, and could be dropped
if idle power matters.

A rebind of dwc3 (`/sys/bus/platform/drivers/dwc3/{un,}bind`) plus
re-attaching the gadget UDC and a replug was the manual recovery before
0040.

## Booting with the monitor attached (0041, 0042, gadget)

Three separate failures when the monitor was on the port from power-on:

1. **No picture:** the USB-C driver reported HPD high at 11.4 s, but msm
   DP only binds at ~21.5 s. `drm_aux_hpd_bridge_notify()` ->
   `drm_bridge_hpd_notify()` dropped the event (no `hpd_cb` yet), and
   the connector stayed "disconnected". 0042 makes the aux-hpd bridge
   remember the last state and replay "connected" from a work item when
   the connector enables HPD.
2. **dwc3 failed to probe** ("failed to initialize core", -110): the mux
   was already DP-only, and `qmp_combo_usb_init()` powered the USB side
   on anyway, which times out in DP-only mode. 0041, as pocknix's
   RP5 patches: no USB power on/off in DP-only mode (usb_init/exit and
   the orientation switch), and `usb_init_count` kept across the switch.
3. **No USB network after the monitor:** the ECM gadget binds its UDC at
   boot. In host mode (or before dwc3 has registered the UDC) the bind
   fails, and nothing retried. `usb-gadget-ecm-wait.service` now retries
   until the port reaches device mode (`tools/rootfs/usb/gadget/`).

Unrelated but found in the same boot: the swap service's ordering cycle
(see `docs/dev-environment-quickref.md`, rootfs v12), which once took out
Wi-Fi and the gadget.

## Robustness bits (0040)

- Enter Mode is resent up to 3 times, 2.5 s apart, until an Enter ACK or
  a DP Attention shows the partner is in DP mode.
- One boot showed the partner's Attention with "enabled" (`0x1a`, then
  `0x8a` HPD high) but never the Configure ACK: an enabled Attention now
  counts as configured.
- **Shutdown reset:** the CCIC runs from the battery and keeps its state
  across a reboot. Like stock `max77705_usbc_shutdown()`, the driver's
  `.shutdown` turns the VBUS boost off, clears the AUX switch and the
  PS5169, masks the interrupts and resets the firmware (register 0x80 =
  0x0f, then 100 ms). Writing that by hand while running also works but
  leaves the driver deaf (masks and SET_ALTERNATEMODE are reset) until
  the next boot.

## The garbled 1366x768 picture (0038)

The monitors' preferred 1366x768 came out sheared, tilted and
blinking; 1360x768 and 1280x720 were clean. SM8250 DP uses the wide bus
(2 pixels per clock), and a width that isn't a multiple of 4 breaks
it. `msm_dp_bridge_mode_valid()` now rejects such modes when the wide bus
is on, and KDE picks 1360x768.

## Timing

A picture appears about **7-10 s** after plugging in. From one log:
attach 224.7 s, Discover Modes 225.2, our Enter 226.7 (+1.5 s delay),
Configure ACK 233.9, HPD 235.1.

With every event logged (2026-09-24): attach 126.15, Discover Modes
126.77, Enter 128.29 and 132.04 (resend), **no Enter ACK, no DP Status
event, and no reply to either 0x48 request**, then Configure ACK 135.81
and HPD 137.03. So the firmware seems to enter and configure on its own
schedule, ~9.6 s after attach, and our Enter may not be what triggers
it. Stock sends Enter straight from the Discover Modes handler (queued
behind its other opcodes); sent at once here it collided with the
firmware's Samsung-SVID discovery. Speeding it up needs experiments
(e.g. queueing Enter like stock, or SET_ALTERNATEMODE variants); parked.

## Don't

**Don't read `/sys/kernel/debug/dri/0/DP-1/*`** while DP is up.
`msm_dp_test_active_show` dereferences NULL (a mainline bug) and the
tablet resets.

## Not covered

- Pin assignment D (DP + USB 3 at once): coded, but untested; neither
  monitor offers it. A dock would test it.
- **Audio over DP: attempted, parked** (`kernel/patches-wip/dp-audio-wip.patch`,
  not in the series). The pieces exist in mainline: `mdss_dp` is a
  sound DAI (hdmi-codec via `dp_audio_prepare`), q6afe has
  `DISPLAY_PORT_RX` (AFE port 0x6020), `sm8250.c` sets up the DP0 jack.
  With a MultiMedia3 front end, the DP back-end link and a UCM "HDMI1"
  device:
  - PipeWire probes every PCM of the verb (open + hw_params + prepare).
    The DP port start then hangs 3 s in the ADSP and fails, and one failed
    mapping drops the whole profile: **the speakers vanished**. Never ship
    a UCM DP device before the port can start.
  - Deferring the AFE port start from prepare to trigger (after the DP
    codec's prepare enabled its audio engine), sending the downstream
    `AFE_PARAM_ID_HDMI_DP_MST_VID_IDX_CFG` / `_DPTX_IDX_CFG` (0/0), and a
    no-op DP prepare without a monitor: the params and the HDMI config
    are accepted, but **`AFE_PORT_CMD_DEVICE_START` is never answered**
    (-110), even with the monitor up and `msm_dp_audio_prepare` run.
  - The stock DP audio path (sde `dp_audio.c`, `msm-dai-q6-hdmi-v2.c`)
    does the same register setup and the same config. Stock also sends an
    AFE topology, calibration and HW delay before the start, which
    mainline never does for any port.
  - Next: in the stock-boot pass, play audio to the monitor under DeX and
    capture the AFE/ext-disp sequence (kernel log with audio debug,
    `tinymix` state of the "Display Port" controls).
- Tool: `tools/rootfs/usb/vdmprobe.sh` is the read-only discovery probe
  used at the start. It enables VDM discovery from userspace
  (i2c-tools) and dumps the firmware's Discover Identity/SVIDs/Modes
  answers. It sends no Enter/Configure. Don't run it while the driver is
  bound and a partner is attached.
