//============================================================================
// fast_ram.sv  --  banks $01-$04 in BRAM: 256 KB of single-cycle program RAM.
//
// WHY THIS EXISTS
//
// Measured on hardware (doc/AUDIT.md 6.2): code executing from SDRAM runs
// 4.47x slower than the same code from BRAM -- roughly 6 CPU cycles per SDRAM
// access against 1.  A program's code lives at $01:0000 because that is where
// the HPS loader drops it, so every instruction byte a program fetches has
// been an SDRAM access.  Backing $01-$04 with BRAM means EVERY EXISTING
// BINARY gets that speedup by being loaded rather than rewritten.
//
// This is the same argument bank0_ram.sv makes for bank $00, applied one bank
// up, and this file deliberately copies its structure: one array, one clock,
// and a loader port that crosses into that clock by handshake rather than
// taking a second RAM port.  VERA drops to a stock 128 KB to pay for it.
//
// WHY 32 BITS WIDE WHEN THE CPU IS 8
//
// Packing.  M10K is 10,240 bits, and a byte-wide array uses only 8,192 of
// them -- bank0_ram measures 65 blocks for 64 KB, a fifth wasted.  At 32 bits
// the block is fully used, so 256 KB costs ~205 blocks instead of ~260, and
// 55 M10K is the difference between comfortable and not on a device that is
// already 92% full.
//
// The cost is one mux on the read path and byte enables on the write path,
// both of which are free in logic terms.  addr[1:0] picks the byte.
//
// WHY THE MEMORY IS INFERRED HERE AND INSTANTIATED IN switch_ram.sv
//
// Because this shape is one Quartus actually infers.  An earlier design made
// this block switchable between the CPU and VERA, which needed TRUE DUAL PORT
// ON TWO CLOCKS, and Quartus refused: it fell back to registers (Error
// 276003) and then, instantiated explicitly as altsyncram, failed to fit at
// 6192 LABs of 4191.  bank0_ram's header already had the answer -- "M10K has
// two ports and the read port owns one" -- and the resolution was to stop
// switching.  Banks $01-$04 are always BRAM now; VERA is always 128 KB.
// doc/BRAM_SWITCH.md records how that was arrived at.
//
// *** NEGEDGE READ *** for the same reason bank0_ram does it: the M10K gets a
// half-cycle head start, so rd_data reflects the address presented THIS cycle
// when the CPU samples it at the next posedge.  That is what makes the access
// single-cycle, which is the entire point of the module.
//
// DOWNLOAD PORT.  Identical in shape to bank0_ram's, and necessary for the
// same reason: the loader is in another clock domain and cannot have a RAM
// port of its own.  Its bytes cross by toggle handshake and are muxed onto
// the single write port, which is safe because the CPU is held in reset for
// the whole download (x816.sv `dl_hold`).  ld_busy throttles the HPS to the
// crossing rate rather than letting it overrun.
//
// M10K is zero-initialised by FPGA configuration, so a program that reads
// before writing sees zeroes rather than the noise SDRAM comes up with.
//============================================================================
`default_nettype none

module fast_ram #(
    parameter WORDS = 65536              // x 4 bytes = 256 KB, banks $01-$04
) (
    input  wire        clk,              // cpu_clk
    input  wire [17:0] addr,             // byte offset within the block
    input  wire        cs,
    input  wire        we,
    input  wire [7:0]  wr_data,
    output wire [7:0]  rd_data,

    // ---- download port (ld_clk domain; the CPU is in reset throughout) ----
    input  wire        ld_clk,
    input  wire        ld_wr,
    input  wire [17:0] ld_addr,
    input  wire [7:0]  ld_data,
    output wire        ld_busy
);

    localparam AW = $clog2(WORDS);

    (* ramstyle = "M10K" *) reg [31:0] mem [0:WORDS-1];

    // ---- loader -> cpu_clk, by handshake ---------------------------------
    // Copied from bank0_ram: a small FIFO on the loader side, one request
    // carried across by a toggle, and an ack toggling back. The FIFO exists so
    // the HPS is throttled smoothly instead of stalling on every byte.
    reg [25:0] ldfifo [0:7];             // {ld_addr[17:0], ld_data[7:0]}
    reg  [2:0] ldf_rd = 3'd0, ldf_wr = 3'd0;
    reg  [3:0] ldf_cnt = 4'd0;
    wire       ldf_nonempty = (ldf_cnt != 4'd0);
    assign     ld_busy      = (ldf_cnt >= 4'd4);

    reg         req_tgl = 1'b0;
    reg  [17:0] req_addr;
    reg   [7:0] req_data;
    reg   [1:0] ack_s = 2'b00;
    reg         ack_d = 1'b0;
    reg         pending = 1'b0;
    wire        ldf_pop = ldf_nonempty & ~pending;
    reg         ack_tgl = 1'b0;

    always @(posedge ld_clk) begin
        ack_s <= {ack_s[0], ack_tgl};
        ack_d <= ack_s[1];
        if (ack_s[1] != ack_d) pending <= 1'b0;

        if (ld_wr) begin
            ldfifo[ldf_wr] <= {ld_addr, ld_data};
            ldf_wr         <= ldf_wr + 3'd1;
        end
        ldf_cnt <= ldf_cnt + (ld_wr ? 4'd1 : 4'd0) - (ldf_pop ? 4'd1 : 4'd0);

        if (ldf_pop) begin
            {req_addr, req_data} <= ldfifo[ldf_rd];
            ldf_rd               <= ldf_rd + 3'd1;
            req_tgl              <= ~req_tgl;
            pending              <= 1'b1;
        end
    end

    reg [1:0] req_s = 2'b00;
    reg       req_d = 1'b0;
    wire      ld_take = (req_s[1] != req_d);

    always @(posedge clk) begin
        req_s <= {req_s[0], req_tgl};
        req_d <= req_s[1];
        if (ld_take) ack_tgl <= ~ack_tgl;
    end

    // ---- the single write port, shared by the CPU and the loader ----------
    // The loader wins, which costs nothing: the CPU is in reset while a
    // download runs, so the two are never asserted together.
    wire [AW-1:0] w_word = ld_take ? req_addr[AW+1:2] : addr[AW+1:2];
    wire   [1:0]  w_lane = ld_take ? req_addr[1:0]    : addr[1:0];
    wire   [7:0]  w_data = ld_take ? req_data         : wr_data;
    wire          w_en   = ld_take | (cs & we);

    // Byte enables rather than a read-modify-write: this is the template
    // Quartus infers byte-enabled M10K from, and it is what lets the array be
    // 32 bits wide -- see the header on packing.
    always @(posedge clk) begin
        if (w_en) begin
            if (w_lane == 2'd0) mem[w_word][7:0]   <= w_data;
            if (w_lane == 2'd1) mem[w_word][15:8]  <= w_data;
            if (w_lane == 2'd2) mem[w_word][23:16] <= w_data;
            if (w_lane == 2'd3) mem[w_word][31:24] <= w_data;
        end
    end

    // ---- read, on the NEGEDGE, so the byte is ready at the CPU's posedge --
    reg [31:0] rd_word;
    reg  [1:0] rd_lane;
    always @(negedge clk) begin
        rd_word <= mem[addr[AW+1:2]];
        rd_lane <= addr[1:0];
    end

    assign rd_data = (rd_lane == 2'd0) ? rd_word[7:0]
                   : (rd_lane == 2'd1) ? rd_word[15:8]
                   : (rd_lane == 2'd2) ? rd_word[23:16]
                                       : rd_word[31:24];

endmodule

`default_nettype wire
