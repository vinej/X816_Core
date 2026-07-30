//`default_nettype none

// jyv 2026-07-07: VERA FX 16x16 multiplier + 32-bit accumulator.
// Generic re-implementation of the upstream mult_accum.v, which instantiates
// the Lattice iCE40 pmi_dsp (SB_MAC16) primitive -- not available on
// Cyclone V.  Behavior replicated from the primitive configuration used
// upstream (X16Community/vera-module v47.0.2):
//
//   * output_32 = accum ± (A*B) when mult_enabled, else the raw
//     {B,A} cache passthrough (upstream uses the DSP's OLOAD path for this,
//     so cache writes with the multiplier disabled write the cache itself).
//   * accumulate (1-cycle pulse) captures output_32 into the accumulator.
//   * reset_accum (1-cycle pulse) clears the accumulator (wins over
//     accumulate, matching the DSP's ORST priority).
//   * add_or_sub: 0 = accum + product, 1 = accum - product (ADDSUB=1 is
//     subtract on the SB_MAC16).
//
// Quartus infers a DSP block for the signed 16x16 multiply.
module mult_accum (
    input  wire        clk,

    input  wire [15:0] input_a_16,
    input  wire [15:0] input_b_16,
    input  wire        mult_enabled,
    input  wire        reset_accum,
    input  wire        accumulate,
    input  wire        add_or_sub,

    output wire [31:0] output_32);

    // Power-up at 0 like the SB_MAC16 output FFs (Quartus honors the
    // initializer; without it ModelSim propagates X until the first
    // accumulator reset and poisons every multiply result).
    reg [31:0] accum_r = 32'd0;

    wire signed [31:0] mult_result = $signed(input_a_16) * $signed(input_b_16);

    wire [31:0] adder_out = add_or_sub ? (accum_r - mult_result)
                                       : (accum_r + mult_result);

    // OLOAD equivalent: multiplier disabled passes the raw cache through.
    wire [31:0] adder_or_load = mult_enabled ? adder_out
                                             : {input_b_16, input_a_16};

    always @(posedge clk) begin
        if (reset_accum) begin
            accum_r <= 32'd0;
        end else if (accumulate) begin
            accum_r <= adder_or_load;
        end
    end

    assign output_32 = adder_or_load;

endmodule
