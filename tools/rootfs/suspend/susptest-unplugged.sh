#!/bin/sh
# Wait until the USB cable is pulled (charger reports offline, up to
# 10 min; usb0 carrier doesn't drop because dwc3 has no VBUS sensing),
# settle 10 s, then run susptest.sh with a ${1:-30} s RTC wake.
# Results in /root/susp-*.log as usual; replug afterwards.
P=/sys/class/power_supply/max77705-charger/online
i=0
while [ "$(cat $P 2>/dev/null)" = 1 ] && [ $i -lt 600 ]; do
	sleep 1; i=$((i+1))
done
sleep 10
sh /root/susptest.sh ${1:-30}
