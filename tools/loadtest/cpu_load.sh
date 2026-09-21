#!/bin/bash
# CPU-only load test: no GPU/display work at all, to isolate whether the
# hard-freeze trigger is purely CPU-side (e.g. RT-priority starvation,
# scheduler pathology) independent of GPU/DPU traffic.
#
# Usage: cpu_load.sh [duration_seconds]  (default 900s = 15min, comfortably
# past the ~12min it took to reproduce the crash after the DPU/interconnect
# fixes - see "Bug 2" in docs/kernel-boot-debugging.md)
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

DURATION="${1:-900}"
log "=== CPU-only load test: start, duration ${DURATION}s, $(nproc) CPUs ==="
start_heartbeat
run_cpu "$DURATION"
log "=== CPU-only load test: completed (device survived) ==="
