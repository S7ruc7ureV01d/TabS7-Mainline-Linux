#!/bin/sh
# Trace the RPMh messages across one s2idle (tracing kernel needed). The
# sleep/wake sets the CPUs flush on the way down show which resources
# (rails, CXO, regulator modes, bandwidth) are still voted in sleep.
# Decode addresses with /sys/kernel/debug/cmd-db. Output: /root/rpmh-trace-*.txt
T=/sys/kernel/tracing
O=/root/rpmh-trace-$(date +%H%M%S).txt
sleep ${1:-3}
echo 0 > $T/tracing_on; echo > $T/trace
echo 16384 > $T/buffer_size_kb
echo 1 > $T/events/rpmh/enable
echo 1 > $T/tracing_on
sh /root/susptest.sh ${2:-20}
echo 0 > $T/tracing_on
cat $T/trace > $O
cat /sys/kernel/debug/cmd-db > $O.cmddb
echo 0 > $T/events/rpmh/enable
