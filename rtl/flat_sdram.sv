//============================================================================
// flat_sdram.sv  --  Flat 16 MB byte-addressed main memory backed by SDRAM.
//
// Derived from the X16 core's ext_ram_sdram.sv, but with every X16-specific
// client stripped out (cart loader/backer, bitmap framebuffer stream, blitter).
// What remains is the CPU port plus a download port, because in a flat machine
// the CPU port is no longer a WINDOW -- it is the whole memory system, and it
// carries every opcode fetch, operand, stack push and data access.
//
//   * CPU port runs on clk (cpu_clk).  byte_addr is the raw 24-bit CPU address:
//     {bank, offset}.  The parent decides which addresses come here (see the
//     bank-0 BRAM split in x816.sv) -- this module maps its input 1:1 onto the
//     low 16 MB of the SDRAM part.
//   * Controller + FSM run on sdram_clk (100 MHz), the speed sdram.v was
//     designed for.  A 25-bit address goes to sdram.v; we drive the low 24.
//
// CDC is a toggle handshake, identical in shape to the X16 version:
//   req_tgl (cpu -> sdram) flips to request, ack_tgl (sdram -> cpu) flips on
//   completion, and the payload registers are stable either side of the flip.
//
// THREE THINGS HERE ARE LOAD-BEARING.  They were each paid for with a silicon
// bug on the DE10-Nano and are carried over deliberately:
//
//  1. `ready` must never compare live CPU address bits.  Doing so closes a
//     combinational loop cpu_a -> ready -> cpu_rdy -> CPU rdy_i -> a_o -> cpu_a
//     (a ~105-node comb loop; symptom was a metastable two-attempt boot).
//     ready is built from a plain ~cs term plus REGISTERED flags only.
//
//  2. `| we` in the ready term.  The P65C816's RDY_IN is a GLOBAL clock
//     enable -- unlike a 65C02 it honours the stall on write cycles too.  A
//     write is captured by the FIFO at the bus edge, so there is nothing to
//     wait for; without this term the held write re-pushes every cycle, keeps
//     served_valid cleared, and ready never rises again -> deadlock.
//
//  3. Read delivery is "serve once, deliver once" (consume-clear) with no
//     address compare in the stall cone.  Back-to-back accesses where cs never
//     falls -- which in a flat machine is the COMMON case, since sequential
//     instruction fetches all land here -- are then correct by construction.
//
// ADDRESS MAPPING -- sdram.v is NOT a plain byte-addressed controller.
// It decomposes its 25-bit input like this (sdram.v lines 164-167):
//
//     sd_ba   <= addr[22:21];              // bank
//     sd_addr <= addr[20:8];               // row
//     caddr   <= {addr[23], addr[7:0]};    // column (addr[23] is the col MSB)
//     bt      <= addr[24];                 // byte lane WITHIN the 16-bit word
//
// so addr[23:0] is a WORD address and addr[24] picks the lane.  Consecutive
// byte addresses therefore land in DIFFERENT WORDS, not in the two lanes of
// one word.
//
// This module uses TWO mappings, chosen by address range -- see map_addr()
// below for the arithmetic and the reasoning:
//
//   * EVERYWHERE EXCEPT $E0-$EF: `{1'b0, byte_addr}` -- lane 0 of word
//     byte_addr, exactly as the original proven build.  Every CPU byte
//     consumes a whole 16-bit word and wastes the high half, so a 16 MB flat
//     space needs a 32 MB (or larger) MiSTer SDRAM module.  8 MB parts cannot
//     back a flat '816 at all.
//
//   * BANKS $E0-$EF (the VERA2 framebuffer): two bytes per word, so the
//     scanout engine can read two pixels per SDRAM access.  It has to -- at
//     8 clocks (80 ns) per access a 32 us line affords only ~400 accesses and
//     640x480 8bpp needs 640 bytes of them.
//
// Outside the window nothing changed, which is the point: the address path
// every existing program takes is bit-identical to the build that was proven
// on hardware.
//
// DO NOT try to use sd_dout16 for 16-bit CPU fetch outside the window: under
// {1'b0, byte_addr} it returns byte A alongside byte A+0x1000000, which are
// unrelated.  Moving the CPU's LSB into the lane bit GLOBALLY --
//     acc_addr = {byte_addr[0], 1'b0, byte_addr[23:1]}
// -- would put bytes 2N/2N+1 in the two lanes of word N, make dout16 useful
// everywhere and drop the part requirement to exactly 16 MB.  That is a real
// future option (a 16-bit fetch is worth cycles on every instruction), and
// the window below is the same trick applied to one range first.  The write
// path is already lane-correct for either bt (sd_addr[12:11] -> sd_dqm,
// sdram.v line 174).
//============================================================================
module flat_sdram (
    // ---- CPU domain ----
    input  logic        clk,          // cpu_clk
    input  logic        reset_n,
    input  logic        cs,           // access targets flat RAM this cycle
    input  logic        we,           // 1 = write
    input  logic [23:0] byte_addr,    // flat CPU address {bank, offset}
    input  logic  [7:0] wr_data,
    output logic  [7:0] rd_data,
    output logic        ready,        // 0 = stall the CPU

    // ---- Download port (sdram_clk domain = the hps_io ioctl domain) ----
    // Streams an image into flat memory while the CPU is held in reset.
    // ld_busy drives ioctl_wait so the HPS throttles if the FIFO fills.
    input  logic        sdram_clk,    // 100 MHz
    input  logic        ld_wr,
    input  logic [23:0] ld_addr,
    input  logic  [7:0] ld_data,
    output logic        ld_busy,

    // ---- SDRAM chip pins ----
    output logic [12:0] SDRAM_A,
    inout  wire  [15:0] SDRAM_DQ,
    output logic  [1:0] SDRAM_BA,
    output logic        SDRAM_nCS,
    output logic        SDRAM_nWE,
    output logic        SDRAM_nRAS,
    output logic        SDRAM_nCAS,
    output logic        SDRAM_CKE,
    output logic        SDRAM_CLK,
    output logic        SDRAM_DQML,
    output logic        SDRAM_DQMH
);

    localparam [9:0] REFRESH_INTERVAL = 10'd750;  // < 780 = 7.8 us @ 100 MHz
    localparam [3:0] CYCLE_LEN        = 4'd9;     // > sdram.v's 8-state cycle
    localparam [9:0] INIT_WAIT_LEN    = 10'd400;  // > 31*8 self-init cycles

    // ---- fast-domain reset: async assert, sync deassert into sdram_clk ----
    logic [1:0] rstf_sync;
    always_ff @(posedge sdram_clk or negedge reset_n)
        if (!reset_n) rstf_sync <= 2'b00;
        else          rstf_sync <= {rstf_sync[0], 1'b1};
    wire reset_n_f = rstf_sync[1];

    // ---- CDC toggles + captured read data ----
    logic       req_tgl;
    logic       ack_tgl;
    logic [7:0] rd_data_f;

    // ---- cpu-domain capture of the in-flight access params ----
    logic        lat_we;
    logic [23:0] lat_addr;
    logic  [7:0] lat_wdata;

    // ---- fast-domain snapshot ----
    logic        sd_ce, sd_we_l, sd_refresh;
    logic [24:0] acc_addr;

    // ======================================================================
    // ADDRESS MAPPING -- one function, used by BOTH the CPU path and the
    // loader path, so an image can be staged straight into the framebuffer.
    //
    // Everywhere except the VERA2 framebuffer window this is the original
    // {1'b0, byte_addr}: lane 0 of word byte_addr, bit-identical to what the
    // proven build did, so no existing access changes at all.
    //
    // THE WINDOW IS DIFFERENT ON PURPOSE.  Banks $E0-$EF hold the VERA2
    // framebuffer (X816_VFB_BASE), and the scanout engine has to read it fast
    // enough to keep up with the raster.  An sdram.v access is 8 clocks at
    // 100 MHz = 80 ns, so a 32 us line affords ~400 accesses.  640x480 8bpp
    // needs 640 bytes per line: one pixel per word would be 640 accesses and
    // MISSES -- and no amount of prefetch depth fixes an average-rate
    // deficit.  Packing two pixels into the two lanes of one word halves it
    // to 320, which fits with room for the CPU and refresh.
    //
    //     FB byte $E0:0000 + k  ->  word {4'hE, 1'b0, k[19:1]}, lane k[0]
    //
    // so consecutive FB bytes are the two halves of one 16-bit word and
    // sd_dout16 delivers {odd pixel, even pixel} -- low byte = even x, which
    // is the layout bitmap_engine.sv already expects.
    //
    // NO COLLISION IS POSSIBLE.  Diverting bytes $E00000-$EFFFFF away from
    // the plain mapping is exactly what frees lane 0 of words $E00000-$EFFFFF,
    // and the window only ever lands in words $E00000-$E7FFFF.  Everything
    // else still owns lane 0 of its own word and is untouched.
    //
    // The CPU therefore writes the framebuffer with ORDINARY STORES -- no
    // ADDR/DATA port, and MVN block moves work on it at 7 cycles/byte. That
    // is a better programming model than the upstream VERA2 this is derived
    // from, which reaches its framebuffer only through a data port.
    // ======================================================================
    localparam logic [3:0] VFB_BANK_HI = 4'hE;   // X816_VFB_BASE >> 20

    function automatic logic [24:0] map_addr(input logic [23:0] a);
        map_addr = (a[23:20] == VFB_BANK_HI)
                 ? {a[0], VFB_BANK_HI, 1'b0, a[19:1]}   // {lane, word}
                 : {1'b0, a};
    endfunction

    logic  [7:0] acc_wdata;
    wire   [7:0] sd_dout;
    wire  [15:0] sd_dout16;
    wire   [1:0] sd_dqm;

    sdram u_sdram (
        .sd_addr (SDRAM_A),
        .sd_data (SDRAM_DQ),
        .sd_ba   (SDRAM_BA),
        .sd_cs   (SDRAM_nCS),
        .sd_we   (SDRAM_nWE),
        .sd_ras  (SDRAM_nRAS),
        .sd_cas  (SDRAM_nCAS),
        .sd_clk  (SDRAM_CLK),
        .sd_dqm  (sd_dqm),

        .init    (~reset_n_f),
        .clk     (sdram_clk),
        .addr    (acc_addr),
        .din     (acc_wdata),
        .dout    (sd_dout),
        .dout16  (sd_dout16),
        .refresh (sd_refresh),
        .ce      (sd_ce),
        .we      (sd_we_l)
    );
    assign SDRAM_CKE  = 1'b1;
    assign SDRAM_DQML = sd_dqm[0];
    assign SDRAM_DQMH = sd_dqm[1];

    // ========================================================================
    // CPU domain
    //
    // WRITES go into a 4-deep FIFO, captured at the write-on-bus posedge, and
    // are drained ahead of any read so read-after-write ordering holds.
    // READS use consume-clear delivery (see header note 3).
    // ========================================================================
    logic [31:0] wfifo [0:3];                  // {byte_addr[23:0], wr_data[7:0]}
    logic  [1:0] wf_rd, wf_wr;
    logic  [2:0] wf_cnt;

    wire wf_nonempty = (wf_cnt != 3'd0);
    wire wf_hi       = (wf_cnt >= 3'd2);       // keep headroom for 2 more
    // Push exactly once per write, on its committing (unstalled) cycle.  The
    // '816 freezes mid-write when stalled, holding cs/we/addr/data; an ungated
    // push would re-push every clock until wf_wr laps wf_rd and writes are LOST.
    // During a write, ready == ~wf_hi, so ~wf_hi *is* "at the commit edge".
    wire wpush = cs & we & ~wf_hi;

    logic [1:0] ack_s;
    logic       ack_d, waiting, served_valid, wr_since_issue;
    wire        ack_edge  = (ack_s[1] != ack_d);
    wire        need_read = cs & ~we & ~served_valid;
    wire        wpop      = ~waiting & wf_nonempty;

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            req_tgl <= 1'b0; ack_s <= 2'b00; ack_d <= 1'b0;
            waiting <= 1'b0; served_valid <= 1'b0; wr_since_issue <= 1'b0;
            lat_we  <= 1'b0; lat_addr <= 24'h0; lat_wdata <= 8'h00;
            wf_rd   <= 2'd0; wf_wr <= 2'd0; wf_cnt <= 3'd0;
            rd_data <= 8'h00;
        end else begin
            ack_s <= {ack_s[0], ack_tgl};
            ack_d <= ack_s[1];

            // consume-clear: on the delivery cycle the CPU takes rd_data at
            // this posedge, so the next in-window access must re-serve.
            if (cs & ~we & served_valid) served_valid <= 1'b0;
            if (!cs)                     served_valid <= 1'b0;

            // issue next access: queued writes first, then the pending read
            if (!waiting) begin
                if (wf_nonempty) begin
                    lat_we                <= 1'b1;
                    {lat_addr, lat_wdata} <= wfifo[wf_rd];
                    wf_rd                 <= wf_rd + 2'd1;
                    req_tgl               <= ~req_tgl;
                    waiting               <= 1'b1;
                    wr_since_issue        <= 1'b0;
                end else if (need_read) begin
                    lat_we         <= 1'b0;
                    lat_addr       <= byte_addr;
                    req_tgl        <= ~req_tgl;
                    waiting        <= 1'b1;
                    wr_since_issue <= 1'b0;
                end
            end

            if (wpush) begin
                wfifo[wf_wr]   <= {byte_addr, wr_data};
                wf_wr          <= wf_wr + 2'd1;
                served_valid   <= 1'b0;          // a write shadows any delivery
                wr_since_issue <= 1'b1;
            end

            wf_cnt <= wf_cnt + (wpush ? 3'd1 : 3'd0) - (wpop ? 3'd1 : 3'd0);

            // Fast domain finished the in-flight access.  Deliver ONLY if no
            // write was pushed while the read was in flight and the CPU is
            // still parked on this exact read; otherwise drop it and let the
            // read re-serve.  Both checks feed registers, never the comb cone.
            if (waiting && ack_edge) begin
                waiting <= 1'b0;
                if (!lat_we && !wr_since_issue
                    && cs && !we && (byte_addr == lat_addr)) begin
                    served_valid <= 1'b1;
                    rd_data      <= rd_data_f;
                end
            end
        end
    end

    // See header notes 1 and 2 before touching this line.
    assign ready = (~cs | we | (served_valid & ~waiting)) & ~wf_hi;

    // ========================================================================
    // SDRAM domain -- init / refresh / download / CPU access.
    // REFRESH has top priority so a seconds-long download cannot starve it.
    // ========================================================================
    typedef enum logic [1:0] {S_INIT, S_IDLE, S_ACC, S_RFSH} st_t;
    st_t         state;
    logic  [9:0] init_cnt, rfsh_cnt;
    logic  [3:0] cyc;
    logic  [1:0] req_s;
    logic        req_d, req_pending;
    logic        acc_is_ld;

    logic [31:0] ldfifo [0:7];                 // {ld_addr[23:0], ld_data[7:0]}
    logic  [2:0] ldf_rd, ldf_wr;
    logic  [3:0] ldf_cnt;
    wire         ldf_nonempty = (ldf_cnt != 4'd0);
    assign       ld_busy      = (ldf_cnt >= 4'd4);   // headroom for in-flight

    wire refresh_due = (rfsh_cnt == REFRESH_INTERVAL);
    wire ld_pop      = (state == S_IDLE) & ~refresh_due & ldf_nonempty;

    always_ff @(posedge sdram_clk or negedge reset_n_f) begin
        if (!reset_n_f) begin
            state <= S_INIT; init_cnt <= 10'd0; rfsh_cnt <= 10'd0; cyc <= 4'd0;
            sd_ce <= 1'b0; sd_refresh <= 1'b0; sd_we_l <= 1'b0; rd_data_f <= 8'h00;
            req_s <= 2'b00; req_d <= 1'b0; req_pending <= 1'b0; ack_tgl <= 1'b0;
            acc_addr <= 25'h0; acc_wdata <= 8'h0; acc_is_ld <= 1'b0;
            ldf_rd <= 3'd0; ldf_wr <= 3'd0; ldf_cnt <= 4'd0;
        end else begin
            sd_ce      <= 1'b0;   // ce/refresh are single-cycle triggers
            sd_refresh <= 1'b0;

            req_s <= {req_s[0], req_tgl};
            req_d <= req_s[1];
            if (req_s[1] != req_d) req_pending <= 1'b1;

            if (!refresh_due) rfsh_cnt <= rfsh_cnt + 10'd1;

            if (ld_wr) begin
                ldfifo[ldf_wr] <= {ld_addr, ld_data};
                ldf_wr         <= ldf_wr + 3'd1;
            end
            ldf_cnt <= ldf_cnt + (ld_wr ? 4'd1 : 4'd0) - (ld_pop ? 4'd1 : 4'd0);

            case (state)
                S_INIT: begin
                    init_cnt <= init_cnt + 10'd1;
                    if (init_cnt == INIT_WAIT_LEN) state <= S_IDLE;
                end
                S_IDLE: begin
                    if (refresh_due) begin
                        sd_refresh <= 1'b1; rfsh_cnt <= 10'd0; cyc <= 4'd0;
                        state <= S_RFSH;
                    end else if (ldf_nonempty) begin
                        sd_ce      <= 1'b1;
                        sd_we_l    <= 1'b1;
                        acc_addr   <= map_addr(ldfifo[ldf_rd][31:8]);
                        acc_wdata  <= ldfifo[ldf_rd][7:0];
                        ldf_rd     <= ldf_rd + 3'd1;
                        acc_is_ld  <= 1'b1;
                        cyc        <= 4'd0;
                        state      <= S_ACC;
                    end else if (req_pending) begin
                        // snapshot the cpu-domain params (stable by construction)
                        sd_ce       <= 1'b1;
                        sd_we_l     <= lat_we;
                        acc_addr    <= map_addr(lat_addr);
                        acc_wdata   <= lat_wdata;
                        acc_is_ld   <= 1'b0;
                        cyc         <= 4'd0;
                        req_pending <= 1'b0;
                        state       <= S_ACC;
                    end
                end
                S_ACC: begin
                    cyc <= cyc + 4'd1;
                    if (cyc == CYCLE_LEN) begin
                        if (!acc_is_ld) begin
                            rd_data_f <= sd_dout;
                            ack_tgl   <= ~ack_tgl;   // completion -> CPU domain
                        end
                        state <= S_IDLE;
                    end
                end
                S_RFSH: begin
                    cyc <= cyc + 4'd1;
                    if (cyc == CYCLE_LEN) state <= S_IDLE;
                end
                default: state <= S_IDLE;
            endcase
        end
    end

    // dout16 is unused here (the 16-bit fetch optimisation is a later step);
    // reference it so Quartus does not warn about a dangling output.
    wire _unused_dout16 = |sd_dout16;

endmodule
