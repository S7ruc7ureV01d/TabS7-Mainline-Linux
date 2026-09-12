# Building Our Own TWRP for `gts7l` — Build Notes

Recorded: 2026-09-11. This resolves `docs/recovery-options.md`'s "Option 3"
(build our own from the stale `twrp_gts7l` source trees) — **done and
successful**. A working `recovery.img` now exists at
`../artifacts/twrp-gts7l-unofficial.img`, built entirely from source we can
audit, rather than trusting a third-party binary.

## Why this path, over the community prebuilts

Per `recovery-options.md`: the only actively-maintained prebuilt TWRP found
targets `gts7lwifi` (T870), not our T875, with a different partition layout;
and TerracottaROM's own install guidance says to update to "latest stock
firmware" first, which conflicts with this project's permanent anti-rollback
constraint (`device-state.md`). Building our own from a device tree written
specifically for `gts7l`/T875 avoids trusting either of those.

## What was already there

`ianmacd/twrp_gts7l` (also mirrored, less recently updated, at
`Bush-cat/twrp_gts7l`) turned out to be a real, reasonably complete TWRP
device tree for this exact model — its `recovery.fstab` matches our actual
partition layout confirmed in `device-state.md` byte-for-byte (`efs`,
`sec_efs`, `optics`, `prism`, `metadata`, etc.), and it ships a **prebuilt
kernel `Image` + `recovery_dtbo`**, meaning we didn't need to build or port a
kernel for the recovery itself — a huge scope reduction. See
`../recovery/PROVENANCE.md` for exactly what's ours vs. upstream, and why the
binary prebuilts aren't committed to this repo.

## Build environment

- **`repo` tool**: not packaged for this distro; bootstrapped directly from
  Google's launcher script (`storage.googleapis.com/git-repo-downloads/repo`)
  into `work/twrp/bin/`, no system install needed.
