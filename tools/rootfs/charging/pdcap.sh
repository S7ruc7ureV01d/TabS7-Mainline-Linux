#!/bin/sh
# Read-only capture of a charger plug event (docs/phase3-typec-muic-scoping.md).
# Charger regmap (0-0069, offsets from 0xB0): 02 INT_OK, 03 DETAILS_00,
# 04 DETAILS_01, 05 DETAILS_02, 10 CNFG_09. CCIC at 0x25 (no driver):
# 06 USBC_STATUS1 (VBADC[7:4]), 07 USBC_STATUS2, 08 BC_STATUS, 0a CC_STATUS0,
# 0b CC_STATUS1, 0c PD_STATUS0, 0d PD_STATUS1.
D=${1:-90}
OUT=/root/pdcap-$(date +%H%M%S).log
R=/sys/kernel/debug/regmap/0-0069/registers
dmesg -w > $OUT.dmesg 2>&1 & DM=$!
end=$(( $(date +%s) + D ))
echo "time chg[INT_OK DTLS00 DTLS01 DTLS02 CNFG09] usbc[ST1 ST2 BC CC0 CC1 PD0 PD1] online ilim_mA chg_mA | bat_mA bat_status therm_mC" > $OUT
T=$(ls /sys/bus/iio/devices/iio:device*/in_temp_batt_therm_input 2>/dev/null | head -1)
C=/sys/class/power_supply/max77705-charger; B=/sys/class/power_supply/max170xx_battery
while [ $(date +%s) -lt $end ]; do
	c=$(awk '/^0[2345]:|^10:/{printf "%s ", $2}' $R)
	u=""; for r in 0x06 0x07 0x08 0x0a 0x0b 0x0c 0x0d; do u="$u$(i2cget -f -y 0 0x25 $r 2>/dev/null | cut -c3-) "; done
	echo "$(date +%T.%N | cut -c1-12) $c| $u| $(cat $C/online) $(( $(cat $C/input_current_limit)/1000 )) $(( $(cat $C/constant_charge_current)/1000 )) | $(( $(cat $B/current_now)/1000 )) $(cat $B/status) $(cat $T 2>/dev/null)" >> $OUT
	sleep 0.15
done
kill $DM
echo "done: $OUT"
