//============================================================================
// cpu_pace.sv  --  the CPU advance pacer behind SYSCTL's TURBO bit.
//
// WHY THE MACHINE HAS TWO SPEEDS FROM ONE CLOCK
//
// The whole cpu_clk domain runs at 14 MHz (the PLL's outclk_1, retuned from
// 12.5 MHz after the 12.5 build proved out on hardware).  The measured Fmax
// of the domain is 17.7 MHz -- limited by the deliberate negedge BRAM reads
// in fast_ram/bank0_ram -- so 14 MHz closes with a 26% margin and NOTHING in
// the domain needed retiming.  14 MHz IS THE PROVEN CEILING: a 16 MHz build
// (2026-08-04, pace 1/2, read stall 4) passed STA with +8 ns of setup slack
// in this domain and every other corner clean, and still CRASHED the board
// -- whatever breaks at 16 is not in the timing report, so do not re-try 16
// by just turning the frequency back up.  What did need care is software
// compatibility: an 8 MHz machine that silently became 1.75x faster would
// invalidate every measured number in doc/ and any delay loop ever written
// against it.
//
// So the CLOCK never changes; the CPU's ADVANCE RATE does.  The P65C816 takes
// a global clock-enable (x816.sv wires cpu_rdy into it already, for stalls);
// this module produces one more enable term:
//
//   turbo = 1   adv_en high every cycle          -> CPU at 14 MHz
//   turbo = 0   adv_en high PACE_NUM cycles of   -> CPU at 14 * 4/7
//               every PACE_DEN, phase-accumulated =  8.000 MHz average, exact
//
// The fractional accumulator adds NUM into a mod-DEN counter every clock and
// advances on the cycles where it wraps, so the 8 MHz mode is exact in the
// long run (4 advances in every 7-clock window; NUM/DEN are coprime so the
// pattern period IS 7).  Individual gaps are 0 or 1 extra stall cycles --
// invisible to software, which already lives with multi-cycle SDRAM stalls.
//
// Everything else in the domain (VIA, SMC, PS/2 bridge, ms_timer, the VERA
// bus pipeline) keeps running on the raw 14 MHz clock in BOTH modes, so
// their behaviour is mode-independent: ms_timer divides 14000 to a true
// millisecond whichever speed the CPU runs at, and the VERA strobe widths in
// nanoseconds never change.  The one systemic consequence -- that a paced CPU
// HOLDS a bus state for extra cycles -- is handled where the bus is consumed:
// every level-sensitive commit point takes the composed advance signal
// (x816.sv `cpu_adv`), the same discipline those points already needed for
// SDRAM/SD stalls.
//
// WHY IT IS A MODULE AND NOT SIX LINES IN x816.sv
//
// ms_timer.sv's argument, verbatim: x816.sv can only be proven by compiling a
// bitstream, and the property that matters here -- that turbo=0 advances
// EXACTLY 4 of every 7 cycles, not roughly -- is exactly the one a screen
// cannot show.  sim/tb_cpu_pace.v counts it directly.
//============================================================================
`default_nettype none

module cpu_pace #(
    parameter [5:0] PACE_NUM = 6'd4,    // advance this many cycles...
    parameter [5:0] PACE_DEN = 6'd7     // ...of every this many, when ~turbo
) (
    input  wire clk,        // cpu_clk, 14 MHz
    input  wire reset_n,
    input  wire turbo,      // SYSCTL bit 2: 1 = full clock rate
    output reg  adv_en      // this cycle may advance the CPU
);

    // Phase accumulator, mod PACE_DEN.  adv_en is REGISTERED -- it feeds the
    // CPU's global clock-enable cone (see flat_sdram.sv header note 1 on why
    // that cone is treated with respect), so it must be a flop output, not
    // arithmetic.
    reg  [5:0] acc = 6'd0;
    wire [6:0] sum  = {1'b0, acc} + {1'b0, PACE_NUM};
    wire       wrap = (sum >= {1'b0, PACE_DEN});

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            acc    <= 6'd0;
            adv_en <= 1'b1;      // never gate the first post-reset cycle
        end else if (turbo) begin
            acc    <= 6'd0;      // re-enter 8 MHz mode at a known phase
            adv_en <= 1'b1;
        end else begin
            acc    <= wrap ? (sum[5:0] - PACE_DEN) : sum[5:0];
            adv_en <= wrap;
        end
    end

endmodule

`default_nettype wire
