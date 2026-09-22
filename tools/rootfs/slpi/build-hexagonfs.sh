#!/bin/sh
# Build the HexagonFS tree hexagonrpcd serves to the SLPI (sensor DSP) on the
# Galaxy Tab S7 LTE (gts7l). Run on the device as root.
#
#   build-hexagonfs.sh VENDOR_SENSORS_DIR PERSIST_SENSORS_DIR
#
#   VENDOR_SENSORS_DIR   stock /vendor/etc/sensors (config/, sns_reg_config)
#   PERSIST_SENSORS_DIR  stock /mnt/vendor/persist/sensors (registry/registry/)
#
# Both come from stock firmware: vendor from super.img (lpunpack), persist from
# a read-only copy of the persist partition. See docs/kernel-boot-debugging.md,
# "SLPI sensor hub, stage 2".
set -eu
VS=${1:?vendor etc/sensors dir}
PS=${2:?persist sensors dir}
R=/usr/share/qcom/sm8250/Samsung/gts7l

id fastrpc >/dev/null 2>&1 || { echo "create the fastrpc user first" >&2; exit 1; }
mkdir -p "$R/sensors" "$R/socinfo" "$R/sensors/persist/registry"

rm -rf "$R/sensors/config"
cp -r "$VS/config" "$R/sensors/config"

# Stock reads the SSC revision from a Samsung-only sysfs node; serve it from
# socinfo/ instead (hexagonrpcd maps socinfo/ as /sys/devices/soc0).
sed 's#^file=revision=.*#file=revision=/sys/devices/soc0/ssc_hw_rev#' \
	"$VS/sns_reg_config" > "$R/sensors/sns_reg.conf"

# socinfo values stock's kernel exposes and mainline doesn't. hw_platform MTP:
# kona_lsm6dso_0_0.json (this unit's IMU) only matches MTP/Surf/RCM.
# ssc_hw_rev = Android ro.revision = androidboot.revision=7 on this unit.
printf '356\n'     > "$R/socinfo/soc_id"
printf 'MTP\n'     > "$R/socinfo/hw_platform"
printf 'Unknown\n' > "$R/socinfo/platform_subtype"
printf '0\n'       > "$R/socinfo/platform_subtype_id"
printf '0\n'       > "$R/socinfo/platform_version"
printf '7\n'       > "$R/socinfo/ssc_hw_rev"
for f in revision family machine; do
	cp "/sys/devices/soc0/$f" "$R/socinfo/$f"
done

# The SLPI rewrites its registry here (and sns_reg_version one level up), so
# it must be writable by hexagonrpcd. Seed it with this unit's stock registry
# (factory calibration) only if empty; drop sns_reg_version so it re-validates.
if [ -z "$(ls -A "$R/sensors/persist/registry")" ]; then
	cp "$PS"/registry/registry/* "$R/sensors/persist/registry/"
	rm -f "$R/sensors/persist/sns_reg_version"
fi
ln -sfn persist/registry "$R/sensors/registry"
chown -R fastrpc:fastrpc "$R/sensors/persist"
chmod 775 "$R/sensors/persist/registry"
echo "HexagonFS ready at $R ($(ls "$R/sensors/config" | wc -l) configs, $(ls "$R/sensors/persist/registry" | wc -l) registry files)"
