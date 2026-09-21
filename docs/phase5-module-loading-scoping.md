# Phase 5 scoping: real kernel module loading

Recon pass done 2026-09-20 right after `docs/phase3-audio-scoping.md`
found that SM8250's real mainline audio stack **requires** loading the
codec/machine drivers as modules after boot - forcing them built-in
(this project's answer to "no module-loading infrastructure" for
every Phase 2/3 driver so far) is community-documented to cause a
genuine, non-recoverable probe failure, not just a size/efficiency
risk. Goal: find out what real module loading would actually take for
this project, and whether it's the low-risk, purely-additive change
the owner hopes it is. This is build-pipeline/Phase-5 infrastructure
scope, not a new hardware bring-up - cross-references
`docs/phase5-userspace-scoping.md` (the original Arch rootfs
scoping) and `docs/phase3-audio-scoping.md` (the task motivating this
one). Nothing here has been built or tested yet - this is pure
research, following the same methodology as every other Phase 2/3/5
scoping doc (real sources cited, nothing assumed).

## The headline finding: the hard part is already done, for free

**`CONFIG_MODULES=y` is already set** in every build this project has
produced (`work/linux/.config:950`) - plain `defconfig`'s own default,
never touched or disabled by `kernel/config/gts7l.fragment` (grepped
directly: zero `MODULE` references anywhere in the fragment). The
kernel binary this project has been flashing all session is already
fully capable of loading modules at runtime; nothing has ever loaded
one because the *rootfs* has never had any to offer, not because the
kernel itself was ever missing the capability.

**No module-signing gotcha, a real class of footgun proactively
checked for**: `# CONFIG_MODULE_SIG is not set` (`.config:958`) - an
unsigned local build's `.ko` files will load without any signature
check. This isn't a new risk to manage; it's simply off.

