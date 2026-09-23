# Phase 3 scoping: Audio (speakers + microphone)

Recon pass before starting real audio bring-up, done 2026-09-20 right
after charging status, fuel gauge, and Wi-Fi/Bluetooth all got
confirmed working on real hardware, and after USB-C/PD/MUIC was
scoped and deliberately deferred (no mainline prior art, ~7,760-line
port). Goal: find out how real hardware wiring, mainline driver
availability, and this project's own "force everything built-in, no
module loading" policy interact for audio specifically - **per this
project's established practice, prior art and community-maturity
research was done before assuming either "just enable it" (Wi-Fi/BT/
battery's outcome) or "no driver exists" (USB-C/PD's outcome).**
Nothing here has been built or tested yet - this is pure research,
following the same methodology as every other Phase 2/3 scoping doc
(real sources cited, nothing assumed).


## Status and plan (2026-09-22, night) - stages 0-4 done: first protected sound

### Corrections to the scoping below, found against real hardware and the stock dumps

- **The CS35L41 amps are I2C, not SoundWire.** Stock's boot log shows
  all four on **I2C bus 7**, at `0x40`-`0x43` (`cs35l41`, `_b`, `_br`, `_r`),
  with audio over TDM/I2S from LPASS. `sm8250-mtp.dts` is a template for
  the LPASS/Q6 plumbing only; its speaker graph (WSA881x over SoundWire)
  doesn't apply.
- **No module loading is needed.** The early-boot problem is firmware
  availability, the same as for the SLPI: the PAS driver is built in and
  probes before the rootfs mounts. Starting the DSP from a unit after
  `local-fs.target` fixes it, and the Q6 APR services (and anything that
  binds to them) only appear then. (`/lib/modules` on the rootfs is
  still empty in any case.)
- **The ADSP carveout had to move to stock's placement** (see stage 0).

### Safety-critical facts

Wrong values here can damage the amps or speakers.

- **Speaker protection:** stock runs Cirrus speaker protection on each
  amp's DSP: `cs35l40-spk-dsp1-spk-prot.wmfw` plus `.bin` tuning and
  `-calib.bin`, all present in `work/stock-dump/dump/vendor-firmware/`.
- **Per-unit calibration:** this unit's factory speaker calibration is
  in `work/stock-dump/dump/cirrus/` (`rdc_cal*`, `temp_cal`,
  `vsc_cal*`/`isc_cal*`, one set per speaker suffix).
- **Boost converter:** the downstream DT sets only
  `cirrus,boost-peak-milliamp = <4100>`; the downstream driver never
  configures the boost inductor or capacitor. Mainline's binding
  *requires* `cirrus,boost-ind-nanohenry` and `cirrus,boost-cap-microfarad`
  and derives the boost loop coefficients from them. **Do not guess
  these.**

### Stages

| Stage | Work | Speaker risk | Status |
|---|---|---|---|
| 0 | Move the ADSP carveout to stock's placement and boot the ADSP (`QCOM_APR=y` only; all sound drivers stay unbuilt). | none | **done** |
| 1 | Read the CS35L41 boost-converter registers read-only (done from TWRP, which runs Samsung's kernel), and derive the real inductor/capacitor values. | none | **done** |
| 2 | Control-only CS35L41 bring-up (mainline `i2c11`) with those values; no sound card, amps' GLOBAL_EN off. | very low | **done** |
| 3 | Load the protection firmware and tuning, feed this unit's calibration into the DSP, and confirm protection is running before any sound. | low | **done** |
| 4 | Machine graph: LPASS TDM port -> 4 amps (port from the downstream DAI links). First sound at about -40 dB with a UCM software volume cap, then raise gradually. | controlled | **first tone done**; volume cap/UCM pending |
| 5 | Microphones (no 3.5 mm jack; likely digital mics via WCD938x or the VA macro). | none | |

**Rules throughout:**
- no audio through an amp unless its protection DSP is confirmed
  running;
- never hand-write amp registers;
- exact DT values from stock only;
- a hard software volume ceiling until the whole chain is verified.

### Stage 0 result

**Carveouts, moved to stock's live layout:**
- `adsp_mem` -> `0x8a700000` + `0x2c00000`
- `spss_mem` -> `0x8d300000` + `0x100000`
- the unreferenced `cdsp_secure_heap` -> a placeholder at
  `0x8d400000` + `0x3100000`

So `0x89200000`-`0x90500000` stays one contiguous no-map range, as on
stock. `gpu_mem` is left at upstream's address (the zap shader works
there).

**Firmware:** stock `adsp.mdt` + 22 parts in
`/lib/firmware/qcom/sm8250/samsung/gts7l/`, started by
`tools/rootfs/slpi/slpi-start.service` (which now boots SLPI and ADSP).

**Result on real hardware:**
- "remote processor adsp is now up";
- `PDR: Indication received from msm/adsp/audio_pd`;
- APR registered `aprsvc:service:4:3` (q6core), `4:4` (q6afe), `4:7`
  (q6asm) and `4:8` (q6adm);
