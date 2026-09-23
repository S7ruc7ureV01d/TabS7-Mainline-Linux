#!/bin/sh
# Per-speaker check: -40 dBFS 1 kHz, one 4-ch stream channel at a time, analog gain 0.
set -u
get() { amixer -c0 cget name="$1" 2>&1 | grep ": values" | sed 's/.*values=//'; }
for n in FL FR RL RR; do [ "$(get "$n Analog PCM Volume")" = 0 ] && [ "$(get "$n PCM Source")" = 1 ] || { echo "ABORT $n"; exit 1; }; done
for a in 40 41 42 43; do [ "$(cat /sys/bus/i2c/devices/11-00$a/power/autosuspend_delay_ms)" = 0 ] || { echo "ABORT autosuspend"; exit 1; }; done
dmesg -C
amixer -q -c0 cset name="PRIMARY_TDM_RX_0 Audio Mixer MultiMedia1" on
for c in 1 2 3 4; do
	printf "Press Enter to play channel %s (5 s beep)... " $c; read _ </dev/tty
	aplay -q -D hw:0,0 /root/tone4L-ch$c.wav || echo "aplay failed ch$c"
	printf "  channel %s done. Where did it come from? (note it)\n" $c
done
amixer -q -c0 cset name="PRIMARY_TDM_RX_0 Audio Mixer MultiMedia1" off
echo "== kernel log"; dmesg | grep -v Handover