**Already empirically proven, not just theoretical**: `find
work/linux -name '*.ko'` finds **1616 `.ko` files already sitting in
the build tree right now**, produced as an ordinary side effect of
this project's own existing `make -j20 ARCH=arm64 LLVM=1 LLVM_IAS=1
Image` command - Kbuild compiles every `=m`-configured driver as a
`.ko` in the same pass it builds `Image`, with zero extra invocation
needed. The only genuinely new build step is `make modules_install`
(collecting those files into a clean, depmod-processed
`/lib/modules/<release>/` tree) - not a new compilation step, a
packaging one.

## The kernel release string: stable, but a real process discipline
point, not a blocker

`work/linux/include/config/kernel.release` (generated at build time)
currently reads **`7.2.0-dirty`** - matching the `uname -r` already
seen live on-device this session (Bluetooth work). This comes from
`scripts/setlocalversion`'s `git describe --dirty`-style logic
(`CONFIG_LOCALVERSION_AUTO=y`, `.config:45`), not a content hash - since
this project's `work/linux` checkout is a fixed base tag
(`8d3ae59288f1e7d58d76558a6ee96d533bc5019f`, "Linux 7.2") with all of
this project's own changes applied as always-uncommitted working-tree
modifications (never committed inside `work/linux` itself, only
tracked as `kernel/patches/*.patch` + the DTS/config fragment in this
repo), the release string is **stable and identical across every
build this project has ever produced or will produce**, as long as
that base tag doesn't change.

**The real gotcha, not previously encountered because nothing has
ever needed matched kernel+userspace artifacts before**:
`CONFIG_MODVERSIONS` is **not set** (`.config:956`) - there is no
per-symbol CRC check, only the coarse `vermagic` string (kernel
release + compiler + SMP flags) gate. Because the release string
never changes between builds by itself, **a stale `/lib/modules/
7.2.0-dirty/` tree from an older build would still "version-match" a
newer, actually-different kernel image** - the module loader would not
reject it the way a normal distro kernel (whose release string changes
on every real rebuild) would. This is a real, standing process rule to
add going forward, the same class of thing as the "package and check
the exact byte count before flashing" rule Wi-Fi's overflow taught
this project: **rebuild and redeploy the module tree together with
the kernel image on every kernel rebuild, never independently** - not
a blocker, just discipline that has to be followed by hand since the
kernel itself won't catch a mismatch for you here.

## What Arch's own systemd needs - and it turns out to be nothing custom

This is the central question this doc set out to answer. **Arch's
`systemd`/`udev`, once a real `/lib/modules/<uname -r>/` tree with
`depmod`-generated metadata (`modules.dep`, `modules.alias`, etc.)
exists on the rootfs, auto-loads matching modules with zero custom
scripting** - this is completely standard, general Linux-distro
behavior, not something specific to this project to build:
`systemd-udevd` processes a `MODALIAS` uevent (emitted by the kernel
for *any* bus that supports driver matching, including the
of-platform-device bus every devicetree node - `wcd938x-codec`,
`cs35l41@43`, etc. - already sits on) and loads a matching module via
`modprobe` automatically. On boot, `systemd-udev-trigger.service`
re-fires (`coldplugs`) this same event for every already-registered
device, so devices created before `udev` was running still get their
modules loaded once it starts. **`kernel/initramfs/init` (this
project's own bring-up initramfs) needs zero changes** - it already
does nothing but mount root and `exec switch_root /newroot /sbin/init`
(confirmed by reading it directly, lines ~60-84); no module needs
loading before that handoff, since the current UFS/ext4/storage path
is entirely built-in already, and everything module-loading-related
belongs to the real systemd instance that starts *after* the handoff,
exactly as it would on any ordinary Arch install.

**One real, audio-specific nuance this general capability does *not*
by itself solve, flagged honestly rather than assumed away**: the
community's own documented fix for SM8250 audio is loading the
codec/machine-driver modules only *after* the ADSP has genuinely
finished booting, not just "at some point after switch_root." Generic
udev coldplug auto-loading happens early in the normal boot sequence
and could still race the ADSP the same way a built-in driver does,
unless something explicitly orders it (e.g. a systemd unit/udev rule
gated on the `remoteproc`'s own sysfs `state` reaching `running`, or
relying on kernel deferred-probe if the relevant drivers correctly
return `-EPROBE_DEFER` while APR isn't ready yet - not confirmed
either way from this pass, genuinely unresolved, see below). **This
means module-loading infrastructure is necessary but may not be
sufficient for audio on its own** - it's still the correct prerequisite
either way, and this ordering question becomes audio's own follow-up
work once the general capability exists, not a reason to avoid
building the general capability now.

## The real build/deploy pipeline change needed

1. **Build**: add `make modules_install
   INSTALL_MOD_PATH=<some local output dir>
   INSTALL_MOD_STRIP=1` (module stripping is completely standard for
   embedded/device deployments - real size reduction with zero
   functional cost, the modules this project would actually load have
   no debug-symbol use case on this device) as a new step alongside
   the existing `make Image`/`make dtbs` steps in this project's
   established build sequence. No changes to the actual compile step -
   the `.ko` files already get built as a side effect of the ordinary
   `Image` build for whatever's `=m` in `.config`.
2. **Output location, matching established project convention**: this
   is *build output*, not a tracked source input - the same relationship
   `kernel/uniloader/blob/Image` (an ordinary build artifact) has to
   `kernel/dts/*.dts`/`kernel/config/gts7l.fragment` (the real,
   tracked source). It belongs under the existing gitignored `work/`
   scratch tree (e.g. `work/modules-install/`), **not** under `kernel/`
   - `kernel/` is reserved for real tracked source and genuinely
   unregenerable binary inputs pulled from the physical device
   (`kernel/firmware/`'s existing precedent: real extracted firmware
   blobs that can't be rebuilt from source, unlike a `.ko` which is
   pure build output from source already in `work/linux`).
3. **Deployment onto the live rootfs**: `scp`/`ssh` while booted into
   Arch, the same established mechanism used all session for every
   other non-kernel-image file this project has pushed (the `ath11k`
   firmware onto `/lib/firmware/`, `wlan-pci-rebind.service`/
   `bt-uart-rebind.service` onto `/etc/systemd/system/` +
   `/usr/local/bin/`) - push the whole `INSTALL_MOD_PATH` tree's
   `lib/modules/7.2.0-dirty/` directory to the rootfs's own
   `/lib/modules/7.2.0-dirty/`, then run `depmod 7.2.0-dirty` on-device
   (or push pre-generated `modules.dep`/etc. from the build host - both
   work, running `depmod` live on-device is simpler and matches this
   project's existing "do the finishing touch over SSH" pattern for
   `wlan-pci-rebind.service`/etc rather than trying to perfectly
   replicate host-side tooling). **Not** via TWRP: TWRP *could*
   plausibly mount the `archroot` partition directly (it's a plain
   ext4 partition per the whole-tablet approach), but every other
   non-kernel-image deployment this session has used the live-Arch
   SSH path instead, and there's no reason to deviate here - it's
   simpler (no extra reboot cycle) and already proven repeatedly.
4. **Needed on every kernel rebuild** where the set of `=m` symbols or
   their code changes (not just DTS-only or config-comment changes) -
   see the vermagic-stability discussion above for why this needs to
   be a deliberate discipline rule, not something the tooling enforces
   automatically for you.

## Real, unambiguous secondary benefit: this also resolves the
standing `boot`-partition-size problem, not just audio's own timing issue

This is worth stating plainly, since it's been flagged with growing
urgency in three straight scoping docs (Wi-Fi's `docs/phase3-wifi-bt-scoping.md`,
battery's `docs/phase3-battery-scoping.md`, and now audio's own doc)
without ever being resolved: **`.ko` files live entirely outside the
`boot` partition** - they get deployed onto the Arch rootfs (the
repurposed `userdata` partition, which has no meaningful size
constraint remotely close to the `boot` partition's confirmed,
zero-headroom 71303168-byte hard ceiling). Moving large or
code-heavy drivers to modules doesn't just solve audio's specific
ADSP-timing requirement - it structurally removes their size from the
one partition this project has already hit a real `dd` `ENOSPC` error
against once (Wi-Fi's firmware-in-kernel attempt, `docs/phase3-battery-scoping.md`'s
"the real blocker" section). This doesn't mean retroactively moving
already-working built-in drivers (Wi-Fi/BT/battery/UHID/Landlock) to
modules - those work today and there's no reason to disturb them - but
it means **every future Phase 3/4 addition (motion sensors, S Pen,
cameras, fingerprint - all still ahead per the roadmap) now has a real
choice** between forcing `=y` (simple, but consumes the now-fully-spent
boot-partition budget) and building as a module (a few extra minutes
of deploy work, but genuinely unconstrained by that partition) - a
choice this project hasn't had available until now.

## Safety: confirmed this stays entirely within the already-established
safe boundary

This change touches only two things, both already inside this
project's existing, repeatedly-exercised safety boundary:

- The **kernel build's own config** (`kernel/config/gts7l.fragment`,
  purely additive - setting specific driver symbols to `=m` instead of
  `=y`, or newly introducing symbols as `=m` for drivers not yet
  attempted at all like audio's codec stack) - still flashed the exact
  same way, to the exact same `boot`-partition-only target, verified
  with the exact same `dd`-readback + `rp`/`ro.bootloader`
  before-and-after check this project has used on every single flash
  this entire session.
- The **persistent Arch rootfs** (`userdata`-backed `archroot`
  partition) - already written to constantly all session (package
  installs, systemd units, firmware files) via the same SSH mechanism
  this change would reuse. Nothing here touches `vbmeta`, `dtbo`, the
  partition table, or any partition outside this project's own
  established whitelist.

No new partition, no new flashing mechanism, no interaction with the
anti-rollback counter or bootloader whatsoever - genuinely as
low-risk as the owner hoped, on the infrastructure side. The one real
residual risk is standard to *any* Linux system that loads modules at
all (a misbehaving module can still crash/hang the system, same as a
misbehaving built-in driver already can) - not a new category of risk
this project hasn't already been living with for every built-in driver
flashed so far.

## Open questions, genuinely unresolved

- **The ADSP-boot-ordering mechanism specifically** (flagged above,
  the one real audio-specific gap this general capability doesn't
  close by itself) - whether plain udev coldplug timing is naturally
  late enough in practice, or whether an explicit `systemd`
  unit/`udev` rule gated on the ADSP `remoteproc`'s own state is
  needed. Not resolved by this pass; genuinely audio's own follow-up
  work once module loading itself exists.
- **Real `.ko` file sizes for the specific audio-stack modules**, not
  measured in this pass (no local trial build attempted, per this
  doc's own research-only scope) - the existing 1616 already-built
  `.ko` files in the tree give confidence the mechanism itself works,
  but not a real size number for the audio-specific set
  (`SND_SOC_SM8250`, `WCD938X`(+SDW variant), `WSA881X`, `CS35L41`,
  the SoundWire bus core, four LPASS macro drivers). A real trial
  build (`make modules` with those symbols set to `=m`) would give an
  exact number cheaply, as a first, low-risk step of implementation.
- Whether `kmod` (providing `modprobe`/`depmod`) and `mkinitcpio` are
  genuinely already installed on the live rootfs - very likely (both
  are standard, near-universal Arch base-system packages, and a
  pacman post-transaction hook labeled "Updating linux initcpios" was
  already observed firing during this session's own package installs,
  strongly suggesting `mkinitcpio` is present) but **not directly,
  live-confirmed in this pass** - the device wasn't reachable over SSH
  at research time (mid-charger-test). A one-line live check
  (`pacman -Q kmod mkinitcpio`) should be the very first thing done
  once implementation starts.

## Suggested first step

Given this looks genuinely low-risk and purely additive, per the
research above:

1. **Live-confirm the two open questions above first** (`kmod`/
   `mkinitcpio` presence, quick SSH check) - cheap, and closes out the
   only two things this pass couldn't verify live.
2. **A real trial build**: set a small, low-risk, already-mainlined,
   easy-to-test symbol to `=m` instead of `=y` first (not audio yet -
   something already confirmed working built-in, tested in isolation,
   to prove the whole pipeline end-to-end with a known-good baseline
   to fall back to) - build, `modules_install`, push over SSH, `depmod`,
   confirm a real `udevadm test`/coldplug auto-load succeeds and the
   feature still works exactly as it does today. This is the "confirm
   the hardware path before chasing anything else" discipline this
   project has used for every other Phase 2/3 bring-up, applied to
   infrastructure instead of a peripheral.
3. Only once that trial is confirmed working end-to-end: return to
   `docs/phase3-audio-scoping.md`'s own suggested sequence (bootstrap
   symbols built-in, ADSP `remoteproc` bring-up as its own checkable
   milestone, codec/machine stack as modules, `sm8250-mtp.dts`'s real
   audio graph adapted) - with the ADSP-ordering open question above
   as that work's own first thing to resolve, likely via a real
   `remoteproc`-state-gated `udev` rule or systemd unit, tested live
   rather than assumed.

## Status: scoped, not yet started

Nothing built or flashed. This document is the research-only pass;
implementation is a separate, future step.
