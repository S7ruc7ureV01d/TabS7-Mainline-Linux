# Load-test modules for the heavy-load freeze investigation (2026-09-21)

Follow-up to the unresolved freeze documented in `docs/kernel-boot-debugging.md`
("Crash #4 (round91, pseudo-NMI active)") and `docs/crash-investigation-nmi-research.md`.
All prior reproductions used Minecraft specifically, which conflates JVM/GC CPU
load with Freedreno/DPU GPU load and gives no control over *when* the two
happen relative to each other. The owner also reports the freeze consistently
lands right at the world-loading -> gameplay transition, not at an arbitrary
point during sustained play - a detail the Minecraft-only repro can't isolate.

Three separate modules, all in `tools/loadtest/`, deployed to `/root/loadtest/`
on the device:

- **`cpu_load.sh [seconds]`** - `stress-ng --cpu $(nproc) --cpu-method all`,
  zero GPU/display work. Isolates whether pure CPU saturation (independent of
  any DPU/GPU commit traffic) can trigger the freeze on its own.
- **`gpu_load.sh [seconds]`** - `glmark2-wayland --run-forever --fullscreen`,
  run as the real desktop user (`gts7l`, uid 1001) against the actual running
  KWin Wayland session (`wayland-0`), so it goes through the same
  DPU/Freedreno (FD650) path Minecraft uses, with minimal CPU load of its own.
  Isolates whether sustained GPU/DPU traffic alone is sufficient.
- **`burst_transition.sh [cycles] [idle_s] [burst_s]`** - alternates an idle
  period with a *simultaneous* sudden-onset CPU+GPU burst, repeated. Targets
  the specific loading -> gameplay transition report: a sharp combined edge
  after a lighter period, rather than N minutes on a sustained plateau.
  Default: 20 cycles x (15s idle + 20s burst) ~= 12 minutes total, matching
  the known Minecraft reproduction window from the Bug 2 writeup.

