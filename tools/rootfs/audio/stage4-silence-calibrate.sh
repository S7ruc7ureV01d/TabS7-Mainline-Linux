#!/bin/sh
# Audio stage 4, steps 1-4 (docs/phase3-audio-scoping.md): power the four
# CS35L41 amps with DIGITAL SILENCE only, confirm the protection firmware
# took this unit's calibration and is running. Plays no signal.
# The kernel writes the calibration before the firmware starts (patch 0018,
# values from the DTS): the running firmware clears CAL_R/STATUS/CHECKSUM
# written from userspace, so this script only verifies. CAL_SET_STATUS is
# the firmware's verdict: 1 = its defaults, 2 = our calibration.
# Run as root with the audio gate in place.
set -u
C=0
ctl()  { amixer -q -c$C cset name="$1" "$2"; }
get()  { amixer -c$C cget name="$1" 2>&1 | grep ": values" | sed 's/.*values=//'; }
be32() { printf '0x%02x,0x%02x,0x%02x,0x%02x' $(( ($1>>24)&255 )) $(( ($1>>16)&255 )) $(( ($1>>8)&255 )) $(( $1&255 )); }
# Live reads only: regmap debugfs shows cached values for the DSP memory,
# not what the DSP holds, so all readback goes through the wm_adsp controls.
rt()   { cat /sys/bus/i2c/devices/11-00$1/power/runtime_status; }
alive() { kill -0 $AP 2>/dev/null || { echo "ABORT: silence stream ended early"; exit 1; }; }

# name:i2c-addr:rdc:vsc:isc  (work/stock-dump/dump/cirrus, suffix map in the doc)
AMPS="FL:43:8401:16769733:16776646 FR:42:8590:9608:2201 RL:41:9087:16760669:16776875 RR:40:9144:9560:16775534"
TEMP=27

echo "== step 1: minimum gain, protection in path"
for a in $AMPS; do n=${a%%:*}
	ctl "$n Analog PCM Volume" 0
	ctl "$n PCM Source" DSP
	ctl "$n DSP1 Preload Switch" on
	echo "$n: analog=$(get "$n Analog PCM Volume") src=$(get "$n PCM Source") preload=$(get "$n DSP1 Preload Switch")"
	[ "$(get "$n PCM Source")" = 1 ] || { echo "ABORT: $n PCM Source is not DSP"; exit 1; }
	[ "$(get "$n Analog PCM Volume")" = 0 ] || { echo "ABORT: $n analog gain not 0"; exit 1; }
done
ctl "PRIMARY_TDM_RX_0 Audio Mixer MultiMedia1" on

echo "== step 2: digital silence stream"
aplay -q -D hw:$C,0 -f S16_LE -c 2 -r 48000 -d 60 /dev/zero &
AP=$!
sleep 2
kill -0 $AP 2>/dev/null || { echo "ABORT: silence stream did not start"; exit 1; }
for a in $AMPS; do n=${a%%:*}; r=$(echo $a | cut -d: -f2); echo "$n runtime=$(rt $r) CSPL_STATE=$(get "$n DSP1 Protection cd CSPL_STATE")"
	[ "$(rt $r)" = active ] || { echo "ABORT: $n not runtime-active during stream"; kill $AP; exit 1; }; done

echo "== step 3: calibration taken?"
fail=0
for a in $AMPS; do
	n=$(echo $a | cut -d: -f1)
	vsc=$(echo $a | cut -d: -f4); isc=$(echo $a | cut -d: -f5)
	alive
	P="$n DSP1 Protection"
	got="SET=$(get "$P cd CAL_SET_STATUS") AMB=$(get "$P cd CAL_AMBIENT") VIMON=$(get "$P 400a4 VIMON_CAL") VSC=$(get "$P 400a4 VSC") ISC=$(get "$P 400a4 ISC")"
	want="SET=$(be32 2) AMB=$(be32 $TEMP) VIMON=$(be32 2) VSC=$(be32 $vsc) ISC=$(be32 $isc)"
	if [ "$got" = "$want" ]; then echo "$n calibration OK: $got"; else echo "$n MISMATCH: got $got / want $want"; fail=1; fi
done
echo "== step 4: protection running?"
for a in $AMPS; do n=${a%%:*}; r=$(echo $a | cut -d: -f2); alive
	P="$n DSP1 Protection"
	h1=$(get "$P 400a4 HALO_HEARTBEAT"); sleep 1; h2=$(get "$P 400a4 HALO_HEARTBEAT")
	st=$(get "$P cd CSPL_STATE")
	echo "$n runtime=$(rt $r) HALO_STATE=$(get "$P 400a4 HALO_STATE") HEARTBEAT $h1 -> $h2 CSPL_STATE=$st"
	[ -n "$h1" ] && [ "$h1" != "$h2" ] || fail=1
	[ "$st" = "$(be32 0)" ] || fail=1
done

echo "== kernel's read-back from DSP memory (patch 0018)"
dmesg | grep -E "cs35l41 11-004[0-3]: (Calibration|Failed to write|Ignoring|Cannot read)"
[ "$(dmesg | grep -cE 'cs35l41 11-004[0-3]: Calibration applied')" -ge 4 ] || fail=1

kill $AP 2>/dev/null; wait $AP 2>/dev/null
ctl "PRIMARY_TDM_RX_0 Audio Mixer MultiMedia1" off
sleep 1
echo "PCM after stop: $(cat /proc/asound/card0/pcm0p/sub0/status)"
[ $fail = 0 ] && echo "RESULT: ALL CHECKS PASSED" || echo "RESULT: FAILED - do not proceed to a tone"
