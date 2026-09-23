#!/bin/sh
# Debug kernel only (trace_printk in clk_core_(un)prepare for bi_tcxo):
# log every CXO prepare/unprepare with its stack across one s2idle, with
# the RPMh messages as flush markers.
T=/sys/kernel/tracing
O=/root/xo-trace-$(date +%H%M%S).txt
sleep ${1:-3}
echo 0 > $T/tracing_on; echo > $T/trace
echo 32768 > $T/buffer_size_kb
echo 1 > $T/events/rpmh/rpmh_send_msg/enable
echo "bi_tcxo count before: $(cat /sys/kernel/debug/clk/bi_tcxo/clk_prepare_count)" > $O.info
echo 1 > $T/tracing_on
sh /root/susptest.sh ${2:-20}
echo 0 > $T/tracing_on
cat $T/trace > $O
echo "bi_tcxo count after: $(cat /sys/kernel/debug/clk/bi_tcxo/clk_prepare_count)" >> $O.info
echo 0 > $T/events/rpmh/rpmh_send_msg/enable
echo 1 > $T/tracing_on
