#!/usr/bin/env python3
"""Build the TWRP installer ZIP.

    make-installer-zip.py BOOT.img ROOTFS.img OUT.zip [--version TEXT]

boot.img and rootfs.img are stored with their SHA-256 and size in MiB
(BOOT-IMAGE / ROOTFS-IMAGE): the installer verifies what it wrote, and
TWRP's shell can only count in MiB. Both images must be whole MiB.
rootfs.img is stored in CHUNK_MIB pieces (rootfs.img.000, ...): TWRP's
unzip (AOSP ziptool) aborts on an entry of several GiB.
"""
import argparse, hashlib, shutil, stat, zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
CHUNK_MIB = 1024


def info(name, mode=0o644):
    i = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
    i.create_system = 3
    i.external_attr = (stat.S_IFREG | mode) << 16
    i.compress_type = zipfile.ZIP_DEFLATED
    return i


def manifest(path):
    size = path.stat().st_size
    if size % (1024 * 1024):
        raise SystemExit(f"{path} is {size} bytes, not whole MiB")
    h = hashlib.sha256()
    with path.open('rb') as f:
        for chunk in iter(lambda: f.read(8 << 20), b''):
            h.update(chunk)
    return f"{h.hexdigest()} {size} {size // (1024 * 1024)}\n"


def add_pieces(zf, src, name):
    """Store src as name.000, name.001, ... of CHUNK_MIB each; returns the count."""
    chunk = CHUNK_MIB * 1024 * 1024
    n = 0
    with src.open('rb') as s:
        while True:
            left = chunk
            data = s.read(min(8 << 20, left))
            if not data:
                break
            with zf.open(info(f'{name}.{n:03d}'), 'w', force_zip64=True) as d:
                while data:
                    d.write(data)
                    left -= len(data)
                    data = s.read(min(8 << 20, left)) if left else b''
            n += 1
    return n


def add(zf, src, name, mode=0o644):
    with src.open('rb') as s, zf.open(info(name, mode), 'w', force_zip64=True) as d:
        shutil.copyfileobj(s, d, 8 << 20)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('boot', type=Path)
    ap.add_argument('rootfs', type=Path)
    ap.add_argument('out', type=Path)
    ap.add_argument('--version', default='development build')
    a = ap.parse_args()
    with zipfile.ZipFile(a.out, 'w', compresslevel=6) as zf:
        add(zf, HERE / 'installer/update-binary', 'META-INF/com/google/android/update-binary', 0o755)
        zf.writestr(info('META-INF/com/google/android/updater-script'), '#gts7l installer\n')
        zf.writestr(info('VERSION'), a.version + '\n')
        zf.writestr(info('BOOT-IMAGE'), manifest(a.boot))
        zf.writestr(info('BANNER'), (HERE / 'installer/banner.txt').read_text())
        add(zf, a.boot, 'boot.img')
        parts = add_pieces(zf, a.rootfs, 'rootfs.img')
        zf.writestr(info('ROOTFS-IMAGE'),
                    manifest(a.rootfs).rstrip('\n') + f' {parts} {CHUNK_MIB}\n')
    print(a.out, a.out.stat().st_size // (1024 * 1024), 'MiB')


if __name__ == '__main__':
    main()
