# Phase 3 scoping: Bluetooth (Qualcomm QCA6390, UART transport)

Recon pass before starting real Bluetooth bring-up, done 2026-09-20
right after Wi-Fi (the other half of the same QCA6390 combo chip) got
fully working on real hardware
(`docs/phase3-wifi-bt-scoping.md`/`docs/kernel-boot-debugging.md`).
Goal: find the real UART instance and confirm how much of this is
reusable versus genuinely new work, before writing any DTS/config
changes. Nothing here has been built or tested yet - this is pure
research, following the same methodology as the Wi-Fi and touchscreen
scoping docs (real sources cited, nothing assumed).

## Same chip, completely different transport - already flagged, now confirmed

As found (and corrected in-doc) during Wi-Fi bring-up: Bluetooth on
QCA6390 does **not** ride the PCIe link WLAN just got working on. It's
a genuinely separate UART transport. Confirmed directly in mainline's
own reference board for this exact chip on this exact SoC
(`work/linux/arch/arm64/boot/dts/qcom/sm8250-xiaomi-elish-common.dtsi`,
lines 813-826):

```
&uart6 {
	status = "okay";

	bluetooth {
		compatible = "qcom,qca6390-bt";

		vddrfacmn-supply = <&vreg_pmu_rfa_cmn>;
		vddaon-supply = <&vreg_pmu_aon_0p59>;
		vddbtcmx-supply = <&vreg_pmu_btcmx_0p85>;
		vddrfa0p8-supply = <&vreg_pmu_rfa_0p8>;
		vddrfa1p2-supply = <&vreg_pmu_rfa_1p2>;
		vddrfa1p7-supply = <&vreg_pmu_rfa_1p7>;
	};
};
```

All six of those `vreg_pmu_*` regulator labels are the exact same
`qca6390-pmu`-internal sub-nodes our own gts7l DTS already defines
(`kernel/dts/sm8250-samsung-gts7l.dts`, added for Wi-Fi bring-up) -
this part is **already done**, zero new regulator work needed.

## Real hardware fact: which UART instance, resolved with real evidence

This was the one genuinely open question going in. Two different UART
instances looked plausible at a glance in Samsung's downstream overlay
(`references/gts7l/arch/arm64/boot/dts/samsung/gts7l/
kona-sec-gts7l-eur-overlay-r07.dts`) - easy to pick the wrong one:

- `qupv3_se12_2uart` (SE12, register `0xa90000`) - has its own
  board-specific pinctrl block right in the overlay
  (`qupv3_se12_2hsuart_pins`, fragment@82, real pins TX=GPIO34/RX=GPIO35)
  and its label literally contains "hsuart". Looked like the obvious
  candidate at first.
- `qupv3_se6_4uart` (SE6, register `0x998000`) - only toggled
  `status = "ok"` in the overlay (fragments 47/144), no board-specific
  pin override at all.

**SE6 is the real one**, confirmed two independent ways:

1. Its base definition in `references/gts7l/arch/arm64/boot/dts/
   vendor/qcom/kona-qupv3.dtsi:83` (`qupv3_se6_4uart: qcom,qup_uart@998000`)
   carries `qcom,wakeup-byte = <0xFD>` - a real, distinctive Qualcomm
   HS-UART/QCA-Bluetooth integration property (the byte the host sends
   to wake the BT controller from UART sleep). Mainline's own
   `drivers/bluetooth/hci_qca.c` sends the exact same `0xFD` IBS wake
   command (`qca_serdev_shutdown()`'s `ibs_wake_cmd`) - not a
   coincidence.
2. It's 4-wire (`qupv3_se6_default_cts`/`_rtsrx`/`_tx` - real hardware
   flow control), while SE12 is 2-wire only (TX/RX, no CTS/RTS) despite
   its "hsuart"-sounding pinctrl label - that label name is generic
   boilerplate carried over from SoC-reference-design pin-group naming,
   not evidence of actual usage. SE12 is very likely used for something
   else on this board (never identified, out of scope here) - its
   compatible in the base tree (`qcom,msm-geni-console`) is literally
   the debug-console UART driver, reinforcing that it isn't Bluetooth.

**`qupv3_se6_4uart`'s real pins, all fixed at the SoC-reference-design
level** (no per-board override needed, matching PCIe0's PERST/WAKE
GPIOs from the Wi-Fi work - same recurring pattern):

