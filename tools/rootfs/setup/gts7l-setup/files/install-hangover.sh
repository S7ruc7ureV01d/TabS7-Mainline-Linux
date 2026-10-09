#!/bin/bash
# Wine for x86/x64 Windows programs on the gts7l (Arch Linux ARM, aarch64):
# Hangover (Wine + FEX/Box64 emulation) from its Debian 13 release, unpacked
# to /opt/hangover (Wine is relocatable; there is no Arch package).
#
#   x86-64 .exe  -> ARM64EC + FEX   (libarm64ecfex.dll, the default)
#   i386 .exe    -> WoW64 + Box64   (wowbox64.dll, the default) or FEX with
#                   HODLL=libwow64fex.dll
#
# Run as root. Each user's prefix (~/.wine) is created on the first `wine`
# run; it needs the 32-bit emulator present at that moment, or syswow64
# stays empty and every 32-bit program fails with "could not load
# kernel32.dll" (then: rm -rf ~/.wine and run wine again).
#
# Not usable from the Debian build on Arch: gphoto2/sane (cameras/scanners)
# and winedmo (links ffmpeg 7 sonames; Arch has ffmpeg 8).
set -euo pipefail

VER=11.16
URL=https://github.com/AndreRH/hangover/releases/download/hangover-$VER/hangover_${VER}_debian13_trixie_arm64.tar
WORK=/var/tmp/hangover-$VER

mkdir -p "$WORK"
cd "$WORK"
[ -f h.tar ] || curl -fL -o h.tar "$URL"
tar xf h.tar

rm -rf /opt/hangover
mkdir -p /opt/hangover
for deb in hangover-wine_*.deb hangover-libarm64ecfex_*.deb \
	   hangover-libwow64fex_*.deb hangover-wowbox64_*.deb; do
	d=$(mktemp -d)
	(cd "$d" && bsdtar xf "$WORK/$deb" && bsdtar xf data.tar.*)
	cp -a "$d/usr/." /opt/hangover/
	rm -rf "$d"
done
# DXVK (x64/x32/arm64ec builds) is kept next to it for prefixes that want it
cp dxvk-*.tar.gz /opt/hangover/share/

for b in wine wineserver winecfg wineboot winedbg winefile wineconsole \
	 winepath msiexec regedit regsvr32 notepad winemine; do
	ln -sf /opt/hangover/bin/$b /usr/local/bin/$b
done

# .exe/.msi open with Wine from the file manager
mkdir -p /usr/local/share/applications
cp /opt/hangover/share/applications/wine.desktop /usr/local/share/applications/
update-desktop-database /usr/local/share/applications || true

echo "Hangover $VER installed in /opt/hangover"
