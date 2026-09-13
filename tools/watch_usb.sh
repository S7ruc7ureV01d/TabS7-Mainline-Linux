#!/system/bin/sh
# Live USB-C attach/detach watcher for testing a hand-wired CC-resistor rig.
# Streams the kernel log and highlights anything USB/CC/typec-related the
# instant it happens - this catches CC-comparator activity even when no
# VBUS is present (which a plain power_supply/charging check would miss,
# since a bare CC-to-GND resistor rig never drives VBUS).
#
# Usage on the rooted test phone:
#   adb push watch_usb.sh /data/local/tmp/
#   adb shell su -c 'sh /data/local/tmp/watch_usb.sh'
# (drop "su -c" if the adb shell is already root, e.g. after `adb root`)
#
# Leave it running, then plug/unplug/flip/short your rig repeatedly.
# Every matching kernel-log line prints immediately, in real time.

PATTERN='usb|cc_|typec|extcon|muic|ccic|attach|detach|plug|vbus|rid|jig|max777'

echo "=== USB/CC live watcher starting ==="
echo "=== filtering kernel log for: $PATTERN ==="
echo "=== plug/unplug your rig now - matching lines print live below ==="
echo ""

dmesg -w 2>&1 | grep -iE --line-buffered "$PATTERN"
RC=$?

if [ $RC -ne 0 ]; then
	echo "(dmesg -w unavailable or failed, falling back to /proc/kmsg)"
	if [ -r /proc/kmsg ]; then
		cat /proc/kmsg 2>&1 | grep -iE --line-buffered "$PATTERN"
	else
		echo "Neither 'dmesg -w' nor /proc/kmsg worked - is this shell actually root?"
		exit 1
	fi
fi
