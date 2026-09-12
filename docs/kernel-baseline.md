# Kernel Baseline Decision — What to Fork the `gts7l` DTS From

Recorded: 2026-09-11. This resolves the open "pick the closest upstream board
file" item from Phase 0/1 of `../plans/roadmap.md`.

## Decision

**Base the `gts7l` devicetree directly on current upstream mainline Linux's
existing Samsung SM8250 family support** —
`arch/arm64/boot/dts/qcom/sm8250-samsung-common.dtsi` — rather than on:

- the `sm8250-mainline` community org's `linux` tree (`references/linux`,
  branch `sm8250/v6.2` — a stale, non-Samsung, OnePlus/Xiaomi/Sony-oriented
  fork), or
- Qualcomm's raw reference `kona.dts`/`kona.dtsi` (`references/gts7l`'s AOSP
  tree), or
- any of the non-Samsung `kona` phone boards (OnePlus 8 series etc.).

## Why

Checking current upstream (`torvalds/linux`, presently tracking `v7.3-rc2`)
directly — not just the `sm8250-mainline` mirror, which turned out to be a
stale `v6.2` snapshot focused on other vendors' phones — turned up something
better than expected:

```
arch/arm64/boot/dts/qcom/sm8250-samsung-common.dtsi   <- shared Samsung SM8250 base
arch/arm64/boot/dts/qcom/sm8250-samsung-r8q.dts        <- Samsung Galaxy S20 FE
arch/arm64/boot/dts/qcom/sm8250-samsung-x1q.dts        <- Samsung Galaxy S20
```

Mainline already carries **Samsung's own SM8250 device family**, not just
generic-vendor `kona` boards. `sm8250-samsung-common.dtsi` is built directly
on `pm8150.dtsi` — **the exact PMIC family confirmed on the Tab S7
(`PM8150`+`PM8009`) in `hardware-inventory.md`** — plus shared `gpio-keys`,
`ramoops`, `simple-framebuffer`, and regulator scaffolding that Samsung's
SM8250 phones all share. A Samsung device is a much closer relative of
another Samsung device on the same SoC than a OnePlus/Xiaomi one is, even
before accounting for the PMIC match: expect closer regulator topology,
similar GPIO conventions, and a maintainer community that already understands
Samsung's device-tree idioms.

Per-model files (`r8q`, `x1q`) are refreshingly small — each is only a
`model`/`compatible` stanza plus three `firmware-name` overrides
(adsp/cdsp/slpi paths). That's the shape a `gts7l` board file should take
too: a `sm8250-samsung-gts7l.dts` including `sm8250-samsung-common.dtsi`, with
Tab-S7-specific overrides layered in for what actually differs from a phone —
display (Novatek NT36523 panel, not a phone AMOLED), touch (same NT36523,
integrated TDDI), S Pen (Wacom W90xx — phones don't have this), Wi-Fi/BT
(QCA6390), and MAX77705 charger/fuel-gauge wiring. All per
`hardware-inventory.md`.

## Naming convention to follow

Samsung's upstream `compatible` convention is `"samsung,<codename>", "qcom,sm8250"`
(e.g. `"samsung,x1q", "qcom,sm8250"`). Follow the same pattern:
**`"samsung,gts7l", "qcom,sm8250"`** for the board file's `compatible`, and
name the file `sm8250-samsung-gts7l.dts` to match upstream's existing file
naming for this family, in case this work is ever proposed for upstream
inclusion later.

## What still needs to be figured out (not yet done)

- `sm8250-samsung-common.dtsi` is phone-shaped (`chassis-type = "handset"`,
  a 1080×2400 phone framebuffer placeholder, single `vol-up` key only — no
  `vol-down`, no tablet-sized panel). A `gts7l` board file will need to
  override or bypass a fair amount of this rather than including it verbatim
  — treat it as a strong reference for *shared platform plumbing* (PMIC,
  ADSP/CDSP/SLPI firmware paths, base regulator setup), not as a drop-in
  parent to inherit unmodified.
- The `adsp`/`cdsp`/`slpi` `firmware-name` paths (`qcom/sm8250/Samsung/<codename>/*.mbn`)
  point at Samsung's signed DSP firmware blobs — need to check whether the
  same blobs from the Tab S7's stock firmware can be reused under a
  `Samsung/gts7l/` path, same as the S9 Ultra project staged proprietary
  blobs from the owner's own device rather than redistributing them (see that
  project's `kernel/PROVENANCE.md` precedent).
- Not yet checked whether `r8q`/`x1q`'s upstream commits reference a
  postmarketOS or other community port that already solved phone-vs-tablet
  differences worth learning from — worth a follow-up `git log`/PR search on
  those two files specifically before writing the `gts7l` DTS from scratch.
