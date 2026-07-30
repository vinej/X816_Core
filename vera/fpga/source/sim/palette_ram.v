//`default_nettype none

module palette_ram(
    input  wire        wr_clk_i,
    input  wire        rd_clk_i,
    input  wire        wr_clk_en_i,
    input  wire        rd_en_i,
    input  wire        rd_clk_en_i,
    input  wire        wr_en_i,
    input  wire  [1:0] ben_i,
    input  wire [15:0] wr_data_i,
    input  wire  [7:0] wr_addr_i,
    input  wire  [7:0] rd_addr_i,
    output reg  [15:0] rd_data_o);

    // 2026-06-21: pin to M10K so Quartus doesn't drop this 4 Kbit table into
    // LUT-flops.  The initial block sets the X16 default palette and Quartus
    // synthesises that into the block-RAM MIF.
    (* ramstyle = "M10K" *) reg [15:0] mem[0:255];

    always @(posedge wr_clk_i) begin
        if (wr_en_i) begin
            if (ben_i[1]) mem[wr_addr_i][15:8] <= wr_data_i[15:8];
            if (ben_i[0]) mem[wr_addr_i][7:0]  <= wr_data_i[7:0];
        end
    end

    always @(posedge rd_clk_i) begin
        rd_data_o <= mem[rd_addr_i];
    end

    initial begin: INIT
        $readmemh("vera_source_original/generated/palette_ram/misc/palette_ram_palette_ram_copy.mem", mem);
    end

endmodule

