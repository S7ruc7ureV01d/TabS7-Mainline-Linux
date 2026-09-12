# Porting `ubuntu-galaxy-tab-s9-ultra` to the Samsung Galaxy Tab S7 — Feasibility Analysis

Date: 2026-09-11
Source project analyzed: https://github.com/agcarbajo/ubuntu-galaxy-tab-s9-ultra
(built on top of https://github.com/agcarbajo/postmarketos-galaxy-tab-s9-ultra)

## 1. What the source project actually is

`ubuntu-galaxy-tab-s9-ultra` is **not a generic "Ubuntu on tablets" image**. It is a
device-specific port for exactly one board:

- Device: Samsung Galaxy Tab S9 Ultra Wi-Fi, model `SM-X910`, codename `gts9uwifi`
- SoC: Qualcomm SM8550 ("Kalama") / Snapdragon 8 Gen 2, Adreno 740 GPU
- Kernel: **upstream mainline Linux 7.2-rc3** (commit `a13c140cc289c0b7b3770bce5b3ad42ab35074aa`), not a Samsung/Android downstream kernel
- Base: forked from a sibling `postmarketOS` port for the *same* device, then layered with Ubuntu 24.04 userspace (GNOME 46 / Wayland), a device tree, dozens of hand-written or hand-adapted kernel drivers, TWRP-based installer ZIPs, a dual-boot Android app, and a companion GNOME app ("Tab Companion") for S Pen/fingerprint/keyboard integration.
- Firmware/camera tables, PMIC/charger drivers (sm5440, sm5714), the fingerprint driver (egis_el721), SPSS/GLINK/SPCOM drivers, and the display panel driver were all **built specifically against the SM-X910's stock firmware and CamX blobs**, with SHA-256-pinned provenance per file.

The huge majority of engineering effort documented in `docs/porting-log.md` and
`docs/development-notes.md` is *board bring-up on mainline Linux*: DTS authoring,
regulator/clock topology, panel timing, PMIC/fuel-gauge drivers, Gunyah
virtualization glue, USB-PD negotiation, and an enormous amount of flashing/boot-chain
reverse engineering specific to the X910's partition layout and ABL.

## 2. The core problem: the Tab S7 is a completely different SoC generation

| | Galaxy Tab S9 Ultra (SM-X910) | Galaxy Tab S7 (SM-T870/T875) |
|---|---|---|
| SoC | Qualcomm SM8550 / Snapdragon 8 Gen 2 | Qualcomm SM8250 / Snapdragon 865(+) |
| CPU | 1×Cortex-X3 + 2×A715 + 2×A710 + 3×A510 | 1×Cortex-A77 + 3×A77 + 4×A55 |
| GPU | Adreno 740 | Adreno 650 |
| Wi-Fi/BT chip | WCN7850 (`ath12k`) | WCN3990-class (`ath11k`/downstream, older gen) |
| Display | 14.6" AMOLED, 2960×1848, 120 Hz, custom `ana38407` panel driver + UDFPS | 11" LCD (WQXGA 1600×2560, 120 Hz, no OLED, no UDFPS) |
| Fingerprint | Under-display (EgisTec EL721, custom mainline driver written for this project) | None on base S7 (capacitive side button on some variants) — different or absent hardware entirely |
| S Pen | BLE + magnetic dock with custom protocol driver | Passive/EMR S Pen, no BLE pairing, different digitizer generation |
| Charger/fuel gauge | Samsung SM5440/SM5714 (custom drivers written in this project) | Different PMIC generation entirely |
| Camera | Samsung HI1337 + DW9808 VCM, blob-derived driver tables | Different camera modules |
| Release year / Android base | 2023, Android 13 firmware | 2020, Android 10 (up to 12/13 via updates) firmware |
| Kernel generation gap | mainline Linux 7.2-rc3 already has SM8550 upstream support to build on | SM8250 mainline support exists but is **less mature** and largely driven by a *different* community (OnePlus 8/8T/8 Pro, Poco F2 Pro) with **different DTS, different regulators, different panel** |

The two devices don't just differ in "which tablet" — they are **two SoC
generations apart** with a non-overlapping peripheral set (PMIC, charger, Wi-Fi/BT
combo chip, fingerprint sensor presence, display panel, camera ISP wiring). Under
Linux, essentially none of the device-tree nodes, board-specific drivers, or
firmware blob parsers in `kernel/` are reusable as-is for SM8250. They would all
need to be rewritten or ported by studying the Tab S7's own downstream Samsung
kernel source and CamX/ACPM blobs.

## 3. What *is* reusable / transferable

Even though the low-level kernel work isn't portable, several **methodological and
architectural** assets from the project carry over well and would meaningfully
shorten a Tab S7 port:

1. **The overall strategy** — "mainline-first" (real upstream Linux instead of a
   forked Android kernel), Ubuntu via `mmdebstrap`, dual-boot via a TWRP-flashed
   installer ZIP + Android-side toggle app — is SoC-agnostic and is a proven,
   working recipe.
2. **The boot-chain / flashing knowledge** (ABL log reading, `vbmeta` handling,
   `param` partition boot-mode flag, heimdall quirks, Download/TWRP mode detection
   via USB VID:PID) is Samsung-Odin-platform knowledge that mostly transfers to
   any Samsung Exynos/Snapdragon tablet using the same Samsung bootloader family,
   S7 included — this is a genuinely reusable chunk.
3. **Tab Companion's architecture** (S Pen settings, keyboard remap, fingerprint
   enrollment UI, dual-boot toggle) is a reasonable template to reimplement
   against S7-specific backends, even though the backends themselves differ.
