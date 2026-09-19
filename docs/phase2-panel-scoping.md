# Phase 2 scoping: the gts7l LCD panel (NT36523 / PPA957DB1)

Recon pass before starting real Phase 2 (display + input) work, done
2026-09-19 right after Phase 1 completed (`docs/kernel-boot-debugging.md`
Rounds 30-37). Goal: find out how much of the panel bring-up is genuinely
new work versus reusable from mainline/other devices, before touching
any real display hardware sequencing. Nothing here has been built or
tested yet - this is pure research, recorded for when that work starts.

## Headline finding: a mainline driver for this exact chip family already
exists, used on a directly comparable SM8250 tablet

`drivers/gpu/drm/panel/panel-novatek-nt36523.c` (in our own vendored
`work/linux` tree already) already supports three devices' NT36523
panels: Lenovo J606F (`lenovo,j606f-boe-nt36523w`), and - most
importantly - the **Xiaomi Mi Pad 5 Pro / "elish"**
(`xiaomi,elish-boe-nt36523`, `xiaomi,elish-csot-nt36523`). Elish is a
mainline-merged **SM8250 tablet** (same SoC as gts7l) with dual-DSI,
C-PHY, a 2560x1600-class LCD panel, working DRM/KMS, and a real
devicetree (`arch/arm64/boot/dts/qcom/sm8250-xiaomi-elish-common.dtsi` +
`-boe.dts`/`-csot.dts`). This is a far closer, more directly reusable
reference than the S9 Ultra project (a phone, AMOLED, command-mode
panel, different SoC generation-adjacent quirks) that earlier rounds of
this project leaned on.

The driver's own init sequences (`elish_boe_init_sequence()` etc. in
that file) are literally just the vendor's undocumented DCS register
dump, ported over verbatim from Xiaomi's downstream kernel - the exact
same technique this project has already used repeatedly (sec_log_buf,
reserved-memory carveouts, etc.): find the downstream driver, extract
its raw sequence, re-express it as `mipi_dsi_dcs_write_seq()`/
`mipi_dsi_dual_dcs_write_seq_multi()` calls in the mainline driver's own
idiom, and register a new `compatible` string. This is squarely the
correct approach here too, since our panel is likely a **new
`of_match` entry in this same file**, not a new driver from scratch.

## Our panel, identified directly from Samsung's own GPL source

