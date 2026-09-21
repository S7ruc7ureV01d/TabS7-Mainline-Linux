# Hard-lockup crash investigation: NMI hardlockup detector research (2026-09-20)

Research-only follow-up to the real hard-lockup crash investigated live on hardware
(see `docs/kernel-boot-debugging.md` for the confirmed DPU frame-event overflow fix,
the `CONFIG_INTERCONNECT_QCOM_OSM_L3` cpufreq fix, and the pstore/`mmap()`-recovered
backtrace showing an RCU stall on CPU 5 → NMI sent from CPU 4 → CPU 5 never responded
→ buddy-detector panic reported by CPU 6, with CPU 5's own stack never captured).

## 1. Can we get a real per-CPU NMI-capable hardlockup detector on this SoC?

Two real upstream mechanisms exist, both active in mailing-list review as of mid-2026:

- **`CONFIG_HARDLOCKUP_DETECTOR_PERF` via ARM64 GICv3 pseudo-NMI**
  (`CONFIG_ARM64_PSEUDO_NMI`). This is the standard, already-upstream mechanism (not a
  pending patch). Requirements, confirmed via the v8 pseudo-NMI series and later
  Qualcomm testing threads:
  - GICv3 (SM8250 has this).
  - `SCR_EL3.FIQ` must be `1` when Linux is running, OR Linux must be running in a
    single security state. On this device, TrustZone/`xbl`/`tz` firmware owns EL3 —
    whether it sets `SCR_EL3.FIQ=1` for the Linux EL2/EL1 world is **firmware-controlled
    and outside our reach** (we've never touched `tz`/`xbl`, and per the project's
    hard rule, never will). This can only be answered empirically: enable
    `CONFIG_ARM64_PSEUDO_NMI=y`, boot with `irqchip.gicv3_pseudo_nmi=1` (or the older
    `enable_pseudo_nmi`), and check `dmesg` for `GICv3: Pseudo-NMI enabled` vs. a
    silent fallback to normal IRQ priority.
  - Real, measured cost if it *does* work: ~5% on general workloads, up to ~66% on a
    syscall-heavy microbenchmark (from the current LKML pseudo-NMI performance
    discussion). Non-trivial for a device we also use for everyday gaming/graphics load.
  - This is a **build+bootarg-only change** — no devicetree change needed, no
    `boot`-partition size concern beyond what a bootarg costs (~free). Low risk to try.

- **Qualcomm watchdog-pretimeout-as-NMI series** (`watchdog: qcom: Support NMI...`,
  actively being revised, v2/v3 posted July–September 2026). This repurposes the
  existing QCOM hardware watchdog's pretimeout "bark" interrupt to fire as a
  pseudo-NMI specifically so the pretimeout governor can capture a backtrace of a
  *fully IRQ-masked* CPU before the hardware watchdog resets the board. Tested by its
  author on "Google CoachZ" (another Qualcomm ARM64 SoC), not SM8250 specifically, and
  it still **depends on the same pseudo-NMI/`SCR_EL3.FIQ` prerequisite above** — it's a
  refinement on top, not an alternative to it. Also not yet merged upstream (patch
  series, not in mainline `qcom-wdt` driver as of this writing) — using it here would
  mean carrying an out-of-tree patch, which is a real added maintenance cost.

- **SDEI-based cross-CPU NMI** (`arm64: cross-CPU NMI via SDEI`, v2–v6 in review). A
  *lighter-weight alternative* to full pseudo-NMI — delivers a firmware-mediated
  NMI-like signal on demand (e.g., only when a stall is actually detected) instead of
  running with interrupt-priority masking active at all times, avoiding the ~5%
  steady-state cost. Requires the platform's EL3 firmware to support SDEI (specifically
  the software-signalled `SDEI_EVENT_SIGNAL`). Whether Samsung's SM8250 TrustZone
  firmware on this specific device implements SDEI is unknown and, again, effectively
  unanswerable without either firmware source (which we don't have) or empirical
  probing (`sdei_probe()` success/failure in `dmesg`). Not yet in mainline as of this
  writing — same out-of-tree cost as the watchdog series.

  **Bottom line for point 1:** the only thing actually available in-tree, today, with
  no patch-carrying burden, is `CONFIG_ARM64_PSEUDO_NMI` + `HARDLOCKUP_DETECTOR_PERF`.
  It's genuinely worth a one-round trial specifically *because* it's a firmware-gated
  coin flip we can resolve empirically in minutes (enable, boot, grep dmesg for
  "Pseudo-NMI enabled"), and if it works, we keep it disabled by default and only set
  the bootarg when deliberately trying to reproduce+capture the crash, avoiding the 5%
  tax during normal use (TWRP fastboot-style: add the bootarg only for a targeted
  reproduction session, not permanently in the DTB/cmdline).

## 2. Is "RCU stall then hard lockup under heavy JVM/GC/Mesa-Freedreno load" a known pattern?

No specific, named upstream bug report matching this exact combination (Minecraft/LWJGL
JVM + Freedreno + SM8250) turned up. What the general RCU-stall literature does say,
directly relevant to judging this case:

- An RCU stall warning is **definitionally a symptom, not a cause** — it fires when a
  CPU hasn't passed through a quiescent state for `RCU_CPU_STALL_TIMEOUT` seconds,
  which is exactly consistent with "CPU 5 was already wedged" rather than "RCU itself
  broke something." The recovered backtrace already shows the actual mechanism: CPU 5
  stopped responding to *everything*, including an NMI — that's a hard freeze of the
  CPU itself (stuck instruction stream, stuck in a firmware/EL3 trap, or a hardware
  fault), not an RCU subsystem bug.
  Documented common causes of a genuine stall (kernel.org `stallwarn.txt` and the
  Red Hat/SUSE KB pages found): a slow serial console flooding printk under load, an
  interrupt handler that runs longer than the interrupt period, or a higher-priority
  realtime task starving RCU's kthreads. None of the first two apply here (no serial
  console in the loop, no known long-running IRQ handler implicated). The third is
  *structurally plausible* and connects directly to something we already know:
  the DPU frame-event kthread runs `SCHED_FIFO` (confirmed via `sched_set_fifo()` in
  `dpu_kms.c`). A convergence of (a) heavy GPU commit traffic from Minecraft's OpenGL
  renderer, (b) the RT-priority DPU event thread we already found to be overflowing at
  4 slots, and (c) whatever CPU that thread pins to, is a real, hardware-grounded
  candidate mechanism for starving a normal-priority CPU long enough to look "frozen"
  even before a true hardware/firmware-level hang — though the NMI-unresponsiveness in
  the actual recovered trace is stronger evidence of a true hard hang than pure RT
  starvation (a pure scheduler-starved CPU still normally answers an NMI, since NMI
  delivery on real hardware bypasses the scheduler entirely — the fact it didn't
  respond even to that is the strongest single data point we have, and points toward
  a genuinely-frozen core, not merely a starved one).
