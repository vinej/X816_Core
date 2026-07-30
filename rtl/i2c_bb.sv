//============================================================================
// i2c_bb.sv  -  bit-banged I2C master (~100 kHz) for ADV7513 + WM8731 init.
//
// Single-byte register writes only:  start | dev_addr | reg_addr | data | stop.
// Drive `start` high for one cycle while `dev_addr`, `reg_addr`, `data` are
// stable; `busy` rises immediately and falls when the bus is idle again.
// `ack_error` latches if any byte was NACK'd (cleared on next start).
//
// SCL / SDA are open-drain: we only drive low.  Pull-ups are on the board.
//
//   clk_sys parameter must match the system clock so the SCL divider lands
//   on ~100 kHz.  Default 50 MHz -> divide by 500 -> 100 kHz toggle base.
//============================================================================

module i2c_bb #(
    parameter int CLK_FREQ_HZ = 50_000_000,
    parameter int I2C_FREQ_HZ =    100_000
) (
    input  logic        clk,
    input  logic        reset_n,

    input  logic        start,
    input  logic [6:0]  dev_addr,    // 7-bit slave address
    input  logic [7:0]  reg_addr,
    input  logic [7:0]  data,
    output logic        busy,
    output logic        ack_error,

    inout  wire         scl,
    inout  wire         sda
);

    // Quarter-bit tick: 4 phases per I2C bit (set-up SDA, raise SCL, hold, fall SCL).
    localparam int DIV = CLK_FREQ_HZ / (I2C_FREQ_HZ * 4);

    logic [$clog2(DIV)-1:0] div_cnt;
    logic                   qtick;

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            div_cnt <= '0;
            qtick   <= 1'b0;
        end
        else if (div_cnt == DIV - 1) begin
            div_cnt <= '0;
            qtick   <= 1'b1;
        end
        else begin
            div_cnt <= div_cnt + 1'b1;
            qtick   <= 1'b0;
        end
    end

    typedef enum logic [4:0] {
        S_IDLE, S_START1, S_START2,
        S_SHIFT_SETUP, S_SHIFT_HIGH1, S_SHIFT_HIGH2, S_SHIFT_LOW,
        S_ACK_REL, S_ACK_HIGH, S_ACK_SAMPLE, S_ACK_LOW,
        S_NEXTBYTE,
        S_STOP1, S_STOP2, S_STOP3
    } state_t;

    state_t      state;
    logic [7:0]  shreg;
    logic [2:0]  bit_idx;
    logic [1:0]  byte_idx;     // 0=addr+W, 1=reg, 2=data
    logic        scl_o, sda_o; // 0 -> drive low, 1 -> release (hi-Z)

    assign scl = scl_o ? 1'bz : 1'b0;
    assign sda = sda_o ? 1'bz : 1'b0;

    assign busy = (state != S_IDLE);

    // 3 bytes to send: {addr,W=0}, reg, data
    function automatic logic [7:0] byte_for(input logic [1:0] idx);
        case (idx)
            2'd0:    byte_for = {dev_addr, 1'b0};
            2'd1:    byte_for = reg_addr;
            default: byte_for = data;
        endcase
    endfunction

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state     <= S_IDLE;
            scl_o     <= 1'b1;
            sda_o     <= 1'b1;
            bit_idx   <= 3'd7;
            byte_idx  <= 2'd0;
            shreg     <= 8'h00;
            ack_error <= 1'b0;
        end
        else begin
            case (state)
                S_IDLE: begin
                    scl_o <= 1'b1;
                    sda_o <= 1'b1;
                    if (start) begin
                        ack_error <= 1'b0;
                        byte_idx  <= 2'd0;
                        shreg     <= byte_for(2'd0);
                        bit_idx   <= 3'd7;
                        state     <= S_START1;
                    end
                end

                // START: SDA falls while SCL is high.
                S_START1: if (qtick) begin sda_o <= 1'b0; state <= S_START2; end
                S_START2: if (qtick) begin scl_o <= 1'b0; state <= S_SHIFT_SETUP; end

                // Shift out 8 bits, MSB first.
                S_SHIFT_SETUP: if (qtick) begin
                    sda_o <= shreg[7];
                    state <= S_SHIFT_HIGH1;
                end
                S_SHIFT_HIGH1: if (qtick) begin scl_o <= 1'b1; state <= S_SHIFT_HIGH2; end
                S_SHIFT_HIGH2: if (qtick) begin                state <= S_SHIFT_LOW;   end
                S_SHIFT_LOW:   if (qtick) begin
                    scl_o <= 1'b0;
                    shreg <= {shreg[6:0], 1'b0};
                    if (bit_idx == 3'd0) state <= S_ACK_REL;
                    else begin
                        bit_idx <= bit_idx - 3'd1;
                        state   <= S_SHIFT_SETUP;
                    end
                end

                // Release SDA so slave can ACK.
                S_ACK_REL:    if (qtick) begin sda_o <= 1'b1; state <= S_ACK_HIGH; end
                S_ACK_HIGH:   if (qtick) begin scl_o <= 1'b1; state <= S_ACK_SAMPLE; end
                S_ACK_SAMPLE: if (qtick) begin
                    if (sda == 1'b1) ack_error <= 1'b1; // NACK
                    state <= S_ACK_LOW;
                end
                S_ACK_LOW:    if (qtick) begin scl_o <= 1'b0; state <= S_NEXTBYTE; end

                S_NEXTBYTE: begin
                    if (byte_idx == 2'd2) state <= S_STOP1;
                    else begin
                        byte_idx <= byte_idx + 2'd1;
                        shreg    <= byte_for(byte_idx + 2'd1);
                        bit_idx  <= 3'd7;
                        state    <= S_SHIFT_SETUP;
                    end
                end

                // STOP: SDA rises while SCL is high.
                S_STOP1: if (qtick) begin sda_o <= 1'b0; state <= S_STOP2; end
                S_STOP2: if (qtick) begin scl_o <= 1'b1; state <= S_STOP3; end
                S_STOP3: if (qtick) begin sda_o <= 1'b1; state <= S_IDLE;  end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
