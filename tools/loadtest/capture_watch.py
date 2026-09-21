#!/usr/bin/env python3
"""Fast, frequently-fsynced crash-lead-up capture, run during a real
Minecraft repro. Motivation: pstore/ramoops's dead-simple memcpy() into a
tiny reserved DRAM region has captured nothing useful across four
independent real freezes (docs/load-test-modules.md). A plain file on the
real /data-backed rootfs, written and fsync'd every fraction of a second,
survives up to the last successful sync even if the system dies a moment
later - we don't need the crash to trigger a dump, we just need our own
log to always be a little ahead of it.

Samples, every SAMPLE_INTERVAL seconds: per-core CPU busy% (from
/proc/stat deltas - this is what would show the single-core-pegged-at-100%
the owner saw on the KDE widget, but at higher resolution and with
process-level attribution), plus a heavier snapshot (top CPU processes,
dmesg tail, /proc/interrupts delta) every HEAVY_EVERY samples.
"""
import os
import sys
import time
import subprocess

LOGDIR = "/root/loadtest"
OUTFILE = os.path.join(LOGDIR, "capture_watch.log")
SAMPLE_INTERVAL = 0.3
HEAVY_EVERY = 7  # ~every ~2s at 0.3s sampling


def read_proc_stat():
    with open("/proc/stat") as f:
        lines = f.readlines()
    cpus = {}
    for line in lines:
        if not line.startswith("cpu"):
            break
        parts = line.split()
        name = parts[0]
        if name == "cpu":
            continue
        vals = list(map(int, parts[1:8]))  # user nice system idle iowait irq softirq
        cpus[name] = vals
    return cpus


def cpu_busy_pct(prev, cur):
    out = {}
    for name in cur:
        if name not in prev:
            continue
        p, c = prev[name], cur[name]
        deltas = [c[i] - p[i] for i in range(len(c))]
        total = sum(deltas)
        idle = deltas[3] + deltas[4]  # idle + iowait
        if total <= 0:
            out[name] = 0.0
        else:
            out[name] = 100.0 * (total - idle) / total
    return out


def top_procs(n=6):
    try:
        out = subprocess.run(
            ["ps", "-eo", "pid,pcpu,comm", "--sort=-pcpu"],
            capture_output=True, text=True, timeout=2,
        ).stdout
        return "\n".join(out.splitlines()[: n + 1])
    except Exception as e:
        return f"(ps failed: {e})"


def dmesg_tail(n=5):
    try:
        out = subprocess.run(
            ["dmesg"], capture_output=True, text=True, timeout=2
        ).stdout
        return "\n".join(out.splitlines()[-n:])
    except Exception as e:
        return f"(dmesg failed: {e})"


def main():
    os.makedirs(LOGDIR, exist_ok=True)
    fd = os.open(OUTFILE, os.O_CREAT | os.O_WRONLY | os.O_APPEND, 0o644)
    f = os.fdopen(fd, "a")

    prev = read_proc_stat()
    i = 0
    f.write(f"=== capture_watch start {time.strftime('%Y-%m-%dT%H:%M:%S')} ===\n")
    f.flush()
    os.fsync(fd)

    while True:
        time.sleep(SAMPLE_INTERVAL)
        cur = read_proc_stat()
        busy = cpu_busy_pct(prev, cur)
        prev = cur
        ts = time.strftime("%H:%M:%S")
        busy_str = " ".join(f"{k}={v:5.1f}%" for k, v in sorted(busy.items()))
        f.write(f"[{ts}] {busy_str}\n")

        i += 1
        if i % HEAVY_EVERY == 0:
            f.write(f"--- top procs @ {ts} ---\n{top_procs()}\n")
            f.write(f"--- dmesg tail @ {ts} ---\n{dmesg_tail()}\n")

        f.flush()
        os.fsync(fd)


if __name__ == "__main__":
    main()
