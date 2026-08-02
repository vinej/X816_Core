//`default_nettype none

// jyv 2026-07-07: VERA FX update -- write enables widened from 4 byte lanes
// to 8 nibble lanes (bus_wrnibblesel), required for FX 4-bit mode and
// transparent/cache writes.  Matches upstream v47.0.2 main_ram.v port.
//
// VERA816: VRAM grows from 128 KB to 352 KB and the word address from 15 to
// 17 bits.  See doc/VERA816.md, which is the contract this and the emulator
// both implement.
//
// The stock design split VRAM into two groups of 8 nibble arrays (blk10,
// blk32) selected by bus_addr[14].  That split is a legacy of the original
// Lattice SP256K primitives, which were 256 Kbit each -- it is not a
// requirement of the design.  VERA816 collapses it to ONE group of 8 nibble
// arrays indexed directly by bus_addr, which is both simpler and larger:
//
//     8 arrays x 4 bits            = 32 bits per word
//     90,112 words x 4 bytes       = 360,448 B = 352 KB
//     M10K x4 mode is 2048 deep    -> 44 blocks per array x 8 = 352 blocks
//
// Nibble granularity is retained because VERA FX needs 4-bit write enables.
// It costs 20% packing efficiency (M10K x4 mode uses 4 of 5 bits) and cannot
// be recovered without dropping FX.
module main_ram(
    input  wire        clk,

    // Slave bus interface
    input  wire [16:0] bus_addr,
    input  wire [31:0] bus_wrdata,
    input  wire  [7:0] bus_wrnibblesel,
    output reg  [31:0] bus_rddata,
    input  wire        bus_write);

