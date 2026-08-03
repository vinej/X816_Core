`timescale 1ns/1ps
// ============================================================================
// sdram_sim.v -- behavioral stand-in for rtl/sdram.v (MiST byte controller).
//
// Faithful to the real controller's TWO-PLANE 16-bit organization so the
// framebuffer 16-bit tap (dout16) can be verified:
//   * The chip is 16-bit.  A byte address's bit[24] selects the byte LANE of a
//     16-bit word; bits[23:0] select the word.  So two byte addresses A
//     (A24=0) and A|0x1000000 (A24=1) are the LOW and HIGH byte of the SAME
//     word -- exactly how rtl/sdram.v maps them (bt=addr[24], word={ba,row,col}
//     from addr[23:0]).
//   * dout   = the selected byte (bt ? high : low)  -- the CPU byte path.
//   * dout16 = the whole word {high,low}            -- the framebuffer tap.
//   * writes byte-mask via bit[24] (the real dqm), so a low-plane write never
//     disturbs the high plane and vice-versa.
//
// Storage is a 16-bit word array indexed by addr[22:0].  For every legacy test
// (HiRAM 0x000000-0x1FFFFF, cart 0x480000-0x7FFFFF -- all A24=0, addr<0x800000)
// this is byte-per-address IDENTICAL to the old flat model: each address is a
// distinct word's low byte.  tb_fb keeps its framebuffer base below 0x800000
// too.  Init pattern $DD = "uninitialised RAM" (both lanes).
//
// Same 1-cycle-`ce` handshake as the old model; the byte/word lands a few clk
// after ce, well before ext_ram_sdram samples (CYCLE_LEN=9 for CPU accesses,
// FB_CYC=6 for framebuffer reads).  Chip pins are stubbed.
// ============================================================================
module sdram (
    output [12:0] sd_addr,
    inout  [15:0] sd_data,
    output  [1:0] sd_ba,
    output        sd_cs,
    output        sd_we,
    output        sd_ras,
    output        sd_cas,
    output        sd_clk,
    output  [1:0] sd_dqm,

    input         init,
    input         clk,
    input  [24:0] addr,
    input   [7:0] din,
    output reg  [7:0] dout,
    output reg [15:0] dout16,
    input         refresh,
    input         ce,
    input         we
);
    assign sd_addr = 13'd0;
    assign sd_ba   = 2'd0;
    assign sd_cs   = 1'b1;
    assign sd_we   = 1'b1;
    assign sd_ras  = 1'b1;
    assign sd_cas  = 1'b1;
    assign sd_clk  = 1'b0;
    assign sd_dqm  = 2'b00;

    // 16 M 16-bit words, indexed by the FULL 24-bit word address.
    //
    // This was [0:8388607] indexed by addr[22:0] until 2026-08-03, which
    // silently ALIASED every word above $7FFFFF onto a low one -- and the CPU
    // maps byte N to word N, so every access above $7F:FFFF was affected,
    // including the `fw` target's staging at $F0:0000 (word $F00000 -> word
    // $700000). Nothing collided in practice, so the tests passed, but they
    // were passing on a model that did not match rtl/sdram.v: that decomposes
    // addr[23:0] into ba(2) + row(13) + col(9) = a genuine 24-bit word
    // address, 16 M words on a 32 MB part.
    //
    // It stopped being harmless with the VERA2 framebuffer, whose window sits
    // at word $E00000-$E7FFFF and would have aliased onto $600000 -- i.e. onto
    // ordinary CPU memory, in the model only. A test for the window would then
    // have been measuring the model's bug.
    reg [15:0] wmem [0:16777215];  // 16-bit words, indexed by addr[23:0]
    integer i;
    initial for (i = 0; i < 16777216; i = i + 1) wmem[i] = 16'hDDDD;

    reg        last_ce = 1'b0;
    reg  [3:0] q = 4'd0;
    reg [24:0] a_l;
    reg  [7:0] d_l;
    reg        w_l;

    wire [23:0] widx = a_l[23:0];   // word index (full width -- see wmem)

    always @(posedge clk) begin
        last_ce <= ce;
        if (ce && !last_ce) begin
            q   <= 4'd1;
            a_l <= addr;
            d_l <= din;
            w_l <= we;
        end else if (q != 4'd0) begin
            q <= q + 4'd1;
            if (q == 4'd4) begin
                if (w_l) begin
                    if (a_l[24]) wmem[widx][15:8] <= d_l;   // high-plane byte
                    else         wmem[widx][7:0]  <= d_l;   // low-plane byte
                end else begin
                    dout   <= a_l[24] ? wmem[widx][15:8] : wmem[widx][7:0];
                    dout16 <= wmem[widx];
                end
            end
            if (q == 4'd8) q <= 4'd0;
        end
    end
endmodule
