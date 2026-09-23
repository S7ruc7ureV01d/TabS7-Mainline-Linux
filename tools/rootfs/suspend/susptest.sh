#!/bin/sh
# s2idle test: suspend with an RTC wake after ${1:-20} s, log what happened.
L=/root/susp-$(date +%H%M%S)
echo N > /sys/module/printk/parameters/console_suspend
{
echo "start $(date +%T) uptime $(cut -d' ' -f1 /proc/uptime)"
cat /sys/power/mem_sleep
for f in /sys/power/suspend_stats/*; do echo "$(basename $f)=$(cat $f)"; done 2>/dev/null | tr '\n' ' '; echo
} > $L.log
stats() { for s in aosd cxsd ddr; do printf "%s:%s/%s " $s $(sed -n 's/^Count: //p' /sys/kernel/debug/qcom_stats/$s) $(sed -n 's/^Accumulated Duration: //p' /sys/kernel/debug/qcom_stats/$s); done 2>/dev/null; echo; }
echo "qcom_stats before: $(stats)" >> $L.log
dmesg > $L.before
sync
rtcwake -m freeze -s ${1:-20} >> $L.log 2>&1
echo "rtcwake exit $? at $(date +%T) uptime $(cut -d' ' -f1 /proc/uptime)" >> $L.log
echo "qcom_stats after:  $(stats)" >> $L.log
for f in /sys/power/suspend_stats/*; do echo "$(basename $f)=$(cat $f)"; done 2>/dev/null | tr '\n' ' ' >> $L.log
echo >> $L.log
cat /sys/kernel/debug/wakeup_sources 2>/dev/null | sort -k6 -n -r | head -12 >> $L.log
dmesg > $L.after
sync
