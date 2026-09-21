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
