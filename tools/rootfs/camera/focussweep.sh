#!/bin/bash
# Step the rear main lens (GT9769, dw9768 driver) through its range and
# capture raw frames at each position, for a host-side sharpness check.
# Keeps the lens subdev open: the driver powers the actuator only while
# it is open. Output: /root/focus/pos-NNNN.raw
L=$(media-ctl -d /dev/media0 -e "dw9768 23-000c")
mkdir -p /root/focus; rm -f /root/focus/*
exec 3<>"$L"
for p in ${*:-0 100 200 300 400 500 600 700 800 900 1023}; do
	v4l2-ctl -d "$L" --set-ctrl=focus_absolute=$p
	sleep 0.3
	sh /root/rawcap.sh /root/focus/pos-$(printf %04d $p).raw 4 1620 8 >/dev/null 2>&1
done
exec 3>&-
ls -l /root/focus