All three source `common.sh`, which:
- writes a 0.5s-resolution heartbeat to `/root/loadtest/heartbeat.log` (plain
  `date +%s.%N`, fsync'd by virtue of small appends) so that after a *total*
  freeze with no pstore trace at all (the Crash #4 outcome), we still have a
  precise last-alive timestamp to correlate against anything that *did* get
  captured;
- logs phase transitions (`start`/`BURST START`/`BURST END`/`completed`) to
  `/root/loadtest/session.log`.

`tools/loadtest/monitor_from_host.sh [host] [key]` runs on the **host** during
a test and polls `ssh ... true` once a second, printing `OK`/`UNREACHABLE`
with a timestamp. This replaces trying to live-follow `journalctl -k -f` over
the debug link, which `docs/dev-environment-quickref.md` already documents as
unreliable for catching a real crash live (the TCP session can go silently
stale exactly when the device dies, with no FIN/RST).

## Procedure

1. Confirm physical presence at the device before starting anything past a
   short smoke test - the worst-case outcome (Crash #4) needs a manual
   10-15s power-button hold to recover; SSH dies along with everything else.
2. Start `monitor_from_host.sh` on the host first.
3. Run one module at a time on the device (`ssh ... 'nohup /root/loadtest/X.sh
   N >/root/loadtest/run.out 2>&1 &'` so an SSH drop doesn't kill the test).
4. On a freeze: note the wall-clock time the host monitor's `OK` lines stop,
   power-cycle, then run the existing pstore recovery recipe
   (`docs/dev-environment-quickref.md`, "Crash forensics: pstore/ramoops")
   and diff its timestamp against `heartbeat.log`'s/`session.log`'s last
   lines (survives in `/root/loadtest/` only if `/data` itself wasn't what
   froze - otherwise these logs are lost too, which is itself a data point).
5. Record the outcome of each module (survived full duration vs. froze, and
   if froze: at what point - during a specific glmark2 scene, during a
   specific stress-ng method, during idle-to-burst transition N) back into
   `docs/kernel-boot-debugging.md` and update `plans/roadmap.md`.

## Results log

**2026-09-21, all three full-duration runs, in sequence, same boot
(`root@172.16.42.1` uptime continuous ~34min -> ~1h03m across all three -
no reboot happened between runs):**

- `gpu_load.sh 900` (01:47:33-02:02:35 UTC): **survived clean.**
  `glmark2-wayland --run-forever --fullscreen` through the real
  KWin/Freedreno (FD650) path, 90-1300+ FPS depending on scene (i.e. well
  past display refresh, so a genuinely high sustained DPU commit rate) -
  zero reachability gaps for the full 15 minutes.
- `cpu_load.sh 900` (02:03:02-02:18:02 UTC): **survived clean.** All 8
  cores pinned via `stress-ng --cpu-method all`, zero GPU/display work,
  load average up to ~8.8 - zero reachability gaps for the full 15
  minutes.
- `burst_transition.sh` (20 cycles x 15s idle + 20s simultaneous CPU+GPU
  burst, 02:18:28-02:30:49 UTC, ~12min): **survived clean, all 20
  cycles.** Zero reachability gaps.

**None of the three synthetic modules reproduced the freeze**, despite the
GPU module in particular exceeding Minecraft's real GPU commit rate and the
burst module specifically targeting a sudden simultaneous CPU+GPU edge
after idle (the closest analog this project has to the loading -> gameplay
transition). Minecraft itself reliably triggers the freeze within
1-12 minutes (see `docs/kernel-boot-debugging.md`).

**Interpretation:** raw CPU saturation, raw GPU/DPU throughput, and a sharp
simultaneous CPU+GPU *amplitude* spike are each, individually and combined,
insufficient. What none of these synthetic tools reproduce is Minecraft/
JVM's actual behavior at that specific moment: heavy GC pressure together
with rapid GL *object churn* - creating and destroying large numbers of
VBOs/textures for newly-generated chunk meshes, not just resubmitting draws
against scenes that already exist (glmark2's steady-state model) or doing
generic ALU/cache/memory-bandwidth work with no allocator interaction
(stress-ng's model). That points the next round of synthetic reproduction
at allocator/driver-object-lifecycle pressure specifically - e.g.
`stress-ng --vm`/`--bigheap`/`--mmapfork` for JVM-GC-like memory churn,
combined with a GL workload that actually creates/destroys buffer objects
per frame rather than reusing a fixed scene - rather than at more raw
throughput on either axis, which this round has now ruled out.

Also worth noting given the pasted note at the start of this session's
handoff: this device is currently flashed with the pseudo-NMI trial kernel
(`irqchip.gicv3_pseudo_nmi=1` still in `/proc/cmdline` as of this test
round) - per the recommendation in `docs/kernel-boot-debugging.md`
("Crash #4"), this should be reverted once the freeze investigation is
considered closed, since it costs ~5% steady-state and didn't end up
answering the deeper freeze question.

## `capture_watch.py`: first real lead-up visibility, but inconclusive (2026-09-21)

Built `tools/loadtest/capture_watch.py` specifically because pstore's
dead-simple memcpy() into a tiny reserved DRAM region had captured
nothing useful across four independent real freezes. This instead
samples per-core CPU% (from `/proc/stat`, ~0.3s cadence) plus a heavier
top-processes/dmesg snapshot (~2s cadence) to a plain file on the real
`/data`-backed rootfs, `fsync()`'d after every sample - doesn't need the
crash to trigger anything, just needs to stay a fraction of a second
ahead of it.

**It worked, in the sense that it survived**: the log runs continuously
right up to `04:49:22` (device-local, matches the host monitor's
last-alive SSH check `2026-09-21T01:49:21-03:00` almost to the second) -
our own capture script died at the same instant everything else did, six
seconds of real lead-up finally recovered from a real crash.

**What it shows is more ambiguous than hoped**, though. This session's
new "one CPU core pegs to 100% right before the crash" observation (via
KDE's CPU monitor widget) is real in the data - `cpu7` sits at 96-100%
across every single sample in the visible window - but the concurrent
top-processes snapshots show `java` at 215-224% CPU (multiple threads),
not any specific kernel worker or GPU-related task by name. This is
consistent with Minecraft's own render thread being legitimately
CPU-bound under heavy load, not obviously a kernel-side busy-wait bug -
the visual "100% core" signal may just be normal intensive gameplay, not
direct evidence of the suspected GMU/HFI poll-loop theory. **Don't
over-read this single data point** - it neither confirms nor rules out
that theory, since a kernel-side busy loop competing for the same core
would look similar from this vantage point alone (per-core %, not a
per-thread breakdown of *why* a thread is running).

**Separately informative**: zero new `dmesg` lines appear anywhere in
the final 6 seconds - no hung-task warning (despite `hung_task_timeout_
secs=5`, deliberately lowered from the 120s default specifically so it
would have time to fire), no softlockup warning, nothing. Whatever
happens, happens with no visible gradual buildup even at 0.3s
resolution - looks abrupt, not a slowly-worsening cascade. This leans
(weakly - one sample) back toward something below where even a 5-second
hung-task check gets a chance to run, rather than confirming the
software-deadlock theory.

Full captured log for this crash: available in this project's scratch
area; not committed to the repo (large, single-crash-specific raw data,
not a durable artifact - the summary above is what's durable).

## Self-inflicted crash from `capture_watch.py` itself (2026-09-21) - false lead, now fixed

After adding a DPU-side debugfs read (`/sys/kernel/debug/dri/0/crtc-0/
state`) to `capture_watch.py` per the owner's "think about what other
low-level debug we can add" request, the very next test run crashed
within seconds - **before Minecraft was even launched**, on an otherwise
idle desktop. Traced directly, not guessed: `capture_watch.log` showed
84 occurrences of a real kernel `WARN_ON` (`dpu_crtc_debugfs_state_show`,
`drivers/gpu/drm/msm/disp/dpu1/dpu_crtc.c:627`, `CPU#N: python3/<our
own pid>`) in an 820-line log, starting at line 22 - i.e. within the
first second of the script reading that file. Reading this specific
debugfs file apparently violates a locking precondition the driver
assumes is only ever true when the real DRM/KMS subsystem calls it
internally, not when read raw from an unrelated process - it produces a
genuine ~30-40 line stack-trace printk burst *every single read*, at our
0.3s cadence. That's a real printk storm (2500+ log lines in well under
a minute), which tainted the kernel (`Tainted: G W`) and very likely
caused (or heavily contributed to) this specific crash on its own -
**this crash is a false lead for the actual freeze investigation, not a
Minecraft repro, and should be discarded from that data set.**

Also notable: pstore's own recovery this time reported an even more
garbled header than usual (`found existing invalid buffer, size
4452340` - larger than the entire 1MB region itself), plausibly because
the printk storm itself corrupted the ring buffer's header worse than a
typical crash does.

**Fixed**: `read_dpu_crtc_state()` disabled (returns a placeholder
string instead of reading the file) - do not re-enable without first
understanding/fixing whatever locking precondition `dpu_crtc.c:627`
assumes. Rest of `capture_watch.py` (GPU ring bounded read, IRQ deltas,
per-thread breakdown, meminfo, per-core CPU%) was already confirmed
clean across two earlier idle-desktop smoke tests before this addition
- no reason to distrust those parts.

## Real, non-self-inflicted evidence at last: repeated GPU fault/recover cascade (2026-09-21)

With the DPU-read bug fixed, re-ran the real Minecraft repro. Crashed
again, but this time `capture_watch.log` (zero self-inflicted WARN
occurrences, confirmed) captured real, substantive lead-up - the
clearest evidence this investigation has produced.

**A rapid-fire sequence of genuine GPU fault -> recovery cycles, roughly
every ~2.2 seconds, right as Minecraft's JVM was loading**, each
independently confirmed via kmsg lines drained live:

```
05:06:30 - [drm:a6xx_irq] gpu fault ... -> hangcheck recover! (offending: kwin_wayland) -> recovered, rptr/wptr resynced
05:06:32 - [drm:a6xx_irq] gpu fault ... -> hangcheck recover! (offending: plasmashell)  -> recovered
05:06:32 - [drm:a6xx_irq] gpu fault ... -> hangcheck recover! (offending: plasmashell)  -> recovered (second one in the same ~2s window)
05:06:34 - [drm:a6xx_irq] gpu fault ... -> hangcheck recover! (offending: plasmashell)  -> recovered
```

Every one of these **succeeded** - fence counters climbed monotonically
each time, `rptr`/`wptr` resynced after each recovery. This is exactly
the "recovery usually works, but it's a race" pattern the S9 Ultra
project's own diagnosis needs - a single fault recovering cleanly proves
nothing either way, but a *cascade* of several in quick succession,
under rising load, is exactly the condition that would eventually hit
the unlucky timing window.

**Concurrently, real resource pressure was building fast**: `MemFree`
dropped from ~2.9GB to ~1.08GB in under 10 seconds (JVM asset
loading/JIT compilation, `Client thread`/`C2 CompilerThread` visible in
the per-thread breakdown), and CPU load climbed across *multiple* cores
simultaneously in the final samples (not just one - refines the earlier
single-core observation; this run showed several cores at 90-100% at
once, more consistent with genuine multi-threaded load than a lone
spinning core).

**Then the log stops mid-cascade** at `05:06:35`, matching the host
monitor's last-alive reading almost exactly. No 5th fault message
visible, no final failed-recovery attempt caught on camera, so to
speak - **important caveat**: kmsg draining only happens on the ~2s
heavy cadence, and the faults were arriving on almost exactly that same
cadence. It's plausible a 5th fault started logging and was never
drained before the freeze, rather than printk itself failing. Next
tuning step: drain kmsg every light cycle (~0.3s, still cheap - it's a
non-blocking read) instead of only every heavy cycle, specifically to
try to catch the actual final fault/recovery-failure message rather
than inferring it from where the log stops.

## Real Minecraft repro, same session (2026-09-21)

Since all three synthetic modules survived, ran the actual Minecraft repro
one more time with `watch_minecraft.sh` (heartbeat-only logging, no
synthetic load) plus the host-side monitor running, specifically to get a
precise, corroborated timestamp and to check pstore while the pseudo-NMI
detector was confirmed active and pstore was confirmed empty beforehand.

**Froze again, quickly** (~61s after starting the watch script/launching
Minecraft). Last-alive timestamp confirmed two independent ways within a
second of each other:
- Host monitor (`monitor_from_host.sh`): last `OK` at `2026-09-20T23:35:26
  -03:00`, first `UNREACHABLE` one second later.
- On-device heartbeat log (survived the reset - `/root/loadtest/` is on
  persistent storage): last line `1789958126.458` = `2026-09-21T02:35:26.458
  UTC` - the same moment, converted.

**Pstore result: nothing captured, again** - same outcome as "Crash #4" in
`docs/kernel-boot-debugging.md`, not the earlier softer RCU-stall/NMI-panic
mode from Bugs 1/2. `dmesg`/`console-ramoops-0` after reboot showed only
(a) this fresh boot's own early console output (had already overwritten
the start of the 1MB ring buffer within its first ~41s at `loglevel=15`)
and (b) old stale stock-Android HIDL/battery-monitor fragments at the tail
- the same "leftover from an old stock boot" gotcha documented for Crash
#4. A full raw `mmap()` recovery (`docs/dev-environment-quickref.md`
recipe) and a `strings` search for `panic|NMI|lockup|watchdog|RCU stall`
across the entire 1MB region came up completely empty. Pseudo-NMI was
confirmed active this whole time (`GICv3: Pseudo-NMIs enabled` present at
this boot's own start, and confirmed working in the original Crash #4
round) - **the freeze is, again, happening at a level the NMI-capable
hardlockup detector never gets to fire at all**, consistent with Crash
#4's own conclusion (something lower than a schedulable-CPU hard lockup -
bus/memory-controller livelock, a stuck SMC/EL3 trap, or similar) rather
than contradicting it. Two independent real Minecraft freezes now show
this same "nothing fires, nothing captured" signature; this looks like the
freeze's normal/default behavior at this point, not a one-off.

Also: booting into TWRP after a manual power-cycle recovery (as happened
partway through this session) was **deliberate this time**, not an
automatic side-effect of the crash/reset path - don't read anything into
it. `androidboot.boot_recovery=1` was seen once but the user confirmed
they navigated there on purpose; worth re-checking if it ever happens
*without* the user doing so on purpose, since `param` being pinned to
force-recovery was a real, separate historical issue in this project
(Phase 1 Round 7/13) - not reopened here, just flagged as a thing to watch.

## Candidate fix #1 tested and ruled out: `CONFIG_QCOM_ICC_BWMON` (2026-09-21)

Research (two parallel forks: a local downstream-vs-mainline source diff,
and an upstream mailing-list/bug-report search) converged on
`CONFIG_QCOM_ICC_BWMON` being left at defconfig's `=m` and never loaded -
the same bug class as the already-fixed `CONFIG_INTERCONNECT_QCOM_OSM_L3`
(Bug 1), but on the DDR-bandwidth-monitoring side. Forced `=y` in
`kernel/config/gts7l.fragment`, rebuilt, flashed (`boot` only, RP/
bootloader confirmed unchanged before/after, readback-verified) - full
build/flash log in the `904b8ee` commit.

**Confirmed live on real hardware before retesting**: `9091000.pmu` bound
to the `qcom-bwmon` driver (`/sys/bus/platform/devices/9091000.pmu/driver`
symlink present), and `/sys/kernel/debug/interconnect/interconnect_summary`
showed it actively casting a real ~3GB/s peak bandwidth vote on both the
`llcc_mc@163d000`/`ebi@163d000` DDR paths - previously completely absent.
The fix itself works exactly as intended.

**Retested with real Minecraft anyway: froze again**, even faster than
before (~30-47s from launch to freeze, at the same world-loading ->
gameplay transition). Same total-silence signature: host monitor lost
reachability abruptly (last-alive `2026-09-21T00:08:57-03:00`), pstore's
own driver rejected a torn buffer again (`found existing invalid buffer,
size 148840, start 148841`), and a full raw `mmap()` recovery + `strings`
search for `panic|NMI|lockup|watchdog|RCU stall|bwmon|BUG` across the
entire 1MB region again found nothing from this kernel's own crash - only
stale leftover fragments.

**Conclusion: Candidate #1 is ruled out as the (sole) cause.** The fix is
real and worth keeping (adaptive DDR bandwidth scaling that previously
never ran at all is a genuine improvement), but it does not explain this
freeze. Whatever's happening is not "DDR bandwidth scaling never engages
under combined load" on its own. Next candidates from the same research,
not yet tried: the GPU's own missing bus-bandwidth OPP table/`interconnects`
property (a mainline-wide gap, not gts7l-specific, so lower prior but
stacks with #1), the SMMU stall-on-fault race (matches the GL-object-churn
theory better - a mishandled page fault under heavy alloc/free could hang
indefinitely rather than fault-and-recover), or the zap-shader/zap-region
devicetree carveout (a documented historical cause of literal whole-system
freezes, not just GPU hangs, on this exact SoC family during early SM8250
mainline bring-up).

## Retest with 0.3s kmsg draining: sharper picture, still not conclusive (2026-09-21)

Re-ran with kmsg now drained every light cycle instead of only the ~2s
heavy tier. Crashed again (last-alive `2026-09-21T02:13:44-03:00`). Same
recoverable-fault pattern repeated three times (05:13:31/05:13:36/
05:13:40 - fault, hangcheck recover!, offending task: plasmashell, clean
resync each time, roughly every 4-5s this run). Then:

- `05:13:45`: `prismlauncher` (the Minecraft launcher) appears in
  top-procs for the first time.
- Same instant: the `gpu-irq` delta **spikes to 295**, versus a 20-85
  baseline in every prior window this run (and the run before it) - a
  3-15x jump.
- **No `hangcheck recover!` (or any fault message at all) accompanies
  this spike** - the kmsg drain at that exact moment shows only a
  harmless cgroups line.
- Log stops immediately after, matching the host monitor's last-alive
  reading almost exactly.

Two readings, can't fully distinguish from this data alone: (1) recovery
itself got stuck this time (matches the deadlock theory - `recover_worker`
started, took `gpu->lock`, never got far enough to print anything), or
(2) whatever happened this time was fast enough that even a 0.3s-cadence
non-blocking kmsg read never got another turn before the freeze. Either
way: a burst of GPU interrupt activity coinciding with the app launch,
immediately followed by total death, with no clean fault-and-recover
message this time - a real escalation pattern, not proof of the specific
deadlock mechanism yet.

## 50ms sampling retest: final recovery shows an unresynced ring (2026-09-21)

Sped `capture_watch.py` up to 50ms sampling (benchmarked headroom: ~1.6ms
of actual work per light cycle against the old 300ms interval) with
millisecond timestamps. Crashed again. Same repeated fault/recover
pattern (multiple clean cycles, `rptr`==`wptr` resync each time), but
**the final recovery attempt this run showed `rptr=1068`, `rb wptr:
1417`** - a real, unresolved gap, unlike every prior successful recovery
in any capture so far, where they matched exactly right after the
recovery message printed. Immediately before this, `gpu-irq` delta hit
**738** in one window - the largest spike yet. CPU saturation then
spread across *multiple* cores simultaneously (not one), `MemFree`
dropped ~200MB in the final 400ms, and the log stopped cold, matching
the host monitor's last-alive reading almost exactly. Converging
evidence across three real crashes now: elevated GPU IRQ activity right
before death, escalating multi-core saturation, fast memory drop, then
silence - and this time, direct evidence the final recovery attempt
didn't finish resyncing before everything died.

## Fix attempt: bounded `fault_coredump_done` wait (`kernel/patches/0006-...`) - changed the signature, not proven to have fixed it (2026-09-21)

Applied the S9 Ultra project's bounded-wait fix (see the patch file for
full reasoning) to `a6xx_gmu.c`/`a6xx_hfi.c`, built, flashed (kernel
`#70`). Retested.

**Froze again - before Minecraft was even launched this time** (the
owner saw "a bunch of kwin desktop effects restart" messages, i.e.
several GPU-reset recoveries during idle desktop use, then a full
freeze). `capture_watch.log` survived and shows something genuinely new:

- Same repeated fault/recover pattern (8 cycles this run, matching the
  owner's "a bunch of these" observation), each showing `hangcheck
  recover!` + an offending task. The **final** one again shows an
  unresynced ring (`rptr: 5181`, `rb wptr: 5647`), same as the previous
  run's final attempt.
- Then, for the first time, **`cpu0` pins at exactly 100.0% and stays
  there, unchanging, for over 1.5 continuous seconds** (30+ consecutive
  50ms samples) while every other core drops to near-idle - direct,
  sustained evidence of a single-core spin, never captured this clearly
  before.
- **The patch's own new error path
  (`DRM_DEV_ERROR("Timeout waiting for GMU OOB...")`) never fired**,
  despite `cpu0` being stuck long enough for 30+ kmsg-drain opportunities
  (kmsg draining runs on whatever core the scheduler puts our script on,
  which kept working fine on other cores throughout the pin - confirmed
  by the log itself continuing to write for the full 1.5s). This means
  we do **not** have direct proof the code we patched is what's
  actually spinning - either a different, unbounded loop is the real
  culprit, or something downstream of our new timeout return doesn't
  handle the failure gracefully and spins somewhere else instead.
- Notable: the host monitor's SSH check went unreachable ~2-3 seconds
  *before* our own on-device script finally stopped writing - networking
  died first, general scheduling failed later. Consistent with `cpu0`'s
  spin gradually starving the rest of the system rather than an instant,
  uniform freeze.

**Conclusion: the fix changed the failure's observable signature (a
sustained, capturable single-core spin instead of instant silent death)
but is not confirmed to have addressed the actual root cause** - we
don't know yet whether the spin is inside the code we bounded or
somewhere else entirely. A real gap surfaced: the heavy-cycle process
snapshot only runs every ~2s and the next one never fired before the
system died, so we have no thread-level attribution for what's actually
running on `cpu0` during the pin. Next step, not yet implemented: an
adaptive trigger that takes an immediate heavy sample the moment any
core exceeds ~95% for a couple of consecutive light samples, instead of
waiting for the fixed cadence - specifically to catch which thread is on
the pinned core.

## Major pivot: the GPU deadlock theory was very likely a red herring - `storage_load.sh` (2026-09-21)

The owner ran a plain `dd if=/dev/zero ... bs=1G count=10 conv=fdatasync`
against `~/Documents` by hand, completely unrelated to the GPU/Minecraft
investigation - **and the device froze immediately.** Wrapped it as
`tools/loadtest/storage_load.sh` (same invocation, on `/root/loadtest/`)
and reproduced it with full logging in under 10 seconds - by far the
fastest, cleanest repro of the entire investigation, a huge improvement
over booting Minecraft every time.

`capture_watch.log` shows exactly what happens, and it has nothing to do
with the GPU:

- A routine GPU hangcheck/recover cycle appears in the log, but
  **before** the storage test even started (confirmed against
  `session.log`'s start marker) - direct proof these cycles are just
  constant background noise on this hardware, unrelated to whatever
  workload happens to be running, not a symptom of it.
- Once the `dd` starts, `MemFree` collapses from ~2.7GB to ~1GB in under
  a second (real dirty-page/writeback pressure from the 10GB write).
- **`cpu7` pins at exactly 100% and stays there, unchanging, for over
  2.5 continuous seconds** (50+ consecutive 50ms samples) while every
  other core sits near-idle.
- The heavy-cycle process breakdown catches the actual culprit directly,
  twice: **`kworker/7:2+events` (a generic per-CPU workqueue worker
  pinned to CPU 7 - that's what the `kworker/7:` name means) consuming
  219 ticks in one single ~2s window** - essentially the entire core.
- **The GPU itself is verified idle and healthy throughout**: the `gpu
  ring` read during this exact window shows `rptr=68 wptr=68` (fully
  drained, matching exactly) and `gpu irq delta: 0`.
- `jbd2/sda37-8` (the root filesystem's own journaling thread) and
  `kworker/0:1H-kblockd` (block-layer workqueue) both appear in the same
  window with minimal ticks - present in the picture, not the ones stuck.

**This strongly suggests the GPU fault/recover cascade chased through
most of this investigation was a correlated symptom, not the root
cause** - Minecraft's heavy asset loading generates real memory/storage
pressure as a side effect of loading, which is probably what was
actually triggering the freeze the whole time, with the GPU hangcheck
messages just being incidental background activity that happened to be
visible in captures taken during real usage. The `CONFIG_QCOM_ICC_BWMON`
fix and the `fault_coredump_done` bounded-wait fix (`kernel/patches/
0006-...`) are both still worth keeping, but neither should be expected
to fix this - the real target is now a stuck generic workqueue worker
under memory/writeback pressure, not anything GPU-specific.

Added a stuck-core kernel-stack capture to `capture_watch.py` (the
moment any core is >=95% busy for 4 consecutive light samples, snapshot
exactly which thread is `RUNNING` there via a live `/proc` scan and dump
its real kernel stack from `/proc/<pid>/task/<tid>/stack`) - not yet
exercised on a real crash, since this improvement landed after this
particular repro already completed. Next test should show the exact
kernel function `kworker/7:2+events` (or whichever worker/core is
implicated next time) is actually stuck in.

## Root cause found: a real spinlock stuck in ext4's delayed-allocation write path (2026-09-21)

The stuck-core detector fired on a retest (threshold lowered to 2
samples after a near-miss), but `/proc/<pid>/task/<tid>/stack` came back
useless - a single non-symbol garbage value. Root cause of *that*: this
file is only reliable for a *sleeping* task; a task that's genuinely
`RUNNING` right now has no saved stack to unwind. Switched the detector
to trigger sysrq's cross-CPU NMI backtrace instead (`echo l >
/proc/sysrq-trigger`, `arch_trigger_cpumask_backtrace`) - this
interrupts every CPU via NMI and has each one dump its own real, live
call trace, which does work for a running task. Also had to enable
`sysrq=1` (this device's default, `16`/`0x10`, is missing the bit this
trigger needs) - now done automatically at script start.

Retested. **Got a complete, symbolized kernel stack trace of the actual
stuck core (CPU 6, PID 12299 `dd`):**

```
_raw_spin_lock+0x2c/0x68        <- actively spinning here
ext4_da_reserve_space+0x4c/0xbc
ext4_da_get_block_prep+0x228/0x5b0
ext4_block_write_begin+0x260/0x5bc
ext4_da_write_begin+0x23c/0x314
generic_perform_write+0xac/0x250
ext4_buffered_write_iter+0x130/0x1c0
ext4_file_write_iter+0x70/0x6a0
vfs_write+0x288/0x444
ksys_write+0x78/0xec
__arm64_sys_write
```

**This is the real root cause, and it has nothing to do with the GPU.**
`dd`'s plain `write()` syscall enters ext4's delayed-allocation path and
gets stuck forever spinning on a spinlock inside
`ext4_da_reserve_space()` - the function that reserves blocks and
updates free-space/reservation accounting for a delayed-allocation
write. A real ext4 filesystem-level lock, not a GPU driver deadlock, not
a scheduler issue, not memory pressure by itself (though heavy
writeback pressure is almost certainly what exposes the race).

The other CPUs captured in the same NMI sweep (0, 1, 3) show completely
ordinary in-flight syscalls (an `open()` path lookup, a page fault,
plain userspace execution) - normal activity that happened to be
running at that instant, not evidence of being stuck themselves. Only
`dd` on CPU 6 is actually spinning on a lock; the freeze presumably
cascades from there as every other thread needing filesystem I/O on the
same superblock eventually piles up behind the same contended
accounting path.

**Reframes the whole investigation**: the GPU fault/recover cascade
chased through most of this session was unrelated background noise.
Minecraft triggers this bug because loading a world generates real,
heavy disk I/O (save files, asset caches) - enough to hit the same ext4
locking pathology - not because of anything GPU-specific. The
`CONFIG_QCOM_ICC_BWMON` and `fault_coredump_done` fixes are both still
worth keeping on their own merits, but neither was ever going to fix
this.

**Next step, not yet tried**: mounting with `nodelalloc` (disables ext4
delayed allocation entirely) as both a diagnostic and a possible
mitigation - if that avoids the freeze, it strongly confirms this
exact code path as the cause. Also worth checking this kernel's exact
`ext4_da_reserve_space()` source and superblock-level reservation lock
for a known upstream bug/fix, now that the exact function is known
rather than guessed at.

## `nodelalloc` does not fix it - and a pure-memory trigger reveals a second, different failure signature (2026-09-21)

Testing `nodelalloc` as a mitigation turned into its own investigation.
`rootflags=nodelalloc` on the kernel cmdline, and separately
`nodelalloc` in `/etc/fstab`, both proved unable to actually take effect
on the *root* filesystem in this boot setup: whatever performs the
first real mount of `/dev/sda37` (well before `systemd-fstab-generator`'s
own unit ever runs) already has delalloc enabled, and ext4 hard-refuses
to disable it via any later remount ("can't disable delalloc during
remount") - confirmed directly via `/sys/fs/ext4/sda37/
delayed_allocation_blocks` staying nonzero and climbing on new writes
regardless of what the cmdline/fstab said.

A genuinely isolated test needed a filesystem that was never mounted
with delalloc in the first place - a loop-mounted image turned out not
to qualify either (the backing file still lives on root, so the loop
device's writes still flow through root's own delalloc/writeback path
to persist that file). **`tmpfs` (pure RAM, and this device has zero
swap configured, so genuinely no path to real storage at all) was the
only truly clean test - and it still froze**, running the exact same
`dd ... conv=fdatasync` workload with nothing touching a real block
device or ext4 at all.

**This means the ext4 spinlock captured earlier is very likely not the
root cause - it's a plausible secondary victim.** A separate,
completely storage-free trigger confirms this further: the owner found
that `stress-ng --vm 1 --vm-bytes 3G --vm-keep` (pure memory allocation
and access, zero filesystem I/O whatsoever) also reliably freezes the
device. Retested with full instrumentation (stuck-core detector +
sysrq NMI backtrace) running, and it froze again in seconds.

**The resulting NMI backtrace shows something qualitatively different
from the ext4 case.** `stress-ng-vm` (the pinned core) was not stuck in
any kernel function at all - its captured PC was a plain userspace
address, meaning it was simply, validly executing its own memory-touching
loop, using CPU normally. Every other core was idling normally via the
standard `cpu_suspend`/`do_idle` path - nothing anywhere in this
snapshot looks wrong. **Then, immediately after that snapshot, every
core drops to 0% simultaneously and the log goes completely silent** -
no thread visibly spinning on anything, just a sudden, uniform stop
across the whole system with nothing left running even to produce
another log line. No OOM-killer activity in dmesg either - memory
pressure was real (`MemFree` down to ~1GB) but never exhausted or
`OutOfMemory`-triggering.

**Interpretation**: this pure-memory trigger's signature (nothing
software-visibly stuck, a sudden uniform stop) looks much more like the
original hardware/bus/interconnect-level hypothesis from early in this
investigation than like a software deadlock. A plausible unifying
theory: something about a rapid, large memory-allocation/access event
on this hardware (whether from a big single `write()`, a 3GB anonymous
allocation, or Minecraft's own asset loading) can trigger a genuine
hardware/firmware-level stall - and the ext4 spinlock captured earlier
may simply be a *downstream* victim, a thread that happened to be
waiting on a lock whose owner froze for the same underlying
hardware-level reason, not the actual root cause itself. This would
mean the freeze is not straightforwardly fixable from the Linux/driver
side at all - consistent with `docs/crash-investigation-nmi-research.md`'s
original conclusion, now revisited with much more evidence behind it.

Not yet tried: retesting `stress-ng --vm` at smaller/graduated memory
sizes to find a threshold, and checking whether a *slower* memory
allocation pattern (vs. `dd`'s single massive `bs=1G` write or
`stress-ng`'s abrupt 3G grab) avoids the freeze - which would help
narrow down whether it's really about total memory pressure, or
specifically about the *rate/burstiness* of a large allocation/access
event.

## The real root cause: a specific CPU stops responding even to an NMI (2026-09-21)

Ran a graduated `stress-ng --vm` series (512M, 1G, 1.5G, each 20s) to
find a size threshold. 512M and 1G both survived cleanly ("successful
run completed"). **1.46GB (`--vm-bytes 1500M`) froze it** - narrows the
threshold to somewhere between 1G and 1.46GB on this device (~5.3GB
total RAM, no swap). Both smaller steps also triggered the stuck-core
detector, but those were confirmed false positives (stress-ng
legitimately using a core for its own valid userspace work, same as
the earlier 3G test) - the real evidence is what happened during the
1.5G step, right before the freeze:

**`khugepaged` (the kernel's Transparent Huge Page background daemon,
PID 65) was caught by the hung-task detector, genuinely blocked for
over 5 seconds**, with a complete, real stack trace:

```
khugepaged -> lru_add_drain_all -> __lru_add_drain_all -> flush_work
  -> wait_for_completion -> schedule_timeout -> schedule -> __schedule
```

`khugepaged` periodically calls `lru_add_drain_all()`, which requires
*every* CPU to run a small per-CPU work item (draining that CPU's page
LRU cache) before it can return - it's blocked waiting for that to
complete everywhere.

**Then, in the same window, the sysrq NMI backtrace (triggered by the
stuck-core detector moments earlier) reported:**

```
After 10 seconds, these CPUs still haven't responded to the NMI: 6
```

**CPU 6 never responded - not even to an NMI.** A CPU spinning in a
software loop, even stuck on a spinlock, still answers an NMI (NMIs
preempt almost everything by design). Non-response to an NMI means
that core is genuinely unresponsive at the hardware/firmware level -
not busy, not looping, just gone.

**This is the same signature as "Crash #4"/"Crash #5" from
`docs/kernel-boot-debugging.md`, documented at the very start of this
whole freeze investigation, well before tonight's GPU/ext4 detours** -
back then it was CPU 5 that never answered an NMI; this time it's CPU
6. Different core, same underlying phenomenon. This directly explains
every trigger found across this entire investigation (Minecraft's
asset loading, `dd`'s page-cache pressure, `stress-ng --vm`'s
allocation, the ext4 spinlock, the earlier "sudden uniform stop"
signature): they're all different paths into cross-CPU synchronization
primitives (`lru_add_drain_all()` and similar, invoked by memory
reclaim/compaction under real pressure) - and any of them is enough to
expose that some specific core has *already* gone hardware-level
unresponsive, for a reason no kernel-side software fix can address.

**Conclusion: this is very likely below what this project's software
tools can diagnose further or fix.** The GPU deadlock and ext4 spinlock
found earlier were both real, but both downstream symptoms of the same
underlying hardware/firmware-level single-CPU lockup - not root causes
in their own right. Matches, and now substantially reinforces with a
second independent NMI-non-response capture, the original conclusion
in `docs/crash-investigation-nmi-research.md`.
