#!/usr/bin/env python3
"""Fast, frequently-fsynced crash-lead-up capture, run during a real
Minecraft repro. Motivation: pstore/ramoops's dead-simple memcpy() into a
tiny reserved DRAM region has captured nothing useful across four
independent real freezes (docs/load-test-modules.md). A plain file on the
real /data-backed rootfs, written and fsync'd every fraction of a second,
survives up to the last successful sync even if the system dies a moment
later - we don't need the crash to trigger a dump, we just need our own
log to always be a little ahead of it.

Everything here is a plain file read - no subprocess spawns (an earlier
version shelled out to `ps`/`dmesg`; that showed up as noise in its own
`ps` snapshot and costs real fork/exec overhead on an already-stressed
system). Two cadences:

LIGHT (every SAMPLE_INTERVAL, ~0.3s) - cheap, bounded reads only:
  - per-core CPU busy% (/proc/stat)
  - GPU devfreq cur/target frequency
  - GPU ring-buffer state: a *bounded* 300-byte read of
    /sys/kernel/debug/dri/0/gpu - the full file is 40-50KB (it dumps the
    entire ring buffer as an ascii85 blob), but the useful summary
    (rbbm-status, ring rptr/wptr, fence counters) is always in the first
    ~300 bytes, before that blob starts. rptr/wptr diverging and not
    advancing is the direct "GPU stopped draining its command queue"
    signal; rbbm-status nonzero is a raw hardware fault-status readback.
  - /proc/loadavg

HEAVY (every HEAVY_EVERY light samples, ~2s):
  - GPU ring-buffer state (see above) - too costly for the light tier
  - top processes by CPU delta (pure /proc/*/stat scan, no `ps`)
  - per-thread CPU delta breakdown for the top 2 processes only
    (/proc/<pid>/task/*/stat) - bounded to just the busiest processes,
    not a system-wide thread scan
  - /proc/interrupts delta, specifically gpu-irq/gmu (did the GPU stop
    interrupting entirely, independent of what any thread looks like)

kmsg draining runs every LIGHT cycle, not just heavy - a real crash
showed GPU fault/recover cascades arriving on almost exactly the same
~2s cadence the old heavy-only drain used, risking missing the actual
final message. It's a non-blocking read, cheap even at 0.3s.
"""
import os
import time

LOGDIR = "/root/loadtest"
OUTFILE = os.path.join(LOGDIR, "capture_watch.log")
SAMPLE_INTERVAL = 0.05  # benchmarked: fsync ~1.3ms + reads ~0.3ms << 50ms,
                        # well under 5% duty cycle, safe to go this fast
HEAVY_EVERY = 40  # 40 * 0.05s = ~2s wall-clock, same heavy cadence as before
GPU_DEBUGFS = "/sys/kernel/debug/dri/0/gpu"
GPU_DEBUGFS_READ_BYTES = 400  # covers the header, stops before the ascii85 ring dump
GPU_DEVFREQ = "/sys/class/devfreq/3d00000.gpu"
DPU_CRTC_STATE = "/sys/kernel/debug/dri/0/crtc-0/state"

CLK_TCK = os.sysconf("SC_CLK_TCK")


def read_proc_stat_cpus():
    with open("/proc/stat") as f:
        cpus = {}
        for line in f:
            if not line.startswith("cpu"):
                break
            parts = line.split()
            if parts[0] == "cpu":
                continue
            cpus[parts[0]] = list(map(int, parts[1:8]))
    return cpus


def cpu_busy_pct(prev, cur):
    out = {}
    for name in cur:
        if name not in prev:
            continue
        deltas = [cur[name][i] - prev[name][i] for i in range(7)]
        total = sum(deltas)
        idle = deltas[3] + deltas[4]
        out[name] = 0.0 if total <= 0 else 100.0 * (total - idle) / total
    return out


def read_gpu_devfreq():
    try:
        with open(f"{GPU_DEVFREQ}/cur_freq") as f:
            cur = int(f.read().strip())
        with open(f"{GPU_DEVFREQ}/target_freq") as f:
            tgt = int(f.read().strip())
        return f"cur={cur} target={tgt}"
    except Exception as e:
        return f"(unavailable: {e})"


