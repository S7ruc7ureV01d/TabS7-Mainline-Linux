#!/bin/sh
# Install the SDX55 boot helper into a root filesystem (not enabled: stage 2
# is tested by hand; enable with systemctl enable sdx55-boot).
set -eu
R=${1:-/}
D=$(dirname "$0")
install -D -m 755 "$D/sdx55-boot.sh" "$R/usr/local/bin/sdx55-boot.sh"
install -D -m 644 "$D/sdx55-boot.service" "$R/etc/systemd/system/sdx55-boot.service"
echo "installed sdx55-boot (not enabled)"
