# Phase 2 scoping: the gts7l touchscreen (Novatek NT36523 TDDI)

Recon pass before starting real touchscreen bring-up, done 2026-09-19
right after Phase 2's display work reached a real, working picture on
hardware (`docs/kernel-boot-debugging.md` Rounds 38-56). Goal: find out
how much of the touch bring-up is genuinely new work versus reusable,
before writing any driver code. Nothing here has been built or tested
yet - this is pure research, recorded for when that work starts.

## The chip is the same silicon as the panel - a TDDI part

This device's touchscreen and LCD panel are driven by the **same
physical chip**: Novatek NT36523, a TDDI ("Touch and Display Driver
Integration") part. That has one immediately useful consequence,
confirmed directly by reading the downstream driver
(`references/gts7l/drivers/input/touchscreen/novatek/nt36523/nt36xxx.c`):
**the touch side has no reset-GPIO handling of its own at all** - no
`reset-gpio`/`novatek,reset-gpio` property anywhere on the downstream
devicetree node, and nothing in the driver source requests one. Touch
bring-up is entirely coupled to the panel's own power/reset sequencing
(GPIO 82, `nt36523_reset()` in
`drivers/gpu/drm/panel/panel-novatek-nt36523.c`, already working) -
there is no separate touch power-on dance to design.

## Real hardware facts, extracted directly from Samsung's own overlay

`references/gts7l/arch/arm64/boot/dts/samsung/gts7l/
kona-sec-gts7l-eur-overlay-r07.dts`, fragment@127:

| Property | Value | Source |
|---|---|---|
| I2C address | `0x62` | `touchscreen@62`'s own `reg` |
| I2C bus | QUP SE5 (`qupv3_se5_i2c` fixup label) | `__fixups__` table, cross-referenced against `work/linux/arch/arm64/boot/dts/qcom/sm8250.dtsi` -> mainline's `i2c5` at `0x994000` |
| Parent QUP wrapper | `qupv3_id_0` (`geniqup@9c0000`) | `sm8250.dtsi` - **defaults to `status = "disabled"`**, same as Round 48's `qupv3_id_1`/i2c8 issue for the ISL98608 bias IC |
| IRQ | GPIO 15 | `interrupts = <0xf 0x0>;` directly on the node (not inferred) |
| Resolution | 1600x2560 | `novatek,resolution = <0x640 0xa00>` - matches the panel's native resolution exactly, as expected for TDDI |
| Max touch points | 10 | `novatek,max_touch_num = <0xa>` |
| Firmware filename | `tsp_novatek/nt36523_gts7l.bin` | `novatek,firmware_name` - see below, likely not needed |

**Direct, concrete parallel to a bug this project already hit and
fixed**: `qupv3_id_0` needs `status = "okay"` set explicitly, exactly
like `qupv3_id_1` did for `&i2c8`/the ISL98608 bias IC in Round 48 - a
disabled parent QUP wrapper means none of its children (`i2c5`
included) ever get instantiated regardless of their own status. This is
the first thing to add to `kernel/dts/sm8250-samsung-gts7l.dts` when
this work starts.

## Firmware download: not a blocker, skippable for first bring-up

The single biggest open question going in was whether this chip needs a
firmware blob pushed from the host at every boot (a real, possibly
license-encumbered blocker) or whether it has persistent internal
storage. Read `nt36xxx_fw_update.c`'s
`nvt_ts_firmware_update_on_probe()` directly: it checks
`ts->platdata->bringup == 1` and returns immediately, skipping firmware
handling entirely, if set - **downstream's own driver already has a
purpose-built "skip firmware update" bring-up mode for exactly this
situation.** Even in the normal path, it only reflashes when
`nvt_ts_check_fw_ver()`/`nvt_ts_check_checksum()` detect a mismatch -
the chip has real non-volatile flash holding its own firmware, which
persists across power cycles; this is not a RAM-only touch controller
that needs firmware pushed every single power-up.

Corroborated by a real mainline precedent: a 2020 patch series for the
same `nt36xxx` chip family (NT36525/672A/676F/772/870, posted by
AngeloGioacchino Del Regno to linux-input) describes these as
"DrIC+Touch combo chips [that] typically include non-volatile memory
with embedded touch firmware in the DriverIC," and deliberately omits
firmware-flashing support entirely as unnecessary for that family.

Since this physical unit has run stock Android from the factory for
years, the chip's internal flash almost certainly already holds valid,
working firmware. **A first mainline driver can skip firmware handling
completely** and talk to whatever's already resident on the chip -
matching the same "get a picture/get input first, defer the polish"
philosophy that got Phase 2's display working. Pulling
`tsp_novatek/nt36523_gts7l.bin` off the device's own `/vendor/firmware`
(or wherever it actually lives) via `adb` is worth doing anyway, purely
as a fallback reference in case the chip's resident firmware ever
proves stale/corrupted - not because it's expected to be needed.

## Protocol: paged/banked I2C addressing, not flat registers - and not
a match for mainline's existing Novatek driver

Mainline already has `drivers/input/touchscreen/novatek-nvt-ts.c`
(Hans de Goede, 2023, 349 lines), supporting `novatek,nt11205-ts` and
`novatek,nt36672a-ts`. It is tempting to assume this could just be
extended with a new compatible string, the same pattern this project
used for the panel driver - **but it doesn't apply here**: that driver
does flat, fixed-offset I2C reads at a single address (touch reports at
a constant register, a simple chip-ID byte check, no paging). NT36523's
real protocol, read directly from `nt36xxx.c`'s `nvt_ts_i2c_read()`/
`_write()`, is fundamentally different:

- The `address` parameter to these functions is actually **which I2C
  slave address to target**, not a register offset - the chip responds
  on different addresses depending on mode (`I2C_HW_Address = 0x62` for
  normal touch operation, `I2C_FW_Address`/`I2C_BLDR_Address = 0x01` for
  firmware/bootloader-mode access).
- Real register addressing is **paged**: `nvt_ts_set_page(ts, i2c_addr,
  addr)` writes `0xFF` followed by a 3-byte page address, and
  subsequent reads/writes hit an offset within whatever page was just
  selected - a materially different scheme from a flat register map.
- The touch-report interrupt handler pages to `mmap->EVENT_BUF_ADDR`
  and reads a fixed 108-byte (`POINT_DATA_LEN`) block, at
  `I2C_FW_Address` (`0x01`) - not the `0x62` address the chip is
  enumerated at.

Given this, `novatek-nvt-ts.c`'s protocol simply does not match this
chip - extending it is not viable. A new driver is needed.

## What's genuinely new work vs. reusable

**Reusable / already solved**:
- Panel's existing reset/power sequencing (GPIO 82) - touch has no
  separate reset to design, per above.
- The exact "enable the parent QUP wrapper" devicetree pattern from
  Round 48 - directly applicable to `qupv3_id_0`/`i2c5`.
- The general porting philosophy this project has used throughout:
  extract the real protocol from Samsung's downstream driver, drop the
  firmware-flashing/factory-test/debug-proc code
  (`nt36xxx_fw_update.c`'s normal-path reflash logic, all of
  `nt36xxx_ext_proc.c`, `nt36xxx_mp_ctrlram.c`, and Samsung's own
  `nt36xxx_sec_fn.c` - confirmed via a skim to be manufacturing
  test/debug-proc code, not required for functional touch input, and at
  4092 lines for `sec_fn.c` alone, by far the largest chunk of the
  downstream package - not needed at all).

**New work, but scoped and concrete**:
- A new mainline touchscreen driver (own file - the protocol doesn't
  overlap with `novatek-nvt-ts.c` enough to extend it), implementing
  only: paged I2C read/write (`nvt_ts_set_page` + addressed read/write,
  ported from `nt36xxx.c`), a probe path that skips firmware download
  entirely (mirroring downstream's own `bringup=1` mode), and the
  108-byte touch-report parser at `EVENT_BUF_ADDR`.
- Devicetree pieces: **done** (`docs/kernel-boot-debugging.md`,
  "Phase 2 touchscreen bring-up begins") - `&qupv3_id_0`/`&gpi_dma0`
  enabled, `&i2c5` node added with a placeholder `touchscreen@62`,
  confirmed enumerating on real hardware
  (`/sys/bus/i2c/devices/5-0062`). Getting there required finding and
  fixing a genuine bug in mainline's `drivers/dma/qcom/gpi.c`: this
  SoC's shared GPI DMA hardware needs a TrustZone/firmware-configured
  "EE" (execution environment) register-bank offset that mainline
  hardcoded wrong for the `qcom,sm8250-gpi-dma` compatible (`0x0`
  instead of the real `0x1000` this device's firmware actually uses,
  confirmed against Samsung's own downstream devicetree) - fixed by
  adding an optional `qcom,gpi-ee-offset` devicetree override to the
  driver, matching downstream's own property name.

**Genuinely open questions, not yet answered:**
- GPIO 15's real pull/drive configuration on a genuinely working
  system (stock Android or TWRP) hasn't been directly confirmed yet -
  on our own mainline kernel right now it just reads as unclaimed
  default TLMM state (`in low, func0, pull down`), which is expected
  since nothing requests it yet, not evidence of anything. Worth a
  quick live check (the owner has already offered to boot stock Android
  for this) once real devicetree/driver work starts and pinctrl values
  are needed.
- No existing mainline or readily-adaptable out-of-tree driver was
  found for this exact chip. A 2020 patch series for the sibling
  `nt36xxx` family (kholk, 9 revisions on linux-input, never found
  merged into current mainline nor present in `work/linux`) shares the
  same architecture and "no firmware flash needed" reasoning, but its
  explicit supported-chip list (NT36525/672A/676F/772/870) doesn't
  include NT36523 - worth tracking down if it still exists anywhere
  reusable, but not assumed to exist as a drop-in.
- Whether `tsp_novatek/nt36523_gts7l.bin` is actually present on this
  device's own firmware partitions, and exactly where, hasn't been
  checked - low priority since it's not expected to be needed for first
  bring-up.

## Suggested next step when this work actually starts

Add the devicetree pieces first (`qupv3_id_0` enable + `i2c5` node) and
confirm the chip at least responds/enumerates at `0x62` before writing
any real driver logic - the same "confirm the hardware path exists
before building on top of it" order this project used successfully for
the ISL98608 bias IC in Round 47/48. Then write a minimal driver that
does nothing but page to `EVENT_BUF_ADDR`, read the 108-byte report,
and log it - get real touch-event bytes flowing before wiring up the
full `input_mt`/slot-tracking report parser.
