# Memory-pressure freeze investigation - 2026-09-21 session summary

Single reference for everything found in one long investigation session
into the hard-freeze bug under memory pressure. Written for a future
session to pick up from without re-deriving all of this. The full,
dated, moment-by-moment narrative (including false leads and
corrections) is in `docs/load-test-modules.md` and
`docs/kernel-boot-debugging.md` - this file is the consolidated,
skimmable version, with pointers to the raw evidence.

## The bug

Under sustained memory pressure with no (or insufficient) swap headroom,
the device hard-freezes: multiple CPUs simultaneously become completely
unresponsive - not busy-looping, but unreachable by cross-CPU IPIs *and*
by NMI-class delivery, including during the kernel's own last-resort
panic-shutdown sequence (`SMP: failed to stop secondary CPUs`).
Confirmed via the owner: stock Samsung Android and custom Android ROMs
on this exact hardware do **not** exhibit this under heavy load, so
it's a real, fixable mainline-vs-downstream difference, not a hardware
defect in this unit - even though several deep-dive results below are
consistent with the *mechanism* being below what Linux's own
configuration can fully control.

Primary repro:
```
stress-ng --vm 1 --vm-bytes 1500M --vm-keep --timeout 30s   # moderate pressure - FIXED, see below
stress-ng --vm 1 --vm-bytes 3G --vm-keep --timeout 30s      # real OOM pressure - UNRESOLVED, see below
```

## Status for a future session

- **Moderate-pressure case: fixed.** `kernel/patches/0008-disable-cluster-sleep-0-domain-idle-state.patch`
  genuinely stops the 1.46GB repro. Confirmed clean twice in a row with
  a host-side reachability monitor. Ship this.
- **Severe-pressure case (3GB, real OOM): unresolved.** Every specific
  mechanism tested individually was ruled out with direct evidence (see
  below). The pattern across five independent crash captures is one
  shared, system-wide stall observed through whichever watchdog catches
  it first - not several independent bugs. The most recent, cleanest
  trace (log 07 below) shows completely normal cpufreq/RPMh/interconnect
  activity right up to a sudden, silent, total stop with zero
  lead-up - consistent with something below Linux's own visibility
  (firmware or hardware), not a traceable software resource-exhaustion
  bug. Recommend shipping the confirmed fixes and infrastructure below,
  documenting this as a known residual risk, and revisiting only if it
  shows up under real (non-synthetic) usage.
- **Real, general improvements to keep regardless of the unresolved
  case:** zram swap (`CONFIG_ZRAM=y`, was completely absent before -
  standard on stock Android), much better crash forensics (panic-on-hang
  sysctls, uncompressed pstore, a wider ramoops console buffer, ftrace),
  and the GPU fault-recovery bounded-wait fix (`patch 0006`, predates
  this session, confirmed still applied and still correct).

## What's confirmed fixed

**`kernel/patches/0008-disable-cluster-sleep-0-domain-idle-state.patch`**
removes the `cluster_sleep_0` domain-idle-state from `sm8250.dtsi`'s
`cluster_pd` node. Downstream's own `lpm-levels.c` checks
`is_IPI_pending()` before letting the CPU cluster collapse into its
deepest shared idle state; mainline's generic cpuidle-psci governor has
no equivalent guard. An IPI arriving mid-collapse (e.g. from
`lru_add_drain_all()` under memory reclaim) could leave a CPU
permanently unresponsive. Removing the cluster-level collapse entirely
closes that specific race. Confirmed fixed the moderate-pressure repro
twice in a row.

## What's been ruled out, with direct evidence, for the severe case

Each of these was a real, testable hypothesis, individually eliminated:

