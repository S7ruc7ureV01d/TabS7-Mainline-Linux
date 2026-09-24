#!/bin/sh
# Install the gts7l swap file units into a root filesystem.
# Usage: sh install.sh [ROOT]  (default /). The 8 GiB /swapfile itself is
# created on first boot (gts7l-swapfile-create.service), not shipped.
set -eu
R=${1:-/}
D=$(dirname "$0")
# The old service (ordering cycle with local-fs.target), if present
rm -f "$R/etc/systemd/system/swap.target.wants/gts7l-swapfile.service" \
      "$R/etc/systemd/system/gts7l-swapfile.service"
install -D -m 644 "$D/gts7l-swapfile-create.service" "$R/etc/systemd/system/gts7l-swapfile-create.service"
install -D -m 644 "$D/swapfile.swap" "$R/etc/systemd/system/swapfile.swap"
mkdir -p "$R/etc/systemd/system/swap.target.wants"
ln -sf ../swapfile.swap "$R/etc/systemd/system/swap.target.wants/swapfile.swap"
echo "installed swapfile.swap + gts7l-swapfile-create.service (enabled)"
