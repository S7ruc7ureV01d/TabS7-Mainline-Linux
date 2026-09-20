# Phase 3 scoping: Wi-Fi/Bluetooth (Qualcomm QCA6390)

Recon pass before starting real Wi-Fi/Bluetooth bring-up, done
2026-09-20 right after the touchscreen firmware-flash fix
(`docs/kernel-boot-debugging.md` "touch debugging" section). Goal: find
out how much of the bring-up is genuinely new work versus reusable
mainline infrastructure, before writing any DTS/config changes. Nothing
here has been built or tested yet - this is pure research, recorded for
when that work starts, following the same methodology
`docs/phase2-touchscreen-scoping.md` used for touch (real sources
cited, nothing assumed).

## The chip and its transport

Combo chip confirmed **Qualcomm QCA6390** (Wi-Fi 6 "Hastings" +
Bluetooth), PCIe-attached, per `docs/hardware-inventory.md`. Unlike the
touchscreen (a from-scratch driver was needed), **this is a much more
mainline-friendly situation**: QCA6390 has real, mature `ath11k`
(Wi-Fi) and `btusb`-adjacent MHI-transport Bluetooth support already in
current mainline, and - critically - a **directly comparable, real
shipping mainline board already wires up the exact same chip on the
exact same SoC**: `work/linux/arch/arm64/boot/dts/qcom/
sm8250-xiaomi-elish-common.dtsi` (the same reference board this
project's panel and GPU work already used). This is a "adapt a working
example" task, not a "port a driver from scratch" task like touch was.

## Correcting an initial wrong assumption: which PCIe root port

The downstream WLAN node itself
(`references/gts7l/arch/arm64/boot/dts/vendor/qcom/kona.dtsi:4747`,
`wlan: qcom,cnss-qca6490@b0000000`) does **not** carry its own
`qcom,pcie-parent` property. The real PCIe attachment is set by an
override further down the same file:

```
&pcie0_rp {
	...
	cnss_pci: cnss_pci {
		reg = <0 0 0 0 0>;
		qcom,iommu-group = <&cnss_pci_iommu_group>;
		memory-region = <&cnss_wlan_mem>;
		...
	};
};
```
(`kona.dtsi:5020-5041`) - **`cnss_pci` (our QCA6390) lives on
`pcie0_rp`**, not `pcie1_rp`. A separate `wil6210: qcom,wil6210` node
(`kona.dtsi:4911-4930`) does carry `qcom,pcie-parent = <&pcie1>`, but
that's Qualcomm/Facebook's unrelated 60GHz "Terragraph" WiGig radio -
explicitly `status = "disabled"` on this device (`kona.dtsi:4930`) and
out of scope entirely. Easy to conflate at a glance since both nodes
are near each other and both mention "pcie1"/"wlan" in nearby text -
worth flagging so a future pass doesn't repeat the mistake.

This means gts7l matches elish's mainline pattern exactly - both use
**PCIe controller 0** (`&pcie0`/`&pcieport0`) for WLAN. No board-routing
mismatch to reconcile.

## Real hardware facts, PCIe0 controller itself

From `references/gts7l/arch/arm64/boot/dts/vendor/qcom/kona-pcie.dtsi`
(lines 1-110), cross-checked against `work/linux/arch/arm64/boot/dts/
qcom/sm8250.dtsi`'s own `pcie0`/`pcie0_phy` nodes (lines 2131-2254):

| Property | Value | Source |
|---|---|---|
| PERST GPIO | GPIO 79, active-low | `kona-pcie.dtsi:32` (`perst-gpio = <&tlmm 79 0>`) - **matches mainline's own hardcoded `perst-gpios = <&tlmm 79 GPIO_ACTIVE_LOW>`** (`sm8250.dtsi:2201`) exactly, byte-for-byte. This GPIO is apparently fixed at the SoC reference-board level, not board-specific. |
| WAKE GPIO | GPIO 81, active-high | `kona-pcie.dtsi:33` - **also matches mainline's hardcoded `wake-gpios = <&tlmm 81 GPIO_ACTIVE_HIGH>`** (`sm8250.dtsi:2202`) exactly. |
| PCIe0 controller regulators (downstream names) | `vreg-1p8-supply = <&pm8150_l9>`, `vreg-0p9-supply = <&pm8150_l5>` | `kona-pcie.dtsi:46-48` |
| Mainline PHY status | `&pcie0`/`&pcie0_phy` both `status = "disabled"` by default in `sm8250.dtsi` | `sm8250.dtsi:2206`, `:2254` - **same "disabled by default in the SoC dtsi" pattern this project already solved for `qupv3_id_0`/`gpi_dma0`** (touch/panel bring-up) - just needs `status = "okay"` on both. |

Since both the PERST and WAKE GPIOs are hardcoded identically in
mainline's own `sm8250.dtsi` (not something a board `.dts` overrides)
and match Samsung's downstream values exactly, **no GPIO-number
discovery work is needed here** - unlike touch, where the IRQ GPIO had
to be pulled from the board overlay.

## What elish's mainline DTS already does (the pattern to adapt)

`sm8250-xiaomi-elish-common.dtsi`, read in full for every WLAN/BT
section:

- **A `qca6390-pmu` platform node** (lines 103-166ish), `compatible =
  "qcom,qca6390-pmu"`, with `pinctrl-0 = <&bt_en_state>,
  <&wlan_en_state>`, and this full regulator chain: `vddaon-supply`,
  `vddpmu-supply`, `vddrfa0p95-supply` (all `&vreg_s6a_0p95`),
  `vddrfa1p3-supply` (`&vreg_s8c_1p35`), `vddrfa1p9-supply`
  (`&vreg_s5a_1p9`), `vddpcie1p3-supply`/`vddpcie1p9-supply` (same two
  rails reused), `vddio-supply` (`&vreg_s4a_1p8`),
  `wlan-enable-gpios = <&tlmm 20 GPIO_ACTIVE_HIGH>`,
  `bt-enable-gpios = <&tlmm 21 GPIO_ACTIVE_HIGH>`. It also declares an
  internal `regulators { ldo0..ldoN }` sub-block naming the PMU's own
  internally-sequenced output rails (`vreg_pmu_rfa_cmn`,
  `vreg_pmu_aon_0p59`, etc.) that the actual WLAN PCI device node then
  consumes.
- **`&pcie0 { status = "okay"; }`** and **`&pcie0_phy { vdda-phy-supply
  = <&vreg_l5a_0p88>; vdda-pll-supply = <&vreg_l9a_1p2>; status =
  "okay"; }`** - just enabling the controller/PHY with board-specific
  analog supplies, no other overrides.
- **`&pcieport0 { wifi@0 { ... } }`** - the actual WLAN PCI endpoint,
  `compatible = "pci17cb,1101"` (QCA6390's real PCI vendor:device ID,
  matched by `ath11k_pci`'s own ID table, not a devicetree-only
  compatible string), `reg = <0x10000 0x0 0x0 0x0 0x0>;`, consuming
  the PMU-sequenced rails by name (`vddrfacmn-supply =
  <&vreg_pmu_rfa_cmn>`, etc., all 9 of them), plus one board-identity
  property: `qcom,calibration-variant = "Xiaomi_Pad_5Pro";`.

**No separate Bluetooth devicetree node exists at all** in elish - the
`qca6390-pmu`'s own `bt-enable-gpios` is the only BT-specific wiring;
actual Bluetooth then comes up automatically over the same PCIe
link via `btusb`'s or `ath11k`-adjacent QMI/MHI handling once WLAN
enumerates (QCA6390 is architecturally a single PCIe function serving
both radios, sequenced by the one PMU). This matches downstream's own
single combined `wlan: qcom,cnss-qca6490` node, which has no separate
Bluetooth node either.

## Mapping gts7l's real regulators onto the elish pattern

Downstream's `vdd-wlan-*`/`wlan-ant-switch` names (from the "Real
hardware facts" table in the intro) don't share elish's exact property
names (elish's driver, `qcom,qca6390-pmu`, uses `vddaon`/`vddpmu`/
`vddrfa0p95`/etc.; downstream's separate `qcom,cnss-qca6490` driver
uses `vdd-wlan-aon`/`vdd-wlan-dig`/etc. - two different Linux drivers
for the same chip, different binding vocabularies), but the **physical
PMIC rails they point at are directly comparable by role**:

| Role | gts7l downstream rail | elish mainline rail | Match confidence |
|---|---|---|---|
| AON/always-on | `pm8150_s6` (`vdd-wlan-aon-config = <950000...>`) | `vreg_s6a_0p95` | High - both ~0.95V, both an `S6`-suffixed switcher |
| RFA (RF analog) tier 1 | `pm8150_s5` (2040000, i.e. ~2.04V - `vdd-wlan-rfa1`) | `vreg_s5a_1p9` (~1.9V) | Medium - same `S5` rail, close but not identical voltage; downstream's own value may be this exact unit's real config, worth trusting over elish's guess |
| RFA tier 2 | `pm8150a_s8` (1350000) | `vreg_s8c_1p35` | High - same `S8` rail, same ~1.35V |
| Digital core | `pm8009_s2` (950000/952000) | not separately named in elish (folded into `vddpmu`) | needs real testing |
| I/O | `pm8150_s4` (1800000) | `vreg_s4a_1p8` | High - same `S4` rail, same 1.8V |
| Antenna switch | `pm8150a_l5` (1800000) | not present in elish (board-specific extra) | gts7l-specific, keep as its own regulator reference |

This table is a **starting hypothesis for the DTS work, not yet
verified** - the actual gts7l-specific regulator *labels* (`pm8150_s6`
etc. are downstream's own driver-internal names, not necessarily what
this project's already-written `sm8250-samsung-gts7l.dts` calls the
same physical PMIC outputs) need to be cross-checked against whatever
PM8150/PM8150L/PM8009 regulator nodes this project's DTS already
defines (inherited from `sm8250-samsung-common.dtsi` plus this
project's own PM8150L/PM8009 `#include`s, per the Phase 1 roadmap
entry) before writing the `qca6390-pmu` node.

## Kernel config: already closer to ready than touch was

Checked `work/linux/.config` (built from `defconfig` +
`kernel/config/gts7l.fragment`) directly:

- **`CONFIG_ATH11K=m`, `CONFIG_ATH11K_AHB=m`, `CONFIG_ATH11K_PCI=m`** -
  already enabled as modules by plain `defconfig`, no fragment change
  needed for the Wi-Fi driver itself.
- **`CONFIG_PCIE_QCOM=y`, `CONFIG_PCIE_QCOM_COMMON=y`** - PCIe
  controller driver already built-in.
- **`CONFIG_MHI_BUS=m`, `CONFIG_MHI_BUS_PCI_GENERIC=m`** - MHI
  transport (what `ath11k_pci` uses to talk to QCA6390 over PCIe)
  already enabled as a module.
- **`CONFIG_POWER_SEQUENCING_QCOM_WCN` is NOT currently set** (not
  present anywhere in the resolved `.config`, despite `drivers/power/
  sequencing/Kconfig` declaring `default m if ARCH_QCOM` for it, and
  `CONFIG_ARCH_QCOM=y`/`CONFIG_POWER_SEQUENCING=y` both already being
  set) - **this is the one real gap**: the `qcom,qca6390-pmu` driver
  itself (`drivers/power/sequencing/pwrseq-qcom-wcn.c`, confirmed via
  its own `.compatible = "qcom,qca6390-pmu"` match table entry at
  line 568) needs `CONFIG_POWER_SEQUENCING_QCOM_WCN=y` (or `=m`)
  explicitly added to `kernel/config/gts7l.fragment`. Unclear why the
  `default m if ARCH_QCOM` didn't already take effect - worth checking
  whether `merge_config.sh`/our fragment process resolves defaults
  correctly, or whether it just needs to be stated explicitly like
  every other gts7l-specific symbol in the fragment already is.

## Open question, not yet answered: modules vs. built-in

`ATH11K`/`ATH11K_PCI`/`MHI_BUS`/`MHI_BUS_PCI_GENERIC` are all currently
`=m` (loadable modules) from plain `defconfig`. **This project has
never loaded a kernel module at runtime before** - every driver so far
(UFS SCSI, the touch/panel/ISL98608 drivers) has been forced built-in
(`=y`), and a `grep` of `kernel/initramfs/init` found zero
module-loading infrastructure (no `modprobe`/`insmod`/`depmod` calls,
no `/lib/modules` handling). Two real options, not yet decided:

1. **Force everything built-in** (`=y`), matching this project's
   existing pattern exactly and requiring zero new infrastructure -
   the simplest, lowest-risk path, at the cost of a somewhat larger
   kernel image.
2. **Set up real module loading** for the first time, now that Phase 5
   means the rootfs is a genuine persistent Arch Linux install (not a
   disposable initramfs) - `pacman`'s own `linux`-adjacent tooling
   normally handles `depmod`/module installation automatically, and
   Arch's own init (systemd) auto-loads modules for enumerated
   hardware without any custom scripting, unlike the old busybox
   initramfs. This is more "the normal way a real distro works" but is
   new ground for this project's build pipeline (kernel `Image` and
   `modules_install` output would need to reach the Arch rootfs
   together, kept in version lock-step).