def read_gpu_ring_summary():
    try:
        with open(GPU_DEBUGFS, "rb") as f:
            chunk = f.read(GPU_DEBUGFS_READ_BYTES).decode("utf-8", "replace")
        fields = {}
        for line in chunk.splitlines():
            line = line.strip()
            for key in ("rbbm-status", "last-fence", "retired-fence", "rptr", "wptr"):
                if line.startswith(key + ":"):
                    fields[key] = line.split(":", 1)[1].strip()
        return " ".join(f"{k}={v}" for k, v in fields.items()) or "(no fields parsed)"
    except Exception as e:
        return f"(unavailable: {e})"


def read_loadavg():
    try:
        with open("/proc/loadavg") as f:
            return f.read().strip()
    except Exception as e:
        return f"(unavailable: {e})"


def read_dpu_crtc_state():
    """REMOVED FROM USE (kept only so the function exists if anyone
    re-derives this) - reading DPU_CRTC_STATE
    (/sys/kernel/debug/dri/0/crtc-0/state) triggers a real kernel
    WARN_ON on this device, every single time, in
    dpu_crtc_debugfs_state_show (drivers/gpu/drm/msm/disp/dpu1/
    dpu_crtc.c:627) - confirmed directly: 84 occurrences in an 820-line
    capture_watch.log, starting at line 22 (i.e. within the first
    second of reading it), tainting the kernel (Tainted: G W) and
    producing a real printk storm (a 30-40 line stack trace every 0.3s
    read). This almost certainly caused (or heavily contributed to) a
    real crash during testing that had nothing to do with Minecraft -
    do not re-enable this specific debugfs read without first fixing
    whatever locking precondition dpu_crtc.c:627 assumes."""
    return "(disabled - see docstring, WARN_ON on this kernel)"


def read_meminfo_brief():
    try:
        with open("/proc/meminfo") as f:
            out = {}
            for line in f:
                if line.startswith(("MemFree:", "MemAvailable:")):
                    k, v = line.split(":", 1)
                    out[k] = v.strip()
                if len(out) == 2:
                    break
        return " ".join(f"{k}={v}" for k, v in out.items())
    except Exception as e:
        return f"(unavailable: {e})"


def scan_proc_times():
    """pid -> (comm, utime+stime in ticks). Pure /proc scan, no ps."""
    out = {}
    for entry in os.listdir("/proc"):
        if not entry.isdigit():
            continue
        try:
            with open(f"/proc/{entry}/stat", "rb") as f:
                data = f.read().decode("utf-8", "replace")
            # comm is the (parenthesized) field, may contain spaces - split on last ')'
            rparen = data.rfind(")")
            comm = data[data.find("(") + 1 : rparen]
            rest = data[rparen + 2 :].split()
            utime, stime = int(rest[11]), int(rest[12])
            out[int(entry)] = (comm, utime + stime)
        except Exception:
            continue
    return out


def scan_thread_times(pid):
    out = {}
    try:
        for tid in os.listdir(f"/proc/{pid}/task"):
            try:
                with open(f"/proc/{pid}/task/{tid}/stat", "rb") as f:
                    data = f.read().decode("utf-8", "replace")
                rparen = data.rfind(")")
                comm = data[data.find("(") + 1 : rparen]
                rest = data[rparen + 2 :].split()
                utime, stime = int(rest[11]), int(rest[12])
                out[int(tid)] = (comm, utime + stime)
            except Exception:
                continue
    except Exception:
        pass
    return out


def top_by_delta(prev, cur, n):
    """[(pid, comm, pct)] sorted by CPU%% over the interval since prev."""
    rows = []
    for pid, (comm, t) in cur.items():
        if pid in prev:
            dt = t - prev[pid][1]
            if dt > 0:
                rows.append((pid, comm, dt))
    rows.sort(key=lambda r: -r[2])
    return rows[:n]


def read_interrupts():
    out = {}
    try:
        with open("/proc/interrupts") as f:
            lines = f.readlines()
        for line in lines[1:]:
            parts = line.split()
            if not parts:
                continue
            irq = parts[0].rstrip(":")
            name = parts[-1]
            if name in ("gpu-irq", "gmu"):
                counts = [int(x) for x in parts[1:-4] if x.isdigit()]
                out[name] = sum(counts) if counts else 0
    except Exception:
        pass
    return out


def open_kmsg():
    try:
        fd = os.open("/dev/kmsg", os.O_RDONLY | os.O_NONBLOCK)
        os.lseek(fd, 0, os.SEEK_END)
        return fd
    except Exception:
        return None