| Hypothesis | Test | Result | Evidence |
|---|---|---|---|
| cpuidle/PSCI race (cluster level) | disabled `cluster_sleep_0` only | fixed the *moderate* case, not the severe one | - |
| cpuidle/PSCI race (per-CPU level too) | also disabled `little_cpu_sleep_0`/`big_cpu_sleep_0` (`patch 0009`, diagnostic) | still froze | log 03 - confirmed via NMI-skip messages showing plain `cpu_do_idle` (WFI), never `psci_cpu_suspend_enter` |
| `irqsoff` tracer self-amplification | control test: identical repro with tracer forced to `nop` | still froze, same severity | (not saved as a separate log - see `docs/load-test-modules.md`) |
| BPF-JIT/seccomp IPI hang (`kick_all_cpus_sync`) | disabled BPF JIT (`bpf_jit_enable=0`), avoided SSH-reconnect storms | still froze | (see `docs/load-test-modules.md`) |
| cpufreq/RPMh bandwidth-vote churn | forced `performance` governor on all 8 CPUs (no schedutil-driven votes) | still froze | log 04 |
| Total absence of swap | added `CONFIG_ZRAM=y`, 4GB active zram swap confirmed via `free -h` | still froze | log 05 |
| BWMON not requesting more bandwidth under load | read `drivers/soc/qcom/icc-bwmon.c` directly | the flat vote is *expected* behavior (`dev_pm_opp_set_opp()` only called on an actual OPP-tier change), not a bug | - |
| RPMh TCS-queue contention/exhaustion | enabled real `rpmh_send_msg`/`rpmh_tx_done`/`icc_set_bw` tracepoints, ran the repro with `capture_watch.py` off to avoid diluting the console buffer | no contention visible - normal traffic right up to a sudden, total, untraceable stop | log 07 (cleanest capture of the whole session) |

## The "different victim every time" pattern

Five independent crash captures each showed a *different* subsystem as
"the blocked task" when caught by whichever watchdog fired first:

1. **PSCI `cpu_suspend`** - multiple idle-task NMI backtraces caught
   literally inside the `CPU_SUSPEND` firmware call (log 02, before
   per-CPU idle was also disabled).
2. **RPMh completion timeout** - `sugov_work` → `qcom_cpufreq_hw` →
   `icc_set_bw` → `rpmh_write_batch`, then `Error sending RPMH requests
   (-110)` (`-ETIMEDOUT`, `RPMH_TIMEOUT_MS` is 10s,
   `drivers/soc/qcom/rpmh.c:25`) - found in the same capture as the RCU
   stall panic below, timing lines up almost exactly with the RCU stall
   detector's own window, meaning whatever blocked RPMh's completion had
   already been stuck before the RPMh call even timed out (log 03).
3. **The RCU grace-period kthread itself**, plus `SMP: failed to stop
   secondary CPUs 0-1,4-5` during the kernel's own panic shutdown - with
   *every* CPU idle state (cluster and per-CPU) disabled (log 03).
4. **The GPU DRM scheduler's `gpu->lock`** (`msm_job_run`,
   `msm_ringbuffer.c:38`) - the same lock from the GPU-fault-recovery
   deadlock theory from early in the project, already mitigated by
   `patch 0006` for a different specific interaction
   (`fault_coredump_done`). The reported lock owner's pid had been
   reused by an unrelated process earlier in the same capture, so this
   is read as another downstream victim, not a second confirmed GPU bug
   (log 04).
5. **ext4 journal commit and a Bluetooth HCI RX worker**
   (`jbd2_log_wait_commit`/`ext4_fsync`, and separately
   `synchronize_rcu`) - with 4GB of zram swap active (log 05).

