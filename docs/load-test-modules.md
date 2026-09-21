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

- (pending - modules smoke-tested for 10-15s each successfully on real
  hardware 2026-09-21; full-duration runs not yet performed)
