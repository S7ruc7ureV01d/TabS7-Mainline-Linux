#!/bin/sh
# WARNING: do not run on kernels without clk_ignore_unused (#127 on): stopping
# the ADSP under the active VA macro resets the SoC. Kept for the record.
# Strip the known RPMh vote holders, then suspend: USB controller, BT UART,
# Wi-Fi (rfkill), SLPI and ADSP. If qcom_stats still shows no CX/AOSS sleep,
# the blocker is something else. Audio and sensors are gone afterwards:
# reboot to restore. USB is rebound at the end so ssh comes back.
sleep ${1:-5}
rfkill block all
echo 998000.serial > /sys/bus/platform/drivers/qcom_geni_serial/unbind
echo stop > /sys/class/remoteproc/remoteproc0/state
echo stop > /sys/class/remoteproc/remoteproc1/state
echo a6f8800.usb > /sys/bus/platform/drivers/dwc3-qcom-legacy/unbind
sleep 3
sh /root/susptest.sh ${2:-30}
echo a6f8800.usb > /sys/bus/platform/drivers/dwc3-qcom-legacy/bind
L=$(ls -t /root/susp-*.log | head -1)
{ for r in /sys/class/remoteproc/*; do echo "$(cat $r/name) $(cat $r/state)"; done
  echo "bi_tcxo users after: $(awk '$1=="bi_tcxo"{print $2}' /sys/kernel/debug/clk/clk_summary)"; } >> $L
