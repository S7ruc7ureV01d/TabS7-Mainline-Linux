# Custom Recovery (TWRP/PBRP) Options for `gts7l` (SM-T875)

Recorded: 2026-09-11. This closes out the last open Phase 0 exit criterion in
`../plans/roadmap.md` ("a working TWRP... confirmed available, or a plan to
build one") — **research is complete; a concrete decision on which option to
actually use/flash is still open and deliberately left to the owner**, since
flashing anything to this device is exactly the kind of consequential,
hard-to-reverse action that shouldn't be auto-decided given the anti-rollback
constraint in `device-state.md`.

## TL;DR

No option found is a risk-free, "just download and flash" slam dunk for our
*exact* unit (`SM-T875`, bootloader `T875XXU1ATK4`, RP=1, must-not-advance).
There are three real paths, in order of how much we'd have to trust someone
else's work vs. do it ourselves:

1. **A currently-maintained prebuilt TWRP exists, but for the wrong model
   variant** (T870 Wi-Fi, not our T875 LTE).
2. **A currently-maintained project explicitly lists our model** (TerracottaROM,
   `gts7l`) but its actual recovery/vbmeta artifacts weren't directly
   inspectable this pass (Mega/Google Drive/XDA links, not straightforwardly
   fetchable by an automated tool) — needs a manual look, and its own
   installation guidance contains a red flag (see below).
3. **Two old, source-only TWRP device trees target our exact model** (`gts7l`/
   T875) by name, but haven't been built into a flashable image by anyone in
   4-5 years — building one ourselves is fully within our control and
   auditable, at the cost of doing the AOSP/TWRP build work.

## Option 1 — ShionKanagawa's TWRP (prebuilt, actively maintained, wrong variant)

- Repo: <https://github.com/ShionKanagawa/android_device_samsung_gts7lwifi-twrp>
- Latest release: `v0.3.0`, **TWRP 3.7.1-12**, published 2025-07-15, kernel
  `4.19.325`. Ships `TWRP-3.7.1_12-1-gts7lwifi-UNOFFICIAL.tar` (and a
  matching `.img`) plus a separate `vbmeta.tar` (an AVB-verification-disabled
  vbmeta, flashed alongside it — same technique the S9 Ultra project used).
  Actively maintained (multiple 2025 releases: v0.1.0 Sep 2024 → v0.3.0 Jul
  2025), credits LineageOS team and named contributors for recent fixes.
- **Problem: this device tree's README explicitly says "Samsung Galaxy Tab S7
  T870 (gts7lwifi)"** — the Wi-Fi-only model, not our LTE `T875`. `T870` and
  `T875` share the SoC/board but **T875 has modem/RIL partitions T870 lacks**
  (confirmed in `device-state.md`'s partition dump — `modem`, `modemst1/2`,
  `mdm1m9kefs*`, `mdmddr`, `fsg`). A recovery's `fstab`/partition table built
  for T870 is not guaranteed to handle T875's different partition layout
  correctly. **Do not assume this image is safe to flash on our unit without
  verifying its fstab against `T875`'s actual partition table first.**
- Installation method it documents: flash the `.tar` via **Odin3, AP slot,
  Auto Reboot unticked**, then flash `vbmeta.tar` before rebooting — i.e., it
  only touches `recovery` and `vbmeta`, not `abl`/`xbl`/`tz`/bootloader
  proper. This is consistent with **not** requiring an anti-rollback (`rp`)
  bump by itself, *if* the recovery/vbmeta images themselves don't embed a
  higher anti-rollback version tag than what's currently fused — not
  independently verified this pass.

## Option 2 — TerracottaROM (active project, explicitly lists `gts7l`)

- GitLab (moved off GitHub after a takedown): <https://gitlab.com/jeykul/TerracottaROM>
- XDA thread: "[ROM][15][gts7l/gts7lwifi/gts7xl/gts7xlwifi] TerracottaROM 1.2.0
  (OneUI 7) for Tab S7+ and Tab S7", last updated 2025-08-21. **Explicitly
  lists `gts7l` (our exact codename) as supported**, alongside `gts7lwifi`,
  `gts7xl`, `gts7xlwifi`. A fork of ProjectNERV, itself a fork of UN1CA.
- Its installation instructions (as summarized from forum discussion; the XDA
  thread itself returned HTTP 403 to automated fetches this pass — a human
  browsing it directly will see more) call for downloading a **PBRP/TWRP
  build plus a matching `vbmeta.img`** for the specific codename, flashed via
  Odin.
- **⚠️ Red flag found in the installation guidance:** it tells users to
  *"make sure you're on the latest Stock firmware"* and that the *"OEM
  Bootloader is Unlocked"* before installing. **"Latest stock firmware" is
  exactly what this project must never do to this unit** — updating past
  `T875XXU1ATK4` risks advancing the `rp` anti-rollback counter, which is
  irreversible (see `device-state.md`). **Before using anything from this
  project, get the actual `gts7l`-specific recovery/vbmeta files and check
  what bootloader/AP version they were built against and whether they
  actually require an update, or whether that instruction is generic
  boilerplate that doesn't apply to a device already on a recent-enough
  firmware.** Don't take the generic guidance at face value for this specific
  unit.
- Not independently downloaded/inspected this pass — the actual files are
  distributed via Mega/Google Drive links embedded in a paginated XDA thread,
  which isn't reliably fetchable by automated tools. **This needs a manual
  look by whoever has XDA/Mega access, specifically hunting for: (a) the
  `gts7l` (not `gts7lwifi`) recovery+vbmeta download links, (b) what
  bootloader/AP build they were tested against, (c) whether flashing them
  actually requires a firmware update first or whether that's boilerplate.**

## Option 3 — Build our own from the `gts7l`-specific source device trees

Two source-only TWRP device trees exist, both explicitly named for our exact
model, both stale (no commits or releases in 4-5 years), neither ever built
into a downloadable image by their authors:

- <https://github.com/ianmacd/twrp_gts7l> (same author as `references/gts7l`,
  the kernel source we're already using — last pushed 2020-12-11)
- <https://github.com/Bush-cat/twrp_gts7l> (last pushed 2021-06-13)

Building one of these ourselves against a current TWRP/AOSP recovery build
tree is the most work, but gives full control and auditability — we'd know
exactly what's in the image, that it's built against `T875`'s real partition
table (not T870's), and could verify there's nothing in it that would touch
`abl`/`xbl`/`vbmeta` in a way that risks `rp`. This is the option most in
keeping with the project's general preference (matching the S9 Ultra
project's approach) for reproducible, understood builds over trusting a
downloaded binary — at the cost of it being 4-5-year-old device-tree code
that will likely need real work to get building against a current TWRP tree.

## Recommendation (not yet acted on — needs a decision)

Given the anti-rollback constraint is permanent and non-negotiable, and given
that Option 1's fstab-mismatch risk and Option 2's "update to latest
firmware" instruction are both real yellow/red flags for *this specific
unit*, the safest sequencing is:

1. Manually pull the actual `gts7l`-specific files referenced by TerracottaROM
   (Option 2) and inspect what bootloader/AP version they assume, before
   trusting the "update to latest stock" instruction either way.
2. In parallel, check whether ShionKanagawa's T870 TWRP's `fstab`/`BoardConfig`
   could be adapted for T875's partition table cheaply, as a fallback that
   reuses actively-maintained, working code rather than reviving a 5-year-old
   tree from scratch.
3. Treat Option 3 (build our own from `twrp_gts7l`) as the fallback if 1 and 2
   don't produce something trustworthy — not the default first move, since
   it's the most work.

**Nothing has been flashed or downloaded to the device as part of this
research pass** — this is purely a documented survey of what exists, per the
"stop and let the owner decide" posture warranted by the RP constraint.

## Progress log

- 2026-09-11: Initial survey completed (this document). Roadmap Phase 0's
  TWRP checkbox marked "researched, decision pending" rather than fully
  done — see `../plans/roadmap.md`.