Also found, early in the session, via a differently-corrupted pstore
capture: a real, corroborated (matches a known upstream code path -
[OrbStack issue #2471](https://github.com/orbstack/orbstack/issues/2471)
hits the identical stack) soft-lockup signature where `sshd-auth`'s
seccomp BPF filter JIT-compiling triggers `kick_all_cpus_sync` (log 01).
Confirmed via a dedicated test (disabling BPF JIT) that this isn't
sufficient on its own to explain the freeze, but it's a real example of
the same general shape: *any* code needing a cross-CPU synchronization
primitive at the wrong moment shows up as the apparent culprit.

## Other real findings along the way (not the root cause, but worth knowing)

- **This device has a genuine read-time bit-corruption problem** in its
  persistent-RAM (pstore/ramoops) region - individual characters get
  scrambled differently on repeated reads of the exact same crash. Plain
  text (the `console-ramoops` backend) survives this well enough to read
  around; a single bit flip anywhere in a compressed `dmesg-ramoops`
  stream corrupts everything after it and makes the whole record
  unparseable by zlib in any mode. This is why
  `CONFIG_PSTORE_COMPRESS` is now disabled
  (`kernel/config/gts7l.fragment`).
- **The existing `ramoops@9fa00000` node was real but wastefully
  split**: 256KB each for record/console/ftrace/pmsg, with neither
  ftrace-pstore nor `/dev/pmsg0` in use. Reallocated to 960KB of
  console-size (`kernel/patches/0010-reallocate-ramoops-console-size.patch`),
  which turned "under one second of capture before a crash" into
  several seconds.
- **`capture_watch.py`'s own console output competes with any
  tracepoint you're trying to capture** for the same finite pstore
  buffer. Turning it off (relying only on a host-side reachability
  monitor) roughly quadrupled the useful trace density in the same
  buffer size (log 06 → log 07, 11 events → 41 events for the same
  kind of capture).
- **`QCOM_ICC_BWMON` is real and correctly bound** on this device
  (`9091000.pmu`/`90b6400.pmu`, both attached to the `qcom-bwmon`
  driver, IRQs 81/581) - an earlier session note claiming it was dead
  code was wrong (it just checked for a device node literally named
  `*bwmon*`, which doesn't match how these devices are actually named).
- **`apps_rsc` (the RPMh resource-state coordinator) has only 2
  `ACTIVE_TCS` slots** (`sm8250.dtsi`'s `qcom,tcs-config`), shared by
  *every* RPMh consumer in mainline's current configuration - CPU power
  domains, cpufreq/interconnect bandwidth, GPU power, display,
  regulators. Downstream's kernel gives display its own separate
  `disp_rsc` instead of sharing `apps_rsc`; mainline's `sm8250.dtsi` has
  no `disp_rsc` node at all. A sibling porting project
  (`references/kernel_samsung_sm8250`, commit `30dcb35b3c6d8f2`) hit an
  almost exactly matching symptom (RPMh TCS exhaustion, different
  subsystem blocked each time, sometimes zero forensics, needing a hard
  reset) caused specifically by this kind of RSC sharing under a display
  quirk. This remains a real, untested structural difference - the live
  RPMh tracing in log 07 didn't show contention on `apps_rsc`, but that
  capture also didn't reach the actual moment of freeze (the trace
  simply stops, no panic fired), so it doesn't rule this out either.
  **This is the one concrete lead left if a future session wants to keep
  pushing on the severe case**: either port a `disp_rsc` node from
  downstream, or test a cheaper proxy (disable the display pipeline
  entirely during the stress test, removing its RPMh votes as a
  variable) before committing to the bigger devicetree change.

## Diagnostic infrastructure built this session (reusable)

- **Panic-on-hang, every boot** (these are runtime sysctls, not
  persisted - re-run after every reboot before testing):
  ```
  echo 1 > /proc/sys/kernel/softlockup_panic
  echo 1 > /proc/sys/kernel/hung_task_panic
  echo 1 > /proc/sys/kernel/panic_on_rcu_stall
  echo 5 > /proc/sys/kernel/hung_task_timeout_secs
  ```
  Converts a silent, unrecoverable hang into a panic that (usually)
  auto-reboots and leaves a pstore trace. Not guaranteed - two crashes
  this session never auto-recovered at all, meaning the watchdogs
  themselves can apparently also get stuck.
- **`CONFIG_PSTORE_COMPRESS` disabled**, **ramoops console-size widened
  to 960KB** (`kernel/patches/0010-...patch`) - see above.
- **`CONFIG_FTRACE`/`CONFIG_FUNCTION_TRACER`/`CONFIG_IRQSOFF_TRACER`
  added** (`kernel/config/gts7l.fragment`) - none of these were
  compiled in before this session (no `/sys/kernel/debug/tracing/` at
  all). Also set `ftrace_dump_on_oops=1` so the ftrace ring buffer gets
  flushed to the console (and thus pstore) at panic time.
- **`tools/loadtest/icc_watch.sh`** - samples the LLCC/EBI interconnect
  bandwidth vote and BWMON IRQ counts every 150ms to `/dev/kmsg` so it
  survives a hard freeze via pstore. Useful pattern for watching any
  `/sys` state across a crash without needing a file write to survive
  (which buffered writes generally don't - lost `icc_watch` output to
  this exact mistake once this session, see `docs/load-test-modules.md`).
- **Real kernel tracepoints usable the same way**: `rpmh:rpmh_send_msg`,
  `rpmh:rpmh_tx_done`, `icc_bwmon:qcom_bwmon_update`,
  `interconnect:icc_set_bw`, `interconnect:icc_set_bw_end`. Enable via
  `echo 1 > /sys/kernel/debug/tracing/events/<group>/<name>/enable`,
  they mirror to the console (and thus pstore) automatically as long as
  `current_tracer` isn't set to something that suppresses it.

## Raw logs (`docs/logs/freeze-2026-09-21/`)

All pulled from `/sys/fs/pstore/console-ramoops-0` (or `-1`) after a
crash. Every one of these has real, individual-character corruption
from this device's persistent-RAM read issue (see above) - read through
it, don't expect clean text. Numbered roughly in the order they were
captured this session:

1. `01-sshd-bpf-jit-kick-all-cpus-sync-ipi-hang.txt` - the `sshd-auth`
   seccomp BPF JIT / `kick_all_cpus_sync` soft-lockup signature.
2. `02-console-percpu-idle-disabled-stuck-core-recovers.txt` - a
   transient stuck-core event that recovered cleanly (cluster idle
   disabled, per-CPU idle still active) - the run that also caught the
   idle task inside real `cpu_suspend()`/`psci_cpu_suspend_enter()`.
3. `03-console-all-idle-disabled-RCU-stall-SMP-failed-to-stop.txt` -
   every CPU idle state disabled, RCU stall panic, `SMP: failed to stop
   secondary CPUs 0-1,4-5`. Also contains the RPMh `-ETIMEDOUT` trace.
4. `04-console-performance-governor-GPU-mutex-block.txt` - `performance`
   governor, hung-task panic on `msm_job_run`/`gpu->lock`.
5. `05-console-zram-swap-active-ext4-bluetooth-block.txt` - 4GB zram
   swap active, hung-task panic on ext4 journal commit and a Bluetooth
   HCI worker.
6. `06-console-rpmh-trace-diluted-by-capture_watch.txt` - first RPMh/
   interconnect tracing attempt, `capture_watch.py` still running and
   competing for buffer space (only 11 trace events survived).
7. `07-console-rpmh-interconnect-trace-clean-no-anomaly.txt` - cleanest
   capture of the session, `capture_watch.py` off, 41 trace events,
   normal-looking activity right up to a sudden, silent, total stop
   with no panic.

## Scripts referenced

- `tools/loadtest/capture_watch.py` - the main diagnostic (CPU/GPU
  sampling, stuck-core NMI-backtrace trigger). Pre-existing.
- `tools/loadtest/monitor_from_host.sh` - host-side reachability
  polling. Pre-existing. **Caution**: leaving multiple instances running
  across test rounds without killing the old ones happened once this
  session and amplified an unrelated test's severity - always
  `pkill -f monitor_from_host.sh` before starting a fresh one.
- `tools/loadtest/icc_watch.sh` - new this session, see above.

## Kernel changes from this session

- `kernel/patches/0006-bound-fault-coredump-wait-a6xx.patch` - predates
  this session, confirmed still applied and correct.
- `kernel/patches/0007-backport-genpd-psci-osi-power-unknown.patch` -
  backported unmerged upstream genpd/cpuidle-psci OSI-mode fix. Real,
  legitimate fix for what it addresses (genpd's boot-time power-state
  bookkeeping under PSCI OSI mode) but **tested and confirmed not to fix
  either freeze case**. Kept because it's still correct, not because it
  helped here.
- `kernel/patches/0008-disable-cluster-sleep-0-domain-idle-state.patch` -
  **the confirmed fix** for the moderate-pressure case.
- `kernel/patches/0009-disable-percpu-idle-states-diagnostic.patch` -
  diagnostic only, used to definitively rule out cpuidle/PSCI at every
  level. Real battery cost, no benefit - not for shipping as-is, but
  documents a real, airtight negative result.
- `kernel/patches/0010-reallocate-ramoops-console-size.patch` - real
  infrastructure improvement, keep.
- `kernel/config/gts7l.fragment` additions: `CONFIG_FTRACE`,
  `CONFIG_FUNCTION_TRACER`, `CONFIG_IRQSOFF_TRACER`,
  `# CONFIG_PSTORE_COMPRESS is not set`, `CONFIG_ZRAM=y`. All real,
  worth keeping regardless of the unresolved severe case.

Note: as of the end of this session, `work/linux`'s live tree has
**both** patch 0008 and patch 0009's changes applied (cluster *and*
per-CPU idle states disabled) - patch 0009 was left in place as the
most recent diagnostic state rather than reverted. Before shipping,
revert patch 0009's per-CPU idle-state removal (real, unnecessary
battery cost) and keep only patch 0008's cluster-level change.
