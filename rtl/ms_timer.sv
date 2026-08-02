//============================================================================
// ms_timer.sv  --  the free-running millisecond counter at $00:9F90-$00:9F93.
//
// WHY THIS EXISTS AS A DEVICE AT ALL
//
// The kernel needs a monotonic clock (doc/KERNEL.md 5.6, TIME_GET), and every
// timebase this machine already had runs SLOW in proportion to SD activity:
//
//   * Both VIAs take .enable(cpu_rdy) in x816.sv, so their timers stop dead
//     for the whole length of an SD transfer.  That is doc/AUDIT.md L-4,
//     accepted at the time on the grounds that nothing kept time yet.
//   * VERA does keep running -- it is in pix_clk -- but its VSYNC interrupt
//     is a single LATCH.  Freeze the CPU across four frames and the handler
//     still sees one VSYNC, so a jiffy count driven from it loses the other
//     three.
//
// Both failures are silent and proportional to how busy the card is, which is
// the worst shape a clock error can have.  So this counter is gated by
// NOTHING: not cpu_rdy, not a chip select, not the read port.  It is clk and
// reset_n, and that is the entire design.  The keyboard diagnostic counters
// at $9F8D-$9F8F are the same shape and the precedent for it.
//
// WHY IT IS A SEPARATE FILE AND NOT TEN LINES INSIDE x816.sv
//
// Because it can be simulated.  x816.sv cannot be brought up in a testbench
// without hps_io, the PLLs and the whole of VERA behind it, so anything
// written inline there is provable only by compiling a bitstream and looking
// at a screen.  As a module, sim/tb_ms_timer.v drives it directly -- including
// the one property that matters most and is otherwise untestable: that the
// count still advances while cpu_rdy is held LOW.
//
// TEARING, AND THE LATCH THAT FIXES IT
//
// The CPU reads 32 bits one byte at a time and the counter does not pause to
// let it.  A read straddling a carry ($..FF -> $..00 between two byte reads)
// returns a value that was never true and can go BACKWARDS -- fatal in a
// monotonic clock, and intermittent enough to survive testing.
//
// So reading the LOW byte at $9F90 captures bits 31:8 into a shadow, and
// $9F91-$9F93 read the shadow.  SOFTWARE MUST READ $9F90 FIRST; that is
// normative and doc/MEMORY_MAP.md says so.  It also means a 16-bit `lda
// $9F90` followed by a 16-bit `lda $9F92` returns one coherent 32-bit value,
// which is exactly what runtime/kirq.s does.
//
// The capture takes bits 31:8 of the SAME value the read is returning bits
// 7:0 of: the non-blocking assignment samples ms_r before the increment in
// the block above can land, so a read landing exactly on a tick is coherent
// rather than being the one case that tears.
//============================================================================
`default_nettype none

module ms_timer #(
    // cpu_clk cycles per tick.  8.000 MHz / 8000 = 1 kHz exactly, so the unit
    // is a millisecond with no rounding error to accumulate.  Checked against
    // the contract by tools/contract.py; the testbench overrides it to
    // something small so it can reach a carry without simulating a quarter of
    // a second.
    parameter [12:0] TIMER_DIV = 13'd8000
) (
    input  wire       clk,
    input  wire       reset_n,
    input  wire       cs,        // $9F90-$9F93, already dec_valid-qualified
    input  wire       rd,        // cpu_rwn
    input  wire       cpu_rdy,   // a read commits only on an advancing cycle
    input  wire [1:0] addr,
    output wire [7:0] rd_data
);

    reg [12:0] div_r   = 13'd0;
    reg [31:0] ms_r    = 32'd0;
    reg [23:0] latch_r = 24'd0;

    // Deliberately NOT gated by cpu_rdy.  See the header.
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            div_r <= 13'd0;
            ms_r  <= 32'd0;
        end else if (div_r == TIMER_DIV - 13'd1) begin
            div_r <= 13'd0;
            ms_r  <= ms_r + 32'd1;
        end else begin
            div_r <= div_r + 13'd1;
        end
    end

    // cpu_rdy DOES gate the capture, and must: the CPU repeats the address of
    // a stalled cycle, and a capture on every repeat would re-sample the high
    // bytes after the low byte had already been taken.
    always @(posedge clk) begin
        if (cpu_rdy && cs && rd && addr == 2'b00)
            latch_r <= ms_r[31:8];
    end

    assign rd_data = (addr == 2'b00) ? ms_r[7:0]
                   : (addr == 2'b01) ? latch_r[7:0]
                   : (addr == 2'b10) ? latch_r[15:8]
                                     : latch_r[23:16];

endmodule

`default_nettype wire