- ADSP fastrpc compute banks 3-5 appeared;
- both DSPs running 10+ minutes with no crash, and the SLPI
  accelerometer unaffected.

(The SLPI's recurring `Handover signaled, but it already happened`
tracks the accelerometer stream: it stops when iio-sensor-proxy stops.
It's cosmetic and unrelated to audio.)

### Stage 1 result: boost values from real hardware

Read-only regmap reads from TWRP (Samsung's own kernel binds all four
amps; debugfs regmap). Raw capture:
`docs/logs/audio-stage1-2026-09-22/cs35l41-boost-registers-twrp.txt`.

All four amps read identically (chip ID `0x35a40`):

| Register | Value | Meaning |
|---|---|---|
| `BSTCVRT_COEFF` 0x3810 | `0x2424` | K1 = 0x24, K2 = 0x24 |
| `BSTCVRT_SLOPE_LBST` 0x3814 | `0x7500` | slope 0x75, LBST 0 |
| `BSTCVRT_PEAK_CUR` 0x3808 | `0x4a` | 4500 mA (the reset default; see below) |

Downstream never writes K1/K2/slope/LBST, so stock runs with these
power-on values. In mainline's `cs35l41-lib.c` tables they match exactly
one inductor: `lbst_val 0` = **1.0 uH** (`slope_table[0]` = 0x75), with
K1/K2 = 0x24 = **capacitor range 0 (0-19 uF)**.

Peak current is the exception: downstream only writes `bst_ipk` when the
sound card comes up (not in TWRP), so 0x4a is the reset default, and
stock's DT value (`cirrus,boost-peak-milliamp = <4100>`, 0x42) is what
it actually runs.

**Mainline DT values** (these reproduce stock's register state; none are
guessed):
- `cirrus,boost-ind-nanohenry = <1000>`
- `cirrus,boost-cap-microfarad` = any value in 1-19 (same registers)
- `cirrus,boost-peak-milliamp = <4100>`

**Other stage 2 inputs (TWRP sysfs and downstream DT):**
- **Bus:** stock "i2c-7" is the controller at `0xa8c000` = mainline
  `&i2c11`. Pins are gpio60/61 `qup11`, the same in both DTs.
  Downstream uses GPI DMA on `gpi_dma1`, whose `qcom,gpi-ee-offset` is
  `0x6000`; our DTS doesn't enable `gpi_dma1` yet.
- **Supplies:** VA/VP go to a `dummy_vreg` on stock (the rails are
  always on in hardware).
- **IRQ:** one line, gpio84, shared by all four amps (idles high, so
  active-low). Mainline requests it `IRQF_SHARED`.
- **Reset:** see stage 2. One node *does* carry it: `cs35l41@43` has
  `reset-gpios = <&tlmm 69 0>`, shared by all four amps.

### Stage 2 result: all four amps probe, and configure exactly like stock

It took three fixes, each found by comparing live state against TWRP.
All three are in the DTS/fragment with comments.

1. **PM8150L LDO4, 1.8V always-on** (`vreg_l4c_1p8`). Stock's overlay
   pins `pm8150a_l4` to a fixed 1.8V with `regulator-always-on` and no
   consumer, and it's enabled in TWRP. That fits the amps' VA, which
   stock models as a "dummy" always-on rail. Mainline never defined it.
2. **The shared reset, gpio69.** Downstream declares it on only one of
   the four nodes, so it was missed at first. gpio69 idles low with a
   pull-down, which held all four chips in reset: every address NACKed
   (`Failed waiting for OTP_BOOT_DONE`, -ENXIO). It's now `reset-gpios =
   <&tlmm 69 GPIO_ACTIVE_HIGH>` on all four nodes.
3. **`CONFIG_GPIO_SHARED_PROXY=y`.** In 7.x, gpiolib (`GPIO_SHARED=y`)
   claims any GPIO referenced by several DT nodes and routes consumers
   through a proxy driver, which defaults to `=m` and so never loaded.
   Every amp deferred ("Failed to get reset GPIO"; `gpioinfo` showed
   line 69 as `consumer="shared"`). The proxy votes: the line only
   returns to its default (reset asserted) when the *last* consumer
   drops its vote, so one amp's error or shutdown can't reset the
   others.

**One deliberate deviation from stock:** GPIO2 (the IRQ output) is
open-drain INTB (`src 2`) with a SoC-side pull-up on gpio84, not stock's
push-pull INTB. All four amps share that line, and push-pull outputs
could contend on it; open-drain can't. The driver still sees the same
active-low interrupt.

**Result on real hardware:**
- all four probe: "Cirrus Logic CS35L41 (35a40), Revision: A0", the
  same as stock;
- no speaker pops or noise at any boot;
- the shared gpio84 IRQ at 0 events.

Registers after probe
(`docs/logs/audio-stage2-2026-09-22/mainline-cs35l41-registers-after-probe.txt`)
match stock on every amp:

| Register | Value |
|---|---|
| `PEAK_CUR` | `0x42` (4100 mA) |
| `COEFF` | `0x2424` |
| `SLOPE_LBST` | `0x7500` |
| `SW_FREQ` | `0x01008000` |
| `OVERVOLT` | `0x130` |
| `GLOBAL_EN` | 0 (output off) |

The SLPI, ADSP, touch and sensors are unaffected.

### Stage 3/4 design (2026-09-22) - for review before anything is built

All of this comes from stock sources: downstream `techpack/audio/asoc/kona.c`,
`drivers/mfd/cirrus-cal.c`, stock `vendor/etc/mixer_paths.xml`
(extracted to `work/stock-super/vendor-extract/etc/audio/`), the r07
overlay, and stock's boot log.

**Speaker map.** Stock's MFD numbers its codec sub-devices in probe order
(`7-0043` probes first and gets `cs35l41-codec.0`, then `.4`, `.8`,
`.12`), and `kona_tdm_cirrus_init` names `codec_dais[0..3]` FL/FR/RL/RR:

| Amp | Speaker | Cal suffix | `rdc_cal` |
|---|---|---|---|
| `0x43` | FL | `_b` | 8401 |
| `0x42` | FR | `_br` | 8590 |
| `0x41` | RL | (none) | 9087 |
| `0x40` | RR | `_r` | 9144 |

Our `sound-name-prefix` values should become FL/FR/RL/RR so the control
names match stock's `mixer_paths.xml` one to one.

**Firmware.** Mainline asks for
`cirrus/cs35l41-dsp1-spk-prot-<system>-<prefix>.wmfw|bin` (lowercased),
then `...-<system>.wmfw|bin`, then a legacy name. `<system>` comes from
the DT property `cirrus,subsystem-id` (hence "Subsystem ID not found").
Plan:
- set `cirrus,subsystem-id = "gts7l"`;
- install stock's `cs35l40-spk-dsp1-spk-prot.wmfw` and `.bin` as
  `cirrus/cs35l41-dsp1-spk-prot-gts7l.wmfw|.bin`. Stock loads that same
  pair on all four amps.

**Never install `-calib.bin`:** it's the factory calibration-run tuning.

**Calibration** (`cirrus_cal_apply()`, run by stock on every boot). Per
amp, write these into the protection firmware's DSP memory:

| Register | Value |
|---|---|
| `CAL_RDC` 0x02800224 | the amp's `rdc_cal` |
| `CAL_AMBIENT` 0x02800228 | `temp_cal` (27) |
| `CAL_STATUS` 0x0280022C | 1 |
| `CAL_CHECKSUM` 0x02800230 | status + rdc |
| `VIMON_CAL_STATUS` 0x0280006c | 2 (success; all VSC/ISC files present and in range) |
| `VIMON_CAL_VSC` / `_ISC` 0x02800070 / 0x02800074 | the stored values |

Mainline's ASoC cs35l41 has no calibration support of its own, so this
goes through the firmware's coefficient controls (exposed by wm_adsp once
the firmware loads) from a small userspace step before any stream. Each
value should be read back to confirm.

**TDM link:**
- **Port:** stock uses **`PRIMARY_TDM_RX_0`** (AFE 36864), format
  **DSP_A**, codec bit-clock/frame slave (CBS_CFS), **IB_NF**.
- **Slots:** `qcom,tdm-max-slots = <4>` x 32-bit slots at 48 kHz, so
  BCLK = 6.144 MHz. RX slot positions are FL 0, FR 1, RL 2, RR 3 (the
  `ASPRX1 Slot Position` controls; ASPRX2 is 7 = unused).
- **Feedback:** the amps' VI feedback goes out on the same slots on TX
  (`ASP TX1 Source = DSPTX1`). Protection runs on each amp's own DSP from
  its own VMON/IMON, so the AP-side TX capture isn't needed to be safe.

**Mainline gap:** `sound/soc/qcom/sm8250.c` only handles MI2S. `sdm845.c`
has a full TDM implementation (`sdm845_tdm_snd_hw_params`: LPASS TDM
clock, `set_tdm_slot` on CPU and codec DAIs, channel map). Stage 4 ports
that into sm8250 for `PRIMARY_TDM_RX_0`. The q6afe DT binding already
has the TDM properties (`qcom,tdm-sync-mode/-sync-src/-data-out/
-invert-sync/-data-delay/-data-align`); their values need reading from
the downstream `qcom,msm-dai-tdm-pri-*` nodes.

**Stock's operating values** (`mixer_paths.xml`):
- **Defaults:** `DSP1 Firmware = Protection`, `DSP1 Preload Switch = 1`,
  `AMP PCM Gain = 0`, `AMP Enable Switch = 0`, `DSP RX2 Source = ASPRX1`,
  unmuted.
- **Speaker path ("spk" plus "speaker"):** `PCM Source = DSP`,
  `Boost Enable = Enabled`, `AMP Enable Switch = 1`, and on all four amps
  **`AMP PCM Gain = 17`, `Digital PCM Volume = 817`**. These are the
  maximum values stock ever runs.

**Hard rules for our UCM/test scripts:**
1. `PCM Source` must be **DSP** (protection in the signal path) before any
   stream opens. `ASP` bypasses protection and is never used.
2. The protection firmware must be confirmed running on all four amps
   before any stream (`HALO_STATE` 0x02800050 = 0 = CSPL running;
   `HALO_HEARTBEAT` 0x02800054 incrementing), with calibration written
   and read back.
3. Gain ceilings: `AMP PCM Gain` never above 17 and `Digital PCM Volume`
   never above 817. First sound uses much lower values plus a software
   cap (about -40 dB).
4. Boot defaults: amps disabled, gain 0, and no stream until rules 1-2
   are verified.

**Implementation order:**
- **3a:** DT prefixes FL/FR/RL/RR, `cirrus,subsystem-id`, firmware files.
- **3b:** the sm8250 TDM machine-driver patch plus the `&sound` card
  (PRI TDM RX0 -> 4 amps); build the machine and Q6 drivers in.
- **3c:** boot with no stream; confirm the firmware loads (preload) and
  runs on all four; apply calibration and read it back.
- **4:** first sound under the rules above.

### Stage 3 result (2026-09-22): card up, gate holds, protection firmware loaded on all four

- **Kernel:** `kernel/patches/0017-asoc-qcom-sm8250-primary-tdm-for-gts7l-speaker-amps.patch`
  (TDM for sm8250.c). Built in: `SND_SOC_SM8250`, `SND_SOC_QDSP6`,
  `SND_SOC_QCOM(_COMMON/_SDW)` and the SoundWire *bus core*.
  `SND_SOC_QDSP6_USB` and `SND_SOC_QCOM_OFFLOAD_UTILS` are off (the
  latter capped the machine driver at `=m`). WCD938x, WSA881x, the LPASS
  macros and `SOUNDWIRE_QCOM` stay `=m`.
- **DTS:** the `&sound` card `Samsung-GTS7L-CS35L41-Speakers`
  (MultiMedia1 -> PRIMARY_TDM_RX_0 -> FL/FR/RL/RR), `q6afedai dai@24`
  with stock's TDM values, `pri_tdm_active` pins, amp prefixes
  FL/FR/RL/RR, and `cirrus,subsystem-id = "gts7l"`.
- **Rootfs** (`tools/rootfs/audio/`):
  - `72-gts7l-audio-gate.rules`: all ALSA nodes root:root 0600, no
    uaccess.
  - stock firmware as `cirrus/cs35l41-dsp1-spk-prot-gts7l.wmfw` and
    `.bin` (md5 `262db054...`, `a11d8387...`, the same as stock).
  - Note that linux-firmware ships a generic
    `cirrus/cs35l41-dsp1-spk-prot.wmfw|bin` (a laptop default) at the
    end of wm_adsp's fallback chain, so always confirm from the log which
    file loaded.
- **Verified:**
  - card 0 registered; `pcmC0D0p`/`controlC0` root 0600 with no user
    ACL; PipeWire sees only "Dummy Output";
  - all four amps "Subsystem ID: gts7l"; `GLOBAL_EN = 0` throughout.
  - **Defaults after boot:** `PCM Source = ASP` (protection bypassed -
    the reason for the gate), `Analog PCM Volume = 0` (the minimum,
    0.5 dB), `Digital PCM Volume = 817` (0 dB, stock's value),
    `DSP1 Firmware = Protection`.
- **3c, firmware:** `PCM Source` set to DSP on all four, then `DSP1
  Preload Switch` on. Every amp loaded
  `cirrus/cs35l41-dsp1-spk-prot-gts7l.wmfw` ("Fri 17 Jan 2020 16:05:21",
  the same timestamp as stock's boot log, firmware 400a4 v0.0.1) and
  `...-gts7l.bin`, whose embedded tuning name is
  **`TAB_S7_SPKPV1_PPP_20200603.bin`**. No errors, and `GLOBAL_EN`
  stayed 0 (logs: `docs/logs/audio-stage3-2026-09-22/`).
- **3c, calibration: not possible in preload.** The firmware exposes
  `cd CAL_R/CAL_AMBIENT/CAL_STATUS/CAL_CHECKSUM` and `400a4
  VIMON_CAL/VSC/ISC`, `HALO_STATE/HALO_HEARTBEAT`, `CSPL_STATE`. But they
  are *volatile* controls, and wm_adsp refuses both reads and writes
  ("Operation not permitted") until the DSP is *running*, which in
  mainline happens only when a stream starts (preload loads it but
  doesn't run it; heartbeat reads 0). Stock applies calibration at the
  same point, when the DSP boots at stream start.

**Revised stage 4 procedure** (so calibration is in place before any
non-zero signal):
1. As root, with the gate still in place, set every amp to
   `Analog PCM Volume = 0` and `PCM Source = DSP`.
2. Open the PRIMARY_TDM stream playing **digital silence** (all zeros).
   The DSPs start and the amps power up with no signal.
3. Immediately write each amp's calibration through the controls, and
   read it back.
4. Confirm `HALO_STATE`/`CSPL_STATE` are running and `HALO_HEARTBEAT` is
   incrementing, on all four amps.
5. Only then, feed a short, low-level test tone (about -40 dBFS, analog
   gain still at its minimum). Stop at the first anomaly.



### Stage 4 result (2026-09-22): calibration in the firmware, first protected tone

Logs: `docs/logs/audio-stage4-2026-09-22/`. Scripts:
`tools/rootfs/audio/stage4-silence-calibrate.sh` (verify only) and
`stage4-tone.sh`.

- **Step 3 as planned doesn't work.** Once the protection firmware
  runs, it clears `CAL_R`, `CAL_STATUS` and `CAL_CHECKSUM` within
  milliseconds of a write, in any order and even in one batched `amixer
  -s`. It reads them only at start-up. `CAL_SET_STATUS` (0x2800234) is
  its verdict: 1 = DEFAULT (built-in values), 2 = SET (the same values
  as mainline cs35l56). Until then it ran on its defaults. Writing
  `CSPL_COMMAND = 3` did nothing. `CSPL_COMMAND` is a cached control, so
  it had to be put back to 0, or it would be re-sent at the next DSP
  start.
- **Fix: kernel patch 0018.** The cs35l41 driver writes the calibration
  from wm_adsp's `pre_run`, after the firmware loads and before the core
  starts. Values come from new per-amp DT properties (`cirrus,cal-r`,
  `cirrus,cal-ambient`, `cirrus,vimon-cal-vsc`, `cirrus,vimon-cal-isc`)
  holding this unit's /efs values. The amp-to-file map is stock DT's
  `cirrus,mfd-suffix`: 0x43 `_b`, 0x42 `_br`, 0x41 none, 0x40 `_r`.
  Status 1 and checksum = R + 1 match stock `cirrus_cal_apply()`.
  About 2 s after the first run, the driver logs every word read back
  from DSP memory:
  `Calibration applied: CAL_SET_STATUS=2 R=8401 ambient=27 status=1
  checksum=8402 vimon=2 ...`, with R 8401/8590/9087/9144 for
  FL/FR/RL/RR.
- **Readback traps:**
  - regmap debugfs shows the regmap cache for DSP memory, not the DSP's
    contents;
  - a cached (non-volatile) control such as `CAL_AMBIENT` reads back
    its kernel cache. A raw write left that cache at 0 while the DSP
    held 27, so 0018 writes cached controls through
    `cs_dsp_coeff_write_ctrl()`;
  - `amixer cget name=` walks about 1,500 controls, so each read takes
    about 0.5 s and a status dump can outlast a short stream.
- **Protection verified running on all four** with silence:
  - `HALO_STATE` = 2;
  - `HALO_HEARTBEAT` about +1010/s;
  - `CSPL_STATE` = 0;
  - `CSPL_TEMPERATURE` 0x5c000 = 23.0 °C (radix 14).
- **Mainline mailbox bug:** a stream that starts within 3 s of the last
  one, before runtime PM hibernates the amps, fails RESUME on every amp:
  "Failed to set mailbox cmd 2 (status 1)", then "DSP1 event failed:
  -42". The DSP stays PAUSED, and because PCM Source = DSP the output is
  silence, so the failure is safe. It reproduces every time (gaps of
  0 s and 1 s fail; 5 s works). Workaround: set
  `/sys/bus/i2c/devices/11-004[0-3]/power/autosuspend_delay_ms` to 0,
  so every stream starts from hibernation; back-to-back streams then
  work. It isn't persistent yet, and the kernel fix still needs finding.
  Stock sends RESUME from the main-amp PMU after GLOBAL_EN and waits
  for the DSP's ack IRQ.
- **First tone:** 1 kHz at -40 dBFS for 2 s, analog gain 0, through the
  protection DSP. No kernel errors, protection running throughout. The
  owner heard it, quiet. (It was stereo, so only channels 1-2 played: see
  below.)

### Stage 4b (2026-09-23): per-speaker check, and four TDM-link bugs

The test plays one channel of a 4-channel stream at a time: -40 dBFS,
analog gain 0, run by the owner with
`tools/rootfs/audio/stage4-per-speaker.sh`. Each fix below changed one
thing and was checked with silence first (the DSP heartbeat must climb
about 1000/s; `CAL_SET_STATUS` must be 2).

1. **Channels 3 and 4 were silent (patch 0017 fix plus new 0019).** The
   BE fixup's `snd_mask_set_format(S32_LE)` added to the format mask but
   never cleared S16, so the link ran S16. cs35l41 sized its slots from
   the sample width, giving 16-bit slots on a 32-bit-slot link: amp n
   read half of ADSP slot n/2. Stock: S16_LE, 4 channels,
   `cirrus,fixed-width = 32`. Fix: the fixup sets S16 explicitly (mask
   cleared first), and new patch 0019 adds cs35l41 `set_tdm_slot()` for
   the slot width. The machine driver calls it with 4 x 32.
2. **Slots 1-3 crackled continuously, slot 0 was clean.** The TDM
   framing and clock didn't match stock, with three causes:
   - The DTS took Qualcomm's base `msm-audio-lpass.dtsi` values
     (sync-mode 1, invert-sync 1). Samsung's overlay (fragment@119 ->
     `tdm_pri_rx`) sets **sync-mode 0, invert-sync 0, data-delay 1**.
   - Mainline q6afe-dai parses `qcom,tdm-data-out/-invert-sync/
     -data-delay` but never sent them: always 0. Fixed by **patch 0020**.
   - Mainline hardcodes `Q6AFE_LPASS_CLK_ATTRIBUTE_INVERT_COUPLE_NO` for
     TDM bit clocks. Stock is `clk-attribute 0x0001` (COUPLE_NO). The
     extra inversion, on top of the amps' IB_NF, puts their sampling edge
     on the data transitions. With long sync that gave marginal bits on
     slots 1-3. With short sync, the amps lost the frames and the DSP
     heartbeat stalled at 1-6. Fixed by **patch 0022**, an optional
     `qcom,tdm-clk-attribute` per port; the DTS sets 1.
   - Also stock: `cirrus,use-fsync-errata`. **Patch 0021** adds the one
     write mainline's revision errata lack, `ASP_CONTROL4 = 0x01010000`.
     Alone it did not fix the stall. It is kept because stock has it.
3. **Result:** all four channels clean ("perfect sound"). The mapping,
   landscape with the camera on top:

   | Channel | Slot | Amp | Speaker |
   |---|---|---|---|
   | 1 | 0 | 0x43 "FL" | bottom right |
   | 2 | 1 | 0x42 "FR" | top right |
   | 3 | 2 | 0x41 "RL" | bottom left |
   | 4 | 3 | 0x40 "RR" | top left |

   Landscape stereo is therefore **L = channels 3+4, R = channels 1+2**.
   Samsung's FL/FR/RL/RR names don't describe landscape positions.
4. **Autosuspend workaround made persistent:**
   `tools/rootfs/audio/73-gts7l-cs35l41-autosuspend.rules`. It matches
   `add|bind`: the built-in driver binds before udev starts, so only the
   coldplug add is seen.
5. **Not persistent yet:** after boot the amps come up with **PCM Source
   = ASP**, which bypasses the protection DSP. It must be set to DSP (with
   gain 0 and preload on) before any audio. The audio gate stays until
   that is automatic and verified.

## Real hardware: a genuinely complex, multi-chip audio topology

Confirmed directly in the downstream overlay
(`references/gts7l/arch/arm64/boot/dts/samsung/gts7l/
kona-sec-gts7l-eur-overlay-r07.dts`) - this is **not** a single
codec/amp pair, it's a real SoundWire-based multi-component graph:

- **4x Cirrus Logic CS35L41** smart speaker amplifiers -
  `cs35l41@43`/`@42`/`@41`/`@40` (lines 9643, 9684, 9723, 9761,
  `compatible = "cirrus,cs35l41"`), with fixup labels `cs35l41_fl`/
  `cs35l41_fr` (line 12370-12371) confirming at least front-left/
  front-right channels - a quad-speaker layout (matches this
  tablet's real marketed "AKG quad speaker" hardware), not a simple
  stereo pair.
- **Qualcomm WCD938X** - the SoC-family's own codec IC, wired over
  **SoundWire** (not I2C/I2S) via separate TX and RX "macro" nodes
  (`tx-macro@3220000`/`rx-macro@3200000`, each with their own
  `swr_master` sub-bus and a `wcd938x-tx-slave`/`wcd938x-rx-slave`
  child, lines 6898-6935) plus a top-level `wcd938x-codec` node (line
  7002-7003, `compatible = "qcom,wcd938x-codec"`). This is Qualcomm's
  standard "Bolero" codec architecture for this SoC generation
  (`asoc-codec-names` at line 7048 literally lists `"bolero_codec"`).
- **4x Qualcomm WSA881x** smart speaker amps - `wsa881x@20170211`/
  `@20170212`/`@21170213`/`@21170214` (lines 6968-6993), *also*
  SoundWire, under a `wsa-macro@3240000`.

  **Resolved, 2026-09-22**: booted real stock Android (Magisk root)
  specifically to check this. `cs35l41` probes for real - four full
  instances (`cs35l41-pwr`/`-cal`/`-bd`/MFD core, `_fl`/`_fr`/plain/`_r`
  suffixes), each with `dsp_part_name: cs35l40-spk`, at
  `t≈1.08-1.09s` in the boot log
  (`docs/logs/stock-boot-2026-09-22/08-audio-amp-cs35l41-vs-wsa881x-trace.txt`).
  **`wsa881x` never appears anywhere in the boot log at all** - not a
  single probe attempt, success or failure. CS35L41 is the real,
  actively-used amp for this exact unit; WSA881x is dead/unused
  devicetree - a disabled reference-design leftover, not a
  different-channel split as speculated above. Port CS35L41 only.
- **LPASS clock IDs and `qcom,codec-lpass-ext-clk-freq` properties**
  (lines 7154-7218, 8 separate entries) confirm this board genuinely
  drives multiple codec clock domains from the SoC's own LPASS
  (Low-Power Audio Subsystem) clock controller, not a simpler
  external-oscillator setup.

**Microphone(s)**: not separately identified in this pass - WCD938X
is itself a combo codec (has its own TX/ADC paths for mic input, per
its real, mainlined driver's own capabilities), so mic input is very
likely routed through the same WCD938X TX macro path rather than a
separate chip - not confirmed live.

## Mainline driver availability: much better than the "SM8250 audio is
notoriously hard" reputation alone would suggest

Checked `work/linux/sound/soc/qcom/`, `work/linux/sound/soc/codecs/`,
and `work/linux/drivers/soundwire/` directly - **every real chip this
board needs already has a mainline driver, already built at some point
this session** (`.ko`/`.mod` files already present in the tree from an
earlier `defconfig`-driven build, confirming these Kconfig symbols
already resolve and compile cleanly against Linux 7.2):

- `sound/soc/codecs/wcd938x.c` + `wcd938x-sdw.c` (SoundWire variant)
- `sound/soc/codecs/wsa881x.c`
- `sound/soc/codecs/cs35l41.c` + `cs35l41-i2c.c` (a mature, widely-used
  driver across many Windows/Chromebook laptop speaker setups, not
  chip-specific to this board)
- `sound/soc/codecs/lpass-rx-macro.c`/`lpass-tx-macro.c`/
  `lpass-wsa-macro.c`/`lpass-va-macro.c` (the Bolero macro framework
  downstream's own `bolero_codec` name maps to)
- `drivers/soundwire/qcom.c` (the actual SoundWire bus controller
  driver for this SoC)
- `sound/soc/qcom/sm8250.dtsi`/`sm8250-mtp.dts` - **a complete, real,
  working reference DT audio graph already exists in this exact
  kernel tree**, for the *same SoC* (Qualcomm's own MTP reference
  board), using the *same* codec set (WCD938X + WSA881x over
  SoundWire, `q6afe`/`q6asm`/`q6routing` DSP DAI links) - this is a
  substantially better starting point than anything found for
  Wi-Fi/BT/battery, which all needed to adapt a *different device's*
  DTS. `sm8250-mtp.dts:655-820` (the `&sound {}` node and its
  `swr0`/`swr1`/`swr2` SoundWire bus definitions) is a directly
  copyable pattern, not something to reverse-engineer from scratch.

**Conclusion: this is not a "no driver exists" situation like
USB-C/PD, and not a from-scratch port like touch was** - every
individual component driver is real, mature, mainlined code with a
working same-SoC reference to adapt from.

## The real complication: a documented, community-known boot-ordering
requirement that conflicts directly with this project's own standing policy

Web research (per this project's established practice) into SM8250
mainline audio maturity found the real community history, via the
active `sm8250-mainline` GitHub org and postmarketOS's own SM8250
port:

- SM8250 audio genuinely works on real mainline-adjacent kernels today
  (postmarketOS's own `linux-postmarketos-qcom-sm8250` package, an
  active `#sm8250-mainline` community channel) - this isn't a dead or
  purely theoretical effort.
- **A specific, documented, real timing problem exists**: the audio
  probe fails if the relevant drivers are built directly into the
  kernel image rather than loaded as modules from the rootfs after
  boot, because **the ADSP (audio DSP coprocessor) isn't ready to
  serve APR (Audio Packet Router, the IPC mechanism every Q6-DSP-
  routed audio driver depends on) requests that early in boot** -
  a probe-time failure, not a recoverable "wait and retry" deferred
  probe. The community's own documented fix: keep `QCOM_APR`,
  `QCOM_Q6V5_PAS`, `QCOM_Q6V5_COMMON`, and `PINCTRL_LPASS_LPI` built
  in (these are the *bootstrap* pieces - loading and authenticating
  the ADSP firmware image itself, a real remoteproc/PAS flow directly
  comparable to this project's own Adreno zap-shader precedent, not
  just Kconfig plumbing), but build the actual **codec/machine-driver
  audio stack as loadable modules**, brought up by userspace
  (`systemd`/`udev`) only once the ADSP has genuinely finished
  booting.

**This is a direct, structural conflict with this project's own
standing "force every driver `=y`, no module-loading infrastructure"
policy** - a policy this project has followed successfully (if
sometimes painfully) for every Phase 2/3 chunk so far, including
several real tristate-ceiling surprises along the way (`CFG80211`/
`MAC80211`/`RFKILL` for Wi-Fi, `CONFIG_PHY_QCOM_QMP_PCIE`,
`CONFIG_UHID`/`BT_HIDP`, `CONFIG_SECURITY_LANDLOCK`). Every one of
those was a Kconfig *dependency-graph* problem, solvable by forcing
more `=y` symbols. **Audio is a different kind of problem: forcing
the codec/machine drivers `=y` doesn't just risk not fitting the boot
partition, it is independently, community-documented to cause a real,
non-recoverable probe failure at the wrong point in boot, regardless
of Kconfig dependency resolution.** This is the first Phase 3 item
where the "always force built-in" shortcut this project has relied on
so far is very likely to genuinely not work at all, not just risk
inefficiency.

Real Kconfig dependency chain confirming the scope of what would need
to move to modules: `sound/soc/qcom/Kconfig:185`,
`config SND_SOC_SM8250` - `depends on QCOM_APR && SOUNDWIRE`,
`depends on COMMON_CLK`; `sound/soc/codecs/Kconfig:2473`,
`SND_SOC_WCD938X depends on SND_SOC_WCD938X_SDW`, which itself
`depends on SOUNDWIRE`; `SND_SOC_WSA881X depends on SOUNDWIRE` too -
the entire codec stack sits behind the SoundWire bus subsystem
(`drivers/soundwire/Kconfig`), a real, separate bus driver with its
own dependency surface this project has never touched at all.

## The `boot` partition size question, and why it matters more here

Same standing constraint as every Phase 3 item since Wi-Fi: the
partition is at its confirmed, measured hard ceiling (71303168 bytes,
zero headroom on every recent build). Two things make this worse for
audio specifically, not just a repeat of the same rule:

1. **This is real driver code volume this project hasn't yet
   attempted at this scale**: SoundWire bus core + `qcom.c` bus
   driver, WCD938X + its SDW variant, WSA881x, CS35L41, four LPASS
   macro drivers, the SM8250 ASoC machine driver, and Q6 DSP
   APR/AFE/ASM/routing glue - a meaningfully larger set of new
   built-in code than any single Wi-Fi/BT/battery addition, all of
   which fit within small page-rounding slack so far.
2. **The community's own documented fix (move the codec/machine
   stack to modules) can't be adopted without solving this project's
   long-deferred module-loading gap first** - previously flagged as a
   "nice to have soon" in the Wi-Fi scoping doc, and again in the
   battery-fuel-gauge doc as "hasn't been forced yet." Audio may be
   the item that finally forces this decision, rather than something
   to defer again.

