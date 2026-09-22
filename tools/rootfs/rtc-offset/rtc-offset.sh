#!/bin/sh
# Keep wall-clock time across reboots on the Tab S7 (gts7l).
#
# The PM8150 RTC keeps counting while the tablet is off, but Linux can't
# write it: the PMIC arbiter gives write access to another execution
# environment ("disallowed SPMI write to sid=0, addr=0x6046"). Same as
# stock Android's time daemon: store offset = real time - raw RTC, and
# restore time = raw RTC + offset at boot.
#
#   restore - at boot, before time-set.target
#   save    - at shutdown, and periodically while NTP-synchronized
set -eu
RTC=/sys/class/rtc/rtc0/since_epoch
STATE=/var/lib/rtc-offset
OFFSET=$STATE/offset
TRUST=/run/rtc-offset.trusted

[ -r "$RTC" ] || { echo "rtc-offset: no $RTC" >&2; exit 0; }
raw=$(cat "$RTC")

case "${1:-}" in
restore)
	if [ -r "$OFFSET" ]; then
		off=$(cat "$OFFSET")
		now=$((raw + off))
		date -u -s "@$now" >/dev/null
		touch "$TRUST"
		echo "rtc-offset: restored $(date -u) (raw $raw + offset $off)"
	else
		echo "rtc-offset: no saved offset yet, leaving clock alone"
	fi
	;;
save)
	# Only trust the system clock if NTP synced it this boot, or we
	# restored it from a previous trusted offset - never persist a
	# clock that is still at systemd's build-date floor.
	synced=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo no)
	if [ "$synced" = yes ]; then
		touch "$TRUST"
	fi
	[ -e "$TRUST" ] || { echo "rtc-offset: clock not trusted, not saving"; exit 0; }
	off=$(( $(date -u +%s) - raw ))
	mkdir -p "$STATE"
	echo "$off" > "$OFFSET.tmp" && mv "$OFFSET.tmp" "$OFFSET"
	echo "rtc-offset: saved offset $off (synced=$synced)"
	;;
*)
	echo "usage: $0 restore|save" >&2; exit 2
	;;
esac
