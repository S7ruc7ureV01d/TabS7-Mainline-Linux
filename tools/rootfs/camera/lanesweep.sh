#!/bin/sh
# (Historical: found the reversed lane order, now data-lanes = <3 2 1 0> in the DTS.)
# Debug kernel only (qcom_camss dbg_lane_assign / dbg_settle parameters):
# try every CSID lane assignment (and optionally settle counts) for the
# rear main sensor and report which ones deliver frames.
# Usage: lanesweep.sh [settle...]   (no args: driver's own settle count)
P=/sys/module/qcom_camss/parameters
M="media-ctl -d /dev/media0"
F=SGRBG10_1X10/2104x1184
$M -r
$M -l '"msm_csiphy0":1->"msm_csid0":0[1],"msm_csid0":1->"msm_vfe0_rdi0":0[1]'
$M -V "\"s5k3m5 20-002d\":0[fmt:$F],\"msm_csiphy0\":0[fmt:$F],\"msm_csid0\":0[fmt:$F],\"msm_vfe0_rdi0\":0[fmt:$F]"
v4l2-ctl -d /dev/video0 --set-fmt-video=width=2104,height=1184,pixelformat=pgAA
SETTLES=${*:--1}
for st in $SETTLES; do
	echo $st > $P/dbg_settle
	for a in 0 1 2 3; do for b in 0 1 2 3; do for c in 0 1 2 3; do for d in 0 1 2 3; do
		[ $a = $b ] || [ $a = $c ] || [ $a = $d ] || [ $b = $c ] || [ $b = $d ] || [ $c = $d ] && continue
		v=$(( (d << 12) | (c << 8) | (b << 4) | a ))
		echo $v > $P/dbg_lane_assign
		rm -f /tmp/f.raw
		timeout 4 v4l2-ctl -d /dev/video0 --stream-mmap --stream-count=3 --stream-to=/tmp/f.raw >/dev/null 2>&1
		sz=$(stat -c %s /tmp/f.raw 2>/dev/null || echo 0)
		printf "settle %s assign 0x%04x bytes %s\n" $st $v $sz
		[ "$sz" -gt 0 ] && cp /tmp/f.raw /root/cam0-$(printf %04x $v)-s$st.raw
	done; done; done; done
done
echo -1 > $P/dbg_lane_assign; echo -1 > $P/dbg_settle
