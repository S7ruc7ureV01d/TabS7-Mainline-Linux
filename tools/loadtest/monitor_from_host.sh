#!/bin/bash
# Run this from the HOST while a load-test module runs on the device.
# journalctl -k -f over SSH is documented as unreliable for catching a
# real crash live (docs/dev-environment-quickref.md: "a live-following SSH
# session ... can go silently stale ... exactly when the device crashes").
# This instead polls freshly each time, so a stall is unambiguous: it just
# stops printing OK lines, with the last printed timestamp bounding when
# the device died.
set -u
HOST="${1:-172.16.42.1}"
KEY="${2:-$HOME/.ssh/id_ed25519_gts7l}"

while true; do
    ts="$(date -Is)"
    if timeout 3 ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=2 \
        "root@$HOST" "true" 2>/dev/null; then
        echo "$ts OK"
    else
        echo "$ts UNREACHABLE"
    fi
    sleep 1
done
