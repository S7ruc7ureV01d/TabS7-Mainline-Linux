#!/bin/sh
# Install the automatic-brightness curve seeding (a user service that runs
# before KWin at every login; only fills an all-zero curve).
# Usage: sh install.sh [ROOT]  (default /).
set -eu
R=${1:-/}
D=$(dirname "$0")
install -D -m 755 "$D/gts7l-seed-autobrightness" "$R/usr/local/bin/gts7l-seed-autobrightness"
install -D -m 644 "$D/gts7l-seed-autobrightness.service" "$R/usr/lib/systemd/user/gts7l-seed-autobrightness.service"
mkdir -p "$R/etc/systemd/user/plasma-kwin_wayland.service.wants"
ln -sf /usr/lib/systemd/user/gts7l-seed-autobrightness.service \
	"$R/etc/systemd/user/plasma-kwin_wayland.service.wants/gts7l-seed-autobrightness.service"
echo "installed gts7l-seed-autobrightness (enabled for all users)"