| Signal | GPIO | Source |
|---|---|---|
| CTS | 16 | `kona-pinctrl.dtsi:134` (`qupv3_se6_default_cts`) / `:176` (`qupv3_se6_ctsrx`, active) |
| RTS | 17 | `kona-pinctrl.dtsi:148`/`:189` |
| TX | 18 | `kona-pinctrl.dtsi:162`/`:202` |
| RX | 19 | `kona-pinctrl.dtsi:148` (shares the `rtsrx` pin group with RTS)/`:176` (shares `ctsrx` with CTS) |

**And this maps directly onto mainline's `uart6` node** -
`work/linux/arch/arm64/boot/dts/qcom/sm8250.dtsi:1699`,
`serial@998000` (byte-identical register address to downstream's SE6),
`compatible = "qcom,geni-uart"` (mainline's single unified GENI serial
driver, not downstream's split debug/HS-UART driver naming),
`status = "disabled"` by default (same recurring "off unless a board
DTS turns it on" pattern this project keeps finding). Its default
pinctrl state, `qup_uart6_default`
(`sm8250.dtsi:5744`), is `pins = "gpio16", "gpio17", "gpio18", "gpio19"`
- **matches every one of gts7l's real pins above, exactly, with zero
board-specific override needed** - the same situation elish is in
(elish's own `&uart6` block has no pinctrl override either, just
`status = "okay"`).

**Conclusion: `&uart6 { status = "okay"; bluetooth { ... }; };` can be
copied from elish essentially verbatim** - the hard part (figuring out
which of two plausible UART instances is correct, and whether its pins
need a board-specific override) is already resolved with real evidence,
not a guess.

## Kernel config: same tristate-ceiling class of gotcha as Wi-Fi hit twice

Checked `work/linux/.config` directly (built from `defconfig` +
`kernel/config/gts7l.fragment` as it currently stands):

- **`CONFIG_SERIAL_QCOM_GENI=y`** already - the actual UART controller
  driver (`uart6`'s own `qcom,geni-uart` compatible) is fine, no repeat
  of the Wi-Fi PCIe-PHY module trap here.
- **`CONFIG_BT=m`, `CONFIG_BT_QCA=m`, `CONFIG_BT_HCIUART=m`** - all
  still modules from plain `defconfig`, despite
  `CONFIG_BT_HCIUART_QCA=y` (the actual QCA-protocol glue) already
  being on. This project has no module-loading infrastructure (same
  fact established for Wi-Fi) - a `=m` driver here is silently
  indistinguishable from "doesn't exist". All three need forcing `=y`
  in `kernel/config/gts7l.fragment`, the same fix pattern already used
  for `CFG80211`/`MAC80211`/`RFKILL`/`ATH11K`/`ATH11K_PCI`/
  `CONFIG_PHY_QCOM_QMP_PCIE`.
- `drivers/bluetooth/hci_qca.c` directly matches
  `.compatible = "qcom,qca6390-bt"` (`qca_bluetooth_of_match[]`,
  confirmed by reading the source) - no missing driver, no guessing
  needed on that front.

## Firmware: likely NOT a hard blocker, unlike Wi-Fi

Read `qca_setup()` in `hci_qca.c` directly rather than assuming this
needs the same live-device-extraction treatment as Wi-Fi's `amss.bin`:
firmware/rampatch filenames only come from an *optional* devicetree
`firmware-name` property (`device_property_read_string_array(...,
"firmware-name", ...)`, `hci_qca.c:2407`) - elish's own DTS doesn't set
one at all. When absent, the driver reads the chip's real ROM/SoC
version directly over UART at runtime and falls back to computed
default filenames (`qca_get_..._name()` returning `NULL` triggers this
path in `qca_setup()`). If those defaults aren't found
(`request_firmware()` returns `-ENOENT`/`-EAGAIN`), **the driver
explicitly falls back to running with the chip's original,
already-in-ROM firmware/config** (`qca_setup()`: "No patch/nvm-config
found, run with original fw/config", `set_bit(QCA_ROM_FW, ...)`) rather
than failing outright, unlike `ath11k`'s hard requirement for
`amss.bin`.

Downstream's own `references/gts7l/drivers/bluetooth/btqca.c:345-376`
confirms the exact default naming convention (this file is a close
copy of the same upstream driver, not a Samsung-proprietary rewrite,
unlike touch/Wi-Fi's dedicated downstream stacks): rampatch defaults to
`"qca/crbtfw%02x.tlv"` (or `"qca/rampatch_%08x.bin"` if keyed by full
SoC version instead of ROM version) and NVM/config defaults to
`"qca/crnv%02x.bin"` (or `"qca/nvm_%08x.bin"`) - both `%x` values read
live from the chip, not hardcodable from source alone. These are
**standard, generic `linux-firmware.git` filenames** (already present
on the live rootfs at `/usr/lib/firmware/ath11k/QCA6390/hw2.0/`'s
sibling location, confirmed during Wi-Fi bring-up that `linux-firmware`
the Arch package is already installed) - genuinely worth trying the
generic ones first here, unlike Wi-Fi's `board-2.bin` where a wrong
calibration variant could plausibly mean "enumerates but performs
badly". No dedicated Samsung Bluetooth firmware directory was found
under `references/gts7l/` analogous to `references/gts7l/firmware/
tsp_novatek/` or `.../qca6390/` (the Wi-Fi one) - if the generic
`linux-firmware` files turn out to be missing/wrong, real-device
extraction would need on-device discovery (`find /vendor -iname
'*bt*fw*'`-style search via the same `/dev/block/mapper/vendor` TWRP
mount already used for Wi-Fi), not something identifiable from the GPL
source dump alone.

## Open questions, genuinely unresolved

- Whether the ROM-fallback path (no rampatch/NVM at all) is good enough
  for basic pairing/audio, or whether real firmware is needed for
  acceptable behavior - can't know without testing on hardware.
- Whether `linux-firmware.git`'s generic `crbtfw*.tlv`/`crnv*.bin`
  files match this chip's real ROM version closely enough to load at
  all (the filename is versioned by a value read from the chip itself
  at runtime, not knowable in advance from source alone).
- SE12 (`qupv3_se12_2uart`)'s real purpose on this board was not
  identified - not blocking Bluetooth, but worth knowing eventually
  (possibly GPS, since GNSS chips commonly use a 2-wire debug/NMEA UART
  on Qualcomm reference designs, but this is a guess, not confirmed).

## Suggested next step when this work actually starts

Same order that worked for Wi-Fi and touch - confirm the hardware path
before chasing firmware:
1. Add `&uart6 { status = "okay"; bluetooth { compatible =
   "qcom,qca6390-bt"; <the six vreg_pmu_* supplies>; }; };` to
   `kernel/dts/sm8250-samsung-gts7l.dts`, copied from elish - no pin
   overrides needed (confirmed above), no new regulators needed
   (already defined for Wi-Fi).
2. Force `CONFIG_BT=y`, `CONFIG_BT_QCA=y`, `CONFIG_BT_HCIUART=y` in
   `kernel/config/gts7l.fragment` (the same tristate-ceiling class of
   fix already applied three times this phase).
3. Build, flash, and check `dmesg`/`bluetoothctl list` /
   `hciconfig`(or `btmgmt`) for a real `hci0` device appearing - the
   "does the hardware path even exist" milestone, mirroring Wi-Fi's
   "confirm real PCIe enumeration before chasing firmware" step.
4. Only then check whether the ROM-fallback firmware path is
   sufficient, or whether generic `linux-firmware` QCA files (already
   on the rootfs) or real device-extracted ones are needed for
   reliable pairing/audio.
5. Consider whether Plasma needs an equivalent to `plasma-nm` for
   Bluetooth (likely `bluedevil`, the KDE Bluetooth applet package) -
   not checked yet, but the same "kernel works, nothing shows in the
   UI until the right Plasma package is installed" gap Wi-Fi just hit
   is worth checking for proactively this time instead of being
   surprised by it again.

## Status: Bluetooth working on real hardware (2026-09-20)

Implemented the same day this doc was written, mirroring Wi-Fi's own
"scope then implement, hardware-first" order. Three real bugs found,
each confirmed live on hardware, none of them guessed:

**1. Missing `aliases { serial0 = &uart6; };`** - `qcom_geni_serial`'s
probe() requires a `serialN`/`hsuartN` alias to get a port "line"
number at all (`of_alias_get_id()`), logged as the unhelpful
`qcom_geni_serial 998000.serial: Invalid line -19`. No `aliases {}`
node had ever existed anywhere in this project's devicetree chain
before - never needed until `&uart6` became the first UART this
project ever turned on. elish has the identical `serial0 = &uart6;`
for the identical reason. **A real process mistake happened here
too**: the first attempted fix (round78) still failed identically,
traced to forgetting to copy the freshly-rebuilt DTB from
`work/linux/arch/arm64/boot/dts/qcom/` back into the tracked
`kernel/dts/sm8250-samsung-gts7l.dtb` before packaging - round78
actually flashed the *stale* pre-fix devicetree. Caught by checking
`/proc/device-tree/aliases/serial0` directly on the live device rather
than trusting the build log, fixed properly as round79.

**2. `hci0` registers and loads real firmware, but stays
"unconfigured"** - confirmed exactly as scoped: chip identifies itself
correctly over UART (`QCA SOC Version 0x400a0200`, real ROM/patch
versions), `qca/htbtfw20.tlv` and `qca/htnv20.bin` (the *generic*
`linux-firmware.git` files, exactly as predicted - no live-device
firmware extraction needed for Bluetooth, unlike Wi-Fi) download and
apply successfully ("QCA setup on UART is completed"), and `hci0`
appears in `/sys/class/bluetooth/` and
`/sys/kernel/debug/bluetooth/hci0/`. But `bluetoothctl`/`btmgmt`
reported zero controllers regardless - root-caused (not guessed) via a
raw AF_BLUETOOTH/HCI_CHANNEL_CONTROL mgmt-socket query in Python,
which showed `hci0` sitting in the *unconfigured* controller index
list specifically. Real cause, found by reading `btqca.c` directly:
this chip has no unique burned-in BD address - it reports a well-known
QCA placeholder instead, `qca_check_bdaddr()` detects the match and
sets `HCI_QUIRK_USE_BDADDR_PROPERTY`, and mainline's own
`hci_dev_get_bd_addr_from_property()` then requires a real
`local-bd-address` devicetree property before promoting the controller
out of unconfigured state - a normal, expected situation for this chip
family (no factory BD-address provisioning exists for a hobbyist
single-unit build), not a bug. Fixed with a fixed, locally-administered
address (`e6:2e:8b:7a:ca:29`, IEEE local/universal bit set, stored
byte-reversed per the DT binding convention) in
`kernel/dts/sm8250-samsung-gts7l.dts`. **Confirmed**: `bluetoothctl
show` now reports a real, powered "public" controller at that exact
address.

**3. Pairing "succeeds" but a real BLE mouse does nothing** - the
`wlan-pci-rebind.service`-style boot-time firmware race did **not**
recur here in the same form (this UART device's driver's probe()
itself always succeeds; the race is invisible unless something tries
to actually *use* Bluetooth before the real rootfs's `/lib/firmware`
is mounted) - but a `bt-uart-rebind.service` (same shape as the Wi-Fi
one, `/sys/bus/serial/drivers/hci_uart_qca/{unbind,bind}` on
`serial0-0`) was added anyway as a preventive measure, confirmed
working across a genuine cold reboot. Once `hci0` was genuinely
usable, the owner tried a real BLE mouse ("Mi Mouse3C") -
`bluetoothctl` showed `Paired: yes`/`Connected: yes` and full GATT
service discovery (Battery Service, HID Service), but the mouse did
nothing at all. Root cause: `CONFIG_UHID` was completely unset.
BlueZ's `input` plugin bridges BLE HID-over-GATT (HOGP) devices - like
this mouse, which only advertises the "Human Interface Device" GATT
service, not the classic BR/EDR HID profile - into the kernel's real
input subsystem via `/dev/uhid`, injecting synthetic HID reports read
over GATT. Without it, `bluetoothd` completes the BLE connection and
GATT discovery fine, but has no path at all to deliver real input
events. Forced `CONFIG_UHID=y` (also `CONFIG_BT_HIDP=y`, was `=m` -
same tristate-ceiling pattern as `ATH11K`/`CFG80211`/
`PHY_QCOM_QMP_PCIE`/etc, needed for classic BR/EDR HID like this
device's own Book Cover Keyboard trackpad might use later - and
`CONFIG_HIDRAW=y`, harmless/commonly-needed). **Confirmed by the
owner directly**: the mouse now moves the cursor and clicks work.

**Plasma UI**: unlike Wi-Fi, `bluedevil` (KDE's Bluetooth applet,
Wi-Fi's own `plasma-nm` equivalent flagged as a risk in this doc's
"suggested next step" section) was installed proactively *before*
first real hardware test, avoiding a repeat of the "kernel works,
nothing shows in the UI" surprise Wi-Fi hit.

**Bonus, unrelated-to-Bluetooth fix found along the way**: real
interactive use surfaced `pacman` failing every install with
`"switching to sandbox user 'alpm' failed!"` -
`CONFIG_SECURITY_LANDLOCK` was never enabled (pacman 7.x sandboxes its
own download/extract step with Landlock). Added - a plain `bool`
depending only on the already-`=y` `CONFIG_SECURITY`, no
tristate-ceiling gotcha this time, just never added before now.

**Still open / not covered by this pass**:
- SE12 (`qupv3_se12_2uart`)'s real purpose was never identified
  (unrelated to Bluetooth).
- No audio/A2DP testing done (only a BLE HID mouse tested so far).
- The Book Cover Keyboard's own Bluetooth/pogo-pin behavior (if any)
  not investigated - out of scope for this pass.
