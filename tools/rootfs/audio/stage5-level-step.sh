#!/bin/sh
# Audio level step (docs/phase3-audio-scoping.md): one 3 s 1 kHz beep per
# speaker at LEVEL dBFS with analog gain GAIN, checking protection after
# each. Usage: sh stage5-level-step.sh LEVEL GAIN   e.g. 40 17 (= -40 dBFS)
# Tones: /root/lvl-m<LEVEL>-ch<N>.wav. GAIN is capped at stock's 17.
# Gain always goes back to 0 on exit.
set -u
LEVEL=${1:?level}; GAIN=${2:?gain}
C=SamsungGTS7LCS3
get() { amixer -c "$C" cget name="$1" 2>/dev/null | sed -n 's/^  : values=//p'; }
gain_all() { for n in FL FR RL RR; do amixer -q -c "$C" cset name="$n Analog PCM Volume" "$1"; done; }
finish() { amixer -q -c "$C" cset name="PRIMARY_TDM_RX_0 Audio Mixer MultiMedia1" off 2>/dev/null; gain_all 0; echo "gain back to 0: FL=$(get 'FL Analog PCM Volume') FR=$(get 'FR Analog PCM Volume') RL=$(get 'RL Analog PCM Volume') RR=$(get 'RR Analog PCM Volume')"; }
trap finish EXIT INT TERM

case "$GAIN" in ''|*[!0-9]*) echo "ABORT: bad gain"; exit 1;; esac
[ "$GAIN" -le 17 ] || { echo "ABORT: gain $GAIN above stock's 17"; exit 1; }
[ -e /run/gts7l-audio-safe.ok ] || { echo "ABORT: gts7l-audio-safe did not verify the amps this boot"; exit 1; }
for c in 1 2 3 4; do [ -e /root/lvl-m$LEVEL-ch$c.wav ] || { echo "ABORT: no tone for -$LEVEL dBFS"; exit 1; }; done
for n in FL FR RL RR; do
	[ "$(get "$n PCM Source")" = 1 ] && [ "$(get "$n DSP1 Firmware")" = 9 ] || { echo "ABORT: $n not on the protection DSP"; exit 1; }
done
for a in 40 41 42 43; do [ "$(cat /sys/bus/i2c/devices/11-00$a/power/autosuspend_delay_ms)" = 0 ] || { echo "ABORT: autosuspend not 0"; exit 1; }; done

gain_all "$GAIN"
for n in FL FR RL RR; do [ "$(get "$n Analog PCM Volume")" = "$GAIN" ] || { echo "ABORT: $n gain did not take"; exit 1; }; done
echo "-$LEVEL dBFS, analog gain $GAIN on all four amps"
dmesg -C
amixer -q -c "$C" cset name="PRIMARY_TDM_RX_0 Audio Mixer MultiMedia1" on

for c in 1 2 3 4; do
	n=$(echo "FL FR RL RR" | cut -d' ' -f$c)
	printf "Press Enter to play channel %s (%s, 3 s)... " $c $n; read _ </dev/tty
	aplay -q -D hw:$C,0 /root/lvl-m$LEVEL-ch$c.wav & AP=$!
	# Read mid-beep: the amps hibernate as soon as the stream ends
	# (autosuspend 0), and a hibernated DSP's controls can't be read.
	sleep 1.2
	P="$n DSP1 Protection"
	st=$(get "$P cd CSPL_STATE"); halo=$(get "$P 400a4 HALO_STATE"); t=$(get "$P cd CSPL_TEMPERATURE")
	wait $AP || { echo "ABORT: aplay failed"; exit 1; }
	# temperature: Q10.14 (0x5c000 = 23.0 C)
	tc=$(printf '%s' "$t" | awk -F, '{printf "%.1f", (strtonum($2)*65536 + strtonum($3)*256 + strtonum($4)) / 16384}')
	errs=$(dmesg | grep cs35l41 | grep -v Handover | grep -iE "error|fail|short|temp|overvolt|undervolt|boost" )
	echo "  $n: CSPL_STATE=$st HALO_STATE=$halo temp=${tc}C"
	[ "$st" = "0x00,0x00,0x00,0x00" ] && [ "$halo" = "0x00,0x00,0x00,0x02" ] || { echo "ABORT: protection not running on $n"; exit 1; }
	[ -z "$errs" ] || { echo "ABORT: amp errors:"; echo "$errs"; exit 1; }
done
echo "== kernel log"; dmesg | grep -v Handover
echo "STEP OK"