4. **The general packaging/config layout** (`packaging/`, `configs/`, `scripts/`)
   is a good skeleton to fork and adapt.
5. **Existing SM8250 mainline Linux work outside this project** — the community
   around `sm8250-mainline` (OnePlus 8/8T/8 Pro, Poco F2 Pro, Xiaomi Mi 10) has
   already upstreamed a lot of SM8250 core platform support (clocks, RPMh,
   pinctrl, UFS, base Adreno 650/DPU support) into mainline Linux and
   postmarketOS. This is a *better* starting point for SM8250 bring-up than
   starting from zero, but it is a different device family from Samsung tablets,
   so display panel, touchscreen, PMIC, and Wi-Fi/BT would still need Tab
   S7–specific work.

## 4. What would have to be built essentially from scratch

- A new devicetree (`sm8250-samsung-*.dts`) for `gts7wifi`/`gts7`, including
  regulators, pinctrl, and the exact power sequencing Samsung used for this board.
- A panel driver for the S7's 11" LCD (not OLED — no UDFPS/AMOLED-panel code
  applies), likely needing a DSI panel driver adapted from Samsung's downstream
  kernel source for `gts7`.
- Touchscreen driver bring-up (Tab S7 does not use Goodix in the same
  configuration as the S9 Ultra necessarily — needs verification against Samsung's
  released GPL kernel source for `gts7`).
- Wi-Fi/Bluetooth combo chip driver — a different chip generation than
  `ath12k`/WCN7850; likely `ath11k` or a Samsung-specific out-of-tree variant.
- PMIC/charging/fuel-gauge driver — Tab S7 does not use SM5440/SM5714; the exact
  parts must be identified from Samsung's public GPL kernel source drop for the S7.
- S Pen driver — Tab S7's Wacom/Samsung digitizer is a different generation
  without BLE pairing (no "S Pen BLE" battery/gesture features possible the way
  the S9 Ultra has them); at most, hover/pressure/tilt via the passive digitizer.
- Fingerprint: base Tab S7 units largely don't have one at all (side power-button
  capacitive fingerprint exists on some regional/carrier SKUs, not a UDFPS
  sensor), so the EL721 driver work is inapplicable and this feature would likely
  be dropped rather than ported.
- Camera ISP driver and blob-derived register tables — camera modules and CamX
  blob layout differ; the HI1337/DW9808 driver and generated tables are specific
  to the S9 Ultra's actual camera hardware and firmware.
- New TWRP build, new partition/bootloader offsets, new `vbmeta`/`param` handling
  validated against this specific device's ABL — the *procedure* transfers, the
  concrete bytes/partitions do not.

