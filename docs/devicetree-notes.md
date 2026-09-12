# `sm8250-samsung-gts7l.dts` — Devicetree Notes

Recorded: 2026-09-11. First real Phase 1 artifact — see
`../kernel/dts/sm8250-samsung-gts7l.dts`. This document is the "how it was
derived and what's still missing" companion; the file itself carries inline
provenance comments per node.

## Method: two independent sources, cross-checked

Every hardware fact in the DTS is backed by **two independent sources** that
had to agree before being trusted:

1. **Samsung's GPL kernel source** for this device
   (`references/gts7l/arch/arm64/boot/dts/samsung/gts7l/
   kona-sec-gts7l-eur-overlay-r07.dts` — the exact board-revision overlay
   matching our unit's `androidboot.revision=7`). This is a **decompiled**
   devicetree (Samsung ships compiled `.dtbo` blobs; `references/gts7l` has
   the `.dts` form reconstructed from that), which matters because
   decompiled DTBOs lose symbolic labels — cross-references show up as raw
   phandle integers (e.g. `gpios = <0x92 0xb 0x1>`) rather than `&label`
   names. Resolving what `0x92` *is* required searching the same file for
   `phandle = <0x92>;` and reading that node's own `compatible`/context.
2. **Live introspection of the physical tablet** (rooted, stock
   `T875XXU1ATK4`) via `adb shell`:
   - `cat /proc/interrupts` — real, currently-firing interrupt names next to
     their GPIO controller and pin number (e.g. `msmgpio 15 Edge nvt-ts`).
     This was the single most valuable source: Samsung's downstream kernel
     registers descriptive IRQ names per device, so the *running* kernel
     hands you a plain-English table of "this exact pin is this exact
     device," no phandle archaeology needed.
   - `cat /sys/kernel/debug/gpio` — per-GPIO-chip electrical state
     (input/output, pull, configured or not), used to cross-check that a pin
     `/proc/interrupts` named was actually configured the way a button/irq
     line should be.

Anything that only appeared in one source, or that required guessing a
regulator/bus topology neither source directly confirmed, was left as an
explicit `TODO(phaseN)` comment in the DTS rather than filled in with a
plausible-looking value. A devicetree that silently boots into an unmapped
regulator or a `NULL` pinctrl node is a worse outcome than an honest gap.

## What this resolved

| Fact | Samsung GPL source | Live confirmation |
|---|---|---|
| Volume Up is on **PM8150L**, not PM8150 (unlike the phone reference) | DT symbol table: `.../qcom,pm8150l@4/pinctrl@c000/key_vol_up/...` | `/proc/interrupts`: `volume_up` on `pmic_arb`; `pm8150l` gpiochip's `gpio3` configured with pull-up |
| Touchscreen (Novatek NT36523 TDDI) irq = **tlmm gpio 15** | `novatek,irq-gpio = <0xffffffff 0xf 0x2002>` (0xf=15) | `/proc/interrupts`: `nvt-ts` on `msmgpio 15` |
| S Pen (Wacom W90xx) irq = **tlmm gpio 136**, pdct = **gpio 7**, fwe = **gpio 6** | `wacom,irq-gpio/pdct-gpio/fwe-gpio` = 0x88/0x7/0x6 | `/proc/interrupts`: `sec_epen_irq` on `msmgpio 136`, `sec_epen_pdct` on `msmgpio 7` |
| MAX77705 (charger/fuel-gauge/MUIC) irq = **PM8150L gpio 11** | `max77705,irq-gpio = <0x92 0xb 0x1>`, `0x92` resolved to the pm8150l gpio-controller node | `pm8150l` gpiochip's `gpio11` configured input+pull-up; `/proc/interrupts` shows a live family of `max77705` IRQs (chgin, fuelgauge, muic-*, pd-*, usbc-*) actually firing |
| Wi-Fi/BT (QCA6390) is **PCIe-attached**, not SDIO | `CONFIG_CNSS_QCA6390=y` in Samsung's defconfig | `/proc/interrupts`: `wlan_wake_irq` and `WLAN_CE_*` on the `msm_pci_msi` domain |
| S Pen AVDD supply is **PM8150 LDO13** | A second instance of the wacom node elsewhere in the GPL source: `wacom,regulator_avdd = "pm8150_l13"` | not independently live-confirmed — recorded as single-sourced |

## Kernel baseline gap discovered: missing PMICs

`sm8250-samsung-common.dtsi` (the upstream Galaxy S20 phone base chosen in
`kernel-baseline.md`) only `#include`s `pm8150.dtsi`. Our tablet's GPL source
confirms a **three-PMIC complex**: PM8150 + **PM8150L** + **PM8009** (visible
as `pm8150`, `pm8150l`, `pm8009` regulator/gpio references throughout the GPL
overlay). `sm8250-samsung-gts7l.dts` adds `#include "pm8150l.dtsi"` and
`#include "pm8009.dtsi"` directly (both mainline files exist and self-attach
to `&spmi_bus`, confirmed by grepping how `sm8250-mtp.dts` uses them) — this
was necessary just to make the `&pm8150l_gpios` label resolve at all.

## Verified: builds clean, overrides actually take effect

Built against the upstream `v7.2` tree already proven in
`build-environment.md`: copied into a scratch `work/linux` checkout,
registered in `arch/arm64/boot/dts/qcom/Makefile`, built with
`make ARCH=arm64 LLVM=1 LLVM_IAS=1 dtbs`. Result:

- **Zero DTC warnings or errors.**
- Decompiling the resulting `.dtb` back to `.dts` and grepping it confirmed
  every override actually landed: the inherited phone `chosen`/`framebuffer`
  node is gone, `key-vol-up`'s `gpios` phandle resolves to the node with
  `compatible = "qcom,pm8150l-gpio"` (not the phone's plain `pm8150-gpio`),
  and all five new pinctrl states (`vol-up-n-gts7l-state`,
  `nvt-ts-int-state`, `epen-int-state`, `epen-pdct-state`, `epen-fwe-state`,
  `max77705-int-state`) are present in the compiled output.
- This is **devicetree-level validation only** — it proves the DTS is
  syntactically correct and wires to real, existing labels, not that any of
  it works on real silicon. That requires an actual boot, which needs a
  kernel config + boot image + flashing procedure (Phase 1's remaining exit
  criteria).
- The scratch copy used for this test build was reverted afterward;
  `kernel/dts/sm8250-samsung-gts7l.dts` in the repo is the source of truth,
  not anything left in the gitignored `work/` tree.

## What's deliberately not in this file yet

Per the DTS's own inline `TODO` comments, tracked here so they're not lost:

- **Display panel** (Novatek NT36523 / PPA957DB1 WQXGA LCD) and **Adreno 650
  GPU** enablement — Phase 2.
- **Touchscreen I2C bus/address, reset-gpio, and supply rails** — only the
  irq line is confirmed; the GPL node's `reg = <0x62>` needs a bus segment
  identified.
- **Wi-Fi/BT (QCA6390) PCIe instantiation** — confirmed *that* it's
  PCIe-attached, not yet *which* PCIe root complex node, nor its enable/reset
  GPIOs and regulator supplies. Flagged as its own pass, not attempted here.
- **MAX77705 driver + regulator supply** — mainline has no
  `maxim,max77705` driver at all; this needs real driver work (Phase 3), the
  devicetree node alone doesn't get charging working.
- **Wacom S Pen driver binding** — mainline has no `wacom,w90xx` binding;
  needs evaluation against the generic Wacom I2C digitizer support (Phase 4).
- **Book Cover Keyboard** (`stm,touchpad`/`stm,keypad` pogo-pin nodes,
  confirmed present in `hardware-inventory.md`) — Phase 5.
- The inherited `reserved-memory` region addresses (`cont_splash_mem`,
  `ramoops`) are carried over from the phone reference **unverified** against
  this tablet's actual memory map. Low risk (both are advisory/no-map
  regions) but not confirmed correct.

## Next step

Phase 1's remaining exit criteria: get an actual kernel + this DTB booting on
the physical tablet far enough to reach a console — needs a `gts7l`-flavored
kernel config (starting from the `defconfig` already proven in
`build-environment.md`, adding whatever drivers the nodes above need enabled)
and a way to get it onto the device, which loops back to the still-open
recovery/flashing question in `recovery-options.md`.
