#!/bin/bash
# Heartbeat-only logging for a manual, real Minecraft repro session (not a
# synthetic module) - just gives us the same precise last-alive timestamp
# the synthetic modules get, so a freeze here can be correlated against
# pstore/ramoops afterward the same way. Run detached, kill when done.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

log "=== Minecraft repro watch: start (manual play, not a synthetic module) ==="
start_heartbeat
wait "$HB_PID"
