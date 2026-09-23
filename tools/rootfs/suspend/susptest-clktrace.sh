#!/bin/sh
# Trace all clock prepare/unprepare (0<->1 transitions) plus RPMh messages
# across one s2idle. With the clock tree snapshot taken before, the trace
# can be replayed to the RPMh sleep flush to see which clocks under bi_tcxo
# (CXO) are still prepared when the CPUs go down.
T=/sys/kernel/tracing
O=/root/clk-trace-$(date +%H%M%S).txt
sleep ${1:-3}
echo 0 > $T/tracing_on; echo > $T/trace
echo 32768 > $T/buffer_size_kb
echo 1 > $T/events/clk/clk_prepare/enable
echo 1 > $T/events/clk/clk_unprepare/enable
echo 1 > $T/events/rpmh/rpmh_send_msg/enable
cd /sys/kernel/debug/clk
for c in */; do c=${c%/}; echo "$c $(cat $c/clk_prepare_count) $(cat $c/clk_parent 2>/dev/null)"; done > $O.tree
cd /
echo 1 > $T/tracing_on
sh /root/susptest.sh ${2:-20}
echo 0 > $T/tracing_on
cat $T/trace > $O
echo 0 > $T/events/clk/clk_prepare/enable
echo 0 > $T/events/clk/clk_unprepare/enable
echo 0 > $T/events/rpmh/rpmh_send_msg/enable
