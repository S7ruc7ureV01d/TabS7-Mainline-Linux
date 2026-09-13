#!/usr/bin/env python3
"""Find where a PE32+ EFI module's AArch64 code loads a string literal's address.

Locates every ADRP+ADD instruction pair that materializes a given file-offset
address (== RVA, for a typical EFI PE with ImageBase 0 and PointerToRawData ==
VirtualAddress per section) - the standard AArch64 PIC pattern for loading a
string literal's address into a register, so you can find the calling code
around a string found via plain `strings`/grep without a full decompiler.

Setup (local venv, no sudo needed):
    python3 -m venv abl-venv && ./abl-venv/bin/pip install pefile capstone

Usage:
    python3 find_string_refs.py <module.pe> <text_start_hex> <text_end_hex> \
        <label>=<offset_hex> [<label>=<offset_hex> ...]

Example (finding what code references two strings found in a LinuxLoader
PE32 pulled from a Samsung `abl` partition's UEFI Firmware Volume):
    python3 find_string_refs.py section1.pe 0x1000 0xdd000 \
        "No match found for Soc Dtb type"=0xafbb2 \
        "qcom,board-id"=0xaff26

First find text_start/text_end from the section table (e.g. via `pefile`:
`pe.sections` gives VirtualAddress/Misc_VirtualSize for `.text`), and find each
string's file offset with `data.find(b"...")` in Python - see dump_func.py in
this same directory for disassembling the code once you have a hit.
"""
import sys
import capstone


def main():
    if len(sys.argv) < 5:
        print(__doc__)
        sys.exit(1)

    path = sys.argv[1]
    text_start = int(sys.argv[2], 16)
    text_end = int(sys.argv[3], 16)
    targets = {}
    for arg in sys.argv[4:]:
        label, _, off = arg.rpartition("=")
        targets[int(off, 16)] = label

    data = open(path, "rb").read()
    text = data[text_start:text_end]

    md = capstone.Cs(capstone.CS_ARCH_ARM64, capstone.CS_MODE_ARM)
    md.detail = True

    insns = list(md.disasm(text, text_start))
    print(f"Disassembled {len(insns)} instructions from 0x{text_start:x} to 0x{text_end:x}")

    refs = {}
    for i, insn in enumerate(insns):
        if insn.mnemonic != "adrp":
            continue
        try:
            reg = insn.reg_name(insn.operands[0].reg)
            page_val = insn.operands[1].imm
        except Exception:
            continue
        for j in range(i + 1, min(i + 6, len(insns))):
            nxt = insns[j]
            if nxt.mnemonic == "add" and len(nxt.operands) == 3:
                try:
                    src = nxt.reg_name(nxt.operands[1].reg)
                    imm = nxt.operands[2].imm
                except Exception:
                    continue
                if src == reg:
                    full = page_val + imm
                    if full in targets:
                        refs.setdefault(full, []).append((insn.address, nxt.address))
            if nxt.mnemonic == "adrp":
                break

    for t_addr, name in targets.items():
        print(f"\n=== '{name}' @ 0x{t_addr:x} ===")
        for adrp_addr, add_addr in refs.get(t_addr, []):
            print(f"  referenced at ADRP 0x{adrp_addr:x} / ADD 0x{add_addr:x}")


if __name__ == "__main__":
    main()
