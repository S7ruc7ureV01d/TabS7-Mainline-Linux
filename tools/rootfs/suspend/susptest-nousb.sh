#!/bin/sh
# As susptest-unplugged.sh, with the USB controller's glue driver unbound for
# the suspend and rebound after (ssh over USB is gone meanwhile).
D=/sys/bus/platform/drivers/dwc3-qcom-legacy
sleep ${1:-25}
echo a6f8800.usb > $D/unbind
sleep 2
sh /root/susptest.sh ${2:-30}
echo a6f8800.usb > $D/bind
echo "rebind: $(readlink /sys/bus/platform/devices/a6f8800.usb/driver)" >> $(ls -t /root/susp-*.log | head -1)
