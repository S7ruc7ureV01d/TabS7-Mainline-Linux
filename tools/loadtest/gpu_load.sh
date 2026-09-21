#!/bin/bash
# GPU-only load test: sustained rendering through the real KWin/Wayland
# session (same DPU/Freedreno path Minecraft uses), with minimal CPU work
# of our own, to isolate whether sustained GPU/DPU commit traffic alone can
# trigger the freeze independent of heavy CPU load (JVM/GC in the
# Minecraft case).
#
# Usage: gpu_load.sh [duration_seconds]  (default 900s = 15min)
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

DURATION="${1:-900}"
log "=== GPU-only load test: start, duration ${DURATION}s ==="
start_heartbeat
run_gpu "$DURATION"
log "=== GPU-only load test: completed (device survived) ==="
