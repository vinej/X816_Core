//============================================================================
// bank0_ram.sv  --  Bank $00 of the flat map, in on-chip M10K.
//
// WHY BANK 0 IS SPECIAL (and why it gets the fast memory):
// the 65816 forces two of its hottest structures into bank 0 regardless of
// what DBR/PBR hold --
//     * the STACK is always bank $00 (S is 16-bit in native mode, but the
//       bank is fixed),
//     * DIRECT PAGE is always bank $00 (D is a 16-bit offset within it).
// So every JSR/RTS, every interrupt, every push/pull and every dp-addressed
// operand lands here.  Backing bank 0 with single-cycle BRAM instead of SDRAM
// removes the stall from the paths that execute most often; banks $01-$FF go
// to flat_sdram.sv.  The CPU sees one uniform 16 MB space either way -- the
// split is invisible to software.
//
// Bank 0 is 64 KB, but two ranges are carved out by the parent's decode and
// never reach this module's READ path:
//     $00:9F00-$00:9FFF   I/O page (VERA, YM2151, VIA1/2, system control)
//     $00:FF00-$00:FFFF   boot ROM overlay, while SYSCTL bit 0 is set
// The array is still allocated full-size: the holes cost ~2 M10K, and keeping
// the address math a plain truncation avoids a decode term in the read path.
// WRITES to $FF00-$FFFF land here even while the overlay is active, so boot
// code can copy itself down and then unmap the overlay (see boot_rom.sv).
//
// M10K is zero-initialised by FPGA configuration, so power-on state is
// deterministic -- unlike the SDRAM banks, which come up as noise.
//
// *** NEGEDGE READ *** gives the M10K a half-cycle head start, so rd_data
// reflects mem[addr presented THIS cycle] when the CPU samples it at the next
// posedge.  Same convention as the X16 core's lowram_bram/rom_banks.
//
// DOWNLOAD PORT.  M10K has two ports and the read port owns one, so the
// loader cannot have a port of its own: instead its bytes are carried into
// the CPU clock domain by a toggle handshake and muxed onto the single write
// port.  That is safe because the CPU is held in reset for the whole download
// (x816.sv `dl_hold`), so its write port is idle.  ld_busy is held until the
// byte has been consumed and drives ioctl_wait, so the HPS is throttled to
// the crossing rate (~3 cpu_clk/byte = ~2.6 MB/s at 8 MHz) instead of
// overrunning it.
//============================================================================
module bank0_ram (
    input  logic        clk,          // cpu_clk
    input  logic [15:0] addr,         // offset within bank $00
    input  logic        cs,           // 1 = this access targets bank-0 RAM
    input  logic        we,           // 1 = write, 0 = read
    input  logic  [7:0] wr_data,
    output logic  [7:0] rd_data,

    // ---- download port (ld_clk domain; CPU must be in reset) ----
    input  logic        ld_clk,
    input  logic        ld_wr,        // 1-cycle strobe, qualified by the parent
    input  logic [15:0] ld_addr,
    input  logic  [7:0] ld_data,
    output logic        ld_busy       // -> ioctl_wait
);

    (* ramstyle = "M10K" *) logic [7:0] mem [0:65535];

    // ---- ld_clk side: 8-deep FIFO feeding a one-in-flight toggle handshake --
    // The FIFO is not an optimisation, it is required for correctness.  A
    // single-byte latch would drop bytes: ld_busy is REGISTERED, so it rises a
    // cycle after the byte is accepted, and hps_io can issue another ld_wr in
    // that gap before it sees ioctl_wait.  Asserting busy at half depth leaves
    // 4 slots of slack for bytes already in flight -- the same margin
    // ext_ram_sdram.sv uses on its cart-loader port.
    logic [23:0] ldfifo [0:7];                 // {ld_addr[15:0], ld_data[7:0]}
    logic  [2:0] ldf_rd = 3'd0, ldf_wr = 3'd0;
    logic  [3:0] ldf_cnt = 4'd0;
    wire         ldf_nonempty = (ldf_cnt != 4'd0);
    assign       ld_busy      = (ldf_cnt >= 4'd4);

    logic        req_tgl = 1'b0;
    logic [15:0] req_addr;
    logic  [7:0] req_data;
    logic  [1:0] ack_s   = 2'b00;
    logic        ack_d   = 1'b0;
    logic        pending = 1'b0;
    wire         ldf_pop = ldf_nonempty & ~pending;

    always_ff @(posedge ld_clk) begin
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

    // ----- cpu_clk side: see the req flip, commit the byte, flip ack ----
    logic       ack_tgl = 1'b0;
    logic [1:0] req_s   = 2'b00;
    logic       req_d   = 1'b0;
    always_ff @(posedge clk) begin
        req_s <= {req_s[0], req_tgl};
        req_d <= req_s[1];
        if (req_s[1] != req_d) ack_tgl <= ~ack_tgl;
    end
    wire ld_commit = (req_s[1] != req_d);

    // ---- single write port, loader takes priority (CPU is in reset) ----
    wire [15:0] wa = ld_commit ? req_addr : addr;
    wire  [7:0] wd = ld_commit ? req_data : wr_data;
    wire        wen = ld_commit | (cs & we);

    always_ff @(posedge clk) begin
        if (wen) mem[wa] <= wd;
    end

    always_ff @(negedge clk) begin
        rd_data <= mem[addr];
    end

endmodule
