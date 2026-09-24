#!/bin/sh
# Install the gts7l swap file service into a root filesystem.
# Usage: sh install.sh [ROOT]  (default /). The 8 GiB /swapfile itself is
# created on first boot, not shipped.
set -eu
R=${1:-/}
D=$(dirname "$0")
install -D -m 644 "$D/gts7l-swapfile.service" "$R/etc/systemd/system/gts7l-swapfile.service"
mkdir -p "$R/etc/systemd/system/swap.target.wants"
ln -sf ../gts7l-swapfile.service "$R/etc/systemd/system/swap.target.wants/gts7l-swapfile.service"
echo "installed gts7l-swapfile.service (enabled)"
