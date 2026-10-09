# Mainline Linux for the Samsung Galaxy Tab S7 (LTE)

Arch Linux ARM with KDE Plasma on the Samsung Galaxy Tab S7 LTE (`SM-T875`,
`gts7l`), running upstream Linux 7.2 with a set of device patches. No
Android kernel, no Halium: the stock bootloader loads a mainline kernel
through [uniLoader](https://github.com/ivoszbg/uniLoader), and the whole
userspace is a normal Arch Linux ARM system.

- **SoC:** Qualcomm Snapdragon 865 (SM8250), Adreno 650
- **Kernel:** Linux 7.2 + `kernel/patches/` (45 patches) and our own device tree
- **Desktop:** KDE Plasma 6.7 on Wayland
- **Base:** Arch Linux ARM (aarch64)

> **Status:** usable as a daily desktop for many tasks, but still a
> bring-up project. Read [Known issues](#known-issues) before installing.
> The installer is not released yet.

## Hardware compatibility

| Component | Status | Summary |
|---|:---:|---|
| Display | ✅ | 1600×2560 at 120, 96, 60 or 48 Hz, backlight |
| Desktop | ✅ | KDE Plasma 6.7, Wayland |
| GPU | ✅ | Adreno 650 hardware acceleration: OpenGL 4.6, Vulkan 1.3 (Freedreno/Turnip) |
| Touchscreen | ✅ | Novatek NT36523 multitouch |
| S Pen writing | 🟡 | Hover, pressure and the side button (Wacom digitizer); no palm rejection yet |
| S Pen Bluetooth features | ❓ | Air actions, pen battery: not tested |
| On-screen keyboard | ✅ | Floating, resizable keyboard plus a full PC layout for terminals |
| Power and volume buttons | ✅ | |
| Cover sensor | ✅ | Closing the cover sleeps, opening it wakes |
| Wi-Fi | ✅ | QCA6390 (ath11k) |
| Bluetooth | ✅ | QCA6390; keyboards and mice tested |
| Speakers | ✅ | Four CS35L41 amplifiers with Samsung's speaker protection and per-unit calibration |
| Microphones | ✅ | Two digital microphones |
| Vibration motor | 🟡 | Works; no desktop haptic feedback yet |
| Flashlight | ✅ | Torch and camera flash, with a Flashlight launcher |
| Accelerometer / auto-rotation | ✅ | Through the sensor DSP (SLPI) |
| Ambient light / auto-brightness | ✅ | KDE's automatic brightness, with a starting curve |
| Gyroscope / compass | ❓ | On the sensor DSP, not exposed to the desktop |
| Battery status | ✅ | Percentage, voltage, current |
| Charging | 🟡 | USB-PD at 9 V; slower than stock (no PPS fast charging) |
| Charging while powered off | ❌ | Plugging in a powered-off tablet boots Linux |
| Suspend / resume | 🟡 | Sleep and wake work, but no deep sleep: high standby drain |
| microSD | ✅ | |
| USB host | ✅ | Storage, HID, hubs, powered docks |
| USB networking to a PC | ✅ | USB Ethernet gadget |
| USB-C DisplayPort | 🟡 | External monitors work (also at boot, through hubs); no DP audio |
| Rear main camera | 🟡 | Works in apps through libcamera; fixed focus, software image processing |
| Front and ultra-wide cameras | ❌ | Need new sensor drivers |
| Fingerprint reader | ❌ | Owned by the secure world; not feasible |
| LTE modem | ❌ | Work in progress (external SDX55 over PCIe) |
| Keyboard cover | ❓ | Not tested (no hardware) |
| Windows programs | 🟡 | Wine (Hangover) with FEX/Box64 and DXVK; optional |

✅ working on the tablet · 🟡 partial or with limitations · ❌ not working ·
❓ not tested

Details, evidence and the remaining work for every item are in
[docs/open-items.md](docs/open-items.md) and the per-component scoping docs
in [docs/](docs/).

## Known issues

- **Charging is slow.** Stock charges at up to 45 W through a separate
  direct charger (PCA9468, PPS). We charge through the MAX77705 alone at a
  fixed 9 V, and also stop at 4.2 V instead of stock's 4.38 V, which leaves
  some capacity unused.
- **No deep sleep.** Suspend and resume work (power button, cover), but the
  SoC never reaches its lowest power state, so the battery drains much
  faster in standby than on Android.
- **No offline charging.** Plugging in the charger while the tablet is off
  boots straight into Linux; there is no charging-only mode.
- **Short blank screen at boot.** After the uniLoader message the screen
  goes dark for 1-2 s while the display driver takes over.
- **Battery temperature** in the desktop is a fixed value (the fuel gauge
  is not wired to the thermistor); charging uses the real thermistor.
- **No palm rejection with the S Pen.** While writing with the pen, a hand
  resting on the screen is still read as touch input.
- **Speaker channels** stay fixed to the landscape ends when rotated.
- Not working yet: LTE, the front and ultra-wide cameras, DisplayPort audio,
  camera autofocus.

## Installation

**Not released yet.** A TWRP-flashable installer is being finished:

- it formats the `userdata` partition for Linux and installs the system
  (**everything on Android's data partition is erased**);
- it copies the firmware and per-device calibration it needs from the
  tablet itself, so nothing proprietary is redistributed;
- on first boot, KDE's setup wizard asks for the language, keyboard layout,
  time zone, user account and host name, then a tablet page for automatic
  brightness, auto-rotation, automatic login, a root password, SSH and
  Windows program support.

Requirements:

- a Galaxy Tab S7 **LTE** (`SM-T875`) with an unlocked bootloader;
- TWRP for `gts7l` (the device tree is in [recovery/](recovery/));
- unlocking trips Knox permanently and voids the warranty.

Only the `boot` and `userdata` partitions are written. Android can be
restored with Odin and the stock firmware for your region. Do not flash a
newer stock firmware than you need: Samsung's anti-rollback fuse can
prevent going back to older versions.

The Wi-Fi-only Tab S7 (`SM-T870`) is not supported yet.

## Building from source

The kernel is upstream Linux 7.2 plus the patch series, our device tree and
a config fragment:

```
git clone https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git
cd linux && git checkout v7.2
for p in ../kernel/patches/0*.patch; do git apply "$p"; done
cp ../kernel/dts/sm8250-samsung-gts7l.dts arch/arm64/boot/dts/qcom/
cp -r ../kernel/firmware firmware        # touch firmware, built in
make ARCH=arm64 LLVM=1 defconfig
./scripts/kconfig/merge_config.sh -m .config ../kernel/config/gts7l.fragment
make ARCH=arm64 LLVM=1 olddefconfig
make ARCH=arm64 LLVM=1 Image qcom/sm8250-samsung-gts7l.dtb
```

The kernel and DTB are wrapped by uniLoader (`kernel/uniloader/`) into a
`boot.img` that the stock bootloader accepts. The full pipeline (build,
pack, flash from Linux or TWRP) is in
[docs/dev-environment-quickref.md](docs/dev-environment-quickref.md).

## Documentation

| Document | Contents |
|---|---|
| [docs/open-items.md](docs/open-items.md) | Everything unfinished, known quirks, recent work |
| [docs/hardware-inventory.md](docs/hardware-inventory.md) | The tablet's chips and how they are wired |
| [docs/dev-environment-quickref.md](docs/dev-environment-quickref.md) | Build, flash and debug workflow |
| [docs/kernel-boot-debugging.md](docs/kernel-boot-debugging.md) | The bring-up log, round by round |
| `docs/phase*-scoping.md` | One document per component: findings, decisions, test results |
| [plans/roadmap.md](plans/roadmap.md) | The bring-up phases and their exit criteria |

## Repository layout

| Path | Contents |
|---|---|
| `kernel/patches/` | The kernel patch series on top of Linux 7.2 |
| `kernel/patches-wip/` | Unfinished work (LTE modem, DP audio) |
| `kernel/dts/` | The `gts7l` device tree |
| `kernel/config/` | The kernel config fragment |
| `kernel/uniloader/` | uniLoader, with the `gts7l` board support |
| `kernel/initramfs/` | The small init that mounts the root filesystem |
| `tools/rootfs/` | Userspace pieces: audio, sensors, camera, USB, setup wizard, keyboards, Wine, ... |
| `recovery/` | TWRP device tree for `gts7l` |
| `docs/` | Findings, logs and per-component notes |

## Firmware and licensing

Proprietary firmware is **not** in this repository. The Samsung firmware the
port needs (audio DSP, sensor DSP, GPU zap shader, speaker protection) and
each tablet's own calibration data are copied from the tablet's own
partitions at install time. Wi-Fi, Bluetooth and GPU firmware come from the
upstream `linux-firmware` packages. The one exception is the touchscreen
controller firmware (`kernel/firmware/tsp_novatek/`), which Samsung
publishes in its GPL kernel source for this model and which is built into
the kernel image.

This project is licensed under the [GPL-2.0](LICENSE), like the Linux
kernel it patches. Third-party components keep the licenses stated in their
directories (uniLoader, the TWRP device tree, and upstream sources the
packaging files build).

## Credits

- [ubuntu-galaxy-tab-s9-ultra](https://github.com/agcarbajo/ubuntu-galaxy-tab-s9-ultra)
  and its postmarketOS base, the project this port is modeled on
- [sm8250-mainline](https://github.com/sm8250-mainline/linux) and the
  upstream Qualcomm/Linux developers
- [uniLoader](https://github.com/ivoszbg/uniLoader)
- Samsung's GPL kernel source for `SM-T875`, via
  [ianmacd/gts7l](https://github.com/ianmacd/gts7l), and
  [ianmacd/twrp_gts7l](https://github.com/ianmacd/twrp_gts7l)
- postmarketOS, libssc, hexagonrpcd, KDE, Arch Linux ARM, Hangover, and the
  authors of the bundled on-screen keyboards

## Disclaimer

This project was built with the help of AI (Claude Code). The released build
was tested on real hardware. Use at your own risk.

I'm not responsible for your device exploding, bending, falling apart or in
any other way deconstructing itself from a failed flash, broken zip alignment
or thermonuclear wars. Nor am I held accountable if you accidentally reflash
the image 3481 times causing your eemc chip to die. If you have any concerns
about the features or modifications included in this port please do some
research before flashing it. You are choosing to make these modifications to
your device.
