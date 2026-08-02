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
// SYNTHESIS IS THE GATE, NOT SIMULATION.  main_ram.v's header lists what
// Quartus needs to pack an array into M10K, and the one rule this file has to
// break is "one always block per lane" -- true dual port needs two.  That is
// the standard dual-port idiom and should infer, but it must be CONFIRMED
// from the fit report before the design is believed: if these arrays land in
// ALMs instead the design grows by tens of thousands of LEs and the whole
// plan is off.  doc/BRAM_SWITCH.md step 4.
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
    output reg  [31:0]        vera_rddata,

    // ---- CPU side: byte addressed, active in FAST mode --------------------
    input  wire               cpu_clk,
    input  wire               cpu_cs,
    input  wire               cpu_we,
    input  wire [AWIDTH+1:0]  cpu_addr,    // byte address within the block
    input  wire [7:0]         cpu_wrdata,
    output wire [7:0]         cpu_rddata
);

    // ---- the eight nibble lanes -------------------------------------------
    (* ramstyle = "M10K" *) reg [3:0] ram_n0 [0:WORDS-1];
    (* ramstyle = "M10K" *) reg [3:0] ram_n1 [0:WORDS-1];
    (* ramstyle = "M10K" *) reg [3:0] ram_n2 [0:WORDS-1];
    (* ramstyle = "M10K" *) reg [3:0] ram_n3 [0:WORDS-1];
    (* ramstyle = "M10K" *) reg [3:0] ram_n4 [0:WORDS-1];
    (* ramstyle = "M10K" *) reg [3:0] ram_n5 [0:WORDS-1];
    (* ramstyle = "M10K" *) reg [3:0] ram_n6 [0:WORDS-1];
    (* ramstyle = "M10K" *) reg [3:0] ram_n7 [0:WORDS-1];

    // ---- VERA port: whole 32-bit words, per-nibble write enables ----------
    // Gated by ~fast_mode.  In FAST mode VERA cannot reach this memory at all,
    // which is what stops a display still scanning stale layer registers from
    // writing over a program.
    wire vera_en = ~fast_mode;
    wire [7:0] vera_we = {8{vera_en & vera_write}} & vera_wrnibblesel;

    always @(posedge vera_clk) begin
        if (vera_we[0]) ram_n0[vera_addr] <= vera_wrdata[3:0];
        vera_rddata[3:0]   <= ram_n0[vera_addr];
    end
    always @(posedge vera_clk) begin
        if (vera_we[1]) ram_n1[vera_addr] <= vera_wrdata[7:4];
        vera_rddata[7:4]   <= ram_n1[vera_addr];
    end
    always @(posedge vera_clk) begin
        if (vera_we[2]) ram_n2[vera_addr] <= vera_wrdata[11:8];
        vera_rddata[11:8]  <= ram_n2[vera_addr];
    end
    always @(posedge vera_clk) begin
        if (vera_we[3]) ram_n3[vera_addr] <= vera_wrdata[15:12];
        vera_rddata[15:12] <= ram_n3[vera_addr];
    end
    always @(posedge vera_clk) begin
        if (vera_we[4]) ram_n4[vera_addr] <= vera_wrdata[19:16];
        vera_rddata[19:16] <= ram_n4[vera_addr];
    end
    always @(posedge vera_clk) begin
        if (vera_we[5]) ram_n5[vera_addr] <= vera_wrdata[23:20];
        vera_rddata[23:20] <= ram_n5[vera_addr];
    end
    always @(posedge vera_clk) begin
        if (vera_we[6]) ram_n6[vera_addr] <= vera_wrdata[27:24];
        vera_rddata[27:24] <= ram_n6[vera_addr];
    end
    always @(posedge vera_clk) begin
        if (vera_we[7]) ram_n7[vera_addr] <= vera_wrdata[31:28];
        vera_rddata[31:28] <= ram_n7[vera_addr];
    end

    // ---- CPU port: one byte = two adjacent nibbles ------------------------
    // Byte b of a word occupies nibble lanes 2b and 2b+1, so addr[1:0] selects
    // the pair.  Same layout VERA sees, which is why a byte written here and a
    // word read by VERA agree -- not that anything depends on that, since a
    // cold boot wipes the block, but a mapping that did NOT agree would be a
    // silent trap for whoever assumed it later.
    wire [AWIDTH-1:0] cpu_word = cpu_addr[AWIDTH+1:2];
    wire [1:0]        cpu_lane = cpu_addr[1:0];
    wire              cpu_en   = fast_mode & cpu_cs;
    wire              cpu_wr   = cpu_en & cpu_we;

    reg [3:0] cpu_q0, cpu_q1, cpu_q2, cpu_q3, cpu_q4, cpu_q5, cpu_q6, cpu_q7;

    always @(posedge cpu_clk) begin
        if (cpu_wr && cpu_lane == 2'd0) ram_n0[cpu_word] <= cpu_wrdata[3:0];
        cpu_q0 <= ram_n0[cpu_word];
    end
    always @(posedge cpu_clk) begin
        if (cpu_wr && cpu_lane == 2'd0) ram_n1[cpu_word] <= cpu_wrdata[7:4];
        cpu_q1 <= ram_n1[cpu_word];
    end
    always @(posedge cpu_clk) begin
        if (cpu_wr && cpu_lane == 2'd1) ram_n2[cpu_word] <= cpu_wrdata[3:0];
        cpu_q2 <= ram_n2[cpu_word];
    end
    always @(posedge cpu_clk) begin
        if (cpu_wr && cpu_lane == 2'd1) ram_n3[cpu_word] <= cpu_wrdata[7:4];
        cpu_q3 <= ram_n3[cpu_word];
    end
    always @(posedge cpu_clk) begin
        if (cpu_wr && cpu_lane == 2'd2) ram_n4[cpu_word] <= cpu_wrdata[3:0];
        cpu_q4 <= ram_n4[cpu_word];
    end
    always @(posedge cpu_clk) begin
        if (cpu_wr && cpu_lane == 2'd2) ram_n5[cpu_word] <= cpu_wrdata[7:4];
        cpu_q5 <= ram_n5[cpu_word];
    end
    always @(posedge cpu_clk) begin
        if (cpu_wr && cpu_lane == 2'd3) ram_n6[cpu_word] <= cpu_wrdata[3:0];
        cpu_q6 <= ram_n6[cpu_word];
    end
    always @(posedge cpu_clk) begin
        if (cpu_wr && cpu_lane == 2'd3) ram_n7[cpu_word] <= cpu_wrdata[7:4];
        cpu_q7 <= ram_n7[cpu_word];
    end

    // The lane select is registered alongside the data so the read mux uses
    // the lane belonging to THIS result rather than whatever address arrived
    // while it was in flight.
    reg [1:0] cpu_lane_q;
    always @(posedge cpu_clk) cpu_lane_q <= cpu_lane;

    assign cpu_rddata = (cpu_lane_q == 2'd0) ? {cpu_q1, cpu_q0}
                      : (cpu_lane_q == 2'd1) ? {cpu_q3, cpu_q2}
                      : (cpu_lane_q == 2'd2) ? {cpu_q5, cpu_q4}
                                             : {cpu_q7, cpu_q6};

endmodule

`default_nettype wire
