#!/bin/sh
# Install the USB ECM debug gadget (172.16.42.1) into a root filesystem.
# Usage: sh install.sh [ROOT]  (default /).
set -eu
R=${1:-/}
D=$(dirname "$0")
install -D -m 755 "$D/usb-gadget-ecm.sh" "$R/usr/local/bin/usb-gadget-ecm.sh"
install -D -m 644 "$D/usb-gadget-ecm.service" "$R/etc/systemd/system/usb-gadget-ecm.service"
install -D -m 644 "$D/usb-gadget-ecm-wait.service" "$R/etc/systemd/system/usb-gadget-ecm-wait.service"
mkdir -p "$R/etc/systemd/system/multi-user.target.wants"
ln -sf ../usb-gadget-ecm.service "$R/etc/systemd/system/multi-user.target.wants/usb-gadget-ecm.service"
echo "installed usb-gadget-ecm (+ -wait)"
