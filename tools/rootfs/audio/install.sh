#!/bin/sh
# Install the Galaxy Tab S7 (gts7l) speaker setup into a root filesystem
# (docs/phase3-audio-scoping.md). Usage: sh install.sh [ROOT]   (default /)
# Firmware is not handled here: /lib/firmware/cirrus/cs35l41-dsp1-spk-prot-
# gts7l.{wmfw,bin} come from stock (docs), and the ADSP firmware comes via
# the slpi-start setup.
set -eu
R=${1:-/}
D=$(dirname "$0")
inst() { install -D -m "$1" "$D/$2" "$R/$3"; echo "  $3"; }

echo "installing into $R:"
# Safety: gate (root-only until verified), safe state at boot, autosuspend workaround
inst 644 72-gts7l-audio-gate.rules            etc/udev/rules.d/72-gts7l-audio-gate.rules
inst 644 73-gts7l-cs35l41-autosuspend.rules   etc/udev/rules.d/73-gts7l-cs35l41-autosuspend.rules
inst 644 74-gts7l-audio-safe.rules            etc/udev/rules.d/74-gts7l-audio-safe.rules
inst 755 gts7l-audio-safe                     usr/local/sbin/gts7l-audio-safe
inst 644 gts7l-audio-safe.service             etc/systemd/system/gts7l-audio-safe.service
# Desktop audio: UCM profile, WirePlumber sink setup, PipeWire upmix
inst 644 ucm2/conf.d/sm8250/Samsung-GTS7L-CS35L41-Speakers.conf usr/share/alsa/ucm2/conf.d/sm8250/Samsung-GTS7L-CS35L41-Speakers.conf
inst 644 ucm2/Samsung/gts7l/HiFi.conf          usr/share/alsa/ucm2/Samsung/gts7l/HiFi.conf
inst 644 51-gts7l-speakers.conf               etc/wireplumber/wireplumber.conf.d/51-gts7l-speakers.conf
for d in client.conf.d pipewire-pulse.conf.d pipewire.conf.d; do
	inst 644 50-gts7l-upmix.conf              etc/pipewire/$d/50-gts7l-upmix.conf
done
# No ALSA mixer save/restore: alsa-restore raced gts7l-audio-safe at boot and
# replayed every saved control, including the protection DSP's cached
# tuning controls. The safe state and UCM set everything that matters.
mkdir -p "$R/etc/systemd/system"
ln -sf /dev/null "$R/etc/systemd/system/alsa-restore.service"; echo "  etc/systemd/system/alsa-restore.service -> /dev/null (masked)"
ln -sf /dev/null "$R/etc/systemd/system/alsa-state.service";   echo "  etc/systemd/system/alsa-state.service -> /dev/null (masked)"
rm -f "$R/var/lib/alsa/asound.state"
echo "done"
echo "optional, per user: copy speaker-id.sh and speaker-id-ch*.wav to ~/speaker-id/"
