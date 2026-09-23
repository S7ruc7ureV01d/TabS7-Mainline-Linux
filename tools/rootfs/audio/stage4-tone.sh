#!/bin/sh
# Stage 4 step 5: one 2 s 1 kHz tone at -40 dBFS, analog gain 0, via protection DSP.
# /root/tone-1k-m40.wav: 48 kHz S16 stereo, amplitude 328 (-40.0 dBFS), 20 ms fades.
# Needs the amps' autosuspend_delay_ms at 0 (see docs/phase3-audio-scoping.md,
# stage 4 result): otherwise the second stream here fails the DSP RESUME.
set -u
C=0
get() { amixer -c$C cget name="$1" 2>&1 | grep ": values" | sed 's/.*values=//'; }
for n in FL FR RL RR; do
	[ "$(get "$n Analog PCM Volume")" = 0 ] && [ "$(get "$n PCM Source")" = 1 ] || { echo "ABORT: $n gain/source not safe"; exit 1; }
done
dmesg -C
amixer -q -c$C cset name="PRIMARY_TDM_RX_0 Audio Mixer MultiMedia1" on
# 1 s of silence first so DSP/amps settle, then the tone
aplay -q -D hw:$C,0 -f S16_LE -c 2 -r 48000 -d 1 /dev/zero
( aplay -q -D hw:$C,0 /root/tone-1k-m40.wav; echo "aplay exit=$?" ) & AP=$!
sleep 1
for n in FL FR RL RR; do P="$n DSP1 Protection"; echo "during $n CSPL_STATE=$(get "$P cd CSPL_STATE") HALO=$(get "$P 400a4 HALO_STATE") TEMP=$(get "$P cd CSPL_TEMPERATURE")"; done
wait $AP
amixer -q -c$C cset name="PRIMARY_TDM_RX_0 Audio Mixer MultiMedia1" off
echo "PCM: $(cat /proc/asound/card0/pcm0p/sub0/status)"
echo "== kernel log"; dmesg | grep -v Handover
