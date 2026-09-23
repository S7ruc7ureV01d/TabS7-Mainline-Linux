#!/bin/sh
# As susptest-unplugged.sh, with Wi-Fi and Bluetooth blocked (rfkill) for
# the test and restored after resume.
rfkill block wifi; rfkill block bluetooth
sleep ${1:-25}
sh /root/susptest.sh ${2:-30}
rfkill unblock wifi; rfkill unblock bluetooth