## Open questions, genuinely unresolved

- Whether this exact unit's ADSP firmware blob (needed for
  `QCOM_Q6V5_PAS` to actually load and authenticate the DSP, the same
  real "device-signed firmware blob" pattern as the Adreno
  zap-shader) is obtainable the same way - not checked in this pass,
  would need a live-device `/vendor/firmware` search, same precedent
  as GPU/Wi-Fi/BT firmware extraction.
- Whether CS35L41 or WSA881x (or both, on different channels) is the
  real, active speaker path on this specific board revision - not
  resolved from the DTS alone.
- Whether forcing just the bootstrap pieces (`QCOM_APR`/
  `QCOM_Q6V5_PAS`/`QCOM_Q6V5_COMMON`/`PINCTRL_LPASS_LPI`) built-in
  while leaving everything else unbuilt (not even as modules, since
  this project has no module-loading path at all yet) would leave the
  system in a stable, harmless "no audio, nothing else broken" state
  - probably yes (deferred probe / absent driver is normal, not
  fatal), but not confirmed.

## Suggested first step: decide on the module-loading prerequisite
before writing any audio-specific code

Given the community-documented boot-ordering requirement directly
conflicts with this project's established "force everything built-in"
pattern, the honest recommendation is **not** to start with a DTS
node the way every other Phase 3 item did. Instead:

