#!/bin/bash
# gts7l Phase 5 debug access: USB Ethernet (ECM) gadget, brought up early
# so the host can reach this system over SSH even with no WiFi (Phase 3
# not done yet) and no USB-OTG host mode for a keyboard. Static IPs on a
# private link, no DHCP needed.
set -e

# The bring-up initramfs's own ACM console gadget (kernel/initramfs/init)
# is still bound to the UDC at this point - switch_root doesn't tear
# down configfs state, since /sys/kernel/config is a kernel-internal
# filesystem independent of which root is currently mounted. A UDC can
# only have one gadget bound at a time, so unbind whatever's already
# there first (real failure hit on hardware: "g_ecm couldn't find an
# available UDC or it's busy").
for g in /sys/kernel/config/usb_gadget/*/; do
	[ -e "${g}UDC" ] && echo "" > "${g}UDC" 2>/dev/null || true
done

G=/sys/kernel/config/usb_gadget/g_ecm
mkdir -p "$G"
cd "$G"

echo 0x1d6b > idVendor
echo 0x0105 > idProduct
mkdir -p strings/0x409
echo "gts7l-arch-000000" > strings/0x409/serialnumber
echo "UbuntuTabS7 project" > strings/0x409/manufacturer
echo "gts7l Arch debug network" > strings/0x409/product

mkdir -p configs/c.1/strings/0x409
echo "ECM debug network" > configs/c.1/strings/0x409/configuration
echo 120 > configs/c.1/MaxPower

mkdir -p functions/ecm.usb0
# Locally-administered MAC addresses (the "02" high bit) - device and
# host sides must differ.
# (EBUSY once the function is linked into the config: already set then)
echo "02:00:00:00:00:01" > functions/ecm.usb0/host_addr 2>/dev/null || true
echo "02:00:00:00:00:02" > functions/ecm.usb0/dev_addr 2>/dev/null || true

[ -e configs/c.1/ecm.usb0 ] || ln -s functions/ecm.usb0 configs/c.1/

UDC=$(ls /sys/class/udc | head -1)
# Binding fails (ENODEV) while dwc3 is in host mode, e.g. a monitor or USB
# device on the port at boot. Then retry in the background until the port
# goes to device mode (a PC plugged in), instead of never binding
# (usb-gadget-ecm-wait.service runs this script with --wait).
if [ "${1:-}" = --wait ]; then
	# The UDC may not even be registered yet at boot: look it up each time
	until UDC=$(ls /sys/class/udc | head -1) && [ -n "$UDC" ] &&
	      echo "$UDC" > UDC 2>/dev/null; do
		sleep 2
	done
elif [ -z "$UDC" ] || ! echo "$UDC" > UDC 2>/dev/null; then
	echo "UDC '$UDC' missing or not in device mode yet, binding later"
	systemctl --no-block start usb-gadget-ecm-wait.service
	exit 0
fi

# Wait for usb0 to appear, then bring it up with a static IP.
for i in $(seq 1 50); do
	[ -e /sys/class/net/usb0 ] && break
	sleep 0.1
done

ip addr add 172.16.42.1/24 dev usb0
ip link set usb0 up

# The host shares its own internet connection over this link (NAT/
# MASQUERADE set up on the host side, ip_forward enabled there) - real
# Wi-Fi (Phase 3) isn't done yet, but this gets pacman and friends
# working directly on-device in the meantime. Only added once the host
# side is actually up (172.16.42.2 = the host), so this is a no-op and
# harmless on a boot where the debug cable isn't plugged in at all.
if ping -c 1 -W 1 172.16.42.2 >/dev/null 2>&1; then
	ip route replace default via 172.16.42.2 dev usb0
	echo "nameserver 1.1.1.1" > /etc/resolv.conf
fi
