// Ghidra headless post-script: print a function's real address range (entry
// point through highest instruction address) and whether a given RVA falls
// within it - useful for sanity-checking function-boundary assumptions before
// trusting a decompilation or reference-search result.
//
// Usage:
//   analyzeHeadless ... -postScript FunctionBounds.java <func_rva_hex> <check_rva_hex>

import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.address.AddressSetView;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionManager;

public class FunctionBounds extends GhidraScript {
    @Override
    protected void run() throws Exception {
        String[] args = getScriptArgs();
        Address base = currentProgram.getImageBase();
        FunctionManager fm = currentProgram.getFunctionManager();

        long funcRva = Long.parseLong(args[0].replace("0x", ""), 16);
        Address funcAddr = base.add(funcRva);
        Function func = fm.getFunctionAt(funcAddr);
        if (func == null) {
            println("No function at " + funcAddr);
            return;
        }
        println("Function: " + func.getName() + " entry=" + func.getEntryPoint());
        AddressSetView body = func.getBody();
        println("Body min=" + body.getMinAddress() + " max=" + body.getMaxAddress());
        println("Num address ranges: " + body.getNumAddressRanges());

        if (args.length > 1) {
            long checkRva = Long.parseLong(args[1].replace("0x", ""), 16);
            Address checkAddr = base.add(checkRva);
            println("Check address " + checkAddr + " contained: " + body.contains(checkAddr));
        }
    }
}