// 2026-06-21: Phase 1 strip -- use inferable BRAM unconditionally so Quartus
// can pack into M10K.  Original Lattice SP256K primitives kept under
// `LATTICE_SP256K` for upstream tool compatibility.
`ifndef LATTICE_SP256K
    // Quartus M10K inference requirements (learned the hard way on the X16
    // core, and all still apply at the larger size):
    //   * (* ramstyle = "M10K" *) or Synthesis implements the array in ALMs --
    //     the design grows by ~50000 LEs and elaboration takes over an hour.
    //   * non-blocking (<=) writes; blocking assignments on an array element
    //     disqualify the array from BRAM inference.
    //   * one always block per lane; Quartus's BRAM pattern matcher wants
    //     that idiom.
    //   * index with a signal whose width matches the array bound.
    // 128 KB, stock VERA.  It was 352 KB (90112 words) until banks $01-$04
    // were given BRAM: 224 M10K blocks moved from VRAM to program RAM, which
    // is what pays for rtl/fast_ram.sv.  doc/BRAM_SWITCH.md has the reasoning
    // and doc/AUDIT.md 6.2 has the 4.47x that motivated it.  The 19-bit
    // address space is unchanged and still only partly populated, so nothing
    // above needed rewiring -- reads past the end return undefined data
    // exactly as they did past 352 KB.
    localparam VRAM_WORDS = 32768;      // 128 KB / 4 bytes per word

    (* ramstyle = "M10K" *) reg [3:0] vram_n0 [0:VRAM_WORDS-1];
    (* ramstyle = "M10K" *) reg [3:0] vram_n1 [0:VRAM_WORDS-1];
    (* ramstyle = "M10K" *) reg [3:0] vram_n2 [0:VRAM_WORDS-1];
    (* ramstyle = "M10K" *) reg [3:0] vram_n3 [0:VRAM_WORDS-1];
    (* ramstyle = "M10K" *) reg [3:0] vram_n4 [0:VRAM_WORDS-1];
    (* ramstyle = "M10K" *) reg [3:0] vram_n5 [0:VRAM_WORDS-1];
    (* ramstyle = "M10K" *) reg [3:0] vram_n6 [0:VRAM_WORDS-1];
    (* ramstyle = "M10K" *) reg [3:0] vram_n7 [0:VRAM_WORDS-1];

    wire [16:0] mem_addr = bus_addr;

    // The 19-bit address space is 512 KB but only 352 KB is populated.
    // doc/VERA816.md section 3 makes the hole normative: reads return $00 and
    // writes are discarded, with no mirroring.  352 KB is not a power of two,
    // so this is a compare rather than a mask.
    wire in_range = (bus_addr < VRAM_WORDS);
    wire do_write = bus_write && in_range;

    reg in_range_r;
    always @(posedge clk) in_range_r <= in_range;

    // Nibble-lane writes (one always per lane -- Quartus BRAM pattern).
    always @(posedge clk) if (do_write && bus_wrnibblesel[0]) vram_n0[mem_addr] <= bus_wrdata[3:0];
    always @(posedge clk) if (do_write && bus_wrnibblesel[1]) vram_n1[mem_addr] <= bus_wrdata[7:4];
    always @(posedge clk) if (do_write && bus_wrnibblesel[2]) vram_n2[mem_addr] <= bus_wrdata[11:8];
    always @(posedge clk) if (do_write && bus_wrnibblesel[3]) vram_n3[mem_addr] <= bus_wrdata[15:12];
    always @(posedge clk) if (do_write && bus_wrnibblesel[4]) vram_n4[mem_addr] <= bus_wrdata[19:16];
    always @(posedge clk) if (do_write && bus_wrnibblesel[5]) vram_n5[mem_addr] <= bus_wrdata[23:20];
    always @(posedge clk) if (do_write && bus_wrnibblesel[6]) vram_n6[mem_addr] <= bus_wrdata[27:24];
    always @(posedge clk) if (do_write && bus_wrnibblesel[7]) vram_n7[mem_addr] <= bus_wrdata[31:28];

    // Synchronous read -- one M10K group per nibble lane, reassembled.
    reg [31:0] vram_rddata_r;
    always @(posedge clk) begin
        vram_rddata_r <= {vram_n7[mem_addr], vram_n6[mem_addr],
                          vram_n5[mem_addr], vram_n4[mem_addr],
                          vram_n3[mem_addr], vram_n2[mem_addr],
                          vram_n1[mem_addr], vram_n0[mem_addr]};
    end

    // in_range_r is registered alongside the read data so the hole returns
    // zero with the same one-cycle latency as a real read.
    always @* bus_rddata = in_range_r ? vram_rddata_r : 32'h0;

    // 2026-06-21: Phase 1 strip -- the upstream `initial begin ... for` loop
    // assigning blk10[i]=i is rejected by Quartus (loop must terminate within
    // 5000 iterations) and also flagged as non-constant initial value.  Drop
    // it: the CPU clears VRAM before enabling video output, so initial values
    // do not matter.

`else
    // Upstream Lattice path, retained for tool compatibility only. iCE40
    // UltraPlus has nowhere near 352 KB of SPRAM, so this branch is limited
    // to the original 128 KB and cannot implement VERA816.
    wire blk10_cs = !bus_addr[14];
    wire blk32_cs = bus_addr[14];
    wire [31:0] blk10_rddata;
    wire [31:0] blk32_rddata;

    reg bus_addr14;
    always @(posedge clk) bus_addr14 <= bus_addr[14];

    always @* bus_rddata = bus_addr14 ? blk32_rddata : blk10_rddata;

    SP256K blk0(
        .CK(clk),
        .AD(bus_addr[13:0]),
        .DI(bus_wrdata[15:0]),
        .DO(blk10_rddata[15:0]),
        .MASKWE(bus_wrnibblesel[3:0]),
        .WE(bus_write && blk10_cs),
        .CS(1'b1),
        .STDBY(1'b0),
        .SLEEP(1'b0),
        .PWROFF_N(1'b1));

    SP256K blk1(
        .CK(clk),
        .AD(bus_addr[13:0]),
        .DI(bus_wrdata[31:16]),
        .DO(blk10_rddata[31:16]),
        .MASKWE(bus_wrnibblesel[7:4]),
        .WE(bus_write && blk10_cs),
        .CS(1'b1),
        .STDBY(1'b0),
        .SLEEP(1'b0),
        .PWROFF_N(1'b1));

    SP256K blk2(
        .CK(clk),
        .AD(bus_addr[13:0]),
        .DI(bus_wrdata[15:0]),
        .DO(blk32_rddata[15:0]),
        .MASKWE(bus_wrnibblesel[3:0]),
        .WE(bus_write && blk32_cs),
        .CS(1'b1),
        .STDBY(1'b0),
        .SLEEP(1'b0),
        .PWROFF_N(1'b1));

    SP256K blk3(
        .CK(clk),
        .AD(bus_addr[13:0]),
        .DI(bus_wrdata[31:16]),
        .DO(blk32_rddata[31:16]),
        .MASKWE(bus_wrnibblesel[7:4]),
        .WE(bus_write && blk32_cs),
        .CS(1'b1),
        .STDBY(1'b0),
        .SLEEP(1'b0),
        .PWROFF_N(1'b1));

`endif

endmodule
