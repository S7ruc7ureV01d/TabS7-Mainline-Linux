#!/bin/bash
# Shared helpers for the load-test modules (see docs/load-test-modules.md).
# Heartbeat log lets us tell, after a full freeze with zero pstore trace
# (see "Crash #4" in docs/kernel-boot-debugging.md), the last moment the
# device was still alive - journalctl -f is documented as unreliable for
# this (docs/dev-environment-quickref.md).

LOGDIR="${LOADTEST_LOGDIR:-/root/loadtest}"
mkdir -p "$LOGDIR"

start_heartbeat() {
    ( while true; do date +%s.%N >> "$LOGDIR/heartbeat.log"; sleep 0.5; done ) &
    HB_PID=$!
    trap 'kill "$HB_PID" 2>/dev/null' EXIT
}

log() {
    echo "[$(date -Is)] $*" | tee -a "$LOGDIR/session.log"
}

# Run glmark2 against the real KWin Wayland session (uid 1001, socket
# wayland-0) rather than a headless/DRM-master context, since the goal is
# to reproduce load through the same display path Minecraft actually uses.
run_gpu() {
    local duration="$1"
    timeout "$duration" su - gts7l -c \
        "XDG_RUNTIME_DIR=/run/user/1001 WAYLAND_DISPLAY=wayland-0 glmark2-wayland --run-forever --fullscreen --annotate" \
        >> "$LOGDIR/gpu_load.out" 2>&1
}

run_cpu() {
    local duration="$1"
    stress-ng --cpu "$(nproc)" --cpu-method all --metrics-brief --timeout "${duration}s" \
        >> "$LOGDIR/cpu_load.out" 2>&1
}
