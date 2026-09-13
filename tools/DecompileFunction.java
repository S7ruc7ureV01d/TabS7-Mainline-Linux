// Ghidra headless post-script: decompile a function (given by RVA) and print
// its pseudocode, plus decompile whatever calls IT, recursively up a chain.
// Much more readable than raw capstone disassembly for understanding control
// flow / data sources - use this instead of tools/dump_func.py once you have
// a real function address to look at.
//
// Usage:
//   /opt/ghidra/support/analyzeHeadless /tmp/ghidra_project ablproj \
//       -process LinuxLoader.pe \
//       -postScript DecompileFunction.java <rva_hex> [<rva_hex> ...] \
//       -scriptPath <repo>/tools
//
// Pass one or more RVAs as script args (space-separated hex, with or without
// 0x prefix) - each gets decompiled in turn.

import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionManager;
import ghidra.util.task.ConsoleTaskMonitor;

public class DecompileFunction extends GhidraScript {

    @Override
    protected void run() throws Exception {
        String[] args = getScriptArgs();
        if (args.length == 0) {
            println("Usage: pass one or more RVA hex addresses as script args");
            return;
        }

        Address base = currentProgram.getImageBase();
        FunctionManager fm = currentProgram.getFunctionManager();

        DecompInterface decomp = new DecompInterface();
        decomp.openProgram(currentProgram);

        for (String arg : args) {
            String hex = arg.startsWith("0x") ? arg.substring(2) : arg;
            long rva = Long.parseLong(hex, 16);
            Address target = base.add(rva);

            Function func = fm.getFunctionAt(target);
            if (func == null) {
                func = fm.getFunctionContaining(target);
            }
            if (func == null) {
                println("=== 0x" + hex + ": no function found ===");
                continue;
            }

            println("=== " + func.getName() + " at " + func.getEntryPoint() + " (requested 0x" + hex + ") ===");
            DecompileResults res = decomp.decompileFunction(func, 60, new ConsoleTaskMonitor());
            if (res.decompileCompleted()) {
                println(res.getDecompiledFunction().getC());
            } else {
                println("DECOMPILE FAILED: " + res.getErrorMessage());
            }
            println("");
        }

        decomp.dispose();
    }
}
