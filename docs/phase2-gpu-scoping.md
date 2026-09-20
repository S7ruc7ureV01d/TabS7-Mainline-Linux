# Phase 2 GPU scoping — Adreno 650 (2026-09-20)

Scoping pass for the next Phase 2 exit criterion: Adreno 650 GPU
acceleration. Done the same way the touchscreen work started - read what
mainline already has, cross-check against Samsung's own downstream source
and a real, shipping mainline SM8250 device, before writing anything.

## The good news: mainline already fully describes this GPU

`arch/arm64/boot/dts/qcom/sm8250.dtsi` already has complete `gpu`, `gmu`,
`gpucc`, and `adreno_smmu` nodes for exactly this silicon:

```
gpu: gpu@3d00000 {
	compatible = "qcom,adreno-650.2", "qcom,adreno";
	...
	qcom,gmu = <&gmu>;
	nvmem-cells = <&gpu_speed_bin>;
	status = "disabled";

	gpu_zap_shader: zap-shader {
		memory-region = <&gpu_mem>;
	};
	...
};

gmu: gmu@3d6a000 {
	compatible = "qcom,adreno-gmu-650.2", "qcom,adreno-gmu";
	...
	status = "disabled";
};
```

Both default to `status = "disabled"` - same pattern as every other
peripheral this project has had to enable so far (`qupv3_id_0`, `gpi_dma0`,
etc.). `gpu_speed_bin` and `gpu_mem` (the nvmem cell and reserved-memory
region the GPU node references) are already defined generically in
`sm8250.dtsi` itself - no per-board node needed for those.

Confirmed against Samsung's own downstream source
(`references/gts7l/arch/arm64/boot/dts/vendor/qcom/kona-gpu.dtsi`) that
this is genuinely the right silicon: downstream's legacy `qcom,kgsl-3d0`
node declares `qcom,chipid = <0x06050000>`, which lines up with mainline's
`a6xx_catalog.c` entry for `chip_ids = ADRENO_CHIP_IDS(0x06050002)`,
`revn = 650` - the exact "adreno-650.2" compatible already in the DT.
(Mainline pins the variant via the DT compatible string rather than
runtime chip-ID detection, so the small last-nibble difference doesn't
matter here.)

## The one real hardware-specific piece: the zap shader

Adreno's GX power rail is behind TrustZone on these SoCs - Linux can't
turn the GPU on directly. `adreno_zap_shader_load()`
(`drivers/gpu/drm/msm/adreno/adreno_gpu.c`) loads a small, **device-signed**
firmware blob through `qcom_scm_pas_auth_and_reset()`/the Peripheral
Authentication Service to do this. `a6xx_catalog.c`'s `chip_ids =
0x06050002` entry sets `.zapfw = "a650_zap.mdt"` as the default filename,
but the actual blob is per-device (signed against this exact device's own
keys/fuses) - it has to come from Samsung's real gts7l firmware, not
another SM8250 device's dump, and not something genuinely reusable/
redistributable.

**Confirmed via a real, shipping mainline device that this exact recipe
works**: `sm8250-xiaomi-elish-common.dtsi` (the same reference dual-DSI
tablet this project has leaned on throughout) does exactly this:

```
&gmu {
	status = "okay";
};

&gpu {
	status = "okay";
};

