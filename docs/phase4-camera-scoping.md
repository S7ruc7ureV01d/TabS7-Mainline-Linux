# Phase 4 scoping: cameras (front/rear via V4L2)

Recon pass done 2026-09-23. Starting point: nothing. The roadmap line
(`plans/roadmap.md`, Phase 4: "Cameras (front/rear) working via V4L2, to
whatever extent the ISP allows") had no research behind it. Method as in
the earlier passes: identify the real chips first, check mainline for
drivers before assuming a port, search for prior art, and say plainly
where it is big. Nothing here has been built or tested; this is research.

## The headline: tractable, and the main rear camera is nearly free

1. **The sensors are identified**, from real hardware: the stock boot
   logs already in this repo (`docs/logs/stock-boot-2026-09-22/01-*` and
   `09-*`) contain the downstream driver's probe lines, with chip IDs read
   over CCI. No live capture needed.
2. **Mainline has the whole Qualcomm side for SM8250**: CAMSS
   (`qcom,sm8250-camss`, CSIPHY + CSID gen2 + VFE 480), CCI
   (`qcom,sm8250-cci`), the camera clock controller (`camcc-sm8250`), and
   all three nodes in `sm8250.dtsi`. There is an in-tree SM8250 board using
   them: `qrb5165-rb5-vision-mezzanine.dtso` (RB5 with an IMX577).
3. **The main rear sensor already has a mainline driver**:
   `drivers/media/i2c/s5k3m5.c` (Linaro, 2025, written for the SM8550
   HDK/QRD), same chip ID. The other two sensors have no driver anywhere
   that a search found; they are the real work.

So the order question ("sensor first, or CAMSS maturity first?") answered
itself quickly: both were cheap to check, and both came back positive.

## The sensors

From the stock probe (`cam_sensor_match_id ... read id`):

| Slot | Position | Chip ID | Chip | Mainline driver |
|---|---|---|---|---|
| 0 | rear, main (13 MP) | 0x30d5 | Samsung **S5K3M5** (techpack `SENSOR_ID_S5K3M5 0x30D5`) | **yes**: `s5k3m5.c` |
| 2 | rear, second (5 MP) | 0x559b | Samsung **S5K5E9** | no |
| 1 (and 12) | front (8 MP) | 0x48ab | Samsung **S5K4HA** (the techpack carries `cam_sensor_adaptive_mipi_s5k4ha.h`) | no |

Slot 12 is the same front sensor probed a second time (same CCI master,
address and GPIOs as slot 1); downstream uses it as an alias.

The downstream techpack (`references/gts7l/techpack/camera`) is Samsung's
shared camera stack for many devices (it names IMX555, S5KGW2, ... from
other phones), so its sensor lists don't identify our hardware; the probe
log does. The actual sensor register tables are **not in the kernel**
downstream: they live in stock userspace, in the camera HAL's sensor
modules (`/vendor/lib64/camera/com.qti.sensormodule.*.bin`). The techpack
only has MIPI-rate fragments (the adaptive-MIPI setfiles).

## Board wiring (downstream DT, `kona-sec-gts7l-eur-overlay-r07.dts`)

r07 matches our unit (`androidboot.revision=7`,
`docs/devicetree-notes.md`). All GPIOs are TLMM (`__fixups__`); the
sensors' only "regulator" is the Titan top GDSC. The rails are
GPIO-switched external LDOs, so in mainline they become `regulator-fixed`
nodes with an enable GPIO.

| | Rear main (S5K3M5) | Rear second (S5K5E9) | Front (S5K4HA) |
|---|---|---|---|
| CCI bus | CCI0 (`ac4f000`) | **CCI1** (`ac50000`) | CCI0 |
| CCI master | 0 | 0 | 1 |
| I2C address (7-bit) | 0x2d (8-bit 0x5a) | 0x10 (8-bit 0x20) | 0x2d (8-bit 0x5a) |
| CSIPHY | 0 | 2 | 3 |
| MCLK | MCLK0, gpio94 | MCLK1, gpio95 | MCLK2, gpio96 |
| Reset | gpio73 | gpio78 | gpio30 |
| VANA enable | gpio39 | gpio42 | gpio38 |
| VIO enable | gpio37 (shared) | gpio37 | gpio37 |
| Extras | actuator, EEPROM, flash | EEPROM | EEPROM |

- **Autofocus actuator** (rear main): `qcom,actuator@18`, CCI1 master 1,
  8-bit address 0x18 (7-bit 0x0c), VAF enable gpio39 (the same GPIO as
  the rear main's VANA). Chip unknown; 0x0c is the usual address of
  DW9714/DW9718-class VCM drivers, several of which are in mainline.
- **EEPROMs** (module OTP/calibration): `qcom,eeprom@0` at 8-bit 0xb0 on
  CCI1. Only needed for lens-shading/AF calibration, not for a picture.
- **Flash/torch**: `qcom,camera-flash0` using PMIC flash channels. That's
  the PM8150L flash block, which mainline `leds-qcom-flash` supports.
- **MCLK rate**: stock runs 19.2 MHz (`clock-rates = 0x124f800`). The
  mainline `s5k3m5.c` wants **24 MHz** (its PLL settings assume it). The
  SM8250 camcc MCLK table has both 19.2 and 24 MHz, so 24 MHz is fine.
- **Data lanes**: downstream keeps lane config in the userspace sensor
  module, not the DT. `s5k3m5.c` requires 4 lanes; CSIPHY0 on SM8250 is a
  4-lane-capable combo PHY. The S5K5E9 is typically 2-lane.
- **Gotcha: gpio42 is reserved.** Upstream `sm8250-samsung-common.dtsi`
  has `gpio-reserved-ranges = <20 4>, <40 4>` ("Unused"), which covers
  gpio42, the rear-second VANA. Our DTS has to override the range.

## Kernel config and boot image

The whole media stack is currently `=m`: `VIDEO_QCOM_CAMSS`,
`I2C_QCOM_CCI`, `SM_CAMCC_8250`, `VIDEO_DEV`, `MEDIA_SUPPORT`,
`V4L2_FWNODE`; `VIDEO_S5K3M5` isn't set. **The rootfs has no modules
installed** (`/lib/modules/7.2.0-dirty` doesn't exist), so none of it can
ever load. Either build these `=y` or start installing modules; `=y`
matches how this project has run so far.

Side benefit: camcc `=y` makes camcc bind, which also removes one of the
reasons `rpmhpd` never ran `sync_state()` on its own
(`docs/phase3-suspend-scoping.md`).

Boot partition headroom is fine: with the current kernel (including the
debug-only FTRACE, +5.4 MB), kernel + DTB + ramdisk total 56.5 MB of the
71.3 MB partition, about **14.8 MB free**.

## How relevant is the S9 Ultra project?

`references/ubuntu-galaxy-tab-s9-ultra/` (SM8550, SK Hynix Hi-847):

- **Userspace, directly relevant.** Mainline CAMSS gives raw Bayer frames
  only (no Qualcomm ISP processing: CAMSS drives CSIPHY/CSID/VFE-RDI, not
  the IFE's image pipeline), exactly as on SM8550. The S9U path, libcamera's
  `simple` pipeline plus the software ISP (GPU debayer), PipeWire, V4L2
  relays for legacy apps, stable `/dev/v4l/by-id` aliases (which also
  sidestep a real Ubuntu OBS crash), carries over nearly unchanged,
  including their full-field-of-view softISP patch
  (`docs/camera-gpu-full-field.md`). Their packaging is for Ubuntu; this
  project's rootfs is Arch Linux ARM, so the recipes need translating, not
  copying.
- **Kernel, methodology only.** Different sensor vendor (Hynix vs
  Samsung) and a different CAMSS generation (SM8550 CSID 680/VFE 780 vs
  our CSID gen2/VFE 480, though the same driver). Their
  `hi847-libcamera-compliance.patch` is the useful precedent for what
  libcamera needs from a sensor driver (controls, crop/selection
  rectangles, and so on). We'll likely need the same kind of patch for
  `s5k3m5.c` (for example, its `get_selection` reports
  `height = mode->width`, `s5k3m5.c:1055`, which looks like a typo).
- **Autofocus**: their AF work is a userspace algorithm over a VCM
  control. It becomes relevant once our actuator is identified and driven.

## Plan (staged, cheapest first)

**Stage 0: config.** Build the media stack, CAMSS, CCI, camcc and
`VIDEO_S5K3M5` `=y`. Drop the debug FTRACE first if space ever gets tight.
No hardware risk.

**Stage 1: talk to the rear main sensor.** DTS: enable `&camcc`,
`&cci0`, `&camss`; add three `regulator-fixed` rails (VANA gpio39, VIO
gpio37, plus a placeholder for VDIG if the stock capture shows one), MCLK0
pinctrl on gpio94, reset gpio73; an `s5k3m5` node on CCI0 master 0 at
0x2d with a 4-lane endpoint to CSIPHY0 and a 24 MHz MCLK. Success: the
driver reads chip ID 0x30d5. Very low risk; just I2C reads.

**Stage 2: raw frames.** Link the sensor to CSIPHY0 → CSID → VFE RDI with
`media-ctl`, capture 10-bit Bayer at 2104×1184 with `yavta` or
`v4l2-ctl`, look at a debayered frame. This is where CAMSS on SM8250
actually gets proven on this board.

**Stage 3: usable camera.** libcamera `simple` pipeline + softISP, then
PipeWire and the KDE camera portal, following S9U.

**Stage 4: the other two sensors.** New `s5k5e9` and `s5k4ha` drivers,
modelled on `s5k3m5.c`. Register sequences: from the stock sensor modules
(pull `/vendor/lib64/camera/com.qti.sensormodule.*.bin` during the
planned stock boot), plus the techpack's MIPI-rate fragments. This is
the only genuinely large part: roughly 1,000 lines of driver per sensor,
most of it register tables.

**Stage 5: extras.** AF actuator (identify the chip, likely a mainline
VCM driver), torch/flash via `leds-qcom-flash` (the only piece with a
safety angle: keep flash current and timeout at stock's limits), EEPROM
calibration (optional).

## To grab during the stock boot (planned anyway for the suspend work)

- `/vendor/lib64/camera/com.qti.sensormodule.*.bin` and
  `/vendor/lib64/camera/*sensor*`, for Stage 4 register tables, lane
  counts and link frequencies.
- `dmesg` and `logcat` while opening each camera: CSIPHY lane masks and
  data rates, MCLK rate per sensor, actuator probe, flash current limits.
- `/sys/class/camera/*` (Samsung's sysfs: sensor IDs, module info).
- Regulator states with a camera open (whether any PMIC LDO feeds the
  sensors besides the GPIO rails).

## Open questions

- Is there a separate VDIG (core) rail, or does one of the GPIO LDOs feed
  it? The downstream power sequence lists only VANA and VIO.
- Which actuator chip sits at 0x0c?
- Does the rear main module really use 4 lanes on CSIPHY0? (`s5k3m5.c`
  refuses anything else.)
- Whether libcamera's simple pipeline handles CAMSS on SM8250 as well as
  on SM8550 (it should: same driver, same RDI-only model).

Sources for the online prior-art search (none found for S5K4HA or
S5K5E9; recent Samsung sensor submissions such as the S5KJN5 are useful
templates):
[S5KJN5 v3 series](https://ratatoskr.run/linux-devicetree/2026/08/17373982/t),
[S5KJN5 v2 series](https://ratatoskr.run/linux-devicetree/2026/07/17314141/t),
[S5K4E5 driver (older precedent)](https://patchwork.kernel.org/patch/3064871/).