- No evidence found of a known, tracked Freedreno/Mesa a650 hang bug matching "hangs
  the whole CPU, not just the GPU ring" under sustained load. Mesa's own hang-debugging
  docs (`TU_DEBUG=hang`, breadcrumbs, GFR) are for GPU-side hangs recoverable by a GPU
  reset — not CPU lockups. If Freedreno were the root cause we'd expect a GPU hang
  timeout/recovery message in the log, not a CPU-side RCU stall; none was seen in any
  of the three real captures. This weakens (doesn't rule out) a pure-GPU-driver
  explanation.

  **Bottom line for point 2:** not a documented, named upstream issue. The evidence in
  hand (NMI-unresponsive CPU, no GPU-hang-recovery messages, RT-priority DPU thread
  already independently confirmed overflowing under the same load) points more toward
  a genuine CPU/SoC-level hard hang than a known Mesa or generic-RCU software bug — but
  without the frozen CPU's own backtrace, this remains circumstantial, not proven.

## 3. Is `RCU_CPU_STALL_TIMEOUT` tuning a real lever or a red herring?

Red herring for root-causing this, confirmed by the mechanics above and by the
recovered trace: the RCU stall message is only the *first symptom to become visible* in
the log, printed by a *different, unaffected* CPU noticing CPU 5 hadn't reported in.
Changing the stall timeout only changes when the first alarm fires — it does not change
whether CPU 5 is frozen, does not prevent the subsequent NMI-based hard-lockup
detection, and does not affect the final panic/reset. It also does not help capture
more data: no extra information is logged that we don't already have from the NMI
sequence and the pstore-recovered backtrace. **Not worth spending a build round on.**

## 4. Recommendation, prioritized

1. **Try `CONFIG_ARM64_PSEUDO_NMI=y` as a single low-risk trial, boot-arg gated
   (not default-on).** This is the only lever in the whole investigation that could
   plausibly hand us a *real* backtrace of the actually-frozen CPU on the next crash,
   it's in-tree (no out-of-tree patch to carry), costs no `boot`-partition space beyond
   a Kconfig bit, and is empirically self-answering in one boot (`dmesg | grep -i
   pseudo-nmi`). If firmware doesn't allow it (`SCR_EL3.FIQ` not set by TZ), it fails
   safe — the kernel logs a fallback and keeps using the buddy detector, no regression.
   Concretely: add `CONFIG_ARM64_PSEUDO_NMI=y` and `CONFIG_HARDLOCKUP_DETECTOR_PERF=y`
   to the fragment, and add `irqchip.gicv3_pseudo_nmi=1` only as a one-off kernel
   command-line addition (via TWRP/whatever the project uses to set bootargs) for a
   deliberate reproduction session — not baked permanently into the DTB — so normal
   daily use never pays the ~5% tax.
2. **If pseudo-NMI reports enabled successfully**, deliberately reproduce the crash
   once (Minecraft, same as before) specifically to capture a *real* CPU-5 backtrace
   via `HARDLOCKUP_DETECTOR_PERF` + the existing pstore/`mmap()` recovery pipeline
   already built and validated this session. That backtrace is the single piece of
   evidence that would actually distinguish "GPU/DPU-driver-induced RT starvation
   masquerading as a freeze" from "genuine SoC/firmware-level hard hang" — everything
   else in this report is inference without it.
3. **If pseudo-NMI does NOT enable** (firmware doesn't permit it), stop chasing a true
   hardware backtrace — the SDEI and Qualcomm-watchdog-NMI approaches are both
   out-of-tree, unmerged, and *also* gated on the same firmware capability class we'd
   have just found missing, so they're not a fallback, they're the same dead end with
   more patch-carrying cost. At that point, this is the right moment to **document the
   crash as a known limitation** (real, reproducible, mitigated-but-not-eliminated by
   the DPU queue-size fix, root cause unconfirmed) in `docs/kernel-boot-debugging.md`
   and `plans/roadmap.md`, and move on to the already-queued work (finish the module
   tree deployment, resume audio bring-up). Given the DPU overflow fix already reduced
   frequency/changed the failure signature once, it's plausible normal use is already
   meaningfully more stable than before this round's fixes even without a full root
   cause.
4. **Do not spend a round on `RCU_CPU_STALL_TIMEOUT` tuning** — confirmed above as not
   actionable for this specific failure mode.

Sources consulted: Ratatoskr-mirrored LKML/linux-arm-msm/kexec threads on the pending
SDEI cross-CPU NMI series and the Qualcomm watchdog NMI series (2026 v2–v6 revisions),
the current `HARDLOCKUP_DETECTOR_PERF`/pseudo-NMI performance-tradeoff discussion, the
original ARM64 pseudo-NMI v8 series (prerequisites: GICv3 + `SCR_EL3.FIQ=1` or single
security state), kernel.org `Documentation/RCU/stallwarn.txt`, Red Hat/SUSE KB articles
on RCU-stall-preceding-hard-lockup patterns, and Mesa's Freedreno hang-debugging docs.
