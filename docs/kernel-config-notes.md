# `gts7l` Kernel Config — Notes

Recorded: 2026-09-11. Companion to `../kernel/config/gts7l.fragment`.

## Method

Rather than write a kernel config from scratch or copy Samsung's downstream
`gts7l_eur_open_defconfig` wholesale (a 4.19-era, thousands-of-lines,
Android-specific config not meaningfully portable to mainline `v7.2`), the
plain upstream `arch/arm64/configs/defconfig` was audited symbol-by-symbol
against every piece of hardware confirmed in `hardware-inventory.md` and
wired up in `sm8250-samsung-gts7l.dts`. The question for each was: *is this
already on, and if not, does Phase 1 (boot to a console, mount root) actually
need it, or is it a later-phase concern?*

## Result: defconfig already covers nearly everything Phase 1 needs

Checked and already `=y` (built-in) in plain `defconfig`, no fragment entry
needed:

- Core SoC platform: `PINCTRL_SM8250`, `COMMON_CLK_QCOM`, `SM_GCC_8250`,
  `SM_DISPCC_8250`, `QCOM_RPMH`, `QCOM_RPMHPD`, `REGULATOR_QCOM_RPMH`,
  `INTERCONNECT_QCOM`
- IPC/platform plumbing: `QCOM_SMEM`, `QCOM_SMP2P`, `QCOM_SMD_RPM`,
  `QCOM_APCS_IPC`, `MAILBOX`, `QCOM_COMMAND_DB`, `QCOM_TSENS`
- PMIC: `SPMI`, `MFD_SPMI_PMIC`, `PINCTRL_QCOM_SPMI_PMIC` (covers the
  PM8150/PM8150L/PM8009 GPIO pinctrl our DTS uses), `INPUT_PM8941_PWRKEY`
  (covers both the power key *and* the volume-down/`pon_resin` line our DTS
  relies on)
- Input: `KEYBOARD_GPIO` (the actual Kconfig name behind the `gpio-keys`
  driver our volume-up node uses - there's no separate `INPUT_GPIO_KEYS`
  symbol, despite that being an easy name to expect and search for first)
- Console/debug: `SERIAL_QCOM_GENI` + `SERIAL_QCOM_GENI_CONSOLE` (real UART
  console), `DEBUG_FS` (this is exactly what made the live GPIO/interrupt
  cross-checks in `devicetree-notes.md` possible on the stock kernel, and
  will matter again once we're debugging our own boots), `PSTORE`
- Boot mechanics: `MODULES`, `BLK_DEV_INITRD`, `DEVTMPFS` + `DEVTMPFS_MOUNT`

Left as modules (`=m`), correctly, since Phase 1 doesn't need them and
forcing them built-in would only bloat the image: `ATH11K`/`ATH11K_PCI`
(Wi-Fi, Phase 3), `DRM_MSM` (display, Phase 2), `QCOM_Q6V5_ADSP`/`_MSS`
(audio/modem remoteproc, Phase 3), `I2C_QCOM_GENI`/`SPI_QCOM_GENI` (touch/S
Pen buses, Phase 2/4), `QCOM_SPMI_TEMP_ALARM`, `PSTORE_RAM` (the `ramoops`
backend - our DTS's `ramoops` node region is inherited/unverified anyway per
`devicetree-notes.md`, not worth chasing further right now).

## What the fragment actually changes, and why

Only **root storage** needed forcing built-in — everything else Phase 1
needs was already there:

```
CONFIG_SCSI_UFS_QCOM=y
CONFIG_PHY_QCOM_QMP=y
CONFIG_PHY_QCOM_QMP_UFS=y
```

`defconfig` ships both the UFS host controller (`SCSI_UFS_QCOM`) and its PHY
(`PHY_QCOM_QMP_UFS`) as modules. For a *first* boot attempt on unfamiliar
hardware, the fewer moving parts between "kernel starts" and "root
filesystem is mounted" the better — an initramfs that has to find and load
the right `.ko` files in the right order to reach its own root is one more
way for a first attempt to fail opaquely. Built-in removes that variable
entirely.

**Gotcha hit while doing this:** setting `CONFIG_PHY_QCOM_QMP_UFS=y` alone in
the fragment silently didn't take — `merge_config.sh` + `olddefconfig` left
it at `=m`. Cause: `PHY_QCOM_QMP_UFS` lives inside an `if PHY_QCOM_QMP`
Kconfig block (`PHY_QCOM_QMP` is itself a `menuconfig` tristate), so a
symbol nested under it can never exceed its parent's value - and the parent
was still `=m` from `defconfig`. Had to also promote `CONFIG_PHY_QCOM_QMP=y`
in the fragment before the child would actually reach `=y`. Promoting the
parent pulled its sibling submenu drivers (`PHY_QCOM_QMP_PCIE`,
`PHY_QCOM_QMP_PCIE_8996`, `PHY_QCOM_QMP_USB`) up to `=y` too, as a side
effect of their own `default PHY_QCOM_QMP` Kconfig lines — harmless (bigger
image, nothing functionally wrong), just worth knowing if the image size
looks larger than expected later. Worth remembering this parent/child
tristate-ceiling pattern for any other Qualcomm QMP-PHY-family symbol this
project needs to force built-in later (USB, PCIe/Wi-Fi in Phase 3).

## Verified

Merged and built against the same `v7.2` tree used throughout Phase 0/1:

```sh
make ARCH=arm64 LLVM=1 LLVM_IAS=1 defconfig
./scripts/kconfig/merge_config.sh -O <tree> -m arch/arm64/configs/defconfig \
    kernel/config/gts7l.fragment
make ARCH=arm64 LLVM=1 LLVM_IAS=1 olddefconfig
make ARCH=arm64 LLVM=1 LLVM_IAS=1 -j20 Image dtbs
```

Result: **clean build, zero warnings**, `CONFIG_SCSI_UFS_QCOM=y`,
`CONFIG_PHY_QCOM_QMP=y`, `CONFIG_PHY_QCOM_QMP_UFS=y` all confirmed in the
final `.config`. Same caveat as the devicetree: this proves the config
merges and builds correctly, not that it boots — that's the next, and last,
Phase 1 exit criterion.

## Not yet done

- No actual boot attempt yet - needs a boot image (`Image` + our
  `sm8250-samsung-gts7l.dtb`, likely packaged via `mkbootimg` given it's
  already confirmed present per `build-environment.md`) and a way onto the
  device, which is still blocked on the open recovery/flashing decision in
  `recovery-options.md`.
- This fragment will grow in later phases (display, touch/S-Pen buses,
  charging, Wi-Fi) as those get tackled - it's deliberately minimal right
  now, not a place to preemptively stage config for hardware the devicetree
  doesn't wire up yet.
