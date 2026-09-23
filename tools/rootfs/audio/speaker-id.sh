#!/bin/sh
# Play a beep on each of the Galaxy Tab S7's four speakers by HARDWARE
# channel number (1-4), whatever labels WirePlumber currently gives them.
# The stream is tagged with the sink's own channel positions, so file
# channel N reaches sink channel N unchanged. Run as the desktop user.
# Beeps: -20 dBFS 1 kHz, 3 s, scaled by the sink volume.
set -eu
DIR=$(dirname "$0")
SINK=$(wpctl status | sed -n '/Sinks:/,/Sources:/p' | grep -o '[0-9]\+\. Built-in Audio Speakers' | cut -d. -f1)
[ -n "$SINK" ] || { echo "speaker sink not found"; exit 1; }
POS=$(wpctl inspect "$SINK" | sed -n 's/.*audio.position = "\[ \(.*\) \]"/\1/p' | tr -d ' ')
echo "sink $SINK, current labels by channel: $POS"
for id in 1 2 3 4; do
	[ -n "${1:-}" ] && [ "$1" != "$id" ] && continue
	label=$(echo "$POS" | cut -d, -f$id)
	printf "Press Enter to play speaker ID %s (now labelled %s)... " "$id" "$label"
	read _ </dev/tty
	pw-cat --playback --target "$SINK" --channels 4 --channel-map "$POS" "$DIR/speaker-id-ch$id.wav"
	echo "  ID $id done - where was it, and what should KDE call it?"
done
