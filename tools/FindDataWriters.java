// Ghidra headless post-script: find every reference TO a data address (an RVA
// into the file's data/bss), and for each referencing instruction, print
// which function it's in and the surrounding decompiled context by showing
// the function's decompilation once per unique containing function.
//
// Usage:
//   analyzeHeadless ... -postScript FindDataWriters.java <data_rva_hex>

import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionManager;
import ghidra.program.model.symbol.Reference;
import ghidra.program.model.symbol.ReferenceIterator;
import ghidra.program.model.symbol.ReferenceManager;
import ghidra.util.task.ConsoleTaskMonitor;

import java.util.LinkedHashSet;
import java.util.Set;

public class FindDataWriters extends GhidraScript {
    @Override
    protected void run() throws Exception {
        String[] args = getScriptArgs();
        long dataRva = Long.parseLong(args[0].replace("0x", ""), 16);
        Address base = currentProgram.getImageBase();
        Address target = base.add(dataRva);

        FunctionManager fm = currentProgram.getFunctionManager();
        ReferenceManager refMgr = currentProgram.getReferenceManager();

        println("=== References to data 0x" + Long.toHexString(dataRva) + " (" + target + ") ===");
        ReferenceIterator refs = refMgr.getReferencesTo(target);
        Set<Function> containingFuncs = new LinkedHashSet<>();
        for (Reference ref : refs) {
            Address from = ref.getFromAddress();
            Function containing = fm.getFunctionContaining(from);
            String name = containing != null ? containing.getName() : "?";
            println("  from " + from + " (in " + name + ") type=" + ref.getReferenceType());
            if (containing != null) {
                containingFuncs.add(containing);
            }
        }

        println("");
        println("=== Decompiling each unique containing function ===");
        DecompInterface decomp = new DecompInterface();
        decomp.openProgram(currentProgram);
        for (Function f : containingFuncs) {
            println("--- " + f.getName() + " at " + f.getEntryPoint() + " ---");
            DecompileResults res = decomp.decompileFunction(f, 60, new ConsoleTaskMonitor());
            if (res.decompileCompleted()) {
                println(res.getDecompiledFunction().getC());
            } else {
                println("DECOMPILE FAILED: " + res.getErrorMessage());
            }
        }
        decomp.dispose();
    }
}
