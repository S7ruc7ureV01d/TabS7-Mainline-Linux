# Open items (as of 2026-09-24)

A single list of everything still unfinished, gathered from the roadmap, the
scoping docs and this session's work. Each item says where it stands and the
first concrete step. Finished work is in `plans/roadmap.md` and the scoping
docs it links.

**Build state:** the kernel is fully reproducible from the repo. v7.2 plus
`kernel/patches/0002-0044` (all apply cleanly and reproduce the working tree
exactly, checked 2026-09-24), `kernel/dts/sm8250-samsung-gts7l.dts` and
`kernel/config/gts7l.fragment`. Work in progress outside the series:
`kernel/patches-wip/`. The current rootfs tarball is v12
(`docs/dev-environment-quickref.md`).

## Not started (roadmap exit criteria)

| Item | What is known | First step |
|---|---|---|
| **Suspend/resume** | In progress (`docs/phase3-suspend-scoping.md`). s2idle suspends and resumes; the SLPI crash (0026) and four drivers holding CXO in sleep (0027-0030) are fixed, and the application CPUs' RPMh sleep votes are now clean. The SoC still never reaches AOSS sleep/CX collapse (`qcom_stats` 0), so the blocker is outside Linux's own votes. | Check the display RSC and the unbooted subsystems; compare with stock Android's sleep stats. |
| **LTE modem** | Scoped 2026-09-24 (`docs/phase4-lte-modem-scoping.md`): external flashless **SDX55** on PCIe2/MHI, reset via its PMX55 PMIC (SPMI SID 8); all firmware in the `modem` partition, EFS in `mdm1m9kefs*` (backed up, not in git). No mainline support; the Xiaomi Mi 10T pmOS port (same SoC/modem, kernel 7.1) has it working with a Sahara client, esoc import and custom userspace. | Stage 1: PMX55 reset + AP2MDM GPIOs + PCIe2, see 17cb:0306 enumerate and SBL load. |
| **Cameras** | In progress (`docs/phase4-camera-scoping.md`). Rear main (Samsung S5K3M5) works in apps: CAMSS + libcamera simple pipeline/software ISP + PipeWire, 30 fps, AE/AWB, fixed focus (`gts7l-cam-focus`, `FOCUS=330`). **Proper autofocus deferred** (owner, 2026-09-23): libcamera's simple pipeline has no AF/lens control; the GT9769 actuator works (dw9768.c). Rear ultra-wide (S5K5E9) and front (S5K4HA) need new drivers. | New sensor drivers: pull the stock sensor modules (`/vendor/lib64/camera/com.qti.sensormodule.*.bin`) during the stock boot. AF: contrast AF in libcamera, then restore the `lens-focus` link. |
| **Fingerprint** | **Not feasible, parked** (2026-09-24, `docs/phase4-fingerprint-scoping.md`): Goodix GW36T1 on SPI owned by the secure world; Samsung's production kernel only handles power/reset/IRQ, image capture and matching run in a trusted app. No libfprint driver. | None. |
| **USB-C DisplayPort** | **Works** (2026-09-24, `docs/phase4-usb-dp-scoping.md`, patches 0037-0044): DP alt mode, 4 lanes (pin C), both orientations, two monitors, KDE second screen; USB device mode comes back after a monitor; a monitor attached at boot lights up, its USB hub works (UTMI clock in DP-only mode) and USB to the PC still works; CCIC reset at shutdown. Left: picture takes 7-10 s (the CCIC firmware enters/configures on its own ~9.6 s after attach); pin D (DP + USB 3) untested; **DP audio parked**: the ADSP never answers the DP AFE port start (`kernel/patches-wip/dp-audio-wip.patch`). A powered Switch-style dock gives USB 3 + charging but no DP (the CCIC refuses VDMs as a DFP sink). | Stock-boot pass: DP audio under DeX, and whether DeX drives this dock. |
| **Book Cover Keyboard** | Pogo pins, an `stm32@2a` MCU (`stm,touchpad`, `stm,keypad`) in the stock DT. Untested. | Scoping: the stock `stm32` driver and its I2C protocol. |
| **Installer ZIP, dual boot, pacman updates, "Tab Companion" app** | Phase 5 packaging, not started. | After the hardware items; see `docs/phase5-userspace-scoping.md`. |
| **Project docs** | `hardware-status.md`, `development-notes.md`, `porting-log.md`, known issues, a licensing/provenance file (roadmap end). | This file covers "known issues" in part. |

## Parked on purpose

### Ambient light sensor / auto-brightness (works 2026-09-24)

- **Sensor:** VEML3235 behind the SLPI; it streams once `pm8150_l10`
  (2.8 V, always-on, as stock) is on - `vreg_l10a_2p8` in the DTS.