Recommendation, not yet acted on: given Phase 5 already establishes a
real persistent rootfs with `pacman` and full `systemd`, option 2 is
probably the right long-term direction (a real Wi-Fi driver update
shouldn't require a full kernel reflash-via-TWRP cycle forever), but
option 1 is the safer **first** bring-up test (isolates "does the
hardware/DTS work at all" from "does module loading work", the same
"single-variable" testing discipline this project used successfully
throughout Phase 1's ABL debugging). Suggest bringing it up built-in
first, confirming a real Wi-Fi association, then revisiting
modules for the production/Phase 5-packaging version.

## Firmware: the real open question, needs live device access

QCA6390 needs real firmware/calibration blobs for `ath11k` to do
anything (`board-2.bin`, `amss.bin`, and related files, normally under
`/lib/firmware/ath11k/QCA6390/hw2.0/` - `ath11k`'s standard
`request_firmware()` layout, confirmed by mainline driver convention,
not yet directly inspected in `work/linux/drivers/net/wireless/ath/
ath11k/` source this session). Searched the GPL kernel source dump
(`references/gts7l/drivers/net/wireless/qualcomm/qca6390/`) for actual
firmware binary blobs - **found none**: that directory only has driver
*source* (`qcacld-3.0`, `qca-wifi-host-cmn`, `fw-api` headers), no
`.bin`/`.mbn` files anywhere in the repository. This is expected -
firmware blobs live on the device's own `/vendor/firmware` partition,
not in a GPL kernel source release, **exactly the same situation this
project already solved once**: the Adreno 650 GPU's zap-shader blob
also wasn't in any source dump and had to be pulled directly off this
physical unit's own `apnhlos`/`vendor` partitions
(`docs/kernel-boot-debugging.md`, "Adreno 650 GPU bring-up").

Genuinely unknown, not yet checked:
- Whether generic `linux-firmware.git` QCA6390 blobs (not
  device-specific) are sufficient for basic association, or whether
  real per-device calibration data (an NVM/board-data file analogous
  to the GPU's per-panel zap shader) is required for RF to actually
  work correctly. `ath11k`'s `board-2.bin` mechanism is explicitly
  designed to carry multiple board-specific calibration variants
  selected by a `bus=pci,vendor=17cb,device=1101,...` compatible
  string (visible in elish's own `qcom,calibration-variant =
  "Xiaomi_Pad_5Pro"` property) - if gts7l's real variant isn't already
  one of the ones bundled in upstream `linux-firmware.git`'s
  `board-2.bin`, Wi-Fi may enumerate but perform poorly or not
  associate at all without a real device-specific extraction.
- Exact path/filename of gts7l's real on-device WLAN calibration data
  (likely somewhere under `/vendor/firmware/wlan/` or similar on the
  live device, per the downstream driver's own `qcacld-3.0` config
  conventions - not yet located, would need a live `adb`/TWRP session
  to search for, same as the zap-shader extraction).

## Suggested next step when this work actually starts

Mirror the order that worked for touch and GPU bring-up: get the
hardware path enumerating before writing any driver-specific
config. Concretely:
1. Enable `&pcie0`/`&pcie0_phy` (`status = "okay"`, PHY analog
   supplies once the regulator-name cross-check above is resolved).
2. Add the `qca6390-pmu` node (adapted from elish, with gts7l's own
   `wlan-enable-gpios`/`bt-enable-gpios` - **note**: elish uses GPIO 20
   for WLAN-enable and GPIO 21 for BT-enable; downstream's
   `wlan-en-gpio = <&tlmm 20 0>` (`kona.dtsi:4752`) matches GPIO 20
   exactly, but downstream's BT-enable GPIO wasn't found in `kona.dtsi`
   under the `wlan` node - worth checking the board overlay
   (`kona-sec-gts7l-eur-overlay-r07.dts`) for a real BT-enable pin
   before assuming GPIO 21 carries over unchanged).
3. Add `CONFIG_POWER_SEQUENCING_QCOM_WCN=y` to `gts7l.fragment`.
4. Add the `wifi@0` PCI endpoint node under `&pcieport0`, generic
   `linux-firmware.git` blobs first (fastest path to "does it even
   enumerate"), decide on built-in-vs-module per the open question
   above (recommend built-in for this first test).
5. Confirm real PCIe enumeration (`lspci`/`/sys/bus/pci/devices/`)
   before worrying about actual Wi-Fi association or real calibration
   data - the same "confirm the hardware path exists before building
   on top of it" discipline `docs/phase2-touchscreen-scoping.md` used
   for the touch I2C bus.
6. Only once PCIe enumeration is confirmed, chase real firmware/
   calibration data (device extraction, mirroring the GPU zap-shader
   precedent) and real Wi-Fi association.

## Status: Wi-Fi working on real hardware (2026-09-20)

Implementation happened the same day this doc was written. Real results,
corrections to what's written above, and what's still open:

**Correction**: "No separate Bluetooth devicetree node exists at all in
elish" above is **wrong** - a fuller read of the file found
`&uart6 { bluetooth { compatible = "qcom,qca6390-bt"; ... }; };`.
Bluetooth rides a completely separate UART transport, not the PCIe link
at all. Not wired up yet - deferred, needs its own UART-instance
research on this board. `bt-enable-gpios` on `qca6390-pmu` is still
correct regardless (the PMU chip sequences power for both radios
together no matter which transport BT ends up using).

**GPIO correction confirmed real, not just cautious**: this board's
actual `wlan-enable`/`bt-enable` GPIOs are 90/76, not elish's 20/21 -
confirmed two independent ways in the downstream overlay (the real,
`status = "ok"` `bt_qca6390` node's `qca,bt-reset-gpio` and its shared
regulator voltage levels matching the `wlan` node's own config
byte-for-byte). Good thing this wasn't assumed from elish directly.

**Real PCIe enumeration achieved, but not from the DTS/regulator work
alone** - a second real bug, invisible at the Kconfig-dependency level:
`&pcie0`'s own PHY (`phy@1c06000`) had **no driver at all**, because
`CONFIG_PHY_QCOM_QMP_PCIE` was still `=m` from plain `defconfig`. This
project has no module-loading infrastructure, so a `=m` driver here is
silently indistinguishable from "doesn't exist" - confirmed live via
`phy@1c06000` having no `driver` symlink and `1c00000.pcie` sitting
permanently in `/sys/kernel/debug/devices_deferred` with an *empty*
reason (a `phy_get()` call that never printed anything on its own
failure). Forced `=y`; PCIe linked up immediately after
(`PCIe Gen.2 x1 link up`, QCA6390 shows up as a real PCI device).

**Firmware: went with real device extraction directly, not generic
linux-firmware.git blobs** (per the owner's explicit direction) - see
`kernel/config/gts7l.fragment`'s own comments for the full pull
(`/vendor/firmware/qca6390/{amss20.bin,m3.bin,regdb.bin,bdwlan.elf}`,
mounted via `/dev/block/mapper/vendor` in TWRP). All four confirmed
genuinely correct: manually rebinding `ath11k_pci` with these files
present loaded real Samsung firmware
(`fw_version 0x10138081`/`WLAN.HST.1.0.1.c6-00129-...`) and brought up
a working `wlp1s0` that scans and sees dozens of real access points.

**A real boot-partition size constraint, hit and safely recovered
from**: baking the ~4.5MB of Wi-Fi firmware into the kernel image via
`CONFIG_EXTRA_FIRMWARE` (the same approach used for touch) produced a
boot.img 825408 bytes larger than the `boot` partition's real, fixed
capacity - confirmed by a genuine `dd` `ENOSPC` error on real hardware.
Round75's kernel (PCIe/PHY fix, no Wi-Fi firmware) was already filling
almost the entire partition with zero headroom left. Restored the
known-good image immediately, then took the architecturally correct
path instead: unlike touch (needed at the very first I2C probe before
anything else can even talk to that bus), `ath11k` probes well after
the real Arch rootfs is mounted, so these four files live at a real
`/lib/firmware/ath11k/QCA6390/hw2.0/` path on the persistent rootfs,
not baked into the kernel at all.

**One more real bug, fixed with a systemd service, not a kernel
change**: `ath11k_pci`'s very first probe attempt happens before
`switch_root` swaps in the real Arch rootfs, so `request_firmware_direct()`
for `amss.bin` genuinely can't see `/lib/firmware` yet on a cold boot -
confirmed live, this failure was 100% reproducible on every cold boot.
A plain PCI unbind/bind once the real root is up succeeds every time.
`wlan-pci-rebind.service` (`work/archroot-build/wlan-pci-rebind.{sh,service}`,
same gitignored-source pattern as `usb-gadget-ecm.service`) redoes that
unbind/bind after `local-fs.target` - **confirmed working across a
genuine cold reboot with zero manual intervention**,
`systemctl is-system-running` → `running`, `wlp1s0` present and
scanning.

**Plasma UI**: `NetworkManager` itself was already installed and
running (from earlier Phase 5 package installs) and immediately showed
`wlp1s0` correctly as a managed Wi-Fi device (`nmcli device status`) -
but no Wi-Fi icon appeared anywhere in Plasma's system tray, because
`plasma-nm` (the actual Plasma applet package - separate from
`networkmanager` itself) was never installed. Installed it
(`pacman -S plasma-nm`, pulled in `networkmanager-qt`/`modemmanager`/
`modemmanager-qt`/`qtkeychain-qt6`/`ppp` as dependencies) and restarted
`sddm` to get a fresh `plasmashell`. **Confirmed by the owner directly
on the physical screen**: the Wi-Fi icon is now present in the system
tray.

**Still open, deliberately deferred**:
- Bluetooth (separate UART transport, not researched yet - see
  correction above).
- Making the firmware files *and* `plasma-nm`/its dependencies part of
  a reproducible build/install step rather than one-off `scp`/`pacman`
  commands run by hand on the live rootfs (this project has no
  `packaging/` directory yet at all - Phase 5's own exit criteria
  already flags this same gap for the base rootfs build).
- Actually connecting to a network end-to-end (association + DHCP +
  browsing) - confirmed so far: real `iw scan` results, `wlp1s0`
  correctly managed by NetworkManager, and the Plasma applet visible,
  but no real connection attempt made yet.
- Understanding *why* the PCI probe races ahead of `switch_root` (the
  rebind service works around it reliably, but the root timing cause
  itself wasn't investigated - lower priority since the workaround is
  solid).

Full driver-independent build details (DTS, Kconfig, firmware fragment
comments) in `kernel/dts/sm8250-samsung-gts7l.dts` and
`kernel/config/gts7l.fragment` directly.
