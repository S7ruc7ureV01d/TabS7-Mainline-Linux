#!/bin/bash
# Storage-only load test: no GPU, no Minecraft/JVM at all - heavy
# sequential write + fdatasync against the real UFS-backed rootfs.
# Motivation: the owner ran a plain `dd ... conv=fdatasync` against
# ~/Documents by hand and the device froze immediately - a completely
# GPU-unrelated repro, much faster than booting Minecraft, and it calls
# into question whether the GPU fault/recover cascade chased through
# most of this investigation (docs/load-test-modules.md) was the actual
# root cause or just a correlated symptom (Minecraft's heavy asset
# loading also generates real storage/page-cache pressure, not just
# GPU load).
#
# Usage: storage_load.sh [size_gb] [count]  (default: 1GB x 10 = 10GB,
# matching the owner's own repro exactly)
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

SIZE_GB="${1:-1}"
COUNT="${2:-10}"
# Test file target directory overridable (e.g. a separate nodelalloc-
# mounted filesystem, per docs/load-test-modules.md "isolated nodelalloc
# test" - a loop file backed by root itself doesn't isolate anything if
# the test file/logs are also written there).
TESTFILE="${LOADTEST_TESTDIR:-/root/loadtest}/storage_test.img"

log "=== Storage-only load test: start, ${SIZE_GB}G x ${COUNT} = $((SIZE_GB * COUNT))G total, fdatasync per block ==="
start_heartbeat
dd if=/dev/zero of="$TESTFILE" bs="${SIZE_GB}G" count="$COUNT" conv=fdatasync status=progress
log "=== Storage-only load test: completed (device survived) ==="
rm -f "$TESTFILE"
