# Phase 3 scoping: Audio (speakers + microphone)

Recon pass before starting real audio bring-up, done 2026-09-20 right
after charging status, fuel gauge, and Wi-Fi/Bluetooth all got
confirmed working on real hardware, and after USB-C/PD/MUIC was
scoped and deliberately deferred (no mainline prior art, ~7,760-line
port). Goal: find out how real hardware wiring, mainline driver
availability, and this project's own "force everything built-in, no
module loading" policy interact for audio specifically - **per this
project's established practice, prior art and community-maturity
research was done before assuming either "just enable it" (Wi-Fi/BT/
battery's outcome) or "no driver exists" (USB-C/PD's outcome).**
Nothing here has been built or tested yet - this is pure research,
following the same methodology as every other Phase 2/3 scoping doc
(real sources cited, nothing assumed).

## Real hardware: a genuinely complex, multi-chip audio topology

Confirmed directly in the downstream overlay
(`references/gts7l/arch/arm64/boot/dts/samsung/gts7l/
kona-sec-gts7l-eur-overlay-r07.dts`) - this is **not** a single
codec/amp pair, it's a real SoundWire-based multi-component graph:

- **4x Cirrus Logic CS35L41** smart speaker amplifiers -
  `cs35l41@43`/`@42`/`@41`/`@40` (lines 9643, 9684, 9723, 9761,
  `compatible = "cirrus,cs35l41"`), with fixup labels `cs35l41_fl`/
  `cs35l41_fr` (line 12370-12371) confirming at least front-left/
  front-right channels - a quad-speaker layout (matches this
  tablet's real marketed "AKG quad speaker" hardware), not a simple
  stereo pair.
- **Qualcomm WCD938X** - the SoC-family's own codec IC, wired over
  **SoundWire** (not I2C/I2S) via separate TX and RX "macro" nodes
  (`tx-macro@3220000`/`rx-macro@3200000`, each with their own
  `swr_master` sub-bus and a `wcd938x-tx-slave`/`wcd938x-rx-slave`
  child, lines 6898-6935) plus a top-level `wcd938x-codec` node (line
  7002-7003, `compatible = "qcom,wcd938x-codec"`). This is Qualcomm's
  standard "Bolero" codec architecture for this SoC generation
  (`asoc-codec-names` at line 7048 literally lists `"bolero_codec"`).
- **4x Qualcomm WSA881x** smart speaker amps - `wsa881x@20170211`/
  `@20170212`/`@21170213`/`@21170214` (lines 6968-6993), *also*
  SoundWire, under a `wsa-macro@3240000`. **Real open question,
  genuinely unresolved by this pass**: why both CS35L41 *and* WSA881x
  appear to be present for what should be 4 physical speakers - either
  one set is a disabled/unused reference-design leftover, or they
  serve genuinely different channels (e.g. WSA881x for the two larger
  woofers, CS35L41 for tweeters, a real design some Samsung tablets
  use) - not determined from the DTS alone; would need a live
  `status`/regulator-supply check or a stock Android `dmesg`/`amixer`
  capture to resolve.
- **LPASS clock IDs and `qcom,codec-lpass-ext-clk-freq` properties**
  (lines 7154-7218, 8 separate entries) confirm this board genuinely
  drives multiple codec clock domains from the SoC's own LPASS
  (Low-Power Audio Subsystem) clock controller, not a simpler
  external-oscillator setup.

**Microphone(s)**: not separately identified in this pass - WCD938X
is itself a combo codec (has its own TX/ADC paths for mic input, per
its real, mainlined driver's own capabilities), so mic input is very
likely routed through the same WCD938X TX macro path rather than a
separate chip - not confirmed live.

## Mainline driver availability: much better than the "SM8250 audio is
notoriously hard" reputation alone would suggest

Checked `work/linux/sound/soc/qcom/`, `work/linux/sound/soc/codecs/`,
and `work/linux/drivers/soundwire/` directly - **every real chip this
board needs already has a mainline driver, already built at some point
this session** (`.ko`/`.mod` files already present in the tree from an
earlier `defconfig`-driven build, confirming these Kconfig symbols
already resolve and compile cleanly against Linux 7.2):

- `sound/soc/codecs/wcd938x.c` + `wcd938x-sdw.c` (SoundWire variant)
- `sound/soc/codecs/wsa881x.c`
- `sound/soc/codecs/cs35l41.c` + `cs35l41-i2c.c` (a mature, widely-used
  driver across many Windows/Chromebook laptop speaker setups, not
  chip-specific to this board)
- `sound/soc/codecs/lpass-rx-macro.c`/`lpass-tx-macro.c`/
  `lpass-wsa-macro.c`/`lpass-va-macro.c` (the Bolero macro framework
  downstream's own `bolero_codec` name maps to)
- `drivers/soundwire/qcom.c` (the actual SoundWire bus controller
  driver for this SoC)
- `sound/soc/qcom/sm8250.dtsi`/`sm8250-mtp.dts` - **a complete, real,
  working reference DT audio graph already exists in this exact
  kernel tree**, for the *same SoC* (Qualcomm's own MTP reference
  board), using the *same* codec set (WCD938X + WSA881x over
  SoundWire, `q6afe`/`q6asm`/`q6routing` DSP DAI links) - this is a
  substantially better starting point than anything found for
  Wi-Fi/BT/battery, which all needed to adapt a *different device's*
  DTS. `sm8250-mtp.dts:655-820` (the `&sound {}` node and its
  `swr0`/`swr1`/`swr2` SoundWire bus definitions) is a directly
  copyable pattern, not something to reverse-engineer from scratch.

**Conclusion: this is not a "no driver exists" situation like
USB-C/PD, and not a from-scratch port like touch was** - every
individual component driver is real, mature, mainlined code with a
working same-SoC reference to adapt from.

## The real complication: a documented, community-known boot-ordering
requirement that conflicts directly with this project's own standing policy

Web research (per this project's established practice) into SM8250
mainline audio maturity found the real community history, via the
active `sm8250-mainline` GitHub org and postmarketOS's own SM8250
port:

- SM8250 audio genuinely works on real mainline-adjacent kernels today
  (postmarketOS's own `linux-postmarketos-qcom-sm8250` package, an
  active `#sm8250-mainline` community channel) - this isn't a dead or
  purely theoretical effort.
- **A specific, documented, real timing problem exists**: the audio
  probe fails if the relevant drivers are built directly into the
  kernel image rather than loaded as modules from the rootfs after
  boot, because **the ADSP (audio DSP coprocessor) isn't ready to
  serve APR (Audio Packet Router, the IPC mechanism every Q6-DSP-
  routed audio driver depends on) requests that early in boot** -
  a probe-time failure, not a recoverable "wait and retry" deferred
  probe. The community's own documented fix: keep `QCOM_APR`,
  `QCOM_Q6V5_PAS`, `QCOM_Q6V5_COMMON`, and `PINCTRL_LPASS_LPI` built
  in (these are the *bootstrap* pieces - loading and authenticating
  the ADSP firmware image itself, a real remoteproc/PAS flow directly
  comparable to this project's own Adreno zap-shader precedent, not
  just Kconfig plumbing), but build the actual **codec/machine-driver
  audio stack as loadable modules**, brought up by userspace
  (`systemd`/`udev`) only once the ADSP has genuinely finished
  booting.

**This is a direct, structural conflict with this project's own
standing "force every driver `=y`, no module-loading infrastructure"
policy** - a policy this project has followed successfully (if
sometimes painfully) for every Phase 2/3 chunk so far, including
several real tristate-ceiling surprises along the way (`CFG80211`/
`MAC80211`/`RFKILL` for Wi-Fi, `CONFIG_PHY_QCOM_QMP_PCIE`,
`CONFIG_UHID`/`BT_HIDP`, `CONFIG_SECURITY_LANDLOCK`). Every one of
those was a Kconfig *dependency-graph* problem, solvable by forcing
more `=y` symbols. **Audio is a different kind of problem: forcing
the codec/machine drivers `=y` doesn't just risk not fitting the boot
partition, it is independently, community-documented to cause a real,
non-recoverable probe failure at the wrong point in boot, regardless
of Kconfig dependency resolution.** This is the first Phase 3 item
where the "always force built-in" shortcut this project has relied on
so far is very likely to genuinely not work at all, not just risk
inefficiency.

Real Kconfig dependency chain confirming the scope of what would need
to move to modules: `sound/soc/qcom/Kconfig:185`,
`config SND_SOC_SM8250` - `depends on QCOM_APR && SOUNDWIRE`,
`depends on COMMON_CLK`; `sound/soc/codecs/Kconfig:2473`,
`SND_SOC_WCD938X depends on SND_SOC_WCD938X_SDW`, which itself
`depends on SOUNDWIRE`; `SND_SOC_WSA881X depends on SOUNDWIRE` too -
the entire codec stack sits behind the SoundWire bus subsystem
(`drivers/soundwire/Kconfig`), a real, separate bus driver with its
own dependency surface this project has never touched at all.

## The `boot` partition size question, and why it matters more here

Same standing constraint as every Phase 3 item since Wi-Fi: the
partition is at its confirmed, measured hard ceiling (71303168 bytes,
zero headroom on every recent build). Two things make this worse for
audio specifically, not just a repeat of the same rule:

1. **This is real driver code volume this project hasn't yet
   attempted at this scale**: SoundWire bus core + `qcom.c` bus
   driver, WCD938X + its SDW variant, WSA881x, CS35L41, four LPASS
   macro drivers, the SM8250 ASoC machine driver, and Q6 DSP
   APR/AFE/ASM/routing glue - a meaningfully larger set of new
   built-in code than any single Wi-Fi/BT/battery addition, all of
   which fit within small page-rounding slack so far.
2. **The community's own documented fix (move the codec/machine
   stack to modules) can't be adopted without solving this project's
   long-deferred module-loading gap first** - previously flagged as a
   "nice to have soon" in the Wi-Fi scoping doc, and again in the
   battery-fuel-gauge doc as "hasn't been forced yet." Audio may be
   the item that finally forces this decision, rather than something
   to defer again.

## Open questions, genuinely unresolved

- Whether this exact unit's ADSP firmware blob (needed for
  `QCOM_Q6V5_PAS` to actually load and authenticate the DSP, the same
  real "device-signed firmware blob" pattern as the Adreno
  zap-shader) is obtainable the same way - not checked in this pass,
  would need a live-device `/vendor/firmware` search, same precedent
  as GPU/Wi-Fi/BT firmware extraction.
- Whether CS35L41 or WSA881x (or both, on different channels) is the
  real, active speaker path on this specific board revision - not
  resolved from the DTS alone.
- Whether forcing just the bootstrap pieces (`QCOM_APR`/
  `QCOM_Q6V5_PAS`/`QCOM_Q6V5_COMMON`/`PINCTRL_LPASS_LPI`) built-in
  while leaving everything else unbuilt (not even as modules, since
  this project has no module-loading path at all yet) would leave the
  system in a stable, harmless "no audio, nothing else broken" state
  - probably yes (deferred probe / absent driver is normal, not
  fatal), but not confirmed.

## Suggested first step: decide on the module-loading prerequisite
before writing any audio-specific code

Given the community-documented boot-ordering requirement directly
conflicts with this project's established "force everything built-in"
pattern, the honest recommendation is **not** to start with a DTS
node the way every other Phase 3 item did. Instead:

1. **Resolve the module-loading question first**, as its own
   decision, before any audio-specific work: either (a) build a real
   `/lib/modules` + `modprobe`/`depmod` path into the Arch rootfs
   (Phase 5 already has a persistent `systemd` install, `pacman`'s own
   `linux`-adjacent tooling normally handles this automatically) and a
   `udev`/systemd unit to load the audio stack once the ADSP is up, or
   (b) accept audio may not be achievable under this project's current
   all-built-in kernel model at all, and defer it explicitly rather
   than attempting a doomed all-`=y` build.
2. Only once that's decided: force the bootstrap-only symbols
   (`QCOM_APR`, `QCOM_Q6V5_PAS`, `QCOM_Q6V5_COMMON`,
   `PINCTRL_LPASS_LPI`) built-in, add the ADSP `remoteproc` devicetree
   node (base scaffolding already exists in `sm8250.dtsi`, same
   "disabled by default" pattern as every other peripheral this
   project has enabled), and confirm the ADSP itself boots and
   authenticates cleanly (a real, checkable milestone independent of
   any codec work at all) before touching WCD938X/WSA881x/CS35L41/
   SoundWire.
3. Adapt `sm8250-mtp.dts`'s real, complete `&sound {}` graph
   (SoundWire buses, macros, DAI links) rather than writing one from
   scratch, once the module-loading and ADSP-boot questions are both
   resolved.
4. **Package and check the exact byte count against 71303168 before
   touching the device** - standing rule, more likely than ever to
   actually bind given the code volume here.

## Status: scoped, not yet started

Nothing built or flashed. This document is the research-only pass;
implementation - which may reasonably start with the module-loading
prerequisite decision rather than audio-specific code at all - is a
separate, future step.