`references/gts7l/techpack/display/msm/samsung/NT36523_PPA957DB1/` is a
complete downstream Samsung DSI panel driver package for this exact
device (the dtsi's own comment literally says "TABS7 does not support
MULTI_RESOLUTION, only WQXGA" - device-specific, not a shared file).
Contents:

- `dsi_panel_NT36523_PPA957DB1_wqxga_video.dtsi` (616 lines) - the full
  devicetree fragment: timings, on/off command sequences, ESD check
  config, DFPS list.
- `ss_dsi_panel_NT36523_PPA957DB1.c`/`.h` - Samsung's own panel glue
  driver (much thinner than the dtsi; most of the actual sequencing
  lives in the dtsi's DCS command arrays on this downstream stack).
- `ss_dsi_mdnie_NT36523_PPA957DB1.h` - mDNIE (Samsung's color/tone
  mapping IP) tables - irrelevant to mainline, that block doesn't exist
  upstream.
- `isl98608_hw_i2c.c` - a separate I2C driver for the panel's
  bias/boost IC (**not** the backlight itself - see below).

### Key facts extracted

| Property | Value | Source |
|---|---|---|
| Driver IC | Novatek NT36523 | `samsung,disp-model = "PPA957DB1"`, filename |
| Panel vendor | CST | `samsung,panel-vendor = "CST"` |
| DSI mode | **video mode** (not command mode) | `qcom,mdss-dsi-panel-type = "dsi_video_mode"` |
| Link topology | **dual-DSI**, split horizontally | `qcom,mdss-dsi-panel-width = <800>; // 1600/2` comment, `qcom,display-topology = <2 0 2>` |
| PHY type | **C-PHY** | `qcom,panel-cphy-mode` |
| Physical size | 148mm x 236mm | `qcom,mdss-pan-physical-{width,height}-dimension` |
| Native framerate | 120Hz (DFPS list 120/96/60/48) | `qcom,mdss-dsi-panel-framerate`, `qcom,dsi-supported-dfps-list` |
| Porches | h: pulse=2 back=30 front=84 skew=0; v: pulse=1 back=7 front=26 | `qcom,mdss-dsi-{h,v}-*` |
| Backlight control | **DCS-based** (`bl_ctrl_dcs`), range 4-462 | `qcom,mdss-dsi-bl-{min,max}-level` |
| Reset pulse | low 12ms, high 12ms, low 12ms, high 12ms | `qcom,mdss-dsi-reset-sequence = <0 12>, <1 12>, <0 12>, <1 12>` |
| Reset GPIO | GPIO 82 | `kona-sec-gts7l-eur-overlay-r07.dts` fragment@152, `qcom,platform-reset-gpio = <... 0x52 0x0>` (0x52 = 82) |
| Bias/boost IC | Intersil ISL98608 (`isl98608,display_buck`) at I2C addr `0x29` | overlay fragment@156 |
| Panel 1.8V rail | fixed regulator "lcd-vdd", enable GPIO 135 (0x87) | overlay fragment@155 |
| Panel buck enable | fixed regulator "lcd-buck", enable GPIO 93 (0x5d) | overlay fragment@155 |

**Video mode confirmation matters directly**: this independently confirms
Round 35's diagnosis in `docs/kernel-boot-debugging.md` (the `dispcc`
PLL-reprogram bug that blanked the screen) - a video-mode panel has no
internal frame memory and needs continuous active DSI streaming, exactly
why that bug manifested as an *immediate* blank rather than a delayed
one.

**Backlight is simpler than Xiaomi's elish**: elish uses an external I2C
backlight/bias combo chip (Kinetic KTZ8866, one chip does both). Ours
splits the two roles - actual brightness dimming is DCS commands sent to
the panel itself (`bl_ctrl_dcs`), while ISL98608 is a separate
"display_buck" purely for the AVDD/AVEE analog bias rails the LCD cell
needs, not brightness. This likely means the mainline `nt36523` driver's
existing `has_dcs_backlight` field (already present in `struct
panel_desc` - see `panel-novatek-nt36523.c`) already covers our backlight
path with zero new code, and only the ISL98608 bias IC needs a small new
driver or a `regulator-fixed`-equivalent if it turns out to just need
on/off rather than genuine register programming - `isl98608_hw_i2c.c` is
short (183 lines) and worth reading in full when that work starts.

**I2C bus for ISL98608 is bit-banged, not a real controller instance**: a
neighboring bus in the same overlay uses `compatible = "i2c-gpio"` on
raw GPIO pins - the display_buck fragment's own bus target wasn't fully
resolved in the decompiled overlay (symbolic reference lost in this
already-compiled dts), so the exact SDA/SCL pins for *this specific*
i2c-gpio instance need re-confirming from the live device
(`/sys/kernel/debug/gpio`, same technique Round 1-era hardware-inventory
work already used successfully for the volume key wiring) before writing
any devicetree for it.

## What's genuinely new work vs. reusable

**Reusable almost as-is** (already correct in mainline, matches this
device's SoC generation):
- `drivers/gpu/drm/panel/panel-novatek-nt36523.c`'s entire probe/attach/
  DSI-transfer/backlight plumbing - only need a new `panel_desc` entry
  + `of_match` compatible string.
- `sm8250-xiaomi-elish-common.dtsi`'s `&mdss`/`&mdss_dsi0`/`&mdss_dsi1`
  wiring pattern (dual-DSI, C-PHY, `qcom,sync-dual-dsi`/
  `qcom,master-dsi`) - direct template, same SoC, same panel class.

**New work, but mechanical** (same extraction technique used throughout
this project so far):
- Port the actual DCS init/on/off command sequences from
  `dsi_panel_NT36523_PPA957DB1_wqxga_video.dtsi`'s
  `samsung,*_tx_cmds_revA` arrays into `mipi_dsi_dual_dcs_write_seq_multi()`
  calls in the mainline driver's idiom (full 616-line dtsi not yet
  fully transcribed - only the opening sequence was spot-checked here to
  confirm it's the same NT36523 register-bank-switching convention as
  elish's own sequence, e.g. `0xFF`/`0xB9`/`0x18` bank-select bytes
  appear in both).
- A new `drm_display_mode` entry with this panel's exact timings (table
  above has all the values already).
- Devicetree: `reset-gpios`, the two fixed regulators, dual-DSI
  `data-lanes`/port graph wiring, matching gts7l's real GPIO numbers
  (already found above) rather than elish's.

**Genuinely open questions, not yet answered:**
- Whether the ISL98608 bias IC needs a real Linux driver (register
  sequencing) or can be treated as a dumb enable-only regulator for a
  first pass - `isl98608_hw_i2c.c` needs a full read, not yet done.
- The exact i2c-gpio SDA/SCL pins for the display_buck bus on the real
  hardware (see above).
- DSI lane count and lane-to-lane mapping per link (not yet located in
  the downstream dtsi - the file has 616 lines and only the timing
  section was read closely so far).
- Whether `dispcc`'s probe-time PLL reprogram (disabled entirely in
  Round 35 for Phase 1) can be safely re-enabled once a real panel
  driver exists to immediately redo the full re-init sequence after, or
  whether the PLL config values themselves also need adjusting for this
  panel's specific pixel clock (~998 MHz bit clock, per
  `qcom,mdss-dsi-panel-clockrate`).

## Suggested next step when this work actually starts

Read `dsi_panel_NT36523_PPA957DB1_wqxga_video.dtsi` in full (only the
first ~260 of 616 lines were read for this scoping pass) to extract the
complete on/off command sequences, then draft a new
`kernel/dts/`-equivalent panel devicetree fragment and a new
`panel_desc`/`of_match` entry in a project-local copy of
`panel-novatek-nt36523.c`, following `sm8250-xiaomi-elish-common.dtsi`'s
structure as the template throughout.
