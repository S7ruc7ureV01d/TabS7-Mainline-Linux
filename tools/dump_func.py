#!/usr/bin/env python3
"""Disassemble a byte range of a PE32+ EFI module's AArch64 code.

For a typical EFI PE with ImageBase 0 and PointerToRawData == VirtualAddress
per section, a code address is also its file offset - so once
find_string_refs.py (in this same directory) points you at an ADRP/ADD pair,
disassemble the surrounding function with this.

Setup (local venv, no sudo needed):
    python3 -m venv abl-venv && ./abl-venv/bin/pip install pefile capstone

Usage:
    python3 dump_func.py <module.pe> <start_hex> <end_hex>

Example:
    python3 dump_func.py section1.pe 0x25700 0x25a30
"""
import sys
import capstone


def main():
    if len(sys.argv) != 4:
        print(__doc__)
        sys.exit(1)

    path = sys.argv[1]
    start = int(sys.argv[2], 16)
    end = int(sys.argv[3], 16)

    data = open(path, "rb").read()
    chunk = data[start:end]

    md = capstone.Cs(capstone.CS_ARCH_ARM64, capstone.CS_MODE_ARM)
    md.detail = True

    for insn in md.disasm(chunk, start):
        print(f"0x{insn.address:06x}:  {insn.mnemonic}\t{insn.op_str}")


if __name__ == "__main__":
    main()