- **libssc:** looked only for data type `ambient_light`; Samsung registers
  it as `ambient_light_v`. `tools/rootfs/sensors/libssc/` builds libssc
  0.4.4-1.1 with a fallback (lookup `ambient_light_v` when `ambient_light`
  isn't there). Installed on the tablet; not in rootfs v12.
- **Desktop:** Plasma 6.6+ has automatic brightness in **KWin** (not
  PowerDevil), fed by iio-sensor-proxy's `LightLevel`. With the patched
  libssc, iio-sensor-proxy reports `HasAmbientLight` and KWin shows
  "Automatic brightness: supported" for DSI-1. It's switched in **System
  Settings -> Display & Monitor** for the built-in screen. KWin only checks
  at session start, so after installing libssc a re-login/reboot is
  needed.

### Charging: what's not covered

- **PPS / up to 45 W:** stock uses a separate **PCA9468** direct charger
  (`pca9468@57`, its own IRQ/enable GPIOs) for PPS. We do fixed 9 V
  through the MAX77705 only (about 2.5 A into the battery). This would be
  a separate driver with its own safety work.
- **Hot band charge voltage:** above 42 C stock also drops the float
  voltage to 4.15 V. The mainline charger driver has no writable CV, so
  our driver instead cuts the current to 1000 mA (stock: 2750 mA).
- **No true charge-disable:** above 50 C or below 0 C we set the
  charger's minimum, 100 mA, not "off". A `charge_behaviour` or CHG_EN
  control in `max77705_charger` would allow a real stop.
- **Float voltage 4.2 V vs stock's 4.38 V:** the DT battery node has no
  `voltage-max-design-microvolt` (the boot log warns about it), so the
  charger uses 4.2 V. That is safer, but it leaves some capacity unused.
  Setting stock's 4380 mV is a DT one-liner once we're sure of it.
- **Fuel gauge temperature** reads a constant 33.5 C (not wired to the
  thermistor). Charging now uses the PM8150L ADC thermistor instead, but
  `max170xx_battery`'s own `temp` in sysfs/upower is still the fake value.

## Known quirks, left as is (documented)

| Quirk | Where |
|---|---|
| Once per boot: LPASS LPI pinctrl vote timeout (`AFE failed to vote (3)`, `-110`). The first AFE command after the ADSP comes up gets no reply; harmless because the VA macro holds the same votes. | `docs/phase3-audio-scoping.md` |
| 24-bit audio front end: S24 playback is silent and S24 capture is garbage. PipeWire is pinned to S16 for both (as stock). | same |
| Speaker left/right stays fixed to the landscape ends when rotated to portrait. It would need a small service to swap WirePlumber positions on rotation. | same |
| SLPI "Handover signaled, but it already happened" log spam, tracking the accelerometer stream. Cosmetic. | `docs/dev-environment-quickref.md` |
| `CONFIG_BOOTPARAM_SOFTLOCKUP_PANIC` is 0, so there is no panic on soft lockups. It was always 0: the old `=y` is invalid since it became an int. Set 1 if crash capture on soft lockups is wanted again. | `kernel/config/gts7l.fragment` |
| DSI PHY probe logs 4 clock WARNs (`dsi0_phy_pll_out_dsiclk already unprepared/disabled`, from PLL reparenting in `dsi_phy_driver_probe`), on every boot since at least #120. The display works. | `docs/phase4-usb3-scoping.md` (noticed in a pstore log) |
| `CONFIG_CMDLINE` still has `loglevel=15 clk_ignore_unused` from bring-up. `clk_ignore_unused` is still needed (display); `loglevel=15` could drop. The owner said to skip this for now. | `kernel/config/gts7l.fragment` |

## Housekeeping

- ~~Three config options not pinned in the fragment~~: **fixed
  2026-09-23.** A fresh defconfig plus fragment merge now reproduces the
  working `.config` exactly. The kernel currently flashed still has
  `DETECT_HUNG_TASK=y` (harmless); the next flashed build drops it, as
  the 2026-09-22 debug clean-up intended.
- **Host-side USB network:** the host's NetworkManager profile
  `gts7l-debug` (172.16.42.2) is now bound to `enp0s20f0u1`, the USB port
  used since 2026-09-23. Moving the cable back to the old port needs
  `nmcli con mod gts7l-debug connection.interface-name enp0s20f0u3`.
- **WirePlumber's saved speaker volume** was left at 0%/muted once during
  label testing (in `~/.local/state/wireplumber/default-routes`). It's
  fixed by just raising the volume in KDE; listed only in case it recurs.
