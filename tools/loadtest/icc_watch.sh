#!/bin/bash
# Samples the LLCC/EBI interconnect bandwidth vote and the QCOM_ICC_BWMON
# threshold-IRQ counts every 150ms, writing each sample to /dev/kmsg so it
# survives into a pstore console-ramoops capture across a hard freeze
# (a regular log file's buffered writes are lost on a crash/reboot - this
# doesn't need fsync because printk's ring buffer + pstore's ramoops
# backend already durably capture kmsg writes).
#
# Written for the 2026-09-21 freeze investigation
# (docs/freeze-investigation-2026-09-21-summary.md). Run this on the
# device (over ssh, backgrounded) before reproducing the freeze, and
# read back /sys/fs/pstore/console-ramoops-0 after the device reboots.
#
# Needs CONFIG_PSTORE_COMPRESS disabled (kernel/config/gts7l.fragment) -
# a compressed pstore record is unparseable after this device's
# read-time bit corruption, plain text survives it well enough to read
# around. Also needs a decent console-size in the ramoops devicetree
# node (kernel/patches/0010-reallocate-ramoops-console-size.patch) or
# this and capture_watch.py's own output will crowd each other out of
# the buffer within about a second.
while true; do
    bw=$(cat /sys/kernel/debug/interconnect/interconnect_summary | grep -E "^(ebi|llcc_mc|qns_llcc|qns_mem_noc_hf)@" | tr '\n' '|')
    irq=$(grep -E "9091000.pmu|90b6400.pmu" /proc/interrupts | tr '\n' '|')
    echo "ICCWATCH: $bw IRQ: $irq" > /dev/kmsg
    sleep 0.15
done
