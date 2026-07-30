//`default_nettype none

module dpram #(parameter ADDR_WIDTH = 8, DATA_WIDTH = 8) (
    input  wire                  wr_clk,
    input  wire [ADDR_WIDTH-1:0] wr_addr,
    input  wire                  wr_en,
    input  wire [DATA_WIDTH-1:0] wr_data,

    input  wire                  rd_clk,
    input  wire [ADDR_WIDTH-1:0] rd_addr,
    output reg  [DATA_WIDTH-1:0] rd_data);

    // 2026-06-21: Add Quartus M10K ramstyle.  The upstream `syn_ramstyle`
    // hint is Lattice/Synplify-only and is ignored by Quartus, which then
    // defaults to LUT-based RAM for small dpram instances and to ALMs for
    // anything larger.  This module is instantiated >10 times (sprite line
    // buffers + layer line buffers), so the size adds up quickly.
    (* ramstyle = "M10K" *)
    reg [DATA_WIDTH-1:0] mem [(1<<ADDR_WIDTH)-1:0];

    always @(posedge wr_clk) if (wr_en) mem[wr_addr] <= wr_data;
    always @(posedge rd_clk) rd_data <= mem[rd_addr];

    // jyv 2026-07-07: initial zero for ALL tools (was `ifdef __ICARUS__,
    // so ModelSim left the contents X -- the PSG's phase/attr RAMs then
    // poisoned the whole audio path in sim; on the FPGA M10Ks power up 0
    // and Quartus honors this initial the same way).
    initial begin: INIT
        integer i;
        for (i=0; i<(1<<ADDR_WIDTH); i=i+1) begin
            mem[i] = 0;
        end
    end

endmodule
