#!/bin/sh
# Capture raw 10-bit Bayer frames from the rear main camera (S5K3M5) via
# CAMSS: CSIPHY0 -> CSID0 -> VFE0 RDI0 -> /dev/video0.
# Usage: rawcap.sh [out.raw] [frames] [exposure 8-1620] [gain 1-16]
# Convert on the host with tools/camera/raw2png.py.
OUT=${1:-/root/rear.raw}; N=${2:-8}; EXP=${3:-1620}; GAIN=${4:-8}
M="media-ctl -d /dev/media0"
F=SGRBG10_1X10/2104x1184
S=$($M -e "s5k3m5 20-002d")
$M -r
$M -l '"msm_csiphy0":1->"msm_csid0":0[1],"msm_csid0":1->"msm_vfe0_rdi0":0[1]'
$M -V "\"s5k3m5 20-002d\":0[fmt:$F],\"msm_csiphy0\":0[fmt:$F],\"msm_csid0\":0[fmt:$F],\"msm_vfe0_rdi0\":0[fmt:$F]"
v4l2-ctl -d /dev/video0 --set-fmt-video=width=2104,height=1184,pixelformat=pgAA
v4l2-ctl -d $S --set-ctrl=exposure=$EXP,analogue_gain=$GAIN
rm -f $OUT
timeout 10 v4l2-ctl -d /dev/video0 --stream-mmap --stream-count=$N --stream-to=$OUT
ls -l $OUT
