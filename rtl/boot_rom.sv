//============================================================================
// boot_rom.sv  --  256-byte boot ROM overlay at $00:FF00-$00:FFFF.
//
// WHY THIS EXISTS AT ALL.
// A flat-model machine wants no ROM in its address space.  It gets one anyway,
// for exactly one reason: the 65816 always comes out of RESET in EMULATION
// mode (E=1) and always fetches its reset vector from $00FFFC.  That is
// silicon behaviour -- there is no native reset vector and no pin that changes
// it.  Something at the top of bank 0 must therefore be non-volatile and must
// contain a vector plus the `CLC / XCE` that enters native mode.  256 bytes is
// the smallest window that covers the whole vector region:
//
//     $FFE4-$FFEF   native-mode vectors  (COP, BRK, ABORT, NMI, --, IRQ)
//     $FFF4-$FFFF   emulation vectors    (COP, --, ABORT, NMI, RESET, IRQ)
//
// THE OVERLAY IS TEMPORARY.  SYSCTL bit 0 ($00:9F80) powers up set, mapping
// this ROM over bank-0 RAM for READS only.  Writes to $FF00-$FFFF always go to
// the RAM underneath (see bank0_ram.sv), so the boot stub can build its real
// native vector table in RAM and then clear SYSCTL bit 0 -- from that point
// bank 0 is 64 KB of uniform RAM and the machine is genuinely flat, with its
// vectors in RAM the way a real 65816 system runs them.
//
// CONTENTS come from boot/boot.hex (256 lines, one hex byte per line),
// assembled from boot/boot.s -- see boot/build.sh.  The file is committed so a
// bare `quartus_sh --flow compile` works with no toolchain installed; the HPS
// download path can overwrite bank 0 at runtime for everything beyond the stub.
//
// Same negedge-read convention as bank0_ram.sv so the two mux cleanly.
// ============================================================================
module boot_rom (
    input  logic       clk,
    input  logic [7:0] addr,        // offset within $FF00-$FFFF
    output logic [7:0] rd_data
);

    (* ramstyle = "M10K" *) logic [7:0] mem [0:255];

    initial $readmemh("boot/boot.hex", mem);

    always_ff @(negedge clk) begin
        rd_data <= mem[addr];
    end

endmodule