## 5. Effort estimate

Realistically, this is **not a "port," it is a new device bring-up project** that
can reuse the S9 Ultra project's engineering *playbook* and Samsung-flashing
know-how, but must redo essentially all kernel/DTS/driver work against Samsung's
GPL kernel source release for the Tab S7 (`SM-T870`/`T875`) and against
whatever SM8250 mainline support already exists upstream/in postmarketOS.

Rough phases, mirroring what the S9 Ultra project itself needed:
1. Bootloader/flashing reconnaissance for `gts7` (partition layout, ABL log
   format, `vbmeta`/`param` behavior) — days, aided heavily by reusing the
   existing S9 Ultra flashing knowledge.
2. Devicetree + base mainline boot to a shell (UART/USB console, no display) —
   easier than starting cold because SM8250 already has meaningfully better
   mainline/postmarketOS support than SM8550 did when this project started.
3. Display panel + touchscreen — significant unknown effort; depends entirely on
   whether Samsung's GPL source for `gts7` is available and how close the panel
   is to existing mainline SM8250 panel drivers.
4. Wi-Fi/BT, charging, audio, sensors — one driver at a time, similar shape to
   `docs/porting-log.md` in the source project, likely weeks-to-months of
   incremental bring-up given this was true for the S9 Ultra project despite
   better tooling and more community prior art for its SoC family.
5. Userspace/Ubuntu integration and Tab Companion adaptation — comparatively
   the easiest and most reusable part.

Given the S9 Ultra project itself represents what looks like months of one
person's (AI-assisted) sustained effort on a *newer, better-documented-upstream*
chipset, a Tab S7 port of comparable completeness (working display, GPU accel,
Wi-Fi, audio, sensors, suspend/resume, dual boot) should be expected to be a
**comparable or larger undertaking**, not a quick recompile or config swap.

## 6. Verdict

- **Code reuse: low.** Nearly every kernel driver, DTS, and firmware-derived
  table in `kernel/` is tied to the SM8550/SM-X910's specific hardware and is not
  applicable to SM8250/SM-T870.
- **Process/knowledge reuse: high.** The flashing/boot-chain methodology,
  overall mainline-first + Ubuntu + dual-boot architecture, and Tab Companion
  concept are directly valuable as a blueprint.
- **External tailwind: moderate.** SM8250 has more mature upstream/postmarketOS
  support than SM8550 did, coming from the OnePlus 8-series community — this
  reduces some of the lowest-level platform bring-up work, but device-specific
  panel/touch/PMIC/camera/Wi-Fi work for the Tab S7 specifically still has to be
  done from Samsung's GPL kernel source for that device, which does not currently
  appear to have a published mainline Linux or postmarketOS port equivalent to
  the S9 Ultra one (searches turned up only downstream/Android custom kernels and
  ROMs for `gts7`, no mainline port).
- **Bottom line:** Feasible in principle (Linux mainline SM8250 support exists
  and Samsung's Tab S7 is a well-known, well-documented device in the Android
  modding community), but this would be a ground-up bring-up project using the
  S9 Ultra repository as a *methodology reference*, not as a codebase to fork and
  adapt. Expect to reuse maybe 10-20% of the actual code (packaging scripts,
  installer/flashing tooling, general docs structure) and to need fresh,
  device-specific engineering for the rest.

## Sources

- https://github.com/agcarbajo/ubuntu-galaxy-tab-s9-ultra (README, docs/development-notes.md, kernel/PROVENANCE.md)
- https://github.com/agcarbajo/postmarketos-galaxy-tab-s9-ultra
- https://www.gsmarena.com/samsung_galaxy_tab_s9_ultra-12217.php
- https://www.gsmarena.com/samsung_galaxy_tab_s7-10337.php
- https://wiki.postmarketos.org/wiki/Qualcomm_Snapdragon_865/865+/870_(SM8250)
- https://github.com/sm8250-mainline
- https://xdaforums.com/f/samsung-galaxy-tab-s7-s7-plus-roms-kernels-rec.11255/
