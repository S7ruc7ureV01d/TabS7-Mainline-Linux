#!/bin/sh
# Boot the gts7l's flashless SDX55 modem (docs/phase4-lte-modem-scoping.md).
#
# The bootloader leaves the X55 in PBL; mhi-pci-generic probes it at ~0.8 s,
# before the rootfs, so its SBL load fails. Once the rootfs is up:
#  - serve the modem partition's image/sdx55m (read-only) as
#    /lib/firmware/qcom/sdx55m: sbl1.mbn for BHI, the rest for Sahara;
#  - serve read-only RAM copies of the mdm1m9kefs1/2/3 partitions (the
#    modem's per-device NV) as /lib/firmware/qcom/sdx55m-efs/efsN.bin;
#    nothing writes the partitions;
#  - rebind mhi-pci-generic, which loads SBL; SBL then pulls the rest over
#    Sahara (mhi_sahara_modem).
set -eu

FW=/lib/firmware/qcom
MNT=/run/sdx55m/modem-part
EFS=/run/sdx55m/efs

ro_bind() { # src dst
	mkdir -p "$2"
	mountpoint -q "$2" && return 0
	mount --bind "$1" "$2"
	mount -o remount,bind,ro "$2"
}

mkdir -p "$MNT"
mountpoint -q "$MNT" ||
	mount -t vfat -o ro,nodev,nosuid,noexec /dev/disk/by-partlabel/modem "$MNT"
ro_bind "$MNT/image/sdx55m" "$FW/sdx55m"

mkdir -p "$EFS"
for i in 1 2 3; do
	[ -s "$EFS/efs$i.bin" ] ||
		dd if=/dev/disk/by-partlabel/mdm1m9kefs$i of="$EFS/efs$i.bin" bs=1M status=none
done
chmod 0400 "$EFS"/efs*.bin
ro_bind "$EFS" "$FW/sdx55m-efs"

for d in /sys/bus/pci/devices/*; do
	[ "$(cat "$d/vendor")" = 0x17cb ] && [ "$(cat "$d/device")" = 0x0306 ] || continue
	dev=${d##*/}
	[ -e /sys/bus/pci/drivers/mhi-pci-generic/$dev ] &&
		echo "$dev" > /sys/bus/pci/drivers/mhi-pci-generic/unbind
	sleep 1
	echo "$dev" > /sys/bus/pci/drivers/mhi-pci-generic/bind
	echo "sdx55: rebound $dev"
done
