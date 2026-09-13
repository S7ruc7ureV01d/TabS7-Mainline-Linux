// Ghidra headless post-script (compiled Java GhidraScript - works without the
// PyGhidra Python bridge, unlike a plain .py script in recent Ghidra).
//
// Finds the "Board Dtb" matching function (identified by file offset in prior
// capstone-based analysis - see tools/find_string_refs.py / tools/dump_func.py)
// and prints every reference TO it (direct calls, and any data/vtable
// reference), using Ghidra's real cross-reference database instead of plain
// linear disassembly - resolves indirect/computed calls plain disassembly
// can't see.
//
// Usage:
//   /opt/ghidra/support/analyzeHeadless /tmp/ghidra_project ablproj \
//       -import <path-to-LinuxLoader.pe> \
//       -postScript FindBoardDtbCallers.java \
//       -scriptPath <repo>/tools
//
// RVA_TARGET below is the file-offset/RVA of the function's first instruction
// (0x26744, the "Board Dtb" candidate-matching function per
// docs/kernel-boot-debugging.md Round 9) - adjust for other targets.

import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionManager;
import ghidra.program.model.symbol.Reference;
import ghidra.program.model.symbol.ReferenceIterator;
import ghidra.program.model.symbol.ReferenceManager;

public class FindBoardDtbCallers extends GhidraScript {

    static final long RVA_TARGET = 0x263c8L;

    @Override
    protected void run() throws Exception {
        Address base = currentProgram.getImageBase();
        println("Image base: " + base);

        Address target = base.add(RVA_TARGET);
        println("Target address (base + 0x" + Long.toHexString(RVA_TARGET) + "): " + target);

        FunctionManager fm = currentProgram.getFunctionManager();
        Function func = fm.getFunctionAt(target);
        if (func == null) {
            println("WARNING: no function defined at target address - checking containing function");
            func = fm.getFunctionContaining(target);
            if (func != null) {
                println("Containing function: " + func.getName() + " at " + func.getEntryPoint());
            }
        } else {
            println("Function: " + func.getName() + " at " + func.getEntryPoint());
        }

        println("");
        println("=== References TO 0x" + Long.toHexString(RVA_TARGET) + " ===");
        ReferenceManager refMgr = currentProgram.getReferenceManager();
        ReferenceIterator refs = refMgr.getReferencesTo(target);
        int count = 0;
        for (Reference ref : refs) {
            count++;
            Address from = ref.getFromAddress();
            Function containing = fm.getFunctionContaining(from);
            String containingName = containing != null ? containing.getName() : "?";
            println("  from " + from + " (in function " + containingName + ") type=" + ref.getReferenceType());
        }

        if (count == 0) {
            println("  (none found by Ghidra either - genuinely no static reference exists)");
            println("  Checking nearby addresses (+/- 0x20) for an off-by-a-few-bytes function start:");
            for (long delta = -0x20; delta <= 0x20; delta += 4) {
                Address addr = target.add(delta);
                ReferenceIterator nearby = refMgr.getReferencesTo(addr);
                for (Reference ref : nearby) {
                    println("  [delta 0x" + Long.toHexString(delta) + "] from " + ref.getFromAddress()
                            + " type=" + ref.getReferenceType());
                }
            }
        }

        println("");
        println("=== Done ===");
    }
}
