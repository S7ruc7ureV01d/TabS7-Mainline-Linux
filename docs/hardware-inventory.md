# Hardware Inventory — Galaxy Tab S7 LTE (SM-T875 / `gts7l`)

Recorded: 2026-09-11. Ground truth extracted from **Samsung's own GPL kernel
source release** for this exact model, not from marketing spec sheets. This
supersedes the guessed/spec-sheet-derived hardware assumptions in
`../PORTING_ANALYSIS.md` §2 — trust this document over that one where they
disagree.

## Source of truth

- Repo: `../references/gts7l` (cloned from
  <https://github.com/ianmacd/gts7l>)
- Origin: Samsung's official GPL source drop `SM-T875_QQ_Opensource.zip`,
  imported at bootloader version **`T875XXU1ATK1`** (commit `7f7194ed2`,
  "Import T875XXU1ATK1 from SM-T875_QQ_Opensource.zip").
- **Version gap to note:** our physical unit runs **`T875XXU1ATK4`**
  (`docs/device-state.md`), three point-releases ahead of this `ATK1` source
  drop. `ATK1`→`ATK4` is very likely security-patch-level churn rather than
  hardware/DTS changes, but this is an assumption, not a confirmed fact —
  if a later Samsung source release for `ATK4` specifically becomes available,
  diff it against this one before trusting fine details (exact regulator
  values, timing tables) at the byte level. Board topology, chip selection,
  and driver identity (the things this document lists) are extremely unlikely
  to change between four minor point releases of the same launch-era firmware.
- The repo's `master` branch has 13 commits on top of the raw `stock` import,
  all build/toolchain fixes needed to compile with a modern GCC/Clang
  (warning fixes, `AVB` disabled in `.dtsi`, a "TWRP-compatible" kernel config,
  a build script) — i.e., someone already got this exact source tree
  compiling and producing a flashable, TWRP-compatible boot image. That's a
  useful starting point for Phase 1 tooling even though our end goal is a
  mainline kernel, not this downstream one.
- Board DTS overlays exist per hardware revision:
  `arch/arm64/boot/dts/samsung/gts7l/kona-sec-gts7l-eur-overlay-r00.dts`
  through `-r07.dts` (EUR region). **Our physical unit reports
  `androidboot.revision=7` in `/proc/cmdline`** (see `device-state.md`), so
  **`kona-sec-gts7l-eur-overlay-r07.dts` is the exact board revision DTS
  matching this unit** — not just "close," but the specific file. All
  identifications below were pulled from that file unless noted.

## Confirmed hardware, with driver locations

| Component | Chip / part | Evidence | Driver location in `references/gts7l` |
|---|---|---|---|
| SoC | Qualcomm SM8250 "kona" | `arch/arm64/boot/dts/vendor/qcom/kona*.dts(i)` | n/a (matches `PORTING_ANALYSIS.md`) |
| Display panel + touch controller (TDDI) | **Novatek NT36523**, panel model **PPA957DB1**, WQXGA (1600×2560) LCD | DTS panel node `qcom,mdss-dsi-panel-name` region; `techpack/display/msm/samsung/NT36523_PPA957DB1/`; matches `/proc/cmdline`'s `msm_drm.dsi_display0=ss_dsi_panel_NT36523_PPA957DB1_WQXGA` seen live on the unit | `techpack/display/msm/samsung/NT36523_PPA957DB1/ss_dsi_panel_NT36523_PPA957DB1.c` (panel), `drivers/input/touchscreen/novatek/nt36523/nt36xxx.c` (touch — same IC family, integrated TDDI) |
| Touchscreen (as wired in DT) | Novatek `nvt-ts` | overlay r07 line ~9959: `compatible = "novatek,nvt-ts"` | `drivers/input/touchscreen/novatek/nt36523/` |
| S Pen digitizer | **Wacom W90xx-series EMR** (I2C), IC type `0x233d` | overlay r07 line ~10005: `wacom@56 { compatible = "wacom,w90xx"; ... }` | `drivers/input/wacom/wacom_i2c.c` |
| Charger + fuel gauge + MUIC + haptics | **Maxim MAX77705** | overlay r07 line ~10214: `max77705@66 { compatible = "maxim,max77705"; ... }` | `drivers/battery_v2/max77705_charger.c`, `max77705_fuelgauge.c` |
| Core power management ICs | Qualcomm reference PMICs **PM8150 + PM8009** (standard `kona` platform PMICs — not a Samsung-custom PMIC) | grep of overlay r07 for `pm8150`, `pm8009` | Qualcomm's own mainline PMIC/regulator drivers already exist upstream for this PMIC family (used by other `kona` boards, e.g. OnePlus 8) — **this is a meaningfully easier situation than the S9 Ultra's Samsung-proprietary `sm5440`/`sm5714` PMIC**, which needed bespoke drivers written from scratch |
| Wi-Fi / Bluetooth combo | **Qualcomm QCA6390** (Wi-Fi 6, "Hastings") over the `CNSS2` stack | `arch/arm64/configs/vendor/gts7l_eur_open_defconfig`: `CONFIG_CNSS2=y`, `CONFIG_CNSS_QCA6390=y` (`CNSS_QCA6290`/`CNSS_QCA6490` both explicitly unset) | Handled by mainline `ath11k` (QCA6390 support has existed upstream since roughly Linux 5.8-5.11) — meaningfully newer/better-supported than the `ath10k`/WCN399x-class chip guessed in `PORTING_ANALYSIS.md` §2 |
| Book Cover Keyboard (pogo pins) | STMicro-based trackpad + keypad, matrix labeled `"Tab S7 Book Cover Keyboard"` | overlay r07: `pogo_touchpad { compatible = "stm,touchpad"; }`, `pogo_kpd { compatible = "stm,keypad"; ...keypad,input_name = "Tab S7 Book Cover Keyboard"; }` | Samsung-specific; no direct mainline equivalent identified yet |
| GPIO buttons | Volume up/down, power | overlay r07 `gpio_keys` node | standard `gpio-keys`, already mainline |

## What this changes vs. the original feasibility analysis

`PORTING_ANALYSIS.md` (written before this source was available) guessed at
Tab S7 hardware from spec sheets and reasoned from silence. Concretely:

- **Wi-Fi/BT is QCA6390, not an older WCN399x/`ath10k`-class chip** as
  guessed — this is *better* news than assumed: QCA6390 has real `ath11k`
  mainline support, likely close in maturity to what the S9 Ultra project
  needed to write from scratch for its newer chip.
- **Core PMIC is Qualcomm reference silicon (PM8150/PM8009), not a
  Samsung-proprietary PMIC.** The S9 Ultra project's biggest, most
  bespoke driver-writing effort was around Samsung's own `sm5440`/`sm5714`
  PMIC family. The Tab S7's *charging/fuel-gauge/MUIC* IC (MAX77705) is still
  Samsung/Maxim-specific and will need porting, but the *core rails* driving
  the SoC itself are standard and should mostly just work with existing
  mainline `kona`/SM8250 PMIC support.
- **Touch and display are one IC (Novatek NT36523 TDDI)**, not separate
  panel + touch chips — bring-up for both is tied together; there is no
  separate touchscreen chip to identify.
- **S Pen is a plain EMR digitizer (Wacom W90xx), no BLE** — confirms the
  roadmap's Phase 4 assumption that S9-Ultra-style "S Pen BLE" features
  (battery, air gestures, pairing) do not apply to this device; only
  hover/pressure/tilt over I2C are in scope.
- **The Book Cover Keyboard is real and its DT node is now known** — useful
  for a Phase 5 "Tab Companion"-equivalent keyboard-remap feature, mirroring
  the S9 Ultra project's tested `EF-DX920` support.

## Other repositories cloned into `references/` during this pass

- **`references/gts7l`** — as above; the primary hardware ground truth.
- **`references/linux`** (from `sm8250-mainline/linux`) — a community
  mainline-Linux tree specifically targeting SM8250 ("kona") devices (their
  README lists devices like the Lenovo Xiaoxin Pad Pro 2021, also `kona`-based).
  Not Tab-S7-specific, but the closest existing *mainline* starting point for
  SM8250 platform bring-up (clocks, RPMh, pinctrl, base DRM/KMS) — evaluate
  this as the base to fork a `gts7l` board file onto, rather than starting a
  DTS from Qualcomm's raw AOSP kona reference tree.
- **`references/pmos-pmaports`** (from `sm8250-mainline/pmos-pmaports`) — the
  postmarketOS device packages for that same SM8250-mainline community effort.
  Useful as a packaging template once we reach Phase 5-equivalent work, and as
  a second data point (alongside `references/postmarketos-galaxy-tab-s9-ultra`)
  for how postmarketOS structures a device port.
- **Noted but not cloned:** `mtan221/T875_SM8250` — "Android 11 Linux Kernel
  for Samsung Galaxy Tab S7 (SM-T875) based on SM8250-AB for SM-T870" — a
  further downstream custom-kernel effort (still Android/non-mainline) that
  updated this same source to Android 11. Worth a look later if a specific
  downstream driver fix is needed that Samsung's original `ATK1` drop lacks,
  but not needed for the mainline bring-up path itself. Not cloned to avoid
  reference-repo sprawl; revisit if a concrete need comes up.
- Confirmed (again) that no mainline Linux or postmarketOS port for `gts7`/
  `gts7l` was found to already exist anywhere — this remains a from-scratch
  bring-up, using the S9 Ultra project as a methodology template and this
  hardware inventory as the ground truth, per `PORTING_ANALYSIS.md`.
