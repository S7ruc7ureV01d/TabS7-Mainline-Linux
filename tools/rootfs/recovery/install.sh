#!/bin/sh
# Install the "Reboot to Recovery" launcher into a root filesystem.
# Usage: sh install.sh [ROOT]  (default /). Needs kdialog for the
# confirmation prompt (pacman -S kdialog); without it the reboot is
# immediate.
set -eu
R=${1:-/}
D=$(dirname "$0")
install -D -m 755 "$D/gts7l-reboot-to" "$R/usr/local/bin/gts7l-reboot-to"
install -D -m 644 "$D/gts7l-reboot-recovery.desktop" "$R/usr/share/applications/gts7l-reboot-recovery.desktop"
echo "installed gts7l-reboot-to + Reboot to Recovery launcher"
