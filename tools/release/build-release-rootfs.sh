#!/bin/bash
# Build the release root filesystem image for the installer ZIP.
# Runs as root on an aarch64 Arch Linux ARM system (e.g. the tablet itself).
#
#   build-release-rootfs.sh BASE.tar PKGDIR REPO OUTDIR
#
#   BASE.tar  the latest rootfs tarball (work/archroot-build/archroot-rootfs-vNN.tar)
#   PKGDIR    built packages from tools/rootfs/ (plasma-setup, gts7l-setup,
#             python-uinput, vboard, plasma-keyboard-floating, gts7l-keyboards)
#   REPO      a checkout of this repository
#   OUTDIR    where rootfs.img and manifest.txt are written
#
# The image carries no proprietary firmware and nothing specific to one
# tablet: the installer copies those from the target's own partitions.
set -euo pipefail

BASE=${1:?base tarball}; PKGDIR=${2:?package dir}; REPO=${3:?repo}; OUT=${4:?out dir}
mkdir -p "$OUT"
OUT=$(realpath "$OUT"); BASE=$(realpath "$BASE"); PKGDIR=$(realpath "$PKGDIR"); REPO=$(realpath "$REPO")
R=$OUT/root
[ -e "$R" ] && { echo "$R exists, remove it first" >&2; exit 1; }
mkdir -p "$R"

echo "== unpacking $BASE"
bsdtar --xattrs --numeric-owner -xpf "$BASE" -C "$R"

mounts() {
	mount -t proc proc "$R/proc"; mount -t sysfs sys "$R/sys"
	mount --rbind /dev "$R/dev"; mount -t tmpfs tmpfs "$R/run"
	mount -t tmpfs tmpfs "$R/tmp"
	cp -L /etc/resolv.conf "$R/etc/resolv.conf.build"
	mount --bind "$R/etc/resolv.conf.build" "$R/etc/resolv.conf" 2>/dev/null || true
}
umounts() {
	umount "$R/etc/resolv.conf" 2>/dev/null || true; rm -f "$R/etc/resolv.conf.build"
	umount -R "$R/dev" "$R/proc" "$R/sys" "$R/run" "$R/tmp" 2>/dev/null || true
}
trap umounts EXIT
mounts

echo "== packages: update, then add the release packages"
pacman --sysroot "$R" -Syu --noconfirm
pacman --sysroot "$R" -U --noconfirm --needed "$PKGDIR"/*.pkg.tar.*
pacman --sysroot "$R" -Rdd --noconfirm vboard-git 2>/dev/null || true

echo "== port files"
T=$REPO/tools/rootfs
install -Dm755 "$T/bluetooth/gts7l-bt-address" "$R/usr/local/bin/gts7l-bt-address"
install -Dm644 "$T/bluetooth/gts7l-bt-address.service" "$R/etc/systemd/system/gts7l-bt-address.service"
install -Dm644 "$REPO/tools/release/rootfs-files/gts7l-growroot.service" "$R/etc/systemd/system/gts7l-growroot.service"
install -Dm755 "$T/wine/install-hangover.sh" "$R/usr/local/lib/gts7l/install-hangover.sh"

echo "== accounts: no default user, root locked (the setup wizard creates the user)"
if grep -q '^alarm:' "$R/etc/passwd"; then
	userdel --root "$R" -r alarm 2>/dev/null || userdel --root "$R" alarm
	rm -rf "$R/home/alarm"
fi
usermod --root "$R" -p '!*' root
rm -rf "$R/root/.ssh" "$R/root/stock-firmware-dump" "$R/root/.bash_history" "$R/root/.cache"
rm -f "$R"/etc/ssh/ssh_host_*

echo "== proprietary and per-device data out (the installer adds the target's own)"
rm -rf "$R/usr/lib/firmware/qcom/sm8250/samsung"
rm -f "$R"/usr/lib/firmware/cirrus/cs35l41-dsp1-spk-prot-gts7l.* "$R"/usr/lib/firmware/cirrus/cs35l41-cal-*
# HexagonFS: the sensor configs (vendor) and the factory registry (persist)
# come from the target; socinfo/ is generic SoC data and stays, except the
# board revision, which the installer reads from the target's cmdline.
rm -rf "$R/usr/share/qcom/sm8250/Samsung/gts7l/sensors"
rm -f "$R/usr/share/qcom/sm8250/Samsung/gts7l/socinfo/ssc_hw_rev"
rm -rf "$R/etc/gts7l"

echo "== identity, caches, logs"
: > "$R/etc/machine-id"
rm -f "$R/etc/hostname" "$R/var/lib/dbus/machine-id" "$R/var/lib/systemd/random-seed"
rm -f "$R"/etc/NetworkManager/system-connections/*
rm -rf "$R"/var/cache/pacman/pkg/* "$R"/var/log/journal/* "$R"/var/tmp/*
: > "$R/var/log/pacman.log"
for f in btmp lastlog wtmp; do : > "$R/var/log/$f"; done

echo "== services"
rm -f "$R/etc/systemd/system/plasma-autologin.service" \
      "$R/etc/systemd/system/graphical.target.wants/plasma-autologin.service"
systemctl --root "$R" enable plasmalogin.service plasma-setup.service \
	gts7l-bt-address.service gts7l-growroot.service
systemctl --root "$R" disable sshd.service 2>/dev/null || true
# The installer writes a new machine-id, so systemd never sees a "first
# boot" (that would apply Arch's presets, e.g. re-enable systemd-networkd);
# and nothing may prompt on the console: the setup wizard asks instead.
systemctl --root "$R" mask systemd-firstboot.service
systemctl --root "$R" set-default graphical.target

umounts
trap - EXIT

echo "== image"
used=$(du -sxm "$R" | cut -f1)
size=$(( used * 125 / 100 + 1024 ))
rm -f "$OUT/rootfs.img"
mkfs.ext4 -q -L archroot -m 1 -d "$R" "$OUT/rootfs.img" "${size}M"
e2fsck -fy "$OUT/rootfs.img" >/dev/null || true
{
	echo "built $(date -u +%FT%TZ) from $(basename "$BASE")"
	echo "image ${size} MiB, content ${used} MiB"
	pacman --root "$R" -Q
} > "$OUT/manifest.txt"
sha256sum "$OUT/rootfs.img" | tee -a "$OUT/manifest.txt"
echo "== done: $OUT/rootfs.img"
