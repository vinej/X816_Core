//`default_nettype none

// jyv 2026-07-07: VERA FX update -- write enables widened from 4 byte lanes
// to 8 nibble lanes (bus_wrnibblesel), required for FX 4-bit mode and
// transparent/cache writes.  Matches upstream v47.0.2 main_ram.v port.
module main_ram(
    input  wire        clk,

    // Slave bus interface
    input  wire [14:0] bus_addr,
    input  wire [31:0] bus_wrdata,
    input  wire  [7:0] bus_wrnibblesel,
    output reg  [31:0] bus_rddata,
    input  wire        bus_write);

    wire blk10_cs = !bus_addr[14];
    wire blk32_cs = bus_addr[14];
    wire [31:0] blk10_rddata;
    wire [31:0] blk32_rddata;

    reg bus_addr14;
    always @(posedge clk) bus_addr14 <= bus_addr[14];

    always @* bus_rddata = bus_addr14 ? blk32_rddata : blk10_rddata;

// 2026-06-21: Phase 1 strip -- use inferable BRAM unconditionally so Quartus
// can pack into M10K.  Original Lattice SP256K primitives kept under
// `LATTICE_SP256K` for upstream tool compatibility.
`ifndef LATTICE_SP256K
    // 2026-06-21: Quartus M10K inference fixes for the 64 KB VRAM.
    //   * Add (* ramstyle = "M10K" *) so Synthesis packs the array into the
    //     Cyclone V on-chip block-RAM instead of LUT-flops.  Without this
    //     hint Quartus implemented all 1 Mbit in ALMs -- the design grows by
    //     ~50000 LEs and elaboration takes over an hour with no chance of
    //     fitting.
    //   * Use non-blocking (<=) writes; blocking (=) assignments on an array
    //     element disqualify the array from BRAM inference in Quartus.
    //   * Index writes with bus_addr[13:0] (matches the array bound) instead
    //     of the full 15-bit bus_addr -- the top bit is the bank select and
    //     was implicitly truncated, which also confused inference.
    //   * Split the write-enabled write into independent per-lane always
    //     blocks.  Quartus's BRAM pattern matcher recognises this idiom.
    //   * jyv 2026-07-07 (VERA FX): lanes narrowed from 8 byte lanes to 16
    //     nibble lanes so FX 4-bit-mode / transparent / cache writes get
    //     true nibble-granular write enables.  Same total 1 Mbit of M10K.
    (* ramstyle = "M10K" *) reg [3:0] blk10_n0 [0:16383];
    (* ramstyle = "M10K" *) reg [3:0] blk10_n1 [0:16383];
    (* ramstyle = "M10K" *) reg [3:0] blk10_n2 [0:16383];
    (* ramstyle = "M10K" *) reg [3:0] blk10_n3 [0:16383];
    (* ramstyle = "M10K" *) reg [3:0] blk10_n4 [0:16383];
    (* ramstyle = "M10K" *) reg [3:0] blk10_n5 [0:16383];
    (* ramstyle = "M10K" *) reg [3:0] blk10_n6 [0:16383];
    (* ramstyle = "M10K" *) reg [3:0] blk10_n7 [0:16383];
    (* ramstyle = "M10K" *) reg [3:0] blk32_n0 [0:16383];
    (* ramstyle = "M10K" *) reg [3:0] blk32_n1 [0:16383];
    (* ramstyle = "M10K" *) reg [3:0] blk32_n2 [0:16383];
    (* ramstyle = "M10K" *) reg [3:0] blk32_n3 [0:16383];
    (* ramstyle = "M10K" *) reg [3:0] blk32_n4 [0:16383];
    (* ramstyle = "M10K" *) reg [3:0] blk32_n5 [0:16383];
    (* ramstyle = "M10K" *) reg [3:0] blk32_n6 [0:16383];
    (* ramstyle = "M10K" *) reg [3:0] blk32_n7 [0:16383];

    reg [31:0] blk10_rddata_r;
    reg [31:0] blk32_rddata_r;

    assign blk10_rddata = blk10_rddata_r;
    assign blk32_rddata = blk32_rddata_r;

    wire [13:0] mem_addr = bus_addr[13:0];

    // Nibble-lane writes (one always per lane -- Quartus BRAM pattern).
    always @(posedge clk) if (bus_write && blk10_cs && bus_wrnibblesel[0]) blk10_n0[mem_addr] <= bus_wrdata[3:0];
    always @(posedge clk) if (bus_write && blk10_cs && bus_wrnibblesel[1]) blk10_n1[mem_addr] <= bus_wrdata[7:4];
    always @(posedge clk) if (bus_write && blk10_cs && bus_wrnibblesel[2]) blk10_n2[mem_addr] <= bus_wrdata[11:8];
    always @(posedge clk) if (bus_write && blk10_cs && bus_wrnibblesel[3]) blk10_n3[mem_addr] <= bus_wrdata[15:12];
    always @(posedge clk) if (bus_write && blk10_cs && bus_wrnibblesel[4]) blk10_n4[mem_addr] <= bus_wrdata[19:16];
    always @(posedge clk) if (bus_write && blk10_cs && bus_wrnibblesel[5]) blk10_n5[mem_addr] <= bus_wrdata[23:20];
    always @(posedge clk) if (bus_write && blk10_cs && bus_wrnibblesel[6]) blk10_n6[mem_addr] <= bus_wrdata[27:24];
    always @(posedge clk) if (bus_write && blk10_cs && bus_wrnibblesel[7]) blk10_n7[mem_addr] <= bus_wrdata[31:28];

    always @(posedge clk) if (bus_write && blk32_cs && bus_wrnibblesel[0]) blk32_n0[mem_addr] <= bus_wrdata[3:0];
    always @(posedge clk) if (bus_write && blk32_cs && bus_wrnibblesel[1]) blk32_n1[mem_addr] <= bus_wrdata[7:4];
    always @(posedge clk) if (bus_write && blk32_cs && bus_wrnibblesel[2]) blk32_n2[mem_addr] <= bus_wrdata[11:8];
    always @(posedge clk) if (bus_write && blk32_cs && bus_wrnibblesel[3]) blk32_n3[mem_addr] <= bus_wrdata[15:12];
    always @(posedge clk) if (bus_write && blk32_cs && bus_wrnibblesel[4]) blk32_n4[mem_addr] <= bus_wrdata[19:16];
    always @(posedge clk) if (bus_write && blk32_cs && bus_wrnibblesel[5]) blk32_n5[mem_addr] <= bus_wrdata[23:20];
    always @(posedge clk) if (bus_write && blk32_cs && bus_wrnibblesel[6]) blk32_n6[mem_addr] <= bus_wrdata[27:24];
    always @(posedge clk) if (bus_write && blk32_cs && bus_wrnibblesel[7]) blk32_n7[mem_addr] <= bus_wrdata[31:28];

    // Synchronous reads -- one M10K group per nibble lane, reassembled.
    always @(posedge clk) begin
        blk10_rddata_r <= {blk10_n7[mem_addr], blk10_n6[mem_addr],
                           blk10_n5[mem_addr], blk10_n4[mem_addr],
                           blk10_n3[mem_addr], blk10_n2[mem_addr],
                           blk10_n1[mem_addr], blk10_n0[mem_addr]};
        blk32_rddata_r <= {blk32_n7[mem_addr], blk32_n6[mem_addr],
                           blk32_n5[mem_addr], blk32_n4[mem_addr],
                           blk32_n3[mem_addr], blk32_n2[mem_addr],
                           blk32_n1[mem_addr], blk32_n0[mem_addr]};
    end

    // 2026-06-21: Phase 1 strip -- the upstream `initial begin ... for` loop
    // assigning blk10[i]=i is rejected by Quartus (loop must terminate within
    // 5000 iterations; 16384 > 5000) and also flagged as non-constant initial
    // value.  Drop it: the CPU clears VRAM before enabling video output, so
    // initial values do not matter.

`else

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
