# Release builds

| File | Runs on | Does |
|---|---|---|
| `build-release-rootfs.sh` | an aarch64 Arch Linux ARM system, as root (the tablet itself works) | Base tarball + `pacman -Syu` + the port's packages, then strips everything proprietary or specific to one tablet (Samsung firmware, sensor configs and calibration, accounts, keys, identity, caches), enables the login manager and first-boot wizard, and writes `rootfs.img` (ext4, label `archroot`). |
| `make-installer-zip.py` | any machine with Python 3 | Packs `boot.img`, `rootfs.img` and `installer/update-binary` into the TWRP ZIP, with SHA-256 manifests. |
| `installer/update-binary` | TWRP | Reads this tablet's firmware and calibration (apnhlos, vendor, persist, sec_efs, efs, cmdline) *before* writing anything, writes and verifies the system on userdata and the kernel on boot, then installs the tablet's own data into the new system. |
| `rootfs-files/` | | Files added to the image (first-boot filesystem growth). |

Typical run (on the tablet):

```
build-release-rootfs.sh archroot-rootfs-vNN.tar pkgs/ <repo> out/
python3 make-installer-zip.py boot.img out/rootfs.img /path/on/microsd/installer.zip --version "..."
```

`pkgs/` holds the packages built from `tools/rootfs/` (`setup/plasma-setup`,
`setup/gts7l-setup`, `keyboards/*`). The ZIP must be flashed from microSD or
USB-OTG: it erases internal storage.
