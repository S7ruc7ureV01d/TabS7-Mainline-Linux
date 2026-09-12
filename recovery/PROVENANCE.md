# Recovery Source Provenance

`device-samsung-gts7l/` in this directory is our own patched fork of
**`ianmacd/twrp_gts7l`** (<https://github.com/ianmacd/twrp_gts7l>, commit
`e022e88`, "Initial device tree for the T875 (Galaxy Tab S7)"), with two real
bugs fixed to make it build against the current `twrp-12.1` minimal manifest
— see `../docs/twrp-build-notes.md` for the full story of what was wrong and
why.

## What's committed here vs. what isn't

Only the small, license-clear **text** files are committed:
`Android.mk`, `AndroidProducts.mk`, `BoardConfig.mk`, `omni_gts7l.mk`,
`README.md`, `system.prop`, and the `recovery/` fstab/init files —
Apache-2.0-licensed per the original repo's file headers.

**Not committed** (matches the S9 Ultra reference project's convention of not
storing proprietary/binary firmware in git — see
`../references/ubuntu-galaxy-tab-s9-ultra/kernel/PROVENANCE.md` for that
precedent): the original repo's `prebuilt/` directory, which contains a
prebuilt kernel `Image` (49MB), `recovery_dtbo`, and `dtb/dtb.dtb`. These are
binary blobs of unclear original provenance (likely built by `ianmacd` from
Samsung's kernel source or extracted from a stock firmware, not something
this project produced or independently verified). Re-fetch them from the
upstream repo if rebuilding from scratch:

| File | SHA-256 (as fetched 2026-09-11) |
|---|---|
| `prebuilt/Image` | `20cc684941de698d29219b3b660ed741b3cb394b6b3b5c2a924a8b640bdda0dd` |
| `prebuilt/recovery_dtbo` | `b4194a50e971fba34afe0ca037948731e70d19721f8e0ba7b7c9b85512ed038e` |
| `prebuilt/dtb/dtb.dtb` | `9d285a6132fc344ca685f709dcbb99008dad6a2a49fcb8d1ed4ee6ec0217aa69` |

If these hashes ever don't match what's in the upstream repo, treat that as a
signal to re-verify before trusting the prebuilt kernel — it's the one part
of this whole recovery build we didn't produce ourselves and can't fully
audit line-by-line.

## Build artifacts

The actual built `recovery.img` and a generated `vbmeta_disabled.img` (AVB
verification disabled, `avbtool make_vbmeta_image --flags 2`, matching the
S9 Ultra project's documented precedent for this) live in `../artifacts/`,
gitignored — regenerate them per `../docs/twrp-build-notes.md` rather than
trusting a stale copy.

## License

Per the original repo and Android/TWRP convention: Apache License 2.0 for
the device tree files. The upstream kernel/recovery/AOSP source this builds
against carries its own licensing (GPL-2.0 for the Linux kernel prebuilt,
Apache-2.0 for most of AOSP/TWRP) — this project does not redistribute that
source, only our small patch on top of one publicly available device tree.
