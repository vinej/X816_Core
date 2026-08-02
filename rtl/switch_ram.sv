//============================================================================
// switch_ram.sv  --  the 256 KB block that is either VERA's VRAM or the CPU's
//                    banks $01-$04.
//
// doc/BRAM_SWITCH.md is the plan this implements.  In FAST mode (the default)
// the CPU owns it and banks $01-$04 become single-cycle BRAM; in VIDEO mode
// VERA owns it and VRAM becomes 384 KB.  Which one is an OSD option and
// CHANGING IT IS A FULL COLD BOOT, so `fast_mode` is constant for the entire
// life of a configuration -- there is no runtime switching to design against
// and no mid-access hazard.
//
// WHY IT KEEPS VERA'S NIBBLE ORGANISATION
//
// Eight 4-bit lanes forming a 32-bit word, exactly like main_ram.v, because in
// VIDEO mode this IS VRAM and VERA FX needs 4-bit write enables.  It costs
// ~20% packing efficiency -- M10K x4 mode uses 4 of its 5 bits -- so 256 KB is
// 256 M10K blocks rather than the ~205 a byte-wide array would take.  That is
// not recoverable: a byte-organised block would pack better and could not
// serve VERA at all.
//
// The CPU therefore addresses a byte as two nibbles of a word: addr[17:2]
// picks the word and addr[1:0] picks the byte lane within it.
//
// WHY TRUE DUAL PORT RATHER THAN A MUXED SINGLE PORT
//
// The two owners live in different clock domains -- VERA in pix_clk, the CPU
// in cpu_clk -- so a single-port array would need its CLOCK muxed by the mode.
// Gating a clock feeding BRAM is a bad idea for reasons that show up as
// timing violations and inference failures rather than as anything obvious,
// so each owner gets its own port on its own clock and the mode gates the
// ENABLES instead.  Only one port is ever active in a given configuration.
//
// The mode gating is a safety property, not an optimisation: it is what makes
// a stray VERA write in FAST mode -- or a stray CPU write in VIDEO mode --
// unable to corrupt the other owner's memory.  sim/tb_switch_ram.v tests
// exactly that, in both directions.
//
// WHY THE MEMORY IS INSTANTIATED AND NOT INFERRED
//
// An earlier version of this file described the arrays in behavioural Verilog
// the way main_ram.v does, and Quartus REFUSED TO INFER THEM:
//
//     Error (276003): Cannot convert all sets of registers into RAM
//     megafunctions ... the resulting number of registers ... exceeds the
//     number of registers in the device
//
// It fell back to flip-flops -- 262,144 of them for a 32 KB probe, against a
// device with about 84,000 -- and the compile died in 28 seconds.
//
// main_ram.v gets away with inference because it is SINGLE PORT.  This is
// true dual port, on TWO DIFFERENT CLOCKS, with both ports writing, and
// Quartus's inference templates do not cover that shape: they want an
// explicit read-during-write if/else, and for unrelated clocks they generally
// decline regardless.
//
// So the primitive is instantiated directly.  altsyncram in BIDIR_DUAL_PORT
// mode with clock0/clock1 is exactly this memory, it is the same megafunction
// Quartus was trying to convert the arrays INTO, and it either compiles or
// says why -- there is no pattern-matcher to second-guess.  The MiSTer
// framework instantiates altsyncram directly for the same reason.
//
// EIGHT INSTANCES, NOT ONE, and that is not a style choice: altsyncram's byte
// enables are 8- or 9-bit granular, VERA FX needs FOUR-bit write enables, and
// the only way to get them is one array per nibble.  main_ram.v reached the
// same conclusion and says so.
//============================================================================
`default_nettype none

module switch_ram #(
    // 65,536 words x 32 bits = 256 KB.  Overridable so a testbench can use a
    // small array instead of simulating a quarter of a megabyte.
    parameter WORDS = 65536,
    parameter AWIDTH = 16
) (
    input  wire               fast_mode,   // 1 = the CPU owns it (default)

    // ---- VERA side: the same shape as main_ram.v, active in VIDEO mode ----
    input  wire               vera_clk,
    input  wire [AWIDTH-1:0]  vera_addr,   // word address
    input  wire [31:0]        vera_wrdata,
    input  wire [7:0]         vera_wrnibblesel,
    input  wire               vera_write,
    output wire [31:0]        vera_rddata,

    // ---- CPU side: byte addressed, active in FAST mode --------------------
    input  wire               cpu_clk,
    input  wire               cpu_cs,
    input  wire               cpu_we,
    input  wire [AWIDTH+1:0]  cpu_addr,    // byte address within the block
    input  wire [7:0]         cpu_wrdata,
    output wire [7:0]         cpu_rddata
);

    // ---- the eight nibble lanes ------------------------------------------
    // Port A is VERA's (vera_clk), port B is the CPU's (cpu_clk).  Each is
    // gated by the mode, which is what stops either owner reaching the other's
    // memory -- the property sim/tb_switch_ram.v checks in both directions.
    wire        vera_en = ~fast_mode;
    wire [7:0]  vera_we = {8{vera_en & vera_write}} & vera_wrnibblesel;

    wire [AWIDTH-1:0] cpu_word = cpu_addr[AWIDTH+1:2];
    wire [1:0]        cpu_lane = cpu_addr[1:0];
    wire              cpu_wr   = fast_mode & cpu_cs & cpu_we;

    wire [3:0] vera_q [0:7];
    wire [3:0] cpu_q  [0:7];

    genvar i;
    generate
        for (i = 0; i < 8; i = i + 1) begin : lane
            // The CPU writes a byte as two adjacent nibbles: lanes 2b and
            // 2b+1 belong to byte b, so addr[1:0] selects the pair.
            wire cpu_lane_hit = (cpu_lane == i[2:1]);
            wire [3:0] cpu_nib = i[0] ? cpu_wrdata[7:4] : cpu_wrdata[3:0];

            altsyncram #(
                .operation_mode                     ("BIDIR_DUAL_PORT"),
                .ram_block_type                     ("M10K"),
                .width_a                            (4),
                .widthad_a                          (AWIDTH),
                .numwords_a                         (WORDS),
                .width_b                            (4),
                .widthad_b                          (AWIDTH),
                .numwords_b                         (WORDS),
                .width_byteena_a                    (1),
                .width_byteena_b                    (1),
                // Address registered, data out not: one clock of latency,
                // the same shape a `q <= ram[addr]` description gives.
                .outdata_reg_a                      ("UNREGISTERED"),
                .outdata_reg_b                      ("UNREGISTERED"),
                .indata_reg_b                       ("CLOCK1"),
                .address_reg_b                      ("CLOCK1"),
                .wrcontrol_wraddress_reg_b          ("CLOCK1"),
                // The two ports are never active in the same mode, so there is
                // no simultaneous access to define behaviour for.
                .read_during_write_mode_mixed_ports ("DONT_CARE"),
                .lpm_type                           ("altsyncram")
            ) u_lane (
                .clock0    (vera_clk),
                .address_a (vera_addr),
                .data_a    (vera_wrdata[i*4 +: 4]),
                .wren_a    (vera_we[i]),
                .q_a       (vera_q[i]),

                .clock1    (cpu_clk),
                .address_b (cpu_word),
                .data_b    (cpu_nib),
                .wren_b    (cpu_wr & cpu_lane_hit),
                .q_b       (cpu_q[i]),

                .aclr0(1'b0), .aclr1(1'b0),
                .addressstall_a(1'b0), .addressstall_b(1'b0),
                .byteena_a(1'b1), .byteena_b(1'b1),
                .clocken0(1'b1), .clocken1(1'b1),
                .clocken2(1'b1), .clocken3(1'b1),
                .eccstatus(), .rden_a(1'b1), .rden_b(1'b1)
            );

            assign vera_rddata[i*4 +: 4] = vera_q[i];
        end
    endgenerate

    // The lane select is registered alongside the data so the read mux uses
    // the lane belonging to THIS result rather than whatever address arrived
    // while it was in flight.
    reg [1:0] cpu_lane_q;
    always @(posedge cpu_clk) cpu_lane_q <= cpu_lane;

    assign cpu_rddata = (cpu_lane_q == 2'd0) ? {cpu_q[1], cpu_q[0]}
                      : (cpu_lane_q == 2'd1) ? {cpu_q[3], cpu_q[2]}
                      : (cpu_lane_q == 2'd2) ? {cpu_q[5], cpu_q[4]}
                                             : {cpu_q[7], cpu_q[6]};

endmodule

`default_nettype wire
