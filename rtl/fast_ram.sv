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
// FOUR BYTE-WIDE ARRAYS, ONE PER LANE -- AND NOT ONE 32-BIT ARRAY
//
// A 32-bit array with byte enables packs better on paper: M10K is 10,240 bits
// and a byte-wide array uses only 8,192, so 256 KB would cost ~205 blocks
// instead of ~260.  That version was written, and Quartus would not infer it.
//
// The reason is in main_ram.v's header: "one always block per lane; Quartus's
// BRAM pattern matcher wants that idiom".  Writing a SLICE of an array element
// -- mem[w][7:0] <= d -- is not the pattern.  bank0_ram writes whole elements
// (mem[wa] <= wd) and main_ram splits into eight nibble arrays precisely so
// that every write is a whole element.  Both infer; the byte-enable form did
// not, and the symptom was the one main_ram.v names: "the design grows by
// ~50000 LEs and elaboration takes over an hour."
//
// So: four arrays, addr[1:0] selects which one a write lands in and which one
// a read is muxed from.  Every write is a whole element of a byte-wide array,
// which is bank0_ram's idiom exactly.  It costs 55 M10K blocks over the
// theoretical best, and it is the version that exists.
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

    // One array per byte lane.  Every write below assigns a WHOLE element of a
    // byte-wide array, which is bank0_ram's idiom and the one that infers.
    (* ramstyle = "M10K" *) reg [7:0] mem0 [0:WORDS-1];
    (* ramstyle = "M10K" *) reg [7:0] mem1 [0:WORDS-1];
    (* ramstyle = "M10K" *) reg [7:0] mem2 [0:WORDS-1];
    (* ramstyle = "M10K" *) reg [7:0] mem3 [0:WORDS-1];

    wire we0 = w_en & (w_lane == 2'd0);
    wire we1 = w_en & (w_lane == 2'd1);
    wire we2 = w_en & (w_lane == 2'd2);
    wire we3 = w_en & (w_lane == 2'd3);

    wire [AW-1:0] r_word = addr[AW+1:2];
    reg  [7:0] q0, q1, q2, q3;
    reg  [1:0] rd_lane;

    // Posedge write, NEGEDGE read -- bank0_ram's convention, and what makes
    // the access single-cycle: the M10K gets a half-cycle head start so the
    // byte is ready when the CPU samples at the next posedge.
    always @(posedge clk) if (we0) mem0[w_word] <= w_data;
    always @(posedge clk) if (we1) mem1[w_word] <= w_data;
    always @(posedge clk) if (we2) mem2[w_word] <= w_data;
    always @(posedge clk) if (we3) mem3[w_word] <= w_data;

    always @(negedge clk) q0      <= mem0[r_word];
    always @(negedge clk) q1      <= mem1[r_word];
    always @(negedge clk) q2      <= mem2[r_word];
    always @(negedge clk) q3      <= mem3[r_word];
    always @(negedge clk) rd_lane <= addr[1:0];

    assign rd_data = (rd_lane == 2'd0) ? q0
                   : (rd_lane == 2'd1) ? q1
                   : (rd_lane == 2'd2) ? q2
                                       : q3;

endmodule

`default_nettype wire