&gpu_zap_shader {
	firmware-name = "qcom/sm8250/xiaomi/elish/a650_zap.mbn";
};
```

Our equivalent: enable `&gmu`/`&gpu` the same way, and point
`&gpu_zap_shader`'s `firmware-name` at our own extracted blob (something
like `qcom/sm8250/samsung/gts7l/a650_zap.mbn`, matching the elish path
convention this driver already expects firmware to live under).

**Not yet done - needs live device access**: actually pulling that blob
off the tablet. Real vendor firmware partitions on Samsung Qualcomm
devices typically carry it as `a650_zap.mdt` plus split `.b00`-`.bNN`
segment files (an mdt/PIL split-image, not a single flat blob) somewhere
under `/vendor/firmware/` or `/vendor/firmware_mnt/`. Haven't confirmed
the exact path or filename on this specific device yet - next concrete
step once back on TWRP/stock Android with root. `magiskboot`/plain `dd`
aren't needed here, just an `adb pull` of whatever real file(s) exist.

The other two firmware pieces the catalog entry names -
**`a650_sqe.fw`** (GPU sequencer microcode) and **`a650_gmu.bin`** (GMU
firmware) - are generic, freely-redistributable Qualcomm blobs already
carried in upstream `linux-firmware.git` for the Adreno 6xx generation
(not device-signed, not something we need to extract ourselves). Not
present in this repo yet; need to be fetched separately and placed
wherever this project's firmware search path ends up living.

## A real practical gap: this initramfs has no `/lib/firmware` yet

`request_firmware()`-based loading (used for `a650_zap.mdt`, `a650_sqe.fw`,
and `a650_gmu.bin` alike) needs a populated `/lib/firmware/...` tree
present in whatever root filesystem is mounted **at the point the GPU
driver probes**, not something that can be supplied later. The current
boot environment (uniLoader → minimal busybox initramfs used for all
bring-up testing so far) has no such tree at all - it's a bare debug
shell, not a real root filesystem. First GPU test will need either:

- the three firmware files added directly into this initramfs's own
  `lib/firmware/qcom/...` layout, or
- deferring the real GPU test until Phase 5's actual target rootfs
  (with a real `/lib/firmware`) is in the loop, and treating a bring-up-
  initramfs GPU test as optional/best-effort rather than blocking.

Leaning toward the first option for a fast first test, matching this
project's consistent "prove it works before building further" pattern -
it's a small, temporary addition to the existing bring-up initramfs, not
a real rootfs decision.

## Kernel config: already mostly there

`CONFIG_DRM_MSM=y` is already forced on in `kernel/config/gts7l.fragment`
(same no-module-loading-early-enough class of fix already applied for
the display work) - the actual `a6xx_gpu.c`/`a6xx_catalog.c` driver code
compiling in isn't new work. Still need to confirm (once test-booting)
whether `CONFIG_QCOM_SCM` and `CONFIG_QCOM_MDT_LOADER` - required for the
PAS/SCM calls `adreno_zap_shader_load()` makes - are actually enabled;
neither shows up as an explicit line in either `defconfig` or our
fragment, but both are very likely already pulled in transitively (this
kernel already exercises remoteproc/PIL-loaded firmware paths for other
subsystems, per boot dmesg mentioning `remoteproc`/`cdsp`/`8300000.
remoteproc` sync-state entries) - needs a real `zcat /proc/config.gz`
check on-device to confirm rather than assume.

## Suggested next step when this work actually starts

1. Get real device access (TWRP or rooted stock Android) and locate the
   actual `a650_zap` blob under `/vendor/firmware*` - confirm exact
   filename/extension and whether it's a single file or an mdt+segments
   set, and pull it to the host.
2. Fetch `a650_sqe.fw` and `a650_gmu.bin` from upstream
   `linux-firmware.git`.
3. Add `&gmu { status = "okay"; }`, `&gpu { status = "okay"; }`, and
   `&gpu_zap_shader { firmware-name = "..."; }` to
   `kernel/dts/sm8250-samsung-gts7l.dts`, following elish's exact
   pattern.
4. Stage all three firmware files into the bring-up initramfs's
   `lib/firmware/qcom/...` tree (matching whatever path the
   `firmware-name` properties declare) for a first test.
5. Boot and check dmesg for `a6xx_gpu`/`adreno`/`a6xx_gmu` probe
   success or failure - this is where any real surprises (icc/
   interconnect paths, GDSC sequencing, SCM config gaps) would first
   show up, the same way the touchscreen's real bugs only surfaced once
   actually tested on hardware rather than scoped on paper.

## Status: done, real rendering confirmed on hardware (2026-09-20)

Everything above happened almost exactly as scoped, plus two real bugs
only found once actually tested (a too-old stock SQE firmware version,
and a firmware-path assumption that only held for the zap shader) - see
the "Adreno 650 GPU bring-up" section in `docs/kernel-boot-debugging.md`
for the full story. Went further than "the driver probes": cross-built
Mesa/kmscube for aarch64 and confirmed genuine, sustained 3D rendering
at the display's native 96 fps, watched directly on the physical
screen. Nothing left open from this scoping document.
