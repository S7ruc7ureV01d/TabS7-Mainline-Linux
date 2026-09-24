#!/bin/sh
# DP alt mode scoping (docs/phase4-usb-dp-scoping.md): enable the MAX77705
# firmware's VDM discovery (SET_ALTERNATEMODE 0x3, as stock), wait for a
# device (CCStat = source), then read the firmware's stored Discover
# Identity / SVIDs / Modes responses (GET_VDM_RESP 0x4b). Read-only towards
# the partner: no Enter Mode or DP Configure is sent.
O=/root/vdmprobe.txt; : > $O
op() { # opcode + data...: write at 0x21, trigger at 0x41, reply at 0x51
	i2ctransfer -f -y 0 w$(($# + 1))@0x25 0x21 "$@" && i2ctransfer -f -y 0 w2@0x25 0x41 0x00
	sleep 0.3
	i2ctransfer -f -y 0 w1@0x25 0x51 r32@0x25
}
echo "altmode: $(op 0x55 0x03)" >> $O
n=0
while [ $(( $(i2cget -f -y 0 0x25 0x0a) & 7 )) != 2 ] && [ $n -lt 600 ]; do sleep 1; n=$((n+1)); done
echo "attached: CC=$(i2cget -f -y 0 0x25 0x0a) after ${n}s" >> $O
sleep 3
for id in 0x01 0x02 0x03 0x10; do echo "resp $id: $(op 0x4b $id)" >> $O; done
echo "PD_STATUS0=$(i2cget -f -y 0 0x25 0x0c) PD_STATUS1=$(i2cget -f -y 0 0x25 0x0d)" >> $O