1. **Resolve the module-loading question first**, as its own
   decision, before any audio-specific work: either (a) build a real
   `/lib/modules` + `modprobe`/`depmod` path into the Arch rootfs
   (Phase 5 already has a persistent `systemd` install, `pacman`'s own
   `linux`-adjacent tooling normally handles this automatically) and a
   `udev`/systemd unit to load the audio stack once the ADSP is up, or
   (b) accept audio may not be achievable under this project's current
   all-built-in kernel model at all, and defer it explicitly rather
   than attempting a doomed all-`=y` build.
2. Only once that's decided: force the bootstrap-only symbols
   (`QCOM_APR`, `QCOM_Q6V5_PAS`, `QCOM_Q6V5_COMMON`,
   `PINCTRL_LPASS_LPI`) built-in, add the ADSP `remoteproc` devicetree
   node (base scaffolding already exists in `sm8250.dtsi`, same
   "disabled by default" pattern as every other peripheral this
   project has enabled), and confirm the ADSP itself boots and
   authenticates cleanly (a real, checkable milestone independent of
   any codec work at all) before touching WCD938X/WSA881x/CS35L41/
   SoundWire.
3. Adapt `sm8250-mtp.dts`'s real, complete `&sound {}` graph
   (SoundWire buses, macros, DAI links) rather than writing one from
   scratch, once the module-loading and ADSP-boot questions are both
   resolved.
4. **Package and check the exact byte count against 71303168 before
   touching the device** - standing rule, more likely than ever to
   actually bind given the code volume here.

## Status: scoped, not yet started

Nothing built or flashed. This document is the research-only pass;
implementation - which may reasonably start with the module-loading
prerequisite decision rather than audio-specific code at all - is a
separate, future step.
