#!/bin/bash
# Burst-transition test: repeatedly alternates an idle period with a
# *simultaneous* sudden-onset CPU+GPU burst, to specifically target the
# failure the owner reports - the freeze happens right at the
# world-loading -> gameplay transition in Minecraft, i.e. a sharp combined
# CPU+GPU spike after a lighter period, not necessarily minutes of sustained
# plateau load. Sustained cpu_load.sh/gpu_load.sh alone can't distinguish
# "needs sustained duration" from "needs a sudden combined edge."
#
# Usage: burst_transition.sh [cycles] [idle_seconds] [burst_seconds]
#   defaults: 20 cycles, 15s idle, 20s burst  (~12min total, matching the
#   known reproduction window)
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

CYCLES="${1:-20}"
IDLE="${2:-15}"
BURST="${3:-20}"

log "=== Burst-transition test: start, ${CYCLES} cycles, idle=${IDLE}s burst=${BURST}s ==="
start_heartbeat

for i in $(seq 1 "$CYCLES"); do
    log "cycle $i: idle ${IDLE}s"
    sleep "$IDLE"
    log "cycle $i: BURST START (simultaneous CPU+GPU)"
    run_cpu "$BURST" &
    CPU_PID=$!
    run_gpu "$BURST" &
    GPU_PID=$!
    wait "$CPU_PID" "$GPU_PID"
    log "cycle $i: BURST END"
done

log "=== Burst-transition test: completed (device survived $CYCLES cycles) ==="
