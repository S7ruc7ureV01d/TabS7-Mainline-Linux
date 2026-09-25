#!/bin/sh
# Install the Flashlight launcher into a root filesystem.
# Usage: sh install.sh [ROOT]  (default /).
set -eu
R=${1:-/}
D=$(dirname "$0")
install -D -m 755 "$D/gts7l-flashlight" "$R/usr/local/bin/gts7l-flashlight"
install -D -m 644 "$D/gts7l-flashlight.desktop" "$R/usr/share/applications/gts7l-flashlight.desktop"
install -D -m 644 "$D/gts7l-flashlight.svg" "$R/usr/share/icons/hicolor/scalable/apps/gts7l-flashlight.svg"
if [ "$R" = / ]; then
	gtk-update-icon-cache -q /usr/share/icons/hicolor 2>/dev/null || true
	update-desktop-database -q /usr/share/applications 2>/dev/null || true
fi
echo "installed gts7l-flashlight + Flashlight launcher"