- **Manifest**: `minimal-manifest-twrp/platform_manifest_twrp_aosp`, branch
  `twrp-12.1` — chosen to match what the actively-maintained community TWRP
  build for this device family (`ShionKanagawa`'s T870 build, TWRP 3.7.1-12)
  is known to build against, rather than guessing at a branch.
- **Sync**: `repo sync -c -j8 --no-tags --optimized-fetch --force-sync` (
  current-branch-only, no tags) — landed at **33G**, comfortably inside the
  disk headroom available after the owner freed some space first (see the
  disk-space check-in before this work started).
- **JDK**: the system's JDK 21 was *not* an issue — Soong bootstraps and uses
  its own prebuilt Go/Java toolchain under `prebuilts/` fetched by the sync
  itself, so the host's Java version turned out not to matter for this
  branch. Worth knowing in case an even older TWRP branch is ever attempted,
  where this might not hold.
- **Disk headroom discipline**: watched free space throughout with a
  background monitor (threshold-alert only, not constant chatter) rather
  than assuming a multi-GB sync/build would just fit — it did (66G still
  free after the full build), but this was checked, not assumed.

## Two real bugs found and fixed in the old device tree

The device tree was written in 2020 against an older TWRP branch. Reusing it
against current `twrp-12.1` surfaced two real incompatibilities - both are
now genuinely understood, not worked around blindly:

### 1. `TARGET_SUPPORTS_64_BIT_APPS` missing

First `lunch` attempt failed immediately:

```
error: Building a 32-bit-app-only product on a 64-bit device. If this is
intentional, set TARGET_SUPPORTS_64_BIT_APPS := false.
```

Modern `build/make/core/board_config.mk` added a stricter check: when both
`TARGET_ARCH=arm64` and `TARGET_2ND_ARCH=arm` are set (a 64/32-bit combo
device, which this is), it now requires an explicit
`TARGET_SUPPORTS_64_BIT_APPS` rather than inferring it. The 2020-era device
tree predates this check. Fix: added `TARGET_SUPPORTS_64_BIT_APPS := true` to
`BoardConfig.mk`.

### 2. `recoveryimage` silently built nothing (`PRODUCT_BUILD_RECOVERY_IMAGE` missing/misplaced)

This one took much longer to track down because it **didn't error** — the
build reported `#### build completed successfully ####` while producing no
`recovery.img` at all, twice in a row (once with plain `make`, once with the
`m` wrapper function, to rule out a dispatch difference between the two —
same result either way).

Root cause, traced by reading `build/make/core/board_config.mk` and
`build/make/core/Makefile` directly rather than guessing: on current
build/make, `BUILDING_RECOVERY_IMAGE` (which gates whether
`INSTALLED_RECOVERYIMAGE_TARGET` gets a value at all) only becomes true if
`PRODUCT_BUILD_RECOVERY_IMAGE := true` is set, or `BOARD_RECOVERYIMAGE_PARTITION_SIZE`
is defined. This device tree set neither. Without it, the `recoveryimage`
phony make target ends up depending on nothing (confirmed directly by
grepping the generated `out/build-omni_gts7l.ninja` for
`build recoveryimage:` and finding a bare `phony` with zero prerequisites) -
ninja correctly reports "no work to do" because, from its point of view,
there genuinely was none.

**First fix attempt was itself wrong** and worth recording so it isn't
repeated: adding `PRODUCT_BUILD_RECOVERY_IMAGE := true` to `BoardConfig.mk`
broke `lunch` entirely (`error: cannot assign to readonly variable:
PRODUCT_BUILD_RECOVERY_IMAGE`). Despite the `PRODUCT_` name suggesting
"product config," it's read and `.KATI_READONLY`-locked by
`board_config.mk` *before* the device's own `BoardConfig.mk` is even
included - so it has to be set at the *product* level instead. Moved it to
`omni_gts7l.mk` (the product definition file) and it worked immediately.

**Lesson for later phases**: a variable prefixed `PRODUCT_` almost always
belongs in the product `.mk` file, not `BoardConfig.mk`, even when it feels
board-specific (recovery image size / whether to build one at all does feel
like a board property) - the prefix is a real signal about lock-order, not
just a naming convention.

## Result

```sh
source build/envsetup.sh
lunch omni_gts7l-eng
export SOONG_ALLOW_MISSING_DEPENDENCIES=true   # unrelated VTS-fuzzer modules
                                                 # the minimal manifest doesn't
                                                 # fully include - harmless to
                                                 # skip, not needed for a
                                                 # recovery image
m recoveryimage -j20
```

**Build completed successfully in 15:22 (mm:ss), 20632 steps**, producing
`out/target/product/gts7l/recovery.img` (73MB), confirmed via `file` as a
genuine `Android bootimg` with the expected kernel/ramdisk offsets and
`kona`-era cmdline. Copied to `../artifacts/twrp-gts7l-unofficial.img`.

A matching `vbmeta_disabled.img` was generated with
`avbtool make_vbmeta_image --flags 2 --padding_size 4096` - a 4096-byte,
unsigned (`Algorithm: NONE`), verification-disabled vbmeta with a rollback
index of 0 and no descriptors. This is the same technique documented for the
S9 Ultra project in `device-state.md`, and - importantly for this project's
permanent constraint - **carries no rollback-index bump of its own**: it has
no authentication/auxiliary data at all, so flashing it is not expected to
interact with the anti-rollback (`rp`) fuse the way a real signed Samsung
vbmeta with an embedded higher AVB version would. This reasoning is carried
over from prior analysis, not independently re-verified against actual
hardware in this pass - **flashing anything to the device is still a
separate, deliberate decision, not something this build step did on its
own.**

## Real-hardware validation (2026-09-12) — four more real bugs found and fixed

The plan in `flashing-plan.md` was executed: `gts7l-recovery-vbmeta.tar`
flashed via `odin4` (AP slot only, per that plan's RP-safety reasoning), then
booted directly into recovery. **This is the first time anything from this
project has run on the physical tablet.** Sizeable success once four more
genuine bugs (all present in the original 2020-era device tree, none
guessed at - each one root-caused from either a live TWRP terminal or a
comparison against the actively-maintained sibling `gts7lwifi-twrp` build)
were found and fixed, each requiring its own rebuild-flash-reboot cycle:

1. **Touch/theme orientation mismatch.** `TW_THEME := landscape_hdpi` with
   `RECOVERY_TOUCHSCREEN_SWAP_XY`/`FLIP_Y` was the device tree's original,
   apparently never-actually-tested guess - the panel renders portrait on
   real hardware, and the touch transform for a landscape UI was badly
   misaligned against it. Fixed by switching to the tree's own
   commented-out (also never enabled) `TW_THEME := portrait_hdpi`
   alternative and dropping the touch swap entirely.

2. **`recovery.fstab` pointed `odm`/`product`/`system`/`vendor` at physical
   block devices that don't exist.** This is a dynamic-partitions device -
   those four live inside `super`, not as their own by-name partitions. The
   fstab had *both* a correct `logical,first_stage_mount` form and a broken
   plain form for each, with the broken one left active - "Failed to mount
   '/vendor' (Block device required)" etc. on first boot. Fixed by
   uncommenting the correct forms (also added `ro`, since these are
   verity/AVB-backed read-only partitions recovery has no business writing
   to - a second, smaller "Permission denied" issue that showed up right
   after the first fix).

3. **USB was completely dead: no enumeration at all, not adb, not MTP.**
   Root-caused via a live TWRP terminal (touch working by this point made
   this possible) rather than guessed: `ls /sys/class/android_usb/android0`
   failed outright - this kernel has no legacy gadget sysfs node at all,
   only the modern `/sys/class/udc/a600000.dwc3` (confirmed present and
   correctly probed - the controller itself was never the problem). Every
   USB-bringup rule in TWRP's own stock `init.rc` is gated behind
   `sys.usb.configfs=1`, which defaulted to `0`. Two wrong turns before
   landing on this: first tried `TW_EXCLUDE_DEFAULT_USB_INIT := false`
   (no effect - that flag doesn't control this property), then wrote a full
   duplicate manual ConfigFS gadget-setup block in this device tree's own
   init script (unnecessary and risked racing TWRP's own already-correct
   stock one, which was already building a real gadget tree under
   `/config/usb_gadget/g1` the whole time - confirmed live). The actual fix
   ended up being one line: `setprop sys.usb.configfs 1`.

4. **Even with configfs on, `sys.usb.config` read `mtp,adb`, not `adb`, and
   nothing enumerated.** Every rule that actually writes to
   `/config/usb_gadget/g1/UDC` (the step that attaches the gadget to the
   physical PHY - without it, literally nothing appears on the bus, which
   is exactly what was observed) is an **exact string match** on
   `sys.usb.config` (`=adb`, `=fastboot`, `=sideload` - no rule matches the
   combined `mtp,adb` value). Confirmed live: `sys.usb.ffs.ready` was stuck
   at `0` and `UDC` was empty. Root cause of the *own* regression: an
   earlier simplification pass moved this project's
   `setprop sys.usb.config adb` from `on boot` (late in boot - what the
   actively-working `ShionKanagawa/gts7lwifi-twrp` sibling build does) to
   `on init` (early - trivially overwritten by whatever later composes
   `mtp,adb`, likely TWRP's own MTP-enable logic). Moved back to `on boot`,
   also forcing `persist.sys.usb.config` so nothing re-reads a stale value.
   **Confirmed working immediately after**: `sys.usb.config: adb`,
   `sys.usb.ffs.ready: 1`, device visible in `lsusb` (`18d1:d001`) and
   `adb devices -l` (`product:omni_gts7l model:SM_T875`, recovery state).

**Current confirmed-working state on real hardware:** correct portrait
display/touch, `/vendor`/`/odm`/`/product`/`/system` mount cleanly, USB/adb
fully functional in recovery. Not yet checked: MTP specifically (not needed
for this project's purposes - forcing plain `adb` intentionally dropped it),
and the battery-percentage display (noticed missing in TWRP's UI, not
investigated - likely a separate, lower-priority `TW_*` battery-path config
issue, tracked here rather than dropped: check
`android.hardware.health@2.0-impl-default` or the equivalent battery
capacity sysfs path this recovery reads from, if it matters later).

## Explicitly not yet done

- The prebuilt kernel `Image`/`recovery_dtbo` this recovery boots are still
  external, unaudited binaries (see `../recovery/PROVENANCE.md`) - now
  proven to actually work on real hardware for display/touch/storage/USB,
  which is meaningfully more confidence than before, but still not
  something this project produced or can fully audit.
- The actual Phase 1 kernel/dtbo test (`gts7l-kernel-test.tar` in
  `flashing-plan.md`) has not been attempted yet - this session's hardware
  time went entirely into getting the *recovery* fully working first, per
  the flashing plan's own staged approach (establish a working fallback
  before touching `boot` at all). That's the next real step.
