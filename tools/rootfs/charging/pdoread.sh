#!/bin/sh
# Read-only: when a PD contract is ready (PD_STATUS1 PSRDY), ask the MAX77705
# CCIC for the source's PDO list with OPCODE_CURRENT_SRCCAP (0x30) and log
# the raw reply from 0x51. Does not select a PDO; VBUS is untouched.
OUT=/root/pdoread-$(date +%H%M%S).log
end=$(( $(date +%s) + ${1:-150} ))
g() { i2cget -f -y 0 0x25 $1 2>/dev/null; }
echo "start $(date +%T)" > $OUT
done_once=0
while [ $(date +%s) -lt $end ]; do
	pd1=$(g 0x0d); bc=$(g 0x08); st1=$(g 0x06)
	if [ -n "$pd1" ] && [ $(( pd1 & 0x10 )) -ne 0 ] && [ $(( bc & 0x80 )) -ne 0 ] && [ "$bc" != "0x81" ]; then
		sleep 1
		echo "$(date +%T) PSRDY: PD_STATUS0=$(g 0x0c) PD_STATUS1=$(g 0x0d) BC=$(g 0x08) CC0=$(g 0x0a) ST1=$(g 0x06)" >> $OUT
		i2cset -f -y 0 0x25 0x21 0x30 && i2cset -f -y 0 0x25 0x41 0x00
		sleep 0.5
		r=""; for i in $(seq 0 32); do r="$r $(g $(printf 0x%02x $((0x51 + i))) | cut -c3-)"; done
		echo "$(date +%T) reply 0x51..:$r" >> $OUT
		echo "$(date +%T) after: PD_STATUS0=$(g 0x0c) PD_STATUS1=$(g 0x0d) ST1=$(g 0x06) UIC_INT=$(g 0x02)" >> $OUT
		done_once=1
		break
	fi
	sleep 0.3
done
[ $done_once = 1 ] || echo "no PD contract seen" >> $OUT
echo "end $(date +%T)" >> $OUT
