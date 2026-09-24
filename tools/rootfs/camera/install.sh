#!/bin/sh
# Install the Galaxy Tab S7 (gts7l) camera setup into a root filesystem
# (docs/phase4-camera-scoping.md). Usage: sh install.sh [ROOT]  (default /)
# Packages (not handled here): libcamera libcamera-ipa libcamera-tools
# pipewire-libcamera gst-plugin-libcamera.
set -eu
R=${1:-/}
D=$(dirname "$0")
inst() { install -D -m "$1" "$D/$2" "$R/$3"; echo "  $3"; }

echo "installing into $R:"
inst 644 52-gts7l-camera.conf etc/wireplumber/wireplumber.conf.d/52-gts7l-camera.conf
inst 755 rawcap.sh            usr/local/bin/gts7l-rawcap
inst 755 gts7l-cam-focus         usr/local/sbin/gts7l-cam-focus
inst 644 gts7l-cam-focus.service etc/systemd/system/gts7l-cam-focus.service
[ -e "$R/etc/default/gts7l-cam-focus" ] || inst 644 gts7l-cam-focus.default etc/default/gts7l-cam-focus
echo "enable with: systemctl enable --now gts7l-cam-focus"