def drain_kmsg(fd):
    lines = []
    if fd is None:
        return lines
    while True:
        try:
            data = os.read(fd, 8192)
            if not data:
                break
            lines.append(data.decode("utf-8", "replace").strip())
        except BlockingIOError:
            break
        except Exception:
            break
    return lines


prev_thread_cache = {}


def main():
    os.makedirs(LOGDIR, exist_ok=True)
    fd_out = os.open(OUTFILE, os.O_CREAT | os.O_WRONLY | os.O_APPEND, 0o644)
    out = os.fdopen(fd_out, "a")

    prev_cpu = read_proc_stat_cpus()
    prev_proc = scan_proc_times()
    prev_irq = read_interrupts()
    kmsg_fd = open_kmsg()

    out.write(f"=== capture_watch start {time.strftime('%Y-%m-%dT%H:%M:%S')} ===\n")
    out.flush()
    os.fsync(fd_out)

    i = 0
    while True:
        time.sleep(SAMPLE_INTERVAL)
        now = time.time()
        ts = f"{time.strftime('%H:%M:%S', time.localtime(now))}.{int(now * 1000) % 1000:03d}"

        cur_cpu = read_proc_stat_cpus()
        busy = cpu_busy_pct(prev_cpu, cur_cpu)
        prev_cpu = cur_cpu
        busy_str = " ".join(f"{k}={v:5.1f}%" for k, v in sorted(busy.items()))

        out.write(
            f"[{ts}] {busy_str} | gpufreq: {read_gpu_devfreq()} "
            f"| load: {read_loadavg()} | mem: {read_meminfo_brief()} "
            f"| dpu: {read_dpu_crtc_state()}\n"
        )

        i += 1
        if i % HEAVY_EVERY == 0:
            # gpuring costs ~50ms (touches live GPU registers via debugfs) -
            # too much overhead for the 0.3s light cadence, and risks an
            # observer effect on the exact thing being measured. Heavy tier
            # only.
            out.write(f"--- gpu ring @ {ts} --- {read_gpu_ring_summary()}\n")
            cur_proc = scan_proc_times()
            top = top_by_delta(prev_proc, cur_proc, 6)
            out.write(f"--- top procs @ {ts} (delta ticks over ~{HEAVY_EVERY * SAMPLE_INTERVAL:.1f}s) ---\n")
            for pid, comm, dt in top:
                out.write(f"  pid={pid:<7} {comm:<20} +{dt} ticks\n")

            for pid, comm, _ in top[:2]:
                if pid not in prev_thread_cache:
                    prev_thread_cache[pid] = {}
                cur_threads = scan_thread_times(pid)
                tdeltas = []
                for tid, (tcomm, t) in cur_threads.items():
                    if tid in prev_thread_cache[pid]:
                        dt2 = t - prev_thread_cache[pid][tid][1]
                        if dt2 > 0:
                            tdeltas.append((tid, tcomm, dt2))
                tdeltas.sort(key=lambda r: -r[2])
                prev_thread_cache[pid] = cur_threads
                out.write(f"    threads of pid={pid} ({comm}):\n")
                for tid, tcomm, dt2 in tdeltas[:4]:
                    out.write(f"      tid={tid:<7} {tcomm:<20} +{dt2} ticks\n")

            prev_proc = cur_proc

            cur_irq = read_interrupts()
            irq_deltas = {k: cur_irq.get(k, 0) - prev_irq.get(k, 0) for k in cur_irq}
            prev_irq = cur_irq
            out.write(f"--- gpu irq delta @ {ts} --- {irq_deltas}\n")

        # kmsg draining moved to every light cycle (~0.3s), not just the
        # ~2s heavy tier - a real crash (docs/load-test-modules.md, "Real,
        # non-self-inflicted evidence...") showed GPU fault/recover
        # cascades arriving on almost exactly the same ~2s cadence as the
        # old heavy-only drain, so the actual final fault/failed-recovery
        # message may have been sitting undrained when the freeze hit.
        # This is a plain non-blocking read - cheap even at 0.3s.
        new_kmsg = drain_kmsg(kmsg_fd)
        if new_kmsg:
            out.write(f"--- new kmsg @ {ts} ---\n")
            for line in new_kmsg:
                out.write(f"  {line}\n")

        out.flush()
        os.fsync(fd_out)


if __name__ == "__main__":
    main()
