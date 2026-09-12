# References

Local read-only clones of prior art, kept here so any agent instance working on
this project can grep/read them directly instead of re-fetching from the web.

These are **not** committed as git submodules and **not** tracked by the main
repo's history (see `../.gitignore`) — they're plain working clones, refreshed
with `git pull` as needed. Do not edit files inside them; treat as reference-only.

## Contents

- `ubuntu-galaxy-tab-s9-ultra/` — https://github.com/agcarbajo/ubuntu-galaxy-tab-s9-ultra
  Ubuntu 24.04 port for the Galaxy Tab S9 Ultra Wi-Fi (SM-X910), mainline Linux
  7.2-rc3 on SM8550/Snapdragon 8 Gen 2. This is the project our port is modeled
  after — see `../PORTING_ANALYSIS.md` for what is and isn't reusable from it.

- `postmarketos-galaxy-tab-s9-ultra/` — https://github.com/agcarbajo/postmarketos-galaxy-tab-s9-ultra
  The postmarketOS base port the Ubuntu project itself was forked from. Contains
  the original kernel/DTS/driver work in its earliest, least Ubuntu-specific form.

- `gts7l/` — https://github.com/ianmacd/gts7l
  **Samsung's official GPL kernel source for our actual target device**
  (Galaxy Tab S7 LTE, SM-T875, imported from Samsung's `SM-T875_QQ_Opensource.zip`
  at bootloader `T875XXU1ATK1`), with build-fix patches on top of the raw
  import. This is the ground-truth source for board DTS, PMIC/charger/panel/
  touch/S-Pen/Wi-Fi driver identification — see `../docs/hardware-inventory.md`
  for what was extracted from it. Two branches: `stock` (raw Samsung import)
  and `master` (+ 13 build-fix commits, TWRP-compatible config, build script).

- `linux/` — https://github.com/sm8250-mainline/linux
  Community mainline-Linux tree targeting Qualcomm SM8250 ("kona") devices in
  general (e.g. Lenovo Xiaoxin Pad Pro 2021). Not Tab-S7-specific, but the
  best existing *mainline* starting point for SM8250 platform bring-up
  (clocks/RPMh/pinctrl/base DRM-KMS) to fork a `gts7l` board file onto.

- `pmos-pmaports/` — https://github.com/sm8250-mainline/pmos-pmaports
  postmarketOS device packages from that same SM8250-mainline community
  effort. Packaging-structure reference for whenever this project reaches its
  Phase 5-equivalent (userspace/packaging) work.

Noted but **not** cloned (revisit only if a concrete need comes up — avoid
reference-repo sprawl):
- `mtan221/T875_SM8250` — a further downstream (Android 11, still non-mainline)
  custom-kernel fork of the same Samsung source. Not needed for the mainline
  bring-up path, but could be worth checking if a specific downstream driver
  fix is ever needed that the original `ATK1` GPL drop lacks.

## Adding more references

When cloning something else relevant here (e.g. Samsung's GPL kernel source
drop for `gts7`, SM8250-mainline community trees, other Tab S7 custom-kernel
repos), add a subsection above describing what it is and why it's relevant, so
future agent instances don't have to rediscover that.

## Refreshing

```sh
cd references/ubuntu-galaxy-tab-s9-ultra && git pull
cd references/postmarketos-galaxy-tab-s9-ultra && git pull
cd references/gts7l && git pull
cd references/linux && git pull
cd references/pmos-pmaports && git pull
```
